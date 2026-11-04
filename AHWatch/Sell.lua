-- AHWatch Sell tab
-- Scans your bags for things you can put on the auction house, compares the
-- auction house price with the vendor price, suggests a price that should sell
-- quickly without giving money away, and lets you post from the same screen.
--
-- Note: the auction house never shows what items actually SOLD for, only what
-- they're listed at. "Average" here is the average cheapest listing from the
-- price history this addon has saved.

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
tabQS:SetSize(78, 18)
tabQS:SetText("Quick Sell")
tabQS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -3)
tabSell:SetPoint("RIGHT", tabQS, "LEFT", -2, 0)
tabBuy:SetPoint("RIGHT", tabSell, "LEFT", -2, 0)
for _, t in ipairs({ tabBuy, tabSell, tabQS }) do
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
qsPanel:Hide()
local qsPanelBase = qsPanel:CreateTexture(nil, "BACKGROUND", nil, -8)
qsPanelBase:SetAllPoints()
qsPanelBase:SetColorTexture(0, 0, 0, 1)
local qsPanelBg = qsPanel:CreateTexture(nil, "BACKGROUND", nil, -7)
qsPanelBg:SetAllPoints()

function ns.SkinSellPanel(skinned, mode)
    local function ColorBoth(r, g, b, a)
        panelBg:SetColorTexture(r, g, b, a)
        qsPanelBg:SetColorTexture(r, g, b, a)
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
        for _, bg in ipairs({ panelBg, qsPanelBg }) do
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

    -- Typical price: average of each day's cheapest listing
    if hist and hist.d and #hist.d > 0 then
        local sum = 0
        for _, d in ipairs(hist.d) do sum = sum + d[2] end
        a.typical = math.floor(sum / #hist.d)
        a.days = #hist.d
    end

    -- Cheapest listing right now: a fresh "Check price" beats saved data
    local lv = live[e.itemID]
    if lv and time() - lv.time < LIVE_FRESH then
        a.low, a.listed, a.lowTime, a.isLive = lv.low, lv.qty, lv.time, true
    elseif hist and hist.l then
        a.low, a.listed, a.lowTime = hist.l[2], hist.l[4], hist.l[1]
    end

    -- Suggested price: by default, the average of what it's actually been
    -- selling for, so you're not racing every other seller to the bottom.
    -- Switch to "Undercut" (1c under the cheapest listing) if you want the
    -- fastest possible sale instead.
    local mode = (AHWatchDB and AHWatchDB.sellMode) or "average"
    if mode == "undercut" and a.low and a.low > 0 then
        a.suggest = math.max(1, a.low - 1)
    elseif a.typical then
        a.suggest = a.typical
    elseif a.low and a.low > 0 then
        a.suggest = math.max(1, a.low - 1)   -- no saved average yet - fall back to undercut
    end
    if a.low and a.typical and a.low < a.typical * DUMP_RATIO then a.dumped = true end

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
local modeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
modeBtn:SetSize(100, 18)
modeBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, DY - 118)
modeBtn:SetNormalFontObject(GameFontNormalSmall)
modeBtn:SetHighlightFontObject(GameFontHighlightSmall)
local function SellMode() return (AHWatchDB and AHWatchDB.sellMode) or "average" end
local priceMoney = ns.MoneyInput(16, DY - 134, nil, panel)
local useSuggested = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
useSuggested:SetSize(84, 18)
useSuggested:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, DY - 134)
useSuggested:SetText("Suggested")
useSuggested:SetNormalFontObject(GameFontNormalSmall)
useSuggested:SetHighlightFontObject(GameFontHighlightSmall)

-- Quantity
Text(panel, "GameFontNormalSmall", 8, DY - 166):SetText("Quantity:")
local qtyBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
qtyBox:SetSize(46, 20)
qtyBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 74, DY - 162)
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
local qtyNote = Text(panel, "GameFontHighlightSmall", 142, DY - 166, 190)

