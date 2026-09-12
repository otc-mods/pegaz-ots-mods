TargetBot.Creature.attack = function(params, targets, isLooting) -- params {config, creature, danger, priority}
  if player:isWalking() then
    lastWalk = now
  end

  local config = params.config
  local creature = params.creature
  
  if g_game.getAttackingCreature() ~= creature then
    g_game.attack(creature)
  end

  if not isLooting then -- walk only when not looting
    TargetBot.Creature.walk(creature, config, targets)
  end

  -- attacks: Hunt.attackMode() decides, spell texts / thresholds stay per creature rule
  local mana = player:getMana()
  local mode = Hunt and Hunt.attackMode() or "rule"
  local groupSpell = config.groupAttackSpell or ""
  local singleSpell = config.attackSpell or ""
  local spells = not Hunt or Hunt.spellsOn()        -- "Attack spells" switch: targeting without casting
  local wantGroup = spells and groupSpell:len() > 1 and (mode == "aoe" or (mode == "rule" and config.useGroupAttack))
  local wantSingle = spells and singleSpell:len() > 1 and (mode ~= "rule" or config.useSpellAttack)

  if wantGroup and mana > config.minManaGroup then
    local monsters = 0
    for _, c in ipairs(g_map.getSpectatorsInRange(player:getPosition(), false, config.groupAttackRadius, config.groupAttackRadius)) do
      if c:isMonster() then monsters = monsters + 1 end
    end
    if monsters >= config.groupAttackTargets and (not Hunt or Hunt.aoeAllowed()) then
      if TargetBot.sayAttackSpell(groupSpell, config.groupAttackDelay) then
        return
      end
    end
  end
  if wantSingle and mana > config.minMana then
    if TargetBot.sayAttackSpell(singleSpell, config.attackSpellDelay) then
      return
    end
  end
end

TargetBot.Creature.walk = function(creature, config, targets)
  local cpos = creature:getPosition()
  local pos = player:getPosition()
  
  local isTrapped = true
  local pos = player:getPosition()
  local dirs = {{-1,1}, {0,1}, {1,1}, {-1, 0}, {1, 0}, {-1, -1}, {0, -1}, {1, -1}}
  for i=1,#dirs do
    local tile = g_map.getTile({x=pos.x-dirs[i][1],y=pos.y-dirs[i][2],z=pos.z})
    if tile and tile:isWalkable(false) then
      isTrapped = false
    end
  end
  
  -- luring
  if TargetBot.canLure() and (config.lure or config.lureCavebot) and not (config.chase and creature:getHealthPercent() < 30) and not isTrapped then
    local monsters = 0
    if targets < config.lureCount then
      if config.lureCavebot then
        -- Only move on when the pack keeps up. "Pack" = monsters that were within
        -- lureFollowDist+1 tiles during the last 8 s; fresh monsters far ahead never hold
        -- you back, they just follow and join. Skipped when monsters are as fast as you.
        local packClose = true
        if targets > 0 and player:getSpeed() > creature:getSpeed() then
          local followDist = config.lureFollowDist or 3
          TargetBot.lurePack = TargetBot.lurePack or {}
          local pack = TargetBot.lurePack
          local close, lagging = 0, 0
          for _, c in ipairs(g_map.getSpectatorsInRange(pos, false, 7, 7)) do
            if c:isMonster() then
              local cp = c:getPosition()
              local d = math.max(math.abs(cp.x - pos.x), math.abs(cp.y - pos.y))
              local id = c:getId()
              if d <= followDist + 1 then pack[id] = now end
              if pack[id] and now - pack[id] < 8000 then
                if d <= followDist then close = close + 1 else lagging = lagging + 1 end
              end
            end
          end
          for id, t in pairs(pack) do
            if now - t > 20000 then pack[id] = nil end -- forget dead / left-behind monsters
          end
          packClose = lagging <= close -- at least half of the pack is still with you
        end
        if packClose then
          return TargetBot.allowCaveBot(200)
        end
        -- else: fall through, stand and fight this tick (avoidAttacks still applies)
      else
        local path = findPath(pos, cpos, 5, {ignoreNonPathable=true, precision=2})
        if path then
          return TargetBot.walkTo(cpos, 10, {marginMin=5, marginMax=6, ignoreNonPathable=true})
        end
      end
    end
  end

  -- radius-10 flood only when chase / keep-distance actually need it (was unconditional every tick)
  if config.chase and (creature:getHealthPercent() < 30 or not config.keepDistance) then
    local currentDistance = findPath(pos, cpos, 10, {ignoreCreatures=true, ignoreNonPathable=true, ignoreCost=true})
    if currentDistance and #currentDistance > 1 then
      return TargetBot.walkTo(cpos, 10, {ignoreNonPathable=true, precision=1})
    end
  elseif config.keepDistance then
    local currentDistance = findPath(pos, cpos, 10, {ignoreCreatures=true, ignoreNonPathable=true, ignoreCost=true})
    if currentDistance and #currentDistance ~= config.keepDistanceRange and #currentDistance ~= config.keepDistanceRange + 1 then
      return TargetBot.walkTo(cpos, 10, {ignoreNonPathable=true, marginMin=config.keepDistanceRange, marginMax=config.keepDistanceRange + 1})
    end
  end

  if config.avoidAttacks then
    local diffx = cpos.x - pos.x
    local diffy = cpos.y - pos.y
    local candidates = {}
    if math.abs(diffx) == 1 and diffy == 0 then
      candidates = {{x=pos.x, y=pos.y-1, z=pos.z}, {x=pos.x, y=pos.y+1, z=pos.z}}
    elseif diffx == 0 and math.abs(diffy) == 1 then
      candidates = {{x=pos.x-1, y=pos.y, z=pos.z}, {x=pos.x+1, y=pos.y, z=pos.z}}
    end
    for _, candidate in ipairs(candidates) do
      local tile = g_map.getTile(candidate)
      if tile and tile:isWalkable() then
        return TargetBot.walkTo(candidate, 2, {ignoreNonPathable=true})
      end
    end
  end
end
