-- AHWatch
-- A watch list for the auction house. Add items with a max price, then press
-- one button (or key) over and over: each press either refreshes the search or
-- buys the next batch at or under your price that you can afford.
--
-- The game requires a real click or keypress for every search and purchase,
-- so nothing here runs on its own - every action is one press.

local _, ns = ...                 -- shared with Prices.lua (price history and graph)
ns = ns or {}

local DEFAULT_KEY = "SHIFT-G"
local STALE_AFTER = 20          -- seconds before search results count as old
local BROWSE_ROWS, WATCH_ROWS = 6, 7

local runtime = {}              -- itemID -> { rows = {...}, time = t }
local browse = {}               -- results of the last name search
local selectedBrowse = nil      -- item picked from the name search
local state = "idle"            -- idle, searching, pricing, confirm, buying
local purchase = nil            -- commodity purchase in progress
local current = 1               -- which watched item is up next
local spent = 0                 -- copper spent this session
local ahOpen = false
local purchaseToken = nil       -- identifies the step a timeout belongs to
local browsePending = false     -- true while our own name search is waiting for results
local Update                    -- defined further down

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function Msg(text) print("|cff33ccffAHWatch:|r " .. text) end

local function EnsureDB()
    if type(AHWatchDB) ~= "table" then AHWatchDB = {} end
    AHWatchDB.watch = AHWatchDB.watch or {}
end

local function Money(copper)
    copper = math.floor(copper or 0)
    if GetMoneyString then return GetMoneyString(copper, true) end
    return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function ItemName(itemID)
    if not itemID then return nil end
    local name
    if C_Item and C_Item.GetItemNameByID then name = C_Item.GetItemNameByID(itemID) end
    if not name and C_Item and C_Item.GetItemInfo then name = C_Item.GetItemInfo(itemID) end
    if not name and GetItemInfo then name = GetItemInfo(itemID) end
    if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return name
end

local function ItemIcon(itemID)
    local icon
    if itemID and C_Item and C_Item.GetItemIconByID then icon = C_Item.GetItemIconByID(itemID) end
    if not icon and itemID and GetItemIcon then icon = GetItemIcon(itemID) end
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function MarketPrice(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionPriceByItemID) then return nil end
    local ok, price = pcall(api.GetAuctionPriceByItemID, "AHWatch", itemID)
    if ok and price and price > 0 then return price end
end

local function MaxPriceFor(w)
    if w.maxPct then
        local m = MarketPrice(w.itemID)
        return m and math.floor(m * w.maxPct / 100) or nil
    end
    return w.maxCopper
end

local function MaxText(w)
    if w.maxPct then
        local m = MaxPriceFor(w)
        return w.maxPct .. "% of market" .. (m and (" (" .. Money(m) .. ")") or " (no price data)")
    end
    return Money(w.maxCopper)
end

-- Gold you're allowed to spend right now (your gold, limited by the spend cap)
local function Budget()
    local budget = GetMoney()
    local cap = AHWatchDB.capCopper
    if cap and cap > 0 then budget = math.min(budget, math.max(0, cap - spent)) end
    return budget
end

local function LimitReached()
    return AHWatchDB.capCopper and AHWatchDB.capCopper > 0 and spent >= AHWatchDB.capCopper
end

local function Ready()
    if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady then
        return C_AuctionHouse.IsThrottledMessageSystemReady()
    end
    return true
end

local function FindWatch(itemID)
    for i, w in ipairs(AHWatchDB.watch) do
        if w.itemID == itemID then return w, i end
    end
end

local SORT_PRICE = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0

------------------------------------------------------------
-- Planning: what the next press should buy
------------------------------------------------------------

-- Returns the next purchase for a watched item, plus a summary for the list
local function Plan(w)
    local r = runtime[w.itemID]
    if not r or not r.rows then return nil end
    local max = MaxPriceFor(w)
    if not max then return nil, { note = "no max price" } end
    local budget = Budget()
    local summary = { under = 0, underCost = 0, afford = 0 }
    -- How many more of this item you still want
    local want = math.huge
    if w.maxQty and w.maxQty > 0 then
        want = w.maxQty - (w.bought or 0)
        if want <= 0 then return nil, { note = "bought all " .. w.maxQty } end
    end

    if w.isCommodity then
        local qty, total, stopped = 0, 0, false
        for _, row in ipairs(r.rows) do
            if row.unitPrice > max then break end
            if not row.own then
                summary.under = summary.under + row.quantity
                summary.underCost = summary.underCost + row.quantity * row.unitPrice
                if not stopped then
                    local canAfford = math.floor((budget - total) / row.unitPrice)
                    local take = math.min(row.quantity, canAfford, want - qty)
                    if take > 0 then
                        qty = qty + take
                        total = total + take * row.unitPrice
                    end
                    if take < row.quantity or qty >= want then stopped = true end
                end
            end
        end
        summary.afford = qty
        if qty > 0 then return { kind = "commodity", qty = qty, total = total }, summary end
        return nil, summary
    end

    local best, left = nil, budget
    for _, row in ipairs(r.rows) do
        local unit = row.buyout / math.max(row.quantity, 1)
        if unit <= max and not row.own then
            summary.under = summary.under + row.quantity
            summary.underCost = summary.underCost + row.buyout
            -- Listings are bought whole, so skip stacks bigger than what's still wanted
            if row.buyout <= left and summary.afford + row.quantity <= want then
                if not best then best = row end
                summary.afford = summary.afford + row.quantity
                left = left - row.buyout
            end
        end
    end
    if best then return { kind = "item", auctionID = best.auctionID, price = best.buyout, row = best }, summary end
    return nil, summary
end

------------------------------------------------------------
-- Actions (each one runs from a click or keypress)
------------------------------------------------------------

local function SetState(s)
    state = s
    if Update then Update() end
end

-- Resets a step that never got an answer from the server
local function Timeout(expected, seconds)
    local token = {}
    purchaseToken = token
    C_Timer.After(seconds, function()
        if state == expected and purchaseToken == token then
            if expected == "pricing" or expected == "confirm" then
                pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            end
            purchase = nil
            SetState("idle")
        end
    end)
end

