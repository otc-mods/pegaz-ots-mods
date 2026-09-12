-- Elite knight defaults. This is the only file that differs between the shipped presets: it seeds spell words,
-- potion rows, the buff and the supply icons the first time a preset is used, and never overwrites a value
-- you have already set.
VOCATION = "ek"

local function seed(key, value)
  if storage[key] == nil then storage[key] = value end
end

-- heal spells: {on, title, text, min, max} - min/max are HP% bounds
seed("healing1", { on = false, title = "HP%", text = "exura ico", min = 51, max = 90 })
seed("healing2", { on = false, title = "HP%", text = "exura gran ico", min = 0, max = 50 })

-- potions: item ids, same bounds
seed("hpitem1", { on = false, title = "HP%", item = 266, min = 51, max = 90 })
seed("hpitem2", { on = false, title = "HP%", item = 3160, min = 0, max = 50 })
seed("manaitem1", { on = false, title = "MP%", item = 268, min = 51, max = 90 })
seed("manaitem2", { on = false, title = "MP%", item = 3157, min = 0, max = 50 })

seed("manaShield", "utamo vita")
seed("hasteSpell", "utani hur")
seed("antiParalyze", "utani hur")

-- buff slot 1 (the Buffs section on the Target tab); empty means the slot is idle
if type(storage.buffs) ~= "table" then
  storage.buffs = { { text = "utito tempo", interval = 10 }, { text = "", interval = 10 } }
end

-- supply icons, seeded by features/icons.lua
-- ids verified against this server's own item table and the shop floor, not the 8.6 defaults
VOCATION_ICONS = {
  { item = 7643, lmb = "useSelf", note = "ultimate health potion" },
  { item = 268, lmb = "useSelf", note = "mana potion" },
  { item = 3180, lmb = "crosshair", note = "magic wall rune" },
}
