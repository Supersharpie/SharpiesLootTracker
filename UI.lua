local _, ns = ...
local Compat = ns.Compat

local UI = {}
ns.UI = UI

-- =============================================================
-- Theme: the same flat look as Sharpie's Gear Judge, with the player's class colour as accent
-- =============================================================
local T = {
    Accent = { 0.93, 0.45, 0.68 },
    Value  = { 0.96, 0.64, 0.80 },
    Text   = { 0.92, 0.92, 0.92 },
    Muted  = { 0.55, 0.55, 0.58 },
    Window = { 0.06, 0.06, 0.08, 0.93 },
    Panel  = { 0.10, 0.10, 0.12, 0.80 },
    Edge   = { 1, 1, 1, 0.08 },
    Gold   = { 1.00, 0.80, 0.30 },
    Green  = { 0.45, 0.88, 0.45 },
    Blue   = { 0.42, 0.68, 1.00 },
}
do
    local _, class = UnitClass("player")
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then
        T.Accent = { c.r, c.g, c.b }
        T.Value = { c.r + (1 - c.r) * 0.4, c.g + (1 - c.g) * 0.4, c.b + (1 - c.b) * 0.4 }
    end
end

local STATES = {
    running = { label = "Running", color = { 0.29, 0.87, 0.29 } },
    idle    = { label = "Idle",    color = { 0.95, 0.70, 0.24 } },
    paused  = { label = "Paused",  color = { 0.54, 0.54, 0.54 } },
    ready   = { label = "Ready",   color = { 0.54, 0.54, 0.54 } },
}

local HEADER_H = 26          -- 2px accent stripe + 24px header
local TABS_H = 22
local CONTENT_TOP = HEADER_H + TABS_H + 6
local FOOTER_H = 34
local STATS_W = 200
local STAT_ROW_H = 15
local ROW_H = 17             -- loot list rows
local MIN_W, MIN_H = 400, 280
local COMPACT_W, COMPACT_H = 340, 26
local DOUBLE_CLICK = 0.35

local frame, body, tabs, stats, listFrame, listRows, startBtn, emptyText
local dot, clock, stateText, compactText, title, compactBtn
local listOffset = 0

local function Muted(text) return "|cff8c8c94" .. text .. "|r" end

-- =============================================================
-- Small building blocks
-- =============================================================
local function Solid(parent, layer, c, a)
    local t = parent:CreateTexture(nil, layer)
    t:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1)
    return t
end

local function SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

-- 1px border drawn with four edge textures (no BackdropTemplate needed)
local function Border(f, c, a)
    local edges = {}
    for i = 1, 4 do edges[i] = Solid(f, "BORDER", c, a) end
    edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)
    return edges
end

local function ColorEdges(edges, c, a)
    for _, e in ipairs(edges) do e:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1) end
end

-- Flat panel button; the edge lights up in the accent colour on hover
local function FlatButton(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, height)
    Solid(b, "BACKGROUND", T.Panel):SetAllPoints()
    local edges = Border(b, T.Edge)
    b:SetScript("OnEnter", function() ColorEdges(edges, T.Accent, 1) end)
    b:SetScript("OnLeave", function() ColorEdges(edges, T.Edge) end)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.text:SetPoint("CENTER")
    b.text:SetText(text)
    return b
end

