-- Delirium-News: client side — receives the document, downloads and caches
-- pictures in Zomboid/Lua/DelNews_cache/, hands everything to the UI.
if isServer() then return end
require "DelNews_Shared"

DelNewsClient = {}
local C = DelNewsClient
local MOD = DelNews.MODULE

C.doc = nil      -- { hash, docId, tabs = { { title, lines } }, unread, empty }
C.images = {}    -- name -> { state, key, count, parts, received, tex, lastProgress }

local pending = nil      -- document being assembled from parts
local gotFirstDoc = false
local lastHello = 0
local lastStallCheck = 0
local writeQueue = {}    -- names whose chunks are all here
local writer = nil       -- { name, stream, idx }

local HELLO_RETRY_MS = 5000
local DOWNLOAD_STALL_MS = 30000
local WRITE_PARTS_PER_TICK = 2

local function log(msg) print("[DelNews] " .. msg) end

local function sendHello()
	local player = getPlayer()
	if not player then return end
	lastHello = getTimestampMs()
	sendClientCommand(player, MOD, "hello", { lang = Translator.getLanguage():name(), login = not gotFirstDoc })
end

local function send(command, args)
	local player = getPlayer()
	if player then sendClientCommand(player, MOD, command, args) end
end

---- pictures -----------------------------------------------------------------

-- getTexture() takes an absolute path (vanilla getTextureFromSaveDir passes
-- one). Quoting it inside rich text would break on spaces in the user folder,
-- so the UI looks textures up by name instead.
local function cacheAbsPath(key)
	local sep = getFileSeparator()
	return getMyDocumentFolder() .. sep .. "Lua" .. sep .. "DelNews_cache" .. sep .. key .. ".png"
end

local function loadTexture(name)
	local img = C.images[name]
	-- The engine remembers failed texture loads by path, so this must only run
	-- once the file is completely written.
	local tex = getTexture(cacheAbsPath(img.key))
	if tex then
		img.state = "ready"
		img.tex = tex
	else
		img.state = "failed"
		log("could not load texture " .. cacheAbsPath(img.key))
	end
	if DelNewsUI then DelNewsUI.onImageChanged(name) end
end

local function isCached(key)
	local r = getFileReader(DelNews.CACHE_DIR .. key .. ".txt", false)
	if r then r:close(); return true end
	return false
end

local function requestImages()
	if not C.doc or not C.doc.tabs then return end
	for _, tab in ipairs(C.doc.tabs) do
		for _, line in ipairs(tab.lines) do
			for name in string.gmatch(line, "<IMG:%s*([^>,%s]+)") do
				if DelNews.isValidImageName(name) then
					local img = C.images[name]
					-- Re-ask every time the document arrives: the picture may have
					-- been uploaded or replaced since.
					if not img or img.state == "missing" or img.state == "failed" or img.state == "ready" then
						C.images[name] = C.images[name] or {}
						C.images[name].state = C.images[name].state or "asked"
						send("img", { name = name })
					end
				end
			end
		end
	end
end

local function onImageInfo(args)
	local name = args.name
	local img = C.images[name]
	if not img then img = {}; C.images[name] = img end
	if args.missing then
		img.state = "missing"
		if DelNewsUI then DelNewsUI.onImageChanged(name) end
		return
	end
	if img.key == args.key and (img.state == "ready" or img.state == "downloading" or img.state == "writing") then
		return
	end
	img.key = args.key
	img.count = args.count
	img.tex = nil
	if isCached(args.key) then
		loadTexture(name)
		return
	end
	img.state = "downloading"
	img.parts = {}
	img.received = 0
	img.lastProgress = getTimestampMs()
	send("imgGet", { name = name })
	if DelNewsUI then DelNewsUI.onImageChanged(name) end
end

