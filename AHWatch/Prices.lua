-- AHWatch price history
-- Saves a daily price summary for every item seen on the auction house
-- (lowest listing, average, amount listed), keeps it for 30 days within a size
-- limit (your watch list is always kept first), draws a graph next to the
-- AH Watch window, and adds the saved prices to item tooltips.

local _, ns = ...

local KEEP_DAYS = 30
local DEFAULT_LIMIT_MB = 50
local FULL_SCAN_COOLDOWN = 15 * 60
local FRAME_BUDGET_MS = 12       -- time spent saving per frame, so the game doesn't stutter
local FALLBACK_CHUNK = 3000      -- listings per frame if the timer isn't available

local sizeCache = nil
local scanning = false
local phase = "idle"             -- idle, waiting (for the server), saving
local phaseStart = 0
local progress = 0
local rangeDays = 30

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function Msg(text) print("|cff33ccffAHWatch:|r " .. text) end

-- Price history is kept as many short string chunks (AHWatchItemsData), not
-- as thousands of small nested Lua tables, and not as one giant single-line
-- string either. Either extreme can silently fail to load on some clients:
-- a saved-variables file with thousands of small tables can trip an internal
-- table-size limit, and some custom clients read the file with a fixed-size
-- line buffer, so one very long line can fail just as silently. Many short
-- lines avoid both.
--
-- runtimeItems is the working copy used while playing; it's decoded from
-- AHWatchItemsData once at login and re-encoded back into those chunks
-- whenever it changes, so what's actually written to disk stays in sync.
local runtimeItems = {}
local itemsDirty = false

local function EnsurePrices()
    if type(AHWatchPrices) ~= "table" or AHWatchPrices.v ~= 2 then
        -- v1 is the old, oversized table format; its items can't be trusted
        -- to have loaded (see above), so start clean rather than assume
        AHWatchPrices = { v = 2 }
    end
    return AHWatchPrices
end

-- Written as many short string chunks (not one giant line, and not thousands
-- of small tables) - some custom clients read saved files with a fixed-size
-- line buffer, and a single very long line can fail to load with no error
-- shown, the same way a huge table of tables can. This avoids both.
local CHUNK_SIZE = 3000

local function SplitChunks(str)
    local chunks = {}
    for i = 1, #str, CHUNK_SIZE do
        table.insert(chunks, str:sub(i, i + CHUNK_SIZE - 1))
    end
    return chunks
end

local function EncodeItems(items)
    local parts = {}
    for itemID, it in pairs(items) do
        local days = {}
        for _, d in ipairs(it.d or {}) do
            table.insert(days, table.concat(d, ","))
        end
        table.insert(parts, itemID .. " " ..
            table.concat(it.l or { 0, 0, 0, 0 }, ",") .. " " ..
            table.concat(it.lo or { 0, 0 }, ",") .. " " ..
            table.concat(it.hi or { 0, 0 }, ",") .. " " ..
            table.concat(days, ";"))
    end
    return table.concat(parts, "\n")
end

local function DecodeItems(str)
    local items = {}
    if type(str) ~= "string" or str == "" then return items end
    local function Nums(s)
        local t = {}
        for n in string.gmatch(s, "[^,]+") do table.insert(t, tonumber(n)) end
        return t
    end
    for line in string.gmatch(str, "[^\n]+") do
        local idStr, lStr, loStr, hiStr, dStr = string.match(line, "^(%d+) (%S+) (%S+) (%S+) (%S*)$")
        local itemID = idStr and tonumber(idStr)
        if itemID then
            local it = { l = Nums(lStr), lo = Nums(loStr), hi = Nums(hiStr), d = {} }
            if dStr and dStr ~= "" then
                for dayStr in string.gmatch(dStr, "[^;]+") do table.insert(it.d, Nums(dayStr)) end
            end
            items[itemID] = it
        end
    end
    return items
end

-- Writes the working copy back into the saved chunks. Cheap to call after a
-- batch of changes; avoid calling it once per item during a full scan.
local function SyncItemsString()
    AHWatchItemsData = SplitChunks(EncodeItems(runtimeItems))
    itemsDirty = false
    sizeCache = nil
end

local function MarkDirty()
    itemsDirty = true
    sizeCache = nil
end

local function LimitMB() return (AHWatchDB and AHWatchDB.limitMB) or DEFAULT_LIMIT_MB end

