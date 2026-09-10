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
local tagEvent
-- creature:setText() draws at a position fixed in C++ and the block is TOP-anchored: leading newlines push it
-- further down, trailing newlines do nothing, and there is no way to move it up. The tag therefore cannot sit
-- beside or above the name while the name is left untouched.
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

-- ---- the name hook --------------------------------------------------------------------------------
-- The tag is part of the DISPLAYED name, so it renders inline and takes the name's HP colour. C++ keeps the
-- decorated string and draws it; Lua's Creature:getName() is wrapped to hand back the REAL name instead. That is
-- why nothing breaks: Copy Name, Add to VIP, Message, Rule Violation, the battle list, getCreatureByName and the
-- bot all read through getName(), so they all see the true name - one correction at the source rather than a list
-- of guarded call sites (a list always misses one; Copy Name proved that).
--
-- The original is stashed in a GLOBAL: on a module reload rawget() would otherwise return our own wrapper and we
-- would wrap the wrapper on every reload.
if not _G.__playerInfoOrigGetName then
  _G.__playerInfoOrigGetName = rawget(Creature, 'getName')
end
local origGetName = _G.__playerInfoOrigGetName

local function installNameHook()
  if not origGetName then return end
  Creature.getName = function(self)
    return self.playerInfoRealName or origGetName(self)
  end
end

local function removeNameHook()
  if origGetName then Creature.getName = origGetName end
end

local function trueName(creature)
  return creature.playerInfoRealName or (origGetName and origGetName(creature)) or creature:getName()
end

local function realName(creature) return trueName(creature) end

-- Just the bracketed part, e.g. "[RP 200]". decorate() joins it to the real name for display.
--
-- Approaches that were tried and rejected, so they are not revisited: creature:setText() only draws BELOW the
-- name (its block is top-anchored, verified in game); tile:setText() one tile north can sit above the name but is
-- bound to the tile grid, so it jumps sqm by sqm while the creature animates; mapPanel:setDrawNames(false) throws
-- away the HP colouring, which carries real information; and renaming WITHOUT the getName hook breaks every
-- name-keyed action, with the click-time readers (Copy Name) impossible to guard from outside.
local function tagFor(name)
  local info = cache[name]
  if not info or not (showVocation or showLevel) then return "" end
  local parts = {}
  if showVocation then table.insert(parts, info.voc or "?") end
  if showLevel then table.insert(parts, tostring(info.level or "?")) end
  return "[" .. table.concat(parts, " ") .. "]"
end

local function decorate(name)
  local tag = tagFor(name)
  if tag == "" then return name end
  return tag .. " " .. name
end

local function apply(creature)
  local real = trueName(creature)
  creature.playerInfoRealName = real
  creature.playerInfoName = real          -- the bot reads this one (rp: hunt.lua, icons.lua)
  local want = enabled and decorate(real) or real
  pcall(function() if origGetName(creature) ~= want then creature:setName(want) end end)
  -- leftovers from the approaches that did not work out
  pcall(function() if creature:getText() ~= "" then creature:setText("") end end)
  pcall(function() if creature.getTitle and creature:getTitle() ~= "" then creature:setTitle("") end end)
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

-- ---- drawing -------------------------------------------------------------------------------------
local function drawTags()
  if not g_game.isOnline() then return end
  for _, c in ipairs(visiblePlayers()) do apply(c) end
end

local function undecorateAll()
  if not g_game.isOnline() or not origGetName then return end
  local me = g_game.getLocalPlayer()
  if not me then return end
  for _, c in ipairs(g_map.getSpectators(me:getPosition(), false)) do
    local real = c.playerInfoRealName
    if real and origGetName(c) ~= real then pcall(function() c:setName(real) end) end
    c.playerInfoRealName, c.playerInfoName = nil, nil
  end
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
  -- an earlier build of this module could switch the client's name drawing off; undo that and drop the setting
  if g_settings.exists('playerInfoInline') then
    local mp = modules.game_interface and modules.game_interface.getMapPanel and modules.game_interface.getMapPanel()
    if mp and mp.setDrawNames then pcall(function() mp:setDrawNames(true) end) end
    g_settings.remove('playerInfoInline')
  end
  load()
  button = modules.client_topmenu.addRightGameToggleButton('playerInfoButton', tr('Player info'), '/images/topbuttons/playerinfo', toggleOptions, false, 1003)
  button:setOn(enabled)
  connect(Creature, { onAppear = onAppear })
  connect(g_game, { onTextMessage = onTextMessage, onTalk = onTalk })
  if g_game.isOnline() then
    for _, c in ipairs(visiblePlayers()) do onAppear(c) end
  end
  saveEvent = scheduleEvent(periodicSave, 60000)
  installNameHook()
  tagEvent = cycleEvent(drawTags, 250)   -- creatures come and go; keep the names in step
end

function terminate()
  disconnect(Creature, { onAppear = onAppear })
  disconnect(g_game, { onTextMessage = onTextMessage, onTalk = onTalk })
  removeEvent(lookEvent)
  removeEvent(saveEvent)
  removeEvent(tagEvent)
  undecorateAll()      -- put every displayed name back before letting go of the hook
  removeNameHook()
  clearAllText()
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
