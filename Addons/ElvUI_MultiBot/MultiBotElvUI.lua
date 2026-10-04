--[[
	MultiBot ElvUI

	1. Starts the MultiBot bar hidden. /mb still toggles it exactly as before.
	2. Restyles MultiBot's icon buttons with ElvUI's templates.

	Nothing in the MultiBot folder is touched, so updating it will not undo any
	of this. If ElvUI is missing or disabled only the hiding half runs.
]]

local f = CreateFrame("Frame")
local E
local skinned = {}

local function GetElv()
	if not ElvUI then return end
	local ok, elv = pcall(unpack, ElvUI)
	if ok and elv and elv.media then E = elv end
end

--------------------------------------------------------------------------------
-- Button skinning
--------------------------------------------------------------------------------

-- MultiBot re-anchors the icon with SetAllPoints whenever a button's art
-- changes, which would undo the inset, so this gets re-applied after any call
-- that touches the icon.
local function FixIcon(b)
	if not b.icon then return end
	b.icon:SetTexCoord(unpack(E.TexCoords))
	b.icon:SetDrawLayer("ARTWORK")
	b.icon:SetInside(b)
end

local function Wrap(b, name, after)
	local orig = b[name]
	if type(orig) ~= "function" then return end
	b[name] = function(...)
		local result = orig(...)
		after(b)
		return result
	end
end

local function SkinButton(b)
	if skinned[b] or not b.icon or not b.GetObjectType then return end
	skinned[b] = true

	-- clear the leftovers from ActionButtonTemplate (flash, equipped border,
	-- hotkey/count backdrops) without disturbing MultiBot's own two textures
	for i = 1, b:GetNumRegions() do
		local region = select(i, b:GetRegions())
		if region and region.IsObjectType and region:IsObjectType("Texture")
			and region ~= b.icon and region ~= b.border then
			region:SetTexture(nil)
		end
	end
	b:SetNormalTexture("")

	b:SetTemplate("Default")
	FixIcon(b)

	local hl = b:SetHighlightTexture(E.media.normTex) or b:GetHighlightTexture()
	if hl then
		hl:SetVertexColor(1, 1, 1, 0.25)
		hl:SetInside(b)
	end

	local pushed = b:SetPushedTexture(E.media.normTex) or b:GetPushedTexture()
	if pushed then
		pushed:SetVertexColor(0.9, 0.8, 0.1, 0.3)
		pushed:SetInside(b)
	end

	-- MultiBot uses button.border as its enabled/selected marker. Blank the old
	-- art and mirror its Show/Hide onto an ElvUI coloured ring so the state is
	-- still readable.
	if b.border then
		b.border:SetTexture(nil)

		local glow = CreateFrame("Frame", nil, b)
		glow:SetOutside(b, E.Border, E.Border)
		glow:SetFrameLevel(b:GetFrameLevel() + 2)
		glow:SetTemplate("Default", nil, true)
		glow:SetBackdropColor(0, 0, 0, 0)
		glow:SetBackdropBorderColor(unpack(E.media.rgbvaluecolor))
		glow:Hide()
		b.elvGlow = glow

		local show, hide = b.border.Show, b.border.Hide
		b.border.Show = function(self) show(self) glow:Show() end
		b.border.Hide = function(self) hide(self) glow:Hide() end
		if b.border:IsShown() then glow:Show() end
	end

	Wrap(b, "setButton", FixIcon)
	Wrap(b, "setTexture", FixIcon)
	Wrap(b, "setHighlight", function(self)
		local tex = self:GetHighlightTexture()
		if tex then tex:SetInside(self) end
	end)
end

local function Walk(frame)
	if type(frame) ~= "table" then return end
	if type(frame.buttons) == "table" then
		for _, b in pairs(frame.buttons) do
			if type(b) == "table" then SkinButton(b) end
		end
	end
	if type(frame.frames) == "table" then
		for _, sub in pairs(frame.frames) do Walk(sub) end
	end
end

-- MultiBot.frames holds the bar; its other windows hang off MultiBot directly.
-- They are walked too, otherwise the newButton hook below would skin only the
-- buttons those windows build after login and leave the rest mismatched.
local otherRoots = {
	"inventory", "spellbook", "itemus", "iconos",
	"reward", "necronet", "raidus", "talent", "stats",
}

local function SkinEverything()
	for _, frame in pairs(MultiBot.frames) do Walk(frame) end
	for _, name in ipairs(otherRoots) do Walk(MultiBot[name]) end

	-- bot buttons are created as bots appear, so catch those too
	local newButton = MultiBot.newButton
	MultiBot.newButton = function(...)
		local b = newButton(...)
		if b then SkinButton(b) end
		return b
	end
end

--------------------------------------------------------------------------------
-- Start hidden
--------------------------------------------------------------------------------

local function HideBars()
	-- same two lines /mb runs, so the next /mb shows the bar as normal
	for _, frame in pairs(MultiBot.frames) do frame:Hide() end
	MultiBot.state = false
end

f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
	if not MultiBot or not MultiBot.frames then return end

	GetElv()
	if E then
		local ok, err = pcall(SkinEverything)
		if not ok then
			DEFAULT_CHAT_FRAME:AddMessage("|cffff5555MultiBot ElvUI:|r skinning failed - " .. tostring(err))
		end
	end

	HideBars()
end)