local function Money(copper)
    copper = math.floor(copper or 0)
    if GetMoneyString then return GetMoneyString(copper, true) end
    return string.format("%dg %ds %dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function Today() return math.floor(time() / 86400) end
local function DayText(day) return date("%b %d", day * 86400 + 43200) end

local function Ago(t)
    local s = time() - (t or 0)
    if s < 90 then return "just now" end
    if s < 5400 then return math.floor(s / 60) .. " min ago" end
    if s < 172800 then return math.floor(s / 3600) .. " hr ago" end
    return math.floor(s / 86400) .. " days ago"
end

local function IsWatched(itemID)
    for _, w in ipairs((AHWatchDB and AHWatchDB.watch) or {}) do
        if w.itemID == itemID then return true end
    end
    return false
end

------------------------------------------------------------
-- Saving prices
------------------------------------------------------------

-- One observation: lowest price each, average price each, how many listed
-- The full saved record for one item (latest/lowest/highest/daily history),
-- for anything else in the addon that needs to read it (e.g. the Sell tab).
function ns.GetPriceRecord(itemID)
    return runtimeItems[itemID]
end

local function Median(sorted)
    local n = #sorted
    if n == 0 then return nil end
    if n % 2 == 1 then return sorted[(n + 1) / 2] end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

-- A day only counts as a reliable price if enough copies were actually
-- listed that day - a day with just a couple auctions can be entirely one
-- undercutter's stack rather than a real market snapshot. Bumped up from 3:
-- undercutting happens constantly, and a low threshold let those thin,
-- undercut-heavy days outvote the normal ones.
local function TrustedQty(day) return (day[5] or 0) >= ((AHWatchDB and AHWatchDB.avgMinQty) or 8) end

-- The "typical" price for an item: the MEDIAN, across trusted (not-too-
-- thin) days, of each day's own AVERAGE listed price - not its cheapest
-- listing. This is the real fix for chronic undercutting: someone posting
-- a stack of Copper Ore at 20c when the going rate is 1s10c only drags a
-- day's *cheapest-listing* number down to 20c (100% wrong), but barely
-- budges that day's *quantity-weighted average* (the "avg" this addon
-- already computes from every listing seen during a scan, not just the
-- bottom one) since the undercut stack is a small slice of everything
-- listed. Taking the median across several such days on top of that still
-- protects against one unusually quiet or unusually flooded day. Returns
-- the price and how many days it's based on.
function ns.GetTypicalPrice(itemID)
    local it = runtimeItems[itemID]
    if not it or not it.d then return nil end
    local avgs = {}
    for _, d in ipairs(it.d) do
        if d[4] and d[4] > 0 and TrustedQty(d) then table.insert(avgs, d[4]) end
    end
    if #avgs == 0 then return nil end
    table.sort(avgs)
    return Median(avgs), #avgs
end

-- Day-over-day change for an item: today's saved daily-average price vs the
-- most recent earlier day that had a trustworthy amount listed. Uses the
-- same daily-average basis as GetTypicalPrice above, for the same reason -
-- comparing "cheapest listing" day to day mostly just tracked whichever
-- random undercut showed up that day, producing swings like "+6700%" that
-- had nothing to do with the real market moving.
-- Returns a percent (positive = price went up, negative = went down), or
-- nil if there isn't a trustworthy pair of days to compare.
-- Same hard sanity cap as Flip Opportunities: a swing bigger than this isn't
-- the market moving, it's bad data (an item that trades mostly via bids with
-- no buyout, so a lone stray buyout listing can dominate a day's "average").
local MAX_TREND_RATIO = 4

