-- AHWatch Sell tab
-- Scans your bags for things you can put on the auction house, compares the
-- auction house price with the vendor price, suggests a price that should sell
-- quickly without giving money away, and lets you post from the same screen.
--
-- Note: the auction house never shows what items actually SOLD for, only what
-- they're listed at. "Average" here is the same typical listed price the
-- tooltip shows, from the price history this addon has saved.

local _, ns = ...
local f = AHWatchFrame
local Money, Msg = ns.Money, ns.Msg

local ROWS = 8
local AH_CUT = 0.05          -- the auction house keeps 5% of the sale
local VENDOR_MARGIN = 1.15   -- AH has to beat the vendor by 15% to be worth the wait
local DUMP_RATIO = 0.7       -- cheapest listing under 70% of normal = someone dumping
local LIVE_FRESH = 300       -- live prices count as current for 5 minutes

local items = {}             -- sellable items found in bags
local offset = 0
local selectedID = nil
local duration = 2           -- 1 = 2h, 2 = 8h, 3 = 24h (this client's actual AH duration tiers)
local pendingPost = nil      -- post waiting for a price-warning confirm
local live = {}              -- itemID -> { low = copper, qty = n, time = t } from "Check price"
ns.liveLow = live            -- shared with the Mine tab (Mine.lua)

------------------------------------------------------------
-- Tabs and panel
------------------------------------------------------------

local tabBuy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
tabBuy:SetSize(54, 18)
tabBuy:SetText("Buy")
local tabSell = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
tabSell:SetSize(54, 18)
tabSell:SetText("Sell")
local tabQS = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
tabQS:SetSize(72, 18)
tabQS:SetText("Quick Sell")
local tabFlips = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
tabFlips:SetSize(46, 18)
tabFlips:SetText("Deals")
tabBuy:SetSize(42, 18)
tabSell:SetSize(42, 18)
-- Buy | Sell | Quick Sell | Flips, right-aligned in the title bar
local tabMine = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
tabMine:SetSize(40, 18)
tabMine:SetText("Mine")
tabMine:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -3)
tabFlips:SetPoint("RIGHT", tabMine, "LEFT", -2, 0)
tabQS:SetPoint("RIGHT", tabFlips, "LEFT", -2, 0)
tabSell:SetPoint("RIGHT", tabQS, "LEFT", -2, 0)
tabBuy:SetPoint("RIGHT", tabSell, "LEFT", -2, 0)
-- The window title moves to the left edge so it doesn't sit under the tabs
if f.TitleText then
    f.TitleText:ClearAllPoints()
    f.TitleText:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -5)
    f.TitleText:SetJustifyH("LEFT")
end
tabQS:SetSize(66, 18)
for _, t in ipairs({ tabBuy, tabSell, tabQS, tabFlips, tabMine }) do
    t:SetNormalFontObject(GameFontNormalSmall)
    t:SetHighlightFontObject(GameFontHighlightSmall)
    t:SetFrameLevel(f:GetFrameLevel() + 60)
end

-- The Sell tab covers the Buy tab's content (the bottom row stays visible)
local panel = CreateFrame("Frame", "AHWatchSellPanel", f)
panel:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -26)
panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 34)
panel:SetFrameLevel(f:GetFrameLevel() + 40)
panel:EnableMouse(true)
panel:Hide()
local panelBase = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
panelBase:SetAllPoints()
panelBase:SetColorTexture(0, 0, 0, 1)      -- solid, so nothing from the Buy tab shows through
local panelBg = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
panelBg:SetAllPoints()

-- The Quick Sell tab: pick an item + a price + an amount once, then every
-- press of the Buy tab's same keybind posts another batch - the selling
-- equivalent of the Buy tab's "set it and press repeatedly" workflow. It
-- stops short of the bottom of the window (unlike the advisor panel above)
-- so the shared Go button/keybind stays visible and clickable underneath it.
local qsPanel = CreateFrame("Frame", "AHWatchQuickSellPanel", f)
qsPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -26)
qsPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 74)
qsPanel:SetFrameLevel(f:GetFrameLevel() + 40)
qsPanel:EnableMouse(true)
-- Soak up the mouse wheel too, so scrolling over an empty spot can't reach a
-- hidden Buy-tab price box underneath and change it
qsPanel:EnableMouseWheel(true)
qsPanel:SetScript("OnMouseWheel", function(_, delta)
    if ns.ScrollQSList then ns.ScrollQSList(delta) end
end)
qsPanel:Hide()
local qsPanelBase = qsPanel:CreateTexture(nil, "BACKGROUND", nil, -8)
qsPanelBase:SetAllPoints()
qsPanelBase:SetColorTexture(0, 0, 0, 1)
local qsPanelBg = qsPanel:CreateTexture(nil, "BACKGROUND", nil, -7)
qsPanelBg:SetAllPoints()

-- The Flips tab: every buy-low / resell-near-market opportunity, full page
local flipsPanel = CreateFrame("Frame", "AHWatchFlipsPanel", f)
flipsPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -26)
flipsPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 34)
flipsPanel:SetFrameLevel(f:GetFrameLevel() + 40)
flipsPanel:EnableMouse(true)
flipsPanel:Hide()
local flipsPanelBase = flipsPanel:CreateTexture(nil, "BACKGROUND", nil, -8)
flipsPanelBase:SetAllPoints()
flipsPanelBase:SetColorTexture(0, 0, 0, 1)
local flipsPanelBg = flipsPanel:CreateTexture(nil, "BACKGROUND", nil, -7)
flipsPanelBg:SetAllPoints()

-- Panel backgrounds the theme recolors (other files can add theirs)
ns.panelBgs = { panelBg, qsPanelBg, flipsPanelBg }
function ns.SkinSellPanel(skinned, mode)
    ns.lastSkin = { skinned, mode }
    local function ColorBoth(r, g, b, a)
        for _, bg in ipairs(ns.panelBgs) do bg:SetColorTexture(r, g, b, a) end
    end
    if mode == "auction" then
        ColorBoth(0.055, 0.050, 0.045, 1)
    elseif mode == "spacew" then
        ColorBoth(0.04, 0.035, 0.045, 1)
    elseif mode == "onlylawns" then
        ColorBoth(0.05, 0.075, 0.045, 1)
    elseif skinned then
        ColorBoth(0.067, 0.075, 0.086, 1)
    else
        for _, bg in ipairs(ns.panelBgs) do
            bg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background-Dark", "REPEAT", "REPEAT")
            bg:SetHorizTile(true)
            bg:SetVertTile(true)
            bg:SetVertexColor(1, 1, 1, 1)
        end
    end
end
ns.SkinSellPanel(false, "classic")

local function Text(parent, font, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH("LEFT")
    return fs
end

------------------------------------------------------------
-- Price analysis
------------------------------------------------------------

local function VendorPrice(itemID)
    local price
    if C_Item and C_Item.GetItemInfo then price = select(11, C_Item.GetItemInfo(itemID)) end
    if not price and GetItemInfo then price = select(11, GetItemInfo(itemID)) end
    return price or 0
end

-- Stackable goods (ore, food, cloth...) are "commodities" and post differently
-- from gear. The game answers this for an item in a bag slot, not an item ID.
local function IsCommodity(e)
    local s = e.slots and e.slots[1]
    if s and ItemLocation and C_AuctionHouse and C_AuctionHouse.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
        local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, ItemLocation:CreateFromBagAndSlot(s.bag, s.slot))
        if ok and status == Enum.ItemCommodityStatus.Commodity then return true end
        if ok and status == Enum.ItemCommodityStatus.Item then return false end
    end
    -- Fallback: anything that stacks is almost always a commodity
    local maxStack
    if C_Item and C_Item.GetItemMaxStackSizeByID then maxStack = C_Item.GetItemMaxStackSizeByID(e.itemID) end
    if not maxStack and C_Item and C_Item.GetItemInfo then maxStack = select(8, C_Item.GetItemInfo(e.itemID)) end
    if not maxStack and GetItemInfo then maxStack = select(8, GetItemInfo(e.itemID)) end
    return (maxStack or 1) > 1
end

