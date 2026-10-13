-- Delirium-News: shared constants and helpers (base64, string hash).
-- Images travel server -> client as base64 text because a sendServerCommand
-- string is length-prefixed with a signed short: one string must stay under
-- 32767 bytes, so a picture goes out in many chunks.

DelNews = DelNews or {}

DelNews.MODULE = "DelNews"
DelNews.DIR = "DelNews/"              -- server: Zomboid/Lua/DelNews/
DelNews.CACHE_DIR = "DelNews_cache/"  -- client: Zomboid/Lua/DelNews_cache/
DelNews.CHUNK_BYTES = 12288           -- multiple of 3 -> 16384 base64 chars, no inner padding
DelNews.TEXT_PART_CHARS = 6000        -- Cyrillic is 2 bytes in UTF-8, stay far below 32767

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC = {}
local DEC = {}
for i = 1, 64 do
	ENC[i - 1] = string.sub(ALPHA, i, i)
	DEC[string.byte(ALPHA, i)] = i - 1
end

-- Reads exactly n bytes from a java DataInputStream and returns them as base64.
function DelNews.encodeFromStream(stream, n)
	local out = {}
	local read = 0
	while read < n do
		local b1 = stream:readUnsignedByte()
		local b2, b3
		read = read + 1
		if read < n then b2 = stream:readUnsignedByte(); read = read + 1 end
		if b2 and read < n then b3 = stream:readUnsignedByte(); read = read + 1 end

		local v = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
		local c1 = math.floor(v / 262144) % 64
		local c2 = math.floor(v / 4096) % 64
		local c3 = math.floor(v / 64) % 64
		local c4 = v % 64
		out[#out + 1] = ENC[c1] .. ENC[c2] .. (b2 and ENC[c3] or "=") .. (b3 and ENC[c4] or "=")
	end
	return table.concat(out)
end

-- Decodes a base64 string straight into a java DataOutputStream; returns bytes written.
function DelNews.decodeToStream(s, stream)
	local written = 0
	local len = #s
	for i = 1, len - 3, 4 do
		local a = DEC[string.byte(s, i)] or 0
		local b = DEC[string.byte(s, i + 1)] or 0
		local c3 = string.byte(s, i + 2)
		local c4 = string.byte(s, i + 3)
		local c = DEC[c3]
		local d = DEC[c4]
		local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
		stream:writeByte(math.floor(v / 65536) % 256); written = written + 1
		if c then stream:writeByte(math.floor(v / 256) % 256); written = written + 1 end
		if c and d then stream:writeByte(v % 256); written = written + 1 end
	end
	return written
end

-- Stable across restarts (unlike a counter), so "already read" survives them.
function DelNews.hash(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return tostring(h)
end

-- Only plain file names in our folder: no paths, png only.
function DelNews.isValidImageName(name)
	return type(name) == "string" and string.match(name, "^[%w%._%-]+%.[pP][nN][gG]$") ~= nil
		and not string.find(name, "..", 1, true)
end

-- Client cache file name. Includes the size, so a re-uploaded picture under the
-- same name but with different bytes is fetched again instead of served stale.
-- The prefix also keeps the texture name clear of vanilla texture packs, which
-- getTexture() searches by bare file name first.
function DelNews.imageKey(name, size)
	local base = string.gsub(string.gsub(name, "%.[pP][nN][gG]$", ""), "[^%w_]", "_")
	return "DelNews_" .. base .. "_" .. tostring(size)
end