function ns.GetTrend(itemID)
    local it = runtimeItems[itemID]
    if not it or not it.d or #it.d < 2 then return nil end
    local today = it.d[#it.d]
    if not today or not today[4] or today[4] <= 0 or not TrustedQty(today) then return nil end
    for i = #it.d - 1, 1, -1 do
        local prev = it.d[i]
        if prev and prev[4] and prev[4] > 0 and TrustedQty(prev) then
            local hi, lo = math.max(today[4], prev[4]), math.min(today[4], prev[4])
            if hi > lo * MAX_TREND_RATIO then return nil end
            return (today[4] - prev[4]) / prev[4] * 100
        end
    end
    return nil
end

local function Record(itemID, low, avg, qty, t)
    if not itemID or not low or low <= 0 then return end
    local it = runtimeItems[itemID]
    if not it then
        it = { d = {} }
        runtimeItems[itemID] = it
    end
    t = t or time()
    low, avg = math.floor(low), math.floor(avg or low)
    it.l = { t, low, avg, qty or 0 }                       -- latest
    if not it.lo or low < it.lo[1] then it.lo = { low, t } end   -- lowest ever saved
    if not it.hi or low > it.hi[1] then it.hi = { low, t } end   -- highest ever saved

    local day = Today()
    local last = it.d[#it.d]
    if last and last[1] == day then
        last[2] = math.min(last[2], low)
        last[3] = math.max(last[3], low)
        last[4] = avg
        last[5] = qty or 0
    else
        table.insert(it.d, { day, low, low, avg, qty or 0 })
    end
    while it.d[1] and it.d[1][1] < day - KEEP_DAYS + 1 do table.remove(it.d, 1) end
    MarkDirty()
end

-- Summarizes search results the main window already fetched.
-- The "typical price" for a scan is the QUANTITY-WEIGHTED MEDIAN unit price,
-- not the quantity-weighted mean. A mean still gets dragged hard by a small
-- pile of way-overpriced listings: say 4000 units sit at ~1.5s but 70-odd
-- units are listed near 1g each (a scammer, a mistake, someone testing a
-- price) - that's under 2% of the stack by quantity, but because the mean
-- weights by total COPPER not by how many listings sit there, those 70
-- units alone can drag the "average" up several gold. The median instead
-- asks "what price is the middle unit going for" - walk the listings from
-- cheapest to priciest, stop once half the total quantity has been passed,
-- and that listing's price is what most of the stack is actually selling
-- at, however extreme the expensive tail gets.
function ns.RecordRows(itemID, rows, isCommodity)
    local low, qty = nil, 0
    local units = {}
    for _, r in ipairs(rows or {}) do
        local q = r.quantity or 1
        local unit = isCommodity and r.unitPrice or (r.buyout and r.buyout / math.max(q, 1))
        if unit and unit > 0 then
            if not low or unit < low then low = unit end
            qty = qty + q
            table.insert(units, { unit, q })
        end
    end
    if low and qty > 0 then
        table.sort(units, function(a, b) return a[1] < b[1] end)
        local half, cum, typical = qty / 2, 0, units[1][1]
        for _, u in ipairs(units) do
            cum = cum + u[2]
            typical = u[1]
            if cum >= half then break end
        end
        Record(itemID, low, typical, qty)
        SyncItemsString()
        if ns.RefreshGraph then ns.RefreshGraph() end
        if ns.RefreshFlips then ns.RefreshFlips() end
    end
end

-- Actual size of the saved chunks, in bytes
local function EstimateBytes()
    if sizeCache and not itemsDirty then return sizeCache end
    sizeCache = 300 + #EncodeItems(runtimeItems)
    return sizeCache
end

-- Keeps the file under the limit: drops the items seen longest ago first,
-- and never drops anything on your watch list.
local function Prune()
    local limit = LimitMB() * 1024 * 1024
    if EstimateBytes() <= limit then return 0 end
    local candidates = {}
    for id, it in pairs(runtimeItems) do
        if not IsWatched(id) then table.insert(candidates, { id = id, t = (it.l and it.l[1]) or 0 }) end
    end
    table.sort(candidates, function(a, b) return a.t < b.t end)
    local removed = 0
    for _, c in ipairs(candidates) do
        runtimeItems[c.id] = nil
        removed = removed + 1
        MarkDirty()
        if EstimateBytes() <= limit then break end
    end
    if removed > 0 then SyncItemsString() end
    return removed
end

------------------------------------------------------------
-- Full scan
------------------------------------------------------------

local function CooldownLeft()
    local last = EnsurePrices().lastFullScan or 0
    return math.max(0, last + FULL_SCAN_COOLDOWN - time())
end

-- Reads the whole auction house list in chunks and saves a summary per item.
-- Also runs when Auctionator does its own full scan, so either button works.
local SafeStep
local replicateBefore = 0      -- how many listings the game had before we asked for a scan

local function ProcessReplicate()
    if scanning then return end
    local n = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
    if n <= 0 then return end
    scanning = true
    -- Time how long the server took, if this is a scan we started
    local waited = (phase == "waiting") and (time() - phaseStart) or nil
    phase, phaseStart, progress = "saving", time(), 0
    local saveStart = GetTime()
    local agg, idx, listings = {}, 0, 0
    local clock = debugprofilestop
    local function Step()
        local started = clock and clock()
        local stop = clock and n or math.min(idx + FALLBACK_CHUNK, n)
        for i = idx, stop - 1 do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
            if itemID and buyout and buyout > 0 and count and count > 0 then
                local unit = buyout / count
                local a = agg[itemID]
                if not a then
                    a = { low = unit, sum = 0, qty = 0 }
                    agg[itemID] = a
                end
                if unit < a.low then a.low = unit end
                a.sum = a.sum + buyout
                a.qty = a.qty + count
                listings = listings + 1
            end
            idx = i + 1
            -- Stop for this frame once the time budget is used up
            if clock and (i % 200 == 0) and clock() - started > FRAME_BUDGET_MS then break end
        end
        progress = math.floor(idx / n * 100)
        if idx < n then
            C_Timer.After(0, SafeStep)
            return
        end
        local t, count = time(), 0
        for itemID, a in pairs(agg) do
            Record(itemID, a.low, a.sum / a.qty, a.qty, t)
            count = count + 1
        end
        local db = EnsurePrices()
        db.lastScanInfo = { t = t, items = count, listings = listings, raw = n }
        if waited then
            db.scanTimes = db.scanTimes or {}
            table.insert(db.scanTimes, { wait = waited, save = GetTime() - saveStart })
            while #db.scanTimes > 3 do table.remove(db.scanTimes, 1) end
        end
        local removed = Prune()
        SyncItemsString()
        scanning = false
        phase = "idle"
        Msg(string.format("full scan done: saved %d items (%d listings). Saved data: %.1f MB of %g MB%s.",
            count, listings, EstimateBytes() / 1048576, LimitMB(),
            removed > 0 and (", dropped " .. removed .. " old items to stay under the limit") or ""))
        if ns.RefreshGraph then ns.RefreshGraph() end
        if ns.RefreshFlips then ns.RefreshFlips() end
    end
    -- If anything goes wrong while saving, report it and reset instead of
    -- staying stuck on "scanning" (which would block every later scan)
    function SafeStep()
        local ok, err = pcall(Step)
        if not ok then
            scanning = false
            phase = "idle"
            Msg("full scan hit an error while saving - please send this to Claude: " .. tostring(err))
        end
    end
    SafeStep()
end

local function StartFullScan()
    if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
        Msg("this client doesn't support a full auction house scan.")
        return
    end
    if scanning and time() - phaseStart > 60 then scanning = false end   -- clear a stuck scan
    if scanning or phase == "waiting" then
        Msg("a full scan is already running.")
        return
    end
    local left = CooldownLeft()
    if left > 0 then
        Msg("the server allows a full scan every 15 minutes - " .. math.ceil(left / 60) .. " min left.")
        return
    end
    replicateBefore = (C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems()) or 0
    local ok, err = pcall(C_AuctionHouse.ReplicateItems)
    if not ok then
        Msg("full scan failed: " .. tostring(err))
        return
    end
    EnsurePrices().lastFullScan = time()
    phase, phaseStart = "waiting", time()
    Msg("full scan started - waiting for the server to send the auction house. The panel shows progress.")
    ns.RefreshFooter()
end

------------------------------------------------------------
-- Graph panel
------------------------------------------------------------

local main = AHWatchFrame
local ok, g = pcall(CreateFrame, "Frame", "AHWatchGraphFrame", main, "BasicFrameTemplateWithInset")
if not ok or not g then g = CreateFrame("Frame", "AHWatchGraphFrame", main) end
g:SetSize(340, 515)
g:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, 0)
if ns.AddScaleGrip then ns.AddScaleGrip(g) end
if g.TitleText then g.TitleText:SetText("Price history") end
if g.CloseButton then g.CloseButton:Hide() end
if not g.TitleText then
    local bg = g:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.9)