local function IconButton(parent, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    Solid(b, "HIGHLIGHT", { 1, 1, 1 }, 0.08):SetAllPoints()
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(tooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function ShowItemTooltip(owner, link)
    if not link then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
end

local function HideTooltip() GameTooltip:Hide() end

local function StateOf(s)
    if s.running then return "running" end
    if s.autoPaused then return "idle" end
    return (s.elapsed > 0) and "paused" or "ready"
end

local function BagsText(free)
    if free == 0 then return "|cffff736bfull|r" end
    local text = free .. " free"
    local mins = ns.GetBagsFullMinutes(free)
    if mins then text = text .. Muted(string.format(" (~%dm)", math.floor(mins + 0.5))) end
    return text
end

-- =============================================================
-- Window position and size
-- =============================================================
-- Anchor by the top-left corner so the compact bar and the full window share that corner
local function AnchorTopLeft()
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left then return end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", left, top - UIParent:GetHeight())
end

local function SavePosition()
    AnchorTopLeft()
    local point, _, _, x, y = frame:GetPoint()
    local w = ns.char.window
    w.point, w.x, w.y = point, x, y
    if not w.compact then w.width, w.height = frame:GetSize() end
end

-- =============================================================
-- Header: status, timer, compact/close
-- =============================================================
local function CreateHeader()
    local stripe = Solid(frame, "BORDER", T.Accent)
    stripe:SetPoint("TOPLEFT"); stripe:SetPoint("TOPRIGHT"); stripe:SetHeight(2)

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", 0, -2)
    header:SetPoint("TOPRIGHT", 0, -2)
    header:SetHeight(HEADER_H - 2)

    dot = Solid(header, "ARTWORK", STATES.ready.color)
    dot:SetSize(7, 7)
    dot:SetPoint("LEFT", 9, 0)
    clock = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    clock:SetPoint("LEFT", dot, "RIGHT", 6, 0)
    SetColor(clock, T.Value)
    stateText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stateText:SetPoint("LEFT", clock, "RIGHT", 6, 0)
    SetColor(stateText, T.Muted)
    compactText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    compactText:SetPoint("LEFT", stateText, "RIGHT", 2, 0)
    SetColor(compactText, T.Value)

    local close = IconButton(header, "Hide (type /slt to show again)")
    close:SetPoint("RIGHT", -4, 0)
    close.text = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    close.text:SetPoint("CENTER")
    close.text:SetText("X")
    SetColor(close.text, T.Muted)
    close:SetScript("OnClick", function() UI.SetShown(false) end)

    -- Bar icon = shrink to the compact bar; box icon = back to the full window
    compactBtn = IconButton(header, "Compact bar / full window (or double-click the header)")
    compactBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
    compactBtn.bar = Solid(compactBtn, "ARTWORK", T.Muted)
    compactBtn.bar:SetSize(8, 2)
    compactBtn.bar:SetPoint("CENTER", 0, -3)
    compactBtn.box = CreateFrame("Frame", nil, compactBtn)
    compactBtn.box:SetSize(8, 8)
    compactBtn.box:SetPoint("CENTER")
    Border(compactBtn.box, T.Muted)
    compactBtn:SetScript("OnClick", function() UI.SetCompact(not ns.char.window.compact) end)

    title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("RIGHT", compactBtn, "LEFT", -6, 0)
    title:SetText("Loot Tracker")
    SetColor(title, T.Accent)
end

-- =============================================================
-- Tabs
-- =============================================================
local function LayoutTabs()
    local gap = 2
    local width = (frame:GetWidth() - 12 - gap * (#tabs - 1)) / #tabs
    for i, tab in ipairs(tabs) do
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", body, "TOPLEFT", 6 + (i - 1) * (width + gap), -HEADER_H)
        tab:SetSize(width, TABS_H)
    end
end

local function SelectTab(key)
    ns.char.window.tab = key
    listOffset = 0
    UI.Refresh()
end

local function CreateTabs()
    tabs = {}
    local line = Solid(body, "BORDER", T.Edge)
    line:SetPoint("TOPLEFT", 0, -(HEADER_H + TABS_H))
    line:SetPoint("TOPRIGHT", 0, -(HEADER_H + TABS_H))
    line:SetHeight(1)
    for i, info in ipairs(ns.TABS) do
        local tab = CreateFrame("Button", nil, body)
        tab.key = info.key
        Solid(tab, "HIGHLIGHT", { 1, 1, 1 }, 0.04):SetAllPoints()
        tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        tab.text:SetText(info.label)
        -- Item count badge next to the label
        tab.badge = CreateFrame("Frame", nil, tab)
        tab.badge:SetHeight(12)
        tab.badge:SetPoint("LEFT", tab.text, "RIGHT", 4, 0)
        tab.badge.bg = Solid(tab.badge, "BACKGROUND", { 1, 1, 1 }, 0.08)
        tab.badge.bg:SetAllPoints()
        tab.badge.text = tab.badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tab.badge.text:SetPoint("CENTER", 0, 0)
        tab.underline = Solid(tab, "ARTWORK", T.Accent)
        tab.underline:SetPoint("BOTTOMLEFT"); tab.underline:SetPoint("BOTTOMRIGHT"); tab.underline:SetHeight(2)
        tab:SetScript("OnClick", function() SelectTab(info.key) end)
        tabs[i] = tab
    end
    LayoutTabs()
end

local function RefreshTabs()
    local current = ns.char.window.tab
    for _, tab in ipairs(tabs) do
        local selected = tab.key == current
        SetColor(tab.text, selected and { 1, 1, 1 } or T.Muted)
        tab.underline:SetShown(selected)
        local b = tab.badge
        b.text:SetText(ns.GetTotals(tab.key).count)
        if selected then
            b.bg:SetColorTexture(T.Accent[1], T.Accent[2], T.Accent[3], 1)
            b.text:SetTextColor(0.07, 0.07, 0.07)
        else
            b.bg:SetColorTexture(1, 1, 1, 0.08)
            SetColor(b.text, T.Muted)
        end
        b:SetWidth(b.text:GetStringWidth() + 8)
        -- Center label + badge together
        tab.text:ClearAllPoints()
        tab.text:SetPoint("CENTER", tab, "CENTER", -(b:GetWidth() + 4) / 2, 1)
    end
end

-- =============================================================
-- Stats: Rate / Earnings / Session sections
-- =============================================================
local LAYOUT = {
    ALL = {
        { "sec", "Rate", "Gold" }, { "big" }, { "row", "Per kill" },
        { "sec", "Earnings", "Green" }, { "row", "Gold" }, { "row", "Items" }, { "row", "Costs" }, { "split" },
        { "sec", "Session", "Blue" }, { "row", "Bags" }, { "row", "Priciest" },
    },
    CAT = {
        { "sec", "Rate", "Gold" }, { "big" },
        { "sec", "Earnings", "Green" }, { "row", "Count" }, { "row", "Value" },
        { "sec", "Session", "Blue" }, { "row", "Priciest" },
    },
}

-- Hover help for numbers that need explaining
local STAT_HINTS = {
    GPH = "Estimated gold per hour after costs, over the whole session.\nShown after the first 2 minutes.",
    ["Per kill"] = "Coin and items per kill (your group's killing blows).",
    Costs = "Money spent at vendors this session (repairs, food, ammo).\n/slt costs turns this off.",
    Bags = "Free bag slots, and roughly how long until they're full\nat this session's pace.",
}

local secPool, rowPool, statRow = {}, {}, {}
local big, split, layoutFor

local function OnStatEnter(self)
    if self.link then ShowItemTooltip(self, self.link) return end
    if not self.hint then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.hint, 1, 1, 1, 1, true)
    GameTooltip:Show()
end

local function NewSection()
    local sec = stats:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec.line = Solid(stats, "ARTWORK", T.Accent, 0.5)
    sec.line:SetHeight(1)
    sec.line:SetWidth(STATS_W)
    sec.line:SetPoint("TOPLEFT", sec, "BOTTOMLEFT", 0, -2)
    return sec
end

local function NewRow()
    local row = CreateFrame("Frame", nil, stats)
    row:SetSize(STATS_W, STAT_ROW_H)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("LEFT")
    SetColor(row.label, T.Muted)
    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.value:SetPoint("RIGHT")
    row.value:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
    row.value:SetJustifyH("RIGHT")
    row.value:SetWordWrap(false)
    SetColor(row.value, T.Value)
    row:SetScript("OnEnter", OnStatEnter)
    row:SetScript("OnLeave", HideTooltip)
    return row
end

local function CreateStats()
    stats = CreateFrame("Frame", nil, body)
    stats:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -CONTENT_TOP)
    stats:SetSize(STATS_W, 200)

    -- The headline number: gold per hour
    big = CreateFrame("Frame", nil, stats)
    big:SetSize(STATS_W, 26)
    big.value = big:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local font = (GameFontNormal and GameFontNormal:GetFont()) or STANDARD_TEXT_FONT
    big.value:SetFont(font, 20, "")
    big.value:SetPoint("LEFT", 0, -1)
    SetColor(big.value, T.Gold)
    big.unit = big:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    big.unit:SetPoint("BOTTOMLEFT", big.value, "BOTTOMRIGHT", 4, 2)
    big.unit:SetText("per hour")
    SetColor(big.unit, T.Muted)
    big.hint = STAT_HINTS.GPH
    big:EnableMouse(true)
    big:SetScript("OnEnter", OnStatEnter)
    big:SetScript("OnLeave", HideTooltip)

    -- AH vs vendor split of the item value
    split = stats:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    SetColor(split, T.Muted)
end

local function LayoutStats(kind)
    for _, sec in ipairs(secPool) do sec:Hide(); sec.line:Hide() end
    for _, row in ipairs(rowPool) do row:Hide() end
    big:Hide()
    split:Hide()
    wipe(statRow)
    local y, nSec, nRow = 0, 0, 0
    for i, item in ipairs(LAYOUT[kind]) do
        local what = item[1]
        if what == "sec" then
            if i > 1 then y = y + 5 end
            nSec = nSec + 1
            local sec = secPool[nSec] or NewSection()
            secPool[nSec] = sec
            sec:SetText(item[2]:upper())
            SetColor(sec, T[item[3]])
            sec:ClearAllPoints()
            sec:SetPoint("TOPLEFT", stats, "TOPLEFT", 0, -y)
            sec:Show(); sec.line:Show()
            y = y + 15
        elseif what == "big" then
            big:ClearAllPoints()
            big:SetPoint("TOPLEFT", stats, "TOPLEFT", 0, -y)
            big:Show()
            y = y + 26
        elseif what == "split" then
            split:ClearAllPoints()
            split:SetPoint("TOPLEFT", stats, "TOPLEFT", 0, -y - 1)
            split:Show()
            y = y + 13
        else
            nRow = nRow + 1
            local row = rowPool[nRow] or NewRow()
            rowPool[nRow] = row
            row.label:SetText(item[2])
            row.hint = STAT_HINTS[item[2]]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", stats, "TOPLEFT", 0, -y)
            row:Show()
            statRow[item[2]] = row
            y = y + STAT_ROW_H
        end
    end
    layoutFor = kind
end

-- =============================================================
-- Loot list
-- =============================================================
local SOURCE_NAMES = { vendor = "vendor", tsm = "TSM", auctionator = "Auctionator", auctioneer = "Auctioneer" }

local function VisibleRowCount()
    return math.max(1, math.floor((listFrame:GetHeight() - 4) / ROW_H))
end

local function CreateListRow(i)
    local row = CreateFrame("Button", nil, listFrame)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 3, -2 - (i - 1) * ROW_H)
    row:SetPoint("RIGHT", listFrame, "RIGHT", -3, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    Solid(row, "HIGHLIGHT", { 1, 1, 1 }, 0.07):SetAllPoints()
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_H - 3, ROW_H - 3)
    row.icon:SetPoint("LEFT", 2, 0)
    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.value:SetPoint("RIGHT", -2, 0)
    row.value:SetJustifyH("RIGHT")
    row.qty = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.qty:SetPoint("RIGHT", row.value, "LEFT", -5, 0)
    SetColor(row.qty, T.Muted)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.qty, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row:SetScript("OnEnter", function(self)
        local e = self.entry
        if not e then return end
        ShowItemTooltip(self, e.link)
        local price = "Price: " .. (SOURCE_NAMES[e.source] or e.source or "?")
        if e.age then price = price .. string.format(" (%d day%s old)", e.age, e.age == 1 and "" or "s") end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(price, 0.6, 0.8, 1)
        GameTooltip:AddLine("Right-click: remove   Ctrl-right-click: always ignore", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", HideTooltip)
    row:SetScript("OnClick", function(self, button)
        local e = self.entry
        if not e then return end
        if button == "RightButton" and IsControlKeyDown() then
            ns.Ignore(e.link)
        elseif button == "RightButton" then
            ns.RemoveEntry(e.id)
        elseif IsModifiedClick and HandleModifiedItemClick then
            HandleModifiedItemClick(e.link)
        end
    end)
    return row
end

local function CreateList()
    listFrame = CreateFrame("Frame", nil, body)
    listFrame:SetPoint("TOPLEFT", body, "TOPLEFT", STATS_W + 18, -CONTENT_TOP)
    listFrame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -8, FOOTER_H)
    Solid(listFrame, "BACKGROUND", T.Panel):SetAllPoints()
    Border(listFrame, T.Edge)
    listFrame:EnableMouseWheel(true)
    listFrame:SetScript("OnMouseWheel", function(_, delta)
        listOffset = math.max(0, listOffset - delta * 3)
        UI.RefreshList()
    end)
    listRows = {}
    emptyText = listFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyText:SetPoint("CENTER")
    emptyText:SetText("Nothing looted yet")
end

-- =============================================================
-- Public
-- =============================================================
function UI.Create()
    if frame then return end
    local w = ns.char.window
    if w.width < MIN_W then w.width = MIN_W end
    if w.height < MIN_H then w.height = MIN_H end -- older saved sizes don't fit the new layout

    frame = CreateFrame("Frame", "SharpiesLootTrackerFrame", UIParent)
    frame:SetSize(w.width, w.height)
    frame:SetPoint(w.point, UIParent, w.point, w.x, w.y)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    Compat.SetResizeBounds(frame, MIN_W, MIN_H, 900, 700)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); SavePosition() end)
    -- Double-click the header (or any empty part of the window) to switch compact/full
    local lastClick
    frame:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        local now = GetTime()
        if lastClick and now - lastClick < DOUBLE_CLICK then
            lastClick = nil
            UI.SetCompact(not ns.char.window.compact)
        else
            lastClick = now
        end
    end)

    Solid(frame, "BACKGROUND", T.Window):SetAllPoints()
    Border(frame, T.Edge)
    CreateHeader()

    -- Everything below the header; hidden in compact mode
    body = CreateFrame("Frame", nil, frame)
    body:SetAllPoints()
    CreateTabs()
    CreateStats()
    CreateList()

    startBtn = FlatButton(body, "Start", 84, 20)
    startBtn:SetPoint("BOTTOMLEFT", 8, 7)
    startBtn:SetScript("OnClick", ns.Toggle)

    local resetBtn = FlatButton(body, "Reset", 84, 20)
    resetBtn:SetPoint("LEFT", startBtn, "RIGHT", 6, 0)
    resetBtn:SetScript("OnClick", function()
        if IsShiftKeyDown() then ns.Reset() return end
        StaticPopup_Show("SHARPIESLOOTTRACKER_RESET")
    end)

    StaticPopupDialogs["SHARPIESLOOTTRACKER_RESET"] = {
        text = "Reset the current loot session?",
        button1 = YES, button2 = NO,
        OnAccept = ns.Reset,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    local grip = CreateFrame("Button", nil, body)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() AnchorTopLeft(); frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); SavePosition(); UI.Refresh() end)

    frame:SetScript("OnSizeChanged", function()
        LayoutTabs()
        UI.RefreshList()
    end)

    -- Clock tick while visible
    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 0.5 then
            elapsed = 0
            if ns.char.session.running then UI.RefreshStats() end
        end
    end)

    frame:SetShown(w.shown)
    UI.SetCompact(w.compact)
