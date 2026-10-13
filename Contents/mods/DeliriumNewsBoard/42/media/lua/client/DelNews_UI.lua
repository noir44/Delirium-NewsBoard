-- Delirium-News: news button and window.
if isServer() then return end
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"
require "DelNews_Client"

DelNewsUI = {}
local UI = DelNewsUI

---- rich text with pictures --------------------------------------------------

DelNewsRichText = ISRichTextPanel:derive("DelNewsRichText")

-- Textures found in mod files, by the path written in the news file.
local modTextures = {}

-- <DNIMG:ref[,w,h]> is what buildText turns every picture tag into once the
-- texture is known; ref is a server picture name or a mod file path. Same
-- placement as vanilla IMAGECENTRE, but the texture comes from our tables (no
-- file path for getTexture inside the tag, and never a nil texture: vanilla
-- IMAGE/IMAGECENTRE call nil:getWidth() on a missing file and the whole tab
-- fails to paginate) and it is scaled down to fit the panel width.
function DelNewsRichText:processCommand(command, x, y, lineImageHeight, lineHeight)
	if string.sub(command, 1, 6) ~= "DNIMG:" then
		return ISRichTextPanel.processCommand(self, command, x, y, lineImageHeight, lineHeight)
	end
	local spec = string.sub(command, 7)
	local ref, sw, sh = string.match(spec, "^([^,]+),%s*(%d+),%s*(%d+)$")
	if not ref then ref = spec end
	local img = DelNewsClient.images[ref]
	local tex = modTextures[ref] or (img and img.tex)
	if not tex then return x, y, lineImageHeight end

	local maxW = self.width - self.marginLeft - self.marginRight - 20
	local w, h = tonumber(sw) or tex:getWidth(), tonumber(sh) or tex:getHeight()
	if w > maxW then
		h = math.floor(h * maxW / w)
		w = maxW
	end
	if x + w >= self.width - (self.marginLeft + self.marginRight) then
		x = 0
		y = y + lineHeight
	end
	if lineImageHeight < (h / 2) + 8 then
		lineImageHeight = (h / 2) + 16
	end
	local mx = (self.width - self.marginLeft - self.marginRight) / 2
	self.images[self.imageCount] = tex
	self.imageX[self.imageCount] = mx - (w / 2)
	self.imageY[self.imageCount] = y
	self.imageW[self.imageCount] = w
	self.imageH[self.imageCount] = h
	self.imageCount = self.imageCount + 1
	x = x + w + 7
	for c, _ in ipairs(self.lines) do
		if self.lineY[c] == y then self.lineY[c] = self.lineY[c] + (h / 2) end
	end
	y = y + (h / 2)
	return x, y, lineImageHeight
end

local function hexToRgb(r, g, b)
	return string.format("<RGB:%.3f,%.3f,%.3f>", tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255)
end

local function sizeSuffix(w, h)
	if w and h then return "," .. w .. "," .. h end
	return ""
end

local function placeholder(key, name)
	return " <PUSHRGB:0.6,0.6,0.6> " .. getText(key, name) .. " <POPRGB> "
end

local function serverImageTag(name, w, h)
	local img = DelNewsClient.images[name]
	if img and img.state == "ready" and img.tex then
		return " <DNIMG:" .. name .. sizeSuffix(w, h) .. "> "
	end
	local key = "IGUI_DelNews_ImageLoading"
	if not DelNews.isValidImageName(name) or (img and img.state == "missing") then key = "IGUI_DelNews_ImageMissing"
	elseif img and img.state == "failed" then key = "IGUI_DelNews_ImageFailed" end
	return placeholder(key, name)
end

-- <IMG:name.png[,w,h]>: picture from the server folder.
local function imgTag(spec)
	local name, w, h = DelNewsClient.parseImageSpec(spec)
	return serverImageTag(name, w, h)
end

-- Vanilla <IMAGE:path> / <IMAGECENTRE:path[,w,h]> (what SSR Newsboard files
-- use): a picture inside a mod if one has it, otherwise the picture with the
-- same file name from the server folder.
local function modImageTag(spec)
	local path, w, h = DelNewsClient.parseImageSpec(spec)
	local tex = DelNewsClient.modTexture(path)
	if tex then
		modTextures[path] = tex
		return " <DNIMG:" .. path .. sizeSuffix(w, h) .. "> "
	end
	return serverImageTag(DelNewsClient.baseName(path), w, h)