end

local itemTitle = g:CreateFontString(nil, "OVERLAY", "GameFontNormal")
itemTitle:SetPoint("TOPLEFT", g, "TOPLEFT", 14, -32)
itemTitle:SetWidth(120)
itemTitle:SetJustifyH("LEFT")
itemTitle:SetWordWrap(false)

-- 7 / 14 / 30 day buttons
local rangeBtns = {}
for i, days in ipairs({ 7, 14, 30 }) do
    local b = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    b:SetSize(36, 18)
    b:SetPoint("TOPRIGHT", g, "TOPRIGHT", -14 - (3 - i) * 38, -30)
    b:SetText(days .. "d")
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b:SetScript("OnClick", function()
        rangeDays = days
        ns.RefreshGraph()
    end)
    b.days = days
    rangeBtns[i] = b
end

local PLOT_W, PLOT_H = 256, 170
local plot = CreateFrame("Frame", nil, g)
plot:SetSize(PLOT_W, PLOT_H)
plot:SetPoint("TOPLEFT", g, "TOPLEFT", 66, -60)
local plotBg = plot:CreateTexture(nil, "BACKGROUND")
plotBg:SetAllPoints()
plotBg:SetColorTexture(0, 0, 0, 0.45)
local gridLines = {}
for i = 0, 3 do
    local grid = plot:CreateTexture(nil, "BORDER")
    gridLines[i] = grid
    grid:SetColorTexture(1, 1, 1, 0.08)
    grid:SetHeight(1)
    grid:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, PLOT_H * i / 3)
    grid:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, PLOT_H * i / 3)
end

local yLabels = {}
for i = 0, 3 do
    local fs = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, PLOT_H * i / 3)
    fs:SetJustifyH("RIGHT")
    yLabels[i] = fs
end
local xStart = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
xStart:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -3)
local xEnd = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
xEnd:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -3)

local emptyText = plot:CreateFontString(nil, "OVERLAY", "GameFontDisable")
emptyText:SetPoint("CENTER")
emptyText:SetWidth(PLOT_W - 20)
emptyText:SetText("No saved prices yet.\nSearch this item or run a full scan.")

-- Legend
local function Legend(x, text)
    local sw = g:CreateTexture(nil, "ARTWORK")
    sw:SetSize(12, 3)
    sw:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", x, -22)
    local fs = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", sw, "RIGHT", 4, 0)
    fs:SetText(text)
    return sw
end
local swLow = Legend(-50, "Lowest listing")
local swAvg = Legend(60, "Average")
local swMax = Legend(150, "Your max")

-- Colors for each look. The trading look colors the price line green when
-- the price is up over the period and red when it's down, like a stock chart.
local function Colors(upTrend)
    if ns.theme == "trader" then
        return {
            low = upTrend and { 0.0, 0.78, 0.33 } or { 0.93, 0.27, 0.27 },
            avg = { 0.55, 0.6, 0.68 },
            max = { 1, 0.7, 0.2 },
            plotBg = { 0.04, 0.045, 0.05, 1 },
            grid = { 1, 1, 1, 0.06 },
        }
    end
    return {
        low = { 1, 0.82, 0 },
        avg = { 0.35, 0.7, 1 },
        max = { 1, 0.3, 0.3 },
        plotBg = { 0, 0, 0, 0.45 },
        grid = { 1, 1, 1, 0.08 },
    }
end

-- Price change over the shown period, next to the item name
local changeText = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
changeText:SetPoint("LEFT", itemTitle, "RIGHT", 4, 0)

-- Stats under the graph
local stats = {}
for i = 1, 5 do
    local fs = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", g, "TOPLEFT", 16, -270 - (i - 1) * 15)
    fs:SetWidth(310)
    fs:SetJustifyH("LEFT")
    stats[i] = fs
end

-- Full scan button + saved size
local scanBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
scanBtn:SetSize(100, 22)
scanBtn:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 12, 10)
scanBtn:SetText("Full scan")
scanBtn.pbPrimary = true
scanBtn:SetScript("OnClick", StartFullScan)
scanBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Full scan")
    GameTooltip:AddLine("Saves prices for everything on the auction house.", 1, 1, 1)
    GameTooltip:AddLine("The server allows one every 15 minutes.", 1, 1, 1)
    GameTooltip:AddLine("Auctionator's full scan is saved here too.", 1, 1, 1)
    GameTooltip:Show()
end)
scanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
local footer = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
footer:SetPoint("LEFT", scanBtn, "RIGHT", 8, 0)
footer:SetWidth(214)
footer:SetJustifyH("LEFT")

------------------------------------------------------------
-- Flip opportunities: items currently listed a good bit under their own
-- saved average, across everything ever scanned (not just your watch list)
------------------------------------------------------------

local AH_CUT = 0.05          -- the auction house keeps 5% of a sale
local MIN_FLIP_PCT = 12      -- only worth showing if buying low, reselling
                              -- near average nets at least this much
local MAX_FLIP_RATIO = 4     -- hard sanity cap: if "typical" comes out more
                              -- than 4x the current price, that's not a real
                              -- flip, it's bad data (an item that trades
                              -- mostly via bids with no buyout, so only one
                              -- or two stray buyout listings ever feed the
                              -- average, can still slip past every other
                              -- filter here and produce a "+6000%" fantasy
                              -- number). No legitimate everyday flip needs
                              -- a number this big to be worth taking.
