--[[
	Mouselook Binder
	Replaces the "mouselook" / "d" / "df1" binding macros.

	Toggle key  -> SetBinding(key, "MOUSELOOKBINDER_TOGGLE")  (see Bindings.xml)
	Left/right  -> SetMouselookOverrideBinding("BUTTON1"/"BUTTON2", action)
	              while the plain binding stays CAMERAORSELECTORMOVE / TURNORACTION
	              so the buttons still work outside of mouselook.

	Settings are per character (SavedVariablesPerCharacter).
	The window skins itself with ElvUI when ElvUI is loaded, otherwise it falls
	back to the default Blizzard look.
]]

BINDING_HEADER_MOUSELOOKBINDER = "Mouselook Binder"
BINDING_NAME_MOUSELOOKBINDER_TOGGLE = "Toggle Mouselook"

local MLB = CreateFrame("Frame", "MouselookBinderCore")
local secureLeft, secureRight
local config, picker

local defaults = {
	enabled = true,
	toggleKey = "BUTTON3",
	left  = { kind = "none", spell = "", macro = "", binding = "", macrotext = "" },
	right = { kind = "none", spell = "", macro = "", binding = "", macrotext = "" },
	leftBase = "CAMERAORSELECTORMOVE",
	rightBase = "TURNORACTION",
}

local kindOrder = { "none", "spell", "macrotext", "macro", "binding" }
local kindLabel = {
	none      = "Default (no override)",
	spell     = "Spell",
	macrotext = "Macro text",
	macro     = "Existing macro",
	binding   = "Binding command",
}

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff82c5ffMouselook Binder:|r " .. msg)
end

--------------------------------------------------------------------------------
-- Extra kinds, registered by companion addons
--
-- Keeps this addon free of any dependency on them: it only ever sees a label, a
-- db field to read, and optionally a widget to show while the kind is selected.
--
--   def.label     string                              dropdown entry
--   def.field     string                              db field holding the value, default "binding"
--   def.available function() return boolean end       optional, hides the entry
--   def.build     function(parent, side, y) -> frame  optional widget
--   def.refresh   function(widget, cfg, side)         optional
--------------------------------------------------------------------------------

MLB.kinds = {}

function MLB:RegisterKind(key, def)
	if type(key) ~= "string" or type(def) ~= "table" or not def.label then return end
	def.field = def.field or "binding"
	self.kinds[key] = def
end

local function KindLabel(key)
	return kindLabel[key] or (MLB.kinds[key] and MLB.kinds[key].label) or key
end

local function KindAvailable(key)
	local def = MLB.kinds[key]
	if not def or not def.available then return true end
	return def.available() and true or false
end

local function AllKinds()
	local list = {}
	for _, k in ipairs(kindOrder) do tinsert(list, k) end

	local extra = {}
	for k in pairs(MLB.kinds) do tinsert(extra, k) end
	sort(extra)
	for _, k in ipairs(extra) do tinsert(list, k) end

	return list
end

local function CopyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			CopyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

--------------------------------------------------------------------------------
-- Skinning: ElvUI when present, Blizzard otherwise
--------------------------------------------------------------------------------

local E, S
local Skin = {}

