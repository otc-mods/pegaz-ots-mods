-- Tools tab. Macro names match the stock config so saved on/off states carry over.
setDefaultTab("Tools")

-- The Tools tab used to be one long column of ~20 controls. Every block below declares which collapsible
-- section it belongs to; `panel` is what the bot's builders append to, so pointing it at a section body is
-- enough - no call site has to change. setDefaultTab above must stay first: it resets `panel`.
local tabPanel = panel
local function into(id, title) panel = UI.section(id, title, tabPanel) end
local function done() panel = tabPanel end

-- widgets we want to exist but not show: macros whose switch we draw ourselves, hotkeys that already have a row
local hiddenBin = UI.createWidget('Panel', tabPanel)
hiddenBin:setHeight(0)
hiddenBin:hide()

into("toolsOther", "Utility")

local moneyIds = {3031, 3035, 3043} -- gold, platinum, crystal (100 cc -> golden potato on Pegaz)
local exchangeMacro = macro(1000, "Exchange money", function()
  for _, container in pairs(g_game.getContainers()) do
    if not container.lootContainer then
      for _, item in ipairs(container:getItems()) do
        if item:getCount() == 100 then
          for _, id in ipairs(moneyIds) do
            if item:getId() == id then return g_game.use(item) end
          end
        end
      end
    end
  end
end)
Features.register{ id = "exchangeMoney", name = "Exchange $", group = "Other", macro = exchangeMacro }

local stackMacro = macro(1000, "Stack items", function()
  local toStack = {}
  for _, container in pairs(g_game.getContainers()) do
    if not container.lootContainer then
      for i, item in ipairs(container:getItems()) do
        if item:isStackable() and item:getCount() < 100 then
          local stackWith = toStack[item:getId()]
          if stackWith then
            g_game.move(item, stackWith[1], math.min(stackWith[2], item:getCount()))
            return
          end
          toStack[item:getId()] = {container:getSlotPosition(i - 1), 100 - item:getCount()}
        end
      end
    end
  end
end)
Features.register{ id = "stackItems", name = "Stack items", group = "Other", macro = stackMacro }

local antiKickMacro = macro(10000, "Anti Kick", function()
  local dir = player:getDirection()
  turn((dir + 1) % 4)
  turn(dir)
end)
Features.register{ id = "antiKick", name = "Anti kick", group = "Other", macro = antiKickMacro }

if type(storage.dropItems) ~= "table" then storage.dropItems = {283, 284, 285} end
local dropMacro = macro(5000, "drop items", "", function()
  if not storage.dropItems[1] then return end
  if TargetBot and TargetBot.isActive() then return end
  for _, container in pairs(g_game.getContainers()) do
    for _, item in ipairs(container:getItems()) do
      for _, drop in ipairs(storage.dropItems) do
        if item:getId() == drop.id then
          if item:isStackable() then
            return g_game.move(item, player:getPosition(), item:getCount())
          else
            return g_game.move(item, player:getPosition(), drop.count) -- count doubles as subtype
          end
        end
      end
    end
  end
end, hiddenBin)
Features.register{ id = "dropItems", name = "Drop items", group = "Other", macro = dropMacro }

-- magic wall / wild growth timer: callbacks are always installed, the switch gates them
if storage.mwallTimer == nil then storage.mwallTimer = true end
into("toolsPvp", "PvP")
local mwallSwitch = addSwitch("mwallTimer", "Magic wall timer", function(widget)
  storage.mwallTimer = not storage.mwallTimer
  widget:setOn(storage.mwallTimer)
end)
mwallSwitch:setOn(storage.mwallTimer)
Features.register{ id = "mwallTimer", name = "MW timer", group = "PvP", order = 5,
  isOn = function() return storage.mwallTimer end,
  setOn = function(v) storage.mwallTimer = v; mwallSwitch:setOn(v) end }

local WALLS = { [2129] = 20000, [2130] = 45000 } -- magic wall, wild growth: starting guesses only
if type(storage.wallLife) ~= "table" then storage.wallLife = {} end
local activeTimers, born, warned = {}, {}, {}

local function wallLife(id)
  local seen = storage.wallLife[tostring(id)]
  if type(seen) == "table" and tonumber(seen.min) then
    return math.max(3000, tonumber(seen.min) - 300)   -- a little slack for the round trip
  end
  return WALLS[id]
end

local function noteLife(id, ms)
  if ms < 2000 or ms > 120000 then return end
  local key = tostring(id)
  local seen = storage.wallLife[key]
  if type(seen) ~= "table" then seen = { min = ms, max = ms, n = 0 } end
  seen.min = math.min(tonumber(seen.min) or ms, ms)
  seen.max = math.max(tonumber(seen.max) or ms, ms)
  seen.n = (tonumber(seen.n) or 0) + 1
  storage.wallLife[key] = seen
