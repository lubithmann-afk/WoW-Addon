-- AHWatch "Mine" tab: your own auctions, undercut ones first
-- Lists what you have on the auction house, checks the current lowest price
-- of each item (paced like every other search), and marks the listings
-- someone has undercut. Each press of your main key (or a row's Cancel
-- button) cancels the next undercut listing. Cancelled items come back by
-- mail; the tooltip suggests a relist price that never goes below what you
-- paid (break-even, from the ledger).

local _, ns = ...
local f = AHWatchFrame
local Money, Msg = ns.Money, ns.Msg

local ROWS, ROW_H = 24, 22
local CHECK_FRESH = 60        -- seconds before an item's lowest price is checked again
local STATUS_SOLD = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold) or 1

local auctions = {}           -- your listings, sorted for display
local offset = 0
local checking = nil          -- itemID being price-checked right now
local checkSentAt = 0
local queried = 0             -- GetTime() of the last owned-auctions query
local cancelSent = {}         -- auctionID -> GetTime(), so one press = one cancel

local function S(c) return (ns.ShortMoney and ns.ShortMoney(c)) or Money(c) end

------------------------------------------------------------
-- Panel
------------------------------------------------------------

local panel = CreateFrame("Frame", "AHWatchMinePanel", f)
panel:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -26)
panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 34)
panel:SetFrameLevel(f:GetFrameLevel() + 40)
panel:EnableMouse(true)
panel:Hide()
do
    local base = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
    base:SetAllPoints()
    base:SetColorTexture(0, 0, 0, 1)
    local bg = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints()
    if ns.panelBgs then table.insert(ns.panelBgs, bg) end
    if ns.SkinSellPanel and ns.lastSkin then ns.SkinSellPanel(ns.lastSkin[1], ns.lastSkin[2]) end
end

local function Text(font, x, y, width, justify)
    local fs = panel:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

Text("GameFontNormalSmall", 8, -6, 250):SetText("Your auctions - undercut ones first:")
local info = Text("GameFontDisableSmall", 8, -22, 250)
local refreshBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
refreshBtn:SetSize(70, 18)
refreshBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -10)
refreshBtn:SetText("Refresh")
refreshBtn:SetNormalFontObject(GameFontNormalSmall)
refreshBtn:SetHighlightFontObject(GameFontHighlightSmall)

local MH = -44
Text("GameFontNormalSmall", 26, MH, 110):SetText("Item")
Text("GameFontNormalSmall", 140, MH, 58, "RIGHT"):SetText("Yours")
Text("GameFontNormalSmall", 202, MH, 70, "RIGHT"):SetText("Lowest")

local rows = {}
local emptyText = Text("GameFontDisable", 12, MH - 40, 320)
emptyText:SetWordWrap(true)
local scrollText = Text("GameFontDisableSmall", 8, MH - 20 - ROWS * ROW_H, 330)

------------------------------------------------------------
-- Data
------------------------------------------------------------

local function IsCommodity(a)
    if C_AuctionHouse.GetItemKeyInfo and a.itemKey then
        local ok, ki = pcall(C_AuctionHouse.GetItemKeyInfo, a.itemKey)
        if ok and type(ki) == "table" and ki.isCommodity ~= nil then return ki.isCommodity end
    end
    local maxStack = C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(a.itemID)
    return (maxStack or 1) > 1
end

-- Lowest price someone else is asking, from the latest check (nil = not checked yet)
local function Lowest(itemID)
    local lv = ns.liveLow and ns.liveLow[itemID]
    if lv and time() - lv.time < CHECK_FRESH * 3 then return lv.low, lv end
end

-- Status of one listing: "sold", "checking", "lowest", or "undercut" (+ by how much)
local function Status(a)
    if a.status == STATUS_SOLD then return "sold" end
    local low, lv = Lowest(a.itemID)
    if not lv then return "checking" end
    if not low or a.unit <= low then return "lowest" end
    return "undercut", a.unit - low
end