-- Everything the addon knows about an item's price, plus a recommendation
local function Analyze(e)
    local a = { vendor = VendorPrice(e.itemID) }
    local hist = ns.GetPriceRecord and ns.GetPriceRecord(e.itemID)

    -- Market price: the one the whole addon uses (saved history once it has
    -- 2+ reliable days, Auctionator before that)
    if ns.MarketPrice then
        local m, source, days = ns.MarketPrice(e.itemID)
        if m then a.typical, a.source, a.days = m, source, days end
    end

    -- Cheapest listing right now: a fresh "Check price" beats saved data
    local lv = live[e.itemID]
    if lv and time() - lv.time < LIVE_FRESH then
        a.low, a.listed, a.lowTime, a.isLive = lv.low, lv.qty, lv.time, true
    elseif hist and hist.l then
        a.low, a.listed, a.lowTime = hist.l[2], hist.l[4], hist.l[1]
    end

    -- A few items listed far under the rest are probably bait - price
    -- against where the real supply starts, not against them
    a.bait = ns.GetBait and ns.GetBait(e.itemID)
    local undercutFrom = (a.bait and a.bait.floor) or a.low

    -- Suggested price: by default, the average of what it's actually been
    -- selling for, so you're not racing every other seller to the bottom.
    -- Switch to "Undercut" (1c under the cheapest listing) if you want the
    -- fastest possible sale instead.
    local mode = (AHWatchDB and AHWatchDB.sellMode) or "average"
    if mode == "undercut" and undercutFrom and undercutFrom > 0 then
        a.suggest = math.max(1, undercutFrom - 1)
    elseif a.typical then
        a.suggest = a.typical
    elseif undercutFrom and undercutFrom > 0 then
        a.suggest = math.max(1, undercutFrom - 1)   -- no saved average yet - fall back to undercut
    end
    if not a.bait and a.low and a.typical and a.low < a.typical * DUMP_RATIO then a.dumped = true end

    if a.suggest then
        a.net = math.floor(a.suggest * (1 - AH_CUT))   -- what you actually get after the AH cut
        if a.vendor > 0 and a.net <= a.vendor * VENDOR_MARGIN then
            a.verdict = "vendor"
        else
            a.verdict = "ah"
        end
    else
        a.verdict = (a.vendor > 0) and "unknown-vendor" or "unknown"
    end
    return a
end

------------------------------------------------------------
-- Bag scan
------------------------------------------------------------

local function ScanBags()
    local byID, order = {}, {}
    local lastBag = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
    local canCheck = ns.IsAHOpen() and C_AuctionHouse and C_AuctionHouse.IsSellItemValid and ItemLocation
    for bag = 0, lastBag do
        local slots = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                local ok = true
                if canCheck then
                    local okCall, valid = pcall(C_AuctionHouse.IsSellItemValid, ItemLocation:CreateFromBagAndSlot(bag, slot), false)
                    ok = okCall and valid
                end
                if ok then
                    local e = byID[info.itemID]
                    if not e then
                        e = { itemID = info.itemID, count = 0, slots = {}, icon = info.iconFileID, link = info.hyperlink }
                        byID[info.itemID] = e
                        table.insert(order, e)
                    end
                    e.count = e.count + (info.stackCount or 1)
                    table.insert(e.slots, { bag = bag, slot = slot, count = info.stackCount or 1 })
                end
            end
        end
    end
    for _, e in ipairs(order) do
        e.name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.itemID)) or e.link or "?"
        e.analysis = Analyze(e)
    end
    -- Best money-makers first, things to vendor next, unknowns last
    local rank = { ah = 1, vendor = 2, ["unknown-vendor"] = 3, unknown = 4 }
    table.sort(order, function(x, y)
        local rx, ry = rank[x.analysis.verdict], rank[y.analysis.verdict]
        if rx ~= ry then return rx < ry end
        local vx = (x.analysis.net or x.analysis.vendor or 0) * x.count
        local vy = (y.analysis.net or y.analysis.vendor or 0) * y.count
        return vx > vy
    end)
    items = order
    if offset > math.max(0, #items - ROWS) then offset = math.max(0, #items - ROWS) end
end

------------------------------------------------------------
-- List
------------------------------------------------------------

Text(panel, "GameFontNormalSmall", 8, -6):SetText("Items in your bags you can sell (best first):")
local rescanBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
rescanBtn:SetSize(80, 18)
rescanBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -3)
rescanBtn:SetText("Rescan")
rescanBtn:SetNormalFontObject(GameFontNormalSmall)
rescanBtn:SetHighlightFontObject(GameFontHighlightSmall)

local rows = {}
for i = 1, ROWS do
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(334, 30)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -24 - (i - 1) * 31)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(26, 26)
    b.icon:SetPoint("LEFT", 2, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 6, 0)
    b.name:SetWidth(210)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.info = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.info:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 6, 0)
    b.info:SetWidth(210)
    b.info:SetJustifyH("LEFT")
    b.info:SetWordWrap(false)
    b.badge = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.badge:SetPoint("RIGHT", -6, 0)
    b.badge:SetJustifyH("RIGHT")
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 0.82, 0, 0.12)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:SetScript("OnEnter", function(self)
        if self.entry and self.entry.slots[1] then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetBagItem(self.entry.slots[1].bag, self.entry.slots[1].slot)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    rows[i] = b
end

local emptyText = Text(panel, "GameFontDisable", 12, -60, 320)
emptyText:SetText("Nothing in your bags can be sold on the auction house.")

local scrollHint = Text(panel, "GameFontDisableSmall", 8, -274)
panel:EnableMouseWheel(true)

------------------------------------------------------------
-- Details for the selected item
------------------------------------------------------------

local DY = -292
local dName = Text(panel, "GameFontNormal", 8, DY, 330)
dName:SetWordWrap(false)
local dLines = {}
for i = 1, 4 do dLines[i] = Text(panel, "GameFontHighlightSmall", 8, DY - 18 - (i - 1) * 14, 330) end
local checkBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
checkBtn:SetSize(96, 18)
checkBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, DY + 2)
checkBtn:SetText("Check price")
checkBtn:SetNormalFontObject(GameFontNormalSmall)
checkBtn:SetHighlightFontObject(GameFontHighlightSmall)

local advice = Text(panel, "GameFontNormalSmall", 8, DY - 80, 330)
advice:SetSpacing(2)

Text(panel, "GameFontNormalSmall", 8, DY - 118):SetText("Price each:")
-- How your price compares with the market, updated as you type
-- Two lines next to "Price each:": vs the current lowest listing on top,
-- vs market underneath
local sellLow = Text(panel, "GameFontHighlightSmall", 74, DY - 118, 160)
sellLow:SetWordWrap(false)
local sellVs = Text(panel, "GameFontHighlightSmall", 74, DY - 130, 160)
sellVs:SetWordWrap(false)
local modeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
modeBtn:SetSize(100, 18)
modeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, DY - 118)
modeBtn:SetNormalFontObject(GameFontNormalSmall)
modeBtn:SetHighlightFontObject(GameFontHighlightSmall)
local function SellMode() return (AHWatchDB and AHWatchDB.sellMode) or "average" end
local priceMoney = ns.MoneyInput(16, DY - 146, nil, panel)
local useSuggested = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
useSuggested:SetSize(84, 18)
useSuggested:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, DY - 146)
useSuggested:SetText("Suggested")
useSuggested:SetNormalFontObject(GameFontNormalSmall)
useSuggested:SetHighlightFontObject(GameFontHighlightSmall)

-- Quantity
Text(panel, "GameFontNormalSmall", 8, DY - 178):SetText("Quantity:")
local qtyBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
qtyBox:SetSize(46, 20)
qtyBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 74, DY - 174)
qtyBox:SetAutoFocus(false)
qtyBox:SetNumeric(true)
qtyBox:SetJustifyH("RIGHT")
local function Arrow(dir, anchorPoint, relPoint, y)
    local a = CreateFrame("Button", nil, panel)
    a:SetSize(14, 10)
    a:SetPoint(anchorPoint, qtyBox, relPoint, 1, y)
    a:SetNormalTexture("Interface\\Buttons\\Arrow-" .. dir .. "-Up")
    a:SetPushedTexture("Interface\\Buttons\\Arrow-" .. dir .. "-Down")
    a:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    a.pbArrow = true
    return a
end
local qtyUp = Arrow("Up", "TOPLEFT", "TOPRIGHT", 1)
local qtyDown = Arrow("Down", "BOTTOMLEFT", "BOTTOMRIGHT", -1)
local qtyNote = Text(panel, "GameFontHighlightSmall", 142, DY - 178, 190)

-- Duration
Text(panel, "GameFontNormalSmall", 8, DY - 206):SetText("Duration:")
local durBtns = {}
for i, d in ipairs({ { 1, "2h" }, { 2, "8h" }, { 3, "24h" } }) do
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(44, 18)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", 70 + (i - 1) * 46, DY - 203)
    b:SetText(d[2])
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b.value = d[1]
    durBtns[i] = b
end
local depositText = Text(panel, "GameFontHighlightSmall", 8, DY - 228, 330)

