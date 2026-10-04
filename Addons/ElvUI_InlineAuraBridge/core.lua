--[[
	ElvUI Inline Aura Bridge

	Inline Aura only knows about Blizzard-style action buttons: it registers them
	by name prefix (ActionButton, MultiBar*, DominosActionButton, BT4Button) and
	hooks ActionButton_OnLoad / _Update / _UpdateState.

	ElvUI's bars are LibActionButton-1.0 buttons and never call any of those
	three functions, so Inline Aura is blind to them.

	This file bridges the gap without editing either addon.

	It does NOT register ElvUI's buttons with Inline Aura directly, because the
	two addons collide on field names -- LAB stores the macro-text FontString in
	button.actionName (LibActionButton-1.0.lua:148) while Inline Aura stores the
	resolved spell name there. Writing one breaks the other, and LAB's
	self.actionName:SetText() at :983 then throws inside AB:CreateBar.

	So every ElvUI button gets a small proxy frame instead. The proxy carries the
	state Inline Aura reads, and is what goes into InlineAura.buttons. ElvUI's
	button is never written to. As a bonus the proxy owns its own checked
	texture, so Inline Aura's aura highlight no longer lands on ElvUI's checked
	texture (a 30% white wash it also uses for "ability is active").
--]]

local LAB = LibStub("LibActionButton-1.0-ElvUI", true)
local InlineAura = InlineAura
local E = ElvUI and unpack(ElvUI)
local AB = E and E:GetModule("ActionBars", true)

if not LAB or not AB or not InlineAura or not InlineAura.buttons then return end

local CreateFrame, pairs, ipairs, _G = CreateFrame, pairs, ipairs, _G
local GetActionInfo, GetSpellInfo, GetSpellName = GetActionInfo, GetSpellInfo, GetSpellName
local GetItemSpell, GetMacroSpell = GetItemSpell, GetMacroSpell
local strlower, strtrim = strlower, strtrim

local bridge = {}
local proxies = {}
local db

-- Mirrors Inline Aura's ActionButton_Update_Hook, but reads LAB's state instead
-- of ActionButton_GetPagedID(). _state_action is already resolved for whichever
-- page/state the button currently shows, so no paging maths is needed.
local function ResolveAction(button)
	local kind, action = button._state_type, button._state_action
	if not kind or action == nil then return end

	if kind == "action" then
		local actionType, arg1, arg2, arg3 = GetActionInfo(action)
		if actionType == "spell" then
			if arg1 and arg2 and arg1 > 0 then
				return GetSpellName(arg1, arg2), actionType
			elseif arg3 then
				return GetSpellInfo(arg3), actionType
			end
		elseif actionType == "item" then
			return GetItemSpell(arg1), actionType
		else
			-- for macros arg1 is the macro index; Inline Aura resolves it itself
			return arg1, actionType
		end
	elseif kind == "spell" then
		return GetSpellInfo(action), "spell"
	elseif kind == "item" then
		return GetItemSpell(action), "item"
	elseif kind == "macro" then
		-- resolve here and report it as a spell, otherwise Inline Aura would run
		-- GetMacroSpell() a second time on an already-resolved name
		return (GetMacroSpell(action)), "spell"
	end
end

--------------------------------------------------------------------------------
-- Highlight
--
-- Inline Aura's UpdateHighlight() only knows how to SetVertexColor() whatever
-- GetCheckedTexture() returns and then SetChecked(). To get a look that matches
-- ElvUI we hand it a texture that never draws, purely as a colour carrier, and
-- override SetChecked() on our own proxy to paint the real highlight from that
-- colour. Nothing in Inline Aura changes.
--------------------------------------------------------------------------------

local STYLES = { border = true, glow = true, wash = true }
local DEFAULT_STYLE = "border"
local EDGES = { "TOP", "BOTTOM", "LEFT", "RIGHT" }

local function Style()
	return (db and STYLES[db.style] and db.style) or DEFAULT_STYLE
end

local function LayoutEdges(proxy)
	-- E.Border is ElvUI's own pixel-perfect border width, so the outline lands
	-- on the same grid as every other ElvUI border
	local weight = E.Border or ((E.mult or 1) * 2)
	local e = proxy.edges

	e.TOP:ClearAllPoints()
	e.TOP:SetPoint("TOPLEFT", proxy, "TOPLEFT")
	e.TOP:SetPoint("TOPRIGHT", proxy, "TOPRIGHT")
	e.TOP:SetHeight(weight)

	e.BOTTOM:ClearAllPoints()
	e.BOTTOM:SetPoint("BOTTOMLEFT", proxy, "BOTTOMLEFT")
	e.BOTTOM:SetPoint("BOTTOMRIGHT", proxy, "BOTTOMRIGHT")
	e.BOTTOM:SetHeight(weight)

	e.LEFT:ClearAllPoints()
	e.LEFT:SetPoint("TOPLEFT", proxy, "TOPLEFT")
	e.LEFT:SetPoint("BOTTOMLEFT", proxy, "BOTTOMLEFT")
	e.LEFT:SetWidth(weight)

	e.RIGHT:ClearAllPoints()
	e.RIGHT:SetPoint("TOPRIGHT", proxy, "TOPRIGHT")
	e.RIGHT:SetPoint("BOTTOMRIGHT", proxy, "BOTTOMRIGHT")
	e.RIGHT:SetWidth(weight)
end

