-- Translations: ns.L["English text"] gives the client's language (Locales/<lang>.lua), or the English text itself.
local _, ns = ...

ns.L = setmetatable({}, { __index = function(_, k) return k end })