local postBtn = CreateFrame("Button", "AHWatchPostButton", panel, "UIPanelButtonTemplate")
postBtn:SetSize(330, 26)
postBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, DY - 248)
postBtn.pbPrimary = true

------------------------------------------------------------
-- Quick Sell: pick an item once, then the shared Go button/keybind posts
-- another batch of it every time it's pressed - no re-picking, re-pricing,
-- or re-clicking needed between batches.
------------------------------------------------------------

local qsItemID, qsItemName, qsItemIcon = nil, nil, nil
local qsPendingPost = nil   -- post waiting for a price-warning confirm, mirrors `pendingPost` above
local lastQSPost = 0   -- GetTime() of the last post actually started, for the optional cooldown
local RefreshQS, QuickSellGo   -- defined further down, referenced by widgets created here

local qsIntro = Text(qsPanel, "GameFontNormalSmall", 8, -6, 330)
qsIntro:SetText("Pick an item and set a price + amount below. Press your Buy-tab key to post; press again for more.")

Text(qsPanel, "GameFontNormalSmall", 8, -44):SetText("Find in bags:")
local qsSearchBox = CreateFrame("EditBox", nil, qsPanel, "InputBoxTemplate")
qsSearchBox:SetSize(180, 20)
qsSearchBox:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 88, -40)
qsSearchBox:SetAutoFocus(false)
qsSearchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
qsSearchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

local QS_ROWS = 5
local qsOffset = 0          -- scroll position in the "Find in bags" list
local qsMatchCount = 0
local qsRows = {}
for i = 1, QS_ROWS do
    local b = CreateFrame("Button", nil, qsPanel)
    b:SetSize(334, 24)
    b:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 4, -70 - (i - 1) * 25)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(20, 20)
    b.icon:SetPoint("LEFT", 2, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.name:SetWidth(300)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 0.82, 0, 0.12)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:Hide()
    qsRows[i] = b
end
local qsEmptyText = Text(qsPanel, "GameFontDisable", 12, -74, 320)
-- "1-5 of 23" when there are more matches than fit; scroll to see them
local qsScrollText = qsPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
qsScrollText:SetPoint("TOPRIGHT", qsPanel, "TOPRIGHT", -8, -44)
qsScrollText:SetJustifyH("RIGHT")
qsEmptyText:SetText("No matching sellable items in your bags.")

local QS_DY = -206
local qsSelectedText = Text(qsPanel, "GameFontNormal", 8, QS_DY, 330)
qsSelectedText:SetText("Selected: |cffaaaaaanothing yet|r")

Text(qsPanel, "GameFontNormalSmall", 8, QS_DY - 28):SetText("Price each:")
local qsLow = Text(qsPanel, "GameFontHighlightSmall", 74, QS_DY - 28, 260)
qsLow:SetWordWrap(false)
local qsVs = Text(qsPanel, "GameFontHighlightSmall", 74, QS_DY - 40, 260)
qsVs:SetWordWrap(false)
local qsPriceMoney = ns.MoneyInput(16, QS_DY - 56, nil, qsPanel)
local qsSuggested = CreateFrame("Button", nil, qsPanel, "UIPanelButtonTemplate")
qsSuggested:SetSize(84, 18)
qsSuggested:SetPoint("TOPRIGHT", qsPanel, "TOPRIGHT", -6, QS_DY - 56)
qsSuggested:SetText("Suggested")
qsSuggested:SetNormalFontObject(GameFontNormalSmall)
qsSuggested:SetHighlightFontObject(GameFontHighlightSmall)

Text(qsPanel, "GameFontNormalSmall", 8, QS_DY - 88):SetText("Amount per press:")
local qsQtyBox = CreateFrame("EditBox", nil, qsPanel, "InputBoxTemplate")
qsQtyBox:SetSize(46, 20)
qsQtyBox:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 112, QS_DY - 84)
qsQtyBox:SetAutoFocus(false)
qsQtyBox:SetNumeric(true)
qsQtyBox:SetJustifyH("RIGHT")
qsQtyBox:SetText("1")
local function QSArrow(dir, anchorPoint, relPoint, y)
    local a = CreateFrame("Button", nil, qsPanel)
    a:SetSize(14, 10)
    a:SetPoint(anchorPoint, qsQtyBox, relPoint, 1, y)
    a:SetNormalTexture("Interface\\Buttons\\Arrow-" .. dir .. "-Up")
    a:SetPushedTexture("Interface\\Buttons\\Arrow-" .. dir .. "-Down")
    a:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    a.pbArrow = true
    return a
end
local qsQtyUp = QSArrow("Up", "TOPLEFT", "TOPRIGHT", 1)
local qsQtyDown = QSArrow("Down", "BOTTOMLEFT", "BOTTOMRIGHT", -1)
local function QSQty() return math.max(1, tonumber(qsQtyBox:GetText() or "") or 1) end
local function QSStepQty(dir)
    local step = IsShiftKeyDown() and 10 or 1
    qsQtyBox:SetText(tostring(math.max(1, QSQty() + dir * step)))
end
qsQtyUp:SetScript("OnClick", function() QSStepQty(1) end)
qsQtyDown:SetScript("OnClick", function() QSStepQty(-1) end)

Text(qsPanel, "GameFontNormalSmall", 8, QS_DY - 116):SetText("Duration:")
local qsDuration = 2   -- 1 = 2h, 2 = 8h, 3 = 24h, same tiers as the advisor tab
local qsDurBtns = {}
for i, d in ipairs({ { 1, "2h" }, { 2, "8h" }, { 3, "24h" } }) do
    local b = CreateFrame("Button", nil, qsPanel, "UIPanelButtonTemplate")
    b:SetSize(44, 18)
    b:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 70 + (i - 1) * 46, QS_DY - 113)
    b:SetText(d[2])
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b.value = d[1]
    b:SetScript("OnClick", function(self) qsDuration = self.value; RefreshQS() end)
    qsDurBtns[i] = b
end

-- Optional self-imposed cooldown - off by default. Separate from the AH's
-- own throttle (Ready()): this is for pacing yourself, not for working
-- around anything the server enforces.
local qsCooldownBox = CreateFrame("CheckButton", nil, qsPanel, "UICheckButtonTemplate")
qsCooldownBox:SetSize(22, 22)
qsCooldownBox:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 4, QS_DY - 140)
local qsCooldownLabel = Text(qsPanel, "GameFontNormalSmall", 26, QS_DY - 144)
qsCooldownLabel:SetText("Wait between sales:")
local qsCooldownBoxNum = CreateFrame("EditBox", nil, qsPanel, "InputBoxTemplate")
qsCooldownBoxNum:SetSize(36, 20)
qsCooldownBoxNum:SetPoint("LEFT", qsCooldownLabel, "RIGHT", 8, 0)
qsCooldownBoxNum:SetAutoFocus(false)
qsCooldownBoxNum:SetNumeric(true)
qsCooldownBoxNum:SetJustifyH("RIGHT")
qsCooldownBoxNum:SetText("3")
local qsCooldownSecLabel = Text(qsPanel, "GameFontNormalSmall", 0, 0)
qsCooldownSecLabel:SetPoint("LEFT", qsCooldownBoxNum, "RIGHT", 4, 0)
qsCooldownSecLabel:SetText("sec")

local function QSApplyCooldownEnabled()
    qsCooldownBoxNum:SetEnabled(qsCooldownBox:GetChecked() and true or false)
end

qsCooldownBox:SetScript("OnClick", function(self)
    if not AHWatchDB then AHWatchDB = {} end
    AHWatchDB.qsCooldownEnabled = self:GetChecked() and true or false
    QSApplyCooldownEnabled()
end)

local function QSCommitCooldownSec()
    if not AHWatchDB then AHWatchDB = {} end
    local n = tonumber(qsCooldownBoxNum:GetText())
    if not n or n < 0 then n = 3 end
    AHWatchDB.qsCooldownSec = n
    qsCooldownBoxNum:SetText(tostring(n))
    qsCooldownBoxNum:ClearFocus()
end
qsCooldownBoxNum:SetScript("OnEnterPressed", QSCommitCooldownSec)
qsCooldownBoxNum:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
qsCooldownBoxNum:SetScript("OnEditFocusLost", QSCommitCooldownSec)

local qsStatus = Text(qsPanel, "GameFontHighlightSmall", 8, QS_DY - 168, 330)
qsStatus:SetSpacing(2)
local qsPostedLabel = Text(qsPanel, "GameFontHighlightSmall", 8, QS_DY - 216, 330)

