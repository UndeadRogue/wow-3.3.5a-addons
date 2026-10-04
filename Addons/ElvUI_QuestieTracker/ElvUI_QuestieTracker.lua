--[[
	ElvUI_QuestieTracker

	Gives the Questie Tracker -- the on-screen quest log -- ElvUI's buttons, icons
	and fonts. Nothing in Questie or ElvUI is edited; this only wraps setters on
	widgets Questie has already built.

	Why wrappers rather than a one-shot restyle: every widget touched here gets
	re-set by Questie on a later update, so a single pass at login would be undone
	the first time you accept a quest.

		* TrackerLinePool.SetMode re-SetFont()s a line's label whenever the line
		  changes role (zone header / quest title / objective), pulling the face
		  back out of LibSharedMedia.
		* TrackerHeaderFrame:Update re-SetFont()s the header label on every update.
		* btn.SetItem re-applies SetNormalTexture / SetPushedTexture /
		  SetHighlightTexture / SetFont on a quest item button every time the
		  button is handed out of the pool.
		* expandQuest.SetMode swaps between the Blizzard plus and minus textures.

	So the fonts and the plus/minus/checkmark/play icons get their setter replaced
	with one that substitutes ElvUI's value, and the quest item buttons get
	hooksecurefunc plus E.noop on the two texture setters ElvUI owns. All of it is
	idempotent and flagged, so running the pass twice is harmless.

	Both pools are fixed-size and fully built by TrackerLinePool.Initialize, and
	every frame in them is globally named ("linePool1", "Questie_ItemButton1", ...),
	so walking _G until the names run out covers the lot -- no frame is created
	after init and there is nothing to catch later.

	Deliberately left alone:

		* The base frame backdrop. Questie has its own backdrop/border/fader
		  settings (off by default) and TrackerFadeTicker drives the backdrop
		  colour and alpha directly every tick, which would fight an ElvUI
		  template. Styling it means replacing that fader, not skinning a frame.
		* The Questie logo in the tracker header. That is a brand mark, not a UI
		  icon, so it keeps its own look.
--]]

if not ElvUI or not QuestieLoader then return end

local E = unpack(ElvUI)
local S = E:GetModule("Skins", true)
local LSM = E.LSM

local QuestieTracker = QuestieLoader:ImportModule("QuestieTracker")
local TrackerHeaderFrame = QuestieLoader:ImportModule("TrackerHeaderFrame")

-- QuestieLoader:ImportModule() creates an empty table for a name it has not seen,
-- so check the function is really there before hooking it
if type(QuestieTracker.Initialize) ~= "function" then return end

local _G, type, select, unpack = _G, type, select, unpack
local strfind = string.find
local hooksecurefunc = hooksecurefunc

--------------------------------------------------------------------------------
-- Fonts
--
-- Questie's three tracker font sizes (zone / title / objective) and the header
-- size have no ElvUI equivalent and the user has tuned them, so only the face and
-- the outline are taken from ElvUI. The requested size is passed straight through.
--------------------------------------------------------------------------------

-- Mirrors E's FontTemplate (Core/Toolkit.lua) including its Homespun clamp, but
-- calls the fontstring's original SetFont. FontTemplate itself can't be used:
-- it ends in fs:SetFont(), which is the very method being replaced below.
local function ApplyFont(setFont, fs, size)
	local font = LSM:Fetch("font", E.db.general.font)
	local style = E.db.general.fontStyle
	size = size or E.db.general.fontSize

	if style == "OUTLINE" and E.db.general.font == "Homespun" and size > 10 then
		size, style = 10, "MONOCHROMEOUTLINE"
	end

	setFont(fs, font, size, style)

	if style == "NONE" then
		local s = E.mult or 1
		fs:SetShadowOffset(s, -s / 2)
		fs:SetShadowColor(0, 0, 0, 1)
	else
		fs:SetShadowOffset(0, 0)
		fs:SetShadowColor(0, 0, 0, 0)
	end
end

local function HookFont(fs)
	if not fs or fs.elvQT then return end
	fs.elvQT = true

	local setFont = fs.SetFont
	fs.SetFont = function(self, _, size, _)
		ApplyFont(setFont, self, size)
	end

	-- Questie already put a font on this string during its own init, so restyle it
	-- now at whatever size it is currently carrying
	local _, size = fs:GetFont()
	fs:SetFont(nil, size, nil)
end

--------------------------------------------------------------------------------
-- Icons
--------------------------------------------------------------------------------

