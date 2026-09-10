-- Players online HUD: says !online periodically, reads the "N players online." line (onTextMessage OR onTalk) and
-- shows the count as one more line in the client's game_stats overlay - the widget that owns the FPS / Ping labels
-- (ids 'fps' and 'ping', laid out by a verticalBox). Being a child of it means the layout puts us directly under
-- Ping and we inherit its visibility; every earlier attempt failed by fighting anchors from the outside.
local INTERVAL = 120 * 1000
local ICON = '/images/topbuttons/viplist'

local ui, button, pollEvent, attachEvent
local enabled, auto = true, true
local names, expectNames, debugOn = "", nil, false

local function statsOverlay()
  local gs = modules.game_stats
  return gs and gs.ui or nil
end

-- park the label inside the stats overlay so its verticalBox stacks us after fps/ping
local function attach()
  if not ui then return end
  local target = statsOverlay() or modules.game_interface.getMapPanel()
  if target and ui:getParent() ~= target then
    pcall(function() ui:setParent(target) end)
  end
  if debugOn then
    local p = ui:getParent()
    print(string.format("[online_hud] parent=%s pos=%d,%d size=%dx%d text='%s' visible=%s",
      p and (p:getId() or '?') or 'nil', ui:getX(), ui:getY(), ui:getWidth(), ui:getHeight(),
      ui:getText(), tostring(ui:isVisible())))
  end
end

local function feed(text)
  if type(text) ~= 'string' or not ui then return end
  if debugOn then print("[online_hud] <= " .. text) end
  local n = text:match("(%d+)%s+players online")
  if n then
    ui:setText(n .. " online")
    ui:setTooltip(names ~= "" and names or "players online")
    if enabled then ui:show() end
    expectNames = g_clock.millis() + 1500
    return
  end
  if expectNames and g_clock.millis() < expectNames and text:find("%[%d+%]") then
    names = text; ui:setTooltip(text); expectNames = nil
  end
end

local function onText(mode, text) feed(text) end
local function onTalk(name, level, mode, text) feed(text) end
local function poll() if enabled and g_game.isOnline() then g_game.talk("!online") end end

local function reschedule()
  removeEvent(pollEvent); pollEvent = nil
  if enabled and auto and g_game.isOnline() then
    pollEvent = scheduleEvent(function() poll() reschedule() end, INTERVAL)
  end
end

local function apply()
  if not ui then return end
  if enabled then ui:show() attach() else ui:hide() end
  if button then button:setOn(enabled) end
  reschedule()
end

function toggle()
  enabled = not enabled
  g_settings.set('onlineHudEnabled', enabled)
  apply()
  if enabled then scheduleEvent(poll, 200) end
end

local function onStart()
  apply()
  scheduleEvent(attach, 500)
  scheduleEvent(poll, 3000)
end
local function onEnd() removeEvent(pollEvent) pollEvent = nil end

function debug(on) debugOn = (on ~= false) print("[online_hud] debug " .. tostring(debugOn)) attach() end
function refresh() poll() end
function isEnabled() return enabled end

function init()
  enabled = g_settings.getBoolean('onlineHudEnabled', true)
  ui = g_ui.loadUI('online_hud', statsOverlay() or modules.game_interface.getMapPanel())
  ui:setText("? online")     -- visible immediately, so it can be found before the first reply lands
  ui.onMouseRelease = function(w, pos, mb)
    if mb == MouseLeftButton then poll() return true end
    if mb == MouseRightButton then
      auto = not auto; reschedule()
      ui:setTooltip(auto and "auto refresh on (every 120s) - right-click to pause"
                         or "auto refresh paused - left-click to refresh, right-click to resume")
      return true
    end
    return false
  end
  button = modules.client_topmenu.addRightGameToggleButton('onlineHudButton', tr('Players online'), ICON, toggle, false, 1010)
  connect(g_game, { onTextMessage = onText, onTalk = onTalk, onGameStart = onStart, onGameEnd = onEnd })
  apply()
  attachEvent = cycleEvent(attach, 3000)   -- the overlay is rebuilt on some relogs; re-park if we fall out
  if g_game.isOnline() then scheduleEvent(onStart, 100) end
end

function terminate()
  disconnect(g_game, { onTextMessage = onText, onTalk = onTalk, onGameStart = onStart, onGameEnd = onEnd })
  removeEvent(pollEvent); removeEvent(attachEvent)
  if button then button:destroy() button = nil end
  if ui then ui:destroy() ui = nil end
end