-- Duration
Text(panel, "GameFontNormalSmall", 8, DY - 194):SetText("Duration:")
local durBtns = {}
for i, d in ipairs({ { 1, "2h" }, { 2, "8h" }, { 3, "24h" } }) do
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(44, 18)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", 70 + (i - 1) * 46, DY - 191)
    b:SetText(d[2])
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b.value = d[1]
    durBtns[i] = b
end
local depositText = Text(panel, "GameFontHighlightSmall", 8, DY - 216, 330)

local postBtn = CreateFrame("Button", "AHWatchPostButton", panel, "UIPanelButtonTemplate")
postBtn:SetSize(330, 26)
postBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, DY - 236)
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
qsEmptyText:SetText("No matching sellable items in your bags.")

local QS_DY = -206
local qsSelectedText = Text(qsPanel, "GameFontNormal", 8, QS_DY, 330)
qsSelectedText:SetText("Selected: |cffaaaaaanothing yet|r")

Text(qsPanel, "GameFontNormalSmall", 8, QS_DY - 28):SetText("Price each:")
local qsPriceMoney = ns.MoneyInput(16, QS_DY - 44, nil, qsPanel)

Text(qsPanel, "GameFontNormalSmall", 8, QS_DY - 76):SetText("Amount per press:")
local qsQtyBox = CreateFrame("EditBox", nil, qsPanel, "InputBoxTemplate")
qsQtyBox:SetSize(46, 20)
qsQtyBox:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 112, QS_DY - 72)
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

Text(qsPanel, "GameFontNormalSmall", 8, QS_DY - 104):SetText("Duration:")
local qsDuration = 2   -- 1 = 2h, 2 = 8h, 3 = 24h, same tiers as the advisor tab
local qsDurBtns = {}
for i, d in ipairs({ { 1, "2h" }, { 2, "8h" }, { 3, "24h" } }) do
    local b = CreateFrame("Button", nil, qsPanel, "UIPanelButtonTemplate")
    b:SetSize(44, 18)
    b:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 70 + (i - 1) * 46, QS_DY - 101)
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
qsCooldownBox:SetPoint("TOPLEFT", qsPanel, "TOPLEFT", 4, QS_DY - 128)
local qsCooldownLabel = Text(qsPanel, "GameFontNormalSmall", 26, QS_DY - 132)
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

local qsStatus = Text(qsPanel, "GameFontHighlightSmall", 8, QS_DY - 156, 330)
qsStatus:SetSpacing(2)
local qsPostedLabel = Text(qsPanel, "GameFontHighlightSmall", 8, QS_DY - 204, 330)

------------------------------------------------------------
-- Updating
------------------------------------------------------------

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

    dLines[1]:SetText("Average price (" .. (a.days or 0) .. " days saved): " ..
        (a.typical and Money(a.typical) or "|cff888888no history yet - run a full scan|r"))
    if a.low then
        dLines[2]:SetText("Cheapest listing: " .. Money(a.low) .. "  |cffaaaaaa(" .. (a.listed or 0) .. " listed, "
            .. (a.isLive and "checked " or "saved ") .. Ago(a.lowTime) .. ")|r")
    else
        dLines[2]:SetText("Cheapest listing: |cff888888unknown - click Check price|r")
    end
    dLines[3]:SetText("Vendor price: " .. (a.vendor > 0 and (Money(a.vendor) .. " each, " .. Money(a.vendor * e.count) .. " for all")
        or "|cff888888can't be sold to a vendor|r"))
    if a.net then
        dLines[4]:SetText("You'd get after the 5% AH cut: " .. Money(a.net) .. " each, " .. Money(a.net * e.count) .. " for all")
    end

    -- The recommendation
    if a.verdict == "ah" then
        local mode = (AHWatchDB and AHWatchDB.sellMode) or "average"
        local text = "|cff33dd66Sell on the AH.|r Post at " .. Money(a.suggest) .. " each"
        if mode == "undercut" and a.low then
            text = text .. " - 1c under the cheapest, so yours sells first."
        elseif a.typical and mode ~= "undercut" then
            text = text .. " - the average price, rather than undercutting everyone else."
        elseif a.low then
            text = text .. " - 1c under the cheapest (no saved average yet)."
        else
            text = text .. " (nobody else is selling it right now)."
        end
        if a.dumped then
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
        postBtn:SetText(price > 0 and qty > 0 and ("Post " .. qty .. " for " .. Money(price) .. " each") or "Set a price and quantity")
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