-- The objective-complete checkmark, matched to however ElvUI draws a tick
-- elsewhere in the UI: the Melli block tinted gold when the checkbox skin is on,
-- the plain Blizzard check when it is off (same branch as S:HandleCheckBox).
local function CheckMark()
	if E.private.skins.checkBoxSkin then
		return E.Media.Textures.Melli, 1, 0.82, 0, 0.8
	end

	return [[Interface\Buttons\UI-CheckBox-Check]], 1, 1, 1, 1
end

-- Replaces a texture object's SetTexture with one that swaps known Questie /
-- Blizzard paths for ElvUI's, then re-fires whatever is currently set so the
-- swap applies to the state Questie left behind.
--
-- The remap is by substring and the ElvUI replacements are named after what they
-- replace ("MinusButton.tga"), so a re-fired texture maps to itself -- which is
-- what makes calling this twice safe.
local function HookTexture(tex, remap)
	if not tex or tex.elvQT then return end
	tex.elvQT = true

	local setTexture = tex.SetTexture
	tex.SetTexture = function(self, path, ...)
		if type(path) == "string" then
			local replacement, r, g, b, a = remap(path)
			if replacement then
				setTexture(self, replacement)
				self:SetVertexColor(r, g, b, a)
				return
			end
		end

		setTexture(self, path, ...)
	end

	local current = tex:GetTexture()
	if current then tex:SetTexture(current) end
end

local function RemapCriteria(path)
	if strfind(path, "Checkmark", 1, true) then
		return CheckMark()
	end
end

local function RemapCollapse(path)
	if strfind(path, "MinusButton", 1, true) then
		return E.Media.Textures.MinusButton, 1, 1, 1, 1
	elseif strfind(path, "PlusButton", 1, true) then
		return E.Media.Textures.PlusButton, 1, 1, 1, 1
	end
end

--------------------------------------------------------------------------------
-- The AI_VoiceOver play button
--
-- Questie flips this between its own QuestLogPlayButton and QuestLogStopButton
-- textures from three places, and the button is a plain Button that paints the
-- icon as its normal texture, so the path swap goes through SetNormalTexture.
--------------------------------------------------------------------------------

local function SkinPlayButton(btn)
	if not btn or btn.elvQT then return end
	btn.elvQT = true

	local setNormalTexture = btn.SetNormalTexture
	btn.SetNormalTexture = function(self, path, ...)
		if type(path) == "string" then
			if strfind(path, "QuestLogStopButton", 1, true) then
				path = E.Media.Textures.Pause
			elseif strfind(path, "QuestLogPlayButton", 1, true) then
				path = E.Media.Textures.Play
			end
		end

		setNormalTexture(self, path, ...)

		local tex = self:GetNormalTexture()
		if tex then tex:SetInside(self) end
	end

	-- ElvUI's flat hover/pushed overlays in place of the Blizzard
	-- minimize-button highlight Questie assigned at init
	btn:StyleButton()
	btn.SetHighlightTexture = E.noop

	local tex = btn:GetNormalTexture()
	if tex and tex:GetTexture() then
		btn:SetNormalTexture(tex:GetTexture())
	end
end

