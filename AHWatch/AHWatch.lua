-- AHWatch
-- A watch list for the auction house. Add items with a max price, then press
-- one button (or key) over and over: each press either refreshes the search or
-- buys the next batch at or under your price that you can afford.
--
-- The game requires a real click or keypress for every search and purchase,
-- so nothing here runs on its own - every action is one press.

local _, ns = ...                 -- shared with Prices.lua (price history and graph)
ns = ns or {}

local DEFAULT_KEY = "SHIFT-G"         -- the watch-list button
local DEFAULT_MANUAL_KEY = "SHIFT-H"  -- the Search & buy button
local STALE_AFTER = 20          -- seconds before search results count as old
local BROWSE_ROWS, WATCH_ROWS = 6, 7

local runtime = {}              -- itemID -> { rows = {...}, time = t }
local browse = {}               -- results of the last name search
local browseOffset = 0          -- how far the results list is scrolled
local browseQuery = ""          -- what was searched, to put exact matches first
local selectedBrowse = nil      -- item picked from the name search
local state = "idle"            -- idle, searching, pricing, confirm, buying
local purchase = nil            -- commodity purchase in progress
local current = 1               -- which watched item is up next
local spent = 0                 -- copper spent this session
local ahOpen = false
local purchaseToken = nil       -- identifies the step a timeout belongs to
local browsePending = false     -- true while our own name search is waiting for results
local browsePendingAt = 0       -- when it went out (a search that never answers stops blocking after 5s)
local searchAuto = false        -- the search in progress was started by the addon, not a press
local pendingBids = {}          -- item buyouts sent, waiting for the server to confirm
local lastMoney = nil           -- gold last seen, to spot a buyout going through
local BID_TIMEOUT = 8           -- seconds before an unconfirmed buyout counts as failed
local itemInfoQueued = false
local manualW = nil             -- the watch-list item the Search & buy button works on
local selectedWatchID = nil     -- the watch-list item you clicked (Search & buy's target)
-- Which button started what's happening: "manual" = the big button (searches
-- and buys the item you clicked, cycling through the list), "watch" = the
-- buy-instantly button (buys whatever Watch all has found)
local lastSource = "watch"
local ManualGo                  -- the big button, defined further down
local ManualQuote               -- defined with the Search & buy button
local latePurchase = nil        -- a purchase that timed out mid-buy, in case it still goes through
local Update                    -- defined further down

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local lastMsg, lastMsgAt = nil, 0
local function Msg(text)
    if text == lastMsg and GetTime() - lastMsgAt < 4 then return end   -- no repeats filling chat
    lastMsg, lastMsgAt = text, GetTime()
    print("|cff33ccffAHWatch:|r " .. text)
end

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
    -- One market price for the whole addon (Prices.lua); Auctionator only
    -- if that isn't loaded for some reason
    if ns.MarketPrice then return ns.MarketPrice(itemID) end
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