local function Search(w)
    local key = w.itemKey or C_AuctionHouse.MakeItemKey(w.itemID)
    runtime[w.itemID] = nil
    SetState("searching")
    local ok, err = pcall(C_AuctionHouse.SendSearchQuery, key, { { sortOrder = SORT_PRICE, reverseSort = false } }, false)
    if not ok then
        Msg("search failed: " .. tostring(err))
        SetState("idle")
        return
    end
    Timeout("searching", 8)
end

local function Buy(w, plan)
    if plan.kind == "commodity" then
        purchase = { itemID = w.itemID, qty = plan.qty, max = MaxPriceFor(w), name = w.name, expected = plan.total }
        SetState("pricing")
        local ok, err = pcall(C_AuctionHouse.StartCommoditiesPurchase, w.itemID, plan.qty)
        if not ok then
            Msg("couldn't start the purchase: " .. tostring(err))
            purchase = nil
            SetState("idle")
            return
        end
        Timeout("pricing", 6)
    else
        local ok, err = pcall(C_AuctionHouse.PlaceBid, plan.auctionID, plan.price)
        if not ok then
            Msg("couldn't buy: " .. tostring(err))
            return
        end
        spent = spent + plan.price
        w.bought = (w.bought or 0) + (plan.row.quantity or 1)
        local qtyText = (plan.row.quantity or 1) > 1 and (plan.row.quantity .. "x ") or ""
        Msg("bought " .. qtyText .. (w.name or "item") .. " for " .. Money(plan.price) .. ".")
        -- Take it off the local list so the next press buys the next one
        local rows = runtime[w.itemID] and runtime[w.itemID].rows
        if rows then
            for i, row in ipairs(rows) do
                if row == plan.row then table.remove(rows, i) break end
            end
        end
        Update()
    end
end

local function ConfirmBuy()
    if not purchase then SetState("idle") return end
    local ok, err = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, purchase.itemID, purchase.qty)
    if not ok then
        Msg("couldn't confirm: " .. tostring(err))
        purchase = nil
        SetState("idle")
        return
    end
    SetState("buying")
    Timeout("buying", 10)
end

local function CancelBuy()
    if state == "pricing" or state == "confirm" then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
    purchase = nil
    SetState("idle")
end

-- The one button on the Buy tab: refresh, buy, confirm, or move to the next item
local function BuyGo()
    EnsureDB()
    local list = AHWatchDB.watch
    if not ahOpen then Msg("open the auction house first.") return end
    if #list == 0 then Msg("add an item to your watch list first.") return end
    if state == "confirm" then ConfirmBuy() return end
    if state ~= "idle" then return end
    if not Ready() then return end

    if current > #list then current = 1 end
    local w = list[current]
    local r = runtime[w.itemID]
    if not r or not r.rows or GetTime() - r.time > STALE_AFTER then
        Search(w)
        return
    end
    local plan = Plan(w)
    if plan then
        Buy(w, plan)
        return
    end
    -- Nothing to buy on this item right now: check the next one, unless
    -- "Cycle list" is unchecked, in which case stay locked on this one and
    -- just refresh its search instead of hopping to another item.
    if AHWatchDB.cycleList == false then
        Search(w)
        return
    end
    current = current % #list + 1
    Search(list[current])
end

local function CurrentTab() return (AHWatchDB and AHWatchDB.tab) or "buy" end
ns.CurrentTab = CurrentTab

-- The single Go button/keybind is shared across tabs - Buy has its
-- watch-list logic above, Quick Sell (Sell.lua) has its own repeated-press
-- post logic. Route to whichever tab is actually showing.
local function Go()
    if CurrentTab() == "quicksell" and ns.QuickSellGo then
        ns.QuickSellGo()
        return
    end
    BuyGo()
end

------------------------------------------------------------
-- Window
------------------------------------------------------------

local function TryCreate(ftype, name, parent, template)
    local ok, fr = pcall(CreateFrame, ftype, name, parent, template)
    if ok and fr then return fr end
    return CreateFrame(ftype, name, parent)
end

local f = TryCreate("Frame", "AHWatchFrame", UIParent, "BasicFrameTemplateWithInset")
f:SetSize(360, 680)
f:SetPoint("CENTER")
f:SetFrameStrata("HIGH")
f:SetClampedToScreen(true)
f:EnableMouse(true)
f:SetMovable(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    AHWatchDB.pos = { point, relPoint, x, y }
end)
f:Hide()
table.insert(UISpecialFrames, "AHWatchFrame")

------------------------------------------------------------
-- UI scale: a small drag-grip in the bottom-right corner of each window,
-- for compensating when the game's own UI scale differs between computers
-- (a different scale on someone else's PC otherwise makes this look too
-- big or too small no matter what size we build it at).
------------------------------------------------------------

local scaledFrames = {}

local function CurrentScale() return (AHWatchDB and AHWatchDB.uiScale) or 1 end

function ns.SetUIScale(scale)
    scale = math.max(0.6, math.min(1.6, scale))
    EnsureDB()
    AHWatchDB.uiScale = scale
    for _, fr in ipairs(scaledFrames) do fr:SetScale(scale) end
end

