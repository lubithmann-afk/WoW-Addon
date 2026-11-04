-- AHWatch bag price arrows
-- While the auction house is open, shows a small green up arrow or red down
-- arrow with a percentage on crafting materials in your bags, based on how
-- their saved price has moved day over day. Crafting materials only, for now.
--
-- This hooks the same function Blizzard's own bag UI uses to draw each item
-- button, so it works regardless of how this client names its bag frames -
-- but it's still touching another addon's UI internals, which is the kind
-- of thing that can behave differently on a modified client. If arrows don't
-- show up, /ahw bagtest reports exactly what it found.

local _, ns = ...

local TRADEGOODS_CLASS_ID = 7   -- Blizzard's item class ID for crafting reagents
local MIN_PCT = 1               -- don't bother showing a barely-there change

local function Msg(text) print("|cff33ccffAHWatch:|r " .. text) end

local function IsCraftingMat(itemID)
    if not itemID then return false end
    local ok, classID
    -- pcall prepends its own success flag, so classID (the function's 6th
    -- return value) lands as the 7th value overall - one more skip than
    -- it looks like at first glance.
    if C_Item and C_Item.GetItemInfoInstant then
        ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, itemID)
    end
    if not ok and GetItemInfoInstant then
        ok, _, _, _, _, _, classID = pcall(GetItemInfoInstant, itemID)
    end
    return ok and classID == TRADEGOODS_CLASS_ID
end

------------------------------------------------------------
-- One small overlay per bag button, created the first time we see it
------------------------------------------------------------

local overlays = setmetatable({}, { __mode = "k" })

local function GetOverlay(button)
    local o = overlays[button]
    if o then return o end
    o = {}
    o.frame = CreateFrame("Frame", nil, button)
    o.frame:SetAllPoints()
    o.frame:SetFrameLevel(button:GetFrameLevel() + 5)
    o.bg = o.frame:CreateTexture(nil, "BACKGROUND")
    o.bg:SetPoint("BOTTOMLEFT", 1, 1)
    o.bg:SetSize(28, 12)
    o.bg:SetColorTexture(0, 0, 0, 0.6)
    o.arrow = o.frame:CreateTexture(nil, "OVERLAY")
    o.arrow:SetSize(9, 9)
    o.arrow:SetPoint("BOTTOMLEFT", o.bg, "BOTTOMLEFT", 2, 1)
    o.text = o.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    o.text:SetPoint("LEFT", o.arrow, "RIGHT", 1, 0)
    o.text:SetShadowOffset(1, -1)
    o.text:SetShadowColor(0, 0, 0, 1)
    overlays[button] = o
    return o
end

-- Bag/slot for a bag item button. Tries the modern mixin method first, then
-- falls back to reading it off the button's parent, since that's varied
-- across client versions.
local function GetBagSlot(button)
    local bag, slot
    if button.GetBagID then
        local ok, b = pcall(button.GetBagID, button)
        if ok and type(b) == "number" then bag = b end
    end
    if button.GetID then
        local ok, s = pcall(button.GetID, button)
        if ok and type(s) == "number" then slot = s end
    end
    if not bag then
        local parent = button:GetParent()
        if parent and parent.GetID then
            local ok, b = pcall(parent.GetID, parent)
            if ok and type(b) == "number" then bag = b end
        end
    end
    if type(bag) ~= "number" or type(slot) ~= "number" then return nil end
    return bag, slot
end

local sawAnyButton = false

local testOverrides = {}   -- itemID -> fake percent, set via /ahwtestarrow for visual testing

local function UpdateButton(button)
    if not button or not button.GetParent then return end
    sawAnyButton = true
    local o = GetOverlay(button)
    if not (ns.IsAHOpen and ns.IsAHOpen()) then
        o.frame:Hide()
        return
    end
    local bag, slot = GetBagSlot(button)
    if not bag then o.frame:Hide() return end

    local info
    if C_Container and C_Container.GetContainerItemInfo then
        info = C_Container.GetContainerItemInfo(bag, slot)
    end
    local itemID = info and info.itemID
    if not itemID or not IsCraftingMat(itemID) then
        o.frame:Hide()
        return
    end

    local pct = testOverrides[itemID] or (ns.GetTrend and ns.GetTrend(itemID))
    if not pct or math.abs(pct) < MIN_PCT then
        o.frame:Hide()
        return
    end

    if pct > 0 then
        o.arrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
        o.arrow:SetVertexColor(0.25, 0.95, 0.30)
        o.text:SetTextColor(0.35, 1, 0.40)
    else
        o.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
        o.arrow:SetVertexColor(0.95, 0.25, 0.25)
        o.text:SetTextColor(1, 0.35, 0.35)
    end
    o.text:SetText(string.format("%.0f%%", math.abs(pct)))
    o.frame:Show()
end

------------------------------------------------------------
-- Hooking into the bag UI
------------------------------------------------------------