------------------------------------------------------------
-- Search pacing: every search the addon sends (background scanning, the
-- big button, Find item, the Sell tab's Check price) waits its turn, a set
-- gap apart. If the server pushes back ("too fast", "busy", a dropped
-- request...), the gap doubles, searching pauses for a bit, and the slower
-- pace is remembered. After a long run without trouble it speeds back up a
-- little at a time - never past the pace that caused trouble.
-- Buying is never held back by this.
------------------------------------------------------------

local DEFAULT_GAP, MIN_GAP, MAX_GAP = 1.5, 0.5, 10
local lastSearchAt, pauseUntil, goodStreak = 0, 0, 0

local function SearchGap() return (AHWatchDB and AHWatchDB.searchGap) or DEFAULT_GAP end

-- Seconds until the next search may go out (0 = now)
local function SearchWait()
    local now = GetTime()
    return math.max(0, lastSearchAt + SearchGap() - now, pauseUntil - now)
end
local function SearchPaused() return GetTime() < pauseUntil end
local function CanSearch() return SearchWait() <= 0 and Ready() end
local function NoteSearch() lastSearchAt = GetTime() end

local bgMissesReset   -- set by the background watcher, further down

local function SlowDown()
    local now = GetTime()
    if now - lastSearchAt > 5 or now < pauseUntil then return end   -- not ours, or already handled
    local old = SearchGap()
    local new = math.min(MAX_GAP, math.max(old * 2, old + 1))
    AHWatchDB.searchGap = new
    -- Don't speed back up past the pace that got this response
    AHWatchDB.searchFloor = math.min(MAX_GAP, math.max(AHWatchDB.searchFloor or 0, old * 1.25))
    local pause = math.max(10, new * 4)
    pauseUntil = now + pause
    goodStreak = 0
    if bgMissesReset then bgMissesReset() end
    Msg(string.format("the auction house asked us to slow down - searching paused for %ds, then one search every %.1fs.",
        math.floor(pause + 0.5), new))
end

-- An answer came back fine: after a long run of them, speed up a little
local function SearchAnswered()
    goodStreak = goodStreak + 1
    if goodStreak < 30 then return end
    goodStreak = 0
    local floor = math.max(MIN_GAP, AHWatchDB.searchFloor or 1.0)
    local g = SearchGap()
    if g > floor then AHWatchDB.searchGap = math.max(floor, g * 0.9) end
end

-- Server messages that mean "too fast"
local SLOW_WORDS = { "too fast", "too many", "too quickly", "slow down", "throttl", "busy", "try again",
    "timed out", "time out", "timeout", "wait", "internal auction error", "database error" }
local function IsSlowDownMessage(text)
    text = (text or ""):lower()
    for _, word in ipairs(SLOW_WORDS) do
        if text:find(word, 1, true) then return true end
    end
    return false
end

ns.CanSearch, ns.NoteSearch, ns.SearchWait = CanSearch, NoteSearch, SearchWait

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
------------------------------------------------------------
-- Not getting stuck on purchases that won't work:
-- - a listing that fails once (already sold but still showing, etc.) is
--   never tried again this session;
-- - an item whose purchases keep failing takes a short break (20s, then
--   1 min, then 3) with one message saying why - no presses or searches
--   are spent on it meanwhile. A successful buy, 10 quiet minutes, or
--   clicking the item in the watch list clears it.
------------------------------------------------------------

local badAuctions = {}          -- auctionID -> true: failed once, skipped from now on
local itemFails = {}            -- itemID -> { n = fails in a row, t = last fail, untilT, level }
local BREAKS = { 20, 60, 180 }

local function BreakLeft(itemID)
    local f = itemFails[itemID]
    if not (f and f.untilT) then return 0 end
    return math.max(0, f.untilT - GetTime())
end

-- threshold: how many failures in a row (within 2 min) before a break
local function BuyFailed(itemID, name, why, threshold)
    if not itemID then return end
    local now = GetTime()
    local f = itemFails[itemID] or { n = 0, level = 0 }
    itemFails[itemID] = f
    if now - (f.t or 0) > 120 then f.n = 0 end
    if f.untilT and now - f.untilT > 600 then f.level = 0 end   -- quiet for 10 min: start over
    f.n, f.t = f.n + 1, now
    if f.n < (threshold or 2) then return end
    f.n = 0
    f.level = math.min(f.level + 1, #BREAKS)
    local secs = BREAKS[f.level]
    f.untilT = now + secs
    runtime[itemID] = nil
    Msg(string.format("skipping %s for %s - %s. Click it in your watch list to try it now.",
        name or "that item", secs >= 120 and ((secs / 60) .. " min") or (secs .. "s"), why))
end

local function BuyWorked(itemID) itemFails[itemID] = nil end
local function ClearBreak(itemID)
    if itemID then itemFails[itemID] = nil else itemFails = {} end
end

local function Plan(w)
    local r = runtime[w.itemID]
    if not r or not r.rows then return nil end
    local pause = BreakLeft(w.itemID)
    if pause > 0 then return nil, { note = string.format("skipped for %ds (buying it keeps failing)", math.ceil(pause)) } end
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
        if unit <= max and not row.own and not badAuctions[row.auctionID] then
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

-- A step got stuck: skip ahead to the next watched item, so the next press
-- does something useful instead of retrying the same stuck one. (With
-- "Cycle list" unchecked it stays on this item, as that setting asks.)
local function MoveOn()
    local list = AHWatchDB and AHWatchDB.watch
    if not list or #list == 0 then return end
    local idx = 1
    for i, w in ipairs(list) do if w.itemID == selectedWatchID then idx = i end end
    local stuck = list[idx]
    runtime[stuck.itemID] = nil
    local name = stuck.name or "that item"
    if #list < 2 or AHWatchDB.cycleList == false then
        Msg(name .. " got stuck - press again to retry.")
        return
    end
    current = idx % #list + 1
    selectedWatchID = list[current].itemID
    Msg(name .. " got stuck - moved on to " .. (list[current].name or "the next item") .. ".")
end

-- Resets a step that never got an answer from the server
local function Timeout(expected, seconds)
    local token = {}
    purchaseToken = token
    C_Timer.After(seconds, function()
        if state == expected and purchaseToken == token then
            -- Steps the addon started by itself just quietly stop (the next
            -- press sends them for real); waiting on your confirm isn't stuck
            local auto = (expected == "searching" and searchAuto) or (purchase and purchase.auto)
            if expected == "pricing" or expected == "confirm" then
                pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            end
            if expected == "buying" then latePurchase = purchase end
            purchase = nil
            searchAuto = false
            if expected ~= "confirm" and not auto and lastSource == "manual" then MoveOn() end
            SetState("idle")
        end
    end)
end

-- auto = started by the addon itself (not a press). If the game ignores an
-- automatic request, the next press simply sends it again for real.
local function Search(w, auto)
    if not CanSearch() then return false end   -- not its turn yet (search pacing)
    local key = w.itemKey or C_AuctionHouse.MakeItemKey(w.itemID)
    runtime[w.itemID] = nil
    searchAuto = auto and true or false
    SetState("searching")
    NoteSearch()
    local ok, err = pcall(C_AuctionHouse.SendSearchQuery, key, { { sortOrder = SORT_PRICE, reverseSort = false } }, false)
    if not ok then
        if not auto then Msg("search failed: " .. tostring(err)) end
        SetState("idle")
        return false
    end
    Timeout("searching", math.max(6, SearchGap() + 4))
    return true
end

------------------------------------------------------------
-- Learning: per item, how often deals (listings at or under your max)
-- show up, at what hours, how long they last before someone else takes
-- them, and how often you get them, miss them, or lose the race. Saved
-- between sessions. Used to buy the most contested deal first, and shown
-- by /ahw stats and on the watch list's tooltips.
------------------------------------------------------------

local dealOpen = {}             -- itemID -> { t = when it appeared, bought = got some of it }
local dealAlertAt = nil         -- when the deal alert went off (to time your press)

local function Learn(itemID)
    AHWatchDB.learn = AHWatchDB.learn or {}
    local x = AHWatchDB.learn[itemID]
    if not x then
        x = { seen = 0, bought = 0, missed = 0, lost = 0, lifeSum = 0, lifeN = 0, hours = {} }
        AHWatchDB.learn[itemID] = x
    end
    return x
end

local function DealOpened(itemID)
    if dealOpen[itemID] then return end
    dealOpen[itemID] = { t = GetTime() }
    local x = Learn(itemID)
    x.seen = x.seen + 1
    local h = date("*t").hour + 1   -- 1-24, so it saves as a plain list
    x.hours[h] = (x.hours[h] or 0) + 1
end

-- The deal is gone. If you didn't get any of it, someone else did (or the
-- seller pulled it): count it as missed and note how long it lasted.
local function DealClosed(itemID)
    local d = dealOpen[itemID]
    if not d then return end
    dealOpen[itemID] = nil
    if d.bought then return end
    local x = Learn(itemID)
    x.missed = x.missed + 1
    local life = GetTime() - d.t
    if life < 600 then x.lifeSum, x.lifeN = x.lifeSum + life, x.lifeN + 1 end
end

local function DealBought(itemID)
    local x = Learn(itemID)
    x.bought = x.bought + 1
    if dealOpen[itemID] then dealOpen[itemID].bought = true end
end

-- You pressed, but someone else got there first
local function DealLost(itemID)
    if not itemID then return end
    local x = Learn(itemID)
    x.lost = x.lost + 1
end

-- New results for a watched item: is there a deal on it right now?
local function TrackDeal(w)
    if BreakLeft(w.itemID) > 0 then return end
    local _, sm = Plan(w)
    if sm and (sm.under or 0) > 0 then DealOpened(w.itemID) else DealClosed(w.itemID) end
end

-- Lower = more contested (deals vanish fast, races get lost): bought first
local function ContestScore(itemID)
    local x = AHWatchDB.learn and AHWatchDB.learn[itemID]
    if not x or x.lifeN < 2 then return 60 end
    local lostShare = x.lost / math.max(1, x.bought + x.lost)
    return x.lifeSum / x.lifeN - lostShare * 10
end

local function NoteReaction()
    if not dealAlertAt then return end
    local rt = GetTime() - dealAlertAt
    dealAlertAt = nil
    if rt > 30 then return end   -- you weren't at the keyboard; don't count it
    AHWatchDB.react = AHWatchDB.react or { sum = 0, n = 0 }
    AHWatchDB.react.sum, AHWatchDB.react.n = AHWatchDB.react.sum + rt, AHWatchDB.react.n + 1
end

local function HourText(h)   -- 1-24 -> "7pm"
    local hr = h - 1
    if hr == 0 then return "12am" elseif hr < 12 then return hr .. "am" elseif hr == 12 then return "12pm" end
    return (hr - 12) .. "pm"
end

local function BestHours(x)
    local list = {}
    for h = 1, 24 do
        if (x.hours[h] or 0) >= 2 then list[#list + 1] = { h = h, n = x.hours[h] } end
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    local out = {}
    for i = 1, math.min(3, #list) do out[i] = HourText(list[i].h) end
    return out
end

-- Short summary + advice for one item (tooltip and /ahw stats)
local function LearnLines(itemID)
    local x = AHWatchDB.learn and AHWatchDB.learn[itemID]
    if not x or x.seen == 0 then return { "No deals seen yet." } end
    local lines = {}
    lines[#lines + 1] = string.format("Deals seen: %d   bought: %d   missed: %d   lost races: %d",
        x.seen, x.bought, x.missed, x.lost)
    if x.lifeN > 0 then
        local life = x.lifeSum / x.lifeN
        lines[#lines + 1] = string.format("Deals you missed lasted about %.1fs%s", life,
            life < 3 and " - very contested" or (life < 10 and " - contested" or ""))
    end
    local best = BestHours(x)
    if #best > 0 then lines[#lines + 1] = "Deals mostly show up around " .. table.concat(best, ", ") end
    local races = x.bought + x.lost
    if x.lost >= 3 and x.lost / math.max(1, races) > 0.3 then
        lines[#lines + 1] = "|cffffd100Losing races here: raise your max a little, or give it your fastest key.|r"
    elseif x.missed >= 5 and x.missed > x.bought * 2 then
        lines[#lines + 1] = "|cffffd100Most deals are gone before you press: keep a finger on the Buy instantly key.|r"
    end
    return lines
end
ns.LearnLines = LearnLines

-- A buyout the server never confirmed: take it back off the spent/bought counts
local function FailBid(p)
    for i, q in ipairs(pendingBids) do
        if q == p then table.remove(pendingBids, i) break end
    end
    spent = math.max(0, spent - p.price)
    if p.w then p.w.bought = math.max(0, (p.w.bought or 0) - p.qty) end
    if (p.w and p.w.bought) == 0 then p.w.bought = nil end
    if not p.second then
        DealLost(p.itemID)
        badAuctions[p.auctionID] = true
        -- Losing a race now and then is normal; four in a row means something's wrong
        BuyFailed(p.itemID, p.name, "its purchases keep failing", 4)
    end
    if p.second then
        Msg("the second buy on that press (" .. (p.name or "item") .. ") didn't go through - if this keeps "
            .. "happening, your server allows only one buy per press: untick \"2 per press\".")
    else
        Msg((p.name or "that item") .. " didn't go through (someone else may have bought it first).")
    end
    if Update then Update() end
end

local function ConfirmBid(i)
    local p = table.remove(pendingBids, i)
    if not p then return end
    if ns.AddLedger then ns.AddLedger(p.itemID, p.name, p.qty, p.price) end
    DealBought(p.itemID)
    BuyWorked(p.itemID)
    local qtyText = p.qty > 1 and (p.qty .. "x ") or ""
    Msg("bought " .. qtyText .. (p.name or "item") .. " for " .. Money(p.price) .. ".")
end

local function Buy(w, plan, auto, manual, second)
    if plan.kind == "commodity" then
        purchase = { itemID = w.itemID, qty = plan.qty, max = MaxPriceFor(w), name = w.name, expected = plan.total,
            auto = auto, w = w, manual = manual }
        SetState("pricing")
        local ok, err = pcall(C_AuctionHouse.StartCommoditiesPurchase, w.itemID, plan.qty)
        if not ok then
            if not auto then Msg("couldn't start the purchase: " .. tostring(err)) end
            purchase = nil
            SetState("idle")
            return false
        end
        Timeout("pricing", 5)
        return true
    else
        local ok, err = pcall(C_AuctionHouse.PlaceBid, plan.auctionID, plan.price)
        if not ok then
            if not second then Msg("couldn't buy: " .. tostring(err)) end
            return false
        end
        -- Counted right away so the spend limit holds while you keep pressing;
        -- taken back off if the server doesn't confirm it (FailBid)
        local qty = plan.row.quantity or 1
        spent = spent + plan.price
        w.bought = (w.bought or 0) + qty
        local p = { auctionID = plan.auctionID, price = plan.price, qty = qty, itemID = w.itemID, name = w.name, w = w, t = GetTime(),
            second = second }
        table.insert(pendingBids, p)
        C_Timer.After(BID_TIMEOUT, function()
            for _, q in ipairs(pendingBids) do
                if q == p then FailBid(p) return end
            end
        end)
        -- Take it off the local list so the next press buys the next one
        local rows = runtime[w.itemID] and runtime[w.itemID].rows
        if rows then
            for i, row in ipairs(rows) do
                if row == plan.row then table.remove(rows, i) break end
            end
        end
        Update()
        return true
    end
end

-- "2 per press": right after a single-listing buy, try the next listing at
-- or under your price on the same press. Some servers only allow one buy
-- per press; then the second just doesn't go through (FailBid says so).
local function TwoPerPress() return AHWatchDB and AHWatchDB.twoPerPress ~= false end

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

local function CurrentTab() return (AHWatchDB and AHWatchDB.tab) or "buy" end
ns.CurrentTab = CurrentTab

-- Right after fresh results for a commodity, ask for its price straight away
-- so the next press can confirm - one press per batch instead of two.
-- (Only gets a price quote; nothing is bought without a press.)
-- The next thing worth buying across the whole watch list (fresh results
-- only), starting from the current item.
local function NextPlan()
    local list = AHWatchDB.watch
    local n = #list
    if n == 0 or LimitReached() then return nil end
    if current > n then current = 1 end
    -- Several deals at once: the most contested one first (it'll be gone
    -- soonest); the others are likelier to still be there next press
    local bestW, bestPlan, bestI, bestScore
    for k = 0, n - 1 do
        local i = (current - 1 + k) % n + 1
        local w = list[i]
        local r = runtime[w.itemID]
        if r and r.rows and GetTime() - r.time <= STALE_AFTER then
            local plan = Plan(w)
            if plan then
                local sc = ContestScore(w.itemID)
                if not bestW or sc < bestScore then bestW, bestPlan, bestI, bestScore = w, plan, i, sc end
            end
        end
    end
    return bestW, bestPlan, bestI
end

-- Get a commodity's price ready ahead of time, so the next press buys it
-- outright (the game needs a price check between "start" and "buy").
-- Only gets a price quote; nothing is bought without a press.
local AutoSearchOn
local function AutoQuote(w)
    if not ahOpen or state ~= "idle" or CurrentTab() ~= "buy" or not Ready() then return end
    if not AutoSearchOn() then return end
    local nw, plan, i = NextPlan()
    if not nw or plan.kind ~= "commodity" then return end   -- a press can buy something right now anyway
    if w and nw ~= w then return end
    current = i
    lastSource = "watch"
    Buy(nw, plan, true)
end

------------------------------------------------------------
-- Watching the whole list: while the Buy tab is open, keep every watched
-- item's results fresh in the background (searches are allowed without a
-- press; only buying needs one), so presses go to buying, not searching.
------------------------------------------------------------

local BG_REFRESH = 1.5         -- re-search an item once its results are this old
local bgPending = nil          -- { itemID, t } background search waiting for results
local bgLast, bgMisses = 0, 0
local bgBroken = false         -- the game ignored background searches: presses search instead

function AutoSearchOn() return AHWatchDB and AHWatchDB.autoSearch ~= false and not bgBroken end

-- One search for the whole list: the auction house's favorites search (the
-- star button) returns the cheapest price of every favorited item at once.
-- Watched items are starred, that one search runs every turn, and only an
-- item showing a price at or under your max gets its own full search -
-- instead of one search per item per round.
local favPending = nil          -- time the favorites search went out
local favMisses = 0
local favBroken = false         -- this client can't do it: one item per search instead
local hot = {}                  -- itemID -> true: priced at/under your max, search it next
local hotOrder = {}

local function FavoritesOK()
    return not favBroken and C_AuctionHouse and C_AuctionHouse.SearchForFavorites and C_AuctionHouse.SetFavoriteItem
end

local function WatchKey(w) return w.itemKey or C_AuctionHouse.MakeItemKey(w.itemID) end

-- Star every watched item (remembering which ones we starred, so removing
-- an item from the list un-stars only those)
local function SyncFavorites()
    if not FavoritesOK() or not ahOpen then return end
    AHWatchDB.favAdded = AHWatchDB.favAdded or {}
    for _, w in ipairs(AHWatchDB.watch) do
        local key = WatchKey(w)
        local okF, isFav = pcall(C_AuctionHouse.IsFavoriteItem, key)
        if okF and not isFav then
            if pcall(C_AuctionHouse.SetFavoriteItem, key, true) then AHWatchDB.favAdded[w.itemID] = true end
        end
    end
end
ns.SyncFavorites = SyncFavorites

local function UnfavoriteIfOurs(w)
    if not (w and AHWatchDB.favAdded and AHWatchDB.favAdded[w.itemID]) then return end
    AHWatchDB.favAdded[w.itemID] = nil
    if C_AuctionHouse and C_AuctionHouse.SetFavoriteItem then pcall(C_AuctionHouse.SetFavoriteItem, WatchKey(w), false) end
end

local function MarkHot(itemID)
    if BreakLeft(itemID) > 0 then return end
    if not hot[itemID] then hot[itemID] = true; table.insert(hotOrder, itemID) end
end

-- Favorites results: queue up the items worth a full search
local function FavoritesResults()
    favPending, favMisses = nil, 0
    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    local seen = {}
    for _, res in ipairs((ok and results) or {}) do
        local id = res.itemKey and res.itemKey.itemID
        local w = id and FindWatch(id)
        if w and res.minPrice then
            seen[id] = true
            local max = MaxPriceFor(w)
            local want = not (w.maxQty and w.maxQty > 0 and (w.bought or 0) >= w.maxQty)
            if max and want and res.minPrice <= max then MarkHot(id) else DealClosed(id) end
        end
    end
    -- A watched item missing from the results isn't listed right now
    for id in pairs(dealOpen) do
        if not seen[id] and FindWatch(id) then DealClosed(id) end
    end
    table.sort(hotOrder, function(a, b) return ContestScore(a) < ContestScore(b) end)
    return seen
end

local function BackgroundSearch()
    if not AutoSearchOn() or not ahOpen or state ~= "idle" or CurrentTab() ~= "buy" then return end
    if not (AHWatchFrame and AHWatchFrame:IsShown()) then return end
    if browsePending then   -- your own Find item search is on its way
        if GetTime() - browsePendingAt < 5 then return end
        browsePending = false
    end
    local now = GetTime()
    if favPending and now - favPending > math.max(5, SearchGap() + 3) then
        favPending = nil
        favMisses = favMisses + 1
        if favMisses >= 3 then
            favBroken = true   -- fall back to one item per search
            Msg("this client's favorites search isn't answering - checking items one at a time instead.")
        end
    end
    if favPending then return end
    if bgPending then
        if now - bgPending.t < math.max(5, SearchGap() + 3) then return end
        -- No answer: after a few in a row, this client doesn't allow it
        bgPending = nil
        bgMisses = bgMisses + 1
        if bgMisses >= 3 then
            bgBroken = true
            Msg("this game client won't search in the background, so each press will search when needed instead.")
            if Update then Update() end
            return
        end
    end
    if not CanSearch() then return end   -- search pacing: as fast as the server allows, no faster
    -- A buyout you just made is still going through: don't put a search in its way (up to 3s)
    for _, p in ipairs(pendingBids) do
        if now - (p.t or 0) < 3 then return end
    end
    local list = AHWatchDB.watch
    if #list == 0 then return end
    -- A deal is waiting: leave the server free so your press buys it at once -
    -- just re-check that one item every few seconds, so a deal someone else
    -- took isn't still offered (and to learn how long its deals last)
    local dw = NextPlan()
    if dw then
        local r = runtime[dw.itemID]
        if r and now - r.time < math.max(3, SearchGap() * 2) then return end
        NoteSearch()
        local ok = pcall(C_AuctionHouse.SendSearchQuery, WatchKey(dw), { { sortOrder = SORT_PRICE, reverseSort = false } }, false)
        bgLast = now
        if ok then bgPending = { itemID = dw.itemID, t = now } end
        return
    end
    -- 1) Items the favorites search showed at or under your price: full search, first in line
    while #hotOrder > 0 do
        local id = table.remove(hotOrder, 1)
        hot[id] = nil
        local w = FindWatch(id)
        if w then
            NoteSearch()
            local ok = pcall(C_AuctionHouse.SendSearchQuery, WatchKey(w), { { sortOrder = SORT_PRICE, reverseSort = false } }, false)
            bgLast = now
            if ok then bgPending = { itemID = id, t = now } end
            return
        end
    end
    -- 2) Otherwise one favorites search covers the whole list
    if FavoritesOK() then
        SyncFavorites()
        NoteSearch()
        local ok = pcall(C_AuctionHouse.SearchForFavorites, { { sortOrder = SORT_PRICE, reverseSort = false } })
        if ok then
            favPending = now
            return
        end
        favBroken = true
    end
    -- 3) No favorites search on this client: the item with the oldest results (or none yet)
    local pick, oldest
    for _, w in ipairs(list) do
        local r = runtime[w.itemID]
        local age = (r and r.rows) and (now - r.time) or math.huge
        if age > BG_REFRESH and BreakLeft(w.itemID) == 0 and (not oldest or age > oldest) then pick, oldest = w, age end
    end
    if not pick then return end
    local key = pick.itemKey or C_AuctionHouse.MakeItemKey(pick.itemID)
    NoteSearch()
    local ok = pcall(C_AuctionHouse.SendSearchQuery, key, { { sortOrder = SORT_PRICE, reverseSort = false } }, false)
    bgLast = now
    if ok then bgPending = { itemID = pick.itemID, t = now } end
