-- AHWatch looks
-- "Classic" is the normal WoW window style. "Auction" recolors the same
-- layout to match the game's own Auction House window: a near-black panel,
-- a thin gold border, and red pill buttons for the main actions. "Trader" is
-- a flat, dark look in the style of trading apps like Fidelity. Switching is
-- instant and nothing else about the addon changes.

local _, ns = ...

local PALETTES = {
    -- Note: "classic" mode doesn't use a palette entry at all - it leaves
    -- the window/buttons as the game's own native, untouched art (see
    -- skinned() below), which is what gives it real 3D shading.
    trader = {
        bg        = { 0.067, 0.075, 0.086, 0.97 },
        header    = { 0.10, 0.11, 0.125, 1 },
        border    = { 0.22, 0.24, 0.27, 1 },
        accent    = { 0.0, 0.72, 0.33, 1 },
        btn       = { 0.17, 0.185, 0.21, 1 },
        btnHover  = { 0.24, 0.26, 0.29, 1 },
        primary   = { 0.05, 0.55, 0.25, 1 },
        primaryHi = { 0.07, 0.65, 0.30, 1 },
        danger    = { 0.60, 0.15, 0.15, 1 },
        dangerHi  = { 0.72, 0.20, 0.20, 1 },
        input     = { 0.11, 0.12, 0.14, 1 },
        label     = { 0.78, 0.80, 0.84 },
        title     = { 0.95, 0.96, 0.97 },
    },
    -- Matches the Auction House's own Browse/Sell window: warm parchment-
    -- brown panel (not black - the real window is a warm tan/brown, only
    -- its title bar and inset boxes go near-black), thin gold-bronze
    -- border, red primary buttons with gold text.
    auction = {
        bg        = { 0.19, 0.16, 0.125, 0.97 },
        header    = { 0.05, 0.045, 0.035, 1 },
        border    = { 0.55, 0.42, 0.16, 1 },
        accent    = { 0.75, 0.58, 0.20, 1 },
        btn       = { 0.27, 0.225, 0.16, 1 },
        btnHover  = { 0.35, 0.29, 0.20, 1 },
        primary   = { 0.50, 0.08, 0.08, 1 },
        primaryHi = { 0.65, 0.12, 0.12, 1 },
        danger    = { 0.32, 0.09, 0.07, 1 },
        dangerHi  = { 0.45, 0.13, 0.10, 1 },
        input     = { 0.09, 0.08, 0.065, 1 },
        label     = { 0.88, 0.82, 0.68 },
        title     = { 1, 0.82, 0, 1 },
    },
    -- A dedicated look built around the custom "Space Waffles" artwork:
    -- deep near-black panels (matching the art's own background), warm
    -- cream-gold border and text, amber primary buttons.
    spacew = {
        bg        = { 0.04, 0.035, 0.045, 0.90 },
        header    = { 0.02, 0.018, 0.024, 1 },
        border    = { 0.70, 0.60, 0.42, 1 },
        accent    = { 0.85, 0.68, 0.35, 1 },
        btn       = { 0.16, 0.13, 0.12, 1 },
        btnHover  = { 0.24, 0.20, 0.17, 1 },
        primary   = { 0.55, 0.36, 0.14, 1 },
        primaryHi = { 0.70, 0.47, 0.19, 1 },
        danger    = { 0.40, 0.14, 0.10, 1 },
        dangerHi  = { 0.52, 0.19, 0.14, 1 },
        input     = { 0.03, 0.03, 0.03, 1 },
        label     = { 0.88, 0.83, 0.72 },
        title     = { 1, 0.87, 0.55, 1 },
        art       = "spacew",   -- art\bg_main_spacew.tga / bg_graph_spacew.tga
    },
    -- A lawn-care look built from a custom mowed-lawn photo, cartoon-styled.
    -- Deep greens, cream-white border and text, grass-green primary buttons.
    onlylawns = {
        bg        = { 0.05, 0.075, 0.045, 0.92 },
        header    = { 0.03, 0.05, 0.028, 1 },
        border    = { 0.85, 0.88, 0.80, 1 },
        accent    = { 0.55, 0.80, 0.30, 1 },
        btn       = { 0.14, 0.19, 0.12, 1 },
        btnHover  = { 0.20, 0.27, 0.16, 1 },
        primary   = { 0.22, 0.48, 0.14, 1 },
        primaryHi = { 0.29, 0.60, 0.18, 1 },
        danger    = { 0.40, 0.16, 0.10, 1 },
        dangerHi  = { 0.52, 0.21, 0.14, 1 },
        input     = { 0.03, 0.04, 0.03, 1 },
        label     = { 0.86, 0.90, 0.82 },
        title     = { 0.80, 0.95, 0.55, 1 },
        art       = "onlylawns",   -- art\bg_main_onlylawns.tga / bg_graph_onlylawns.tga
    },
}

