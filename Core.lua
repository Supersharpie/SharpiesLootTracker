local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

SharpiesLootTracker = ns -- global handle for debugging (/dump SharpiesLootTracker.char.session)

ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
ns.PREFIX = "|cff00ccffLoot Tracker:|r "

function ns.Print(msg) print(ns.PREFIX .. tostring(msg)) end

-- Chat line plus a raid-warning style flash and sound, for things worth looking up for
function ns.Alert(msg)
    ns.Print(msg)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, msg, (ChatTypeInfo and ChatTypeInfo.RAID_WARNING) or { r = 1, g = 1, b = 1 })
    end
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
end

-- Item categories, and the tabs in display order (most useful to a farmer first)
ns.CATEGORIES = { "MATS", "GEAR", "JUNK", "OTHER" }
ns.TABS = {
    { key = "ALL",   label = "All" },
    { key = "MATS",  label = "Mats" },
    { key = "GEAR",  label = "Gear" },
    { key = "JUNK",  label = "Junk" },
    { key = "OTHER", label = "Other" },
}
-- 0.2.0 renamed two categories
local RENAMED = { TRASH = "JUNK", TRADEGOODS = "MATS" }

-- Account-wide settings
local ACCOUNT_DEFAULTS = {
    priceSource = "auto",       -- auto | tsm | auctionator | auctioneer | vendor
    tsmPriceString = "min(dbmarket, dbminbuyout)", -- dbmarket alone overrates slow sellers like BoE greens
    neverBelowVendor = true,    -- an AH price under vendor value means you'd just vendor it
    soulboundAsVendor = true,   -- BoP items can't be sold on the AH
    countQuestMoney = true,
    autoStart = true,           -- first loot starts a fresh session (not one you paused)
    idleMinutes = 5,            -- pause after this long without loot, or on AFK (0 = off)
    countCosts = true,          -- money spent at vendors (repairs, food, ammo) comes off the total
    alertValue = 50000,         -- alert for a drop worth at least this much each, in copper (0 = off)
    staleDays = 3,              -- mark Auctionator prices older than this
    ignoreQuestItems = true,    -- quest items are worth nothing and clutter Other stuff
    ignore = {},                -- itemID -> true, never recorded
    maxEntries = 500,
}

-- Per-character window + session state
local CHAR_DEFAULTS = {
    window = { shown = true, point = "CENTER", x = 0, y = 0, width = 470, height = 300, listShown = true, compact = false, tab = "ALL" },
}

