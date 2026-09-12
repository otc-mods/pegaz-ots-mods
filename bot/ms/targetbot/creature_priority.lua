TargetBot.Creature.calculatePriority = function(creature, config, path)
  -- config is based on creature_editor
  local priority = 0

  -- extra priority if it's current target
  if g_game.getAttackingCreature() == creature then
    priority = priority + 1
  end

  -- path may be a direction table or a plain step count
  local path_length = type(path) == "number" and path or #path

  -- "Target order" slider set: use the layered scoring instead of the stock bonuses
  local sort = tonumber(config.targetSort) or 0
  if sort > 0 then
    return TargetBot.Creature.calculateSortedPriority(creature, config, path_length, sort)
  end

  -- check if distance is fine, if not then attack only if already attacked
  if path_length > config.maxDistance then
    return priority
  end

  -- add config priority
  priority = priority + config.priority
  
  -- extra priority for close distance
  if path_length == 1 then
    priority = priority + 3
  elseif path_length <= 3 then
    priority = priority + 1
  end

  -- extra priority for low health
  if config.chase and creature:getHealthPercent() < 30 then
    priority = priority + 5
  elseif creature:getHealthPercent() < 20 then
    priority = priority + 2.5
  elseif creature:getHealthPercent() < 40 then
    priority = priority + 1.5
  elseif creature:getHealthPercent() < 60 then
    priority = priority + 0.5
  elseif creature:getHealthPercent() < 80 then
    priority = priority + 0.2
  end

  return priority
end
-- Custom target order (creature editor "Order" slider): 1 lowest HP, 2 highest HP, 3 closest, 4 farthest.
-- Layers: rule priority (x100) > shootable (in range + line of fire) > chosen order (0-50) > stickiness (5).
TargetBot.Creature.calculateSortedPriority = function(creature, config, path_length, sort)
  local priority = 0
  if g_game.getAttackingCreature() == creature then
    priority = priority + 5 -- ~10% HP or 1 tile of hysteresis, so the target does not flip every tick
  end
  local shootable = path_length <= config.maxDistance and canShoot(creature:getPosition(), config.maxDistance)
  if not shootable then
    return priority -- out of reach: only kept if already attacked and nothing shootable exists
  end
  priority = priority + config.priority * 100 + 50 -- +50: any shootable monster beats an unshootable current target
  local hp = creature:getHealthPercent()
  local steps = math.min(path_length, 10)
  if sort == 1 then
    priority = priority + (100 - hp) / 2
  elseif sort == 2 then
    priority = priority + hp / 2
  elseif sort == 3 then
    priority = priority + (10 - steps) * 5
  elseif sort == 4 then
    priority = priority + steps * 5
  end
  return priority
end
