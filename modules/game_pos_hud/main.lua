-- Position HUD: Pos X / Y / Z lines at the top-left of the map, right under the FPS/ping overlay when that is
-- showing (top bar hidden), else at the map's top-left corner.
local ui, tickEvent

local function place()
  if not ui then return end
  local mapPanel = modules.game_interface.getMapPanel()
  local stats = mapPanel:getChildById('game_stats')
  local top, left = 3, 3
  if stats and stats:isVisible() then
    local last
    for _, id in ipairs({ 'ping', 'fps' }) do
      local l = stats:getChildById(id)
      if l and l:isVisible() then last = l break end
    end
    if last then top = last:getY() + last:getHeight() - mapPanel:getY() end
    left = stats:getX() - mapPanel:getX()
  end
  ui:setMarginTop(top)
  ui:setMarginLeft(left)
end

local function update()
  if not ui then return end
  local me = g_game.getLocalPlayer()
  local pos = me and me:getPosition()
  if not pos then ui:hide() return end
  ui:show()
  ui.x:setText('Pos X: ' .. pos.x)
  ui.y:setText('Pos Y: ' .. pos.y)
  ui.z:setText('Pos Z: ' .. pos.z)
  place()
end

function init()
  ui = g_ui.loadUI('pos_hud', modules.game_interface.getMapPanel())
  connect(LocalPlayer, { onPositionChange = update })
  connect(g_game, { onGameStart = update, onGameEnd = update })
  tickEvent = cycleEvent(place, 1000) -- the FPS/ping overlay comes and goes with the top bar
  update()
end

function terminate()
  disconnect(LocalPlayer, { onPositionChange = update })
  disconnect(g_game, { onGameStart = update, onGameEnd = update })
  removeEvent(tickEvent)
  if ui then ui:destroy() ui = nil end
end