-- Adds a small diagonal-lines grip to a window's bottom-right corner;
-- dragging it resizes THIS addon's own windows (both of them together),
-- separate from the game's own UI scale option.
function ns.AddScaleGrip(frame)
    table.insert(scaledFrames, frame)
    frame:SetScale(CurrentScale())

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(24, 24)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(frame:GetFrameLevel() + 20)

    -- A small backdrop box behind the icon so this reads as a control sitting
    -- in the corner, rather than an easy-to-miss sliver of texture that
    -- blends into whatever's behind it.
    local box = grip:CreateTexture(nil, "BACKGROUND")
    box:SetAllPoints()
    box:SetColorTexture(0, 0, 0, 0.45)
    local edgeTop = grip:CreateTexture(nil, "BORDER")
    edgeTop:SetColorTexture(0.95, 0.82, 0.45, 0.9)
    edgeTop:SetPoint("TOPLEFT")
    edgeTop:SetPoint("TOPRIGHT")
    edgeTop:SetHeight(1)
    local edgeLeft = grip:CreateTexture(nil, "BORDER")
    edgeLeft:SetColorTexture(0.95, 0.82, 0.45, 0.9)
    edgeLeft:SetPoint("TOPLEFT")
    edgeLeft:SetPoint("BOTTOMLEFT")
    edgeLeft:SetWidth(1)

    -- Hand-drawn diagonal lines (the classic Windows/macOS resize-corner
    -- look) instead of a Blizzard atlas icon or a text glyph - both of those
    -- can silently render as nothing if the texture/font doesn't have that
    -- piece, which is what was happening here before (an empty box with no
    -- visible arrow). Three short gold diagonal strokes, stepping toward
    -- the corner, so it unmistakably reads as "drag to resize."
    grip.diagLines = {}
    local function DiagLine(len, inset)
        local t = grip:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(0.95, 0.82, 0.45, 0.95)
        t:SetSize(len, 2)
        t:SetPoint("CENTER", grip, "BOTTOMRIGHT", -inset, inset)
        t:SetRotation(math.rad(45))
        table.insert(grip.diagLines, t)
        return t
    end
    DiagLine(6, 6)
    DiagLine(10, 11)
    DiagLine(14, 17)
    grip:RegisterForDrag("LeftButton")
    grip:SetScript("OnDragStart", function(self)
        self.dragging = true
        self.startX, self.startY = GetCursorPosition()
        self.startScale = CurrentScale()
    end)
    grip:SetScript("OnDragStop", function(self) self.dragging = false end)
    grip:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local x, y = GetCursorPosition()
        local delta = ((x - self.startX) + (self.startY - y)) / 2 / 260
        ns.SetUIScale(self.startScale + delta)
    end)
    grip:SetScript("OnEnter", function(self)
        for _, l in ipairs(self.diagLines) do l:SetColorTexture(1, 1, 1, 1) end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:AddLine("Scales both AH Watch windows together - useful if the game's UI", 1, 1, 1, true)
        GameTooltip:AddLine("scale is different on this computer than what it was built for.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function(self)
        for _, l in ipairs(self.diagLines) do l:SetColorTexture(0.95, 0.82, 0.45, 0.95) end
        GameTooltip:Hide()
    end)
end

ns.AddScaleGrip(f)

local titleFS
if f.TitleText then
    f.TitleText:SetText("AH Watch")
    titleFS = f.TitleText
else
    local bg = CreateFrame("Frame", nil, f, (BackdropTemplateMixin and "BackdropTemplate") or nil)
    bg:SetAllPoints()
    bg:SetFrameLevel(f:GetFrameLevel())
    bg:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOP", 0, -8)
    t:SetText("AH Watch")
    titleFS = t
    local c = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    c:SetPoint("TOPRIGHT", -2, -2)
end

local function Label(text, x, y, font)
    local fs = f:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- Gold / silver / copper input: three small boxes, each with up/down arrows
-- and its coin icon. Mouse wheel works too; hold Shift to step by 10.
-- Themed coin sets: each entry names a tier (used to build the file path)
-- so any theme can supply its own gold/silver/copper icons just by adding
-- three files named coin_<tier>_<theme>.tga in the art folder.
local COINS = {
    { mult = 10000, width = 50, max = nil, icon = "Interface\\MoneyFrame\\UI-GoldIcon", tier = "gold" },
    { mult = 100,   width = 28, max = 99,  icon = "Interface\\MoneyFrame\\UI-SilverIcon", tier = "silver" },
    { mult = 1,     width = 28, max = 99,  icon = "Interface\\MoneyFrame\\UI-CopperIcon", tier = "copper" },
}
local THEMED_COIN_SETS = { spacew = true, onlylawns = true }   -- themes with their own coin art

-- Every coin icon created anywhere, so the active theme can swap them all
-- at once (and back) when the look changes.
local coinIcons = {}
function ns.RefreshCoinIcons()
    local themed = THEMED_COIN_SETS[ns.theme]
    for _, entry in ipairs(coinIcons) do
        local ok = false
        if themed then
            local path = "Interface\\AddOns\\AHWatch\\art\\coin_" .. entry.coin.tier .. "_" .. ns.theme .. ".tga"
            ok = pcall(entry.icon.SetTexture, entry.icon, path)
        end
        if not ok then entry.icon:SetTexture(entry.coin.icon) end
    end
end

local function MoneyInput(x, y, onChange, parent)
    parent = parent or f
    local m = { boxes = {}, quiet = false }
    local anchor, anchorX = nil, x
    for i, coin in ipairs(COINS) do
        local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
        box:SetSize(coin.width, 20)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetJustifyH("RIGHT")
        box:SetMaxLetters(coin.max and 2 or 7)
        box:SetText("0")
        if anchor then
            box:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
        else
            box:SetPoint("TOPLEFT", parent, "TOPLEFT", anchorX, y)
        end

        local function Get() return tonumber(box:GetText()) or 0 end
        local function Set(v)
            v = math.max(0, v)
            if coin.max then v = math.min(coin.max, v) end
            box:SetText(tostring(v))
        end
        local function Step(dir)
            local step = IsShiftKeyDown() and 10 or 1
            Set(Get() + dir * step)
        end

        local up = CreateFrame("Button", nil, parent)
        up:SetSize(14, 10)
        up.pbArrow = true
        up:SetPoint("TOPLEFT", box, "TOPRIGHT", 1, 1)
        up:SetNormalTexture("Interface\\Buttons\\Arrow-Up-Up")
        up:SetPushedTexture("Interface\\Buttons\\Arrow-Up-Down")
        up:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        up:SetScript("OnClick", function() Step(1) end)

        local down = CreateFrame("Button", nil, parent)
        down:SetSize(14, 10)
        down.pbArrow = true
        down:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 1, -1)
        down:SetNormalTexture("Interface\\Buttons\\Arrow-Down-Up")
        down:SetPushedTexture("Interface\\Buttons\\Arrow-Down-Down")
        down:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        down:SetScript("OnClick", function() Step(-1) end)

        local icon = parent:CreateTexture(nil, "ARTWORK")
        icon:SetSize(13, 13)
        icon:SetPoint("LEFT", up, "RIGHT", 1, -5)
        icon:SetTexture(coin.icon)
        table.insert(coinIcons, { icon = icon, coin = coin })

        box:EnableMouseWheel(true)
        box:SetScript("OnMouseWheel", function(_, delta) Step(delta > 0 and 1 or -1) end)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        box:SetScript("OnTextChanged", function(self)
            if coin.max and Get() > coin.max then Set(coin.max) return end
            if not m.quiet and m.onChange then m.onChange(m.GetValue()) end
        end)

        m.boxes[i] = { box = box, coin = coin }
        anchor = icon
    end

    function m.GetValue()
        local total = 0
        for _, b in ipairs(m.boxes) do
            total = total + (tonumber(b.box:GetText()) or 0) * b.coin.mult
        end
        return total
    end

    function m.SetValue(copper)
        copper = math.floor(math.max(0, copper or 0))
        m.quiet = true
        m.boxes[1].box:SetText(tostring(math.floor(copper / 10000)))
        m.boxes[2].box:SetText(tostring(math.floor(copper / 100) % 100))
        m.boxes[3].box:SetText(tostring(copper % 100))
        m.quiet = false
    end

    m.onChange = onChange
    return m