--------------------------------------------------------------------------------
-- Quest item buttons
--
-- These are SecureActionButtonTemplate buttons with no icon child -- the item
-- texture is the button's own normal texture -- so S:HandleItemButton can't be
-- used: it strips the textures it is meant to reparent and finds no icon. Same
-- result built by hand instead: dark fill, cropped icon, ElvUI hover/pushed,
-- ElvUI border, ElvUI cooldown text.
--
-- Everything that has to stack in a known order lives on the button itself, as
-- draw layers:
--
--     BACKGROUND  the dark fill
--     BORDER      the item icon (the button's normal texture)
--     ARTWORK     ElvUI's hover and pushed overlays, from StyleButton
--
-- It has to be done that way round. The obvious build -- ElvUI's backdrop frame
-- for the fill, icon and overlays on the button -- puts a child frame against
-- its parent's textures, and a child frame paints over its parent whenever the
-- two frame levels tie. Questie reparents these buttons between their tracker
-- line and UIParent on every update (it has to: a SecureActionButtonTemplate
-- can't be hidden with its parent in combat) and that resets frame levels, so
-- the relationship is not stable and cannot be pinned down from here. Whichever
-- side of the tie you land on, something vanishes: the fill over the icon, or
-- the icon over the hover overlay.
--
-- So the backdrop frame is kept only for the ElvUI border, with its own fill
-- made fully transparent -- it has nothing left to hide, whatever level it lands
-- on. ignoreUpdates keeps E:UpdateFrameTemplates from colouring it back in.
--
-- Questie sizes and positions the button itself (questItemButtonSize, and the
-- tracker's width maths depends on it), so the button's rect is the one
-- everything here anchors to.
--------------------------------------------------------------------------------

local function FindCooldown(btn)
	local children = { btn:GetChildren() }
	for i = 1, #children do
		local child = children[i]
		if child.GetObjectType and child:GetObjectType() == "Cooldown" then
			return child
		end
	end
end

local function SkinItemButton(btn)
	if not btn or btn.elvQT then return end
	btn.elvQT = true

	-- Border only -- see the note above for why the fill is not used here
	btn:CreateBackdrop("Default", nil, true)
	btn.backdrop:SetAllPoints()
	btn.backdrop:SetBackdropColor(0, 0, 0, 0)

	-- The fill the backdrop would have drawn, as the button's own bottom layer.
	-- backdropcolor carries no alpha, so don't unpack a 4th value out of it.
	local r, g, b = unpack(E.media.backdropcolor)
	btn.elvFill = btn:CreateTexture(nil, "BACKGROUND")
	btn.elvFill:SetInside(btn)
	btn.elvFill:SetTexture(r, g, b, 1)

	-- Hover and pushed overlays, on ARTWORK
	btn:StyleButton()

	-- SetItem re-applies both of these on every tracker update; ElvUI's versions
	-- are already in place from StyleButton, so drop Questie's
	btn.SetHighlightTexture = E.noop
	btn.SetPushedTexture = E.noop

	-- The icon stays the button's normal texture -- so the button keeps behaving
	-- exactly as Questie built it -- and is pinned to BORDER so it sits between
	-- the fill and the overlays no matter which texture got created first.
	-- SetItem re-sets the texture on every tracker update, hence the hook.
	local function StyleIcon()
		local tex = btn:GetNormalTexture()
		if not tex then return end

		tex:SetTexCoord(unpack(E.TexCoords))
		tex:SetInside(btn)
		tex:SetDrawLayer("BORDER")
	end

	hooksecurefunc(btn, "SetNormalTexture", StyleIcon)
	StyleIcon()

	-- Charge count: Questie re-SetFont()s it in SetItem. The range dot it only
	-- ever sets once, at creation.
	HookFont(btn.count)
	HookFont(btn.range)

	-- The Cooldown is a local inside Questie's button closure and is never stored
	-- on the button, so it has to be found among the children
	local cooldown = FindCooldown(btn)
	if cooldown then
		E:RegisterCooldown(cooldown)
	end
end

--------------------------------------------------------------------------------
-- The pass
--------------------------------------------------------------------------------

local function SkinTracker()
	if not E.private then return end -- ElvUI not initialized yet

	local headerFrame = TrackerHeaderFrame.headerFrame
	if headerFrame and headerFrame.trackedQuests then
		HookFont(headerFrame.trackedQuests.label)
	end

	local i = 1
	while _G["linePool" .. i] do
		local line = _G["linePool" .. i]

		HookFont(line.label)

		if line.criteriaMark then
			HookTexture(line.criteriaMark.texture, RemapCriteria)
		end

		if line.expandQuest then
			HookTexture(line.expandQuest.texture, RemapCollapse)
		end

		SkinPlayButton(line.playButton)

		i = i + 1
	end

	i = 1
	while _G["Questie_ItemButton" .. i] do
		SkinItemButton(_G["Questie_ItemButton" .. i])
		i = i + 1
	end

	-- Questie hides the tracker's scrollbar and its arrows at init and never shows
	-- them again itself -- but it sets scrollBarHideable on the quest frame rather
	-- than on the scroll frame (TrackerQuestFrame.lua:57 vs :44), so as far as
	-- UIPanelScrollFrameTemplate is concerned the bar is not hideable and its own
	-- range handler can bring it back. Skin it so it matches if it does.
	if S then
		local scrollBar = _G.TrackedQuestsScrollFrameScrollBar
		if scrollBar then
			S:HandleScrollBar(scrollBar)
		end
	end
end

-- The tracker's frames only exist once QuestieTracker.Initialize has run, and it
-- returns early when the tracker is disabled, so check started rather than
-- assuming the hook means there is something to skin. (QuestieTracker:Enable()
-- clears started and calls Initialize again, which this hook follows.)
hooksecurefunc(QuestieTracker, "Initialize", function()
	if not QuestieTracker.started then return end
	SkinTracker()
end)