------------------------------------------------------------
-- Updating
------------------------------------------------------------

-- Break-even from the ledger: what your unsold units of an item cost
-- (bought with AH Watch), and the lowest price that gets that back after
-- the 5% cut. Posting below it takes a second press, so it's never by accident.
local function BreakEven(itemID, qty)
    if not ns.CostBasis then return nil end
    return ns.CostBasis(itemID, qty)
end
local beAck = nil   -- "itemID:price" you already confirmed posting below break-even
local function BelowBreakEven(itemID, price, qty)
    local each, _, be = BreakEven(itemID, qty)
    if each and price > 0 and price < be then return be end
end

local function Selected()
    for _, e in ipairs(items) do
        if e.itemID == selectedID then return e end
    end
end

local function Ago(t)
    local s = time() - (t or 0)
    if s < 90 then return "just now" end
    if s < 5400 then return math.floor(s / 60) .. " min ago" end
    if s < 172800 then return math.floor(s / 3600) .. " hr ago" end
    return math.floor(s / 86400) .. " days ago"
end

local function Deposit(e, qty)
    if not e or qty < 1 then return nil end
    local ok, v
    if e.commodity then
        ok, v = pcall(C_AuctionHouse.CalculateCommodityDeposit, e.itemID, duration, qty)
    elseif ItemLocation and e.slots[1] then
        local loc = ItemLocation:CreateFromBagAndSlot(e.slots[1].bag, e.slots[1].slot)
        ok, v = pcall(C_AuctionHouse.CalculateItemDeposit, loc, duration, qty)
    end
    return ok and v or nil
end

local function Qty()
    return tonumber(qtyBox:GetText() or "") or 0
end

local Refresh

local function RefreshDetail()
    local e = Selected()
    for i = 1, 4 do dLines[i]:SetText("") end
    if not e then
        sellVs:SetText("")
        sellLow:SetText("")
        dName:SetText("Click an item above to see its prices.")
        advice:SetText("")
        depositText:SetText("")
        postBtn:SetText("Post")
        postBtn:Disable()
        checkBtn:Disable()
        return
    end
    local a = e.analysis
    checkBtn:SetEnabled(ns.IsAHOpen())
    dName:SetText((e.link or e.name) .. "  x" .. e.count)

    local basis = (a.source == "auctionator") and "from Auctionator" or ((a.days or 0) .. " days saved")
    dLines[1]:SetText("Market price (" .. basis .. "): " ..
        (a.typical and Money(a.typical) or "|cff888888no history yet - run a full scan|r"))
    if a.low then
        dLines[2]:SetText("Cheapest listing: " .. Money(a.low) .. "  |cffaaaaaa(" .. (a.listed or 0) .. " listed, "
            .. (a.isLive and "checked " or "saved ") .. Ago(a.lowTime) .. ")|r")
    else
        dLines[2]:SetText("Cheapest listing: |cff888888unknown - click Check price|r")
    end
    dLines[3]:SetText("Vendor price: " .. (a.vendor > 0 and (Money(a.vendor) .. " each, " .. Money(a.vendor * e.count) .. " for all")
        or "|cff888888can't be sold to a vendor|r"))
    local paid, known, be = BreakEven(e.itemID, Qty() > 0 and Qty() or nil)
    if paid then
        dLines[4]:SetText("You paid " .. Money(paid) .. " each |cffaaaaaa(" .. known .. " unsold)|r - break-even "
            .. Money(be) .. " after the cut")
    elseif a.net then
        dLines[4]:SetText("You'd get after the 5% AH cut: " .. Money(a.net) .. " each, " .. Money(a.net * e.count) .. " for all")
    end

    -- The recommendation
    if a.verdict == "ah" then
        local mode = (AHWatchDB and AHWatchDB.sellMode) or "average"
        local text = "|cff33dd66Sell on the AH.|r Post at " .. Money(a.suggest) .. " each"
        if mode == "undercut" and a.bait then
            text = text .. " - 1c under where the real listings start, ignoring the bait below."
        elseif mode == "undercut" and a.low then
            text = text .. " - 1c under the cheapest, so yours sells first."
        elseif a.typical and mode ~= "undercut" then
            text = text .. " - the average price, rather than undercutting everyone else."
        elseif a.low then
            text = text .. " - 1c under the cheapest (no saved average yet)."
        else
            text = text .. " (nobody else is selling it right now)."
        end
        if a.bait then
            text = text .. string.format("\n|cffffcc00Possible bait:|r only %d listed at %s, %.0f%% under the next real listings (%s). Don't undercut it.",
                a.bait.qty, Money(a.bait.low), a.bait.pct, Money(a.bait.floor))
        elseif a.dumped then
            text = text .. "\n|cffffd100Note:|r the cheapest listing right now is unusually low (normally about "
                .. Money(a.typical) .. "). Someone may be dumping stock."
        end
        advice:SetText(text)
    elseif a.verdict == "vendor" then
        advice:SetText("|cffff9933Sell to a vendor.|r After the AH cut you'd only get " .. Money(a.net) .. " vs "
            .. Money(a.vendor) .. " from a vendor - not worth the deposit and the wait.")
    elseif a.verdict == "unknown-vendor" then
        advice:SetText("|cffaaaaaaNo AH price yet.|r Click Check price (or run a full scan). Vendor pays " .. Money(a.vendor) .. " each.")
    else
        advice:SetText("|cffaaaaaaNo AH price yet.|r Click Check price (or run a full scan).")
    end

    -- Quantity rules differ: stackable goods can be split, other items post one stack at a time
    if e.commodity then
        qtyNote:SetText("of " .. e.count)
        qtyBox:Enable()
        if Qty() > e.count then qtyBox:SetText(tostring(e.count)) end
    else
        qtyBox:SetText(tostring(e.slots[1] and e.slots[1].count or 1))
        qtyNote:SetText("one stack per click")
        qtyBox:Disable()
    end
    for _, b in ipairs(durBtns) do
        if b.value == duration then b:LockHighlight() else b:UnlockHighlight() end
        b.pbPrimary = (b.value == duration)
        b:SetText(b:GetText())
    end

    local qty = Qty()
    local dep = Deposit(e, qty)
    depositText:SetText(dep and ("Deposit: " .. Money(dep) .. "  |cffaaaaaa(you get it back if it sells)|r") or "")

    if pendingPost and pendingPost.warned then
        postBtn:SetText("Confirm post (the game warned the price looks low)")
        postBtn:Enable()
    else
        local price = priceMoney.GetValue()
        local below = BelowBreakEven(e.itemID, price, qty)
        sellVs:SetText(below and ("|cffff5555below your break-even (" .. Money(below) .. ")|r")
            or (ns.VsMarket and ns.VsMarket(e.itemID, price) or ""))
        sellLow:SetText(ns.VsLowest and ns.VsLowest(e.itemID, price) or "")
        if below and beAck == (e.itemID .. ":" .. price) then
            postBtn:SetText("Post anyway - " .. qty .. " at a loss (break-even " .. Money(below) .. ")")
        else
            postBtn:SetText(price > 0 and qty > 0 and ("Post " .. qty .. " for " .. Money(price) .. " each") or "Set a price and quantity")
        end
        postBtn:SetEnabled(ns.IsAHOpen() and price > 0 and qty > 0)
    end
end

