-- AHWatch ledger
-- What you've bought through AH Watch and what you've earned selling on the
-- auction house: when, what, how many, and how much. Opened with the Ledger
-- button on the main window (or /ahw ledger). Newest 2000 entries kept.
--
-- Purchases are recorded once the server confirms them. Sales are recorded
-- when you take the gold out of the "Auction successful" mail (that's when
-- the money actually reaches you), however you take it - clicking it, or
-- an "open all" button.

local _, ns = ...
local main = AHWatchFrame
local Money = ns.Money

local MAX_ENTRIES = 2000
local ROWS = 15
local ROW_H = 18

local function Short(c) return ns.ShortMoney and ns.ShortMoney(c) or Money(c) end

local function Entries()
    if type(AHWatchDB) ~= "table" then AHWatchDB = {} end
    AHWatchDB.ledger = AHWatchDB.ledger or {}
    return AHWatchDB.ledger
end

local Refresh

local function Add(entry)
    local list = Entries()
    table.insert(list, entry)
    while #list > MAX_ENTRIES do table.remove(list, 1) end
    if Refresh then Refresh() end
end

-- Called by AHWatch.lua once the server confirms a purchase. The market
-- price at that moment is kept too, to show how good a deal it was.
function ns.AddLedger(itemID, name, qty, total)
    if not itemID then return end
    local m = ns.MarketPrice and ns.MarketPrice(itemID)
    Add({ t = time(), id = itemID, n = name, q = qty or 1, c = math.floor(total or 0),
        m = m and math.floor(m) or nil })
end

------------------------------------------------------------
-- Sales: read from the auction house's "sold" mail as its gold is taken
------------------------------------------------------------

local recentMail = {}   -- guards against counting one mail twice

local function RecordSale(index)
    if type(index) ~= "number" or not GetInboxInvoiceInfo or not GetInboxHeaderInfo then return end
    local ok, invoiceType, itemName, buyer, bid, buyout, _, cut, _, _, count = pcall(GetInboxInvoiceInfo, index)
    if not ok or invoiceType ~= "seller" then return end
    local okH, _, _, _, subject, money, _, daysLeft = pcall(GetInboxHeaderInfo, index)
    if not okH or not money or money <= 0 then return end
    local key = tostring(itemName) .. ":" .. money .. ":" .. tostring(daysLeft) .. ":" .. tostring(subject)
    if recentMail[key] and GetTime() - recentMail[key] < 60 then return end
    recentMail[key] = GetTime()
    local id
    if itemName and C_Item and C_Item.GetItemInfoInstant then
        local okI, found = pcall(C_Item.GetItemInfoInstant, itemName)
        if okI and type(found) == "number" then id = found end
    end
    Add({ kind = "sale", t = time(), id = id, n = itemName, q = tonumber(count) or 1,
        c = money, gross = buyout or bid, cut = cut, who = buyer })
end
for _, fn in ipairs({ "TakeInboxMoney", "AutoLootMailItem" }) do
    if _G[fn] then pcall(hooksecurefunc, fn, RecordSale) end
end

------------------------------------------------------------
-- Window
------------------------------------------------------------

local ok, lf = pcall(CreateFrame, "Frame", "AHWatchLedgerFrame", main, "BasicFrameTemplateWithInset")
if not ok or not lf then
    lf = CreateFrame("Frame", "AHWatchLedgerFrame", main)
    local bg = lf:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)
end
lf:SetSize(360, 470)
lf:SetPoint("TOPRIGHT", main, "TOPLEFT", -2, 0)
lf:EnableMouse(true)
lf:Hide()
if lf.TitleText then lf.TitleText:SetText("Ledger") end
if ns.AddScaleGrip then ns.AddScaleGrip(lf) end

local function Text(font, x, y, width, justify)
    local fs = lf:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", lf, "TOPLEFT", x, y)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- Totals
local sumToday = Text("GameFontHighlightSmall", 14, -30, 332)
local sumWeek  = Text("GameFontHighlightSmall", 14, -45, 332)
local sumAll   = Text("GameFontHighlightSmall", 14, -60, 332)
local sumDeal  = Text("GameFontHighlightSmall", 14, -75, 332)

