local ADDON, ns = ...
local Compat = ns.Compat

local Pricing = {}
ns.Pricing = Pricing

local BIND_ON_PICKUP = 1

-- Each source returns a per-item copper value, or nil when it has no price
local SOURCES = {
    tsm = function(link)
        if not (TSM_API and TSM_API.GetCustomPriceValue and TSM_API.ToItemString) then return nil end
        local ok, itemString = pcall(TSM_API.ToItemString, link)
        if not ok or not itemString then return nil end
        local ok2, value = pcall(TSM_API.GetCustomPriceValue, ns.db.tsmPriceString, itemString)
        return ok2 and value or nil
    end,
    auctionator = function(link)
        local api = Auctionator and Auctionator.API and Auctionator.API.v1
        if not (api and api.GetAuctionPriceByItemLink) then return nil end
        local ok, value = pcall(api.GetAuctionPriceByItemLink, ADDON, link)
        return ok and value or nil
    end,
    auctioneer = function(link)
        local api = AucAdvanced and AucAdvanced.API
        if not (api and api.GetMarketValue) then return nil end
        local ok, value = pcall(api.GetMarketValue, link)
        return ok and value or nil
    end,
}
local AUTO_ORDER = { "tsm", "auctionator", "auctioneer" }

local function GetAuctionValue(link)
    local choice = ns.db.priceSource
    if choice == "vendor" then return nil end
    if SOURCES[choice] then
        local v = SOURCES[choice](link)
        if v and v > 0 then return v, choice end
        return nil
    end
    for _, key in ipairs(AUTO_ORDER) do
        local v = SOURCES[key](link)
        if v and v > 0 then return v, key end
    end
    return nil
end

-- Days since the price was last seen. Only Auctionator offers this; TSM and Auctioneer
-- don't expose a scan age through their APIs.
local function GetPriceAge(link, source)
    if source ~= "auctionator" then return nil end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionAgeByItemLink) then return nil end
    local ok, days = pcall(api.GetAuctionAgeByItemLink, ADDON, link)
    return ok and type(days) == "number" and days or nil
end

-- Per-item value in copper, the source used ("vendor", "tsm", ...) and the price's age in
-- days when the source reports one
function Pricing.GetUnitValue(link, category)
    local _, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = Compat.GetItemInfo(link)
    local vendor = sellPrice or 0
    if category == "JUNK" then return vendor, "vendor" end
    if ns.db.soulboundAsVendor and bindType == BIND_ON_PICKUP then return vendor, "vendor" end

    local ah, source = GetAuctionValue(link)
    if not ah then return vendor, "vendor" end
    if ns.db.neverBelowVendor and vendor > ah then return vendor, "vendor" end
    return ah, source, GetPriceAge(link, source)
end
