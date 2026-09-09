-- Position HUD: one line "x: 405 y: 528 z: 8" at the top of the minimap (falls back to the top of the game map
-- when the minimap module is missing).
local ui

local function update()
  if not ui then return end
  local me = g_game.getLocalPlayer()
  local pos = me and me:getPosition()
  if not pos then ui:hide() return end
  ui:show()
  ui:setText(string.format('x: %d  y: %d  z: %d', pos.x, pos.y, pos.z))
end

function init()
  local parent = modules.game_minimap and modules.game_minimap.minimapWidget or modules.game_interface.getMapPanel()
  ui = g_ui.loadUI('pos_hud', parent)
  connect(LocalPlayer, { onPositionChange = update })
  connect(g_game, { onGameStart = update, onGameEnd = update })
  update()
end

function terminate()
  disconnect(LocalPlayer, { onPositionChange = update })
  disconnect(g_game, { onGameStart = update, onGameEnd = update })
  if ui then ui:destroy() ui = nil end
end