end
-- Being told to slow down isn't the client ignoring background searches
bgMissesReset = function() bgMisses, bgPending = 0, nil end
C_Timer.NewTicker(0.3, BackgroundSearch)

local function BgResults(itemID)
    if bgPending and bgPending.itemID == itemID then
        bgPending = nil
        bgMisses = 0
    end
end

-- The one button on the Buy tab: refresh, buy, confirm, or move to the next item
local function BuyGo()
    EnsureDB()
    local list = AHWatchDB.watch
    if not ahOpen then Msg("open the auction house first.") return end
    if #list == 0 then Msg("add an item to your watch list first.") return end
    if state == "confirm" then NoteReaction(); ConfirmBuy() return end   -- a deal is lined up: buy it
    if state ~= "idle" and lastSource == "manual" then return end   -- the big button is mid-search
    -- An automatic step the game may have ignored: this press sends it for real
    if state == "pricing" and purchase and purchase.auto then
        purchase.auto = false
        local ok = pcall(C_AuctionHouse.StartCommoditiesPurchase, purchase.itemID, purchase.qty)
        if ok then Timeout("pricing", 5) else purchase = nil; SetState("idle") end
        return
    end
    if state ~= "idle" then return end
    -- (Buying doesn't wait for the server to finish background searches)
    if LimitReached() then Msg("spend limit reached - raise it or press Reset spent.") return end
    if not AutoSearchOn() then
        Msg("turn on Watch all - this button buys what it finds. The big button searches item by item.")
        return
    end
    if current > #list then current = 1 end
    -- Anything on the list at or under its price right now: buy it on this press
    local bw, plan, i = NextPlan()
    if bw then
        NoteReaction()
        lastSource = "watch"
        current = i
        if Buy(bw, plan) and plan.kind == "item" and TwoPerPress() then
            local bw2, plan2, i2 = NextPlan()
            if bw2 and plan2.kind == "item" then
                current = i2
                Buy(bw2, plan2, false, false, true)
            end
        end
    end
    -- Nothing found yet: Watch all keeps looking; the button says so
end

-- The single Go button/keybind is shared across tabs - Buy has its
-- watch-list logic above, Quick Sell (Sell.lua) has its own repeated-press
-- post logic. On the Sell tab the button is hidden, so the key just brings
-- you back to Buy rather than buying anything out of sight.
local function Go()
    local tab = CurrentTab()
    if tab == "quicksell" and ns.QuickSellGo then
        ns.QuickSellGo()
        return
    end
    if tab == "sell" then
        if ns.SetTab then ns.SetTab("buy") end
        return
    end
    if ManualGo then ManualGo() end
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
f:SetSize(360, 716)
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
    -- Windows attached to the main one already inherit its scale; scaling
    -- them too would apply it twice
    local parent = frame:GetParent()
    if not parent or parent == UIParent then
        table.insert(scaledFrames, frame)
        frame:SetScale(CurrentScale())
    end

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
            local called, loaded = pcall(entry.icon.SetTexture, entry.icon, path)
            ok = called and loaded ~= false
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
    -- Scroll the results with the mouse wheel
    b:EnableMouseWheel(true)
    b:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #browse - BROWSE_ROWS)
        browseOffset = math.max(0, math.min(maxOffset, browseOffset - delta * (IsShiftKeyDown() and BROWSE_ROWS or 1)))
        if Update then Update() end
    end)
    b:Hide()
    browseRows[i] = b
