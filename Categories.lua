local _, ns = ...
local Compat = ns.Compat

-- Item class IDs are the same on every client (Enum.ItemClass isn't everywhere)
local CLASS_WEAPON, CLASS_GEM, CLASS_ARMOR, CLASS_REAGENT, CLASS_TRADEGOODS = 2, 3, 4, 5, 7

local NON_EQUIP = { [""] = true, INVTYPE_NON_EQUIP = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BAG = true }

-- Returns "JUNK" | "GEAR" | "MATS" | "OTHER", or nil if the item isn't cached yet.
-- Mats = cloth, herbs, ore, leather, gems, reagents, elemental, enchanting (trade goods);
-- Other = recipes, potions, food, containers and the rest.
function ns.Categorize(link)
    local name, _, quality, _, _, _, _, _, equipLoc, _, _, classID = Compat.GetItemInfo(link)
    if not name or quality == nil then return nil end
    if quality == 0 then return "JUNK" end
    if (classID == CLASS_WEAPON or classID == CLASS_ARMOR) and not NON_EQUIP[equipLoc or ""] then return "GEAR" end
    if classID == CLASS_TRADEGOODS or classID == CLASS_REAGENT or classID == CLASS_GEM then return "MATS" end
    return "OTHER"
end
