-- Delirium-News: server side.
-- Reads Zomboid/Lua/DelNews/news*.txt every few seconds, tells clients when a
-- document changed, and streams pictures from Zomboid/Lua/DelNews/*.png to
-- clients that do not have them cached yet.
if not isServer() then return end
require "DelNews_Shared"

local MOD = DelNews.MODULE
local DIR = DelNews.DIR

local config = {
	showOnLogin = "new",       -- new | always | never
	pollSeconds = 10,
	imageChunksPerTick = 2,    -- 16 KB of base64 each
}

local docs = {}          -- docId ("default", "RU", ...) -> { content, hash, lines, images }
local images = {}        -- name -> { state, size, count, chunks, waiters }
local encodeQueue = {}   -- names waiting to be read from disk
local encoding = nil     -- { name, stream, size, done, chunks }
local sendQueue = {}     -- { username, name, idx }
local lastPoll = 0

local function log(msg) print("[DelNews] " .. msg) end

local function readLines(path)
	local reader = getFileReader(path, false)
	if not reader then return nil end
	local lines = {}
	local line = reader:readLine()
	while line ~= nil do
		lines[#lines + 1] = line
		line = reader:readLine()
	end
	reader:close()
	-- Notepad saves UTF-8 with a BOM; it would stick to the first tab title.
	-- Kahlua strings are java Strings, so the BOM is one char U+FEFF, not 3 bytes.
	if lines[1] and string.byte(lines[1], 1) == 65279 then lines[1] = string.sub(lines[1], 2) end
	return lines
end

local function writeLines(path, lines)
	local w = getFileWriter(path, true, false)
	if not w then return end
	for i = 1, #lines do w:write(lines[i] .. "\r\n") end
	w:close()
end

local function getPlayerByName(username)
	local players = getOnlinePlayers()
	if not players then return nil end
	for i = 0, players:size() - 1 do
		local p = players:get(i)
		if p and p:getUsername() == username then return p end
	end
	return nil
end

local function readState()
	local data = ModData.getOrCreate("DelNews")
	data.read = data.read or {}
	return data
end

---- config -------------------------------------------------------------------

local function loadConfig()
	local lines = readLines(DIR .. "config.ini")
	if not lines then
		writeLines(DIR .. "config.ini", {
			"# showOnLogin: new = open on login only if the news changed since the player last read them",
			"#              always = open on every login, never = only the button blinks",
			"showOnLogin=new",
			"# how often the news files are re-read, in real seconds",
			"pollSeconds=10",
			"# picture upload speed: chunks of ~16 KB sent per server tick",
			"imageChunksPerTick=2",
		})
		log("created " .. DIR .. "config.ini")
		return
	end
	for _, line in ipairs(lines) do
		local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
		if k == "showOnLogin" and (v == "new" or v == "always" or v == "never") then
			config.showOnLogin = v
		elseif k == "pollSeconds" and tonumber(v) then
			config.pollSeconds = math.max(2, tonumber(v))
		elseif k == "imageChunksPerTick" and tonumber(v) then
			config.imageChunksPerTick = math.max(1, math.min(20, math.floor(tonumber(v))))
		end
	end
	log(string.format("config: showOnLogin=%s pollSeconds=%d imageChunksPerTick=%d",
		config.showOnLogin, config.pollSeconds, config.imageChunksPerTick))
end

local function createDefaultDoc()
	writeLines(DIR .. "news.txt", {
		"Новости",
		"<H1> Добро пожаловать!",
		"<SIZE:medium> Этот текст лежит на сервере в Zomboid/Lua/DelNews/news.txt.",
		"Правьте файл прямо во время игры: через несколько секунд у игроков замигает кнопка новостей.",
		"<CENTRE> <IMG:example.png>",
		"<LEFT> Картинки кладутся рядом, в Zomboid/Lua/DelNews/, и вставляются тегом IMG.",
		"<PAGE>",
		"Правила",
		"<SIZE:large> <HEX:ffcc33> Вторая вкладка",
		"<SIZE:medium> <RGB:1,1,1> Вкладки разделяются строкой <PAGE>, следующая строка — заголовок вкладки.",
	})
	log("created " .. DIR .. "news.txt")
end

---- images -------------------------------------------------------------------

local function probeSize(name)
	local stream = getFileInput(DIR .. name)
	if not stream then return nil end
	local size = stream:available()
	stream:close()
	return size
end

local function sendImageInfo(username, name)
	local player = getPlayerByName(username)
	if not player then return end
	local img = images[name]
	if not img or img.state == "missing" then
		sendServerCommand(player, MOD, "imgInfo", { name = name, missing = true })
	else
		sendServerCommand(player, MOD, "imgInfo", {
			name = name, key = DelNews.imageKey(name, img.size), count = img.count,
		})
	end
end

local function queueEncode(name)
	local img = images[name]
	if not img then
		img = { waiters = {} }
		images[name] = img
	end
	if img.state == "queued" or img.state == "encoding" then return end
	img.state = "queued"
	encodeQueue[#encodeQueue + 1] = name
end

-- Called on every poll: picks up pictures uploaded or replaced while running.
local function checkImages(names)
	for name, _ in pairs(names) do
		local img = images[name]
		if not img then
			queueEncode(name)
		elseif img.state == "ready" or img.state == "missing" then
			local size = probeSize(name)
			if size ~= img.size then queueEncode(name) end
		end
	end
end

-- One chunk per tick: a 0.6 MB picture is ~50 ticks of work, no server stall.
local function stepEncoding()
	if not encoding then
		local name = table.remove(encodeQueue, 1)
		if not name then return end
		local img = images[name]
		local stream = getFileInput(DIR .. name)
		if not stream then
			img.state = "missing"
			img.size = nil
			log("picture not found: " .. DIR .. name)
			for user, _ in pairs(img.waiters) do sendImageInfo(user, name) end
			img.waiters = {}
			return
		end
		img.state = "encoding"
		encoding = { name = name, stream = stream, size = stream:available(), done = 0, chunks = {} }
		return
	end

	local e = encoding
	local n = math.min(DelNews.CHUNK_BYTES, e.size - e.done)
	if n > 0 then
		e.chunks[#e.chunks + 1] = DelNews.encodeFromStream(e.stream, n)
		e.done = e.done + n
	end
	if e.done >= e.size then
		e.stream:close()
		local img = images[e.name]
		img.state = "ready"
		img.size = e.size
		img.chunks = e.chunks
		img.count = #e.chunks
		encoding = nil
		-- Drop transfers of the previous version of this picture.
		for i = #sendQueue, 1, -1 do
			if sendQueue[i].name == e.name then table.remove(sendQueue, i) end
		end
		log(string.format("picture ready: %s (%d bytes, %d chunks)", e.name, img.size, img.count))
		for user, _ in pairs(img.waiters) do sendImageInfo(user, e.name) end
		img.waiters = {}
		-- A picture uploaded or replaced while the news text stayed the same:
		-- clients that showed "not found" / the old version re-ask on "changed".
		sendServerCommand(MOD, "changed", { docs = {} })
	end
end

local function stepSending()
	local budget = config.imageChunksPerTick
	while budget > 0 and #sendQueue > 0 do
		local job = sendQueue[1]
		local img = images[job.name]
		local player = getPlayerByName(job.username)
		if not player or not img or img.state ~= "ready" or job.idx > img.count then
			table.remove(sendQueue, 1)
		else
			sendServerCommand(player, MOD, "imgPart", {
				name = job.name, key = DelNews.imageKey(job.name, img.size),
				idx = job.idx, count = img.count, data = img.chunks[job.idx],
			})
			job.idx = job.idx + 1
			budget = budget - 1
			-- Round-robin, so one player's big download does not block everyone.
			table.remove(sendQueue, 1)
			if job.idx <= img.count then sendQueue[#sendQueue + 1] = job end
		end
	end
end

---- documents ----------------------------------------------------------------

local function docPath(docId)
	if docId == "default" then return DIR .. "news.txt" end
	return DIR .. "news_" .. docId .. ".txt"
end

local function collectImages(lines, into)
	for _, line in ipairs(lines) do
		for name in string.gmatch(line, "<IMG:%s*([^>,%s]+)") do
			if DelNews.isValidImageName(name) then into[name] = true end
		end
	end
end

local function languageIds()
	local ids = { "default" }
	local langs = Translator.getAvailableLanguage()
	for i = 0, langs:size() - 1 do
		ids[#ids + 1] = langs:get(i):name()
	end
	return ids
end

-- Returns docIds whose content changed since the last poll.
local function pollDocs()
	local changed = {}
	local referenced = {}
	for _, docId in ipairs(languageIds()) do
		local lines = readLines(docPath(docId))
		if lines then
			local content = table.concat(lines, "\n")
			local doc = docs[docId]
			if not doc or doc.content ~= content then
				local imgs = {}
				collectImages(lines, imgs)
				docs[docId] = { content = content, hash = DelNews.hash(content), lines = lines, images = imgs }
				if doc then changed[#changed + 1] = docId end
			end
			for name, _ in pairs(docs[docId].images) do referenced[name] = true end
		elseif docs[docId] then
			docs[docId] = nil
			changed[#changed + 1] = docId
		end
	end
	-- Also everything clients asked for: SSR-style <IMAGECENTRE:media/ui/x.png>
	-- falls back to x.png here, and only the client knows when it needs that.
	for name, _ in pairs(images) do referenced[name] = true end
	checkImages(referenced)
	return changed
end

local function pickDoc(lang)
	if lang and docs[lang] then return lang, docs[lang] end
	return "default", docs["default"]
end

local function sendDoc(player, lang, isLogin)
	local docId, doc = pickDoc(lang)
	if not doc then
		sendServerCommand(player, MOD, "doc", { empty = true, part = 1, parts = 1 })
		return
	end
	local readHash = readState().read[player:getUsername()]
	local unread = readHash ~= doc.hash
	local autoOpen = isLogin and (config.showOnLogin == "always" or (config.showOnLogin == "new" and unread))

	-- Split by size: one packet string must stay under 32767 bytes.
	local parts, cur, curLen = {}, {}, 0
	for _, line in ipairs(doc.lines) do
		if curLen > 0 and curLen + #line > DelNews.TEXT_PART_CHARS then
			parts[#parts + 1] = cur
			cur, curLen = {}, 0
		end
		cur[#cur + 1] = line
		curLen = curLen + #line
	end
	parts[#parts + 1] = cur

	for i = 1, #parts do
		sendServerCommand(player, MOD, "doc", {
			hash = doc.hash, docId = docId, part = i, parts = #parts, lines = parts[i],
			unread = unread, autoOpen = autoOpen,
		})
	end
end

---- events -------------------------------------------------------------------

local function onClientCommand(module, command, player, args)
	if module ~= MOD then return end
	args = args or {}
	if command == "hello" then
		sendDoc(player, args.lang, args.login == true)
	elseif command == "read" then
		if type(args.hash) == "string" then
			readState().read[player:getUsername()] = args.hash
		end
	elseif command == "img" then
		local name = args.name
		if not DelNews.isValidImageName(name) then return end
		local img = images[name]
		if img and (img.state == "ready" or img.state == "missing") then
			sendImageInfo(player:getUsername(), name)
		else
			queueEncode(name)
			images[name].waiters[player:getUsername()] = true
		end
	elseif command == "imgGet" then
		local name = args.name
		local img = images[name]
		if not img or img.state ~= "ready" then return end
		local username = player:getUsername()
		for _, job in ipairs(sendQueue) do
			if job.username == username and job.name == name then return end
		end
		sendQueue[#sendQueue + 1] = { username = username, name = name, idx = 1 }
	end
end

local function onTick()
	local now = getTimestampMs()
	if now - lastPoll >= config.pollSeconds * 1000 then
		lastPoll = now
		local changed = pollDocs()
		if #changed > 0 then
			log("news changed: " .. table.concat(changed, ", "))
			sendServerCommand(MOD, "changed", { docs = changed })
		end
	end
	stepEncoding()
	stepSending()
end

local function onServerStarted()
	loadConfig()
	if not readLines(DIR .. "news.txt") then createDefaultDoc() end
	pollDocs()
	lastPoll = getTimestampMs()
	local ids = {}
	for id, _ in pairs(docs) do ids[#ids + 1] = id end
	log("documents: " .. table.concat(ids, ", "))
	Events.OnTick.Add(onTick)
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnServerStarted.Add(onServerStarted)