local function PaintHighlight(proxy, shown)
	if not shown then
		proxy.fill:Hide()
		for _, edge in pairs(proxy.edges) do edge:Hide() end
		return
	end

	local r, g, b, a = proxy.carrier:GetVertexColor()
	r, g, b, a = r or 1, g or 1, b or 1, a or 1
	local style = Style()

	if style == "border" then
		proxy.fill:Hide()
		LayoutEdges(proxy)
		for _, edge in pairs(proxy.edges) do
			edge:SetVertexColor(r, g, b, a)
			edge:Show()
		end
		return
	end

	for _, edge in pairs(proxy.edges) do edge:Hide() end

	if style == "wash" then
		-- what ElvUI's own checked texture looks like: a flat translucent fill
		proxy.fill:SetTexture(1, 1, 1)
		proxy.fill:SetBlendMode("BLEND")
		proxy.fill:SetVertexColor(r, g, b, 0.25)
	else -- glow
		proxy.fill:SetTexture([[Interface\Buttons\ButtonHilight-Square]])
		proxy.fill:SetBlendMode("ADD")
		proxy.fill:SetVertexColor(r, g, b, a)
	end

	proxy.fill:Show()
end

local function CreateProxy(button)
	local name = button:GetName() .. "InlineAura"

	-- CheckButton because Inline Aura's UpdateHighlight() calls
	-- GetCheckedTexture() and SetChecked() on whatever it is given
	local proxy = CreateFrame("CheckButton", name, button)
	proxy:SetAllPoints(button)
	proxy:EnableMouse(false) -- must never intercept clicks on the real button
	proxy:SetFrameLevel(button:GetFrameLevel() + 1)

	-- Inline Aura anchors its timer frame to _G[name.."Cooldown"]
	local cooldown = CreateFrame("Frame", name .. "Cooldown", proxy)
	cooldown:SetAllPoints(button.cooldown or button)

	-- colour carrier. No texture file is ever set, so it draws nothing, but it
	-- still holds the vertex colour Inline Aura assigns.
	local carrier = proxy:CreateTexture()
	proxy:SetCheckedTexture(carrier)
	proxy.carrier = carrier

	local fill = proxy:CreateTexture(nil, "OVERLAY")
	fill:SetAllPoints(proxy)
	fill:Hide()
	proxy.fill = fill

	proxy.edges = {}
	for _, point in ipairs(EDGES) do
		local edge = proxy:CreateTexture(nil, "OVERLAY")
		edge:SetTexture(1, 1, 1)
		edge:Hide()
		proxy.edges[point] = edge
	end

	local SetChecked = proxy.SetChecked
	proxy.SetChecked = function(self, state)
		SetChecked(self, state and true or false)
		PaintHighlight(self, state and true or false)
	end

	proxy:SetChecked(false)

	-- Inline Aura's "no aura" branch only clears the highlight if .action is
	-- set: IsCurrentAction(0) is false, so this makes it call SetChecked(false).
	-- It lives on the proxy, so LAB's own checked state is untouched.
	proxy.action = 0

	return proxy
end

local function Refresh(button)
	local proxy = proxies[button]
	if not proxy then return end

	proxy.actionName, proxy.actionType = ResolveAction(button)

	-- re-assert: Inline Aura's first-frame sweep after VARIABLES_LOADED can drop
	-- entries from its registry
	InlineAura.buttons[proxy] = true
	InlineAura:RequireUpdate()
end

local function Adopt(button)
	if proxies[button] then return end
	if not button.GetName or not button:GetName() then return end

	proxies[button] = CreateProxy(button)
	Refresh(button)
end

function bridge:OnButtonCreated(_, button)
	Adopt(button)
end

function bridge:OnButtonUpdate(_, button)
	Refresh(button)
end

function bridge:OnButtonContentsChanged(_, button)
	Refresh(button)
end

LAB.RegisterCallback(bridge, "OnButtonCreated", "OnButtonCreated")
LAB.RegisterCallback(bridge, "OnButtonUpdate", "OnButtonUpdate")
LAB.RegisterCallback(bridge, "OnButtonContentsChanged", "OnButtonContentsChanged")

-- Catch anything LAB built before we loaded, and re-assert registrations once
-- the world is up.
local sweeper = CreateFrame("Frame")
sweeper:RegisterEvent("ADDON_LOADED")
sweeper:RegisterEvent("PLAYER_LOGIN")
sweeper:RegisterEvent("PLAYER_ENTERING_WORLD")
sweeper:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" then
		if name ~= "ElvUI_InlineAuraBridge" then return end
		ElvUIInlineAuraBridgeDB = ElvUIInlineAuraBridgeDB or {}
		db = ElvUIInlineAuraBridgeDB
		if not STYLES[db.style] then db.style = DEFAULT_STYLE end
		return
	end

	if not AB.handledBars then return end

	for _, bar in pairs(AB.handledBars) do
		if type(bar) == "table" and bar.buttons then
			for _, button in pairs(bar.buttons) do
				Adopt(button)
				Refresh(button)
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- /iab
--------------------------------------------------------------------------------

SLASH_ELVUIINLINEAURABRIDGE1 = "/iab"
SlashCmdList.ELVUIINLINEAURABRIDGE = function(msg)
	msg = strlower(strtrim(msg or ""))

	if STYLES[msg] then
		db.style = msg
		for _, proxy in pairs(proxies) do
			PaintHighlight(proxy, proxy:GetChecked() and true or false)
		end
		DEFAULT_CHAT_FRAME:AddMessage("|cff82c5ffAura Bridge:|r highlight style set to " .. msg .. ".")
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff82c5ffAura Bridge:|r /iab border | glow | wash  (current: " .. Style() .. ")")
	end
end
