-- Position HUD: "x: 405  y: 528  z: 8" at the top of the minimap (falls back to the top of the game map when
-- the minimap module is missing). On the full map it also shows the tile under the cursor, which is what you
-- need when you are placing waypoints by hand.
local ui, tick

local function cursorLine()
  local mm = modules.game_minimap
  if not mm or not mm.fullmapView or not mm.minimapWidget then return nil end
  local widget = mm.minimapWidget
  if widget:isDestroyed() or not widget:isVisible() then return nil end
  local mouse = g_window.getMousePosition()
  if not mouse or not widget:containsPoint(mouse) then return nil end
  local ok, pos = pcall(function() return widget:getTilePosition(mouse) end)
  if not ok or not pos then return nil end
  return string.format('cursor: %d  %d  %d', pos.x, pos.y, pos.z)
end

local function update()
  if not ui then return end
  local me = g_game.getLocalPlayer()
  local pos = me and me:getPosition()
  if not pos then ui:hide() return end
  ui:show()
  local text = string.format('x: %d  y: %d  z: %d', pos.x, pos.y, pos.z)
  local cursor = cursorLine()
  if cursor then text = text .. '\n' .. cursor end
  ui:setText(text)
end

local function loop()
  update()
  tick = scheduleEvent(loop, 200)
end

function init()
  local parent = modules.game_minimap and modules.game_minimap.minimapWidget or modules.game_interface.getMapPanel()
  ui = g_ui.loadUI('pos_hud', parent)
  connect(LocalPlayer, { onPositionChange = update })
  connect(g_game, { onGameStart = update, onGameEnd = update })
  loop()
end

function terminate()
  if tick then removeEvent(tick) tick = nil end
  disconnect(LocalPlayer, { onPositionChange = update })
  disconnect(g_game, { onGameStart = update, onGameEnd = update })
  if ui then ui:destroy() ui = nil end
end