local C = PALETTES.auction   -- current palette; ApplyTheme repoints this
local mode = "classic"       -- "classic" | "auction" | "trader" | "spacew" | "onlylawns"
local done = {}          -- things already set up, so switching back and forth is cheap
local artWarned = {}

-- Back to "classic" meaning the untouched native WoW window/button art,
-- which has real 3D shading baked into its textures - that's what read as
-- "more 3D" than the flat-colored reskins. Everything else still gets the
-- full reskin (colored background/border/buttons/inputs).
local function skinned() return mode ~= "classic" end

------------------------------------------------------------
-- Small building blocks
------------------------------------------------------------

local function Solid(parent, layer, sub, color)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return t
end

-- Not every client build has SetGradientAlpha (or SetGradient with
-- CreateColor). Try both, and fall back to a flat mid-tone color rather
-- than erroring if neither is available.
-- This client's gradient support turned out unreliable: SetGradientAlpha
-- isn't present at all, and the older SetGradient path "succeeds" (no Lua
-- error) but silently renders nothing, leaving the panel see-through. Since
-- a broken-but-silent render can't be detected from Lua, this just always
-- uses a flat color - the same flat fills that have rendered correctly in
-- every part of this addon before this attempt at real gradients.
local function SafeGradient(tex, vertical, c1, c2)
    tex:SetColorTexture((c1[1] + c2[1]) / 2, (c1[2] + c2[2]) / 2, (c1[3] + c2[3]) / 2, ((c1[4] or 1) + (c2[4] or 1)) / 2)
end

-- A raised edge (light top/left, dark bottom/right) reads as popping out,
-- like a button; a sunken edge (the reverse) reads as pressed in, like a
-- text field. Four two-tone lines, the classic beveled-GUI trick. Made
-- thicker and higher-contrast than the first pass, which read as too flat.
local function Bevel(parent, raised, inset)
    inset = inset or 0
    local hi = { 1, 1, 1, raised and 0.55 or 0.16 }
    local lo = { 0, 0, 0, raised and 0.75 or 0.78 }
    local top, left = raised and hi or lo, raised and hi or lo
    local bottom, right = raised and lo or hi, raised and lo or hi
    local lines = {}
    local t1 = Solid(parent, "BORDER", 6, top)
    t1:SetPoint("TOPLEFT", inset, -inset); t1:SetPoint("TOPRIGHT", -inset, -inset); t1:SetHeight(2)
    local t2 = Solid(parent, "BORDER", 6, left)
    t2:SetPoint("TOPLEFT", inset, -inset); t2:SetPoint("BOTTOMLEFT", inset, inset); t2:SetWidth(2)
    local t3 = Solid(parent, "BORDER", 6, right)
    t3:SetPoint("TOPRIGHT", -inset, -inset); t3:SetPoint("BOTTOMRIGHT", -inset, inset); t3:SetWidth(2)
    local t4 = Solid(parent, "BORDER", 6, bottom)
    t4:SetPoint("BOTTOMLEFT", inset, inset); t4:SetPoint("BOTTOMRIGHT", -inset, inset); t4:SetHeight(2)
    lines[1], lines[2], lines[3], lines[4] = t1, t2, t3, t4
    return lines