end

function UI.IsShown() return frame and frame:IsShown() end

function UI.SetShown(show)
    if not frame then return end
    frame:SetShown(show)
    ns.char.window.shown = show and true or false
    if show then UI.Refresh() end
end

-- Compact: just the header bar (state, time, GPH, bags)
function UI.SetCompact(on)
    if not frame then return end
    local w = ns.char.window
    w.compact = on and true or false
    AnchorTopLeft()
    body:SetShown(not w.compact)
    title:SetShown(not w.compact)
    compactText:SetShown(w.compact)
    compactBtn.bar:SetShown(not w.compact)
    compactBtn.box:SetShown(w.compact)
    if w.compact then frame:SetSize(COMPACT_W, COMPACT_H) else frame:SetSize(w.width, w.height) end
    SavePosition()
    UI.Refresh()
end

function UI.RefreshStats()
    if not frame then return end
    local s = ns.char.session
    local state = STATES[StateOf(s)]
    dot:SetColorTexture(state.color[1], state.color[2], state.color[3], 1)
    stateText:SetText(state.label:upper())
    clock:SetText(Compat.FormatTime(ns.GetElapsed()))

    local fm = Compat.FormatMoney
    local function rate(amount)
        local v = ns.GetPerHour(amount)
        return v and fm(v) or Muted("--")
    end
    local all = ns.GetTotals("ALL")
    local gross = all.coin + all.value
    local net = gross - all.costs
    local free = ns.GetFreeBagSlots()

    if ns.char.window.compact then
        compactText:SetText(Muted("·  ") .. rate(net) .. Muted("/h  ·  Bags ") .. BagsText(free))
        return
    end

    local tab = ns.char.window.tab
    local kind = (tab == "ALL") and "ALL" or "CAT"
    if layoutFor ~= kind then LayoutStats(kind) end
    local t = (tab == "ALL") and all or ns.GetTotals(tab)
    local function set(label, text, link)
        local row = statRow[label]
        row.value:SetText(text)
        row.link = link
        row:EnableMouse(link ~= nil or row.hint ~= nil)
    end

    if kind == "ALL" then
        big.value:SetText(rate(net))
        set("Per kill", all.kills > 0 and (fm(gross / all.kills) .. Muted(" (" .. all.kills .. ")")) or Muted("--"))
        set("Gold", fm(all.coin))
        set("Items", fm(all.value) .. Muted(" (" .. all.count .. ")"))
        set("Costs", all.costs > 0 and fm(-all.costs) or Muted("--"))
        split:SetText("AH " .. fm(all.ahValue) .. "   ·   Vendor " .. fm(all.value - all.ahValue))
        set("Bags", BagsText(free))
    else
        big.value:SetText(rate(t.value))
        set("Count", tostring(t.count))
        set("Value", fm(t.value))
    end
    set("Priciest", t.priciestLink or Muted("--"), t.priciestLink)