end

-- Tags understood on top of vanilla rich text (kept from SSR Newsboard files):
-- <IMG:file.png>, <HEX:rrggbb>, <LINK:text> (shown highlighted, not clickable),
-- and a safe version of vanilla <IMAGE:>/<IMAGECENTRE:>.
local function buildText(lines)
	local out = {}
	for _, line in ipairs(lines) do
		line = string.gsub(line, "<HEX:(%x%x)(%x%x)(%x%x)>", hexToRgb)
		line = string.gsub(line, "<LINK:([^>]+)>", " <PUSHRGB:0.31,0.69,0.96> %1 <POPRGB> ")
		line = string.gsub(line, "<IMG:([^>]+)>", imgTag)
		line = string.gsub(line, "<IMAGECENTRE:([^>]+)>", modImageTag)
		line = string.gsub(line, "<IMAGE:([^>]+)>", modImageTag)
		out[#out + 1] = line
	end
	return table.concat(out, " <LINE> ")
end

---- window -------------------------------------------------------------------

DelNewsPanel = ISPanel:derive("DelNewsPanel")

local function fontHgt(font) return getTextManager():getFontHeight(font) end

function DelNewsPanel:createChildren()
	local btnH = fontHgt(UIFont.Small) + 8
	self.text = DelNewsRichText:new(10, 10, self.width - 20, self.height - 20)
	self.text:initialise()
	self.text.background = true
	self.text.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
	self.text.autosetheight = false
	self.text.clip = true
	self.text.marginRight = self.text.marginLeft
	self:addChild(self.text)
	self.text:addScrollBars()

	self.closeButton = ISButton:new(0, 0, 100, btnH, getText("IGUI_DelNews_Close"), self, DelNewsPanel.onClose)
	self.closeButton:initialise()
	self:addChild(self.closeButton)

	self.tabButtons = {}
	self:layout()
end

function DelNewsPanel:onClose()
	self:setVisible(false)
end

function DelNewsPanel:rebuildTabs()
	for _, b in ipairs(self.tabButtons) do self:removeChild(b) end
	self.tabButtons = {}
	local tabs = DelNewsClient.doc and DelNewsClient.doc.tabs or {}
	for i, tab in ipairs(tabs) do
		local title = tab.title
		if not title or string.match(title, "^%s*$") then title = tostring(i) end
		local w = getTextManager():MeasureStringX(UIFont.Small, title) + 20
		local b = ISButton:new(0, 0, math.max(60, w), fontHgt(UIFont.Small) + 8, title, self, DelNewsPanel.onTab)
		b.internal = i
		b:initialise()
		self:addChild(b)
		self.tabButtons[i] = b
	end
	if not self.selected or self.selected > #tabs then self.selected = 1 end
	self:layout()
end

-- Tab buttons wrap into as many rows as needed.
function DelNewsPanel:layout()
	local pad = 10
	local x, y = pad, pad
	local rowH = fontHgt(UIFont.Small) + 8
	for _, b in ipairs(self.tabButtons) do
		if x > pad and x + b.width > self.width - pad then
			x = pad
			y = y + rowH + 4
		end
		b:setX(x); b:setY(y)
		x = x + b.width + 4
	end
	local top = (#self.tabButtons > 0) and (y + rowH + 6) or pad
	self.closeButton:setX(self.width - self.closeButton.width - pad)
	self.closeButton:setY(self.height - self.closeButton.height - pad)
	self.text:setX(pad)
	self.text:setY(top)
	self.text:setWidth(self.width - pad * 2)
	self.text:setHeight(self.closeButton.y - top - pad)
	if self.text.vscroll then
		self.text.vscroll:setX(self.text.width - self.text.vscroll.width)
		self.text.vscroll:setHeight(self.text.height)
	end
	self:highlightTab()
end

function DelNewsPanel:highlightTab()
	for i, b in ipairs(self.tabButtons) do
		if i == self.selected then
			b.backgroundColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
		else
			b.backgroundColor = { r = 0, g = 0, b = 0, a = 1 }
		end
	end
end

function DelNewsPanel:onTab(button)
	self.selected = button.internal
	self:showTab(true)
end

function DelNewsPanel:showTab(resetScroll)
	local doc = DelNewsClient.doc
	local tab = doc and doc.tabs and doc.tabs[self.selected]
	local text
	if not tab then
		text = getText("IGUI_DelNews_Empty")
	else
		text = buildText(tab.lines)
	end
	local scroll = self.text:getYScroll()
	self.text:setText(text)
	-- Bad markup must not take the whole window down: show a note instead.
	-- (pcall still prints the stack trace to the log, which is what we want here.)
	if not pcall(function() self.text:paginate() end) then
		self.text:setText(getText("IGUI_DelNews_BadMarkup"))
		self.text:paginate()
	end
	if resetScroll then
		self.text:setYScroll(0)
	else
		self.text:setYScroll(scroll)
	end
	self:highlightTab()
end

function DelNewsPanel:resizeToScreen()
	local sh, sw = getCore():getScreenHeight(), getCore():getScreenWidth()
	local h = math.floor(sh * 0.8)
	local w = math.min(math.floor(h * 1.2), sw - 40)
	self:setWidth(w)
	self:setHeight(h)
	self:setX((sw - w) / 2)
	self:setY((sh - h) / 2)
	self:layout()
end

function DelNewsPanel:new()
	local o = ISPanel:new(0, 0, 600, 500)
	setmetatable(o, self)
	self.__index = self
	o.backgroundColor = { r = 0.12, g = 0.12, b = 0.12, a = 0.95 }
	o.borderColor = { r = 1, g = 1, b = 1, a = 0.3 }
	o.moveWithMouse = true
	o.selected = 1
	return o
end

---- button -------------------------------------------------------------------

DelNewsButton = ISButton:derive("DelNewsButton")

function DelNewsButton:prerender()
	local doc = DelNewsClient.doc
	if doc and doc.unread and math.floor(getTimestampMs() / 500) % 2 == 0 then
		self.backgroundColor = { r = 0.75, g = 0.45, b = 0.05, a = 0.9 }
	else
		self.backgroundColor = { r = 0, g = 0, b = 0, a = 0.6 }
	end
	ISButton.prerender(self)
end

local function placeButton()
	if not UI.button then return end
	UI.button:setX(getCore():getScreenWidth() - UI.button.width - 120)
	UI.button:setY(getCore():getScreenHeight() - UI.button.height - 70)
end

local function ensureUI()
	if not UI.panel then
		UI.panel = DelNewsPanel:new()
		UI.panel:initialise()
		UI.panel:addToUIManager()
		UI.panel:setVisible(false)
		UI.panel:resizeToScreen()
	end
	if not UI.button then
		local title = getText("IGUI_DelNews_Button")
		local w = getTextManager():MeasureStringX(UIFont.Small, title) + 24
		UI.button = DelNewsButton:new(0, 0, w, fontHgt(UIFont.Small) + 10, title, nil, function() UI.toggle() end)
		UI.button:initialise()
		UI.button:addToUIManager()
		UI.button:setVisible(true)
		placeButton()
	end
end

function UI.open()
	ensureUI()
	UI.panel:resizeToScreen()
	UI.panel:setVisible(true)
	UI.panel:bringToTop()
	DelNewsClient.markRead()
	UI.panel:showTab(true)
end

function UI.toggle()
	ensureUI()
	if UI.panel:getIsVisible() then
		UI.panel:setVisible(false)
	else
		UI.open()
	end
end

---- hooks called by DelNews_Client -------------------------------------------

function UI.onDocChanged(autoOpen)
	ensureUI()
	UI.panel:rebuildTabs()
	if UI.panel:getIsVisible() then
		UI.panel:showTab(false)
		DelNewsClient.markRead()
	elseif autoOpen then
		UI.open()
	end
end

function UI.onImageChanged(name)
	if UI.panel and UI.panel:getIsVisible() then UI.panel:showTab(false) end
end

Events.OnResolutionChange.Add(function()
	placeButton()
	if UI.panel then UI.panel:resizeToScreen() end
end)