end

onAddThing(function(tile, thing)
  if not storage.mwallTimer or not thing:isItem() then return end
  local timer = wallLife(thing:getId())
  if not timer then return end
  local p = tile:getPosition()
  local key = p.x .. "," .. p.y .. "," .. p.z
  if not activeTimers[key] or activeTimers[key] < now then
    activeTimers[key] = now + timer
    born[key] = { at = now, id = thing:getId() }
  end
  tile:setTimer(activeTimers[key] - now)
end)
onRemoveThing(function(tile, thing)
  if not thing:isItem() or not WALLS[thing:getId()] or not tile:getGround() then return end
  local p = tile:getPosition()
  local key = p.x .. "," .. p.y .. "," .. p.z
  local b = born[key]
  if b and b.id == thing:getId() then noteLife(b.id, now - b.at) end
  born[key] = nil
  activeTimers[key] = nil
  warned[key] = nil
  pcall(function() tile:setFill('#00000000') end)
  tile:setTimer(0)
end)

-- The client draws the countdown itself and gives no colour control over it, but a tile can be tinted:
-- red-wash a wall in its last seconds so you see it about to drop without reading the number.
local WARN_MS = 5000
macro(250, function()
  if not storage.mwallTimer then
    for key in pairs(warned) do
      local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
      local tile = x and g_map.getTile({ x = tonumber(x), y = tonumber(y), z = tonumber(z) })
      if tile then pcall(function() tile:setFill('#00000000') end) end
      warned[key] = nil
    end
    return
  end
  for key, expiry in pairs(activeTimers) do
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    local tile = x and g_map.getTile({ x = tonumber(x), y = tonumber(y), z = tonumber(z) })
    local left = expiry - now
    if tile then
      if left <= WARN_MS and left > 0 then
        if not warned[key] then
          warned[key] = true
          pcall(function() tile:setFill('#ff000055') end)
        end
      elseif warned[key] then
        warned[key] = nil
        pcall(function() tile:setFill('#00000000') end)
      end
    end
  end
end)

-- what the walls actually lasted, for when you want to see the spread rather than trust the countdown
function wallLifeReport()
  local out = {}
  for id, v in pairs(storage.wallLife) do
    out[#out + 1] = string.format("%s: shortest %.1fs, longest %.1fs, %d seen",
      id, (tonumber(v.min) or 0) / 1000, (tonumber(v.max) or 0) / 1000, tonumber(v.n) or 0)
  end
  return #out > 0 and table.concat(out, " | ") or "no walls measured yet"
end

-- auto bless. The server does not send blessings to the client (player:getBlessings() is always 0 on Pegaz),
-- so the server's text reply to !bless is the only truth. Blessings are only lost by dying, which means a
-- relog and therefore a config reload: say !bless after every load and keep trying until an OK reply.
local BLESS_COMMAND = "!bless"
local BLESS_FAIL = { "not enough", "don't have enough", "do not have enough", "cannot", "can't", "you need" } -- checked first
local BLESS_OK = { "already have", "blessed", "bless" }                                                   -- then: all good
local REPLY_TIMEOUT_MS = 3000
local RETRY_MS = 3000            -- keep asking every few seconds until an OK reply
local ALARM_EVERY_MS = 60000     -- ... but nag (warn + alarm) at most this often
local blessDone, blessNextAt, blessAwaitingUntil, blessFails, blessSilent, blessLastNag = false, now + 3000, 0, 0, 0, 0

local function matches(text, list)
  for _, pat in ipairs(list) do if text:find(pat, 1, true) then return true end end
  return false
end

local function blessFailed(why)
  blessFails = blessFails + 1
  blessNextAt = now + RETRY_MS
  if now - blessLastNag < ALARM_EVERY_MS then return end
  blessLastNag = now
  if blessFails >= 2 then playAlarm() end -- one hiccup is fine, two in a row means you need to act
  warn("BLESSINGS (" .. blessFails .. "): " .. why)
end

Hunt.blessed = nil -- true / false once the server has answered a !bless this session (icons colour on it)
onTextMessage(function(mode, text)
  if type(text) ~= "string" then return end
  local lower = text:lower()
  local fail, ok = matches(lower, BLESS_FAIL) and lower:find("bless"), false
  if not fail then ok = matches(lower, BLESS_OK) end
  if fail then Hunt.blessed = false elseif ok then Hunt.blessed = true end
  if blessAwaitingUntil == 0 then return end
  if fail then
    blessAwaitingUntil = 0
    blessFailed(text)
  elseif ok then
    blessAwaitingUntil = 0
    blessDone = true
    if blessFails > 0 then info("BLESSINGS ok: " .. text) end
  end
end)