local function onImagePart(args)
	local img = C.images[args.name]
	if not img or img.state ~= "downloading" or img.key ~= args.key then return end
	if not img.parts[args.idx] then
		img.parts[args.idx] = args.data
		img.received = img.received + 1
	end
	img.lastProgress = getTimestampMs()
	if img.received >= img.count then
		img.state = "writing"
		writeQueue[#writeQueue + 1] = args.name
	end
end

local function stepWriting()
	if not writer then
		local name = table.remove(writeQueue, 1)
		if not name then return end
		local img = C.images[name]
		local stream = getFileOutput(DelNews.CACHE_DIR .. img.key .. ".png")
		if not stream then
			img.state = "failed"
			log("cannot write cache file for " .. name)
			return
		end
		writer = { name = name, stream = stream, idx = 1 }
		return
	end
	local img = C.images[writer.name]
	for _ = 1, WRITE_PARTS_PER_TICK do
		if writer.idx > img.count then break end
		DelNews.decodeToStream(img.parts[writer.idx], writer.stream)
		writer.idx = writer.idx + 1
	end
	if writer.idx > img.count then
		writer.stream:close()
		img.parts = nil
		-- Marker written last: a crash mid-write leaves no marker, so the
		-- half-written picture is downloaded again next time.
		local w = getFileWriter(DelNews.CACHE_DIR .. img.key .. ".txt", true, false)
		if w then w:write("ok"); w:close() end
		local name = writer.name
		writer = nil
		loadTexture(name)
	end
end

local function checkStalls(now)
	for name, img in pairs(C.images) do
		if img.state == "downloading" and now - (img.lastProgress or now) > DOWNLOAD_STALL_MS then
			img.lastProgress = now
			img.parts = {}
			img.received = 0
			send("imgGet", { name = name })
		end
	end
end

---- document -----------------------------------------------------------------

-- Same layout as SSR Newsboard files, so existing news can be copied over:
-- optional "<VERSION...>" first line (ignored, changes are detected by content),
-- then tab title, tab lines, "<PAGE>", next tab title, ...
local function parseTabs(lines)
	local tabs = {}
	local i = 1
	if lines[1] and string.find(lines[1], "^%s*<VERSION") then i = 2 end
	local cur = nil
	while i <= #lines do
		local line = lines[i]
		if string.match(line, "^%s*<PAGE>%s*$") then
			cur = nil
		elseif not cur then
			cur = { title = line, lines = {} }
			tabs[#tabs + 1] = cur
		else
			cur.lines[#cur.lines + 1] = line
		end
		i = i + 1
	end
	return tabs
end

local function onDocPart(args)
	if args.empty then
		gotFirstDoc = true
		C.doc = { empty = true, tabs = {} }
		if DelNewsUI then DelNewsUI.onDocChanged(false) end
		return
	end
	if not pending or pending.hash ~= args.hash or args.part == 1 then
		pending = { hash = args.hash, docId = args.docId, parts = {}, got = 0, total = args.parts }
	end
	if not pending.parts[args.part] then
		pending.parts[args.part] = args.lines or {}
		pending.got = pending.got + 1
	end
	if pending.got < pending.total then return end

	local lines = {}
	for p = 1, pending.total do
		for _, line in ipairs(pending.parts[p]) do lines[#lines + 1] = line end
	end
	local previous = C.doc
	C.doc = { hash = pending.hash, docId = pending.docId, tabs = parseTabs(lines), unread = args.unread == true }
	pending = nil

	local wasLogin = not gotFirstDoc
	gotFirstDoc = true
	if not wasLogin and previous and previous.hash ~= C.doc.hash and C.doc.unread then
		local player = getPlayer()
		if player then player:setHaloNote(getText("IGUI_DelNews_Updated"), 150, 200, 255, 300) end
	end
	requestImages()
	if DelNewsUI then DelNewsUI.onDocChanged(wasLogin and args.autoOpen == true) end
end

function C.markRead()
	if C.doc and C.doc.hash and C.doc.unread then
		C.doc.unread = false
		send("read", { hash = C.doc.hash })
	end
end

---- events -------------------------------------------------------------------

local function onServerCommand(module, command, args)
	if module ~= MOD then return end
	if command == "doc" then
		onDocPart(args)
	elseif command == "changed" then
		sendHello()
	elseif command == "imgInfo" then
		onImageInfo(args)
	elseif command == "imgPart" then
		onImagePart(args)
	end
end

local function onTick()
	local now = getTimestampMs()
	-- A single "on connect" request can be lost before the local player exists;
	-- keep asking until the document is really here.
	if not gotFirstDoc and now - lastHello > HELLO_RETRY_MS then sendHello() end
	stepWriting()
	if now - lastStallCheck > 5000 then
		lastStallCheck = now
		checkStalls(now)
	end
end

if isClient() then
	Events.OnServerCommand.Add(onServerCommand)
	Events.OnGameStart.Add(sendHello)
	Events.OnCreatePlayer.Add(function() sendHello() end)
	Events.OnTick.Add(onTick)
end
