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
local ROWS = 14
local ROW_H = 18

local function Short(c) return ns.ShortMoney and ns.ShortMoney(c) or Money(c) end

-- Money with the gold/silver/copper coin icons
local function Coins(c)
    c = math.floor((c or 0) + 0.5)
    if GetMoneyString then return GetMoneyString(c, true) end
    return Money(c)
end

------------------------------------------------------------
-- Pairing sales with purchases
-- Every purchase remembers how many of it are still unsold ("left"). A sale
-- is matched oldest-purchase-first against unsold purchases of the same
-- item, so each sale knows exactly what those units cost you and the profit.
-- A sale with nothing to match - loot, world drops, crafted items - isn't
-- recorded at all.
------------------------------------------------------------

-- Takes up to `want` unsold units of an item from purchases (oldest first,
-- only those before `upTo` in the list). Returns units matched, their cost,
-- and which purchases they came from.
local function TakeLots(list, id, want, upTo)
    local taken, cost, lots = 0, 0, {}
    if not id or want <= 0 then return 0, 0, lots end
    for i = 1, (upTo or #list) do
        local b = list[i]
        if b.kind ~= "sale" and b.id == id and (b.left or 0) > 0 then
            local take = math.min(b.left, want - taken)
            local each = (b.c or 0) / math.max(b.q or 1, 1)
            b.left = b.left - take
            taken = taken + take
            cost = cost + each * take
            lots[#lots + 1] = { t = b.t, q = take, each = math.floor(each) }
            if taken >= want then break end
        end
    end
    return taken, math.floor(cost), lots
end

-- What your unsold stock of an item cost (from purchases made with AH
-- Watch). With qty, it's the cost of the next `qty` units a sale would be
-- matched against (oldest first), which is what posting them risks.
-- Returns cost each, how many unsold units are known, and the break-even
-- price each (the lowest price that gets your money back after the 5% cut).
-- Nothing known (looted, crafted, bought elsewhere): returns nil.
function ns.CostBasis(itemID, qty)
    if not itemID or type(AHWatchDB) ~= "table" or not AHWatchDB.ledger then return nil end
    local units, cost, counted = 0, 0, 0
    local want = (qty and qty > 0) and qty or math.huge
    for _, b in ipairs(AHWatchDB.ledger) do
        if b.kind ~= "sale" and b.id == itemID and (b.left or 0) > 0 then
            units = units + b.left
            if counted < want then
                local take = math.min(b.left, want - counted)
                cost = cost + (b.c or 0) / math.max(b.q or 1, 1) * take
                counted = counted + take
            end
        end
    end
    if counted == 0 then return nil end
    local each = cost / counted
    return each, units, math.ceil(each / 0.95)
end

-- One-time setup for ledgers from before pairing: works out what's still
-- unsold and matches old sales to old purchases where it can. Nothing is
-- deleted or changed - old sales just gain their cost/profit if they match.
local function PairOldEntries(list)
    if AHWatchDB.ledgerPairV1 then return end
    AHWatchDB.ledgerPairV1 = true
    local nameToId = {}
    for i, e in ipairs(list) do
        if e.kind ~= "sale" then
            if e.left == nil then e.left = e.q or 1 end
            if e.id and e.n then nameToId[e.n] = e.id end
        else
            local id = e.id or (e.n and nameToId[e.n])
            local taken, cost, lots = TakeLots(list, id, e.q or 1, i - 1)
            if taken > 0 then e.cost, e.lots, e.mq = cost, lots, taken end
        end
    end
end

local function Entries()
    if type(AHWatchDB) ~= "table" then AHWatchDB = {} end
    AHWatchDB.ledger = AHWatchDB.ledger or {}
    PairOldEntries(AHWatchDB.ledger)
    return AHWatchDB.ledger
end

-- An item ID for a sale mail that only gave a name: look it up among buys
local function IdFromBuys(name)
    if not name then return nil end
    local list = AHWatchDB and AHWatchDB.ledger or {}
    for i = #list, 1, -1 do
        local e = list[i]
        if e.kind ~= "sale" and e.n == name and e.id then return e.id end
    end
end

-- Profit on a sale that was paired with purchases (nil if it wasn't)
local function SaleProfit(e)
    if not e.cost then return nil end
    local q = math.max(e.q or 1, 1)
    local mq = e.mq or q
    return math.floor((e.c or 0) * mq / q) - e.cost
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
    Entries()
    Add({ t = time(), id = itemID, n = name, q = qty or 1, c = math.floor(total or 0),
        m = m and math.floor(m) or nil, left = qty or 1 })
end

------------------------------------------------------------
-- Sales: read from the auction house's "sold" mail as its gold is taken
------------------------------------------------------------

local recentMail = {}   -- guards against counting one mail twice

-- Reads one mail. GetInboxInvoiceInfo returns: type, item, buyer, bid,
-- buyout, deposit, AH cut, money delay, eta hour, eta min, COUNT (11th).
-- (Before 1.33 the count was read from the 10th value - the delivery
-- minutes, usually 0 - so every sale matched nothing and was dropped.)
local function ReadMail(index)
    local ok, invoiceType, itemName, buyer, bid, buyout, _, cut, _, _, _, count = pcall(GetInboxInvoiceInfo, index)
    if not ok or invoiceType ~= "seller" then return nil end
    local okH, _, _, _, subject, money, _, daysLeft = pcall(GetInboxHeaderInfo, index)
    if not okH then return nil end
    return { itemName = itemName, buyer = buyer, bid = bid, buyout = buyout, cut = cut, count = count,
             subject = subject, money = money, daysLeft = daysLeft }
end

-- Snapshot of the sold-mail in the inbox, taken whenever it changes, so a
-- sale can still be read if its gold is already gone by the time we look
local mailCache = {}
local function CacheInbox()
    mailCache = {}
    if not GetInboxNumItems or not GetInboxInvoiceInfo then return end
    for i = 1, (GetInboxNumItems() or 0) do
        local m = ReadMail(i)
        if m and m.money and m.money > 0 then mailCache[i] = m end
    end
end

local function RecordSale(index)
    if type(index) ~= "number" or not GetInboxInvoiceInfo or not GetInboxHeaderInfo then return end
    local m = ReadMail(index)
    if not m or not m.money or m.money <= 0 then m = mailCache[index] end
    mailCache[index] = nil
    if not m or not m.money or m.money <= 0 then return end
    local itemName, buyer, bid, buyout, cut, count = m.itemName, m.buyer, m.bid, m.buyout, m.cut, m.count
    local subject, money, daysLeft = m.subject, m.money, m.daysLeft
    local key = tostring(itemName) .. ":" .. money .. ":" .. tostring(daysLeft) .. ":" .. tostring(subject)
    if recentMail[key] and GetTime() - recentMail[key] < 60 then return end
    recentMail[key] = GetTime()
    local id
    if itemName and C_Item and C_Item.GetItemInfoInstant then
        local okI, found = pcall(C_Item.GetItemInfoInstant, itemName)
        if okI and type(found) == "number" then id = found end
    end
    -- Pair with what you bought; nothing to pair with = not one of your flips
    local list = Entries()
    id = id or IdFromBuys(itemName)
    local sold = tonumber(count) or 1
    if sold < 1 then sold = 1 end
    local taken, cost, lots = TakeLots(list, id, sold)
    if taken <= 0 then return end
    local f = taken / sold                  -- sold more than you bought: only the bought part counts
    local gross = buyout or bid
    Add({ kind = "sale", t = time(), id = id, n = itemName, q = taken,
        c = math.floor(money * f), gross = gross and math.floor(gross * f) or nil,
        cut = cut and math.floor(cut * f) or nil, who = buyer, cost = cost, lots = lots })
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

-- Totals: a small table - Today / 7 days / All against Spent / Earned / Profit.
-- Profit only counts sales paired with what you paid for those items.
local COLS = { { x = 66, w = 92 }, { x = 160, w = 92 }, { x = 254, w = 92 } }
do
    local heads = { "Spent", "Earned", "Profit" }
    for i, c in ipairs(COLS) do Text("GameFontNormalSmall", c.x, -28, c.w, "RIGHT"):SetText(heads[i]) end
    local line = lf:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.12)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", lf, "TOPLEFT", 12, -41)
    line:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -12, -41)
end
local sumRows = {}
for i, label in ipairs({ "Today", "7 days", "All" }) do
    local y = -45 - (i - 1) * 15
    local r = { label = Text("GameFontNormalSmall", 14, y, 52) }
    r.label:SetText(label)
    for k, c in ipairs(COLS) do r[k] = Text("GameFontHighlightSmall", c.x, y, c.w, "RIGHT") end
    sumRows[i] = r
end
local sumDeal = Text("GameFontHighlightSmall", 14, -92, 332)

-- Filter by name, and which kind to list
Text("GameFontNormalSmall", 14, -112):SetText("Filter:")
local filterBox = CreateFrame("EditBox", nil, lf, "InputBoxTemplate")
filterBox:SetSize(110, 20)
filterBox:SetPoint("TOPLEFT", lf, "TOPLEFT", 58, -108)
filterBox:SetAutoFocus(false)
filterBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
filterBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

local view = "all"   -- all, buy, sale
local viewBtns = {}
for i, v in ipairs({ { "all", "All" }, { "buy", "Bought" }, { "sale", "Sold" } }) do
    local b = CreateFrame("Button", nil, lf, "UIPanelButtonTemplate")
    b:SetSize(52, 18)
    b:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -12 - (3 - i) * 54, -109)
    b:SetText(v[2])
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b.view = v[1]
    viewBtns[i] = b