end
-- "7-12 of 20 - scroll for more", next to "Find item:"
local browseCount = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
browseCount:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -32)
browseCount:SetJustifyH("RIGHT")

-- Exact name first, then names starting with what you typed, then the rest
-- (otherwise in the auction house's own order)
local function SortBrowse()
    local q = browseQuery
    if q == "" then return end
    local function Rank(e)
        local n = e.name and e.name:lower()
        if not n then return 3 end
        if n == q then return 0 end
        if n:sub(1, #q) == q then return 1 end
        return 2
    end
    for _, e in ipairs(browse) do e.rank = Rank(e) end
    table.sort(browse, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.order < b.order
    end)
end

-- Max price + add
Label("Max price each:", 14, -200)
local maxMoney = MoneyInput(22, -216)
-- How the max compares with the market, updated as you type:
-- "50% below market (2s)", or "= 1s 60c each" when using a % instead
local maxVs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
maxVs:SetPoint("TOPLEFT", f, "TOPLEFT", 108, -200)
maxVs:SetWidth(238)
maxVs:SetJustifyH("LEFT")
maxVs:SetWordWrap(false)

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

-- Cycle list: when the big button finds nothing on the item you clicked,
-- move on to the next item (checked) or keep re-checking that one (unchecked)
local cycleBox = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
cycleBox:SetSize(20, 20)
cycleBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -298)
local cycleLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cycleLabel:SetPoint("RIGHT", cycleBox, "LEFT", -2, 0)
cycleLabel:SetText("Cycle list")
cycleBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Cycle list", 1, 1, 1)
    GameTooltip:AddLine("Checked: when the big button finds nothing at your price on the item you clicked, it moves on to the next item on the list.", 1, 0.9, 0.6, true)
    GameTooltip:AddLine("Unchecked: it keeps re-checking just the item you clicked.", 1, 0.9, 0.6, true)
    GameTooltip:Show()
end)
cycleBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
cycleBox:SetScript("OnClick", function(self)
    EnsureDB()
    AHWatchDB.cycleList = self:GetChecked() and true or false
    if Update then Update() end
end)

