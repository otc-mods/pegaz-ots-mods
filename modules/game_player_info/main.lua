-- game_player_info: other players are shown as "[RP 250] Name". The client never receives vocations, so each
-- player that appears is looked at once (throttled); the server's "You see Name (Level N). He is a <vocation>."
-- reply is parsed and cached. Levels also refresh from chat messages, which carry the speaker's level.

LOOK_INTERVAL = 1000            -- ms between automatic looks
CACHE_TTL = 60 * 60             -- s before a cached player is looked at again
CACHE_MAX_AGE = 7 * 24 * 3600   -- s after which a cached entry is dropped
-- one tag per vocation family, whatever the promotion (Pegaz has extra ones, e.g. gladiator for knights);
-- a vocation word not listed here is shown as its first two letters and reported once in the console
VOCATION_FAMILIES = {
  { tag = "EK", words = { "knight", "gladiator" } },
  { tag = "RP", words = { "paladin", "sniper" } },
  { tag = "MS", words = { "sorcerer", "wizard" } },
  { tag = "ED", words = { "druid", "priest" } },
  { tag = "N",  words = { "no vocation", "none" } },
}
local reportedVocations = {}
local function vocationTag(voc)
  local low = voc:lower()
  for _, fam in ipairs(VOCATION_FAMILIES) do
    for _, w in ipairs(fam.words) do
      if low:find(w, 1, true) then return fam.tag end
    end
  end
  if not reportedVocations[low] then
    reportedVocations[low] = true
    print("player_info: unknown vocation '" .. voc .. "' - tell Claude which family it belongs to")
  end
  return voc:sub(1, 2):upper()
end

local enabled = true    -- g_settings 'playerInfoEnabled'
local showVocation, showLevel = true, true -- g_settings 'playerInfoVocation' / 'playerInfoLevel'
local button, optionsWindow
local cache = {}        -- real name -> { level=, voc=, t= }
local queue, queued = {}, {}
local lookEvent, saveEvent

local function load()
  local node = g_settings.getNode('playerInfo')
  cache = {}
  local cutoff = os.time() - CACHE_MAX_AGE
  if type(node) == 'table' then
    for name, info in pairs(node) do
      if type(info) == 'table' and tonumber(info.t) and tonumber(info.t) > cutoff then
        cache[name] = { level = tonumber(info.level), voc = info.voc, t = tonumber(info.t) }
      end
    end
  end
end

local function save() g_settings.setNode('playerInfo', cache) end

local function realName(creature)
  return creature.playerInfoName or creature:getName()
end

-- The tag shown above the player. It is deliberately NOT part of the name: the name is what the rest of the
-- client keys on - add to VIP, open a private message, the battle list, right-click menus - so renaming a
-- creature made all of those unusable. creature:setText() draws an extra line above the creature and leaves the
-- real name completely untouched.
local function tagFor(name)
  local info = cache[name]
  if not info or not (showVocation or showLevel) then return "" end
  local parts = {}
  if showVocation then table.insert(parts, info.voc or "?") end
  if showLevel then table.insert(parts, tostring(info.level or "?")) end
  return "[" .. table.concat(parts, " ") .. "]"
end

local function apply(creature)
  local name = realName(creature)
  -- undo any renaming an earlier version of this module did, so names are correct again
  if creature.playerInfoName and creature:getName() ~= creature.playerInfoName then
    pcall(function() creature:setName(creature.playerInfoName) end)
  end
  creature.playerInfoName = name
  pcall(function() creature:setText(enabled and tagFor(name) or "") end)
end

local function visiblePlayers()
  local out = {}
  local me = g_game.getLocalPlayer()
  if not me then return out end
  for _, c in ipairs(g_map.getSpectators(me:getPosition(), false)) do
    if c:isPlayer() and not c:isLocalPlayer() then table.insert(out, c) end
  end
  return out
end

local function applyByName(name)
  for _, c in ipairs(visiblePlayers()) do
    if realName(c) == name then apply(c) end
  end
end

-- look queue --------------------------------------------------------------------------
local function processQueue()
  lookEvent = nil
  local entry = table.remove(queue, 1)
  if entry then
    queued[entry.name] = nil
    if g_game.isOnline() and not entry.creature:isRemoved() then g_game.look(entry.creature) end
  end
  if #queue > 0 then lookEvent = scheduleEvent(processQueue, LOOK_INTERVAL) end
end

local function requestLook(creature)
  local name = realName(creature)
  local info = cache[name]
  if info and info.voc and os.time() - (info.t or 0) < CACHE_TTL then return end
  if queued[name] then return end
  queued[name] = true
  table.insert(queue, { name = name, creature = creature })
  if not lookEvent then lookEvent = scheduleEvent(processQueue, 300) end
end

-- events --------------------------------------------------------------------------------
local function onAppear(creature)
  if not creature:isPlayer() or creature:isLocalPlayer() then return end
  apply(creature)
  if enabled then requestLook(creature) end