end

-- Shared with Sell.lua
ns.MoneyInput = MoneyInput
ns.Money = Money
ns.Msg = Msg
ns.GetRuntime = function() return runtime end
ns.IsAHOpen = function() return ahOpen end
ns.Ready = Ready

-- Find an item
Label("Find item:", 14, -32)
local searchBox = CreateFrame("EditBox", "AHWatchSearchBox", f, "InputBoxTemplate")
searchBox:SetSize(236, 20)
searchBox:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -48)
searchBox:SetAutoFocus(false)
searchBox:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Type a name, or shift-click an item to fill this in.", nil, nil, nil, nil, true)
    GameTooltip:Show()
end)
searchBox:HookScript("OnLeave", function() GameTooltip:Hide() end)
local searchBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
searchBtn:SetSize(76, 22)
searchBtn:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
searchBtn:SetText("Search")

local browseRows = {}
for i = 1, BROWSE_ROWS do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(330, 20)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -74 - (i - 1) * 20)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", 2, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.name:SetWidth(180)
    b.name:SetJustifyH("LEFT")
    b.price = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.price:SetPoint("RIGHT", -4, 0)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(1, 0.82, 0, 0.15)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:Hide()
    browseRows[i] = b
end

-- Max price + add
Label("Max price each:", 14, -200)
local maxMoney = MoneyInput(22, -216)

Label("or", 22, -246, "GameFontHighlightSmall")
local pctBox = CreateFrame("EditBox", "AHWatchPctBox", f, "InputBoxTemplate")
pctBox:SetSize(34, 20)
pctBox:SetPoint("TOPLEFT", f, "TOPLEFT", 44, -242)
pctBox:SetAutoFocus(false)
pctBox:SetNumeric(true)
pctBox:SetMaxLetters(3)
local pctLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pctLabel:SetPoint("LEFT", pctBox, "RIGHT", 4, 0)
pctLabel:SetText("% market")
pctBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

-- How many to buy in total (0 = as many as fit your price and limit)
Label("Buy up to", 22, -272, "GameFontHighlightSmall")
local qtyBox = CreateFrame("EditBox", "AHWatchQtyBox", f, "InputBoxTemplate")
qtyBox:SetSize(50, 20)
qtyBox:SetPoint("TOPLEFT", f, "TOPLEFT", 80, -268)
qtyBox:SetAutoFocus(false)
qtyBox:SetNumeric(true)
qtyBox:SetMaxLetters(6)
qtyBox:SetJustifyH("RIGHT")
qtyBox:SetText("0")
local function QtyStep(dir)
    local v = (tonumber(qtyBox:GetText()) or 0) + dir * (IsShiftKeyDown() and 10 or 1)
    qtyBox:SetText(tostring(math.max(0, v)))
end
local qtyUp = CreateFrame("Button", nil, f)
qtyUp:SetSize(14, 10)
qtyUp.pbArrow = true
qtyUp:SetPoint("TOPLEFT", qtyBox, "TOPRIGHT", 1, 1)
qtyUp:SetNormalTexture("Interface\\Buttons\\Arrow-Up-Up")
qtyUp:SetPushedTexture("Interface\\Buttons\\Arrow-Up-Down")
qtyUp:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
qtyUp:SetScript("OnClick", function() QtyStep(1) end)
local qtyDown = CreateFrame("Button", nil, f)
qtyDown:SetSize(14, 10)
qtyDown.pbArrow = true
qtyDown:SetPoint("BOTTOMLEFT", qtyBox, "BOTTOMRIGHT", 1, -1)
qtyDown:SetNormalTexture("Interface\\Buttons\\Arrow-Down-Up")
qtyDown:SetPushedTexture("Interface\\Buttons\\Arrow-Down-Down")
qtyDown:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
qtyDown:SetScript("OnClick", function() QtyStep(-1) end)
qtyBox:EnableMouseWheel(true)
qtyBox:SetScript("OnMouseWheel", function(_, delta) QtyStep(delta > 0 and 1 or -1) end)
qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
qtyBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
local qtyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
qtyLabel:SetPoint("LEFT", qtyBox, "RIGHT", 20, 0)
qtyLabel:SetText("total  (0=any)")

local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
addBtn:SetSize(110, 22)
addBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -240)
addBtn:SetText("Add to list")
addBtn.pbPrimary = true

-- Watch list
Label("Watch list:", 14, -300)

-- Whether the shared button cycles through the whole list when the selected
-- item has nothing to buy right now, or just keeps re-checking that one item.
local cycleBox = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
cycleBox:SetSize(20, 20)
cycleBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -298)
local cycleLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cycleLabel:SetPoint("RIGHT", cycleBox, "LEFT", -4, 0)
cycleLabel:SetJustifyH("RIGHT")
cycleLabel:SetWidth(110)
cycleLabel:SetText("Cycle list")
cycleBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Cycle list", 1, 1, 1)
    GameTooltip:AddLine("Checked: pressing the button moves on to the next watched item once the selected one has nothing to buy.", 1, 0.9, 0.6, true)
    GameTooltip:AddLine("Unchecked: it only keeps re-checking the item you clicked, ignoring the rest of the list.", 1, 0.9, 0.6, true)
    GameTooltip:Show()
end)
cycleBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
cycleBox:SetScript("OnClick", function(self)
    EnsureDB()
    AHWatchDB.cycleList = self:GetChecked() and true or false
end)

