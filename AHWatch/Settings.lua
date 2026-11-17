-- AHWatch settings window and guided tour
-- Settings: the two buy keys, the look, buying options, search pace, and a
-- "Show me around" tour that walks through the whole window step by step.
-- Opened with the Settings button (bottom right of the AH Watch window),
-- /ahw settings, or /ahw tour for the tour on its own.

local _, ns = ...
local ui = ns.ui or {}
local main = AHWatchFrame
local function Msg(text) if ns.Msg then ns.Msg(text) else print("|cff33ccffAHWatch:|r " .. text) end end

------------------------------------------------------------
-- Settings window (opens to the left, where the Ledger opens)
------------------------------------------------------------

local ok, sf = pcall(CreateFrame, "Frame", "AHWatchSettingsFrame", main, "BasicFrameTemplateWithInset")
if not ok or not sf then
    sf = CreateFrame("Frame", "AHWatchSettingsFrame", main)
    local bg = sf:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)
end
sf:SetSize(300, 470)
sf:SetPoint("TOPRIGHT", main, "TOPLEFT", -2, 0)
sf:EnableMouse(true)
sf:Hide()
if sf.TitleText then sf.TitleText:SetText("Settings") end

local function Heading(text, y)
    local fs = sf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", sf, "TOPLEFT", 14, y)
    fs:SetText(text)
    local line = sf:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", sf, "TOPLEFT", 12, y - 15)
    line:SetPoint("TOPRIGHT", sf, "TOPRIGHT", -12, y - 15)
    return fs
end

local function Note(text, x, y, width)
    local fs = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", sf, "TOPLEFT", x, y)
    fs:SetWidth(width or 270)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- Moves one of the main window's controls in here
local function Place(widget, x, y, w, h)
    if not widget then return end
    widget:SetParent(sf)
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", sf, "TOPLEFT", x, y)
    if w then widget:SetSize(w, h or 20) end
    local fs = widget.GetFontString and widget:GetFontString()
    if fs and w then fs:SetWidth(w - 14); fs:SetWordWrap(false) end
    widget:Show()
end

-- A checkbox's own label, moved to sit right of the box
local function LabelRight(box, text)
    for _, r in ipairs({ box:GetRegions() }) do
        if r:GetObjectType() == "FontString" and r:GetText() == text then
            r:ClearAllPoints()
            r:SetPoint("LEFT", box, "RIGHT", 2, 0)
        end
    end
end

-- Keys
Heading("Keys", -30)
Note("|cffaaaaaaLeft-click, then press a key, scroll the mouse wheel or click a side mouse button. "
    .. "Right-click puts it back. Keys only work while the auction house is open.|r", 16, -50)
Note("Buy instantly:", 16, -84, 130)
Place(ui.manualKeyBtn, 150, -79, 134, 22)
Note("Big button (search & buy):", 16, -112, 130)
Place(ui.bindBtn, 150, -107, 134, 22)

-- Look
Heading("Look", -142)
Note("Colours and style of AH Watch:", 16, -166, 130)
Place(ui.themeBtn, 150, -161, 134, 22)

-- Buying
Heading("Buying", -196)
local function Check(y, text, tip, get, set)
    local box = CreateFrame("CheckButton", nil, sf, "UICheckButtonTemplate")
    box:SetSize(20, 20)
    box:SetPoint("TOPLEFT", sf, "TOPLEFT", 14, y)
    local fs = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", box, "RIGHT", 2, 0)
    fs:SetText(text)
    box:SetScript("OnClick", function(self)
        if type(AHWatchDB) ~= "table" then return end
        set(self:GetChecked() and true or false)
    end)
    box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text, 1, 1, 1)
        GameTooltip:AddLine(tip, 1, 0.9, 0.6, true)
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    box.get = get
    return box
end
-- (2 per press and Cycle list move here from the Buy tab, with their own tooltips)
if ui.twoBox then
    Place(ui.twoBox, 14, -216)
    ui.twoBox:SetSize(20, 20)
    LabelRight(ui.twoBox, "2 per press")
end
if ui.cycleBox then
    Place(ui.cycleBox, 14, -240)
    ui.cycleBox:SetSize(20, 20)
    LabelRight(ui.cycleBox, "Cycle list")