end

-- Four 1-pixel lines around a region
local function Outline(parent, color, inset, layer)
    inset = inset or 0
    local lines = {}
    local function L(p1, p2, horizontal)
        local t = Solid(parent, layer or "BORDER", 7, color)
        t:SetPoint(p1, parent, p1, (p1:find("LEFT") and inset) or -inset, (p1:find("TOP") and -inset) or inset)
        t:SetPoint(p2, parent, p2, (p2:find("LEFT") and inset) or -inset, (p2:find("TOP") and -inset) or inset)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
        table.insert(lines, t)
    end
    L("TOPLEFT", "TOPRIGHT", true)
    L("BOTTOMLEFT", "BOTTOMRIGHT", true)
    L("TOPLEFT", "BOTTOMLEFT", false)
    L("TOPRIGHT", "BOTTOMRIGHT", false)
    return lines
end

local function ShowList(list, show)
    for _, o in ipairs(list) do o:SetShown(show) end
end

------------------------------------------------------------
-- Window background
------------------------------------------------------------

local function SkinWindow(fr)
    local st = done[fr]
    if not st then
        st = { template = {}, mine = {} }
        -- The template's own art (borders, backgrounds) - remember whether each was showing
        for k, v in pairs(fr) do
            if type(v) == "table" and v.GetObjectType and k ~= "TitleText" and k ~= "CloseButton" then
                local ok, kind = pcall(v.GetObjectType, v)
                if ok and (kind == "Texture" or (kind == "Frame" and not v:IsMouseEnabled())) then
                    table.insert(st.template, { obj = v, shown = v:IsShown() })
                end
            end
        end
        st.bg = fr:CreateTexture(nil, "BACKGROUND", nil, -8)
        st.bg:SetAllPoints()
        -- Optional custom backdrop art. Which file to use depends on the
        -- active theme's `art` key, so it's retextured on every color
        -- refresh below rather than fixed at creation. Given an explicit
        -- sub-level ABOVE bg so it's unambiguously drawn on top of it, not
        -- left to same-level creation-order tie-breaking.
        st.artSlot = (fr == _G.AHWatchFrame) and "main" or (fr == _G.AHWatchGraphFrame) and "graph" or nil
        if st.artSlot then
            st.art = fr:CreateTexture(nil, "BACKGROUND", nil, -7)
            st.art:SetAllPoints()
        end
        st.header = fr:CreateTexture(nil, "BACKGROUND", nil, -5)
        st.header:SetPoint("TOPLEFT")
        st.header:SetPoint("TOPRIGHT")
        st.header:SetHeight(24)
        -- A dark scrim between the art and everything else, so text and
        -- boxes stay readable no matter how bright the art is underneath.
        st.scrim = fr:CreateTexture(nil, "BACKGROUND", nil, -6)
        st.scrim:SetAllPoints()
        st.accent = fr:CreateTexture(nil, "BORDER", nil, 0)
        st.accent:SetPoint("TOPLEFT", st.header, "BOTTOMLEFT")
        st.accent:SetPoint("TOPRIGHT", st.header, "BOTTOMRIGHT")
        st.accent:SetHeight(2)
        -- Fixed-height gloss/shadow bands over the flat fill, since real
        -- gradients don't render on this client (see SafeGradient above).
        -- A lighter band under the header and a darker one along the
        -- bottom read as light falling on a curved/raised panel instead of
        -- a single flat color - the main thing that was making the
        -- reskinned themes look flat next to "classic"'s native 3D art.
        st.gloss = fr:CreateTexture(nil, "BACKGROUND", nil, -4)
        st.gloss:SetPoint("TOPLEFT", st.header, "BOTTOMLEFT")
        st.gloss:SetPoint("TOPRIGHT", st.header, "BOTTOMRIGHT")
        st.gloss:SetHeight(48)
        st.shade = fr:CreateTexture(nil, "BACKGROUND", nil, -4)
        st.shade:SetPoint("BOTTOMLEFT")
        st.shade:SetPoint("BOTTOMRIGHT")
        st.shade:SetHeight(34)
        st.mine = { st.bg, st.header, st.accent, st.gloss, st.shade }
        if st.art then table.insert(st.mine, st.art) end
        if st.scrim then table.insert(st.mine, st.scrim) end
        st.outline = Outline(fr, C.border)
        for _, l in ipairs(st.outline) do table.insert(st.mine, l) end
        -- A raised bevel just inside the gold/colored border gives the whole
        -- panel real depth instead of a flat colored rectangle.
        st.bevel = Bevel(fr, true, 2)
        for _, l in ipairs(st.bevel) do table.insert(st.mine, l) end
        done[fr] = st
    end
    -- Colors are refreshed every call, not just on first creation, so
    -- switching looks (Auction <-> Trader <-> Space W) doesn't leave stale colors behind.
    SafeGradient(st.bg, true, { C.bg[1] * 0.82, C.bg[2] * 0.82, C.bg[3] * 0.82, C.bg[4] or 1 },
        { C.bg[1] * 1.18, C.bg[2] * 1.18, C.bg[3] * 1.18, C.bg[4] or 1 })
    SafeGradient(st.header, true, { C.header[1] * 1.35, C.header[2] * 1.35, C.header[3] * 1.35, 1 },
        { C.header[1] * 0.75, C.header[2] * 0.75, C.header[3] * 0.75, 1 })
    st.accent:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], C.accent[4] or 1)
    st.gloss:SetColorTexture(1, 1, 1, 0.05)
    st.shade:SetColorTexture(0, 0, 0, 0.22)
    for _, l in ipairs(st.outline) do l:SetColorTexture(C.border[1], C.border[2], C.border[3], C.border[4] or 1) end
    for _, t in ipairs(st.template) do t.obj:SetShown(not skinned() and t.shown) end
    ShowList(st.mine, skinned())
    if st.art then
        local wantArt = skinned() and C.art and true or false
        if wantArt then
            if st.artLoadedKey ~= C.art then
                local path = "Interface\\AddOns\\AHWatch\\art\\bg_" .. st.artSlot .. "_" .. C.art .. ".tga"
                local ok = pcall(st.art.SetTexture, st.art, path)
                st.artOk = ok and st.art:GetTexture() and true or false
                st.artLoadedKey = C.art
                if not st.artOk and not artWarned[C.art] then
                    artWarned[C.art] = true
                    print(string.format(
                        "|cff33ccffAHWatch:|r %s background art didn't load - check that the 'art' folder has "
                        .. "bg_main_%s.tga and bg_graph_%s.tga inside your AHWatch addon folder.",
                        C.art, C.art, C.art))
                end
            end
        else
            st.artLoadedKey = nil
        end
        st.art:SetShown(wantArt and st.artOk)
        st.art:SetAlpha(0.55)
    end
    if st.scrim then
        local wantArt = skinned() and C.art and true or false
        st.scrim:SetShown(wantArt)
        st.scrim:SetColorTexture(0, 0, 0, 0.4)
    end
    if fr.TitleText then
        if not st.titleColor then st.titleColor = { fr.TitleText:GetTextColor() } end
        if skinned() then
            fr.TitleText:SetTextColor(unpack(C.title))
        else
            fr.TitleText:SetTextColor(unpack(st.titleColor))
        end
    end