end

-- "You see Bob (Level 250). He is a royal paladin. ..."
local function onTextMessage(mode, text)
  if type(text) ~= 'string' then return end
  local selfVoc = text:match("^You see yourself%. You are an? ([%a ]+)%.")
  if selfVoc then
    local me = g_game.getLocalPlayer()
    print("player_info self-test: vocation '" .. selfVoc .. "' -> tag " .. vocationTag(selfVoc) .. ", level " .. (me and me:getLevel() or "?") .. " (own name is never decorated)")
    return
  end
  local name, level, voc = text:match("^You see (.-) %(Level (%d+)%)%. %a+ is an? ([%a ]+)%.")
  if not name then return end
  local short = vocationTag(voc)
  cache[name] = { level = tonumber(level), voc = short, t = os.time() }
  applyByName(name)
end

-- chat carries the speaker's current level
local function onTalk(name, level, mode, text)
  if type(level) ~= 'number' or level <= 0 or type(name) ~= 'string' then return end
  local info = cache[name]
  if info and info.level ~= level then
    info.level = level
    info.t = os.time()
    applyByName(name)
  end
end

local function periodicSave()
  save()
  saveEvent = scheduleEvent(periodicSave, 60000)
end

local function refreshAll()
  for _, c in ipairs(visiblePlayers()) do apply(c) end -- decorate or restore the real names
  if enabled then for _, c in ipairs(visiblePlayers()) do requestLook(c) end end
  if button then button:setOn(enabled) end
end

function isEnabled() return enabled end

function setEnabled(v)
  enabled = v and true or false
  g_settings.set('playerInfoEnabled', enabled)
  refreshAll()
end

local function syncOptions()
  if not optionsWindow then return end
  optionsWindow.enabled:setChecked(enabled)
  optionsWindow.showVocation:setChecked(showVocation)
  optionsWindow.showLevel:setChecked(showLevel)
end

function showOptions()
  if not optionsWindow then
    optionsWindow = g_ui.displayUI('options')
    -- both parts off = nothing to show: that is "disabled", keep the main box honest
    local function afterPartChange()
      if not (showVocation or showLevel) and enabled then setEnabled(false) end
      refreshAll()
      syncOptions()
    end
    optionsWindow.showVocation.onCheckChange = function(widget, checked)
      showVocation = checked; g_settings.set('playerInfoVocation', checked); afterPartChange()
    end
    optionsWindow.showLevel.onCheckChange = function(widget, checked)
      showLevel = checked; g_settings.set('playerInfoLevel', checked); afterPartChange()
    end
    -- enabling with nothing selected turns both parts back on
    optionsWindow.enabled.onCheckChange = function(widget, checked)
      if checked and not (showVocation or showLevel) then
        showVocation, showLevel = true, true
        g_settings.set('playerInfoVocation', true); g_settings.set('playerInfoLevel', true)
      end
      setEnabled(checked)
      syncOptions()
    end
  end
  syncOptions()
  optionsWindow:show()
  optionsWindow:raise()
  optionsWindow:focus()
end

function hideOptions()
  if optionsWindow then optionsWindow:hide() end
end

function toggleOptions()
  if optionsWindow and optionsWindow:isVisible() then hideOptions() else showOptions() end
end

function init()
  if g_settings.exists('playerInfoEnabled') then enabled = g_settings.getBoolean('playerInfoEnabled') end
  if g_settings.exists('playerInfoVocation') then showVocation = g_settings.getBoolean('playerInfoVocation') end
  if g_settings.exists('playerInfoLevel') then showLevel = g_settings.getBoolean('playerInfoLevel') end
  load()
  button = modules.client_topmenu.addRightGameToggleButton('playerInfoButton', tr('Player info'), '/images/topbuttons/playerinfo', toggleOptions, false, 1003)
  button:setOn(enabled)
  connect(Creature, { onAppear = onAppear })
  connect(g_game, { onTextMessage = onTextMessage, onTalk = onTalk })
  if g_game.isOnline() then
    for _, c in ipairs(visiblePlayers()) do onAppear(c) end
  end
  saveEvent = scheduleEvent(periodicSave, 60000)
end

function terminate()
  disconnect(Creature, { onAppear = onAppear })
  disconnect(g_game, { onTextMessage = onTextMessage, onTalk = onTalk })
  removeEvent(lookEvent)
  removeEvent(saveEvent)
  save()
  if optionsWindow then optionsWindow:destroy() optionsWindow = nil end
  if button then button:destroy() button = nil end
end

-- console helpers: modules.game_player_info.forget("Name") / clear() / test() (look at yourself, print the parse)
function test()
  local me = g_game.getLocalPlayer()
  if me then g_game.look(me) end
end
function forget(name) cache[name] = nil save() end
function clear() cache = {} save() end
