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

local function EncodeOne(itemID, it)
    local days = {}
    for _, d in ipairs(it.d or {}) do
        days[#days + 1] = table.concat(d, ",")
    end
    return itemID .. " " ..
        table.concat(it.l or { 0, 0, 0, 0 }, ",") .. " " ..
        table.concat(it.lo or { 0, 0 }, ",") .. " " ..
        table.concat(it.hi or { 0, 0 }, ",") .. " " ..
        table.concat(days, ";")
end

local function EncodeItems(items)
    local parts = {}
    for itemID, it in pairs(items) do
        parts[#parts + 1] = EncodeOne(itemID, it)
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

-- Writes the working copy back into the saved chunks. This re-encodes the
-- whole history, so it only runs when it has to: on logout/reload (the only
-- time the game writes saved data to disk anyway) and after trimming.
-- It used to run after every single search, which made each press hitch
-- once the history got big.
local sizeAt = 0
local function SyncItemsString()
    local str = EncodeItems(runtimeItems)
    AHWatchItemsData = SplitChunks(str)
    itemsDirty = false
    sizeCache, sizeAt = 300 + #str, GetTime()
end

local function MarkDirty()
    itemsDirty = true
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
local DAY_OUTLIER = 3   -- a day more than 3x off the latest day's price is ignored
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
-- Worked out once per item and reused until that item gets a new price
-- (it used to be re-sorted every time anything was redrawn).
local typicalCache = {}
local typicalCacheDay = nil   -- weights depend on today's date, so the cache resets daily
function ns.ClearTypicalCache() typicalCache = {} end

-- How fast old days stop counting. Each day's weight halves every this many
-- days: with 1.5, yesterday counts ~63%, 3 days ago 25%, a week ago ~4%.
-- Lower = follows price drops faster; higher = steadier. /ahw halflife <days>
local DEFAULT_HALF_LIFE = 1.5
local function HalfLife()
    local h = AHWatchDB and tonumber(AHWatchDB.halfLife)
    return (h and h > 0) and h or DEFAULT_HALF_LIFE
end

function ns.GetTypicalPrice(itemID)
    local today = math.floor(time() / 86400)
    if typicalCacheDay ~= today then typicalCache, typicalCacheDay = {}, today end
    local c = typicalCache[itemID]
    if c then return c[1] or nil, c[2] end
    local it = runtimeItems[itemID]
    local price, days
    if it and it.d then
        -- The most recent trusted day is the reference: older days more than
        -- 3x above or below it are bad data (often saved by an older version
        -- whose full scan used a plain average that a few overpriced
        -- listings could blow up) and are left out. With only 2 days, one
        -- bad day used to drag the average halfway to it.
        local ref
        for i = #it.d, 1, -1 do
            local d = it.d[i]
            if d[4] and d[4] > 0 and TrustedQty(d) then ref = d[4] break end
        end
        -- Recency-weighted median: every day still votes, but recent days
        -- count far more. A plain median of 30 days kept the market value
        -- high for a week or more after competition pushed prices down.
        local hl = HalfLife()
        local pts, totalW = {}, 0
        for _, d in ipairs(it.d) do
            if d[4] and d[4] > 0 and TrustedQty(d)
                and d[4] <= ref * DAY_OUTLIER and d[4] >= ref / DAY_OUTLIER then
                local age = math.max(0, today - (d[1] or today))
                local w = 0.5 ^ (age / hl)
                pts[#pts + 1] = { d[4], w }
                totalW = totalW + w
            end
        end
        if #pts > 0 then
            table.sort(pts, function(a, b) return a[1] < b[1] end)
            local half, cum = totalW / 2, 0
            for _, p in ipairs(pts) do
                cum = cum + p[2]
                price = p[1]
                if cum >= half then break end
            end
            price, days = math.floor(price), #pts
        end
    end
    typicalCache[itemID] = { price or false, days }
    return price, days
end

-- THE market price, used everywhere in the addon (max-price %, the "% below
-- market" notes, the Sell tab, the ledger): your own saved history once it
-- has 2+ reliable days, otherwise Auctionator's price if it's installed,
-- otherwise whatever single day of history there is.
local MIN_MARKET_DAYS = 2
function ns.MarketPrice(itemID)
    if not itemID then return nil end
    local typical, days = ns.GetTypicalPrice(itemID)
    if typical and days >= MIN_MARKET_DAYS then return math.floor(typical), "history", days end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local ok, p = pcall(api.GetAuctionPriceByItemID, "AHWatch", itemID)
        if ok and p and p > 0 then return p, "auctionator", 0 end
    end
    if typical then return math.floor(typical), "history", days end
    return nil
end

-- Compact money text for notes: "2s", "1s 60c", "12g 5s"
function ns.ShortMoney(copper)
    copper = math.floor((copper or 0) + 0.5)
    local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if sv > 0 then parts[#parts + 1] = sv .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

-- How a price compares with the market: "50% below market (2s)"
function ns.VsMarket(itemID, price)
    if not itemID or not price or price <= 0 then return "" end
    local m = ns.MarketPrice(itemID)
    if not m or m <= 0 then return "|cff888888no market price yet|r" end
    local pct = (price - m) / m * 100
    local ms = " |cffaaaaaa(" .. ns.ShortMoney(m) .. ")|r"
    if math.abs(pct) < 0.5 then return "|cffffffffat market|r" .. ms end
    if pct < 0 then
        return string.format("|cff33dd66%d%% below market|r", math.floor(-pct + 0.5)) .. ms
    end
    return string.format("|cffff6666%d%% above market|r", math.floor(pct + 0.5)) .. ms
end

-- How a price compares with the current lowest listing: "5% under lowest (1s 90c)".
-- If the cheapest few are flagged as bait, it compares with where the real
-- listings start instead, and says "lowest real".
function ns.VsLowest(itemID, price)
    if not itemID or not price or price <= 0 then return "" end
    local it = runtimeItems[itemID]
    local bait = ns.GetBait and ns.GetBait(itemID)
    local low = (bait and bait.floor) or (it and it.l and it.l[2])
    if not low or low <= 0 then return "|cff888888lowest listing: not checked yet|r" end
    local age = (it and it.l and it.l[1]) and (time() - it.l[1]) or 0
    local tag = bait and "lowest real" or "lowest"
    local ms = " |cffaaaaaa(" .. ns.ShortMoney(low)
        .. (age >= 3600 and (", " .. math.floor(age / 3600) .. "h ago") or "") .. ")|r"
    local pct = (price - low) / low * 100
    if math.abs(pct) < 0.5 then return "|cffffffffsame as " .. tag .. "|r" .. ms end
    if pct < 0 then
        return string.format("|cff33dd66%d%% under %s|r", math.floor(-pct + 0.5), tag) .. ms
    end
    return string.format("|cffffaa33%d%% over %s|r", math.floor(pct + 0.5), tag) .. ms
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
    typicalCache[itemID] = nil
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
------------------------------------------------------------
-- Bait detection: a handful of items listed well under where the real
-- supply starts, posted so undercutters chase the price down. They're
-- flagged so the Sell tab doesn't undercut them and the flip list doesn't
-- treat them as a real market.
------------------------------------------------------------

local BAIT_MAX_QTY = 10      -- bait is a small amount (1-10 items)...
local BAIT_GAP = 0.15        -- ...at least 15% under where real supply starts
local BAIT_MIN_LISTED = 30   -- below this much listed, there's no "real supply" to compare with
local BAIT_KEEP = 900        -- seconds a bait flag stays valid
local baitInfo = {}

-- Flips use CURRENT listings only, found by quantity and gap - not market value.
-- A flip = a small cheap group (1-10 items, cheapest first) followed by a
-- jump to the next listing. Buy the group, resell 1c under that next listing.
local FLIP_CUT = 0.05        -- the auction house keeps 5% of a sale
local FLIP_MIN_PCT = 12      -- buy the group + resell under the next listing must net this much
local GAP_MAX_QTY = 10       -- the cheap group is at most this many items
local GAP_MIN_JUMP = 0.15    -- next listing must be at least 15% above the group's top price
local GAP_MIN_LISTED = 20    -- need a real market behind the gap
local gapInfo = {}           -- itemID -> best gap flip in the latest data
local vendorInfo = {}        -- itemID -> listings under the vendor's price in the latest data

-- Vendor flips: listings cheaper than what a vendor pays for the item. Buy,
-- sell to any vendor - no AH cut, no waiting. Needs at least 5% (and 1c) profit.
local VENDOR_MIN_PCT = 5
local function VendorPrice(itemID)
    local v
    if C_Item and C_Item.GetItemInfo then v = select(11, C_Item.GetItemInfo(itemID)) end
    if not v and GetItemInfo then v = select(11, GetItemInfo(itemID)) end
    return v or 0
end
ns.VendorPrice = VendorPrice
local function VendorFromUnits(itemID, units)
    local vendor = VendorPrice(itemID)
    if vendor <= 0 or not units[1] or units[1][1] > vendor then return nil end
    local limit = math.min(vendor - 1, math.floor(vendor * (1 - VENDOR_MIN_PCT / 100)))
    local qty, cost, top = 0, 0, 0
    for _, u in ipairs(units) do
        if u[1] > limit then break end
        qty, cost, top = qty + u[2], cost + u[1] * u[2], u[1]
    end
    if qty == 0 then return nil end
    return { qty = qty, cost = math.floor(cost), top = math.floor(top), vendor = vendor,
             profit = math.floor(vendor * qty - cost), t = time() }
end

-- units sorted cheapest first: { {unitPrice, qty}, ... }; total = their qty
local function GapFromUnits(units, total)
    if #units < 2 or total < GAP_MIN_LISTED then return nil end
    local best, qty, cost = nil, 0, 0
    for k = 1, #units - 1 do
        qty = qty + units[k][2]
        cost = cost + units[k][1] * units[k][2]
        if qty > GAP_MAX_QTY then break end
        local top, nextP = units[k][1], units[k + 1][1]
        if nextP >= top * (1 + GAP_MIN_JUMP) then
            local sellEach = math.max(1, nextP - 1) * (1 - FLIP_CUT)
            local profit = sellEach * qty - cost
            local pct = profit / cost * 100
            if pct >= FLIP_MIN_PCT and (not best or profit > best.profit) then
                best = { qty = qty, cost = math.floor(cost), low = units[1][1], top = top,
                         next = nextP, profit = math.floor(profit), pct = pct, t = time() }
            end
        end
    end
    return best
end

-- units = { {unitPrice, qty}, ... } sorted cheapest first; total = their qty
-- Where real supply starts ("the wall"): the price at which a meaningful
-- amount has been passed - at least WallQty() items, or WallPct()% of
-- everything listed, whichever is more. Below that are the small cheap
-- groups (bait, snipes). Both numbers are settings: /ahw wall <qty> [pct]
local function WallQty() return (AHWatchDB and AHWatchDB.wallQty) or 20 end
local function WallPct() return (AHWatchDB and AHWatchDB.wallPct) or 5 end
ns.WallQty, ns.WallPct = WallQty, WallPct

-- units sorted cheapest first: { {unitPrice, qty}, ... }. Returns the wall
-- price, or nil when there isn't enough listed to trust one.
function ns.WallFromUnits(units, total)
    if not total or total < WallQty() then return nil end
    local depth = math.max(WallQty(), math.ceil(total * WallPct() / 100))
    local cum = 0
    for _, u in ipairs(units) do
        cum = cum + u[2]
        if cum >= depth then return u[1] end
    end
    return nil
end

local function BaitFromUnits(units, total)
    if total < BAIT_MIN_LISTED or #units < 2 then return nil end
    local wall = ns.WallFromUnits(units, total)
    if not wall or wall <= 0 then return nil end
    local cutoff = wall * (1 - BAIT_GAP)
    local qty, count, low = 0, 0, nil
    for _, u in ipairs(units) do
        if u[1] >= cutoff then break end
        qty, count = qty + u[2], count + 1
        low = low or u[1]
    end
    -- More than a handful that cheap isn't bait - it's a real price drop
    if count == 0 or qty > BAIT_MAX_QTY then return nil end
    return {
        qty = qty, count = count, low = math.floor(low), floor = math.floor(wall),
        pct = (wall - low) / wall * 100, t = GetTime(),
    }
end

-- Check search results directly (rows as the main window stores them)
function ns.FindBait(rows, isCommodity)
    local units, total = {}, 0
    for _, r in ipairs(rows or {}) do
        local q = r.quantity or 1
        local unit = isCommodity and r.unitPrice or (r.buyout and r.buyout / math.max(q, 1))
        if unit and unit > 0 and not r.own then
            units[#units + 1] = { unit, q }
            total = total + q
        end
    end
    table.sort(units, function(a, b) return a[1] < b[1] end)
    return BaitFromUnits(units, total)
end

-- The latest bait flag for an item, if it's recent enough to trust
function ns.GetBait(itemID)
    local b = itemID and baitInfo[itemID]
    if b and GetTime() - b.t < BAIT_KEEP then return b end
    return nil
end

function ns.RecordRows(itemID, rows, isCommodity)
    local low, qty = nil, 0
    local units = {}
    for _, r in ipairs(rows or {}) do
        local q = r.quantity or 1
        local unit = isCommodity and r.unitPrice or (r.buyout and r.buyout / math.max(q, 1))
        -- Your own listings don't count: posting a big stack shouldn't move
        -- the price you're basing your own decisions on
        if unit and unit > 0 and not r.own then
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
        baitInfo[itemID] = BaitFromUnits(units, qty)   -- units are sorted above
        gapInfo[itemID] = GapFromUnits(units, qty)
        vendorInfo[itemID] = VendorFromUnits(itemID, units)
        if ns.SchedulePriceRefresh then ns.SchedulePriceRefresh() end
    end
end

-- Size of the saved chunks, in bytes. Measuring means encoding everything,
-- so while prices are changing it's re-measured at most every 30 seconds
-- (the panel's footer asks every second); force gets an exact number.
local function EstimateBytes(force)
    if sizeCache and not force and (not itemsDirty or GetTime() - sizeAt < 30) then return sizeCache end
    sizeCache, sizeAt = 300 + #EncodeItems(runtimeItems), GetTime()
    return sizeCache
end

-- Keeps the file under the limit: drops the items seen longest ago first,
-- and never drops anything on your watch list.
-- (Measures once, then subtracts each dropped item's own size, instead of
-- re-measuring everything after every single item.)
local function Prune()
    local limit = LimitMB() * 1024 * 1024
    local size = EstimateBytes(true)
    if size <= limit then return 0 end
    local candidates = {}
    for id, it in pairs(runtimeItems) do
        if not IsWatched(id) then table.insert(candidates, { id = id, t = (it.l and it.l[1]) or 0 }) end
    end
    table.sort(candidates, function(a, b) return a.t < b.t end)
    local removed = 0
    for _, c in ipairs(candidates) do
        size = size - (#EncodeOne(c.id, runtimeItems[c.id]) + 1)
        runtimeItems[c.id] = nil
        typicalCache[c.id] = nil
        removed = removed + 1
        if size <= limit then break end
    end
    if removed > 0 then
        MarkDirty()
        SyncItemsString()
    end
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
    local toRecord, recIdx = nil, 0   -- second pass: saving each item, also spread over frames
    local PACK = 100000
    local me = UnitName and UnitName("player")
    local scanTime = time()
    local function Step()
        local started = clock and clock()
        if toRecord then
            local stopAt = clock and #toRecord or math.min(recIdx + FALLBACK_CHUNK, #toRecord)
            while recIdx < stopAt do
                recIdx = recIdx + 1
                local itemID = toRecord[recIdx]
                local a = agg[itemID]
                -- The price of the middle unit of everything listed (same as a search)
                table.sort(a.v)
                local half, cum, typical = a.qty / 2, 0, a.low
                for _, packed in ipairs(a.v) do
                    cum = cum + packed % PACK
                    typical = math.floor(packed / PACK)
                    if cum >= half then break end
                end
                Record(itemID, a.low, typical, a.qty, scanTime)
                -- Bait check and flip count from the same sorted listings
                local units = {}
                for i, packed in ipairs(a.v) do
                    units[i] = { math.floor(packed / PACK), packed % PACK }
                end
                vendorInfo[itemID] = (#units > 0) and VendorFromUnits(itemID, units) or nil
                if #a.v >= 2 then
                    baitInfo[itemID] = (a.qty >= BAIT_MIN_LISTED) and BaitFromUnits(units, a.qty) or nil
                    gapInfo[itemID] = GapFromUnits(units, a.qty)
                else
                    baitInfo[itemID], gapInfo[itemID] = nil, nil
                end
                agg[itemID] = nil
                if clock and (recIdx % 200 == 0) and clock() - started > FRAME_BUDGET_MS then break end
            end
            progress = 90 + math.floor(recIdx / math.max(#toRecord, 1) * 10)
            if recIdx < #toRecord then
                C_Timer.After(0, SafeStep)
                return
            end
            return "done"
        end
        local stop = clock and n or math.min(idx + FALLBACK_CHUNK, n)
        for i = idx, stop - 1 do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
            if itemID and buyout and buyout > 0 and count and count > 0 and (not me or owner ~= me) then
                local unit = buyout / count
                local a = agg[itemID]
                if not a then
                    a = { low = unit, qty = 0, v = {} }
                    agg[itemID] = a
                end
                if unit < a.low then a.low = unit end
                a.qty = a.qty + count
                -- Each listing packed into one number (price, then amount) -
                -- far lighter than a table per listing on a big auction house
                a.v[#a.v + 1] = math.floor(unit + 0.5) * PACK + math.min(count, PACK - 1)
                listings = listings + 1
            end
            idx = i + 1
            -- Stop for this frame once the time budget is used up
            if clock and (i % 200 == 0) and clock() - started > FRAME_BUDGET_MS then break end
        end
        progress = math.floor(idx / n * 90)
        if idx < n then
            C_Timer.After(0, SafeStep)
            return
        end
        toRecord = {}
        for itemID in pairs(agg) do toRecord[#toRecord + 1] = itemID end
        C_Timer.After(0, SafeStep)
    end
    local function Finish()
        local t, count = scanTime, #toRecord
        local db = EnsurePrices()
        db.lastScanInfo = { t = t, items = count, listings = listings, raw = n }
        if waited then
            db.scanTimes = db.scanTimes or {}
            table.insert(db.scanTimes, { wait = waited, save = GetTime() - saveStart })
            while #db.scanTimes > 3 do table.remove(db.scanTimes, 1) end
        end
        local removed = Prune()
        if removed == 0 then MarkDirty() end   -- written to disk on logout/reload
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
        if ok and err == "done" then ok, err = pcall(Finish) end
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
-- The panel can be tucked away: its X hides it, and a small "Prices" button
-- on the main window's title bar brings it back. Remembered between sessions.
local showPricesBtn = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
showPricesBtn:SetSize(64, 18)
showPricesBtn:SetPoint("TOPLEFT", main, "TOPLEFT", 6, -3)
showPricesBtn:SetText("Prices >")
showPricesBtn:SetNormalFontObject(GameFontNormalSmall)
showPricesBtn:SetHighlightFontObject(GameFontHighlightSmall)
showPricesBtn:SetFrameLevel(main:GetFrameLevel() + 60)
showPricesBtn:Hide()

local function SetGraphShown(show)
    if type(AHWatchDB) == "table" then AHWatchDB.graphHidden = (not show) or nil end
    g:SetShown(show)
    showPricesBtn:SetShown(not show)
end
ns.SetGraphShown = SetGraphShown
showPricesBtn:SetScript("OnClick", function() SetGraphShown(true) end)
showPricesBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Show the price history panel")
    GameTooltip:Show()
end)
showPricesBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local hideBtn = g.CloseButton
if not hideBtn then
    hideBtn = CreateFrame("Button", nil, g, "UIPanelCloseButton")
    hideBtn:SetPoint("TOPRIGHT", -2, -2)
end
hideBtn:SetScript("OnClick", function() SetGraphShown(false) end)
hideBtn:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Hide price history")
    GameTooltip:AddLine("Bring it back with the Prices button at the top left of AH Watch.", 1, 1, 1, true)
    GameTooltip:Show()
end)
hideBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
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
-- CURRENT data only. Before, an item needed 4+ days of saved history (so
-- nothing showed for days), had to have averaged enough listings in the past,
-- was compared against long-term history instead of what's listed now, and
-- anything under 25% of market was thrown out - hiding the very outliers
-- worth buying. Now: every item seen in the last few hours, its cheapest
-- listing vs the typical price of everything listed in that same snapshot.
local FLIP_FRESH = 6 * 3600      -- only snapshots from the last 6 hours (your latest scan/searches)
-- Flips only cover gathering materials, fishing catches and other trade
-- goods - all in WoW's Trade Goods item class (ore, stone, gems, bars,
-- herbs, leather, hides, raw fish, cloth, elemental, etc). Gear, consumables,
-- recipes and the rest are left out: gear varies piece to piece, so
-- "typical" for it isn't a real resale price. Add class IDs here to allow more.
local FLIP_ALLOW_CLASS = { [7] = true }   -- 7 = Trade Goods
local classCache = {}
local function SkipForFlips(itemID)
    local c = classCache[itemID]
    if c == nil then
        local ok, classID
        local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
        if getInfo then ok, classID = pcall(function() return select(6, getInfo(itemID)) end) end
        c = (ok and classID) or false
        classCache[itemID] = c
    end
    return not (c and FLIP_ALLOW_CLASS[c])
end

local function TopFlips(n)
    local now = time()
    local out = {}
    for itemID, g in pairs(gapInfo) do
        if (now - g.t) < FLIP_FRESH and not SkipForFlips(itemID) then
            local it = runtimeItems[itemID]
            local listed = it and it.l and it.l[4] or 0
            out[#out + 1] = { itemID = itemID, current = math.floor(g.top), typical = g.next,
                netSell = (g.next - 1) * (1 - FLIP_CUT), pct = g.pct, qty = listed,
                dealQty = g.qty, dealCost = g.cost, low = math.floor(g.low),
                profit = g.profit, seen = g.t }
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
    while #out > n do table.remove(out) end
    return out
end
ns.TopFlips = TopFlips   -- also used by the Flips tab on the main window

-- Vendor flips for the Flips tab: any kind of item (gear too), best gold first
function ns.TopVendorFlips(n)
    local now, out = time(), {}
    for itemID, v in pairs(vendorInfo) do
        if (now - v.t) < FLIP_FRESH then
            local it = runtimeItems[itemID]
            out[#out + 1] = { itemID = itemID, current = v.top, typical = v.vendor, netSell = v.vendor,
                pct = (v.vendor * v.qty - v.cost) / math.max(1, v.cost) * 100, qty = it and it.l and it.l[4] or 0,
                dealQty = v.qty, dealCost = v.cost, profit = v.profit, seen = v.t, vendorFlip = true }
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
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
flipHeader:SetText("Price-gap deals (Watch: follow it for 15% profit):")

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
    b.buyBtn:SetSize(38, 14)
    b.buyBtn:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.buyBtn:SetText("Watch")
    b.buyBtn:SetNormalFontObject(GameFontHighlightSmall)
    b.buyBtn:SetHighlightFontObject(GameFontHighlightSmall)
    b.buyBtn.parentRow = b
    b.buyBtn:SetScript("OnClick", function(self)
        local row = self.parentRow
        if not row or not row.itemID then return end
        local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(row.itemID)) or ("Item " .. row.itemID)
        -- Margin mode: the max follows where real supply starts, so it doesn't go stale
        if ns.WatchWithMargin then ns.WatchWithMargin(row.itemID, name, (AHWatchDB and AHWatchDB.dealMargin) or 15) end
    end)
    b.buyBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Puts this item on your watch list for 15% profit (margin mode - its max follows "
            .. "where real supply starts) and switches to Buy.", nil, nil, nil, nil, true)
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
        GameTooltip:AddDoubleLine("Resell near:", Money(self.typical) .. " (next listing)", 1, 1, 1, 1, 1, 1)
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
flipEmpty:SetText("No gaps found - run a Full scan to check everything listed right now.")

function ns.RefreshFlips()
    if ns.RefreshFlipsTab then ns.RefreshFlipsTab() end
    local flips = TopFlips(FLIP_ROWS)
    for i = 1, FLIP_ROWS do
        local row, f = flipRows[i], flips[i]
        if f then
            row.itemID, row.current, row.typical, row.netSell, row.qty = f.itemID, f.current, f.typical, f.netSell, f.qty
            local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(f.itemID)) or ("Item " .. f.itemID)
            local bait = ns.GetBait(f.itemID)
            row.text:SetText(string.format("%s  %s -> %s  |cff33dd66+%.0f%%|r", name, Money(f.current), Money(f.typical), f.pct)
                .. (bait and string.format("  |cffffcc00bait x%d|r", bait.qty) or ""))
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

-- New prices arrive with every search. Redrawing the graph and re-ranking
-- every saved item for Flip opportunities is the slow part, so it's done
-- once things settle (not after each result), and only while it's on screen.
local priceRefreshQueued = false
function ns.SchedulePriceRefresh()
    if priceRefreshQueued then return end
    priceRefreshQueued = true
    C_Timer.After(0.3, function()
        priceRefreshQueued = false
        if g:IsVisible() then
            ns.RefreshGraph()
            ns.RefreshFlips()
        elseif ns.RefreshFlipsTab then
            ns.RefreshFlipsTab()
        end
    end)
end

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
    local bait = ns.GetBait(itemID)
    if bait then
        tt:AddDoubleLine("  |cffffcc00Possible bait:|r", string.format("%d at %s  |cffaaaaaa(real supply from %s)|r",
            bait.qty, Money(bait.low), Money(bait.floor)), 1, 1, 1, 1, 1, 1)
    end
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
        SetGraphShown(not (type(AHWatchDB) == "table" and AHWatchDB.graphHidden))
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
