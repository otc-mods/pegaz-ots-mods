-- Shared hunting state: attack mode, AoE player safety, equip-in-progress flag.
Hunt = {}

local MODES = { aoe = true, single = true, rule = true }
if not MODES[storage.attackMode] then storage.attackMode = "aoe" end
if type(storage.aoeSafeRange) ~= "number" then storage.aoeSafeRange = 4 end

Hunt.attackMode = function() return storage.attackMode end
Hunt.setAttackMode = function(mode) if MODES[mode] then storage.attackMode = mode end end

local function isPartyMember(c)
  return c:getShield() > 2 -- 0 none, 1/2 invite pending, 3+ in party
end

-- players (not you, not party) within range sqm of you
Hunt.playersNear = function(range)
  local n = 0
  for _, c in ipairs(g_map.getSpectatorsInRange(player:getPosition(), false, range, range)) do
    if c:isPlayer() and not c:isLocalPlayer() and not isPartyMember(c) then n = n + 1 end
  end
  return n
end

Hunt.monstersNear = function(range)
  local n = 0
  for _, c in ipairs(g_map.getSpectatorsInRange(player:getPosition(), false, range, range)) do
    if c:isMonster() then n = n + 1 end
  end
  return n
end

Hunt.aoeSafeRange = function() return storage.aoeSafeRange end
Hunt.setAoeSafeRange = function(v) storage.aoeSafeRange = math.max(0, math.min(8, v)) end

Hunt.aoeAllowed = function()
  return storage.aoeSafeRange == 0 or Hunt.playersNear(storage.aoeSafeRange) == 0
end

local equipPendingUntil = 0
Hunt.setEquipPending = function(untilTime) equipPendingUntil = untilTime end
Hunt.isEquipPending = function() return equipPendingUntil > now end

-- equip notifications: the Equip feature reports a landed equip, icons re-count while the worn item is fresh
local equipListeners = {}
Hunt.onEquipped = function(fn) table.insert(equipListeners, fn) end
Hunt.fireEquipped = function(itemId) for _, fn in ipairs(equipListeners) do fn(itemId) end end
-- a take-off landed: the piece is back in the bag (icons add one to their running count)
local unequipListeners = {}
Hunt.onUnequipped = function(fn) table.insert(unequipListeners, fn) end
Hunt.fireUnequipped = function(itemId) for _, fn in ipairs(unequipListeners) do fn(itemId) end end

-- last attacked PLAYER, remembered after the attack drops (the exiva-target icon uses it). The player-info
-- module renames other players to "[RP 250] Name", so the original name it keeps is preferred.
Hunt.lastTargetName = nil
onAttackingCreatureChange(function(creature)
  if creature and creature:isPlayer() and not creature:isLocalPlayer() then
    Hunt.lastTargetName = creature.playerInfoName or creature:getName()
  end
end)

-- equip probes: before an empty-slot equip the Equip feature may "use" the item once so the server prints the
-- count of fresh spares (it searches the bags when the slot is empty). Icons register which items they track.
local probeWanted = {}
Hunt.wantEquipProbe = function(itemId, wanted) probeWanted[itemId] = wanted and true or nil end
Hunt.equipProbeWanted = function(itemId) return probeWanted[itemId] == true end
local probeListeners = {}
Hunt.onEquipProbe = function(fn) table.insert(probeListeners, fn) end
Hunt.fireEquipProbe = function(itemId) for _, fn in ipairs(probeListeners) do fn(itemId) end end

-- Attack spells can be turned off while targeting keeps running: same walking, same targets, no casting.
if storage.attackSpells == nil then storage.attackSpells = true end
Hunt.spellsOn = function() return storage.attackSpells ~= false end
Hunt.setSpellsOn = function(v) storage.attackSpells = v and true or false end