function Refresh()
    if not panel:IsShown() then return end
    for i = 1, ROWS do
        local b, e = rows[i], items[offset + i]
        if e then
            local a = e.analysis
            b.entry = e
            b.icon:SetTexture(e.icon)
            b.name:SetText(e.name .. (e.count > 1 and ("  |cffaaaaaax" .. e.count .. "|r") or ""))
            local now = a.low and ("now " .. Money(a.low)) or (a.typical and ("avg " .. Money(a.typical))) or "no AH price"
            b.info:SetText(now .. "  |cffaaaaaavendor " .. (a.vendor > 0 and Money(a.vendor) or "-") .. "|r")
            if a.verdict == "ah" then
                local gain = (a.net - a.vendor) * e.count
                b.badge:SetText("|cff33dd66AH +" .. Money(math.max(gain, 0)) .. "|r")
            elseif a.verdict == "vendor" then
                b.badge:SetText("|cffff9933Vendor|r")
            else
                b.badge:SetText("|cff888888No data|r")
            end
            b.sel:SetShown(e.itemID == selectedID)
            b:Show()
        else
            b:Hide()
        end
    end
    emptyText:SetShown(#items == 0)
    scrollHint:SetText(#items > ROWS and string.format("Showing %d-%d of %d (scroll for more)", offset + 1,
        math.min(offset + ROWS, #items), #items) or "")
    RefreshDetail()
end

-- Prices YOU typed, per item, kept between sessions. A price box is only
-- ever filled with your own last price for that item - never a suggestion,
-- unless you press "Suggested" yourself.
local function MyPrice(itemID)
    local t = AHWatchDB and AHWatchDB.myPrices
    return t and itemID and t[itemID] or nil
end
local function RememberPrice(itemID, copper)
    if not itemID or not AHWatchDB then return end
    AHWatchDB.myPrices = AHWatchDB.myPrices or {}
    AHWatchDB.myPrices[itemID] = (copper and copper > 0) and copper or nil
end
ns.MyPrice, ns.RememberPrice = MyPrice, RememberPrice

local function Select(e)
    selectedID = e.itemID
    pendingPost = nil
    e.commodity = IsCommodity(e)
    priceMoney.SetValue(MyPrice(e.itemID) or 0)
    qtyBox:SetText(tostring(e.commodity and e.count or (e.slots[1] and e.slots[1].count or 1)))
    if ns.ShowGraph then ns.ShowGraph(e.itemID, nil) end
    Refresh()
end

------------------------------------------------------------
-- Actions
------------------------------------------------------------

local function CheckPrice()
    local e = Selected()
    if not e or not ns.IsAHOpen() then return end
    if not ns.Ready() then return end
    -- Same search pacing as the rest of the addon, so the server doesn't time you out
    if ns.CanSearch and not ns.CanSearch() then
        Msg(string.format("waiting so the server doesn't time you out - try again in %.1fs.",
            math.max(0.1, ns.SearchWait and ns.SearchWait() or 1)))
        return
    end
    if ns.NoteSearch then ns.NoteSearch() end
    ns.sellSearchID = e.itemID
    -- Use the exact item (item level etc.) so gear searches find the right listings
    local key
    if C_AuctionHouse.GetItemKeyFromItem and ItemLocation and e.slots[1] then
        local okKey, k = pcall(C_AuctionHouse.GetItemKeyFromItem, ItemLocation:CreateFromBagAndSlot(e.slots[1].bag, e.slots[1].slot))
        if okKey then key = k end
    end
    key = key or C_AuctionHouse.MakeItemKey(e.itemID)
    local sorts = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } }
    local ok, err = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
    if not ok then Msg("price check failed: " .. tostring(err)) end
end

-- Results of "Check price" (your own listings are ignored, so you never undercut yourself)
function ns.OnSellResults(itemID, rowsIn, isCommodity)
    local low, qty = nil, 0
    for _, r in ipairs(rowsIn) do
        local q = r.quantity or 1
        local unit = isCommodity and r.unitPrice or (r.buyout and r.buyout / math.max(q, 1))
        if unit and not r.own then
            if not low or unit < low then low = unit end
            qty = qty + q
        end
    end
    live[itemID] = { low = low and math.floor(low) or nil, qty = qty, time = time() }
    if ns.OnMineResults then ns.OnMineResults(itemID) end
    for _, e in ipairs(items) do
        if e.itemID == itemID then
            e.analysis = Analyze(e)
        end
    end
    Refresh()
end

local function Post()
    local e = Selected()
    if not e or not ns.IsAHOpen() or not ItemLocation then return end
    if not ns.Ready() then return end
    local price, qty = priceMoney.GetValue(), Qty()
    if price <= 0 or qty <= 0 then return end
    local s = e.slots[1]
    local loc = ItemLocation:CreateFromBagAndSlot(s.bag, s.slot)
    local ok, err
    if pendingPost and not pendingPost.warned then return end   -- still waiting to hear back
    if not pendingPost then
        local below = BelowBreakEven(e.itemID, price, qty)
        local key = e.itemID .. ":" .. price
        if below and beAck ~= key then
            beAck = key
            Msg("that's below your break-even of " .. Money(below) .. " each (what you paid, plus the AH cut). "
                .. "Click Post again to post it anyway.")
            RefreshDetail()
            return
        end
    end
    if pendingPost then
        local p = pendingPost
        pendingPost = nil
        if p.commodity then
            ok, err = pcall(C_AuctionHouse.ConfirmPostCommodity, p.loc, p.duration, p.qty, p.price)
        else
            ok, err = pcall(C_AuctionHouse.ConfirmPostItem, p.loc, p.duration, p.qty, nil, p.price * p.qty)
        end
    elseif e.commodity then
        qty = math.min(qty, e.count)
        pendingPost = { commodity = true, loc = loc, duration = duration, qty = qty, price = price }
        ok, err = pcall(C_AuctionHouse.PostCommodity, loc, duration, qty, price)
    else
        qty = s.count
        pendingPost = { commodity = false, loc = loc, duration = duration, qty = qty, price = price }
        ok, err = pcall(C_AuctionHouse.PostItem, loc, duration, qty, nil, price * qty)
    end
    if not ok then
        pendingPost = nil
        Msg("couldn't post: " .. tostring(err))
    end
    if ok then Msg("posting " .. qty .. "x " .. (e.name or "item") .. " at " .. Money(price) .. " each...") end
    -- Wait to hear back: "created" = done, "warning" = one more click to confirm
    local mine = pendingPost
    C_Timer.After(3, function()
        if mine and pendingPost == mine and not mine.warned then
            pendingPost = nil
            Msg("the auction house didn't confirm that post. Check your Auctions tab - if it isn't there, send Claude a screenshot of any red error text.")
            RefreshDetail()
        end
    end)
    RefreshDetail()
end

------------------------------------------------------------
-- Quick Sell logic
------------------------------------------------------------

-- Finds the biggest bag stack of an item right now (fresh each call, since
-- a stack shrinks or disappears after each post) - repeated presses drain
-- the biggest stack first.
local function FindBestStack(itemID)
    local lastBag = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
    local best
    for bag = 0, lastBag do
        local slots = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isBound then
                local count = info.stackCount or 1
                if not best or count > best.count then
                    best = { bag = bag, slot = slot, count = count }
                end
            end
        end
    end
    return best
end

function RefreshQS()
    local q = (qsSearchBox:GetText() or ""):lower()
    local matches = {}
    for _, e in ipairs(items) do
        if q == "" or (e.name and e.name:lower():find(q, 1, true)) then
            matches[#matches + 1] = e
        end
    end
    qsMatchCount = #matches
    qsOffset = math.max(0, math.min(qsOffset, #matches - QS_ROWS))
    qsScrollText:SetText(#matches > QS_ROWS and string.format("%d-%d of %d", qsOffset + 1,
        math.min(qsOffset + QS_ROWS, #matches), #matches) or "")
    for i, b in ipairs(qsRows) do
        local e = matches[qsOffset + i]
        if e then
            b.icon:SetTexture(e.icon)
            b.name:SetText(e.name .. "  |cffaaaaaa(x" .. e.count .. " in bags)|r")
            b.sel:SetShown(e.itemID == qsItemID)
            b.entry = e
            b:Show()
        else
            b:Hide()
        end
    end
    qsEmptyText:SetShown(#matches == 0)

    for _, d in ipairs(qsDurBtns) do
        if d.value == qsDuration then d:LockHighlight() else d:UnlockHighlight() end
    end

    -- The Buy/Sell tabs share one button+keybind with this tab - keep its
    -- label honest about what pressing it will actually do right now.
    local function SetGoLabel(label)
        if ns.CurrentTab and ns.CurrentTab() == "quicksell" and _G.AHWatchGoButton then
            local key = (ns.GetKey and ns.GetKey()) or ""
            if ns.KeyName then key = ns.KeyName(key) end
            _G.AHWatchGoButton:SetText(label .. "  |cff888888(" .. key .. ")|r")
        end
    end

    if not qsItemID then
        qsVs:SetText("")
        qsLow:SetText("")
        qsSelectedText:SetText("Selected: |cffaaaaaanothing yet - click an item above|r")
        qsStatus:SetText("")
        qsPostedLabel:SetText("")
        SetGoLabel("Quick Sale - pick an item")
        return
    end

    local haveCount = (GetItemCount and GetItemCount(qsItemID)) or 0
    qsSelectedText:SetText("Selected: " .. (qsItemName or "?") .. "  |cffaaaaaa(" .. haveCount .. " in bags)|r")

    local price, qty = qsPriceMoney.GetValue(), QSQty()
    local qsBelow = BelowBreakEven(qsItemID, price, qty)
    local qsPaid, qsKnown, qsBE = BreakEven(qsItemID, qty)
    qsVs:SetText(qsBelow and ("|cffff5555below your break-even (" .. Money(qsBelow) .. ")|r")
        or (ns.VsMarket and ns.VsMarket(qsItemID, price) or ""))
    qsLow:SetText(ns.VsLowest and ns.VsLowest(qsItemID, price) or "")
    local cooldownWait = 0
    if AHWatchDB and AHWatchDB.qsCooldownEnabled then
        cooldownWait = (AHWatchDB.qsCooldownSec or 3) - (GetTime() - lastQSPost)
    end
    if qsPendingPost and qsPendingPost.warned then
        qsStatus:SetText("|cffffcc00The price looks low to the game - press your key again to confirm it.|r")
    elseif price <= 0 then
        qsStatus:SetText("|cffff5555Set a price each above 0 first.|r")
    elseif haveCount <= 0 then
        qsStatus:SetText("|cffff5555Out of " .. (qsItemName or "that item") .. " - nothing left in your bags.|r")
    elseif cooldownWait > 0 then
        qsStatus:SetText(string.format("|cff888888Waiting %.0fs before the next sale...|r", cooldownWait))
    elseif qsBelow and beAck ~= (qsItemID .. ":" .. price) then
        qsStatus:SetText("|cffff5555Below your break-even of " .. Money(qsBelow) .. " each.|r Press once to be warned, "
            .. "then again to post anyway.")
    else
        qsStatus:SetText((qsBelow and "|cffff5555Posting at a loss.|r " or "") .. "Ready - press your Buy-tab key to post "
            .. math.min(qty, haveCount) .. "x " .. (qsItemName or "item") .. " at " .. Money(price) .. " each ("
            .. ({ "2h", "8h", "24h" })[qsDuration] .. ").")
    end
    if qsPaid then
        qsStatus:SetText(qsStatus:GetText() .. "\n|cffaaaaaaYou paid " .. Money(qsPaid) .. " each (" .. qsKnown
            .. " unsold) - break-even " .. Money(qsBE) .. ".|r")
    end
    qsPostedLabel:SetText(((AHWatchDB and AHWatchDB.qsPosted) or 0) > 0
        and ("Posted this session: " .. (AHWatchDB.qsPosted or 0)) or "")

    if qsPendingPost and qsPendingPost.warned then
        SetGoLabel("Confirm Quick Sale")
    elseif price <= 0 then
        SetGoLabel("Quick Sale - set a price")
    elseif haveCount <= 0 then
        SetGoLabel("Quick Sale - none left")
    elseif cooldownWait > 0 then
        SetGoLabel(string.format("Quick Sale - wait %.0fs", cooldownWait))
    else
        SetGoLabel("Quick Sale")
    end
end

function QuickSellGo()
    if not ns.IsAHOpen() then Msg("open the auction house first.") return end
    if not qsItemID then Msg("pick an item to quick-sell first.") return end
    if not ns.Ready() then return end
    if qsPendingPost and not qsPendingPost.warned then return end   -- still waiting to hear back

    local ok, err
    if qsPendingPost then
        -- Second press after a "price looks low" warning: confirm it as-is
        local p = qsPendingPost
        qsPendingPost = nil
        if p.commodity then
            ok, err = pcall(C_AuctionHouse.ConfirmPostCommodity, p.loc, p.duration, p.qty, p.price)
        else
            ok, err = pcall(C_AuctionHouse.ConfirmPostItem, p.loc, p.duration, p.qty, nil, p.price * p.qty)
        end
    else
        if AHWatchDB and AHWatchDB.qsCooldownEnabled then
            local wait = (AHWatchDB.qsCooldownSec or 3) - (GetTime() - lastQSPost)
            if wait > 0 then return end   -- self-imposed pacing, not the AH's throttle - no spam, just silently ignore
        end
        local price = qsPriceMoney.GetValue()
        if price <= 0 then Msg("set a price each first.") return end
        local below = BelowBreakEven(qsItemID, price, QSQty())
        if below and beAck ~= (qsItemID .. ":" .. price) then
            beAck = qsItemID .. ":" .. price
            Msg("that's below your break-even of " .. Money(below) .. " each. Press again to post it anyway.")
            RefreshQS()
            return
        end
        local stack = FindBestStack(qsItemID)
        if not stack or stack.count <= 0 then
            Msg("out of " .. (qsItemName or "that item") .. " - nothing left in your bags to sell.")
            RefreshQS()
            return
        end
        local loc = ItemLocation:CreateFromBagAndSlot(stack.bag, stack.slot)
        local commodity = false
        if C_AuctionHouse.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
            local okc, status = pcall(C_AuctionHouse.GetItemCommodityStatus, loc)
            commodity = okc and status == Enum.ItemCommodityStatus.Commodity
        end
        -- Commodities post exactly the amount you asked for, capped to what's
        -- in the biggest stack. Non-commodities (gear, etc.) always post the
        -- whole located stack, same as the advisor Sell tab does - the game
        -- doesn't let those be split per unit the way commodities can.
        local qty = commodity and math.min(QSQty(), stack.count) or stack.count
        qsPendingPost = { commodity = commodity, loc = loc, duration = qsDuration, qty = qty, price = price }
        if commodity then
            ok, err = pcall(C_AuctionHouse.PostCommodity, loc, qsDuration, qty, price)
        else
            ok, err = pcall(C_AuctionHouse.PostItem, loc, qsDuration, qty, nil, price * qty)
        end
        if ok then
            lastQSPost = GetTime()
            if AHWatchDB and AHWatchDB.qsCooldownEnabled then
                -- Tick the status text down while the cooldown is running
                local mySeq = lastQSPost
                C_Timer.NewTicker(0.5, function(self)
                    if lastQSPost ~= mySeq or not (AHWatchDB and AHWatchDB.qsCooldownEnabled) then
                        self:Cancel()
                        return
                    end
                    if (AHWatchDB.qsCooldownSec or 3) - (GetTime() - lastQSPost) <= 0 then
                        self:Cancel()
                    end
                    RefreshQS()
                end)
            end
        end
    end

    if not ok then
        Msg("couldn't post: " .. tostring(err))
        qsPendingPost = nil
    elseif qsPendingPost then
        Msg("posting " .. qsPendingPost.qty .. "x " .. (qsItemName or "item") .. " at " .. Money(qsPendingPost.price) .. " each...")
        if not AHWatchDB then AHWatchDB = {} end
        AHWatchDB.qsPosted = (AHWatchDB.qsPosted or 0) + qsPendingPost.qty
    end
    local mine = qsPendingPost
    if mine then
        C_Timer.After(3, function()
            if mine and qsPendingPost == mine and not mine.warned then
                qsPendingPost = nil
                Msg("the auction house didn't confirm that post. Check your Auctions tab - if it isn't there, send Claude a screenshot of any red error text.")
                RefreshQS()
            end
        end)
    end
    ScanBags()
    RefreshQS()
end
ns.QuickSellGo = QuickSellGo

------------------------------------------------------------
-- Wiring
------------------------------------------------------------

for _, b in ipairs(rows) do
    b:SetScript("OnClick", function(self)
        if not self.entry then return end
        if IsShiftKeyDown() and ns.SearchInAH then ns.SearchInAH(self.entry.itemID, self.entry.name) return end
        Select(self.entry)
    end)
end
panel:SetScript("OnMouseWheel", function(_, delta)
    offset = math.max(0, math.min(math.max(0, #items - ROWS), offset - delta))
    Refresh()
end)
rescanBtn:SetScript("OnClick", function() ScanBags(); Refresh() end)
checkBtn:SetScript("OnClick", CheckPrice)
useSuggested:SetScript("OnClick", function()
    local e = Selected()
    if e and e.analysis.suggest then priceMoney.SetValue(e.analysis.suggest); RefreshDetail() end
end)
local function UpdateModeBtn()
    modeBtn:SetText(SellMode() == "undercut" and "Mode: Undercut" or "Mode: Average")
end
modeBtn:SetScript("OnClick", function()
    AHWatchDB.sellMode = (SellMode() == "undercut") and "average" or "undercut"
    UpdateModeBtn()
    local e = Selected()
    if e then
        e.analysis = Analyze(e)
    end
    Refresh()
end)
modeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Pricing mode")
    GameTooltip:AddLine("Average: post at the average price instead of undercutting.", 1, 1, 1, true)
    GameTooltip:AddLine("Undercut: post 1c under the cheapest listing for the fastest sale.", 1, 1, 1, true)
    GameTooltip:Show()
end)
modeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
UpdateModeBtn()
priceMoney.onChange = function(v) RememberPrice(selectedID, v); RefreshDetail() end
qtyBox:SetScript("OnTextChanged", function(self, userInput)
    local e = Selected()
    if userInput and e and Qty() > e.count then self:SetText(tostring(e.count)) end
    RefreshDetail()
end)
qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
local function StepQty(dir)
    local e = Selected()
    if not e or not e.commodity then return end
    local step = IsShiftKeyDown() and 10 or 1
    qtyBox:SetText(tostring(math.max(1, math.min(e.count, Qty() + dir * step))))
end
qtyUp:SetScript("OnClick", function() StepQty(1) end)
qtyDown:SetScript("OnClick", function() StepQty(-1) end)
for _, b in ipairs(durBtns) do
    b:SetScript("OnClick", function(self) duration = self.value; RefreshDetail() end)
end
postBtn:SetScript("OnClick", Post)

qsSearchBox:SetScript("OnTextChanged", function() qsOffset = 0; RefreshQS() end)

-- Mouse wheel anywhere on the Quick Sell panel scrolls the bag list
-- (Shift scrolls a whole page)
function ns.ScrollQSList(delta)
    local step = IsShiftKeyDown() and QS_ROWS or 1
    qsOffset = math.max(0, math.min(math.max(0, qsMatchCount - QS_ROWS), qsOffset - delta * step))
    RefreshQS()
end
for _, b in ipairs(qsRows) do
    b:SetScript("OnClick", function(self)
        if not self.entry then return end
        if IsShiftKeyDown() and ns.SearchInAH then ns.SearchInAH(self.entry.itemID, self.entry.name) return end
        qsItemID, qsItemName, qsItemIcon = self.entry.itemID, self.entry.name, self.entry.icon
        -- Your own last price for this item, or empty - never a suggestion
        qsPriceMoney.SetValue(MyPrice(qsItemID) or 0)
        RefreshQS()
    end)
    b:SetScript("OnEnter", function(self)
        if self.entry and self.entry.slots[1] then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetBagItem(self.entry.slots[1].bag, self.entry.slots[1].slot)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
qsPriceMoney.onChange = function(v) RememberPrice(qsItemID, v); RefreshQS() end
-- Only fills in the suggested price when you press it
qsSuggested:SetScript("OnClick", function()
    if not qsItemID then return end
    for _, e in ipairs(items) do
        if e.itemID == qsItemID and e.analysis and e.analysis.suggest then
            qsPriceMoney.SetValue(e.analysis.suggest)
            RememberPrice(qsItemID, e.analysis.suggest)
            RefreshQS()
            return
        end
    end
end)
qsQtyBox:SetScript("OnTextChanged", RefreshQS)

------------------------------------------------------------
-- Flips tab
------------------------------------------------------------

local FLIP_TAB_ROWS = 24
local FLIP_ROW_H = 21
local flipOffset = 0
local flipList = {}

local flipsIntro = Text(flipsPanel, "GameFontNormalSmall", 8, -6, 236)
flipsIntro:SetWordWrap(false)
-- One list of deals from your latest scan and searches, best gold first:
-- price gaps (a few cheap items, then a jump - resell on the AH) and vendor
-- deals (listed under what a vendor pays). "Watch" puts the item on your
-- watch list so Buy instantly grabs it: gap deals in margin mode (the max
-- follows real supply), vendor deals at the price shown.
local DEAL_MARGIN = 15
local flipsInfo = Text(flipsPanel, "GameFontDisableSmall", 8, -22, 250)
flipsInfo:SetWordWrap(false)
local flipsRefreshBtn = CreateFrame("Button", nil, flipsPanel, "UIPanelButtonTemplate")
flipsRefreshBtn:SetSize(70, 18)
flipsRefreshBtn:SetPoint("TOPRIGHT", flipsPanel, "TOPRIGHT", -6, -18)
flipsRefreshBtn:SetText("Refresh")
flipsRefreshBtn:SetNormalFontObject(GameFontNormalSmall)
flipsRefreshBtn:SetHighlightFontObject(GameFontHighlightSmall)

-- Column headings
local FH = -44
Text(flipsPanel, "GameFontNormalSmall", 26, FH, 120):SetText("Item")
local hBuy = Text(flipsPanel, "GameFontNormalSmall", 150, FH, 60); hBuy:SetJustifyH("RIGHT"); hBuy:SetText("Buy at")
local hSell = Text(flipsPanel, "GameFontNormalSmall", 212, FH, 60); hSell:SetJustifyH("RIGHT"); hSell:SetText("Next")
local hPct = Text(flipsPanel, "GameFontNormalSmall", 268, FH, 34); hPct:SetJustifyH("RIGHT"); hPct:SetText("Gain")

local flipTabRows = {}
for i = 1, FLIP_TAB_ROWS do
    local b = CreateFrame("Button", nil, flipsPanel)
    b:SetSize(340, FLIP_ROW_H - 1)
    b:SetPoint("TOPLEFT", flipsPanel, "TOPLEFT", 4, FH - 16 - (i - 1) * FLIP_ROW_H)
    if i % 2 == 0 then
        local stripe = b:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.04)
    end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", 2, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("LEFT", 22, 0)
    b.name:SetWidth(122)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.buy = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.buy:SetPoint("LEFT", 146, 0)
    b.buy:SetWidth(60)
    b.buy:SetJustifyH("RIGHT")
    b.sell = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.sell:SetPoint("LEFT", 208, 0)
    b.sell:SetWidth(60)
    b.sell:SetJustifyH("RIGHT")
    b.pct = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.pct:SetPoint("LEFT", 268, 0)
    b.pct:SetWidth(32)
    b.pct:SetJustifyH("RIGHT")
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    -- One click: puts it on the watch list (gap deals in margin mode) and switches to Buy
    b.buyBtn = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
    b.buyBtn:SetSize(40, 16)
    b.buyBtn:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.buyBtn:SetText("Watch")
    b.buyBtn:SetNormalFontObject(GameFontHighlightSmall)
    b.buyBtn:SetHighlightFontObject(GameFontHighlightSmall)
    b.buyBtn:SetScript("OnClick", function()
        local fl = b.flip
        if not fl then return end
        local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(fl.itemID)) or ("Item " .. fl.itemID)
        if fl.vendorFlip then
            if ns.QuickBuySetup and ns.QuickBuySetup(fl.itemID, name, fl.current) then
                Msg("then sell it to any vendor for " .. Money(fl.typical) .. " each - no AH cut.")
            end
        elseif ns.WatchWithMargin then
            ns.WatchWithMargin(fl.itemID, name, (AHWatchDB and AHWatchDB.dealMargin) or DEAL_MARGIN)
        end
    end)
    b:SetScript("OnClick", function(self)
        if self.flip and IsShiftKeyDown() and ns.SearchInAH then ns.SearchInAH(self.flip.itemID) return end
        if self.flip and ns.ShowGraph then ns.ShowGraph(self.flip.itemID, nil) end
    end)
    b:SetScript("OnEnter", function(self)
        local fl = self.flip
        if not fl then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(fl.itemID)
        GameTooltip:AddLine(" ")
        if fl.vendorFlip then
            GameTooltip:AddDoubleLine("Under vendor price:", fl.dealQty .. " for " .. Money(fl.dealCost), 1, 1, 1, 0.4, 1, 0.4)
            GameTooltip:AddDoubleLine("Most you'd pay each:", Money(fl.current), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("A vendor pays:", Money(fl.typical) .. " each", 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Sell them to a vendor, you'd make:", Money(fl.profit) .. " (no AH cut)", 1, 1, 1, 0.4, 1, 0.4)
            if fl.seen then
                local mins = math.floor((time() - fl.seen) / 60)
                GameTooltip:AddDoubleLine("Seen:", mins < 1 and "just now" or (mins .. " min ago"), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
            end
            GameTooltip:AddLine("Vendor deal.  Click: show graph.  Shift-click: search it in the auction house.  Watch: add to your watch list at this price.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
            return
        end
        GameTooltip:AddDoubleLine("Cheap group:", fl.dealQty .. " for " .. Money(fl.dealCost), 1, 1, 1, 0.4, 1, 0.4)
        GameTooltip:AddDoubleLine("Prices:", Money(fl.low) .. " to " .. Money(fl.current), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Next listing:", Money(fl.typical), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Resell 1c under it, you'd make:", Money(fl.profit) .. " after the cut", 1, 1, 1, 0.4, 1, 0.4)
        GameTooltip:AddDoubleLine("Listed now:", tostring(fl.qty), 1, 1, 1, 1, 1, 1)
        if fl.seen then
            local mins = math.floor((time() - fl.seen) / 60)
            GameTooltip:AddDoubleLine("Seen:", mins < 1 and "just now" or (mins .. " min ago"), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
        end
        GameTooltip:AddLine("Price-gap deal.  Click: show graph.  Shift-click: search it in the auction house.  Watch: add to your watch list for "
            .. ((AHWatchDB and AHWatchDB.dealMargin) or DEAL_MARGIN) .. "% profit - its max follows the market.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    flipTabRows[i] = b
end

local flipsEmpty = Text(flipsPanel, "GameFontDisable", 12, FH - 40, 320)
flipsEmpty:SetText("No deals found in the last 6 hours.\n\nPress Full scan (Price history panel) - price gaps "
    .. "(1-10 cheap items, then a 15%+ jump) and listings under what a vendor pays will show up here.")
local flipsScroll = Text(flipsPanel, "GameFontDisableSmall", 8, FH - 20 - FLIP_TAB_ROWS * FLIP_ROW_H, 330)

local function ShortM(c) return (ns.ShortMoney and ns.ShortMoney(c)) or Money(c) end

function ns.RefreshFlipsTab()
    if not flipsPanel:IsShown() then return end
    flipList = {}
    for _, fl in ipairs((ns.TopFlips and ns.TopFlips(100)) or {}) do flipList[#flipList + 1] = fl end
    for _, fl in ipairs((ns.TopVendorFlips and ns.TopVendorFlips(100)) or {}) do flipList[#flipList + 1] = fl end
    table.sort(flipList, function(x, y) return (x.profit or 0) > (y.profit or 0) end)
    flipsIntro:SetText("Deals from your latest scan, best gold first:")
    hSell:SetText("Sell at")
    flipOffset = math.max(0, math.min(flipOffset, #flipList - FLIP_TAB_ROWS))
    for i, b in ipairs(flipTabRows) do
        local fl = flipList[flipOffset + i]
        if fl then
            b.flip = fl
            local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(fl.itemID)) or ("Item " .. fl.itemID)
            local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(fl.itemID)) or "Interface\\Icons\\INV_Misc_QuestionMark"
            b.icon:SetTexture(icon)
            b.name:SetText(name .. (fl.dealQty and (" |cffaaaaaax" .. fl.dealQty .. "|r") or "")
                .. (fl.vendorFlip and " |cffffd100(vendor)|r" or ""))
            b.buy:SetText(ShortM(fl.current))
            b.sell:SetText(ShortM(fl.typical))
            b.pct:SetText(string.format("|cff33dd66+%.0f%%|r", fl.pct))
            b:Show()
        else
            b.flip = nil
            b:Hide()
        end
    end
    flipsEmpty:SetShown(#flipList == 0)
    local info = AHWatchPrices and AHWatchPrices.lastScanInfo
    local ago = info and info.t and math.floor((time() - info.t) / 60)
    flipsInfo:SetText(#flipList .. " found" .. (ago and ("  -  last full scan " .. (ago < 1 and "just now"
        or ago < 120 and (ago .. " min ago") or (math.floor(ago / 60) .. " hr ago"))) or "  -  no full scan yet"))
    flipsScroll:SetText(#flipList > FLIP_TAB_ROWS and string.format("Showing %d-%d of %d (scroll for more)",
        flipOffset + 1, math.min(flipOffset + FLIP_TAB_ROWS, #flipList), #flipList) or "")
end

flipsPanel:EnableMouseWheel(true)
flipsPanel:SetScript("OnMouseWheel", function(_, delta)
    local step = IsShiftKeyDown() and FLIP_TAB_ROWS or 3
    flipOffset = math.max(0, math.min(math.max(0, #flipList - FLIP_TAB_ROWS), flipOffset - delta * step))
    ns.RefreshFlipsTab()
end)
flipsRefreshBtn:SetScript("OnClick", function() ns.RefreshFlipsTab() end)

local function SetTab(name)
    if AHWatchDB then AHWatchDB.tab = name end
    -- Let go of any text box from the tab being left, so keys (and your
    -- keybind) don't go to a box that's now hidden
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    if focus and focus.ClearFocus then focus:ClearFocus() end
    local sell, quick, flips, mine = (name == "sell"), (name == "quicksell"), (name == "flips"), (name == "mine")
    local buy = not sell and not quick and not flips and not mine
    panel:SetShown(sell)
    qsPanel:SetShown(quick)
    flipsPanel:SetShown(flips)
    if ns.SetMineShown then ns.SetMineShown(mine) end
    if ns.SetBuyOverlaysShown then ns.SetBuyOverlaysShown(buy) end
    tabSell.pbPrimary, tabBuy.pbPrimary, tabQS.pbPrimary, tabFlips.pbPrimary, tabMine.pbPrimary = sell, buy, quick, flips, mine
    for _, t in ipairs({ { tabBuy, buy }, { tabSell, sell }, { tabQS, quick }, { tabFlips, flips }, { tabMine, mine } }) do
        if t[2] then t[1]:LockHighlight() else t[1]:UnlockHighlight() end
    end
    tabSell:SetText("Sell"); tabBuy:SetText("Buy"); tabQS:SetText("Quick Sell"); tabFlips:SetText("Deals"); tabMine:SetText("Mine")   -- lets the trader look recolor them
    if mine then
        -- Mine.lua fills itself in when shown
    elseif flips then
        flipOffset = 0
        ns.RefreshFlipsTab()
    elseif sell then
        ScanBags()
        Refresh()
    elseif quick then
        ScanBags()
        RefreshQS()
    elseif ns.Update then
        -- Back on the Buy tab - let AHWatch.lua reclaim the shared button's label
        ns.Update()
    end
end
tabBuy:SetScript("OnClick", function() SetTab("buy") end)
tabSell:SetScript("OnClick", function() SetTab("sell") end)
tabQS:SetScript("OnClick", function() SetTab("quicksell") end)
tabFlips:SetScript("OnClick", function() SetTab("flips") end)
tabMine:SetScript("OnClick", function() SetTab("mine") end)
tabMine:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("My auctions", 1, 1, 1)
    GameTooltip:AddLine("Your listings, with the ones someone has undercut first.", 1, 0.9, 0.6, true)
    GameTooltip:Show()
end)
tabMine:SetScript("OnLeave", function() GameTooltip:Hide() end)
ns.SetTab = SetTab

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "BAG_UPDATE_DELAYED", "AUCTION_HOUSE_SHOW", "GET_ITEM_INFO_RECEIVED",
    "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR", "AUCTION_HOUSE_AUCTION_CREATED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local refreshQueued = false
local tabRestored = false
ev:SetScript("OnEvent", function(_, e, a1)
    if e == "AUCTION_HOUSE_SHOW" and not tabRestored then
        -- Open on whichever tab you used last
        tabRestored = true
        SetTab((AHWatchDB and AHWatchDB.tab) or "buy")
        -- Restore the Quick Sell cooldown option
        local enabled = AHWatchDB and AHWatchDB.qsCooldownEnabled
        qsCooldownBox:SetChecked(enabled and true or false)
        qsCooldownBoxNum:SetText(tostring((AHWatchDB and AHWatchDB.qsCooldownSec) or 3))
        QSApplyCooldownEnabled()
    end
    if e == "ADDON_LOADED" then
        return
    elseif e == "AUCTION_HOUSE_POST_WARNING" then
        -- The game thinks the price is suspiciously low; one more press confirms it
        if pendingPost then
            pendingPost.warned = true
            RefreshDetail()
        elseif qsPendingPost then
            qsPendingPost.warned = true
            RefreshQS()
        end
    elseif e == "AUCTION_HOUSE_AUCTION_CREATED" then
        if pendingPost then
            pendingPost = nil
            local sel = Selected()
            Msg("posted " .. ((sel and sel.name) or "your item") .. ".")
        elseif qsPendingPost then
            qsPendingPost = nil
            Msg("posted " .. (qsItemName or "your item") .. ".")
        end
    elseif e == "AUCTION_HOUSE_POST_ERROR" then
        pendingPost = nil
        qsPendingPost = nil
        Msg("the auction house couldn't post that item.")
        RefreshDetail()
        RefreshQS()
    elseif (panel:IsShown() or qsPanel:IsShown())
        and (e == "BAG_UPDATE_DELAYED" or e == "AUCTION_HOUSE_SHOW" or e == "GET_ITEM_INFO_RECEIVED") then
        -- Item info can arrive in bursts; rescan once things settle
        if refreshQueued then return end
        refreshQueued = true
        C_Timer.After(0.3, function()
            refreshQueued = false
            ScanBags()
            if panel:IsShown() then Refresh() end
            if qsPanel:IsShown() then RefreshQS() end
        end)
    end
end)