end

------------------------------------------------------------
-- Buttons, input boxes, close buttons, arrows, text
------------------------------------------------------------

-- In "auction" mode, buttons keep the game's own beveled button art (which
-- already has real 3D shading baked into its texture) and are just tinted -
-- red for the main actions, untouched for everything else, matching how the
-- game itself colors its Search button red but leaves Filter/tab buttons
-- their normal tan. "trader" keeps its flat fill, with a thin highlight/
-- shadow edge added for a touch of the same dimensionality. "classic" is
-- the untouched native button, already 3D by default.
local TINT = {
    primary   = { 1.55, 0.32, 0.28, 1 },
    primaryHi = { 1.90, 0.42, 0.36, 1 },
    danger    = { 1.05, 0.22, 0.18, 1 },
    dangerHi  = { 1.35, 0.30, 0.24, 1 },
    btn       = { 1, 1, 1, 1 },
    btnHi     = { 1, 1, 1, 1 },
}

local function ButtonRole(b)
    if b:GetName() == "AHWatchGoButton" or b.pbPrimary then return "primary" end
    if b:GetText() == "Cancel" then return "danger" end
    return "btn"
end

local function RefreshButton(b)
    local st = done[b]
    if not st then return end
    local role = ButtonRole(b)
    local hovered = b:IsMouseOver() and b:IsEnabled()
    if mode == "trader" then
        local normal = (role == "primary" and C.primary) or (role == "danger" and C.danger) or C.btn
        local hover = (role == "primary" and C.primaryHi) or (role == "danger" and C.dangerHi) or C.btnHover
        local c = hovered and hover or normal
        local a = b:IsEnabled() and (c[4] or 1) or 0.35
        -- A vertical gradient plus a raised bevel instead of a flat fill,
        -- so it reads as a real button rather than a colored rectangle.
        SafeGradient(st.bg, true, { c[1] * 0.78, c[2] * 0.78, c[3] * 0.78, a }, { c[1] * 1.28, c[2] * 1.28, c[3] * 1.28, a })
    elseif mode == "auction" then
        local t = TINT[hovered and (role .. "Hi") or role] or TINT.btn
        local a = b:IsEnabled() and (t[4] or 1) or 0.5
        for _, p in ipairs(st.parts) do p:SetVertexColor(t[1], t[2], t[3], a) end
    end