end

function UI.RefreshList()
    if not frame or not listFrame then return end
    local tab = ns.char.window.tab

    -- Newest first, filtered to the tab
    local filtered = {}
    local entries = ns.char.session.entries
    for i = #entries, 1, -1 do
        local e = entries[i]
        if tab == "ALL" or e.category == tab then filtered[#filtered + 1] = e end
    end

    local visible = VisibleRowCount()
    listOffset = math.min(listOffset, math.max(0, #filtered - visible))
    for i = 1, visible do
        local row = listRows[i] or CreateListRow(i)
        listRows[i] = row
        local e = filtered[i + listOffset]
        row.entry = e
        if e then
            local _, _, _, _, icon = Compat.GetItemInfoInstant(e.link)
            row.icon:SetTexture(icon)
            row.name:SetText(e.link)
            row.qty:SetText(e.qty > 1 and ("x" .. e.qty) or "")
            -- Orange * marks an old Auctionator price
            local stale = e.age and e.age >= ns.db.staleDays
            row.value:SetText((stale and "|cffff8800*|r " or "") .. Compat.FormatMoney(e.value))
            row:Show()
        else
            row:Hide()
        end
    end
    for i = visible + 1, #listRows do listRows[i]:Hide(); listRows[i].entry = nil end
    emptyText:SetShown(#filtered == 0)
end

function UI.Refresh()
    if not frame then return end
    local s = ns.char.session
    startBtn.text:SetText(s.running and "Pause" or ((s.elapsed > 0) and "Continue" or "Start"))
    RefreshTabs()
    UI.RefreshStats()
    UI.RefreshList()
end
