--[[
	Mouselook Binder - ElvUI keybind mode integration

	While ElvUI's keybind mode is open, LEFT ALT-click any action button to send it to
	Mouselook Binder:

		LEFT ALT + left click   -> left click while mouselooking
		LEFT ALT + right click  -> right click while mouselooking
		same combo again        -> clears that side

	LEFT alt specifically: on many layouts right alt is AltGr and reports as
	Ctrl+Alt, which the modifier check below deliberately rejects.

	ElvUI already does the hard part. AB:BindUpdate() stores a ready-made binding
	command on the hovered button as button.bindstring -- "ACTIONBUTTON3" for a
	Blizzard slot, "CLICK ElvUI_Bar1Button1:LeftButton" for a LibActionButton one
	-- which is exactly what SetMouselookOverrideBinding() wants. So this just
	routes that string into MouselookBinderDB and lets MouselookBinder apply it.

	Nothing in ElvUI or MouselookBinder is edited. This addon only reads ElvUI's
	globals, wraps a script on its ElvUI_KeyBinder frame, and hooksecurefuncs
	four of its module methods.
--]]

if not ElvUI then return end

local E = unpack(ElvUI)
local AB = E:GetModule("ActionBars", true)
if not AB then return end

local _G, pairs, ipairs = _G, pairs, ipairs
local IsAltKeyDown, IsControlKeyDown, IsShiftKeyDown = IsAltKeyDown, IsControlKeyDown, IsShiftKeyDown
local InCombatLockdown, CreateFrame = InCombatLockdown, CreateFrame
local hooksecurefunc = hooksecurefunc

local KIND = "elvui"
local SIDES = { "left", "right" }
local SIDE_LABEL = { left = "left click", right = "right click" }
local SIDE_TAG = { left = "ML-L", right = "ML-R" }

local label
local snapshot

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff82c5ffMouselook Binder:|r " .. msg)
end

-- MouselookBinder builds its DB and frames at PLAYER_LOGIN, so check at use time
local function Ready()
	return MouselookBinderDB and MouselookBinderCore and MouselookBinderCore.Apply
end

-- "binding" is accepted too, so assignments made before this kind existed still
-- round-trip correctly
local function IsAssigned(cfg, command)
	return (cfg.kind == KIND or cfg.kind == "binding") and cfg.binding == command
end

local function BindModeUsable()
	return E.private and E.private.actionbar and E.private.actionbar.enable == true
		and AB.Initialized and true or false
end

local function ApplyAndRefresh()
	MouselookBinderCore:Apply()

	local f = _G.MouselookBinderFrame
	if f and f.Refresh and f:IsShown() then
		f:Refresh()
	end
end

--------------------------------------------------------------------------------
-- What command does the hovered button want?
-- Mirrors AB:BindListener (Bind.lua:98-102) so both paths agree.
--------------------------------------------------------------------------------

local function CommandForHovered()
	local bind = _G.ElvUI_KeyBinder
	local button = bind and bind.button
	if not button then return end

	local spellmacro = bind.spellmacro
	if spellmacro and spellmacro ~= "PET" and spellmacro ~= "SHAPESHIFT" then
		if not button.name then return end
		return spellmacro .. " " .. button.name, button.name
	end

	-- Deliberately NOT button.bindstring for action buttons.
	--
	-- BindUpdate prefers button.keyBoundTarget (Bind.lua:188), which is a
	-- Blizzard command like "ACTIONBUTTON10". Keys bound to that only follow
	-- ElvUI's paging because AB:ReassignBindings rewrites them into
	-- SetOverrideBindingClick on ElvUI's own frame (ActionBars.lua:396). A
	-- mouselook override never goes through that rewrite, so "ACTIONBUTTON10"
	-- would fire Blizzard's slot 10 on the global page and ignore paging.
	--
	-- Clicking the frame directly is page aware, because the frame resolves its
	-- own state.
	if not spellmacro and button.GetName and button:GetName() then
		local name = button:GetName()
		return "CLICK " .. name .. ":LeftButton", button.name or name
	end

	return button.bindstring, button.name
end

--------------------------------------------------------------------------------
-- The overlay tag, so you can see what is already assigned
--------------------------------------------------------------------------------

local function UpdateLabel()
	local bind = _G.ElvUI_KeyBinder
	if not bind then return end

	if not label then
		label = bind:CreateFontString(nil, "OVERLAY")
		label:SetPoint("TOP", bind, "TOP", 0, -2)
		if label.FontTemplate then
			label:FontTemplate(nil, 10, "OUTLINE")
		else
			label:SetFontObject("NumberFontNormalSmall")
		end
		label:SetTextColor(1, 0.82, 0)
	end

	local command = Ready() and bind.active and CommandForHovered()
	if not command then
		label:SetText("")
		return
	end

	local tags
	for _, side in ipairs(SIDES) do
		if IsAssigned(MouselookBinderDB[side], command) then
			tags = tags and (tags .. " " .. SIDE_TAG[side]) or SIDE_TAG[side]
		end
	end

	label:SetText(tags or "")
end

--------------------------------------------------------------------------------
-- Assigning
--------------------------------------------------------------------------------

local function Assign(side)
	if not Ready() then
		Print("Mouselook Binder is not ready yet.")
		return
	end

	local command, name = CommandForHovered()
	if not command then
		Print("Nothing to bind on that button.")
		return
	end

	local cfg = MouselookBinderDB[side]
	if IsAssigned(cfg, command) then
		cfg.kind, cfg.binding = "none", ""
		Print(("%s cleared."):format(SIDE_LABEL[side]))
	else
		cfg.kind, cfg.binding = KIND, command
		Print(("%s while mouselooking |cff00ff00bound to|r %s."):format(SIDE_LABEL[side], name or command))
	end

	ApplyAndRefresh()
	UpdateLabel()