local watchRows = {}
for i = 1, WATCH_ROWS do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(330, 28)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -316 - (i - 1) * 30)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(24, 24)
    b.icon:SetPoint("LEFT", 2, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 6, 0)
    b.name:SetWidth(260)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.info = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.info:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 6, 0)
    b.info:SetWidth(270)
    b.info:SetJustifyH("LEFT")
    b.info:SetWordWrap(false)
    b.next = b:CreateTexture(nil, "BACKGROUND")
    b.next:SetAllPoints()
    b.next:SetColorTexture(0.2, 0.6, 1, 0.15)
    b.remove = CreateFrame("Button", nil, b, "UIPanelCloseButton")
    b.remove.pbClose = true
    b.remove:SetSize(22, 22)
    b.remove:SetPoint("RIGHT", 0, 0)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:Hide()
    watchRows[i] = b
end

-- Spend limit
Label("Spend limit:", 14, -534)
local capMoney = MoneyInput(22, -550)
local spentLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
spentLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -580)
local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
resetBtn:SetSize(90, 20)
resetBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -576)
resetBtn:SetText("Reset spent")
resetBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Resets the gold spent and the bought counts.", 1, 1, 1)
    GameTooltip:Show()
end)
resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- The main button
local goBtn = CreateFrame("Button", "AHWatchGoButton", f, "UIPanelButtonTemplate")
goBtn:SetSize(332, 32)
goBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 36)

local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
cancelBtn:SetSize(80, 20)
cancelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
cancelBtn:SetText("Cancel")
cancelBtn:Hide()

local bindBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
bindBtn:SetSize(112, 20)
bindBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -142, 10)

-- Look switcher: cycles Auction (matches the game's AH window) -> Classic
-- (the plain, untouched WoW window) -> Trader (flat trading-app style) ->
-- Space W -> OnlyLawns -> back to Auction.
-- Shifted in from the corner (was -14) so the resize grip there has room
-- and doesn't sit on top of the button.
local themeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
themeBtn:SetSize(108, 20)
themeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 10)
themeBtn:SetNormalFontObject(GameFontNormalSmall)
themeBtn:SetHighlightFontObject(GameFontHighlightSmall)
local THEME_NEXT = { auction = "classic", classic = "trader", trader = "spacew", spacew = "onlylawns", onlylawns = "auction" }
local THEME_LABEL = { auction = "Auction", classic = "Classic", trader = "Trader", spacew = "Space W", onlylawns = "OnlyLawns" }
local function CurrentTheme() return (AHWatchDB and AHWatchDB.theme) or "auction" end
local TITLE_TEXT = { spacew = "Toast to the Moon", onlylawns = "OnlyLawns" }
local function ThemeLabel()
    themeBtn:SetText("Look: " .. THEME_LABEL[CurrentTheme()])
    if titleFS then titleFS:SetText(TITLE_TEXT[CurrentTheme()] or "AH Watch") end
end
themeBtn:SetScript("OnClick", function()
    AHWatchDB.theme = THEME_NEXT[CurrentTheme()]
    ThemeLabel()
    if ns.ApplyTheme then ns.ApplyTheme(AHWatchDB.theme) end
end)
themeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Change the look")
    GameTooltip:AddLine("Auction matches the game's own Auction House window.", 1, 1, 1, true)
    GameTooltip:AddLine("Classic is the plain WoW window look.", 1, 1, 1, true)
    GameTooltip:AddLine("Trader is a flat trading-app style.", 1, 1, 1, true)
    GameTooltip:AddLine("Space W is a custom look with your own background art.", 1, 1, 1, true)
    GameTooltip:AddLine("OnlyLawns is a custom look with your own lawn photo.", 1, 1, 1, true)
    GameTooltip:Show()
end)
themeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
ns.ThemeLabel = ThemeLabel
bindBtn:SetNormalFontObject(GameFontNormalSmall)
bindBtn:SetHighlightFontObject(GameFontHighlightSmall)
bindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

------------------------------------------------------------
-- Keybind (only active while the auction house is open)
------------------------------------------------------------

local keyOwner = CreateFrame("Frame")
local capturing = false

local function GetKey() return (AHWatchDB and AHWatchDB.keybind) or DEFAULT_KEY end
ns.GetKey = GetKey

local function ApplyKey()
    ClearOverrideBindings(keyOwner)
    if ahOpen then SetOverrideBindingClick(keyOwner, true, GetKey(), "AHWatchGoButton") end
end

local function StopCapture()
    capturing = false
    f:SetScript("OnKeyDown", nil)
    f:EnableKeyboard(false)
    Update()
end

local IGNORE_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, UNKNOWN = true }

bindBtn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
        AHWatchDB.keybind = nil
        ApplyKey()
        if capturing then StopCapture() else Update() end
        return
    end
    if capturing then StopCapture() return end
    capturing = true
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(false)
    f:SetScript("OnKeyDown", function(_, key)
        if IGNORE_KEYS[key] then return end
        if key ~= "ESCAPE" then
            local combo = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
                .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
            AHWatchDB.keybind = (combo ~= DEFAULT_KEY) and combo or nil
            ApplyKey()
            Msg(combo .. " now presses the main button while the auction house is open.")
        end
        StopCapture()
    end)
    Update()
end)
bindBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Keybind")
    GameTooltip:AddLine("Left-click, then press a key. Right-click to reset.", 1, 1, 1)
    GameTooltip:AddLine("Only active while the auction house is open.", 1, 1, 1)
    GameTooltip:Show()
end)
bindBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

------------------------------------------------------------
-- Updating the window
------------------------------------------------------------