local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                ApplyDefaults(target[k], v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            ApplyDefaults(target[k], v)
        end
    end
end

function ns.NewSession()
    -- ahValue: the part of the item value priced from the auction house (the rest is vendor value)
    local s = { running = false, elapsed = 0, coin = 0, costs = 0, kills = 0, lootedMobs = 0, slotsUsed = 0, ahValue = 0, cats = {}, entries = {}, nextId = 1 }
    for _, key in ipairs(ns.CATEGORIES) do
        s.cats[key] = { value = 0, count = 0, priciest = 0, priciestLink = nil }
    end
    return s
end

-- Seconds of farming in this session (only counts time while running and logged in)
function ns.GetElapsed()
    local s = ns.char.session
    local t = s.elapsed
    if s.running and ns.runStartedAt then t = t + (GetTime() - ns.runStartedAt) end
    return t
end

function ns.Start()
    local s = ns.char.session
    if s.running then return end
    s.running = true
    s.paused, s.autoPaused = nil, nil
    ns.runStartedAt = GetTime()
    ns.lastLootAt = GetTime()
    if ns.UI then ns.UI.Refresh() end
end

function ns.Pause()
    local s = ns.char.session
    if not s.running then
        -- Pausing while idle-paused makes it stick: the next loot no longer carries on
        if s.autoPaused then
            s.paused, s.autoPaused = true, nil
            if ns.UI then ns.UI.Refresh() end
        end
        return
    end
    s.elapsed = ns.GetElapsed()
    s.running = false
    s.paused, s.autoPaused = true, nil
    ns.runStartedAt = nil
    if ns.UI then ns.UI.Refresh() end
end

-- Idle or AFK: stop the clock as of the last loot, so the idle stretch isn't counted.
-- Unlike a manual pause, the next loot carries on by itself.
function ns.AutoPause(reason)
    local s = ns.char.session
    if not s.running or not ns.runStartedAt then return end
    local stop = math.min(math.max(ns.lastLootAt or ns.runStartedAt, ns.runStartedAt), GetTime())
    s.elapsed = s.elapsed + (stop - ns.runStartedAt)
    s.running, s.autoPaused = false, true
    ns.runStartedAt = nil
    ns.Print(string.format(L["Paused (%s). Time since your last loot isn't counted; loot something to carry on."], reason))
    if ns.UI then ns.UI.Refresh() end
end

-- Called when something countable is looted; true if the session is (now) running
function ns.EnsureRunning()
    local s = ns.char.session
    if not s.running then
        if s.autoPaused then
            ns.Start()
        elseif ns.db.autoStart and not s.paused then
            ns.Start()
        else
            return false
        end
    end
    ns.lastLootAt = GetTime()
    return true
end

function ns.Toggle()
    if ns.char.session.running then ns.Pause() else ns.Start() end
end

function ns.Reset()
    ns.char.session = ns.NewSession()
    ns.runStartedAt = nil
    if ns.UI then ns.UI.Refresh() end
end

-- Totals for one tab ("ALL" merges every category and adds coin, costs and kills)
function ns.GetTotals(tab)
    local s = ns.char.session
    if tab ~= "ALL" then
        local c = s.cats[tab]
        return { coin = 0, costs = 0, kills = 0, value = c.value, count = c.count, priciest = c.priciest, priciestLink = c.priciestLink }
    end
    local t = { coin = s.coin, costs = s.costs, kills = math.max(s.kills, s.lootedMobs or 0), ahValue = s.ahValue, value = 0, count = 0, priciest = 0 }
    for _, key in ipairs(ns.CATEGORIES) do
        local c = s.cats[key]
        t.value = t.value + c.value
        t.count = t.count + c.count
        if c.priciest > t.priciest then t.priciest, t.priciestLink = c.priciest, c.priciestLink end
    end
    return t
end

-- Estimated per-hour rate over the whole session; nil until there's enough time to go on
-- (a 50s drop 2 seconds in would otherwise read as ~900g/h)
local GPH_MIN_SECONDS = 120
function ns.GetPerHour(amount)
    local elapsed = ns.GetElapsed()
    if elapsed < GPH_MIN_SECONDS then return nil end
    return amount * 3600 / elapsed
end

-- Minutes until the bags are full at this session's fill rate, or nil without enough data
function ns.GetBagsFullMinutes(free)
    local s = ns.char.session
    local elapsed = ns.GetElapsed()
    if elapsed < GPH_MIN_SECONDS or s.slotsUsed <= 0 then return nil end
    return free / (s.slotsUsed / elapsed) / 60
end

-- =============================================================
-- Ignore list
-- =============================================================
local CLASS_QUEST = 12

function ns.IsIgnored(link)
    local id, _, _, _, _, classID = Compat.GetItemInfoInstant(link)
    if not id then return false end
    return ns.db.ignore[id] or (ns.db.ignoreQuestItems and classID == CLASS_QUEST) or false
end

local function ItemText(id)
    local _, link = Compat.GetItemInfo(id)
    return link or string.format(L["item %d"], id)
end

-- Never record this item again and take it out of the current session
function ns.Ignore(linkOrID)
    local id = Compat.GetItemInfoInstant(linkOrID)
    if not id then return end
    ns.db.ignore[id] = true
    local remove = {}
    for _, e in ipairs(ns.char.session.entries) do
        if Compat.GetItemInfoInstant(e.link) == id then remove[#remove + 1] = e.id end
    end
    for _, entryID in ipairs(remove) do ns.RemoveEntry(entryID) end
    ns.Print(string.format(L["Ignoring %s. Undo with /slt unignore %d"], ItemText(id), id))
end

-- =============================================================
-- Report
-- =============================================================
function ns.ReportLine()
    local t = ns.GetTotals("ALL")
    local net = t.coin + t.value - t.costs
    local secs = math.floor(ns.GetElapsed())
    local zone = GetRealZoneText and GetRealZoneText() or ""
    local line = string.format(L["Loot Tracker: %dh %02dm"], math.floor(secs / 3600), math.floor((secs % 3600) / 60))
    if zone ~= "" then line = line .. string.format(L[" in %s"], zone) end
    line = line .. ", " .. Compat.FormatMoneyPlain(net)
    local per = ns.GetPerHour(net)
    if per then line = line .. string.format(L[" (%s per hour)"], Compat.FormatMoneyPlain(per)) end
    if t.priciestLink then line = line .. string.format(L[", best drop %s"], t.priciestLink) end
    return line
end

local CHANNELS = {
    s = "SAY", say = "SAY", p = "PARTY", party = "PARTY", g = "GUILD", guild = "GUILD",
    r = "RAID", raid = "RAID", i = "INSTANCE_CHAT", instance = "INSTANCE_CHAT", w = "WHISPER", whisper = "WHISPER",
}

local function Report(rest)
    local where, target = rest:match("^(%S*)%s*(.-)$")
    where = (where or ""):lower()
    local line = ns.ReportLine()
    local chatType = CHANNELS[where]
    if where == "" then
        -- No channel: your group if you're in one, otherwise just you
        chatType = (IsInRaid and IsInRaid()) and "RAID" or ((IsInGroup and IsInGroup()) and "PARTY" or nil)
    elseif not chatType and where ~= "self" then
        ns.Print(L["Unknown channel. Use say, party, guild, raid, instance, w <name> or self."])
        return
    end
    if not chatType then ns.Print(line) return end
    if chatType == "WHISPER" and target == "" then ns.Print(L["Usage: /slt report w <name>"]) return end
    local ok = pcall(Compat.SendChatMessage, line, chatType, nil, chatType == "WHISPER" and target or nil)
    if not ok then ns.Print(string.format(L["Couldn't send that to %s. %s"], where, line)) end
end

-- =============================================================
-- Load / save
-- =============================================================
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:RegisterEvent("PLAYER_FLAGS_CHANGED")
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        SharpiesLootTrackerDB = SharpiesLootTrackerDB or {}
        SharpiesLootTrackerCharDB = SharpiesLootTrackerCharDB or {}
        ApplyDefaults(SharpiesLootTrackerDB, ACCOUNT_DEFAULTS)
        ApplyDefaults(SharpiesLootTrackerCharDB, CHAR_DEFAULTS)
        ns.db = SharpiesLootTrackerDB
        ns.char = SharpiesLootTrackerCharDB
        -- 0.1.2: move anyone still on the old "dbmarket" default to the new one (once only,
        -- so choosing dbmarket again with /slt tsm sticks)
        if not ns.db.tsmDefaultMoved then
            if ns.db.tsmPriceString == "dbmarket" then ns.db.tsmPriceString = ACCOUNT_DEFAULTS.tsmPriceString end
            ns.db.tsmDefaultMoved = true
        end
        if type(ns.char.session) ~= "table" then ns.char.session = ns.NewSession() end
        local s = ns.char.session
        -- Carry a session from before 0.2.0 over to the renamed categories
        for old, new in pairs(RENAMED) do
            if s.cats and s.cats[old] then s.cats[new], s.cats[old] = s.cats[old], nil end
        end
        for _, e in ipairs(s.entries or {}) do e.category = RENAMED[e.category] or e.category end
        ns.char.window.tab = RENAMED[ns.char.window.tab] or ns.char.window.tab
        if s.ahValue == nil and s.entries then
            -- Best estimate from the rows still listed
            s.ahValue = 0
            for _, e in ipairs(s.entries) do if e.source ~= "vendor" then s.ahValue = s.ahValue + e.value end end
        end
        ApplyDefaults(s, ns.NewSession()) -- fields added in later versions
        -- A session left running at logout resumes, but offline time isn't counted
        if ns.char.session.running then ns.runStartedAt, ns.lastLootAt = GetTime(), GetTime() end
        -- Idle check; runs whether or not the window is shown
        C_Timer.NewTicker(5, function()
            local idle = ns.db.idleMinutes
            if ns.char.session.running and idle > 0 and ns.lastLootAt and GetTime() - ns.lastLootAt >= idle * 60 then
                ns.AutoPause(string.format(L["nothing looted for %s min"], idle))
            end
        end)
        if ns.UI then ns.UI.Create() end
        loader:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_FLAGS_CHANGED" and ns.char then
        if arg1 == "player" and ns.db.idleMinutes > 0 and UnitIsAFK("player") then ns.AutoPause(L["AFK"]) end
    elseif event == "PLAYER_LOGOUT" and ns.char then
        ns.char.session.elapsed = ns.GetElapsed()
        ns.runStartedAt = nil
    end
end)

-- =============================================================
-- Slash commands
-- =============================================================
local SOURCES = { auto = true, tsm = true, auctionator = true, auctioneer = true, vendor = true }

-- From the window's picker and /slt source
function ns.SetPriceSource(key)
    ns.db.priceSource = key
    ns.Print(string.format(L["Price source: %s (applies to new loot)"], key))
    if ns.UI then ns.UI.RefreshSource() end
end

-- on / off for a setting in chat
local function OnOff(v) return v and L["on"] or L["off"] end

local function Help()
    ns.Print(string.format(L["v%s commands:"], ns.VERSION))
    print("  " .. L["/slt - show/hide the window"])
    print("  " .. L["/slt compact - switch between the full window and a one-line bar (or double-click the header)"])
    print("  /slt start | pause | reset")
    print("  " .. L["/slt report [say|party|guild|raid|instance|w <name>|self] - post a session summary"])
    print("  " .. string.format(L["/slt source auto|tsm|auctionator|auctioneer|vendor - where item prices come from (now: %s)"], ns.db.priceSource))
    print("  " .. string.format(L["/slt tsm <price string>|default - any TSM custom price (now: %s)"], ns.db.tsmPriceString))
    print("  " .. string.format(L["/slt vendorfloor - toggle never valuing an item below its vendor price (now: %s)"], OnOff(ns.db.neverBelowVendor)))
    print("  " .. string.format(L["/slt questgold - toggle counting quest reward gold (now: %s)"], OnOff(ns.db.countQuestMoney)))
    print("  " .. string.format(L["/slt autostart - toggle starting a session on the first loot (now: %s)"], OnOff(ns.db.autoStart)))
    print("  " .. string.format(L["/slt idle <minutes> - pause after this long without loot or on AFK, 0 = off (now: %s)"], ns.db.idleMinutes))
    print("  " .. string.format(L["/slt costs - toggle taking vendor spending (repairs, food, ammo) off the total (now: %s)"], OnOff(ns.db.countCosts)))
    print("  " .. string.format(L["/slt alert <gold> - alert for drops worth at least this each, 0 = off (now: %s)"], Compat.FormatMoneyPlain(ns.db.alertValue)))
    print("  " .. string.format(L["/slt stale <days> - mark Auctionator prices older than this (now: %s)"], ns.db.staleDays))
    print("  " .. L["/slt ignore [item|clear] - ignore an item, list ignored items, or clear the list"])
    print("  " .. L["/slt unignore <item> - stop ignoring an item (link or item ID)"])
    print("  " .. string.format(L["/slt questitems - toggle ignoring quest items (now: %s)"], OnOff(ns.db.ignoreQuestItems)))
end

-- Item ID from a pasted link or a plain number
local function ParseItem(text)
    return tonumber(text:match("item:(%d+)") or text:match("^%s*(%d+)%s*$"))
end

SLASH_SHARPIESLOOTTRACKER1 = "/slt"
SLASH_SHARPIESLOOTTRACKER2 = "/loottracker"
SlashCmdList.SHARPIESLOOTTRACKER = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ns.UI.SetShown(not ns.UI.IsShown())
    elseif cmd == "show" then ns.UI.SetShown(true)
    elseif cmd == "hide" then ns.UI.SetShown(false)
    elseif cmd == "compact" then ns.UI.SetCompact(not ns.char.window.compact)
    elseif cmd == "start" then ns.Start()
    elseif cmd == "pause" or cmd == "stop" then ns.Pause()
    elseif cmd == "reset" then ns.Reset()
    elseif cmd == "report" then Report(rest)
    elseif cmd == "source" then
        rest = rest:lower()
        if SOURCES[rest] then
            ns.SetPriceSource(rest)
        else
            ns.Print(L["Unknown source. Use auto, tsm, auctionator, auctioneer or vendor."])
        end
    elseif cmd == "tsm" then
        if rest:lower() == "default" then rest = ACCOUNT_DEFAULTS.tsmPriceString end
        if rest ~= "" then
            -- Any TSM custom price works; check it with TSM when it's loaded
            local ok, valid, err = true, true, nil
            if TSM_API and TSM_API.IsCustomPriceValid then
                ok, valid, err = pcall(TSM_API.IsCustomPriceValid, rest)
            end
            if ok and not valid then
                ns.Print(string.format(L["TSM rejected that price string%s. Kept: %s"], err and (": " .. tostring(err)) or "", ns.db.tsmPriceString))
                return
            end
            ns.db.tsmPriceString = rest
        end
        ns.Print(string.format(L["TSM price string: %s (applies to new loot)"], ns.db.tsmPriceString))
    elseif cmd == "vendorfloor" then
        ns.db.neverBelowVendor = not ns.db.neverBelowVendor
        ns.Print(string.format(L["Never below vendor price: %s"], OnOff(ns.db.neverBelowVendor)))
    elseif cmd == "questgold" then
        ns.db.countQuestMoney = not ns.db.countQuestMoney
        ns.Print(string.format(L["Count quest reward gold: %s"], OnOff(ns.db.countQuestMoney)))
    elseif cmd == "autostart" then
        ns.db.autoStart = not ns.db.autoStart
        ns.Print(string.format(L["Start a session on the first loot: %s"], OnOff(ns.db.autoStart)))
    elseif cmd == "idle" then
        local n = tonumber(rest)
        if n and n >= 0 then ns.db.idleMinutes = n end
        ns.Print(string.format(L["Idle pause: %s"], ns.db.idleMinutes > 0 and string.format(L["%s min without loot, or AFK"], ns.db.idleMinutes) or L["off"]))
    elseif cmd == "costs" then
        ns.db.countCosts = not ns.db.countCosts
        ns.Print(string.format(L["Take vendor spending off the total: %s"], OnOff(ns.db.countCosts)))
    elseif cmd == "alert" then
        local g = tonumber(rest)
        if g and g >= 0 then ns.db.alertValue = math.floor(g * 10000 + 0.5) end
        ns.Print(string.format(L["Drop alert: %s"], ns.db.alertValue > 0 and string.format(L["%s or more each"], Compat.FormatMoneyPlain(ns.db.alertValue)) or L["off"]))
    elseif cmd == "stale" then
        local n = tonumber(rest)
        if n and n > 0 then ns.db.staleDays = n end
        ns.Print(string.format(L["Auctionator prices older than %s days are marked"], ns.db.staleDays))
    elseif cmd == "questitems" then
        ns.db.ignoreQuestItems = not ns.db.ignoreQuestItems
        ns.Print(string.format(L["Ignore quest items: %s"], OnOff(ns.db.ignoreQuestItems)))
    elseif cmd == "ignore" then
        if rest:lower() == "clear" then
            wipe(ns.db.ignore)
            ns.Print(L["Ignore list cleared"])
        elseif ParseItem(rest) then
            ns.Ignore(ParseItem(rest))
        else
            local any = false
            for id in pairs(ns.db.ignore) do
                if not any then ns.Print(L["Ignored items:"]) any = true end
                print("  " .. ItemText(id) .. " (" .. id .. ")")
            end
            if not any then ns.Print(L["No ignored items. Ctrl-right-click a row in the list to ignore an item."]) end
        end
    elseif cmd == "unignore" then
        local id = ParseItem(rest)
        if id and ns.db.ignore[id] then
            ns.db.ignore[id] = nil
            ns.Print(string.format(L["No longer ignoring %s"], ItemText(id)))
        else
            ns.Print(L["That item isn't ignored. /slt ignore lists them."])
        end
    else
        Help()
    end
end