end

local function SkinButton(b)
    local st = done[b]
    if not st then
        st = { parts = {} }
        for _, key in ipairs({ "Left", "Middle", "Right" }) do
            if b[key] then table.insert(st.parts, b[key]) end
        end
        st.bg = b:CreateTexture(nil, "BACKGROUND", nil, -1)
        st.bg:SetAllPoints()
        -- A raised bevel (light top/left, dark bottom/right) instead of a
        -- single flat-colored outline, so it reads as a real 3D button.
        st.outline = Bevel(b, true)
        st.fonts = { b:GetNormalFontObject(), b:GetHighlightFontObject(), b:GetDisabledFontObject() }
        local small = st.fonts[1] == GameFontNormalSmall
        st.skinnedFonts = {
            small and GameFontHighlightSmall or GameFontHighlight,
            small and GameFontHighlightSmall or GameFontHighlight,
            small and GameFontDisableSmall or GameFontDisable,
        }
        b:HookScript("OnEnter", RefreshButton)
        b:HookScript("OnLeave", RefreshButton)
        for _, m in ipairs({ "Enable", "Disable", "SetEnabled", "SetText" }) do
            hooksecurefunc(b, m, RefreshButton)
        end
        done[b] = st
    end
    local flat = (mode == "trader")
    ShowList(st.parts, not flat)
    st.bg:SetShown(flat)
    ShowList(st.outline, flat)
    if not flat then
        for _, p in ipairs(st.parts) do p:SetVertexColor(1, 1, 1, 1) end
    end
    local hl = b:GetHighlightTexture()
    if hl then hl:SetAlpha(flat and 0 or 1) end
    local fonts = skinned() and st.skinnedFonts or st.fonts
    if fonts[1] then b:SetNormalFontObject(fonts[1]) end
    if fonts[2] then b:SetHighlightFontObject(fonts[2]) end
    if fonts[3] then b:SetDisabledFontObject(fonts[3]) end
    RefreshButton(b)