local function GoText()
    local list = AHWatchDB.watch
    if not ahOpen then return "Open the Auction House" end
    if state == "searching" then return "Searching..." end
    if state == "pricing" then return "Checking the price..." end
    if state == "buying" then return "Buying..." end
    if state == "confirm" and purchase then
        return "Confirm: " .. purchase.qty .. "x " .. (purchase.name or "") .. " for " .. Money(purchase.total)
    end
    if #list == 0 then return "Add an item to watch" end
    if LimitReached() then return "Spend limit reached - raise it or Reset spent" end
    if current > #list then current = 1 end
    local w = list[current]
    local r = runtime[w.itemID]
    if not r or not r.rows or GetTime() - r.time > STALE_AFTER then
        return "Search: " .. (w.name or "item")
    end
    local plan = Plan(w)
    if plan and plan.kind == "commodity" then
        return "Buy " .. plan.qty .. "x " .. (w.name or "") .. " for " .. Money(plan.total)
    elseif plan then
        return "Buy " .. (w.name or "item") .. " for " .. Money(plan.price)
    end
    local nextW = list[current % #list + 1]
    return "None under price - check " .. (nextW.name or "next")
end

-- Used by Flip opportunities (Prices.lua): adds an item to the watch list at
-- a given max price if it isn't already watched, makes it the next one up,
-- switches to the Buy tab, and opens the window - so one press of the key
-- is all that's left to actually buy it.
function ns.QuickBuySetup(itemID, name, maxCopper)
    EnsureDB()
    local idx
    for i, entry in ipairs(AHWatchDB.watch) do
        if entry.itemID == itemID then idx = i break end
    end
    if not idx then
        if #AHWatchDB.watch >= 7 then
            Msg("your watch list is full (7) - remove an item first, or add " .. (name or "this item")
                .. " yourself with a smaller max price.")
            return false
        end
        table.insert(AHWatchDB.watch, { itemID = itemID, name = name })
        idx = #AHWatchDB.watch
    end
    local w = AHWatchDB.watch[idx]
    w.maxCopper, w.maxPct = maxCopper, nil
    w.name = w.name or name
    current = idx
    if ns.SetTab then ns.SetTab("buy") end
    f:Show()
    if Update then Update() end
    Msg("ready to buy " .. (w.name or "that item") .. " at or under " .. Money(maxCopper)
        .. " - press " .. GetKey() .. " to search and buy it.")
    return true
end

function Update()
    EnsureDB()
    -- Name search results
    for i, b in ipairs(browseRows) do
        local e = browse[i]
        if e then
            e.name = e.name or ItemName(e.itemID)
            b.icon:SetTexture(ItemIcon(e.itemID))
            b.name:SetText(e.name or "Loading...")
            b.price:SetText(e.minPrice and ("from " .. Money(e.minPrice)) or "")
            b.sel:SetShown(selectedBrowse == e)
            b.entry = e
            b:Show()
        else
            b:Hide()
        end
    end

    -- Watch list
    local list = AHWatchDB.watch
    for i, b in ipairs(watchRows) do
        local w = list[i]
        if w then
            w.name = w.name or ItemName(w.itemID)
            b.icon:SetTexture(ItemIcon(w.itemID))
            b.name:SetText(w.name or "Loading...")
            local r = runtime[w.itemID]
            local status
            if not r or not r.rows then
                status = "not checked"
            else
                local _, summary = Plan(w)
                if summary and summary.note then
                    status = summary.note
                elseif summary and summary.under > 0 then
                    status = summary.under .. " under, can afford " .. summary.afford
                    if summary.afford == 0 and LimitReached() then
                        status = status .. " |cffff5555(limit)|r"
                    elseif summary.afford == 0 then
                        status = status .. " |cffff5555(gold)|r"
                    end
                else
                    status = "none under"
                end
            end
            local progress = ""
            if w.maxQty and w.maxQty > 0 then
                progress = "  bought " .. (w.bought or 0) .. "/" .. w.maxQty
            elseif (w.bought or 0) > 0 then
                progress = "  bought " .. w.bought
            end
            b.info:SetText("max " .. MaxText(w) .. progress .. "  |cffaaaaaa" .. status .. "|r")
            b.next:SetShown(i == current)
            b.index = i
            b:Show()
        else
            b:Hide()
        end
    end

    local capText = AHWatchDB.capCopper and (" of " .. Money(AHWatchDB.capCopper) .. " limit") or " (no limit)"
    if LimitReached() then capText = capText .. " |cffff5555- limit reached|r" end
    spentLabel:SetText("Spent: " .. Money(spent) .. capText)
    if CurrentTab() == "buy" then
        goBtn:SetText(GoText() .. "  |cff888888(" .. GetKey() .. ")|r")
        cancelBtn:SetShown(state == "pricing" or state == "confirm")
    end
    if selectedBrowse and FindWatch(selectedBrowse.itemID) then
        addBtn:SetText("On list (saved)")
        addBtn:Disable()
    else
        addBtn:SetText("Add to list")
        addBtn:SetEnabled(selectedBrowse ~= nil)
    end
    bindBtn:SetText(capturing and "Press a key..." or ("Key: " .. GetKey()))
    ThemeLabel()
end
ns.Update = Update

------------------------------------------------------------
-- Wiring
------------------------------------------------------------

local function PickFromText()
    local text = searchBox:GetText() or ""
    local id = tonumber(text:match("item:(%d+)"))
    if id then
        local e = { itemID = id, name = ItemName(id) }
        browse = { e }
        selectedBrowse = e
        Update()
        return
    end
    if text == "" then return end
    if not ahOpen then Msg("open the auction house to search.") return end
    browse, selectedBrowse = {}, nil
    browsePending = true
    local query = {
        searchString = text,
        sorts = { { sortOrder = SORT_PRICE, reverseSort = false } },
        filters = {},
        itemClassFilters = {},
    }
    local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, query)
    if not ok then Msg("search failed: " .. tostring(err)) end
    Update()
end

searchBtn:SetScript("OnClick", PickFromText)
searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); PickFromText() end)
searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
-- If the picked item is already on the watch list, changes apply right away
local function LiveEdit()
    local e = selectedBrowse
    local w = e and FindWatch(e.itemID)
    if not w then Update() return end
    local pct = tonumber(pctBox:GetText() or "")
    if pct and pct > 0 then
        w.maxPct, w.maxCopper = pct, nil
    elseif maxMoney.GetValue() > 0 then
        w.maxCopper, w.maxPct = maxMoney.GetValue(), nil
    end
    local q = tonumber(qtyBox:GetText() or "") or 0
    w.maxQty = (q > 0) and q or nil
    if ns.ShowGraph then ns.ShowGraph(w.itemID, MaxPriceFor(w)) end
    Update()
end
qtyBox:SetScript("OnTextChanged", function(_, userInput) if userInput then LiveEdit() end end)
qtyUp:HookScript("OnClick", LiveEdit)
qtyDown:HookScript("OnClick", LiveEdit)
qtyBox:HookScript("OnMouseWheel", LiveEdit)
maxMoney.onChange = LiveEdit
pctBox:SetScript("OnTextChanged", function(_, userInput) if userInput then LiveEdit() end end)