-- 2 per press (on by default)
local twoBox = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
twoBox:SetSize(20, 20)
twoBox:SetPoint("TOPLEFT", f, "TOPLEFT", 158, -298)
local twoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
twoLabel:SetPoint("LEFT", twoBox, "RIGHT", 2, 0)
twoLabel:SetText("2 per press")
twoBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("2 per press", 1, 1, 1)
    GameTooltip:AddLine("For single listings (gear and other non-stacking items), each press tries to buy the two cheapest at or under your price instead of one.", 1, 0.9, 0.6, true)
    GameTooltip:AddLine("Stackable goods already buy every unit at your price in one press.", 1, 0.9, 0.6, true)
    GameTooltip:AddLine("Some servers only allow one buy per press - if chat keeps saying the second buy didn't go through, untick this.", 1, 0.9, 0.6, true)
    GameTooltip:Show()
end)
twoBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
twoBox:SetScript("OnClick", function(self)
    EnsureDB()
    AHWatchDB.twoPerPress = self:GetChecked() and true or false
end)

-- Keep searching the whole list in the background (on by default)
local autoBox = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
autoBox:SetSize(20, 20)
autoBox:SetPoint("TOPLEFT", f, "TOPLEFT", 84, -298)
local autoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
autoLabel:SetPoint("LEFT", autoBox, "RIGHT", 2, 0)
autoLabel:SetText("Watch all")
autoBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Watch all", 1, 1, 1)
    GameTooltip:AddLine("Checked: keeps searching every item on your list in the background as fast as the server allows, so each press of the Buy instantly button buys whatever it found at or under your price.", 1, 0.9, 0.6, true)
    GameTooltip:AddLine("The big button still searches and buys the item you clicked, either way.", 1, 0.9, 0.6, true)
    GameTooltip:Show()
end)
autoBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
autoBox:SetScript("OnClick", function(self)
    EnsureDB()
    AHWatchDB.autoSearch = self:GetChecked() and true or false
    if AHWatchDB.autoSearch then bgBroken, bgMisses = false, 0 end   -- try again
    if Update then Update() end
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

local ledgerBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
ledgerBtn:SetSize(80, 20)
ledgerBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
ledgerBtn:SetText("Ledger")
ledgerBtn:SetNormalFontObject(GameFontNormalSmall)
ledgerBtn:SetHighlightFontObject(GameFontHighlightSmall)
ledgerBtn:SetScript("OnClick", function() if ns.ToggleLedger then ns.ToggleLedger() end end)
ledgerBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Ledger")
    GameTooltip:AddLine("Everything you've bought with AH Watch, and what you paid.", 1, 1, 1, true)
    GameTooltip:Show()
end)
ledgerBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
local capturing = nil           -- which key is being set: "keybind" (watch list) or "manualKeybind"

local function GetKey() return (AHWatchDB and AHWatchDB.keybind) or DEFAULT_KEY end
local function GetManualKey() return (AHWatchDB and AHWatchDB.manualKeybind) or DEFAULT_MANUAL_KEY end
ns.GetKey = GetKey

local function ApplyKey()
    ClearOverrideBindings(keyOwner)
    if ahOpen then
        SetOverrideBindingClick(keyOwner, true, GetKey(), "AHWatchGoButton")
        if GetManualKey() ~= GetKey() then
            SetOverrideBindingClick(keyOwner, true, GetManualKey(), "AHWatchManualButton")
        end
    end
end

local function StopCapture()
    capturing = nil
    f:SetScript("OnKeyDown", nil)
    f:EnableKeyboard(false)
    Update()
end

local IGNORE_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, UNKNOWN = true }

-- Left-click a key button, then press a key; right-click puts it back to the default
local function KeyButtonClick(which, button)
    local default = (which == "keybind") and DEFAULT_KEY or DEFAULT_MANUAL_KEY
    local label = (which == "keybind") and "the big button" or "Buy instantly"
    if button == "RightButton" then
        AHWatchDB[which] = nil
        ApplyKey()
        if capturing then StopCapture() else Update() end
        return
    end
    if capturing then StopCapture() return end
    capturing = which
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(false)
    f:SetScript("OnKeyDown", function(_, key)
        if IGNORE_KEYS[key] then return end
        if key ~= "ESCAPE" then
            local combo = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
                .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
            local other = (which == "keybind") and GetManualKey() or GetKey()
            if combo == other then
                Msg(combo .. " is already used by the other button - pick a different key.")
            else
                AHWatchDB[which] = (combo ~= default) and combo or nil
                ApplyKey()
                Msg(combo .. " now presses " .. label .. " while the auction house is open.")
            end
        end
        StopCapture()
    end)
    Update()
end

local function KeyTooltip(self, title)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(title)
    GameTooltip:AddLine("Left-click, then press a key. Right-click to reset.", 1, 1, 1)
    GameTooltip:AddLine("Only active while the auction house is open.", 1, 1, 1)
    GameTooltip:Show()
end

bindBtn:SetScript("OnClick", function(_, button) KeyButtonClick("keybind", button) end)
bindBtn:SetScript("OnEnter", function(self) KeyTooltip(self, "Big button key") end)
bindBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

------------------------------------------------------------
-- Search & buy: a separate button for the item picked in "Find item",
-- at the max price and amount set there - like the original one-button
-- flow: a press searches, the next press buys. It doesn't touch the
-- watch list, and has its own key.
------------------------------------------------------------

local manualBtn = CreateFrame("Button", "AHWatchManualButton", f, "UIPanelButtonTemplate")
manualBtn:SetSize(248, 26)
manualBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 72)
manualBtn.pbAlt = true     -- its own colour, apart from the big button
manualBtn:SetNormalFontObject(GameFontNormalSmall)
manualBtn:SetHighlightFontObject(GameFontHighlightSmall)
manualBtn:SetDisabledFontObject(GameFontDisableSmall)

local manualKeyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
manualKeyBtn:SetSize(82, 22)
manualKeyBtn:SetPoint("LEFT", manualBtn, "RIGHT", 2, 0)
manualKeyBtn:SetNormalFontObject(GameFontNormalSmall)
manualKeyBtn:SetHighlightFontObject(GameFontHighlightSmall)
manualKeyBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
manualKeyBtn:SetScript("OnClick", function(_, button) KeyButtonClick("manualKeybind", button) end)
manualKeyBtn:SetScript("OnEnter", function(self) KeyTooltip(self, "Buy instantly key") end)
manualKeyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
manualBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Buy instantly")
    GameTooltip:AddLine("With Watch all on, every item on your list is checked in the background as fast as the "
        .. "server allows. Each press buys whatever was found at or under its max price - no picking, no searching.", 1, 1, 1, true)
    GameTooltip:Show()
