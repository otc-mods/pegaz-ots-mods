-- The Buttons panel (right side) has a fixed height, so extra buttons from installed modules fall outside it and
-- become unclickable. This resizes it to the rows it actually holds, from the outside: game_buttons itself lives
-- inside the client's data package and cannot be patched.
local CELL = 23 -- button 20 + spacing 3
local tickEvent

local function fit()
  local gb = modules.game_buttons
  if not gb or not gb.buttonsWindow or not gb.contentsPanel then return end
  local win, contents = gb.buttonsWindow, gb.contentsPanel
  local grid = contents.buttons
  if not grid or win:isDestroyed() or not win:isVisible() then return end
  local n = 0
  for _, child in ipairs(grid:getChildren()) do if child:isVisible() then n = n + 1 end end
  local width = grid:getWidth()
  if n == 0 or width <= 0 then return end
  local cols = math.max(1, math.floor((width + 3) / CELL))
  local wanted = math.ceil(n / cols) * CELL + 3 + contents:getMarginTop()
  if win:getHeight() ~= wanted then
    win:setHeight(wanted)
    if win.setContentMinimumHeight then win:setContentMinimumHeight(wanted - contents:getMarginTop()) end
  end
end

function init()
  tickEvent = cycleEvent(fit, 2000) -- buttons come and go with modules; cheap enough to just keep checking
  scheduleEvent(fit, 500)
end

function terminate()
  removeEvent(tickEvent)
end
