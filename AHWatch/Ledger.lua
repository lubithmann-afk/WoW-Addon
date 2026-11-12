-- AHWatch ledger
-- A record of everything bought through AH Watch: when, what, how many, and
-- what it cost. Opened with the Ledger button on the main window (or /ahw ledger).
-- Saved with your other AH Watch settings, newest 2000 purchases kept.

local _, ns = ...
local main = AHWatchFrame
local Money = ns.Money

local MAX_ENTRIES = 2000
local ROWS = 16
local ROW_H = 18

local function Entries()
    if type(AHWatchDB) ~= "table" then AHWatchDB = {} end
    AHWatchDB.ledger = AHWatchDB.ledger or {}
    return AHWatchDB.ledger
end

local Refresh

-- Called by AHWatch.lua once the server confirms a purchase
function ns.AddLedger(itemID, name, qty, total)
    if not itemID then return end
    local list = Entries()
    table.insert(list, {
        t = time(), id = itemID, n = name, q = qty or 1, c = math.floor(total or 0),
    })
    while #list > MAX_ENTRIES do table.remove(list, 1) end
    if Refresh then Refresh() end
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
lf:SetSize(360, 452)
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
local sumToday = Text("GameFontHighlightSmall", 14, -32, 332)
local sumWeek  = Text("GameFontHighlightSmall", 14, -47, 332)
local sumAll   = Text("GameFontHighlightSmall", 14, -62, 332)

-- Filter by name
Text("GameFontNormalSmall", 14, -84):SetText("Filter:")
local filterBox = CreateFrame("EditBox", nil, lf, "InputBoxTemplate")
filterBox:SetSize(150, 20)
filterBox:SetPoint("TOPLEFT", lf, "TOPLEFT", 58, -80)
filterBox:SetAutoFocus(false)
filterBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
filterBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
local filterNote = Text("GameFontDisableSmall", 216, -84, 130)

-- Column headings
local HY = -106
Text("GameFontNormalSmall", 14, HY, 76):SetText("When")
Text("GameFontNormalSmall", 92, HY, 140):SetText("Item")
Text("GameFontNormalSmall", 226, HY, 36, "RIGHT"):SetText("Qty")
Text("GameFontNormalSmall", 264, HY, 82, "RIGHT"):SetText("Paid")
local headLine = lf:CreateTexture(nil, "ARTWORK")
headLine:SetColorTexture(1, 1, 1, 0.15)
headLine:SetHeight(1)
headLine:SetPoint("TOPLEFT", lf, "TOPLEFT", 12, HY - 14)
headLine:SetPoint("TOPRIGHT", lf, "TOPRIGHT", -12, HY - 14)

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
    b.qty:SetPoint("LEFT", 214, 0)
    b.qty:SetWidth(36)
    b.qty:SetJustifyH("RIGHT")
    b.paid = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.paid:SetPoint("RIGHT", -2, 0)
    b.paid:SetJustifyH("RIGHT")
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
        GameTooltip:SetItemByID(e.id)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Bought:", date("%a %b %d, %H:%M", e.t), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Amount:", tostring(e.q), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Each:", Money(e.c / math.max(e.q, 1)), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Total:", Money(e.c), 1, 1, 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Shift-click puts the item link in chat, like anywhere else in the game
    b:SetScript("OnClick", function(self)
        if self.entry and IsModifiedClick and IsModifiedClick("CHATLINK") then
            local _, link = GetItemInfo(self.entry.id)
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
local shown = {}   -- entries matching the filter, newest first

local function NameOf(e)
    if not e.n then
        local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(e.id)
        if n then e.n = n end
    end
    return e.n or ("Item " .. e.id)
end

local function IconOf(id)
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
    if not icon and GetItemIcon then icon = GetItemIcon(id) end
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function Total(label, sum, count)
    return label .. Money(sum) .. "  |cffaaaaaa(" .. count .. " purchase" .. (count == 1 and "" or "s") .. ")|r"
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

    local tSum, tN, wSum, wN, aSum, aN = 0, 0, 0, 0, 0, 0
    shown = {}
    for i = #list, 1, -1 do
        local e = list[i]
        if q == "" or NameOf(e):lower():find(q, 1, true) then
            table.insert(shown, e)
            aSum, aN = aSum + e.c, aN + 1
            if e.t >= weekStart then wSum, wN = wSum + e.c, wN + 1 end
            if e.t >= todayStart then tSum, tN = tSum + e.c, tN + 1 end
        end
    end
    sumToday:SetText(Total("Today:  ", tSum, tN))
    sumWeek:SetText(Total("Last 7 days:  ", wSum, wN))
    sumAll:SetText(Total("All saved:  ", aSum, aN))
    filterNote:SetText(q ~= "" and "(totals for this filter)" or "")

    offset = math.max(0, math.min(offset, #shown - ROWS))
    for i, b in ipairs(rows) do
        local e = shown[offset + i]
        if e then
            b.entry = e
            b.when:SetText(date("%b %d %H:%M", e.t))
            b.icon:SetTexture(IconOf(e.id))
            b.name:SetText(NameOf(e))
            b.qty:SetText(e.q > 1 and (e.q .. "x") or "1")
            b.paid:SetText(Money(e.c))
            b:Show()
        else
            b.entry = nil
            b:Hide()
        end
    end
    if #list == 0 then
        emptyText:SetText("Nothing bought yet.\nPurchases made with AH Watch show up here.")
    elseif #shown == 0 then
        emptyText:SetText("No purchases match that filter.")
    else
        emptyText:SetText("")
    end
    scrollText:SetText(#shown > ROWS and string.format("Showing %d-%d of %d (scroll for more)",
        offset + 1, math.min(offset + ROWS, #shown), #shown) or "")
    clearBtn:SetEnabled(#list > 0)
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
    text = "Clear AH Watch's whole purchase history? This can't be undone.",
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