end)
manualBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
goBtn:SetScript("OnEnter", function(self)
    if CurrentTab() ~= "buy" then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Search and buy")
    GameTooltip:AddLine("Works on the item you clicked in your watch list: a press searches it, the next press buys "
        .. "whatever is at or under its max price.", 1, 1, 1, true)
    GameTooltip:AddLine("With Cycle list checked it moves on to the next item when nothing is found.", 1, 1, 1, true)
    GameTooltip:Show()
end)
goBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- The watch-list item you clicked
local function ManualTarget()
    local list = AHWatchDB and AHWatchDB.watch or {}
    for _, w in ipairs(list) do
        if w.itemID == selectedWatchID then
            manualW = w
            return w
        end
    end
    -- Nothing clicked yet: start at the top of the list
    if list[1] then
        selectedWatchID = list[1].itemID
        manualW = list[1]
        return list[1]
    end
    manualW = nil
    return nil, "add an item to your watch list"
end

-- With "Cycle list" on, the item after the selected one
local function NextAfter(w)
    local list = AHWatchDB.watch
    if AHWatchDB.cycleList == false or #list < 2 then return nil end
    for i, x in ipairs(list) do
        if x == w then return list[i % #list + 1], i % #list + 1 end
    end
end

-- After its search: get a stackable item's price ready, so the next press buys
function ManualQuote()
    if state ~= "idle" or not manualW or not Ready() or LimitReached() then return end
    local plan = Plan(manualW)
    if plan and plan.kind == "commodity" then
        lastSource = "manual"
        Buy(manualW, plan, true, true)
    end
end

function ManualGo()
    EnsureDB()
    if not ahOpen then Msg("open the auction house first.") return end
    local w, why = ManualTarget()
    if not w then Msg(why .. " first.") return end
    -- Something the other button lined up by itself
    if (state == "pricing" or state == "confirm") and purchase and not purchase.manual then
        if purchase.itemID == w.itemID then
            -- It's this same item: take it over instead of starting again
            purchase.manual, lastSource = true, "manual"
            if state == "confirm" then ConfirmBuy() end
            return
        end
        CancelBuy()
    end
    if state == "confirm" and purchase and purchase.manual then ConfirmBuy() return end
    if state == "pricing" and purchase and purchase.manual and purchase.auto then
        purchase.auto = false
        local ok = pcall(C_AuctionHouse.StartCommoditiesPurchase, purchase.itemID, purchase.qty)
        if ok then Timeout("pricing", 5) else purchase = nil; SetState("idle") end
        return
    end
    if state == "searching" and searchAuto and lastSource == "manual" then
        if Ready() then Search(w) end
        return
    end
    if state ~= "idle" then return end
    if LimitReached() then Msg("spend limit reached - raise it or press Reset spent.") return end
    lastSource = "manual"
    -- The item is taking a break (its purchases keep failing): next item, or say so
    if BreakLeft(w.itemID) > 0 then
        local nxt, idx = NextAfter(w)
        if nxt and BreakLeft(nxt.itemID) == 0 then
            selectedWatchID, current, manualW = nxt.itemID, idx, nxt
            if Ready() then Search(nxt) end
        else
            Msg(string.format("%s is skipped for %ds - buying it keeps failing.", w.name or "That item", math.ceil(BreakLeft(w.itemID))))
        end
        return
    end
    local r = runtime[w.itemID]
    if not r or not r.rows or GetTime() - r.time > STALE_AFTER then
        if Ready() then Search(w) end
        return
    end
    local plan, summary = Plan(w)
    if plan then
        if Buy(w, plan, false, true) and plan.kind == "item" and TwoPerPress() then
            local plan2 = Plan(w)
            if plan2 and plan2.kind == "item" then Buy(w, plan2, false, true, true) end
        end
        return
    end
    if not Ready() then return end   -- the rest searches, which has to wait for the server
    -- Nothing to buy on this item: move on to the next one (Cycle list),
    -- or look at this one again
    local nxt, idx = NextAfter(w)
    if nxt then
        selectedWatchID, current = nxt.itemID, idx
        manualW = nxt
        Search(nxt)
    elseif summary and summary.note then
        Msg((w.name or "that item") .. ": " .. summary.note .. ".")
    else
        Search(w)
    end
end

local function ManualText()
    if not ahOpen then return "Open the Auction House" end
    local w, why = ManualTarget()
    if not w then return (why:gsub("^%l", string.upper)) end
    local name = w.name or "item"
    if lastSource == "manual" or (purchase and purchase.manual) then
        if state == "searching" then return "Searching " .. name .. "..." end
        if state == "pricing" then return "Checking the price..." end
        if state == "buying" then return "Buying..." end
        if state == "confirm" and purchase and purchase.manual then
            return "BUY " .. purchase.qty .. "x " .. name .. " for " .. Money(purchase.total)
        end
    elseif state ~= "idle" then
        return name .. " - waiting for the other button..."
    end
    if LimitReached() then return "Spend limit reached" end
    if BreakLeft(w.itemID) > 0 then
        local nxt = NextAfter(w)
        return string.format("%s skipped %ds - click it to retry%s", name, math.ceil(BreakLeft(w.itemID)),
            nxt and (", or press for " .. (nxt.name or "next item")) or "")
    end
    local r = runtime[w.itemID]
    if not r or not r.rows or GetTime() - r.time > STALE_AFTER then
        if SearchPaused() then return string.format("Search: %s (server pause, %ds)", name, math.ceil(SearchWait())) end
        local wait = SearchWait()
        return "Search: " .. name .. (wait > 0.05 and string.format(" (in %.1fs)", wait) or "")
    end
    local plan, summary = Plan(w)
    if plan and plan.kind == "commodity" then
        return "BUY " .. plan.qty .. "x " .. name .. " for " .. Money(plan.total)
    elseif plan then
        return "BUY " .. name .. " for " .. Money(plan.price)
    end
    local nxt = NextAfter(w)
    if nxt then return "None at your price - next: " .. (nxt.name or "next item") end
    if summary and summary.note then return name .. ": " .. summary.note end
    return "None at your price - search again"
end

------------------------------------------------------------
-- Updating the window
------------------------------------------------------------

local function GoText()
    local list = AHWatchDB.watch
    if not ahOpen then return "Buy instantly: open the Auction House" end
    if #list == 0 then return "Buy instantly: add items to watch" end
    if not AutoSearchOn() then
        return bgBroken and "Buy instantly: background search unavailable" or "Buy instantly: turn on Watch all"
    end
    if state ~= "idle" and (lastSource == "manual" or (purchase and purchase.manual)) and state ~= "confirm" then
        return "Buy instantly - waiting for the big button..."
    end
    if state == "searching" then return "Searching..." end
    if state == "pricing" then return "Checking the price of " .. ((purchase and purchase.name) or "it") .. "..." end
    if state == "buying" then return "Buying " .. ((purchase and purchase.name) or "") .. "..." end
    if state == "confirm" and purchase then
        return "BUY " .. purchase.qty .. "x " .. (purchase.name or "") .. " for " .. Money(purchase.total)
    end
    if #list == 0 then return "Add an item to watch" end
    if LimitReached() then return "Spend limit reached - raise it or Reset spent" end
    if current > #list then current = 1 end
    local bw, plan = NextPlan()
    if plan and plan.kind == "commodity" then
        return "Buy " .. plan.qty .. "x " .. (bw.name or "") .. " for " .. Money(plan.total)
    elseif plan then
        return "BUY " .. (bw.name or "item") .. " for " .. Money(plan.price)
    end
    if SearchPaused() then
        return string.format("Server asked to slow down - scanning again in %ds", math.ceil(SearchWait()))
    end
    local n = #list
    return string.format("Watching %d item%s - nothing yet (1 search / %.1fs)", n, n == 1 and "" or "s", SearchGap())
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
        if #AHWatchDB.watch >= WATCH_ROWS then
            Msg("your watch list is full (" .. WATCH_ROWS .. ") - remove an item first, or add " .. (name or "this item")
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
    selectedWatchID = w.itemID
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
    for _, e in ipairs(browse) do e.name = e.name or ItemName(e.itemID) end
    SortBrowse()
    browseOffset = math.max(0, math.min(browseOffset, #browse - BROWSE_ROWS))
    if #browse > BROWSE_ROWS then
        browseCount:SetText(string.format("%d-%d of %d - scroll for more", browseOffset + 1,
            math.min(browseOffset + BROWSE_ROWS, #browse), #browse))
    else
        browseCount:SetText("")
    end
    for i, b in ipairs(browseRows) do
        local e = browse[browseOffset + i]
        if e then
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
            b.next:SetShown(w.itemID == selectedWatchID)
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
        goBtn:SetText(ManualText() .. "  |cff888888(" .. GetKey() .. ")|r")
        manualBtn:SetText(GoText() .. "  |cff888888(" .. GetManualKey() .. ")|r")
        cancelBtn:SetShown(state == "pricing" or state == "confirm")
    end
    ledgerBtn:SetShown(not cancelBtn:IsShown())
    if selectedBrowse and FindWatch(selectedBrowse.itemID) then
        addBtn:SetText("On list (saved)")
        addBtn:Disable()
    else
        addBtn:SetText("Add to list")
        addBtn:SetEnabled(selectedBrowse ~= nil)
    end
    if ns.CheckDealAlert then ns.CheckDealAlert() end
    bindBtn:SetText(capturing == "keybind" and "Press a key..." or ("Key: " .. GetKey()))
    manualKeyBtn:SetText(capturing == "manualKeybind" and "Press a key..." or ("Key: " .. GetManualKey()))

    ThemeLabel()

    local e = selectedBrowse
    if not e then
        maxVs:SetText("")
    else
        local pct = tonumber(pctBox:GetText() or "")
        if pct and pct > 0 then
            local m = MarketPrice(e.itemID)
            maxVs:SetText(m and ("|cffffffff= " .. (ns.ShortMoney and ns.ShortMoney(m * pct / 100) or Money(m * pct / 100)) .. " each|r")
                or "|cff888888no market price yet|r")
        elseif ns.VsMarket then
            maxVs:SetText(ns.VsMarket(e.itemID, maxMoney.GetValue()))
        end
    end
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
    if not CanSearch() then
        Msg(string.format("waiting so the server doesn't time you out - search again in %.1fs.", math.max(0.1, SearchWait())))
        return
    end
    NoteSearch()
    browse, selectedBrowse, browseOffset = {}, nil, 0
    browseQuery = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    browsePending, browsePendingAt = true, GetTime()
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
    if manualW then manualW.bought = nil end
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
    b:SetScript("OnEnter", function(self)
        local w = AHWatchDB.watch[self.index]
        if not w then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(w.name or ItemName(w.itemID) or "Item")
        GameTooltip:AddLine("What AH Watch has learned:", 0.6, 0.8, 1)
        for _, line in ipairs(LearnLines(w.itemID)) do GameTooltip:AddLine(line, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        current = self.index
        local w = AHWatchDB.watch[self.index]
        if w then
            selectedWatchID = w.itemID   -- Search & buy works on this one
            ClearBreak(w.itemID)         -- you picked it: try it again now
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
        if w and w.itemID == selectedWatchID then selectedWatchID = nil end
        UnfavoriteIfOurs(w)
        table.remove(AHWatchDB.watch, i)
        if current > #AHWatchDB.watch then current = 1 end
        Update()
    end)
end

goBtn:SetScript("OnClick", Go)

-- Deal alert: the moment Watch all finds something at your price, play a
-- sound and pulse the Buy instantly button until it's bought or gone, so
-- you can press without having to watch the button. /ahw alert toggles it.
local dealAlerted = false
local pulse = CreateFrame("Frame")
pulse:Hide()
pulse:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    manualBtn:SetAlpha(0.55 + 0.45 * math.abs(math.cos(self.t * 7)))
end)
local function DealReady()
    if not ahOpen or CurrentTab() ~= "buy" or not AutoSearchOn() or LimitReached() then return false end
    if state == "confirm" and purchase and not purchase.manual then return true end
    return state == "idle" and NextPlan() ~= nil
end
function ns.CheckDealAlert()
    local ready = DealReady()
    if ready and not dealAlerted then
        dealAlerted = true
        dealAlertAt = GetTime()
        if AHWatchDB.dealAlert ~= false then
            local sound = (SOUNDKIT and (SOUNDKIT.RAID_WARNING or SOUNDKIT.READY_CHECK)) or 8959
            pcall(PlaySound, sound, "Master")
            pulse.t = 0
            pulse:Show()
        end
    elseif not ready and dealAlerted then
        dealAlerted = false
        dealAlertAt = nil
        pulse:Hide()
        manualBtn:SetAlpha(1)
    end
end
-- Act the moment the key (or mouse button) goes down, not when it's let go
goBtn:RegisterForClicks("AnyDown")
manualBtn:RegisterForClicks("AnyDown")
C_Timer.NewTicker(0.5, function()
    if ahOpen and f:IsShown() and CurrentTab() == "buy" then Update() end
end)
-- On other tabs the Search & buy button is covered up, so its key does nothing there
manualBtn:SetScript("OnClick", function() if CurrentTab() == "buy" then BuyGo() end end)
cancelBtn:SetScript("OnClick", CancelBuy)
f:SetScript("OnShow", Update)

SLASH_AHWATCH1 = "/ahw"
SLASH_AHWATCH2 = "/ahwatch"
SlashCmdList["AHWATCH"] = function(msg)
    local mb = (msg or ""):match("^%s*limit%s*(%S*)")
    local ml = (msg or ""):match("^%s*minlisted%s*(%S*)")
    local sg = (msg or ""):match("^%s*searchgap%s*(%S*)")
    local isAlert = (msg or ""):match("^%s*alert%s*$")
    local unskip = (msg or ""):match("^%s*unskip%s*$")
    local stats = (msg or ""):match("^%s*stats%s*(%S*)")
    local ma = (msg or ""):match("^%s*avgqty%s*(%S*)")
    if (msg or ""):match("^%s*data%s*$") and ns.PrintData then
        ns.PrintData()
    elseif (msg or ""):match("^%s*ledger%s*$") and ns.ToggleLedger then
        ns.ToggleLedger()
    elseif mb and ns.SetLimit then
        ns.SetLimit(mb)
    elseif stats then
        EnsureDB()
        if stats == "reset" then
            AHWatchDB.learn, AHWatchDB.react = nil, nil
            Msg("learned stats cleared.")
            return
        end
        Msg("what AH Watch has learned (/ahw stats reset to start over):")
        local any = false
        for _, w in ipairs(AHWatchDB.watch) do
            any = true
            print("  |cffffd100" .. (w.name or ItemName(w.itemID) or ("Item " .. w.itemID)) .. "|r")
            for _, line in ipairs(LearnLines(w.itemID)) do print("    " .. line) end
        end
        if not any then print("  (your watch list is empty)") end
        local r = AHWatchDB.react
        if r and r.n > 0 then
            print(string.format("  Your reaction: %.2fs on average from the alert to your press (%d presses)", r.sum / r.n, r.n))
        else
            print("  Your reaction: not measured yet (it's timed from the deal alert to your Buy instantly press)")
        end
    elseif unskip then
        ClearBreak()
        Msg("every item is back in - nothing is being skipped.")
    elseif isAlert then
        EnsureDB()
        AHWatchDB.dealAlert = (AHWatchDB.dealAlert == false)
        Msg("deal alert (sound + pulsing Buy instantly button) is now " .. (AHWatchDB.dealAlert and "on" or "off") .. ".")
    elseif sg then
        EnsureDB()
        local n = tonumber(sg)
        if not n or n < MIN_GAP or n > MAX_GAP then
            Msg(string.format("usage: /ahw searchgap <seconds>  (%.1f-%d; now %.1f). How long to wait between auction "
                .. "house searches. It also slows down by itself if the server says it's too fast.", MIN_GAP, MAX_GAP, SearchGap()))
        else
            AHWatchDB.searchGap, AHWatchDB.searchFloor = n, n
            Msg(string.format("one search every %.1fs from now on (it won't speed up past that by itself).", n))
        end
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
            if ns.ClearTypicalCache then ns.ClearTypicalCache() end
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
    "AUCTION_HOUSE_PURCHASE_COMPLETED",
    "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "UI_ERROR_MESSAGE", "CHAT_MSG_SYSTEM",
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
        autoBox:SetChecked(AHWatchDB.autoSearch ~= false)
        cycleBox:SetChecked(AHWatchDB.cycleList ~= false)
        twoBox:SetChecked(AHWatchDB.twoPerPress ~= false)
        return
    end
    if not AHWatchDB then return end

    if e == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        bgBroken, bgMisses, bgPending = false, 0, nil
        browsePending = false
        favBroken, favMisses, favPending, hot, hotOrder = false, 0, nil, {}, {}
        lastMoney = GetMoney()
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
        lastSource = "watch"
        dealOpen = {}   -- deals can't be watched while it's closed
        runtime = {}
        ApplyKey()
        f:Hide()

    elseif e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        if favPending and not browsePending then
            FavoritesResults()
            SearchAnswered()
            Update()
            return
        end
        -- Ignore results from the auction house's own search box
        if not browsePending then return end
        browsePending = false
        browse = {}
        local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
        browseOffset = 0
        for _, res in ipairs((ok and results) or {}) do
            if res.itemKey then
                table.insert(browse, {
                    itemID = res.itemKey.itemID, itemKey = res.itemKey, order = #browse + 1,
                    minPrice = res.minPrice, name = ItemName(res.itemKey.itemID),
                })
            end
        end
        if #browse == 0 then Msg("no results.") end
        Update()

    elseif e == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        local w = FindWatch(a1)
        local isManual = manualW and manualW.itemID == a1
        local forSell = ns.sellSearchID == a1
        if not w and not forSell and not isManual then return end
        if w then w.isCommodity = true end
        if isManual then manualW.isCommodity = true end
        local rows = {}
        for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(a1) or 0 do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(a1, i)
            if r and r.unitPrice and r.quantity then
                table.insert(rows, { unitPrice = r.unitPrice, quantity = r.quantity, own = r.containsOwnerItem })
            end
        end
        table.sort(rows, function(x, y) return x.unitPrice < y.unitPrice end)
        runtime[a1] = { rows = rows, time = GetTime() }
        SearchAnswered()
        if ns.RecordRows then ns.RecordRows(a1, rows, true) end
        if state == "searching" and (w or isManual) then state = "idle"; searchAuto = false end
        BgResults(a1)
        if forSell and ns.OnSellResults then ns.OnSellResults(a1, rows, true) end
        if w then TrackDeal(w) end
        if isManual and lastSource == "manual" then ManualQuote() elseif w then AutoQuote(w) end
        Update()

    elseif e == "ITEM_SEARCH_RESULTS_UPDATED" then
        local key = a1
        local w = key and FindWatch(key.itemID)
        local isManual = key and manualW and manualW.itemID == key.itemID
        local forSell = key and ns.sellSearchID == key.itemID
        if not w and not forSell and not isManual then return end
        if w then w.isCommodity = false end
        if isManual then manualW.isCommodity = false end
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
        SearchAnswered()
        if ns.RecordRows then ns.RecordRows(key.itemID, rows, false) end
        if state == "searching" and (w or isManual) then state = "idle"; searchAuto = false end
        BgResults(key.itemID)
        if forSell and ns.OnSellResults then ns.OnSellResults(key.itemID, rows, false) end
        if w then TrackDeal(w) end
        Update()

    elseif e == "COMMODITY_PRICE_UPDATED" then
        if state ~= "pricing" or not purchase then return end
        local unitPrice, total = a1, a2
        -- Safety check: the real price must still be within your max, your gold and your limit
        if total and total <= purchase.qty * purchase.max and total <= Budget() then
            purchase.total = total
            purchase.auto = false   -- the automatic part is done; from here it's a normal purchase
            SetState("confirm")
            Timeout("confirm", 15)
        else
            if not purchase.auto then
                Msg("price went up to " .. Money(unitPrice or 0) .. " each - not buying. Press again to refresh.")
            end
            pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            runtime[purchase.itemID] = nil
            -- The real price keeps coming back higher than the search showed: stop trying for a while
            BuyFailed(purchase.itemID, purchase.name, "its real price keeps coming back higher than listed", 3)
            purchase = nil
            SetState("idle")
        end

    elseif e == "COMMODITY_PRICE_UNAVAILABLE" then
        if purchase and not purchase.auto then DealLost(purchase.itemID) end
        if purchase then
            runtime[purchase.itemID] = nil
            BuyFailed(purchase.itemID, purchase.name, "its listings keep disappearing before they can be bought", 4)
            if not purchase.auto then Msg("those listings are gone - press again to refresh.") end
        end
        purchase = nil
        SetState("idle")

    elseif e == "COMMODITY_PURCHASE_SUCCEEDED" then
        -- (latePurchase: it timed out and we moved on, but it went through after all)
        local p, late = purchase or latePurchase, (purchase == nil)
        latePurchase = nil
        local w
        if p then
            spent = spent + (p.total or 0)
            w = p.w or FindWatch(p.itemID)
            if w then w.bought = (w.bought or 0) + p.qty end
            if ns.AddLedger then ns.AddLedger(p.itemID, p.name, p.qty, p.total or 0) end
            DealBought(p.itemID)
            BuyWorked(p.itemID)
            Msg("bought " .. p.qty .. "x " .. (p.name or "item") .. " for " .. Money(p.total or 0) .. ".")
            runtime[p.itemID] = nil
        end
        if late then
            if Update then Update() end
            return
        end
        purchase = nil
        SetState("idle")
        -- Search & buy: look again straight away, so the next press can buy more
        if p and p.manual and w and not (w.maxQty and (w.bought or 0) >= w.maxQty) and not LimitReached() and Ready() then
            Search(w, true)
            return
        end
        -- Refresh straight away if you still want more, so the next press is ready to buy
        if not (p and p.manual) and AutoSearchOn() then
            bgLast = 0   -- Watch all refreshes it straight away
        end

    elseif e == "COMMODITY_PURCHASE_FAILED" then
        latePurchase = nil
        if purchase then
            DealLost(purchase.itemID)
            runtime[purchase.itemID] = nil
            BuyFailed(purchase.itemID, purchase.name, "its purchases keep failing", 3)
        end
        Msg("purchase failed - press again to refresh.")
        purchase = nil
        SetState("idle")

    elseif e == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        if ahOpen then SlowDown() end

    elseif e == "UI_ERROR_MESSAGE" or e == "CHAT_MSG_SYSTEM" then
        -- (UI_ERROR_MESSAGE gives an error type then the text; chat gives the text)
        local text = (type(a2) == "string" and a2) or (type(a1) == "string" and a1) or ""
        if ahOpen and IsSlowDownMessage(text) then SlowDown() end

    elseif e == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
        -- The server confirmed an item buyout
        for i, p in ipairs(pendingBids) do
            if p.auctionID == a1 then ConfirmBid(i) break end
        end

    elseif e == "PLAYER_MONEY" then
        -- Gold going down by a buyout's price also confirms it (for clients
        -- without the event above). Several can land in one money update.
        local now = GetMoney()
        if lastMoney and now < lastMoney and #pendingBids > 0 and state ~= "buying" then
            local drop = lastMoney - now
            while drop > 0 and #pendingBids > 0 do
                local pick
                for i, p in ipairs(pendingBids) do
                    if p.price == drop then pick = i break end
                end
                if not pick then
                    for i, p in ipairs(pendingBids) do
                        if p.price <= drop then pick = i break end
                    end
                end
                if not pick then break end
                drop = drop - pendingBids[pick].price
                ConfirmBid(pick)
            end
        end
        lastMoney = now
        if f:IsShown() then Update() end

    elseif e == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if f:IsShown() then Update() end

    elseif e == "GET_ITEM_INFO_RECEIVED" then
        -- These come in bursts (dozens at once): redraw once when it settles
        if f:IsShown() and not itemInfoQueued then
            itemInfoQueued = true
            C_Timer.After(0.2, function()
                itemInfoQueued = false
                if f:IsShown() then Update() end
            end)
        end
    end
end)