-- Modern clients often put the update logic as a METHOD on a shared mixin
-- table (every item button uses the same underlying function), not as a
-- standalone global. Try that first, then fall back to older global-function
-- names from earlier client generations.
-- Hooking Blizzard's own update function turned out unreliable here - it
-- likely copies that function onto each button when the button is first
-- created (a common WoW pattern), so hooking the shared copy afterward
-- never actually fires for buttons that already existed. Instead of relying
-- on that, this looks up the actual button frames directly on a short
-- timer while the AH is open, which works regardless of when or how each
-- button's functions were set up.

-- Modern combined bags keep their item buttons in a frame pool
local function FromPool(pool, out)
    if type(pool) ~= "table" or type(pool.EnumerateActive) ~= "function" then return false end
    local ok = pcall(function()
        for button in pool:EnumerateActive() do table.insert(out, button) end
    end)
    return ok and #out > 0
end

local function DiscoverBagButtons()
    local found = {}
    local combined = _G.ContainerFrameCombinedBags
    if combined then
        for _, poolName in ipairs({ "itemButtonPool", "ItemButtonPool", "buttonPool", "ButtonPool" }) do
            if FromPool(combined[poolName], found) then break end
        end
        if #found == 0 and type(combined.Bags) == "table" then
            for _, bagFrame in pairs(combined.Bags) do
                if type(bagFrame) == "table" and type(bagFrame.Items) == "table" then
                    for _, item in pairs(bagFrame.Items) do
                        if type(item) == "table" and item.GetObjectType then table.insert(found, item) end
                    end
                end
            end
        end
    end
    -- Older, separate-bag-window style client as a fallback
    if #found == 0 then
        for i = 1, 13 do
            local frame = _G["ContainerFrame" .. i]
            if frame and frame.IsShown and frame:IsShown() then
                for j = 1, 40 do
                    local item = _G["ContainerFrame" .. i .. "Item" .. j]
                    if item then table.insert(found, item) end
                end
            end
        end
    end
    return found
end

local lastDiscoverCount = 0
local discoverTicker = C_Timer.NewTicker(0.4, function()
    if not (ns.IsAHOpen and ns.IsAHOpen()) then return end
    local buttons = DiscoverBagButtons()
    lastDiscoverCount = #buttons
    for _, b in ipairs(buttons) do UpdateButton(b) end
end)
local hookedFn = "direct scan (not a hook)"

local function RefreshAll()
    for button in pairs(overlays) do
        if button:IsShown() then UpdateButton(button) end
    end
end
ns.RefreshBagOverlays = RefreshAll

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e)
    if e == "AUCTION_HOUSE_CLOSED" then
        RefreshAll()   -- hides any overlays that were showing
    end
end)

-- For testing the visuals before you have two days of real history: forces
-- a fake up/down % on one item, so you can see the arrow on it right away.
-- Use a crafting mat you're actually carrying so the icon shows in bags.
-- /ahwtestarrow <itemID> <percent>   e.g. /ahwtestarrow 2840 25   (up 25%)
--                                         /ahwtestarrow 2840 -18  (down 18%)
-- /ahwtestarrow clear   removes all test overrides
SLASH_AHWTESTARROW1 = "/ahwtestarrow"
SlashCmdList["AHWTESTARROW"] = function(msg)
    local a, b = string.match(msg or "", "^(%S+)%s*(%S*)$")
    if a == "clear" then
        testOverrides = {}
        Msg("test arrows cleared.")
        return
    end
    local itemID, pct = tonumber(a), tonumber(b)
    if not itemID or not pct then
        Msg("usage: /ahwtestarrow <itemID> <percent>  (e.g. /ahwtestarrow 2840 25), or /ahwtestarrow clear")
        return
    end
    testOverrides[itemID] = pct
    local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or ("item " .. itemID)
    if not IsCraftingMat(itemID) then
        Msg(name .. " isn't a crafting material, so it won't show an arrow even with this override - "
            .. "that part of the check still applies. Try an item from Trade Goods instead.")
    else
        Msg(string.format("forcing %s to show %.0f%% (%s). It'll appear on its bag icon within about half a second.",
            name, pct, pct >= 0 and "up/green" or "down/red"))
    end
end

SLASH_AHWBAGTEST1 = "/ahwbagtest"
SlashCmdList["AHWBAGTEST"] = function()
    local count = 0
    for _ in pairs(overlays) do count = count + 1 end
    Msg(string.format("method: %s. Last scan found %d bag button(s) (AH open: %s). Buttons ever seen: %d.",
        hookedFn, lastDiscoverCount, tostring(ns.IsAHOpen and ns.IsAHOpen()), count))
    if lastDiscoverCount == 0 then
        Msg("ContainerFrameCombinedBags: " .. (_G.ContainerFrameCombinedBags and "exists" or "doesn't exist"))
        local combined = _G.ContainerFrameCombinedBags
        if combined then
            local fields = {}
            for k, v in pairs(combined) do
                if type(v) == "table" then table.insert(fields, k) end
            end
            table.sort(fields)
            Msg("its table fields: " .. (next(fields) and table.concat(fields, ", ") or "(none)"))
        end
        local anyOldFrame = false
        for i = 1, 13 do
            if _G["ContainerFrame" .. i] then anyOldFrame = true break end
        end
        Msg("old-style ContainerFrame1..13: " .. (anyOldFrame and "found at least one" or "none found"))
    end
end