end

local CAP_W = 11   -- rendered width of each rounded end-cap

local function SkinEditBox(e)
    local st = done[e]
    if not st then
        st = { parts = {} }
        for _, key in ipairs({ "Left", "Middle", "Mid", "Right" }) do
            if e[key] then table.insert(st.parts, e[key]) end
        end
        local holder = CreateFrame("Frame", nil, e)
        holder:SetPoint("TOPLEFT", -5, 1)
        holder:SetPoint("BOTTOMRIGHT", 1, -1)
        holder:SetFrameLevel(math.max(0, e:GetFrameLevel() - 1))
        -- A rounded pill shape (left/right end-caps plus a flat stretch in
        -- the middle) instead of a sharp-cornered rectangle. The caps are
        -- one small white shape, tinted to the theme and mirrored for the
        -- right side, so it works at any box width without distortion.
        st.bg = holder:CreateTexture(nil, "BACKGROUND", nil, 0)
        st.bg:SetPoint("TOPLEFT", CAP_W - 2, 0)
        st.bg:SetPoint("BOTTOMRIGHT", -(CAP_W - 2), 0)
        local capOk = true
        st.capL = holder:CreateTexture(nil, "BACKGROUND", nil, 1)
        st.capL:SetSize(CAP_W, 22)
        st.capL:SetPoint("LEFT", 0, 0)
        capOk = capOk and pcall(st.capL.SetTexture, st.capL, "Interface\\AddOns\\AHWatch\\art\\input_cap.tga")
        st.capR = holder:CreateTexture(nil, "BACKGROUND", nil, 1)
        st.capR:SetSize(CAP_W, 22)
        st.capR:SetPoint("RIGHT", 0, 0)
        capOk = capOk and pcall(st.capR.SetTexture, st.capR, "Interface\\AddOns\\AHWatch\\art\\input_cap.tga")
        if capOk then st.capR:SetTexCoord(1, 0, 0, 1) end
        st.capOk = capOk
        if not capOk then
            -- No cap art available: fall back to the plain sunken-bevel look
            st.capL:Hide(); st.capR:Hide()
            st.bg:ClearAllPoints()
            st.bg:SetAllPoints()
            st.outline = Bevel(holder, false)
        end
        -- A thin dark line along the very top and a thin light one along the
        -- very bottom (inset from the rounded ends) gives the pill an inset
        -- groove - reads as pressed-in like a real sunken field, not flat.
        st.grooveTop = holder:CreateTexture(nil, "ARTWORK", nil, 2)
        st.grooveTop:SetPoint("TOPLEFT", CAP_W - 4, -1)
        st.grooveTop:SetPoint("TOPRIGHT", -(CAP_W - 4), -1)
        st.grooveTop:SetHeight(1)
        st.grooveTop:SetColorTexture(0, 0, 0, 0.55)
        st.grooveBottom = holder:CreateTexture(nil, "ARTWORK", nil, 2)
        st.grooveBottom:SetPoint("BOTTOMLEFT", CAP_W - 4, 1)
        st.grooveBottom:SetPoint("BOTTOMRIGHT", -(CAP_W - 4), 1)
        st.grooveBottom:SetHeight(1)
        st.grooveBottom:SetColorTexture(1, 1, 1, 0.14)
        st.holder = holder
        done[e] = st
    end
    SafeGradient(st.bg, true, { C.input[1] * 0.62, C.input[2] * 0.62, C.input[3] * 0.62, C.input[4] or 1 },
        { C.input[1] * 1.25, C.input[2] * 1.25, C.input[3] * 1.25, C.input[4] or 1 })
    if st.capOk then
        st.capL:SetVertexColor(C.input[1], C.input[2], C.input[3], C.input[4] or 1)
        st.capR:SetVertexColor(C.input[1], C.input[2], C.input[3], C.input[4] or 1)
    end
    ShowList(st.parts, not skinned())
    st.holder:SetShown(skinned())