-- Price to relist at: 1c under the lowest, but never below break-even
local function RelistPrice(a)
    local low = Lowest(a.itemID)
    local be
    if ns.CostBasis then be = select(3, ns.CostBasis(a.itemID, a.qty)) end
    local price = low and math.max(1, low - 1) or a.unit
    if be and price < be then return be, true end
    return price, false
end

local function ReadOwned()
    auctions = {}
    local n = (C_AuctionHouse.GetNumOwnedAuctions and C_AuctionHouse.GetNumOwnedAuctions()) or 0
    for i = 1, n do
        local ok, a = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
        if ok and type(a) == "table" and a.itemKey and a.itemKey.itemID then
            local e = {
                auctionID = a.auctionID, itemKey = a.itemKey, itemID = a.itemKey.itemID, link = a.itemLink,
                qty = a.quantity or 1, status = a.status, timeLeft = a.timeLeftSeconds,
            }
            local buyout = a.buyoutAmount or a.bidAmount or 0
            -- Commodity listings report the price each; other items the whole stack
            e.unit = IsCommodity(e) and buyout or math.floor(buyout / math.max(e.qty, 1))
            e.name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.itemID))
                or (e.link and e.link:match("%[(.-)%]")) or ("Item " .. e.itemID)
            if not (cancelSent[e.auctionID] and GetTime() - cancelSent[e.auctionID] < 10) then
                auctions[#auctions + 1] = e
            end
        end
    end
end

local ORDER = { undercut = 1, checking = 2, lowest = 3, sold = 4 }
local function SortAuctions()
    for _, a in ipairs(auctions) do a.st, a.by = Status(a) end
    table.sort(auctions, function(x, y)
        if ORDER[x.st] ~= ORDER[y.st] then return ORDER[x.st] < ORDER[y.st] end
        if x.st == "undercut" then return (x.by / math.max(x.unit, 1)) > (y.by / math.max(y.unit, 1)) end
        return (x.name or "") < (y.name or "")
    end)
end

local function NextUndercut()
    for _, a in ipairs(auctions) do
        if a.st == "undercut" then return a end
    end
end

local function Query()
    if not (ns.IsAHOpen and ns.IsAHOpen()) or not C_AuctionHouse.QueryOwnedAuctions then return end
    queried = GetTime()
    local sorts = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Name) or 1, reverseSort = false } }
    local ok = pcall(C_AuctionHouse.QueryOwnedAuctions, sorts)
    if not ok then pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
end

------------------------------------------------------------
-- Drawing
------------------------------------------------------------

local Refresh

local function SetGoLabel(label)
    if ns.CurrentTab and ns.CurrentTab() == "mine" and _G.AHWatchGoButton then
        local key = (ns.GetKey and ns.GetKey()) or ""
        if ns.KeyName then key = ns.KeyName(key) end
        _G.AHWatchGoButton:SetText(label .. "  |cff888888(" .. key .. ")|r")
    end
end

local function CancelOne(a)
    if not a or not (ns.IsAHOpen and ns.IsAHOpen()) then return end
    if ns.Ready and not ns.Ready() then return end
    if C_AuctionHouse.CanCancelAuction then
        local ok, can = pcall(C_AuctionHouse.CanCancelAuction, a.auctionID)
        if ok and can == false then Msg("the game won't let you cancel that one (it may have just sold).") return end
    end
    local ok, err = pcall(C_AuctionHouse.CancelAuction, a.auctionID)
    if not ok then Msg("couldn't cancel: " .. tostring(err)) return end
    cancelSent[a.auctionID] = GetTime()
    local price, atBE = RelistPrice(a)
    Msg(string.format("cancelling %dx %s. It comes back by mail - relist it from Quick Sell at %s%s.",
        a.qty, a.name or "item", Money(price), atBE and " (your break-even - the lowest is under what you paid)" or ""))
    for i, x in ipairs(auctions) do if x == a then table.remove(auctions, i) break end end
    Refresh()
end