into("toolsOther", "Utility")
local blessMacro = macro(1000, "auto bless", function()
  if blessDone then return end
  if blessAwaitingUntil > 0 and now > blessAwaitingUntil then -- no reply at all
    blessAwaitingUntil = 0
    blessSilent = blessSilent + 1
    if blessSilent >= 3 then
      blessSilent = 0
      blessFailed("no answer to " .. BLESS_COMMAND)
    else
      blessNextAt = now
    end
  end
  if blessAwaitingUntil == 0 and now >= blessNextAt then
    say(BLESS_COMMAND)
    blessAwaitingUntil = now + REPLY_TIMEOUT_MS
    blessNextAt = now + RETRY_MS
  end
end)
Features.register{ id = "autoBless", name = "Auto bless", group = "Other", macro = blessMacro }

-- stamina refill: use item 5080 once a minute while stamina is below 40 h (on by default, switch on Tools / Main)
local STAMINA_ITEM = 5080
local STAMINA_MIN_MINUTES = 40 * 60
local staminaMacro = macro(60000, "stamina refill", function()
  if stamina() < STAMINA_MIN_MINUTES then g_game.useInventoryItem(STAMINA_ITEM) end
end)
if storage._macros["stamina refill"] == nil then staminaMacro.setOn(true) end
Features.register{ id = "staminaRefill", name = "Stamina", group = "Other", macro = staminaMacro }

-- mana training
if type(storage.manaTrain) ~= "table" then storage.manaTrain = {on=false, title="MP%", text="utevo lux", min=80, max=100} end
local manaTrainMacro = macro(1000, function()
  if TargetBot and TargetBot.isActive() then return end
  local mana = math.min(100, math.floor(100 * (player:getMana() / math.max(1, player:getMaxMana()))))
  if storage.manaTrain.max >= mana and mana >= storage.manaTrain.min then say(storage.manaTrain.text) end
end)
manaTrainMacro.setOn(storage.manaTrain.on)
UI.DualScrollPanel(storage.manaTrain, function(widget, newParams)
  storage.manaTrain = newParams
  manaTrainMacro.setOn(newParams.on)
end)
local manaTrainWidget = panel:getLastChild() -- the stock builder returns nothing
Features.register{ id = "manaTrain", name = "Mana train", group = "Other",
  isOn = function() return storage.manaTrain.on end,
  setOn = function(v) storage.manaTrain.on = v; manaTrainWidget.title:setOn(v); manaTrainMacro.setOn(v) end }

UI.Separator()

local dropRow = UI.buttonRow({ "Drop items", "Drop list..." })
dropRow.buttons[1]:setTooltip("Drop the listed items while you walk")
dropRow.buttons[1].onClick = function() dropMacro.setOn(not dropMacro.isOn()) end
macro(500, function()
  UI.fitButtonRow(dropRow)
  dropRow.buttons[1]:setOn(dropMacro.isOn())
end)
dropRow.buttons[2].onClick = (function()
  UI.popup("Items to drop (drag in)", 170, function(content)
    local drops = UI.Container(function(widget, items) storage.dropItems = items end, true, content)
    drops:setHeight(70)
    drops:setItems(storage.dropItems)
  end)
end)

-- keep target: re-attack the creature you were fighting whenever the client drops the attack (stairs, holes, ropes,
-- out of sight) as soon as it is back on your floor. The last target is remembered even while the switch is off, so
-- turning it on after someone ran away picks them up again. Forgotten when it dies, or on ESC.
--
-- It used to sit idle whenever the targetbot engine was on, which meant it never ran at all for anyone who hunts
-- with a targetbot - the switch looked broken. It now holds the target through the targetbot too, and ESC is the
-- release: one press clears the held target and stops the attack.
local keepId
into("toolsPvp", "PvP")
local keepMacro = macro(100, "Keep target", function()
  if not keepId or g_game.getAttackingCreature() then return end
  local c = getCreatureById(keepId)
  if c and not c:isDead() and c:getHealthPercent() > 0 then attack(c) end
end)
onAttackingCreatureChange(function(creature, oldCreature)
  if creature then keepId = creature:getId() end
end)
onCreatureHealthPercentChange(function(creature, percent)
  if keepId and percent <= 0 and creature:getId() == keepId then keepId = nil end
end)
-- ESC: let go. Without this the macro re-attacks whatever the client just cancelled, so the stock Escape did
-- nothing while Keep target was on.
onKeyPress(function(keys)
  if keys == "Escape" then
    keepId = nil
    g_game.cancelAttackAndFollow()
  end
end)
Features.register{ id = "keepTarget", name = "Keep target", group = "PvP", order = 2, macro = keepMacro }