-- Filter by name, and which kind to list
Text("GameFontNormalSmall", 14, -98):SetText("Filter:")
local filterBox = CreateFrame("EditBox", nil, lf, "InputBoxTemplate")
filterBox:SetSize(110, 20)
filterBox:SetPoint("TOPLEFT", lf, "TOPLEFT", 58, -94)
filterBox:SetAutoFocus(false)
filterBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
filterBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

local view = "all"   -- all, buy, sale
local viewBtns = {}
for i, v in ipairs({ { "all", "All" }, { "buy", "Bought" }, { "sale", "Sold" } }) do
    local b = CreateFrame("Button", nil, lf, "UIPanelButtonTemplate")
    b:SetSize(52, 18)
    b:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -12 - (3 - i) * 54, -95)
    b:SetText(v[2])
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b.view = v[1]
    viewBtns[i] = b
end

-- Column headings
local HY = -120
Text("GameFontNormalSmall", 14, HY, 76):SetText("When")
Text("GameFontNormalSmall", 92, HY, 140):SetText("Item")
Text("GameFontNormalSmall", 214, HY, 36, "RIGHT"):SetText("Qty")
Text("GameFontNormalSmall", 254, HY, 92, "RIGHT"):SetText("Amount")
local headLine = lf:CreateTexture(nil, "ARTWORK")
headLine:SetColorTexture(1, 1, 1, 0.15)
headLine:SetHeight(1)
headLine:SetPoint("TOPLEFT", lf, "TOPLEFT", 12, HY - 14)
headLine:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -12, HY - 14)

local function NameOf(e)
    if not e.n and e.id then
        local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)
        if n then e.n = n end
    end
    return e.n or (e.id and ("Item " .. e.id)) or "?"
end

local function IconOf(e)
    local icon
    if e.id then
        icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(e.id)
        if not icon and GetItemIcon then icon = GetItemIcon(e.id) end
    elseif e.n and C_Item and C_Item.GetItemInfoInstant then
        local okI, _, _, _, _, found = pcall(C_Item.GetItemInfoInstant, e.n)
        if okI then icon = found end
    end
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- "18% under market" / "5% over market" for a purchase, from the price then
local function DealText(paidEach, marketEach)
    if not marketEach or marketEach <= 0 then return nil end
    local pct = (marketEach - paidEach) / marketEach * 100
    if math.abs(pct) < 0.5 then return "|cffffffffat market|r" end
    if pct > 0 then return string.format("|cff33dd66%d%% under market|r", math.floor(pct + 0.5)) end
    return string.format("|cffff6666%d%% over market|r", math.floor(-pct + 0.5))
end