end

-- returns true when we have consumed the click
local function Intercept(mouseButton)
	local bind = _G.ElvUI_KeyBinder
	if not bind or not bind.active then return end

	-- LEFT ALT only: plain RightButton still clears ElvUI's bindings, plain
	-- LeftButton is still ignored by ElvUI, CTRL/SHIFT combos stay ElvUI's
	if not IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown() then return end

	if mouseButton == "LeftButton" then
		Assign("left")
		return true
	elseif mouseButton == "RightButton" then
		Assign("right")
		return true
	end
end

--------------------------------------------------------------------------------
-- The "ElvUI keybind mode" entry in Mouselook Binder's kind dropdown.
--
-- Registered here rather than in the base addon, so Mouselook Binder keeps
-- working on its own with no knowledge of ElvUI. The entry hides itself when
-- ElvUI's ActionBars module is not running, and it stores into the same
-- cfg.binding field the plain "Binding command" kind uses.
--------------------------------------------------------------------------------

if MouselookBinderCore and MouselookBinderCore.RegisterKind then
	local Skins = E:GetModule("Skins", true)

	MouselookBinderCore:RegisterKind(KIND, {
		label = "ElvUI keybind mode",
		field = "binding",
		available = BindModeUsable,

		build = function(parent, side, y)
			local container = CreateFrame("Frame", nil, parent)
			container:SetPoint("TOPLEFT", 0, y - 23)
			container:SetPoint("TOPRIGHT", 0, y - 23)
			container:SetHeight(70)

			local enter = CreateFrame("Button", "MouselookBinderElvUIEnter" .. side, container, "UIPanelButtonTemplate")
			enter:SetPoint("TOPLEFT", 200, 0)
			enter:SetWidth(170)
			enter:SetHeight(22)
			enter:SetText("Enter Keybind Mode")
			if Skins then Skins:HandleButton(enter) end

			enter:SetScript("OnClick", function()
				if InCombatLockdown() then
					Print("not while in combat.")
					return
				end

				-- the config window would cover the bars you need to hover
				local f = _G.MouselookBinderFrame
				if f then f:Hide() end

				AB:ActivateBindMode()
			end)

			local hint = container:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
			hint:SetPoint("TOPLEFT", 22, -26)
			hint:SetPoint("TOPRIGHT", -22, -26)
			hint:SetJustifyH("LEFT")
			hint:SetText(("Hover over the button you want to bind, hold LEFT ALT and %s click the button."):format(side))
			if hint.FontTemplate then hint:FontTemplate(nil, 11) end

			local current = container:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			current:SetPoint("TOPLEFT", 22, -54)
			current:SetPoint("TOPRIGHT", -22, -54)
			current:SetJustifyH("LEFT")
			if current.FontTemplate then current:FontTemplate(nil, 11) end
			container.current = current

			return container
		end,

		refresh = function(widget, cfg)
			if cfg.binding and cfg.binding ~= "" then
				widget.current:SetText("Bound to: |cffffffff" .. cfg.binding .. "|r")
			else
				widget.current:SetText("|cff999999Nothing bound yet.|r")
			end
		end,
	})
end

--------------------------------------------------------------------------------
-- Hooks
--------------------------------------------------------------------------------

-- AB:LoadKeyBinder() installs the scripts we need to wrap, and only runs if the
-- ActionBars module is enabled, so wrap from inside a hook on it
local function InstallWrapper()
	local bind = _G.ElvUI_KeyBinder
	if not bind or bind.mlbWrapped then return end
	bind.mlbWrapped = true

	local original = bind:GetScript("OnMouseUp")
	bind:SetScript("OnMouseUp", function(self, mouseButton)
		if Intercept(mouseButton) then return end
		if original then original(self, mouseButton) end
	end)
end

hooksecurefunc(AB, "LoadKeyBinder", InstallWrapper)

hooksecurefunc(AB, "BindUpdate", function()
	UpdateLabel()
end)

hooksecurefunc(AB, "BindHide", function()
	if label then label:SetText("") end
end)

-- ElvUI's Save/Discard only covers real keybindings. Snapshot our two sides so
-- Discard (and being pulled into combat) undoes mouselook changes too.
hooksecurefunc(AB, "ActivateBindMode", function()
	-- also wrap here, in case this addon somehow loaded after AB:Initialize()
	InstallWrapper()

	-- ElvUI bails out of bind mode in combat without setting this
	local bind = _G.ElvUI_KeyBinder
	if not bind or not bind.active then return end
	if not Ready() then return end

	snapshot = {}
	for _, side in ipairs(SIDES) do
		local cfg = MouselookBinderDB[side]
		snapshot[side] = { kind = cfg.kind, binding = cfg.binding }
	end

	Print("LEFT ALT-click an action button to set the mouselook left/right click.")
end)

hooksecurefunc(AB, "DeactivateBindMode", function(_, save)
	if not save and snapshot and Ready() then
		local changed
		for _, side in ipairs(SIDES) do
			local cfg, old = MouselookBinderDB[side], snapshot[side]
			if cfg.kind ~= old.kind or cfg.binding ~= old.binding then
				cfg.kind, cfg.binding = old.kind, old.binding
				changed = true
			end
		end

		if changed then
			ApplyAndRefresh()
			Print("mouselook changes discarded.")
		end
	end

	snapshot = nil
	if label then label:SetText("") end
end)