end

local function SkinClose(b)
    local st = done[b]
    if not st then
        st = { textures = {} }
        for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
            local t = b[getter] and b[getter](b)
            if t then table.insert(st.textures, t) end
        end
        st.x = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        st.x:SetPoint("CENTER", 0, 1)
        st.x:SetText("x")
        b:HookScript("OnEnter", function() if skinned() then st.x:SetTextColor(1, 0.35, 0.35) end end)
        b:HookScript("OnLeave", function() st.x:SetTextColor(C.label[1], C.label[2], C.label[3]) end)
        st.x:SetTextColor(C.label[1], C.label[2], C.label[3])
        done[b] = st
    end
    for _, t in ipairs(st.textures) do t:SetAlpha(skinned() and 0 or 1) end
    st.x:SetShown(skinned())
end

local function SkinArrow(b)
    local t = b:GetNormalTexture()
    if t then
        if skinned() then t:SetVertexColor(0.7, 0.72, 0.76) else t:SetVertexColor(1, 1, 1) end
    end
end

-- Gold WoW labels become soft white; everything else keeps its color
local function SkinText(fs)
    local st = done[fs]
    if not st then
        local r, g, b, a = fs:GetTextColor()
        st = { color = { r, g, b, a }, gold = (r > 0.9 and g > 0.7 and g < 0.9 and b < 0.2) }
        done[fs] = st
    end
    -- A dark drop shadow keeps text legible over the Space W artwork,
    -- which varies from near-black to bright depending on what's behind it.
    if mode == "spacew" then
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 0.9)
    elseif st.shadowSet then
        fs:SetShadowOffset(0, 0)
        fs:SetShadowColor(0, 0, 0, 0)
    end
    st.shadowSet = (mode == "spacew")
    if not st.gold then return end
    if mode == "trader" then
        fs:SetTextColor(C.label[1], C.label[2], C.label[3])
    else
        fs:SetTextColor(unpack(st.color))
    end
end

------------------------------------------------------------
-- Walking the windows
------------------------------------------------------------

local function Walk(fr)
    for _, r in ipairs({ fr:GetRegions() }) do
        if r:GetObjectType() == "FontString" then SkinText(r) end
    end
    for _, c in ipairs({ fr:GetChildren() }) do
        local kind = c:GetObjectType()
        if c.pbClose or (c == fr.CloseButton) then
            SkinClose(c)
        elseif c.pbArrow then
            SkinArrow(c)
        elseif kind == "Button" and c.Left and c.Middle and c.Right then
            SkinButton(c)
        elseif kind == "EditBox" and c.Left and c.Right then
            SkinEditBox(c)
        end
        if not done[c] or kind ~= "Button" then Walk(c) end
    end
end

function ns.ApplyTheme(name)
    mode = PALETTES[name] and name or "classic"
    C = PALETTES[mode] or PALETTES.auction
    ns.theme = mode
    for _, fr in ipairs({ _G.AHWatchFrame, _G.AHWatchGraphFrame }) do
        if fr then
            SkinWindow(fr)
            Walk(fr)
        end
    end
    if ns.SkinSellPanel then ns.SkinSellPanel(skinned(), mode) end
    if ns.RefreshCoinIcons then ns.RefreshCoinIcons() end
    if ns.ThemeLabel then ns.ThemeLabel() end
    if ns.RefreshGraph then ns.RefreshGraph() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, _, name)
    if name == "AHWatch" then
        ns.ApplyTheme((AHWatchDB and AHWatchDB.theme) or "auction")
    end
end)