local rows = {}
for i = 1, ROWS do
    local b = CreateFrame("Button", nil, lf)
    b:SetSize(336, ROW_H)
    b:SetPoint("TOPLEFT", lf, "TOPLEFT", 12, HY - 18 - (i - 1) * ROW_H)
    b.when = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.when:SetPoint("LEFT", 2, 0)
    b.when:SetWidth(76)
    b.when:SetJustifyH("LEFT")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(14, 14)
    b.icon:SetPoint("LEFT", 80, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    b.name:SetWidth(118)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.qty = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.qty:SetPoint("LEFT", 202, 0)
    b.qty:SetWidth(36)
    b.qty:SetJustifyH("RIGHT")
    b.amount = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.amount:SetPoint("RIGHT", -2, 0)
    b.amount:SetJustifyH("RIGHT")
    if i % 2 == 0 then
        local stripe = b:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.04)
    end
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:SetScript("OnEnter", function(self)
        local e = self.entry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if e.id then GameTooltip:SetItemByID(e.id) else GameTooltip:SetText(NameOf(e)) end
        GameTooltip:AddLine(" ")
        local q = math.max(e.q or 1, 1)
        if e.kind == "sale" then
            GameTooltip:AddDoubleLine("Sold:", date("%a %b %d, %H:%M", e.t) .. " (gold collected)", 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Amount:", tostring(q), 1, 1, 1, 1, 1, 1)
            if e.who and e.who ~= "" then GameTooltip:AddDoubleLine("Buyer:", e.who, 1, 1, 1, 1, 1, 1) end
            if e.gross and e.gross > 0 then GameTooltip:AddDoubleLine("Sale price:", Money(e.gross), 1, 1, 1, 1, 1, 1) end
            if e.cut and e.cut > 0 then GameTooltip:AddDoubleLine("AH cut:", Money(e.cut), 1, 1, 1, 1, 1, 1) end
            GameTooltip:AddDoubleLine("You got:", Money(e.c), 1, 1, 1, 0.4, 1, 0.4)
            GameTooltip:AddDoubleLine("Each (after cut):", Money(e.c / q), 1, 1, 1, 1, 1, 1)
        else
            GameTooltip:AddDoubleLine("Bought:", date("%a %b %d, %H:%M", e.t), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Amount:", tostring(q), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Each:", Money(e.c / q), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Total:", Money(e.c), 1, 1, 1, 1, 1, 1)
            if e.m then
                GameTooltip:AddDoubleLine("Market price then:", Money(e.m) .. " each", 1, 1, 1, 1, 1, 1)
                local deal = DealText(e.c / q, e.m)
                if deal then GameTooltip:AddDoubleLine("You paid:", deal, 1, 1, 1, 1, 1, 1) end
            end
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Shift-click puts the item link in chat, like anywhere else in the game
    b:SetScript("OnClick", function(self)
        local e = self.entry
        if e and IsModifiedClick and IsModifiedClick("CHATLINK") then
            local _, link = GetItemInfo(e.id or NameOf(e))
            if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        end
    end)
    b:Hide()
    rows[i] = b
end

local emptyText = lf:CreateFontString(nil, "OVERLAY", "GameFontDisable")
emptyText:SetPoint("TOP", lf, "TOP", 0, HY - 60)
emptyText:SetWidth(300)

local scrollText = Text("GameFontDisableSmall", 14, HY - 22 - ROWS * ROW_H, 250)

local clearBtn = CreateFrame("Button", nil, lf, "UIPanelButtonTemplate")
clearBtn:SetSize(90, 20)
clearBtn:SetPoint("BOTTOMLEFT", lf, "BOTTOMLEFT", 12, 10)
clearBtn:SetText("Clear")
clearBtn:SetNormalFontObject(GameFontNormalSmall)
clearBtn:SetHighlightFontObject(GameFontHighlightSmall)

------------------------------------------------------------
-- Filling it in
------------------------------------------------------------

local offset = 0
local shown = {}   -- entries matching the filter and view, newest first

local function Totals(label, spent, nBuy, earned, nSale)
    local net = earned - spent
    local netText = (net >= 0) and ("|cff33dd66+" .. Short(net) .. "|r") or ("|cffff6666-" .. Short(-net) .. "|r")
    return label .. "spent |cffff9999" .. Short(spent) .. "|r (" .. nBuy .. ")   earned |cff99ff99"
        .. Short(earned) .. "|r (" .. nSale .. ")   net " .. netText
end

function Refresh()
    if not lf:IsShown() then return end
    local list = Entries()
    local q = (filterBox:GetText() or ""):lower()

    -- Midnight today, local time
    local now = time()
    local d = date("*t", now)
    local todayStart = now - (d.hour * 3600 + d.min * 60 + d.sec)
    local weekStart = todayStart - 6 * 86400

    local T = { day = { 0, 0, 0, 0 }, week = { 0, 0, 0, 0 }, all = { 0, 0, 0, 0 } }
    local function Count(bucket, e)
        if e.kind == "sale" then
            bucket[3], bucket[4] = bucket[3] + e.c, bucket[4] + 1
        else
            bucket[1], bucket[2] = bucket[1] + e.c, bucket[2] + 1
        end
    end
    local paidWithMarket, marketValue, dealCount = 0, 0, 0
    shown = {}
    for i = #list, 1, -1 do
        local e = list[i]
        if q == "" or NameOf(e):lower():find(q, 1, true) then
            Count(T.all, e)
            if e.t >= weekStart then Count(T.week, e) end
            if e.t >= todayStart then Count(T.day, e) end
            if e.kind ~= "sale" and e.m and e.m > 0 then
                paidWithMarket = paidWithMarket + e.c
                marketValue = marketValue + e.m * math.max(e.q or 1, 1)
                dealCount = dealCount + 1
            end
            local isSale = (e.kind == "sale")
            if view == "all" or (view == "sale") == isSale then table.insert(shown, e) end
        end
    end
    sumToday:SetText(Totals("Today:  ", unpack(T.day)))
    sumWeek:SetText(Totals("7 days:  ", unpack(T.week)))
    sumAll:SetText(Totals("All:  ", unpack(T.all)))
    if dealCount > 0 then
        local deal = DealText(paidWithMarket, marketValue)
        sumDeal:SetText("Your buys on average: " .. deal .. "  |cffaaaaaa(" .. dealCount .. " with a market price"
            .. (q ~= "" and ", this filter" or "") .. ")|r")
    else
        sumDeal:SetText("|cff888888Your average discount shows here once you've bought something with a market price.|r")
    end

    for _, b in ipairs(viewBtns) do
        if b.view == view then b:LockHighlight() else b:UnlockHighlight() end
    end

    offset = math.max(0, math.min(offset, #shown - ROWS))
    for i, b in ipairs(rows) do
        local e = shown[offset + i]
        if e then
            b.entry = e
            b.when:SetText(date("%b %d %H:%M", e.t))
            b.icon:SetTexture(IconOf(e))
            b.name:SetText(NameOf(e))
            b.qty:SetText((e.q or 1) > 1 and (e.q .. "x") or "1")
            if e.kind == "sale" then
                b.amount:SetText("|cff99ff99+" .. Short(e.c) .. "|r")
            else
                b.amount:SetText("|cffff9999-" .. Short(e.c) .. "|r")
            end
            b:Show()
        else
            b.entry = nil
            b:Hide()
        end
    end
    if #list == 0 then
        emptyText:SetText("Nothing here yet.\nPurchases made with AH Watch, and gold you collect from auction "
            .. "house sales in your mailbox, show up here.")
    elseif #shown == 0 then
        emptyText:SetText("Nothing matches.")
    else
        emptyText:SetText("")
    end
    scrollText:SetText(#shown > ROWS and string.format("Showing %d-%d of %d (scroll for more)",
        offset + 1, math.min(offset + ROWS, #shown), #shown) or "")
    clearBtn:SetEnabled(#list > 0)
end

for _, b in ipairs(viewBtns) do
    b:SetScript("OnClick", function(self) view = self.view; offset = 0; Refresh() end)
end
lf:EnableMouseWheel(true)
lf:SetScript("OnMouseWheel", function(_, delta)
    local step = IsShiftKeyDown() and ROWS or 3
    offset = math.max(0, math.min(math.max(0, #shown - ROWS), offset - delta * step))
    Refresh()
end)
lf:SetScript("OnShow", function() offset = 0; Refresh() end)
filterBox:SetScript("OnTextChanged", function() offset = 0; Refresh() end)

StaticPopupDialogs["AHWATCH_CLEAR_LEDGER"] = {
    text = "Clear AH Watch's whole ledger (purchases and sales)? This can't be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        if type(AHWatchDB) == "table" then AHWatchDB.ledger = {} end
        Refresh()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
clearBtn:SetScript("OnClick", function() StaticPopup_Show("AHWATCH_CLEAR_LEDGER") end)

function ns.ToggleLedger()
    if not main:IsShown() then main:Show() end
    lf:SetShown(not lf:IsShown())
end

-- Item names can arrive a moment after the window opens
local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function()
    if lf:IsShown() and not ev.queued then
        ev.queued = true
        C_Timer.After(0.3, function() ev.queued = false; Refresh() end)
    end
end)