end

-- Column headings
local HY = -134
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
            local profit = SaleProfit(e)
            if profit then
                local mq = e.mq or q
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine("You paid:", Money(e.cost) .. (mq < q and ("  (for " .. mq .. " of them)") or ""),
                    1, 1, 1, 1, 0.6, 0.6)
                local pctText = (e.cost > 0) and string.format("  (%+.0f%%)", profit / e.cost * 100) or ""
                GameTooltip:AddDoubleLine("Profit:", (profit >= 0 and "|cff33dd66+" or "|cffff6666-")
                    .. Money(math.abs(profit)) .. "|r" .. pctText, 1, 1, 1, 1, 1, 1)
                for _, l in ipairs(e.lots or {}) do
                    GameTooltip:AddDoubleLine("  from your buy on " .. date("%b %d", l.t), l.q .. " x " .. Money(l.each),
                        0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
                end
            else
                GameTooltip:AddLine("No matching purchase (recorded before sales were paired with buys).", 0.6, 0.6, 0.6, true)
            end
        else
            GameTooltip:AddDoubleLine("Bought:", date("%a %b %d, %H:%M", e.t), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Amount:", tostring(q), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Each:", Money(e.c / q), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Total:", Money(e.c), 1, 1, 1, 1, 1, 1)
            if e.left ~= nil then
                GameTooltip:AddDoubleLine("Still unsold:", (e.left or 0) .. " of " .. q, 1, 1, 1, 1, 1, 1)
            end
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
        if e and IsShiftKeyDown() and AuctionHouseFrame and AuctionHouseFrame:IsShown() and ns.SearchInAH then
            local id = e.id or select(1, GetItemInfoInstant and GetItemInfoInstant(NameOf(e)) or nil)
            if id then ns.SearchInAH(id, NameOf(e)) return end
        end
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

-- Profit only counts sales paired with what you paid, so unsold stock
-- doesn't show up as a loss
local function FillTotals(r, spent, nBuy, earned, nSale, profit)
    r[1]:SetText(spent > 0 and Coins(spent) or "|cff666666-|r")
    r[2]:SetText(earned > 0 and Coins(earned) or "|cff666666-|r")
    if profit == 0 then
        r[3]:SetText("|cff666666-|r")
    else
        r[3]:SetText((profit > 0 and "|cff33dd66+|r" or "|cffff6666-|r") .. Coins(math.abs(profit)))
    end
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

    local T = { day = { 0, 0, 0, 0, 0 }, week = { 0, 0, 0, 0, 0 }, all = { 0, 0, 0, 0, 0 } }
    local function Count(bucket, e)
        if e.kind == "sale" then
            bucket[3], bucket[4] = bucket[3] + e.c, bucket[4] + 1
            bucket[5] = bucket[5] + (SaleProfit(e) or 0)
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
    FillTotals(sumRows[1], unpack(T.day))
    FillTotals(sumRows[2], unpack(T.week))
    FillTotals(sumRows[3], unpack(T.all))
    local counts = string.format("|cffaaaaaa%d buy%s, %d sale%s%s|r", T.all[2], T.all[2] == 1 and "" or "s",
        T.all[4], T.all[4] == 1 and "" or "s", q ~= "" and " (this filter)" or "")
    if dealCount > 0 then
        sumDeal:SetText(counts .. "  -  your buys average " .. DealText(paidWithMarket, marketValue))
    else
        sumDeal:SetText(counts)
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
            local nameText = NameOf(e)
            local profit = (e.kind == "sale") and SaleProfit(e)
            if profit then
                nameText = nameText .. (profit >= 0 and "  |cff33dd66+" or "  |cffff6666-") .. Short(math.abs(profit)) .. "|r"
            end
            b.name:SetText(nameText)
            b.qty:SetText((e.q or 1) > 1 and (e.q .. "x") or "1")
            if e.kind == "sale" then
                b.amount:SetText("|cff33dd66+|r" .. Coins(e.c))
            else
                b.amount:SetText("|cffff6666-|r" .. Coins(e.c))
            end
            b:Show()
        else
            b.entry = nil
            b:Hide()
        end
    end
    if #list == 0 then
        emptyText:SetText("Nothing here yet.\nPurchases made with AH Watch show up here, and so do their sales "
            .. "(paired with what you paid) when you collect the gold from your mailbox.")
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
pcall(ev.RegisterEvent, ev, "MAIL_SHOW")
pcall(ev.RegisterEvent, ev, "MAIL_INBOX_UPDATE")
ev:SetScript("OnEvent", function(_, e)
    if e == "MAIL_SHOW" or e == "MAIL_INBOX_UPDATE" then CacheInbox() return end
    if lf:IsShown() and not ev.queued then
        ev.queued = true
        C_Timer.After(0.3, function() ev.queued = false; Refresh() end)
    end
end)