capMoney.onChange = function(value)
    AHWatchDB.capCopper = (value > 0) and value or nil
    Update()
end
resetBtn:SetScript("OnClick", function()
    spent = 0
    for _, w in ipairs(AHWatchDB.watch) do w.bought = nil end
    Update()
end)

-- Shift-clicking an item while the search box is focused puts its link there
if ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if link and searchBox:HasFocus() then
            searchBox:SetText(link)
            PickFromText()
        end
    end)
end

for _, b in ipairs(browseRows) do
    b:SetScript("OnClick", function(self)
        selectedBrowse = self.entry
        searchBox:SetText(self.entry.name or "")
        -- Start the max at 80% of the market price when Auctionator knows it
        local market = MarketPrice(self.entry.itemID)
        maxMoney.SetValue(market and math.floor(market * 0.8) or 0)
        pctBox:SetText("")
        local existing = FindWatch(self.entry.itemID)
        qtyBox:SetText(tostring(existing and existing.maxQty or 0))
        if ns.ShowGraph then ns.ShowGraph(self.entry.itemID, existing and MaxPriceFor(existing)) end
        Update()
    end)
end

local function AddSelected()
    EnsureDB()
    local e = selectedBrowse
    if not e then Msg("pick an item first (search, then click one).") return end
    local max
    local pct = tonumber(pctBox:GetText() or "")
    if pct and pct > 0 then
        max = { pct = pct }
    elseif maxMoney.GetValue() > 0 then
        max = { copper = maxMoney.GetValue() }
    end
    if not max then Msg("set a max price with the coin boxes (or a % of market).") return end
    if max.pct and not MarketPrice(e.itemID) then
        Msg("Auctionator has no price for that item yet, so a % won't work. Enter a gold amount instead.")
        return
    end
    local w = FindWatch(e.itemID)
    if not w then
        if #AHWatchDB.watch >= WATCH_ROWS then Msg("the watch list is full - remove one first.") return end
        w = { itemID = e.itemID }
        table.insert(AHWatchDB.watch, w)
    end
    w.itemKey = e.itemKey
    w.name = e.name or ItemName(e.itemID)
    w.maxCopper, w.maxPct = max.copper, max.pct
    local q = tonumber(qtyBox:GetText() or "") or 0
    w.maxQty = (q > 0) and q or nil
    Update()
end
addBtn:SetScript("OnClick", AddSelected)
pctBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); AddSelected() end)

for _, b in ipairs(watchRows) do
    b:SetScript("OnClick", function(self)
        current = self.index
        local w = AHWatchDB.watch[self.index]
        if w then
            -- Load it into the inputs so its max price can be changed with "Add to list"
            local e = { itemID = w.itemID, itemKey = w.itemKey, name = w.name }
            browse, selectedBrowse = { e }, e
            searchBox:SetText(w.name or "")
            qtyBox:SetText(tostring(w.maxQty or 0))
            if ns.ShowGraph then ns.ShowGraph(w.itemID, MaxPriceFor(w)) end
            if w.maxPct then
                pctBox:SetText(tostring(w.maxPct))
                maxMoney.SetValue(0)
            else
                pctBox:SetText("")
                maxMoney.SetValue(w.maxCopper or 0)
            end
        end
        Update()
    end)
    b.remove:SetScript("OnClick", function(self)
        local i = self:GetParent().index
        local w = AHWatchDB.watch[i]
        if w then runtime[w.itemID] = nil end
        table.remove(AHWatchDB.watch, i)
        if current > #AHWatchDB.watch then current = 1 end
        Update()
    end)
end

goBtn:SetScript("OnClick", Go)
cancelBtn:SetScript("OnClick", CancelBuy)
f:SetScript("OnShow", Update)

SLASH_AHWATCH1 = "/ahw"
SLASH_AHWATCH2 = "/ahwatch"
SlashCmdList["AHWATCH"] = function(msg)
    local mb = (msg or ""):match("^%s*limit%s*(%S*)")
    local ml = (msg or ""):match("^%s*minlisted%s*(%S*)")
    local ma = (msg or ""):match("^%s*avgqty%s*(%S*)")
    if (msg or ""):match("^%s*data%s*$") and ns.PrintData then
        ns.PrintData()
    elseif mb and ns.SetLimit then
        ns.SetLimit(mb)
    elseif ml then
        local n = tonumber(ml)
        if not n or n < 0 then
            EnsureDB()
            print("|cff33ccffAHWatch:|r usage: /ahw minlisted <number>  (currently "
                .. ((AHWatchDB.minListed or 8)) .. " - how many need to be listed "
                .. "before an item shows up in Flip opportunities)")
        else
            EnsureDB()
            AHWatchDB.minListed = n
            print("|cff33ccffAHWatch:|r Flip opportunities now needs at least " .. n .. " listed to show an item.")
            if ns.RefreshFlips then ns.RefreshFlips() end
        end
    elseif ma then
        local n = tonumber(ma)
        if not n or n < 1 then
            EnsureDB()
            print("|cff33ccffAHWatch:|r usage: /ahw avgqty <number>  (currently "
                .. ((AHWatchDB.avgMinQty or 8)) .. " - how many need to be listed on a "
                .. "given day before that day's price counts toward Average/trend at all. "
                .. "Higher = more resistant to undercutters, but needs busier markets to work.")
        else
            EnsureDB()
            AHWatchDB.avgMinQty = n
            print("|cff33ccffAHWatch:|r Average price and bag-arrow trend now need at least "
                .. n .. " listed on a day before trusting that day's price.")
            if ns.RefreshGraph then ns.RefreshGraph() end
        end
    else
        f:SetShown(not f:IsShown())
    end
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

local ev = CreateFrame("Frame")
for _, e in ipairs({
    "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
    "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "PLAYER_MONEY", "GET_ITEM_INFO_RECEIVED",
}) do
    pcall(ev.RegisterEvent, ev, e)
end