local blizzBackdrop = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
local blizzInset = {
	bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function InitSkin()
	if not ElvUI then return end
	local ok, elv = pcall(unpack, ElvUI)
	if not ok or not elv then return end
	E = elv
	S = E.GetModule and E:GetModule("Skins", true)
end

function Skin.Panel(f)
	if E then f:SetTemplate("Transparent") else f:SetBackdrop(blizzBackdrop) end
end

function Skin.Inset(f)
	if E then
		f:SetTemplate("Default")
	else
		f:SetBackdrop(blizzInset)
		f:SetBackdropColor(0, 0, 0, 0.6)
		f:SetBackdropBorderColor(0.4, 0.4, 0.4)
	end
end

function Skin.Button(b)    if S then S:HandleButton(b) end end
function Skin.CheckBox(c)  if S then S:HandleCheckBox(c) end end
function Skin.EditBox(e)   if S then S:HandleEditBox(e) end end
function Skin.Close(c)     if S then S:HandleCloseButton(c) end end
function Skin.DropDown(d, width)
	if S then S:HandleDropDownBox(d, width) else UIDropDownMenu_SetWidth(d, width) end
end
function Skin.ScrollBar(name)
	local bar = _G[name .. "ScrollBar"]
	if bar and S then S:HandleScrollBar(bar) end
end
function Skin.Font(fs, size, style)
	if E then fs:FontTemplate(nil, size, style) end
end

--------------------------------------------------------------------------------
-- Applying the bindings
--------------------------------------------------------------------------------

local appliedToggleKey

-- Override bindings are looked up per key combination: registering BUTTON1 does
-- nothing for CTRL-BUTTON1. Register the same action under every combination, so
-- holding a modifier still fires it. When the action is a CLICK on an action
-- button (as it is for anything bound from ElvUI's keybind mode) the button
-- resolves its own paging, so the modifier picks up whatever that bar paged to.
local modifierPrefixes = {
	"", "ALT-", "CTRL-", "SHIFT-",
	"ALT-CTRL-", "ALT-SHIFT-", "CTRL-SHIFT-", "ALT-CTRL-SHIFT-",
}

local function ActionFor(cfg, secureButton)
	if cfg.kind == "spell" then
		if cfg.spell == "" then return nil end
		return "SPELL " .. cfg.spell
	elseif cfg.kind == "macrotext" then
		if cfg.macrotext == "" then return nil end
		secureButton:SetAttribute("type", "macro")
		secureButton:SetAttribute("macrotext", cfg.macrotext)
		return "CLICK " .. secureButton:GetName() .. ":LeftButton"
	elseif cfg.kind == "macro" then
		if cfg.macro == "" then return nil end
		return "MACRO " .. cfg.macro
	elseif cfg.kind ~= "none" then
		-- "binding", plus any registered kind. An unregistered kind still
		-- resolves, so a binding is not silently lost when its companion addon
		-- is missing.
		local def = MLB.kinds[cfg.kind]
		local value = cfg[def and def.field or "binding"]
		if not value or value == "" then return nil end

		-- CLICK commands carry a frame name, which is case sensitive; plain
		-- binding commands are conventionally upper case
		if strfind(strupper(value), "^CLICK ") then
			return value
		end
		return strupper(value)
	end
	return nil
end

function MLB:Apply()
	local db = MouselookBinderDB
	if not db then return end

	if InCombatLockdown() then
		self.pending = true
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		return
	end
	self.pending = nil

	-- toggle key: clear the old one first so rebinding does not leave strays
	if appliedToggleKey and appliedToggleKey ~= db.toggleKey
		and GetBindingAction(appliedToggleKey) == "MOUSELOOKBINDER_TOGGLE" then
		SetBinding(appliedToggleKey, nil)
	end
	appliedToggleKey = nil
	if db.enabled and db.toggleKey and db.toggleKey ~= "" then
		SetBinding(db.toggleKey, "MOUSELOOKBINDER_TOGGLE")
		appliedToggleKey = db.toggleKey
	end

	-- mouse buttons
	local toApply = {
		{ "BUTTON1", db.left,  db.leftBase,  secureLeft  },
		{ "BUTTON2", db.right, db.rightBase, secureRight },
	}
	for _, v in ipairs(toApply) do
		local key, cfg, base, button = v[1], v[2], v[3], v[4]

		-- only the unmodified key gets a plain binding; touching the modified
		-- combos here would clobber real bindings outside of mouselook
		if base and base ~= "" then
			SetBinding(key, base)
		end

		local action = db.enabled and ActionFor(cfg, button) or nil
		for _, prefix in ipairs(modifierPrefixes) do
			SetMouselookOverrideBinding(prefix .. key, action)
		end
	end
end

function MouselookBinder_Toggle()
	if IsMouselooking() then
		MouselookStop()
	else
		MouselookStart()
	end
end

--------------------------------------------------------------------------------
-- Key capture button
--------------------------------------------------------------------------------

local mouseNames = {
	LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3",
	Button4 = "BUTTON4", Button5 = "BUTTON5",
}
local ignoreKeys = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
	LALT = true, RALT = true, UNKNOWN = true,
}

local function WithModifiers(key)
	local prefix = ""
	if IsAltKeyDown() then prefix = "ALT-" end
	if IsControlKeyDown() then prefix = prefix .. "CTRL-" end
	if IsShiftKeyDown() then prefix = prefix .. "SHIFT-" end
	return prefix .. key
end

local function CreateKeyCapture(parent)
	local b = CreateFrame("Button", "MouselookBinderKeyButton", parent, "UIPanelButtonTemplate")
	b:SetWidth(150)
	b:SetHeight(24)
	Skin.Button(b)

	local function Stop()
		b.capturing = nil
		b:EnableKeyboard(false)
		b:EnableMouseWheel(false)
		b:SetText(MouselookBinderDB.toggleKey ~= "" and MouselookBinderDB.toggleKey or "Not bound")
	end

	local function Accept(key)
		if key == "ESCAPE" then
			Stop()
			return
		end
		if key == "BUTTON1" or key == "BUTTON2" then
			Print("BUTTON1/BUTTON2 are used for the click actions below, pick another key.")
			Stop()
			return
		end
		MouselookBinderDB.toggleKey = key
		Stop()
		MLB:Apply()
	end

	-- everything runs off OnMouseDown; using OnClick as well would make the very
	-- click that accepts a mouse button immediately restart the capture
	b:SetScript("OnMouseDown", function(self, button)
		if not self.capturing then
			if button ~= "LeftButton" then return end
			self.capturing = true
			self:SetText("Press a key...")
			self:EnableKeyboard(true)
			self:EnableMouseWheel(true)
			return
		end
		local key = mouseNames[button]
		if key then Accept(WithModifiers(key)) end
	end)
	b:SetScript("OnKeyDown", function(self, key)
		if not self.capturing or ignoreKeys[key] then return end
		Accept(WithModifiers(key))
	end)
	b:SetScript("OnMouseWheel", function(self, delta)
		if not self.capturing then return end
		Accept(WithModifiers(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN"))
	end)
	b.Refresh = Stop
	return b
end

--------------------------------------------------------------------------------
-- Picker, shared by the spell and macro lists
--------------------------------------------------------------------------------

local PICK_ROWS, PICK_ROW_HEIGHT = 14, 22

local function BuildSpellList()
	local list, seen = {}, {}
	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, numSpells = GetSpellTabInfo(tab)
		for i = offset + 1, offset + numSpells do
			local name = GetSpellName(i, BOOKTYPE_SPELL)
			if name and not seen[name] then
				seen[name] = true
				tinsert(list, { name = name, texture = GetSpellTexture(i, BOOKTYPE_SPELL) })
			end
		end
	end
	sort(list, function(a, b) return a.name < b.name end)
	return list
end

local function BuildMacroList()
	local list = {}
	local account, character = GetNumMacros()
	local function add(from, count, scope)
		for i = from, from + count - 1 do
			local name, texture, body = GetMacroInfo(i)
			if name then
				tinsert(list, { name = name, texture = texture, tooltip = body, note = scope })
			end
		end
	end
	add(1, account or 0, "Account")
	add((MAX_ACCOUNT_MACROS or 36) + 1, character or 0, "Character")
	sort(list, function(a, b) return a.name < b.name end)
	return list
end

local function CreatePicker()
	local f = CreateFrame("Frame", "MouselookBinderPicker", UIParent)
	f:SetWidth(240)
	f:SetHeight(PICK_ROWS * PICK_ROW_HEIGHT + 78)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	Skin.Panel(f)
	tinsert(UISpecialFrames, "MouselookBinderPicker")

	local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOP", 0, -10)
	Skin.Font(title)

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	Skin.Close(close)

	local search = CreateFrame("EditBox", "MouselookBinderPickerSearch", f, "InputBoxTemplate")
	search:SetPoint("TOPLEFT", 14, -30)
	search:SetWidth(200)
	search:SetHeight(20)
	search:SetAutoFocus(false)
	Skin.EditBox(search)

	local scroll = CreateFrame("ScrollFrame", "MouselookBinderPickerScroll", f, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -58)
	scroll:SetWidth(200)
	scroll:SetHeight(PICK_ROWS * PICK_ROW_HEIGHT)
	Skin.ScrollBar("MouselookBinderPickerScroll")

	f.rows = {}
	for i = 1, PICK_ROWS do
		local row = CreateFrame("Button", nil, f)
		row:SetHeight(PICK_ROW_HEIGHT)
		row:SetWidth(196)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", f.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row:GetHighlightTexture():SetBlendMode("ADD")

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetWidth(PICK_ROW_HEIGHT - 4)
		row.icon:SetHeight(PICK_ROW_HEIGHT - 4)
		row.icon:SetPoint("LEFT", 2, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
		row.text:SetPoint("RIGHT", -2, 0)
		row.text:SetJustifyH("LEFT")
		Skin.Font(row.text)

		row:SetScript("OnClick", function(self)
			if not self.entryName or not f.onPick then return end
			f.onPick(self.entryName)
			f:Hide()
		end)
		row:SetScript("OnEnter", function(self)
			if not self.tooltip or self.tooltip == "" then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(self.entryName, 1, 1, 1)
			if self.note then GameTooltip:AddLine(self.note, 0.6, 0.6, 0.6) end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(self.tooltip, 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		f.rows[i] = row
	end

	local function Update()
		local filter = strlower(strtrim(search:GetText() or ""))
		local shown = {}
		for _, s in ipairs(f.list or {}) do
			if filter == "" or strfind(strlower(s.name), filter, 1, true) then
				tinsert(shown, s)
			end
		end

		FauxScrollFrame_Update(scroll, #shown, PICK_ROWS, PICK_ROW_HEIGHT)
		local offset = FauxScrollFrame_GetOffset(scroll)
		for i = 1, PICK_ROWS do
			local row, entry = f.rows[i], shown[i + offset]
			if entry then
				row.entryName = entry.name
				row.tooltip = entry.tooltip
				row.note = entry.note
				row.icon:SetTexture(entry.texture)
				row.text:SetText(entry.name)
				row:Show()
			else
				row.entryName = nil
				row.tooltip = nil
				row:Hide()
			end
		end
	end

	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, PICK_ROW_HEIGHT, Update)
	end)
	search:SetScript("OnTextChanged", Update)
	search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	function f:Open(anchor, heading, build, onPick)
		self.onPick = onPick
		self.list = build()
		title:SetText(heading)
		search:SetText("")
		FauxScrollFrame_SetOffset(scroll, 0)
		_G[scroll:GetName() .. "ScrollBar"]:SetValue(0)
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
		Update()
		self:Show()
	end

	return f
end

--------------------------------------------------------------------------------
-- One left/right click section
--------------------------------------------------------------------------------

local function CreateSection(parent, side, title, y)
	local function db() return MouselookBinderDB[side] end
	local s = {}

	local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", 20, y)
	header:SetText(title)
	Skin.Font(header)

	local kind = CreateFrame("Frame", "MouselookBinderKind" .. side, parent, "UIDropDownMenuTemplate")
	kind:SetPoint("TOPLEFT", 4, y - 18)
	Skin.DropDown(kind, 160)

	-- value widgets 1 and 2: spell and macro, both open the shared picker
	local function PickerButton(name, heading, build, field)
		local b = CreateFrame("Button", "MouselookBinder" .. name .. side, parent, "UIPanelButtonTemplate")
		b:SetPoint("TOPLEFT", 200, y - 23)
		b:SetWidth(170)
		b:SetHeight(22)
		Skin.Button(b)
		b:SetScript("OnClick", function(self)
			picker:Open(self, heading, build, function(picked)
				db()[field] = picked
				s:Refresh()
				MLB:Apply()
			end)
		end)
		return b
	end

	local spell = PickerButton("Spell", "Choose a spell", BuildSpellList, "spell")
	local macro = PickerButton("Macro", "Choose a macro", BuildMacroList, "macro")

	-- value widget 3: raw binding command
	local edit = CreateFrame("EditBox", "MouselookBinderEdit" .. side, parent, "InputBoxTemplate")
	edit:SetPoint("TOPLEFT", 200, y - 24)
	edit:SetWidth(170)
	edit:SetHeight(20)
	edit:SetAutoFocus(false)
	Skin.EditBox(edit)

	-- value widget 4: macro text
	local box = CreateFrame("Frame", nil, parent)
	box:SetPoint("TOPLEFT", 22, y - 44)
	box:SetWidth(348)
	box:SetHeight(64)
	Skin.Inset(box)

	local scroll = CreateFrame("ScrollFrame", "MouselookBinderScroll" .. side, box, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)
	Skin.ScrollBar("MouselookBinderScroll" .. side)

	local text = CreateFrame("EditBox", nil, scroll)
	text:SetMultiLine(true)
	text:SetAutoFocus(false)
	text:SetWidth(300)
	text:SetHeight(200)
	text:SetFontObject(ChatFontNormal)
	scroll:SetScrollChild(text)

	-- widgets contributed by companion addons, one per registered kind
	local extras = {}
	for key, def in pairs(MLB.kinds) do
		if def.build then
			local ok, widget = pcall(def.build, parent, side, y)
			if ok and widget then
				widget:Hide()
				extras[key] = widget
			end
		end
	end

	local function Save() MLB:Apply() end

	text:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	text:SetScript("OnTextChanged", function(self) db().macrotext = self:GetText() end)
	text:SetScript("OnEditFocusLost", Save)

	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnTextChanged", function(self) db().binding = self:GetText() end)
	edit:SetScript("OnEditFocusLost", Save)

	function s:Refresh()
		local cfg = db()
		UIDropDownMenu_SetSelectedValue(kind, cfg.kind)
		UIDropDownMenu_SetText(kind, KindLabel(cfg.kind))
		spell:SetText(cfg.spell ~= "" and cfg.spell or "Choose a spell...")
		macro:SetText(cfg.macro ~= "" and cfg.macro or "Choose a macro...")

		macro:Hide(); spell:Hide(); edit:Hide(); box:Hide()
		for _, widget in pairs(extras) do widget:Hide() end

		local def = MLB.kinds[cfg.kind]
		if def and KindAvailable(cfg.kind) then
			local widget = extras[cfg.kind]
			if widget then
				if def.refresh then pcall(def.refresh, widget, cfg, side) end
				widget:Show()
			end
		end

		if cfg.kind == "spell" then
			spell:Show()
		elseif cfg.kind == "macro" then
			macro:Show()
		elseif cfg.kind == "binding" then
			edit:SetText(cfg.binding)
			edit:Show()
		elseif cfg.kind == "macrotext" then
			text:SetText(cfg.macrotext)
			box:Show()
		end
	end

	UIDropDownMenu_Initialize(kind, function()
		for _, k in ipairs(AllKinds()) do
			if KindAvailable(k) then
			local info = UIDropDownMenu_CreateInfo()
			info.text = KindLabel(k)
			info.value = k
			info.func = function(self)
				db().kind = self.value
				UIDropDownMenu_SetSelectedValue(kind, self.value)
				s:Refresh()
				Save()
			end
			UIDropDownMenu_AddButton(info)
			end
		end
	end)

	return s
end

--------------------------------------------------------------------------------
-- Config window
--------------------------------------------------------------------------------

local function CreateConfig()
	local f = CreateFrame("Frame", "MouselookBinderFrame", UIParent)
	f:SetWidth(400)
	f:SetHeight(440)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	Skin.Panel(f)
	tinsert(UISpecialFrames, "MouselookBinderFrame")

	local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText("Mouselook Binder")
	Skin.Font(title, 14)

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	Skin.Close(close)

	local enable = CreateFrame("CheckButton", "MouselookBinderEnable", f, "UICheckButtonTemplate")
	enable:SetPoint("TOPLEFT", 16, -42)
	_G[enable:GetName() .. "Text"]:SetText("Enabled")
	Skin.CheckBox(enable)
	Skin.Font(_G[enable:GetName() .. "Text"])
	enable:SetScript("OnClick", function(self)
		MouselookBinderDB.enabled = self:GetChecked() and true or false
		MLB:Apply()
	end)

	local keyLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	keyLabel:SetPoint("TOPLEFT", 20, -76)
	keyLabel:SetText("Toggle mouselook key")
	Skin.Font(keyLabel)

	local keyButton = CreateKeyCapture(f)
	keyButton:SetPoint("TOPLEFT", 200, -72)

	local hint = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", 20, -100)
	hint:SetPoint("TOPRIGHT", -20, -100)
	hint:SetJustifyH("LEFT")
	hint:SetText("Click the button then press any key or mouse button. Escape cancels.")
	Skin.Font(hint, 11)

	local leftSection = CreateSection(f, "left", "Left click while mouselooking", -126)
	local rightSection = CreateSection(f, "right", "Right click while mouselooking", -256)

	local foot = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	foot:SetPoint("BOTTOMLEFT", 20, 16)
	foot:SetPoint("BOTTOMRIGHT", -20, 16)
	foot:SetJustifyH("LEFT")
	foot:SetText("Changes apply immediately (deferred until you leave combat).")
	Skin.Font(foot, 11)

	function f:Refresh()
		enable:SetChecked(MouselookBinderDB.enabled)
		keyButton:Refresh()
		leftSection:Refresh()
		rightSection:Refresh()
	end

	f:SetScript("OnShow", f.Refresh)
	f:SetScript("OnHide", function() if picker then picker:Hide() end end)
	return f
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

MLB:RegisterEvent("PLAYER_LOGIN")
MLB:SetScript("OnEvent", function(self, event)
	if event == "PLAYER_LOGIN" then
		MouselookBinderDB = MouselookBinderDB or {}
		CopyDefaults(MouselookBinderDB, defaults)

		secureLeft = CreateFrame("Button", "MouselookBinderLeftAction", UIParent, "SecureActionButtonTemplate")
		secureRight = CreateFrame("Button", "MouselookBinderRightAction", UIParent, "SecureActionButtonTemplate")
		for _, b in ipairs({ secureLeft, secureRight }) do
			-- kept shown (a CLICK binding will not fire on a hidden frame) but
			-- invisible, zero sized, off to the side and deaf to the mouse
			b:SetWidth(1)
			b:SetHeight(1)
			b:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -200, -200)
			b:SetAlpha(0)
			b:EnableMouse(false)
			b:RegisterForClicks("AnyDown")
			b:SetAttribute("type", "macro")
			b:Show()
		end

		InitSkin()
		picker = CreatePicker()
		config = CreateConfig()
		self:Apply()
	elseif event == "PLAYER_REGEN_ENABLED" then
		self:UnregisterEvent("PLAYER_REGEN_ENABLED")
		if self.pending then self:Apply() end
	end
end)

SLASH_MOUSELOOKBINDER1 = "/mlb"
SLASH_MOUSELOOKBINDER2 = "/mouselook"
SlashCmdList.MOUSELOOKBINDER = function(msg)
	if msg == "toggle" then
		MouselookBinder_Toggle()
	elseif msg == "apply" then
		MLB:Apply()
		Print("re-applied.")
	elseif config then
		if config:IsShown() then config:Hide() else config:Show() end
	end
end
