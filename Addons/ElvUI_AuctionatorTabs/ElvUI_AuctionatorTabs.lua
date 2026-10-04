-- ElvUI_AuctionatorTabs
--
-- ElvUI skins AuctionFrameTab1..AuctionFrame.numTabs when Blizzard_AuctionUI loads
-- (Modules/Skins/Blizzard/AuctionHouse.lua), and ElvUI_AddOnSkins only skins
-- Auctionator's own tabs when the Blizzard auction house skin is turned *off*
-- (Skins/Addons/auctionator.lua). So with the default settings, whichever of the two
-- ADDON_LOADED handlers runs first decides whether Auctionator's three extra tabs
-- (Buy / Sell / More...) exist in time to be skinned -- and they usually don't.
--
-- This addon re-applies S:HandleTab to any AuctionFrame tab that Auctionator created,
-- after Atr_Init has built them. It is idempotent: S:HandleTab bails out on tabs that
-- already carry an ElvUI backdrop, so it is harmless if either skin got there first.

local _G = _G
local type = type

local frame = CreateFrame("Frame")

local function SkinAuctionatorTabs()
	if not ElvUI then return end

	local E = unpack(ElvUI)
	if not E.private then return end -- ElvUI not initialized yet

	local S = E:GetModule("Skins")

	-- Only worth doing when the surrounding Blizzard tabs are ElvUI-styled; if that skin
	-- is off, ElvUI_AddOnSkins handles Auctionator's tabs itself.
	if not E.private.skins.blizzard.enable or not E.private.skins.blizzard.auctionhouse then return end

	local auctionFrame = _G.AuctionFrame
	if not auctionFrame or not auctionFrame.numTabs then return end

	for i = 1, auctionFrame.numTabs do
		local tab = _G["AuctionFrameTab"..i]

		-- Atr_AddSellTab stamps this on every tab it creates
		if tab and tab.auctionatorTab then
			S:HandleTab(tab)

			local previous = _G["AuctionFrameTab"..(i - 1)]
			if previous then
				tab:ClearAllPoints()
				tab:Point("TOPLEFT", previous, "TOPRIGHT", -15, 0)
			end
		end
	end
end

-- Run on the next frame so we land after every ADDON_LOADED / AUCTION_HOUSE_SHOW handler
-- in the current dispatch, whatever order ElvUI and Auctionator ended up in.
local function OnUpdate(self)
	self:SetScript("OnUpdate", nil)
	SkinAuctionatorTabs()
end

local function QueueSkin()
	frame:SetScript("OnUpdate", OnUpdate)
end

local function OnEvent(self, event)
	if event == "PLAYER_LOGIN" then
		if type(_G.Atr_Init) ~= "function" then return end

		hooksecurefunc("Atr_Init", QueueSkin)
		self:RegisterEvent("AUCTION_HOUSE_SHOW")

		-- Blizzard_AuctionUI can already be loaded (and Auctionator already inited)
		-- if another addon forced it at startup.
		if _G.AuctionatorInited then
			QueueSkin()
		end
	else
		QueueSkin()
	end
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", OnEvent)