-- Your main key on this tab: cancel the next undercut listing
function ns.MineGo()
    local a = NextUndercut()
    if not a then
        Msg("none of your listings are undercut right now.")
        return
    end
    CancelOne(a)
end

for i = 1, ROWS do
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(340, ROW_H - 1)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, MH - 16 - (i - 1) * ROW_H)
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
    b.name:SetWidth(112)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.mine = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.mine:SetPoint("LEFT", 136, 0)
    b.mine:SetWidth(58)
    b.mine:SetJustifyH("RIGHT")
    b.low = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.low:SetPoint("LEFT", 198, 0)
    b.low:SetWidth(90)
    b.low:SetJustifyH("RIGHT")
    b.low:SetWordWrap(false)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.cancel = CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
    b.cancel:SetSize(46, 16)
    b.cancel:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b.cancel:SetText("Cancel")
    b.cancel:SetNormalFontObject(GameFontHighlightSmall)
    b.cancel:SetHighlightFontObject(GameFontHighlightSmall)
    b.cancel:SetScript("OnClick", function() if b.auction then CancelOne(b.auction) end end)
    b:SetScript("OnClick", function(self)
        local a = self.auction
        if not a then return end
        if IsShiftKeyDown() and ns.SearchInAH then ns.SearchInAH(a.itemID, a.name) return end
        if ns.ShowGraph then ns.ShowGraph(a.itemID, nil) end
    end)
    b:SetScript("OnEnter", function(self)
        local a = self.auction
        if not a then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if a.link then GameTooltip:SetHyperlink(a.link) else GameTooltip:SetItemByID(a.itemID) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Your listing:", a.qty .. " at " .. Money(a.unit) .. " each", 1, 1, 1, 1, 1, 1)
        local low = Lowest(a.itemID)
        if a.st == "undercut" then
            GameTooltip:AddDoubleLine("Lowest other:", Money(low) .. " (" .. Money(a.by) .. " under you)", 1, 1, 1, 1, 0.4, 0.4)
        elseif a.st == "lowest" then
            GameTooltip:AddDoubleLine("Lowest other:", low and Money(low) or "nobody else", 1, 1, 1, 0.4, 1, 0.4)
        end
        local paid, known, be
        if ns.CostBasis then paid, known, be = ns.CostBasis(a.itemID, a.qty) end
        if paid then GameTooltip:AddDoubleLine("You paid:", Money(paid) .. " each - break-even " .. Money(be), 1, 1, 1, 1, 1, 1) end
        if a.st == "undercut" then
            local price, atBE = RelistPrice(a)
            GameTooltip:AddDoubleLine("Relist at:", Money(price) .. (atBE and " (break-even)" or ""), 1, 1, 1, 1, 0.82, 0)
        end
        if a.timeLeft then
            GameTooltip:AddDoubleLine("Time left:", string.format("%.1f hr", a.timeLeft / 3600), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
        end
        GameTooltip:AddLine("Cancel: the items come back by mail. Shift-click: search it in the auction house.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:Hide()
    rows[i] = b
end

function Refresh()
    if not panel:IsShown() then return end
    SortAuctions()
    offset = math.max(0, math.min(offset, #auctions - ROWS))
    local undercut, active = 0, 0
    for _, a in ipairs(auctions) do
        if a.st == "undercut" then undercut = undercut + 1 end
        if a.st ~= "sold" then active = active + 1 end
    end
    for i, b in ipairs(rows) do
        local a = auctions[offset + i]
        if a then
            b.auction = a
            b.icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(a.itemID)) or "Interface\\Icons\\INV_Misc_QuestionMark")
            b.name:SetText((a.name or "?") .. (a.qty > 1 and (" |cffaaaaaax" .. a.qty .. "|r") or ""))
            b.mine:SetText(S(a.unit))
            local low = Lowest(a.itemID)
            if a.st == "undercut" then
                b.low:SetText("|cffff5555" .. S(low) .. " -" .. S(a.by) .. "|r")
            elseif a.st == "lowest" then
                b.low:SetText("|cff33dd66" .. (low and S(low) or "only you") .. "|r")
            elseif a.st == "sold" then
                b.low:SetText("|cff888888sold|r")
            else
                b.low:SetText("|cff888888checking...|r")
            end
            b.cancel:SetShown(a.st ~= "sold")
            b:Show()
        else
            b.auction = nil
            b:Hide()
        end
    end
    if #auctions == 0 then
        emptyText:SetText((ns.IsAHOpen and ns.IsAHOpen()) and "You have nothing listed right now."
            or "Open the auction house to see your listings.")
    else
        emptyText:SetText("")
    end
    info:SetText(string.format("%d listed  -  %s%s", active,
        undercut > 0 and ("|cffff5555" .. undercut .. " undercut|r") or "|cff33dd66none undercut|r",
        checking and "  -  checking prices..." or ""))
    scrollText:SetText(#auctions > ROWS and string.format("Showing %d-%d of %d (scroll for more)",
        offset + 1, math.min(offset + ROWS, #auctions), #auctions) or "")
    local nxt = NextUndercut()
    SetGoLabel(nxt and ("Cancel undercut: " .. (nxt.name or "item") .. " x" .. nxt.qty) or "Nothing undercut")
end

-- Called by Sell.lua when a price check comes back
function ns.OnMineResults(itemID)
    if checking == itemID then checking = nil end
    if panel:IsShown() then Refresh() end
end

-- Checks one item's lowest price at a time, oldest first, at the addon's search pace
local function CheckNext()
    if not panel:IsShown() or not (ns.IsAHOpen and ns.IsAHOpen()) then return end
    if checking and GetTime() - checkSentAt < 6 then return end
    checking = nil
    if ns.Ready and not ns.Ready() then return end
    if ns.CanSearch and not ns.CanSearch() then return end
    local pick, oldest
    for _, a in ipairs(auctions) do
        if a.status ~= STATUS_SOLD then
            local lv = ns.liveLow and ns.liveLow[a.itemID]
            local age = lv and (time() - lv.time) or math.huge
            if age > CHECK_FRESH and (not oldest or age > oldest) then pick, oldest = a, age end
        end
    end
    if not pick then return end
    if ns.NoteSearch then ns.NoteSearch() end
    ns.sellSearchID = pick.itemID
    checking, checkSentAt = pick.itemID, GetTime()
    local sorts = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } }
    local ok = pcall(C_AuctionHouse.SendSearchQuery, pick.itemKey or C_AuctionHouse.MakeItemKey(pick.itemID), sorts, false)
    if not ok then checking = nil end
    Refresh()
end

C_Timer.NewTicker(0.5, function()
    if not panel:IsShown() then return end
    if GetTime() - queried > 30 then Query() end
    CheckNext()
end)

function ns.SetMineShown(show)
    panel:SetShown(show)
    if show then
        offset = 0
        Query()
        Refresh()
    end
end

panel:EnableMouseWheel(true)
panel:SetScript("OnMouseWheel", function(_, delta)
    local step = IsShiftKeyDown() and ROWS or 3
    offset = math.max(0, math.min(math.max(0, #auctions - ROWS), offset - delta * step))
    Refresh()
end)
refreshBtn:SetScript("OnClick", function()
    -- Re-check every item's price, then re-read your listings
    if ns.liveLow then for _, a in ipairs(auctions) do ns.liveLow[a.itemID] = nil end end
    Query()
    Refresh()
end)

local ev = CreateFrame("Frame")
for _, e in ipairs({ "OWNED_AUCTIONS_UPDATED", "AUCTION_CANCELED", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_CLOSED" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e)
    if e == "OWNED_AUCTIONS_UPDATED" then
        ReadOwned()
        Refresh()
    elseif e == "AUCTION_CANCELED" then
        Msg("cancelled.")
        Query()
    elseif e == "AUCTION_HOUSE_AUCTION_CREATED" then
        if panel:IsShown() then Query() end
    elseif e == "AUCTION_HOUSE_CLOSED" then
        checking = nil
    end
end)