local MAX_FLIP_AGE = 3 * 86400   -- ignore prices older than 3 days
local MIN_FLIP_DAYS = 4      -- need at least this many days of history before
                              -- trusting a "typical" price at all - with only
                              -- 1-2 days, one troll listing IS half your data
                              -- and no averaging can smooth that out

-- (Median and ns.GetTypicalPrice are defined once, up near ns.GetPriceRecord,
-- and reused here.)

-- Best current buy-low opportunities: cheapest listing well under the
-- typical price it's sold for, so buying now and reselling near that
-- typical price should turn a profit even after the auction house's cut.
-- Requires a real market behind it - enough currently listed, enough listed
-- on average historically, and enough DAYS of history - so one stray
-- mispriced auction (or one thin day) can't make the list on its own.
-- "Typical" comes from ns.GetTypicalPrice - the median of each day's
-- quantity-weighted AVERAGE listed price, not its cheapest listing, so
-- routine undercutting (buying up someone's lowballed stack, which is
-- exactly what this list is for) doesn't drag "typical" down to the
-- undercut price itself.
local function TopFlips(n)
    local minListedNow = (AHWatchDB and AHWatchDB.minListed) or 8
    local minListedAvg = math.max(3, math.floor(minListedNow / 2))
    local out = {}
    for itemID, it in pairs(runtimeItems) do
        if it.l and it.d and #it.d >= MIN_FLIP_DAYS and it.l[2] and it.l[2] > 0
            and (time() - it.l[1]) < MAX_FLIP_AGE
            and (it.l[4] or 0) >= minListedNow then
            local qtySum = 0
            for _, d in ipairs(it.d) do qtySum = qtySum + (d[5] or 0) end
            local avgListed = qtySum / #it.d
            if avgListed >= minListedAvg then
                local typical = ns.GetTypicalPrice(itemID)
                local current = it.l[2]
                if typical and typical > current and typical <= current * MAX_FLIP_RATIO then
                    local netSell = typical * (1 - AH_CUT)
                    local pct = (netSell - current) / current * 100
                    if pct >= MIN_FLIP_PCT then
                        table.insert(out, { itemID = itemID, current = current, typical = typical,
                            netSell = netSell, pct = pct, qty = it.l[4] or 0, avgListed = avgListed })
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.pct > b.pct end)
    while #out > n do table.remove(out) end
    return out
end

local FLIP_ROWS = 5

-- Its own bordered box, separate from the graph and stats above it
local flipBox = CreateFrame("Frame", nil, g, (BackdropTemplateMixin and "BackdropTemplate") or nil)
flipBox:SetPoint("TOPLEFT", g, "TOPLEFT", 8, -343)
flipBox:SetSize(324, 128)
local flipBoxBg = flipBox:CreateTexture(nil, "BACKGROUND")
flipBoxBg:SetAllPoints()
flipBoxBg:SetColorTexture(0, 0, 0, 0.28)
local flipBoxBorder = {}
do
    local function Line(p1, p2, horizontal)
        local t = flipBox:CreateTexture(nil, "BORDER")
        t:SetPoint(p1, flipBox, p1)
        t:SetPoint(p2, flipBox, p2)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
        t:SetColorTexture(0.6, 0.58, 0.5, 0.5)
        table.insert(flipBoxBorder, t)
    end
    Line("TOPLEFT", "TOPRIGHT", true)
    Line("BOTTOMLEFT", "BOTTOMRIGHT", true)
    Line("TOPLEFT", "BOTTOMLEFT", false)
    Line("TOPRIGHT", "BOTTOMRIGHT", false)
end

local flipHeader = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
flipHeader:SetPoint("TOPLEFT", flipBox, "TOPLEFT", 8, -8)
flipHeader:SetText("Flip opportunities (buy low, resell near average):")