end
local alertBox = Check(-264, "Deal alert (sound + flashing button)",
    "When Watch all finds something at your price, play a sound and flash the Buy instantly button until it's bought or gone.",
    function() return AHWatchDB.dealAlert ~= false end,
    function(on) AHWatchDB.dealAlert = on end)
local followBox = Check(-288, "Follow-up after a buy",
    "After you buy something, keep a close eye on that item for a minute - sellers often undercut each other in waves right after.",
    function() return AHWatchDB.followup ~= 0 end,
    function(on) AHWatchDB.followup = (not on) and 0 or nil end)

-- Search pace
Heading("Search pace", -318)
local paceText = Note("", 16, -340, 190)
local paceBtn = CreateFrame("Button", nil, sf, "UIPanelButtonTemplate")
paceBtn:SetSize(80, 20)
paceBtn:SetPoint("TOPRIGHT", sf, "TOPRIGHT", -14, -336)
paceBtn:SetText("Reset")
paceBtn:SetNormalFontObject(GameFontNormalSmall)
paceBtn:SetHighlightFontObject(GameFontHighlightSmall)
paceBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Reset search pace")
    GameTooltip:AddLine("Forget the learned pace and start again from one search every 1.5s. It slows down by itself "
        .. "if the server says it's too fast, and speeds up again when it's fine.", 1, 1, 1, true)
    GameTooltip:Show()
end)
paceBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- Help
Heading("Help", -372)
local tourBtn = CreateFrame("Button", nil, sf, "UIPanelButtonTemplate")
tourBtn:SetSize(272, 26)
tourBtn:SetPoint("TOPLEFT", sf, "TOPLEFT", 14, -394)
tourBtn:SetText("Show me around (tutorial)")
tourBtn.pbPrimary = true
Note("|cffaaaaaaAlso: /ahw tour, /ahw ledger, /ahw stats (what it has learned), /ahw settings|r", 16, -428)

local function RefreshSettings()
    if not sf:IsShown() or type(AHWatchDB) ~= "table" then return end
    alertBox:SetChecked(alertBox.get())
    followBox:SetChecked(followBox.get())
    if ui.twoBox then ui.twoBox:SetChecked(AHWatchDB.twoPerPress ~= false) end
    if ui.cycleBox then ui.cycleBox:SetChecked(AHWatchDB.cycleList ~= false) end
    local gap = AHWatchDB.searchGap or 1.5
    paceText:SetText(string.format("One search every %.1fs |cffaaaaaa(learned from the server)|r", gap))
end
sf:SetScript("OnShow", RefreshSettings)
paceBtn:SetScript("OnClick", function()
    if type(AHWatchDB) ~= "table" then return end
    AHWatchDB.searchGap, AHWatchDB.searchFloor, AHWatchDB.searchFloorManual = nil, nil, nil
    Msg("search pace reset - one search every 1.5s, adjusting by itself from here.")
    RefreshSettings()
end)

-- Settings and the Ledger open in the same spot: one at a time
function ns.ToggleSettings()
    if not main:IsShown() then main:Show() end
    if sf:IsShown() then sf:Hide() return end
    if _G.AHWatchLedgerFrame then _G.AHWatchLedgerFrame:Hide() end
    sf:Show()
end
if _G.AHWatchLedgerFrame then
    _G.AHWatchLedgerFrame:HookScript("OnShow", function() sf:Hide() end)
end

-- The Settings button: bottom right of the main window, where the key and
-- Look buttons used to be
local settingsBtn = CreateFrame("Button", "AHWatchSettingsButton", main, "UIPanelButtonTemplate")
settingsBtn:SetSize(108, 20)
settingsBtn:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -30, 10)
settingsBtn:SetText("Settings")
settingsBtn:SetNormalFontObject(GameFontNormalSmall)
settingsBtn:SetHighlightFontObject(GameFontHighlightSmall)
settingsBtn:SetScript("OnClick", function() ns.ToggleSettings() end)
settingsBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Settings")
    GameTooltip:AddLine("Your keys, the look, buying options - and a tutorial.", 1, 1, 1, true)
    GameTooltip:Show()
end)
settingsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
ns.ui.settingsBtn = settingsBtn