local function Select(e)
    selectedID = e.itemID
    pendingPost = nil
    e.commodity = IsCommodity(e)
    priceMoney.SetValue(e.analysis.suggest or 0)
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
    for _, e in ipairs(items) do
        if e.itemID == itemID then
            e.analysis = Analyze(e)
            if e.itemID == selectedID and e.analysis.suggest then priceMoney.SetValue(e.analysis.suggest) end
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
            table.insert(matches, e)
            if #matches >= QS_ROWS then break end
        end
    end
    for i, b in ipairs(qsRows) do
        local e = matches[i]
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
            _G.AHWatchGoButton:SetText(label .. "  |cff888888(" .. key .. ")|r")
        end
    end

    if not qsItemID then
        qsSelectedText:SetText("Selected: |cffaaaaaanothing yet - click an item above|r")
        qsStatus:SetText("")
        qsPostedLabel:SetText("")
        SetGoLabel("Quick Sale - pick an item")
        return
    end

    local haveCount = (GetItemCount and GetItemCount(qsItemID)) or 0
    qsSelectedText:SetText("Selected: " .. (qsItemName or "?") .. "  |cffaaaaaa(" .. haveCount .. " in bags)|r")

    local price, qty = qsPriceMoney.GetValue(), QSQty()
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
    else
        qsStatus:SetText("Ready - press your Buy-tab key to post " .. math.min(qty, haveCount) .. "x "
            .. (qsItemName or "item") .. " at " .. Money(price) .. " each ("
            .. ({ "2h", "8h", "24h" })[qsDuration] .. ").")
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
    b:SetScript("OnClick", function(self) if self.entry then Select(self.entry) end end)
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
        if e.itemID == selectedID and e.analysis.suggest then priceMoney.SetValue(e.analysis.suggest) end
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
priceMoney.onChange = function() RefreshDetail() end
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

qsSearchBox:SetScript("OnTextChanged", RefreshQS)
for _, b in ipairs(qsRows) do
    b:SetScript("OnClick", function(self)
        if not self.entry then return end
        qsItemID, qsItemName, qsItemIcon = self.entry.itemID, self.entry.name, self.entry.icon
        -- Prefill with the same suggested price the advisor tab would show,
        -- so there's usually just the amount left to set, not the price too.
        local a = self.entry.analysis
        if a and a.suggest then qsPriceMoney.SetValue(a.suggest) end
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
qsPriceMoney.onChange = function() RefreshQS() end
qsQtyBox:SetScript("OnTextChanged", RefreshQS)

local function SetTab(name)
    if AHWatchDB then AHWatchDB.tab = name end
    local sell, quick = (name == "sell"), (name == "quicksell")
    panel:SetShown(sell)
    qsPanel:SetShown(quick)
    tabSell.pbPrimary, tabBuy.pbPrimary, tabQS.pbPrimary = sell, (not sell and not quick), quick
    for _, t in ipairs({ { tabBuy, not sell and not quick }, { tabSell, sell }, { tabQS, quick } }) do
        if t[2] then t[1]:LockHighlight() else t[1]:UnlockHighlight() end
    end
    tabSell:SetText("Sell"); tabBuy:SetText("Buy"); tabQS:SetText("Quick Sell")   -- lets the trader look recolor them
    if sell then
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