ev:SetScript("OnEvent", function(_, e, a1, a2)
    if e == "ADDON_LOADED" and a1 == "AHWatch" then
        EnsureDB()
        -- Older versions stored the limit in whole gold
        if AHWatchDB.cap and not AHWatchDB.capCopper then
            AHWatchDB.capCopper = (tonumber(AHWatchDB.cap) or 0) * 10000
            if AHWatchDB.capCopper <= 0 then AHWatchDB.capCopper = nil end
        end
        AHWatchDB.cap = nil
        -- Save the game's interface number so the outside updater can keep
        -- "## Interface:" in AHWatch.toc matching it (no "out of date")
        local _, _, _, toc = GetBuildInfo()
        if toc then AHWatchDB.clientToc = toc end
        -- Say so in chat the first time a new version loads
        local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local version = getMeta and getMeta("AHWatch", "Version")
        if version and AHWatchDB.lastVersion and AHWatchDB.lastVersion ~= version then
            Msg("updated to version " .. version .. " (was " .. AHWatchDB.lastVersion .. ").")
        end
        if version then AHWatchDB.lastVersion = version end
        -- One-time pointer to the auto-updater that ships in the addon folder
        if not AHWatchDB.updateHintShown then
            AHWatchDB.updateHintShown = true
            C_Timer.After(5, function()
                Msg("to keep AHWatch up to date automatically (Windows), open your "
                    .. "Interface\\AddOns\\AHWatch folder and double-click \"Turn on auto-update\". You only do this once.")
            end)
        end
        capMoney.SetValue(AHWatchDB.capCopper or 0)
        cycleBox:SetChecked(AHWatchDB.cycleList ~= false)
        return
    end
    if not AHWatchDB then return end

    if e == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        ApplyKey()
        f:ClearAllPoints()
        local p = AHWatchDB.pos
        if p then
            f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        elseif AuctionHouseFrame then
            f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
        else
            f:SetPoint("CENTER")
        end
        f:Show()
        Update()
        local w = AHWatchDB.watch[current] or AHWatchDB.watch[1]
        if w and ns.ShowGraph then ns.ShowGraph(w.itemID, MaxPriceFor(w)) end

    elseif e == "AUCTION_HOUSE_CLOSED" then
        if state == "pricing" or state == "confirm" then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
        ahOpen = false
        purchase = nil
        state = "idle"
        runtime = {}
        ApplyKey()
        f:Hide()

    elseif e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        -- Ignore results from the auction house's own search box
        if not browsePending then return end
        browsePending = false
        browse = {}
        local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
        for _, res in ipairs((ok and results) or {}) do
            if res.itemKey and #browse < BROWSE_ROWS then
                table.insert(browse, {
                    itemID = res.itemKey.itemID, itemKey = res.itemKey,
                    minPrice = res.minPrice, name = ItemName(res.itemKey.itemID),
                })
            end
        end
        if #browse == 0 then Msg("no results.") end
        Update()

    elseif e == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        local w = FindWatch(a1)
        local forSell = ns.sellSearchID == a1
        if not w and not forSell then return end
        if w then w.isCommodity = true end
        local rows = {}
        for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(a1) or 0 do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(a1, i)
            if r and r.unitPrice and r.quantity then
                table.insert(rows, { unitPrice = r.unitPrice, quantity = r.quantity, own = r.containsOwnerItem })
            end
        end
        table.sort(rows, function(x, y) return x.unitPrice < y.unitPrice end)
        runtime[a1] = { rows = rows, time = GetTime() }
        if ns.RecordRows then ns.RecordRows(a1, rows, true) end
        if state == "searching" and w then state = "idle" end
        if forSell and ns.OnSellResults then ns.OnSellResults(a1, rows, true) end
        Update()

    elseif e == "ITEM_SEARCH_RESULTS_UPDATED" then
        local key = a1
        local w = key and FindWatch(key.itemID)
        local forSell = key and ns.sellSearchID == key.itemID
        if not w and not forSell then return end
        if w then w.isCommodity = false end
        local rows = {}
        for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) or 0 do
            local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
            if r and r.buyoutAmount then
                table.insert(rows, { auctionID = r.auctionID, buyout = r.buyoutAmount,
                    quantity = r.quantity or 1, own = r.containsOwnerItem })
            end
        end
        table.sort(rows, function(x, y) return x.buyout / math.max(x.quantity, 1) < y.buyout / math.max(y.quantity, 1) end)
        runtime[key.itemID] = { rows = rows, time = GetTime() }
        if ns.RecordRows then ns.RecordRows(key.itemID, rows, false) end
        if state == "searching" and w then state = "idle" end
        if forSell and ns.OnSellResults then ns.OnSellResults(key.itemID, rows, false) end
        Update()

    elseif e == "COMMODITY_PRICE_UPDATED" then
        if state ~= "pricing" or not purchase then return end
        local unitPrice, total = a1, a2
        -- Safety check: the real price must still be within your max, your gold and your limit
        if total and total <= purchase.qty * purchase.max and total <= Budget() then
            purchase.total = total
            SetState("confirm")
            Timeout("confirm", 15)
        else
            Msg("price went up to " .. Money(unitPrice or 0) .. " each - not buying. Press again to refresh.")
            pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            runtime[purchase.itemID] = nil
            purchase = nil
            SetState("idle")
        end

    elseif e == "COMMODITY_PRICE_UNAVAILABLE" then
        if purchase then runtime[purchase.itemID] = nil end
        Msg("those listings are gone - press again to refresh.")
        purchase = nil
        SetState("idle")

    elseif e == "COMMODITY_PURCHASE_SUCCEEDED" then
        if purchase then
            spent = spent + (purchase.total or 0)
            local w = FindWatch(purchase.itemID)
            if w then w.bought = (w.bought or 0) + purchase.qty end
            Msg("bought " .. purchase.qty .. "x " .. (purchase.name or "item") .. " for " .. Money(purchase.total or 0) .. ".")
            runtime[purchase.itemID] = nil
        end
        purchase = nil
        SetState("idle")

    elseif e == "COMMODITY_PURCHASE_FAILED" then
        if purchase then runtime[purchase.itemID] = nil end
        Msg("purchase failed - press again to refresh.")
        purchase = nil
        SetState("idle")

    elseif e == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" or e == "PLAYER_MONEY" or e == "GET_ITEM_INFO_RECEIVED" then
        if f:IsShown() then Update() end
    end
end)