local flipRows = {}
for i = 1, FLIP_ROWS do
    local b = CreateFrame("Button", nil, g)
    b:SetSize(306, 16)
    b:SetPoint("TOPLEFT", flipHeader, "BOTTOMLEFT", 0, -4 - (i - 1) * 16)
    b.arrow = b:CreateTexture(nil, "ARTWORK")
    b.arrow:SetSize(10, 10)
    b.arrow:SetPoint("LEFT", 0, 0)
    b.arrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
    b.arrow:SetVertexColor(0.2, 0.9, 0.3)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", b.arrow, "RIGHT", 4, 0)
    b.text:SetPoint("RIGHT", b, "RIGHT", -36, 0)
    b.text:SetJustifyH("LEFT")
    b.text:SetWordWrap(false)   -- clip rather than wrap onto a second line, which overlapped the row below it
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    -- One-click shortcut: sets this item up on the watch list at its shown
    -- price and switches to Buy, so pressing the key is all that's left.
    b.buyBtn = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
    b.buyBtn:SetSize(34, 14)
    b.buyBtn:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.buyBtn:SetText("Buy")
    b.buyBtn:SetNormalFontObject(GameFontHighlightSmall)
    b.buyBtn:SetHighlightFontObject(GameFontHighlightSmall)
    b.buyBtn.parentRow = b
    b.buyBtn:SetScript("OnClick", function(self)
        local row = self.parentRow
        if not row or not row.itemID then return end
        local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(row.itemID)) or ("Item " .. row.itemID)
        if ns.QuickBuySetup then ns.QuickBuySetup(row.itemID, name, row.current) end
    end)
    b.buyBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Sets this item up on the watch list at its shown price and switches to Buy - "
            .. "press your key to search and buy it.", nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    b.buyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        if self.itemID then ns.ShowGraph(self.itemID, nil) end
    end)
    b:SetScript("OnEnter", function(self)
        if not self.itemID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.itemID)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Buy at:", Money(self.current), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Resell near:", Money(self.typical) .. " (typical)", 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("You'd net:", Money(self.netSell) .. " after the 5% cut", 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Currently listed:", tostring(self.qty), 1, 1, 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    flipRows[i] = b
end

local flipEmpty = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
flipEmpty:SetPoint("TOPLEFT", flipHeader, "BOTTOMLEFT", 0, -4)
flipEmpty:SetText("None found yet - run a full scan, or check back after another.")

function ns.RefreshFlips()
    local flips = TopFlips(FLIP_ROWS)
    for i = 1, FLIP_ROWS do
        local row, f = flipRows[i], flips[i]
        if f then
            row.itemID, row.current, row.typical, row.netSell, row.qty = f.itemID, f.current, f.typical, f.netSell, f.qty
            local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(f.itemID)) or ("Item " .. f.itemID)
            row.text:SetText(string.format("%s  %s -> %s  |cff33dd66+%.0f%%|r", name, Money(f.current), Money(f.typical), f.pct))
            row:Show()
        else
            row:Hide()
        end
    end
    flipEmpty:SetShown(#flips == 0)
end

local function ScanEstimate()
    local times = AHWatchPrices and AHWatchPrices.scanTimes
    if not times or #times == 0 then return nil end
    local wait, save = 0, 0
    for _, t in ipairs(times) do
        wait, save = wait + t.wait, save + t.save
    end
    return wait / #times, save / #times
end

local function Secs(s)
    s = math.max(1, math.floor(s + 0.5))
    if s < 90 then return s .. "s" end
    return string.format("%dm %02ds", math.floor(s / 60), s % 60)
end

local function ScanStatus()
    local wait, save = ScanEstimate()
    if phase == "waiting" then
        local elapsed = time() - phaseStart
        if wait then
            local left = wait + save - elapsed
            return "|cffffd100Scanning: waiting for server... " ..
                (left > 0 and ("about " .. Secs(left) .. " left") or "almost done") .. "|r"
        end
        return "|cffffd100Scanning: waiting for server (" .. Secs(elapsed) .. ")...|r"
    elseif phase == "saving" then
        local left = save and (save * (100 - progress) / 100)
        return "|cffffd100Scanning: saving " .. progress .. "%" ..
            ((left and left >= 1) and (" (about " .. Secs(left) .. " left)") or "") .. "...|r"
    end
    local cd = CooldownLeft()
    local takes = wait and (" - takes about " .. Secs(wait + save)) or " - time unknown until first scan"
    local nextText = cd > 0 and ("next scan in " .. math.ceil(cd / 60) .. " min") or "|cff33ff33scan ready|r"
    return "|cffaaaaaa" .. nextText .. takes .. "|r"
end

function ns.RefreshFooter()
    local info = AHWatchPrices and AHWatchPrices.lastScanInfo
    local last = info and (" - last: " .. info.items .. " items, " .. Ago(info.t)) or ""
    footer:SetText(string.format("%.1f of %g MB saved%s\n%s", EstimateBytes() / 1048576, LimitMB(), last, ScanStatus()))
end

-- Drawing pieces, reused between redraws
local canLine = plot.CreateLine ~= nil
local pools = { lines = {}, dots = {}, hovers = {} }
local used = { lines = 0, dots = 0, hovers = 0 }

local function GetLine()
    used.lines = used.lines + 1
    local l = pools.lines[used.lines]
    if not l then
        l = plot:CreateLine(nil, "ARTWORK")
        pools.lines[used.lines] = l
    end
    l:Show()
    return l
end

local function GetDot()
    used.dots = used.dots + 1
    local d = pools.dots[used.dots]
    if not d then
        d = plot:CreateTexture(nil, "OVERLAY")
        d:SetSize(5, 5)
        pools.dots[used.dots] = d
    end
    d:Show()
    return d
end

local function GetHover()
    used.hovers = used.hovers + 1
    local h = pools.hovers[used.hovers]
    if not h then
        h = CreateFrame("Frame", nil, plot)
        h:SetSize(14, 14)
        h:EnableMouse(true)
        h:SetScript("OnEnter", function(self)
            local e = self.entry
            if not e then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(DayText(e[1]))
            GameTooltip:AddDoubleLine("Lowest listing:", Money(e[2]), 1, 1, 1, 1, 1, 1)
            if e[3] ~= e[2] then GameTooltip:AddDoubleLine("Highest lowest that day:", Money(e[3]), 1, 1, 1, 1, 1, 1) end
            GameTooltip:AddDoubleLine("Average:", Money(e[4]), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Listed:", tostring(e[5]), 1, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end)
        h:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pools.hovers[used.hovers] = h
    end
    h:Show()
    return h
end

local function ClearDrawing()
    for _, kind in ipairs({ "lines", "dots", "hovers" }) do
        for i = 1, #pools[kind] do pools[kind][i]:Hide() end
        used[kind] = 0
    end
end

local function DrawLine(x1, y1, x2, y2, color, thickness)
    if not canLine then return end
    local l = GetLine()
    l:SetColorTexture(color[1], color[2], color[3], 1)
    l:SetThickness(thickness or 2)
    l:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
    l:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
end

local graphItem, graphMax = nil, nil

function ns.ShowGraph(itemID, maxCopper)
    graphItem, graphMax = itemID, maxCopper
    ns.RefreshGraph()
end

function ns.RefreshGraph()
    ns.RefreshFooter()
    for _, b in ipairs(rangeBtns) do
        if b.days == rangeDays then b:LockHighlight() else b:UnlockHighlight() end
    end
    ClearDrawing()
    for i = 1, 5 do stats[i]:SetText("") end
    changeText:SetText("")
    local base = Colors(true)
    plotBg:SetColorTexture(unpack(base.plotBg))
    for i = 0, 3 do gridLines[i]:SetColorTexture(unpack(base.grid)) end
    if not graphItem then
        itemTitle:SetText("Pick an item")
        emptyText:Show()
        return
    end

    local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(graphItem)) or ("Item " .. graphItem)
    itemTitle:SetText(name)
    local it = runtimeItems[graphItem]
    local today = Today()
    local startDay = today - rangeDays + 1
    xStart:SetText(DayText(startDay))
    xEnd:SetText(DayText(today))

    local pts = {}
    for _, e in ipairs((it and it.d) or {}) do
        if e[1] >= startDay then table.insert(pts, e) end
    end
    -- Up or down over the period shown
    local up = true
    if #pts >= 2 and pts[1][2] > 0 then
        local pct = (pts[#pts][2] - pts[1][2]) / pts[1][2] * 100
        up = pct >= 0
        changeText:SetText(string.format("%s%s%.1f%%|r (%dd)", up and "|cff33dd66" or "|cffff5555", up and "+" or "", pct, rangeDays))
    end
    local col = Colors(up)
    local COLOR_LOW, COLOR_AVG, COLOR_MAX = col.low, col.avg, col.max
    swLow:SetColorTexture(COLOR_LOW[1], COLOR_LOW[2], COLOR_LOW[3], 1)
    swAvg:SetColorTexture(COLOR_AVG[1], COLOR_AVG[2], COLOR_AVG[3], 1)
    swMax:SetColorTexture(COLOR_MAX[1], COLOR_MAX[2], COLOR_MAX[3], 1)

    if #pts == 0 then
        emptyText:Show()
        for i = 0, 3 do yLabels[i]:SetText("") end
    else
        emptyText:Hide()
        local lo, hi = math.huge, 0
        for _, e in ipairs(pts) do
            lo = math.min(lo, e[2], e[4])
            hi = math.max(hi, e[2], e[4])
        end
        if graphMax then lo, hi = math.min(lo, graphMax), math.max(hi, graphMax) end
        if hi - lo < 1 then lo, hi = lo * 0.9, hi * 1.1 + 1 end
        local pad = (hi - lo) * 0.1
        lo, hi = math.max(0, lo - pad), hi + pad
        local function X(day) return (day - startDay) / math.max(rangeDays - 1, 1) * PLOT_W end
        local function Y(v) return (v - lo) / (hi - lo) * PLOT_H end
        for i = 0, 3 do yLabels[i]:SetText(Money(lo + (hi - lo) * i / 3)) end

        -- Your max price as a dashed line
        if graphMax then
            local y = Y(graphMax)
            for x = 0, PLOT_W - 8, 14 do DrawLine(x, y, x + 8, y, COLOR_MAX, 1.5) end
        end
        for i, e in ipairs(pts) do
            local x = X(e[1])
            if i > 1 then
                local p = pts[i - 1]
                DrawLine(X(p[1]), Y(p[4]), x, Y(e[4]), COLOR_AVG, 1.5)
                DrawLine(X(p[1]), Y(p[2]), x, Y(e[2]), COLOR_LOW, 2)
            end
            local d = GetDot()
            d:SetColorTexture(COLOR_LOW[1], COLOR_LOW[2], COLOR_LOW[3], 1)
            d:ClearAllPoints()
            d:SetPoint("CENTER", plot, "BOTTOMLEFT", x, Y(e[2]))
            local h = GetHover()
            h:ClearAllPoints()
            h:SetPoint("CENTER", plot, "BOTTOMLEFT", x, Y(e[2]))
            h.entry = e
        end
    end

    if it and it.l then
        stats[1]:SetText("Latest: " .. Money(it.l[2]) .. "  (typical " .. Money(it.l[3]) .. ", " .. it.l[4] .. " listed, " .. Ago(it.l[1]) .. ")")
    end
    if it and it.lo then stats[2]:SetText("Lowest saved: " .. Money(it.lo[1]) .. "  (" .. date("%b %d", it.lo[2]) .. ")") end
    if it and it.hi then stats[3]:SetText("Highest saved: " .. Money(it.hi[1]) .. "  (" .. date("%b %d", it.hi[2]) .. ")") end
    if it then stats[4]:SetText("Days of history: " .. #it.d) end
    if it then
        local typical, days = ns.GetTypicalPrice(graphItem)
        if typical then
            stats[5]:SetText("Average (" .. days .. " trusted day" .. (days == 1 and "" or "s") .. "): " .. Money(typical))
        else
            stats[5]:SetText("Average: not enough reliable history yet")
        end
    end
end

g:SetScript("OnShow", function() ns.RefreshGraph(); ns.RefreshFlips() end)

------------------------------------------------------------
-- Tooltips
------------------------------------------------------------

local function AddPriceLines(tt, itemID)
    if not itemID then return end
    local it = runtimeItems[itemID]
    if not it or not it.l then return end
    tt:AddLine("AH Watch", 0.2, 0.8, 1)
    tt:AddDoubleLine("  Latest:", Money(it.l[2]) .. "  |cffaaaaaa(" .. it.l[4] .. " listed, " .. Ago(it.l[1]) .. ")|r",
        1, 1, 1, 1, 1, 1)
    local typical, days = ns.GetTypicalPrice(itemID)
    if typical then
        tt:AddDoubleLine("  Average:", Money(typical) .. "  |cffaaaaaa(" .. days .. " trusted day" .. (days == 1 and "" or "s") .. ")|r", 1, 1, 1, 1, 1, 1)
    end
    if it.lo then tt:AddDoubleLine("  Lowest saved:", Money(it.lo[1]) .. "  |cffaaaaaa" .. date("%b %d", it.lo[2]) .. "|r", 1, 1, 1, 1, 1, 1) end
    if it.hi then tt:AddDoubleLine("  Highest saved:", Money(it.hi[1]) .. "  |cffaaaaaa" .. date("%b %d", it.hi[2]) .. "|r", 1, 1, 1, 1, 1, 1) end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
        if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
        AddPriceLines(tt, data and data.id)
    end)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
        local _, link = tt:GetItem()
        AddPriceLines(tt, link and tonumber(link:match("item:(%d+)")))
    end)
end

------------------------------------------------------------
-- Settings and events
------------------------------------------------------------

-- What's in memory right now (this is what gets written on /reload or logout)
function ns.PrintData()
    local count, days = 0, 0
    for _, it in pairs(runtimeItems) do
        count = count + 1
        days = days + #it.d
    end
    Msg(string.format("price history in memory: %d items, %d item-days, about %.2f MB. It's written to disk on /reload or logout.",
        count, days, EstimateBytes() / 1048576))
end

function ns.SetLimit(mb)
    mb = tonumber(mb)
    if not mb or mb <= 0 then
        Msg("usage: /ahw limit <MB>  (currently " .. LimitMB() .. " MB, accepts fractions like 0.05)")
        return
    end
    AHWatchDB.limitMB = mb
    local removed = Prune()
    Msg(string.format("price data limit set to %g MB (%.1f MB saved%s).", mb, EstimateBytes() / 1048576,
        removed > 0 and (", dropped " .. removed .. " old items") or ""))
    ns.RefreshFooter()
end

local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "ADDON_LOADED")
pcall(ev.RegisterEvent, ev, "REPLICATE_ITEM_LIST_UPDATE")
pcall(ev.RegisterEvent, ev, "PLAYER_LOGOUT")   -- fires on /reload, logout and exit - last chance to sync
ev:SetScript("OnEvent", function(_, e, a1)
    if e == "ADDON_LOADED" and a1 == "AHWatch" then
        EnsurePrices()
        -- Load the price history, or migrate it from an older format if
        -- that's what's on disk from before this fix (one long string, or
        -- the original oversized table).
        local joined
        if type(AHWatchItemsData) == "table" then
            joined = table.concat(AHWatchItemsData)
        elseif type(AHWatchItemsData) == "string" then
            joined = AHWatchItemsData
        end
        local ok, decoded = pcall(DecodeItems, joined)
        if ok and decoded and next(decoded) then
            runtimeItems = decoded
        elseif type(AHWatchPrices) == "table" and type(AHWatchPrices.items) == "table" then
            runtimeItems = AHWatchPrices.items
            AHWatchPrices.items = nil
            MarkDirty()
        else
            runtimeItems = {}
        end
        local count = 0
        for _ in pairs(runtimeItems) do count = count + 1 end
        local watched = (type(AHWatchDB) == "table" and type(AHWatchDB.watch) == "table") and #AHWatchDB.watch or 0
        if count > 0 or watched > 0 then
            Msg(string.format("loaded saved prices for %d items and %d watched items.", count, watched))
        elseif joined and #joined > 0 then
            Msg("the saved price data didn't parse - starting fresh. If this keeps happening, tell Claude.")
        else
            Msg("no saved price history yet.")
        end
    elseif e == "PLAYER_LOGOUT" then
        if itemsDirty then SyncItemsString() end
    elseif e == "REPLICATE_ITEM_LIST_UPDATE" then
        -- The game can send this several times for the same scan; wait briefly
        -- for it to settle, then save it once.
        if ns.replicatePending or scanning then return end
        ns.replicatePending = true
        C_Timer.After(0.3, function()
            ns.replicatePending = false
            local db = EnsurePrices()
            local n = C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems() or 0
            local info = db.lastScanInfo
            -- Same data we already saved, and no new scan was asked for: skip it
            if phase ~= "waiting" and info and info.raw == n and time() - info.t < FULL_SCAN_COOLDOWN then return end
            if phase ~= "waiting" and (not db.lastFullScan or time() - db.lastFullScan > 60) then
                db.lastFullScan = time()   -- someone else (e.g. Auctionator) started it
            end
            ProcessReplicate()
        end)
    end
end)

-- Keep the "next scan in" countdown current while the window is open
C_Timer.NewTicker(1, function()
    if g:IsVisible() then ns.RefreshFooter() end
    if phase == "waiting" and not scanning and not ns.replicatePending then
        -- Data can arrive without the usual event; check for it directly
        local n = (C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems()) or 0
        if n > 0 and n ~= replicateBefore and time() - phaseStart >= 3 then
            ProcessReplicate()
            return
        end
        -- If the server never answers, stop saying "waiting" and explain
        if time() - phaseStart > 120 then
            phase = "idle"
            -- Don't make you wait 15 minutes for a scan that never happened
            EnsurePrices().lastFullScan = time() - FULL_SCAN_COOLDOWN + 5 * 60
            Msg("no scan data came back from the server after 2 minutes. It may be limiting full scans "
                .. "(some servers allow fewer than one every 15 min). You can try again in 5 minutes.")
            ns.RefreshFooter()
        end
    end
end)