if storage.keepCrosshair == nil then storage.keepCrosshair = false end

-- the repeat itself lives in the game_cursor module: the bot only hears about its own useWith calls, so a
-- wall thrown by hand was never repeated
local function pushKeepCrosshair()
  local cursor = modules.game_cursor
  if cursor and cursor.setKeepCrosshair then cursor.setKeepCrosshair(storage.keepCrosshair) end
end
macro(2000, function() pushKeepCrosshair() end)   -- a module reload resets its copy of the flag

local keepSwitch = addSwitch("keepCrosshair", "Keep crosshair", function(widget)
  storage.keepCrosshair = not storage.keepCrosshair
  widget:setOn(storage.keepCrosshair)
  pushKeepCrosshair()
end)
keepSwitch:setOn(storage.keepCrosshair)
Features.register{ id = "keepCrosshair", name = "Keep crosshair", group = "PvP", order = 4,
  isOn = function() return storage.keepCrosshair end,
  setOn = function(v) storage.keepCrosshair = v keepSwitch:setOn(v) pushKeepCrosshair() end }


-- mwall target: drop a magic wall a few squares ahead of your target, the way elfbot's mwall did. 2 sqm is the
-- useful default, 3 and 4 are tried when it is blocked, out of sight, or would land on us.
MWALL_RUNE = 3180                 -- magic wall rune
local MWALL_OFFSETS = { 2, 3, 4 }
local MWALL_RANGE = 8             -- rune throwing range for the sight/range check
local DIR_STEP = {               -- named constants, not numbers: I had all four diagonals wrong by hand
  [North] = { x = 0, y = -1 }, [East] = { x = 1, y = 0 }, [South] = { x = 0, y = 1 }, [West] = { x = -1, y = 0 },
  [NorthEast] = { x = 1, y = -1 }, [SouthEast] = { x = 1, y = 1 },
  [SouthWest] = { x = -1, y = 1 }, [NorthWest] = { x = -1, y = -1 },
}

-- where the target is actually heading. A creature that stops to swing at you keeps facing you, so its last real
-- step beats getDirection() whenever we have one; the tracker only holds one position per target.
local trackedId, lastPos, lastStep = nil, nil, nil
macro(100, function()
  local t = g_game.getAttackingCreature()
  if not t then trackedId, lastPos, lastStep = nil, nil, nil return end
  local pos = t:getPosition()
  if not pos then return end        -- a target out of view reports no position
  if t:getId() ~= trackedId then
    trackedId, lastPos, lastStep = t:getId(), pos, nil
    return
  end
  if lastPos and pos.z == lastPos.z then
    local dx, dy = pos.x - lastPos.x, pos.y - lastPos.y
    if (dx ~= 0 or dy ~= 0) and math.abs(dx) <= 1 and math.abs(dy) <= 1 then
      lastStep = { x = dx, y = dy }
    end
  end
  lastPos = pos
end)

local function stepName(step)
  return (step.y < 0 and "N" or step.y > 0 and "S" or "") .. (step.x > 0 and "E" or step.x < 0 and "W" or "")
end

local function mwallSpot(creature)
  local step = (lastStep and trackedId == creature:getId()) and lastStep or DIR_STEP[creature:getDirection()]
  if not step then return nil, "nowhere to aim" end
  local base, me = creature:getPosition(), player:getPosition()
  local sight = false
  for _, n in ipairs(MWALL_OFFSETS) do
    local pos = { x = base.x + step.x * n, y = base.y + step.y * n, z = base.z }
    local onMe = pos.x == me.x and pos.y == me.y and pos.z == me.z
    local tile = g_map.getTile(pos)
    if tile and not onMe and tile:isWalkable() and not tile:hasCreature() then
      if canShoot(pos, MWALL_RANGE) then
        local thing = tile:getTopUseThing() or tile:getGround()
        if thing then return thing, n, stepName(step) end
      else
        sight = true
      end
    end
  end
  return nil, sight and "no clear line" or "all blocked"
end

local function gripe() end          -- mwall runs silently: nothing to say in the bot window

local lastSpot = nil   -- where the last wall went, so it can be kept up without re-aiming