------------------------------------------------------------
-- Guided tour: highlights one part of the window at a time, with a short
-- explanation and Back / Next. Parented to the main window so it lines up
-- at any UI scale.
------------------------------------------------------------

local tour = CreateFrame("Frame", nil, main)
tour:SetAllPoints(main)
tour:SetFrameStrata("FULLSCREEN_DIALOG")
tour:Hide()

local hl = CreateFrame("Frame", nil, tour)
hl:SetFrameStrata("FULLSCREEN_DIALOG")
do
    local fill = hl:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    fill:SetColorTexture(1, 0.82, 0, 0.12)
    for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
        local t = hl:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 0.82, 0, 0.95)
        t:SetPoint(side[1], hl, side[1])
        t:SetPoint(side[2], hl, side[2])
        if side[3] then t:SetHeight(2) else t:SetWidth(2) end
    end
end

local bubble = CreateFrame("Frame", nil, tour)
bubble:SetFrameStrata("FULLSCREEN_DIALOG")
bubble:SetFrameLevel(hl:GetFrameLevel() + 5)
bubble:SetSize(300, 150)
bubble:SetClampedToScreen(true)
bubble:EnableMouse(true)
do
    local bg = bubble:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.05, 0.04, 0.97)
    for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
                            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
        local t = bubble:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 0.82, 0, 0.8)
        t:SetPoint(side[1], bubble, side[1])
        t:SetPoint(side[2], bubble, side[2])
        if side[3] then t:SetHeight(1) else t:SetWidth(1) end
    end
end
local bTitle = bubble:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bTitle:SetPoint("TOPLEFT", 12, -10)
bTitle:SetPoint("TOPRIGHT", -12, -10)
bTitle:SetJustifyH("LEFT")
local bText = bubble:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
bText:SetPoint("TOPLEFT", bTitle, "BOTTOMLEFT", 0, -6)
bText:SetWidth(276)
bText:SetJustifyH("LEFT")
bText:SetSpacing(2)
local bStep = bubble:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
bStep:SetPoint("BOTTOMLEFT", 12, 10)

local function TourButton(text, x)
    local b = CreateFrame("Button", nil, bubble, "UIPanelButtonTemplate")
    b:SetSize(62, 20)
    b:SetPoint("BOTTOMRIGHT", bubble, "BOTTOMRIGHT", x, 8)
    b:SetText(text)
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    return b
end
local nextBtn = TourButton("Next", -10)
local backBtn = TourButton("Back", -76)
local closeBtn = TourButton("Close", -142)

