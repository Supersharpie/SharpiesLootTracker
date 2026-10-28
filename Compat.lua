-- Cross-client shims. Every client this addon loads on (Era, Forever, TBC/Anniversary,
-- Wrath, Cata, Mists, Retail) runs the modern engine, but a handful of APIs moved
-- into C_ namespaces or were renamed along the way.
local _, ns = ...

local Compat = {}
ns.Compat = Compat

local floor = math.floor

Compat.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
Compat.GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
Compat.IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
Compat.SendChatMessage = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

-- Free slots in the backpack and equipped general bags (not profession or reagent bags)
local GetFreeSlots = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
function Compat.GetFreeBagSlots()
    local free = 0
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local n, family = GetFreeSlots(bag)
        if n and (family or 0) == 0 then free = free + n end
    end
    return free
end

function Compat.SetResizeBounds(frame, minW, minH, maxW, maxH)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(minW, minH, maxW, maxH)
    elseif frame.SetMinResize then
        frame:SetMinResize(minW, minH)
        if maxW and frame.SetMaxResize then frame:SetMaxResize(maxW, maxH) end
    end
end

-- Chat text can be a protected "secret" value on newer clients; touching it errors.
-- issecretvalue isn't on every build, so fall back to canaccessvalue, then a protected compare.
local _issecret, _canaccess = issecretvalue, canaccessvalue
function Compat.IsReadableString(v)
    if type(v) ~= "string" then return false end
    if _issecret then return not _issecret(v) end
    if _canaccess then return _canaccess(v) and true or false end
    return (pcall(function() return v == "" end))
end

-- Coin text in the same style as the mockup: 12g 05s 03c, with colored unit letters.
local GOLD, SILVER, COPPER = "|cffffd700g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
local function Group(n)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    return tostring(n)
end

function Compat.FormatMoney(copper)
    copper = floor((copper or 0) + 0.5)
    local negative = copper < 0
    if negative then copper = -copper end
    local g = floor(copper / 10000)
    local s = floor((copper % 10000) / 100)
    local c = copper % 100
    local text
    if g > 0 then
        text = string.format("%s%s %02d%s %02d%s", Group(g), GOLD, s, SILVER, c, COPPER)
    elseif s > 0 then
        text = string.format("%d%s %02d%s", s, SILVER, c, COPPER)
    else
        text = string.format("%d%s", c, COPPER)
    end
    return negative and ("-" .. text) or text
end

-- Same without color codes, for chat messages: 12g 5s 3c (zero parts left out)
function Compat.FormatMoneyPlain(copper)
    copper = floor((copper or 0) + 0.5)
    local negative = copper < 0
    if negative then copper = -copper end
    local g, s, c = floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return (negative and "-" or "") .. table.concat(parts, " ")
end

function Compat.FormatTime(seconds)
    seconds = floor(seconds or 0)
    return string.format("%02d:%02d:%02d", floor(seconds / 3600), floor((seconds % 3600) / 60), seconds % 60)
end

-- Turns a GlobalStrings format ("You receive loot: %sx%d.") into a Lua pattern with
-- captures. Handles positional forms (%1$s) that some locales use.
function Compat.FormatToPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    -- Swap the format tokens for placeholders first so escaping can't touch them
    local pattern = fmt:gsub("%%%d%$s", "\1"):gsub("%%%d%$d", "\2"):gsub("%%s", "\1"):gsub("%%d", "\2")
    pattern = pattern:gsub("([%%%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
    pattern = pattern:gsub("\1", "(.+)"):gsub("\2", "(%%d+)")
    return "^" .. pattern .. "$"
end
