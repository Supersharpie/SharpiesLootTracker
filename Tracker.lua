local _, ns = ...
local Compat = ns.Compat

-- =============================================================
-- Chat patterns, built from the client's own localized strings
-- =============================================================
local ITEM_PATTERNS = {}
for _, key in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF" }) do
    local p = Compat.FormatToPattern(_G[key])
    if p then ITEM_PATTERNS[#ITEM_PATTERNS + 1] = p end
end

-- "12 Gold" style pieces; the loot message joins them with commas
local COIN_PATTERNS = {}
for key, mult in pairs({ GOLD_AMOUNT = 10000, SILVER_AMOUNT = 100, COPPER_AMOUNT = 1 }) do
    local fmt = _G[key]
    if type(fmt) == "string" then
        local p = Compat.FormatToPattern(fmt)
        if p then COIN_PATTERNS[#COIN_PATTERNS + 1] = { p:sub(2, -2), mult } end -- unanchored
    end
end

local function ParseItemMessage(msg)
    for _, pattern in ipairs(ITEM_PATTERNS) do
        local a, b = msg:match(pattern)
        if a then
            -- Some locales put the count before the link
            local link, qty = a, b
            if not a:find("|H", 1, true) then link, qty = b, a end
            if link and link:find("|Hitem:", 1, true) then
                return link, tonumber(qty) or 1
            end
        end
    end
end

local function ParseMoneyMessage(msg)
    local total = 0
    for _, entry in ipairs(COIN_PATTERNS) do
        local n = msg:match(entry[1])
        if n then total = total + tonumber(n) * entry[2] end
    end
    return total
end

-- =============================================================
-- Recording
-- =============================================================
-- s is the session that was running when the item was looted, so a late item still lands
-- even if the session was paused in between (and goes nowhere if it was reset)
local function Record(s, link, qty)
    -- Info should be cached by now; if the server never answered, count it rather than lose it
    local category = ns.Categorize(link) or "OTHER"

    local unit, source, age = ns.Pricing.GetUnitValue(link, category)
    local total = unit * qty
    local cat = s.cats[category]
    cat.value = cat.value + total
    cat.count = cat.count + qty
    if unit > cat.priciest then cat.priciest, cat.priciestLink = unit, link end
    if source ~= "vendor" then s.ahValue = s.ahValue + total end

    s.entries[#s.entries + 1] = {
        id = s.nextId, link = link, qty = qty, unit = unit, value = total,
        category = category, source = source, age = age, time = time(),
    }
    s.nextId = s.nextId + 1
    -- The list is capped; dropped rows stay counted in the totals
    while #s.entries > ns.db.maxEntries do table.remove(s.entries, 1) end

    if ns.db.alertValue > 0 and unit >= ns.db.alertValue then
        ns.Alert("Big drop: " .. link .. (qty > 1 and (" x" .. qty) or "") .. " (" .. Compat.FormatMoney(unit) .. " each)")
    end

    if ns.UI then ns.UI.Refresh() end
end

local function RecordWhenLoaded(s, link, qty, attempt)
    if ns.Categorize(link) then Record(s, link, qty) return end
    -- Item info not cached yet: wait for the server instead of giving up after a few tries
    if Item and Item.CreateFromItemLink then
        Item:CreateFromItemLink(link):ContinueOnItemLoad(function() Record(s, link, qty) end)
        return
    end
    attempt = (attempt or 0) + 1
    if attempt > 20 then Record(s, link, qty) return end
    C_Timer.After(0.5, function() RecordWhenLoaded(s, link, qty, attempt) end)
end

function ns.RemoveEntry(id)
    local s = ns.char.session
    for i, e in ipairs(s.entries) do
        if e.id == id then
            local cat = s.cats[e.category]
            cat.value = math.max(0, cat.value - e.value)
            cat.count = math.max(0, cat.count - e.qty)
            if e.source ~= "vendor" then s.ahValue = math.max(0, s.ahValue - e.value) end
            table.remove(s.entries, i)
            -- Recompute the priciest from what's still listed
            cat.priciest, cat.priciestLink = 0, nil
            for _, other in ipairs(s.entries) do
                if other.category == e.category and other.unit > cat.priciest then
                    cat.priciest, cat.priciestLink = other.unit, other.link
                end
            end
            break
        end
    end
    if ns.UI then ns.UI.Refresh() end
end

-- =============================================================
-- Events
-- =============================================================
-- Items bought, mailed or traded arrive as "You receive item:" too; ignore them while
-- one of those windows is open.
local blockers = {}
local BLOCK_OPEN = {
    MERCHANT_SHOW = "merchant", MAIL_SHOW = "mail", TRADE_SHOW = "trade",
    AUCTION_HOUSE_SHOW = "auction", BANKFRAME_OPENED = "bank", GUILDBANKFRAME_OPENED = "guildbank",
}
local BLOCK_CLOSE = {
    MERCHANT_CLOSED = "merchant", MAIL_CLOSED = "mail", TRADE_CLOSED = "trade",
    AUCTION_HOUSE_CLOSED = "auction", BANKFRAME_CLOSED = "bank", GUILDBANKFRAME_CLOSED = "guildbank",
}

-- Quest gold comes from QUEST_TURNED_IN. If a client also posts it as a money message,
-- both arrive together with the same amount, so the second one is skipped.
local lastCoin = { amount = 0, time = 0, source = nil }
local function AddCoin(copper, source)
    local now = GetTime()
    if lastCoin.source and lastCoin.source ~= source and lastCoin.amount == copper and now - lastCoin.time < 1 then
        lastCoin.source = nil
        return
    end
    lastCoin.amount, lastCoin.time, lastCoin.source = copper, now, source
    if ns.EnsureRunning() then
        ns.char.session.coin = ns.char.session.coin + copper
        if ns.UI then ns.UI.Refresh() end
    end
end

-- Loot that comes out of an item (disenchant, prospect, mill, opening a clam or lockbox)
-- was already counted when that item was looted. While the loot window is open, note which
-- items come from an item source, then skip that many matching loot lines.
local fromItem = {}     -- itemID -> { count = lines to skip, expires = GetTime() }
local seenInWindow = {} -- itemID -> slots already noted for the open loot window
local SKIP_SECONDS = 10

local function NoteItemSourcedLoot()
    if not (GetNumLootItems and GetLootSlotLink and GetLootSourceInfo) then return end
    local counts = {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink(slot)
        local guid = GetLootSourceInfo(slot)
        if link and Compat.IsReadableString(guid) and guid:find("^Item%-") then
            local id = Compat.GetItemInfoInstant(link)
            if id then counts[id] = (counts[id] or 0) + 1 end
        end
    end
    -- LOOT_READY and LOOT_OPENED can both fire for one window; only add what's new
    local expires = GetTime() + SKIP_SECONDS
    for id, n in pairs(counts) do
        local added = n - (seenInWindow[id] or 0)
        if added > 0 then
            local e = fromItem[id]
            if not e or e.expires < GetTime() then e = { count = 0 }; fromItem[id] = e end
            e.count, e.expires = e.count + added, expires
            seenInWindow[id] = n
        end
    end
end

local function SkipItemSourced(link)
    local id = Compat.GetItemInfoInstant(link)
    local e = id and fromItem[id]
    if not e then return false end
    if e.expires < GetTime() or e.count <= 0 then fromItem[id] = nil return false end
    e.count = e.count - 1
    return true
end

-- Session that's being farmed: running, or paused partway (idle trips to a vendor still count)
local function ActiveSession()
    local s = ns.char and ns.char.session
    if s and (s.running or s.elapsed > 0) then return s end
end

-- Vendor spending: any drop in money while a merchant is open (repairs, food, ammo, reagents).
-- Guild-bank repairs don't touch your money, so they're rightly left out.
local moneyAtVendor
local function NoteVendorSpending()
    local now = GetMoney()
    local s = ActiveSession()
    if moneyAtVendor and now < moneyAtVendor and s and ns.db.countCosts then
        s.costs = s.costs + (moneyAtVendor - now)
        if ns.UI then ns.UI.Refresh() end
    end
    moneyAtVendor = now
end

-- Kills: your group's killing blows on NPCs, while the session runs
local function NoteKill()
    if not CombatLogGetCurrentEventInfo then return end
    local _, sub, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
    if sub ~= "PARTY_KILL" or not Compat.IsReadableString(destGUID) then return end
    local s = ns.char and ns.char.session
    if s and s.running and (destGUID:find("^Creature%-") or destGUID:find("^Vehicle%-")) then
        s.kills = s.kills + 1
    end
end

-- Bag fill rate: count slots that fill up while farming (not while shopping or at the bank)
local lastFree
local function NoteBagSlots()
    local free = Compat.GetFreeBagSlots()
    local s = ns.char and ns.char.session
    if lastFree and free < lastFree and s and s.running and not next(blockers) then
        s.slotsUsed = s.slotsUsed + (lastFree - free)
        if free == 0 then ns.Alert("Bags full!") end
    end
    lastFree = free
    if ns.UI then ns.UI.RefreshStats() end
end
function ns.GetFreeBagSlots()
    if not lastFree then lastFree = Compat.GetFreeBagSlots() end
    return lastFree
end

local tracker = CreateFrame("Frame")
local function SafeRegister(event) pcall(tracker.RegisterEvent, tracker, event) end
SafeRegister("CHAT_MSG_LOOT")
SafeRegister("CHAT_MSG_MONEY")
SafeRegister("QUEST_TURNED_IN")
SafeRegister("PLAYER_ENTERING_WORLD")
SafeRegister("LOOT_READY")
SafeRegister("LOOT_OPENED")
SafeRegister("LOOT_CLOSED")
SafeRegister("PLAYER_MONEY")
SafeRegister("BAG_UPDATE_DELAYED")
SafeRegister("COMBAT_LOG_EVENT_UNFILTERED")
for event in pairs(BLOCK_OPEN) do SafeRegister(event) end
for event in pairs(BLOCK_CLOSE) do SafeRegister(event) end

tracker:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then NoteKill() return end
    if BLOCK_OPEN[event] then
        blockers[BLOCK_OPEN[event]] = true
        if event == "MERCHANT_SHOW" then moneyAtVendor = GetMoney() end
        return
    end
    if BLOCK_CLOSE[event] then
        blockers[BLOCK_CLOSE[event]] = nil
        if event == "MERCHANT_CLOSED" then moneyAtVendor = nil end
        return
    end
    -- Loading screens close every window; clear any close event we missed (e.g. a disconnect)
    if event == "PLAYER_ENTERING_WORLD" then wipe(blockers) moneyAtVendor = nil NoteBagSlots() return end
    if event == "LOOT_READY" or event == "LOOT_OPENED" then NoteItemSourcedLoot() return end
    if event == "LOOT_CLOSED" then wipe(seenInWindow) return end
    if event == "BAG_UPDATE_DELAYED" then NoteBagSlots() return end
    if event == "PLAYER_MONEY" then
        if blockers.merchant then NoteVendorSpending() end
        return
    end
    if not ns.char then return end

    if event == "CHAT_MSG_LOOT" then
        if next(blockers) or not Compat.IsReadableString(arg1) then return end
        local link, qty = ParseItemMessage(arg1)
        if not link or SkipItemSourced(link) or ns.IsIgnored(link) then return end
        if ns.EnsureRunning() then RecordWhenLoaded(ns.char.session, link, qty) end
    elseif event == "CHAT_MSG_MONEY" then
        if not Compat.IsReadableString(arg1) then return end
        local copper = ParseMoneyMessage(arg1)
        if copper > 0 then AddCoin(copper, "loot") end
    elseif event == "QUEST_TURNED_IN" then
        -- args: questID, xpReward, moneyReward
        if ns.db.countQuestMoney and type(arg3) == "number" and arg3 > 0 then AddCoin(arg3, "quest") end
    end
end)