function mwallTarget()
  local t = g_game.getAttackingCreature()
  if not t then return gripe("mwall: no target") end
  local thing, n = mwallSpot(t)
  if not thing then return gripe("mwall: " .. n .. " ahead of " .. t:getName()) end
  lastSpot = thing:getPosition()
  useWith(MWALL_RUNE, thing)
end

-- keep mwall: throw again at the last tile. Spam it and the chokepoint stays walled; while a wall is still
-- standing there the server just refuses, which costs nothing.
-- a wall thrown by hand never reaches the bot, so the last spot comes from the cursor module, which wraps
-- both of the client's use-with calls
local function lastThrow()
  local c = modules.game_cursor
  local fromClient = c and c.getLastUseWithPos and c.getLastUseWithPos(MWALL_RUNE)
  return fromClient or lastSpot
end

function mwallKeep()
  local lastSpot = lastThrow()
  if not lastSpot then return gripe("mwall: nothing thrown yet") end
  local tile = g_map.getTile(lastSpot)
  if not tile then return gripe("mwall: last spot is out of view") end
  if not canShoot(lastSpot, MWALL_RANGE) then return gripe("mwall: no line to the last spot") end
  local thing = tile:getTopUseThing() or tile:getGround()
  if not thing then return gripe("mwall: nothing to aim at there") end
  useWith(MWALL_RUNE, thing)
end

-- the combo is stored, not hard-coded: the key button on the right opens an editor for it
if type(storage.mwallKey) ~= "string" or storage.mwallKey == "" then storage.mwallKey = "Ctrl+Shift+W" end
if not pcall(hotkey, storage.mwallKey, "MWall target", mwallTarget, hiddenBin) then
  warning("mwall: '" .. tostring(storage.mwallKey) .. "' is not a usable hotkey, back to Ctrl+Shift+W")
  storage.mwallKey = "Ctrl+Shift+W"
  hotkey(storage.mwallKey, "MWall target", mwallTarget, hiddenBin)
end

if type(storage.mwallKeepKey) ~= "string" or storage.mwallKeepKey == "" then storage.mwallKeepKey = "Ctrl+Shift+E" end
if not pcall(hotkey, storage.mwallKeepKey, "Keep MWall", mwallKeep, hiddenBin) then
  warning("mwall: '" .. tostring(storage.mwallKeepKey) .. "' is not a usable hotkey, back to Ctrl+Shift+E")
  storage.mwallKeepKey = "Ctrl+Shift+E"
  hotkey(storage.mwallKeepKey, "Keep MWall", mwallKeep, hiddenBin)
end

local function keyRow(label, action, storageKey, tip)
  local row = UI.buttonRow({ label, storage[storageKey] })
  row.buttons[1].onClick = action
  row.buttons[1]:setTooltip(tip)
  row.buttons[2]:setTooltip("Click, then press the combination you want")
  row.buttons[2].onClick = function()
    UI.captureKey(label .. " hotkey", storage[storageKey], function(combo)
      storage[storageKey] = combo
      reload()
    end)
  end
  return row
end

Features.register{ id = "mwallTarget", name = "MW target", group = "PvP", order = 1, action = mwallTarget }
Features.register{ id = "mwallKeep", name = "Keep MW", group = "PvP", order = 3, action = mwallKeep }

local mwallRow = keyRow("MWall target", mwallTarget, "mwallKey", "Throw a magic wall 2-4 sqm ahead of your target")
local keepRow = keyRow("Keep MWall", mwallKeep, "mwallKeepKey", "Throw again at the last tile you walled")
macro(500, function() UI.fitButtonRow(mwallRow) UI.fitButtonRow(keepRow) end)

-- keep crosshair: after a use-with lands, arm the same item again so the next click repeats it (mwall, rope,
-- shovel). Runes that are gone are simply not re-armed.
pushKeepCrosshair()

into("toolsEditors", "Editors")

-- in-game lua editors (stock)
UI.Button("Macro editor", function()
  UI.MultilineEditorWindow(storage.ingame_macros or "", {title="Macro editor", description="Custom macros or any other lua code"}, function(text)
    storage.ingame_macros = text
    reload()
  end)
end)
UI.Button("Hotkey editor", function()
  UI.MultilineEditorWindow(storage.ingame_hotkeys or "", {title="Hotkeys editor", description="Custom hotkeys / singlehotkeys"}, function(text)
    storage.ingame_hotkeys = text
    reload()
  end)
end)
for _, scripts in ipairs({storage.ingame_macros, storage.ingame_hotkeys}) do
  if type(scripts) == "string" and scripts:len() > 3 then
    local status, result = pcall(function() assert(load(scripts, "ingame_editor"))() end)
    if not status then error("Ingame editor error:\n" .. result) end
  end
end

done()