-- Each step: a title, what to say, and what to highlight - a frame, or a
-- rectangle of the main window (x1, y1, x2, y2 from its top-left corner)
local STEPS = {
    { title = "Welcome to AH Watch",
      text = "AH Watch buys the items you want at or under a price you set - faster than doing it by hand. "
          .. "This tour shows you each part of the window. Press Next to go on, or Close any time.",
      rect = { 8, -24, 352, -296 }, below = true },
    { title = "1. Find an item",
      text = "Type an item's name and press Search (or shift-click an item in your bags or chat). "
          .. "Click a result to pick it. The exact name is listed first; scroll for more.",
      rect = { 8, -26, 352, -182 } },
    { title = "2. Set your max price",
      text = "The most you'll pay each. Three ways:\n- a gold amount,\n- a % of the market price, or\n"
          .. "- a % profit (margin mode): the max follows where real supply starts right now, so it never goes stale.\n"
          .. "\"Buy up to\" limits how many you want (0 = any). Then press Add to list.",
      rect = { 8, -192, 352, -294 } },
    { title = "3. Your watch list",
      text = "Up to 20 items (7 show - scroll for more). Each row shows its max, what's listed under it, "
          .. "and how long since it was checked. Click an item to select it; X removes it; the star saves it to favorites.",
      rect = { 8, -296, 352, -530 } },
    { title = "4. Watch all",
      text = "Keep this ticked. While the Buy tab is open, AH Watch checks your whole list in the background as fast "
          .. "as the server allows - so your presses go to buying, not searching.",
      frame = function() return ui.autoBox end, pad = 4, padRight = 52 },
    { title = "5. Buy instantly",
      text = "Your fastest button: press its key over and over. Each press buys whatever on your list is at or under "
          .. "its max right now. When something's ready, a sound plays and this button flashes.\n"
          .. "Tip: put it on the mouse wheel (Settings) - every scroll notch is a press.",
      frame = function() return ui.manualBtn end, above = true },
    { title = "6. The big button",
      text = "Works on the item you selected: one press searches it, the next press buys. "
          .. "With Cycle list on (Settings) it moves to the next item when nothing's at your price.",
      frame = function() return ui.goBtn end, above = true },
    { title = "7. Spend limit",
      text = "Buying stops once you've spent this much. \"Spent\" counts up as you buy; Reset spent starts again.",
      rect = { 8, -530, 352, -602 }, above = true },
    { title = "8. The tabs",
      text = "Buy - this page.  Sell - what's in your bags: auction house or vendor, and a suggested price.  "
          .. "Quick Sell - post the same item again with each press.  Deals - cheap listings worth flipping "
          .. "(Watch adds them to your list).  Mine - your auctions, undercut ones first.",
      rect = { 84, -1, 336, -24 } },
    { title = "9. Price history",
      text = "The selected item's prices over time, and price-gap deals. X hides this panel; "
          .. "the Prices > button (top left) brings it back.",
      frame = function()
          if ns.SetGraphShown then ns.SetGraphShown(true) end
          return _G.AHWatchGraphFrame
      end },
    { title = "10. Ledger",
      text = "What you've spent and earned - today, this week, all time - and your profit per item.",
      frame = function() return ui.ledgerBtn end, above = true, pad = 3 },
    { title = "11. Settings",
      text = "Your two keys (keyboard, mouse wheel or side buttons), the look, and buying options. "
          .. "You can replay this tour from here any time. Happy hunting!",
      frame = function() return ui.settingsBtn end, above = true, pad = 3 },
}

local step = 1

local function ShowStep()
    local s = STEPS[step]
    hl:ClearAllPoints()
    local target = s.frame and s.frame()
    local lowHalf
    if target and target:IsShown() then
        local p = s.pad or 4
        hl:SetPoint("TOPLEFT", target, "TOPLEFT", -p, p)
        hl:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", p + (s.padRight or 0), -p)
    else
        local r = s.rect or { 8, -24, 352, -296 }
        hl:SetPoint("TOPLEFT", main, "TOPLEFT", r[1], r[2])
        hl:SetPoint("BOTTOMRIGHT", main, "TOPLEFT", r[3], r[4])
        lowHalf = r[2] < -400
    end
    if s.above == nil and lowHalf then s.above = true end
    bubble:ClearAllPoints()
    if s.above then
        bubble:SetPoint("BOTTOM", hl, "TOP", 0, 8)
    else
        bubble:SetPoint("TOP", hl, "BOTTOM", 0, -8)
    end
    bTitle:SetText(s.title)
    bText:SetText(s.text)
    bubble:SetHeight(math.max(110, (bText:GetStringHeight() or 60) + 70))
    bStep:SetText(step .. " / " .. #STEPS)
    backBtn:SetEnabled(step > 1)
    nextBtn:SetText(step == #STEPS and "Done" or "Next")
end

function ns.StartTour()
    if not main:IsShown() then main:Show() end
    sf:Hide()
    if _G.AHWatchLedgerFrame then _G.AHWatchLedgerFrame:Hide() end
    if ns.SetTab then ns.SetTab("buy") end
    if type(AHWatchDB) == "table" then AHWatchDB.tourOffered = true end
    step = 1
    tour:Show()
    ShowStep()
end

nextBtn:SetScript("OnClick", function()
    if step >= #STEPS then
        tour:Hide()
        Msg("tour finished - replay it any time from Settings, or with /ahw tour.")
        return
    end
    step = step + 1
    ShowStep()
end)
backBtn:SetScript("OnClick", function()
    if step > 1 then step = step - 1; ShowStep() end
end)
closeBtn:SetScript("OnClick", function() tour:Hide() end)
tourBtn:SetScript("OnClick", function() ns.StartTour() end)
-- The tour goes away with the window
main:HookScript("OnHide", function() tour:Hide() end)
