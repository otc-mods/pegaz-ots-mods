-- The v2 client keeps the 36 px top bar (Discord / options / exit) after login. Hide it in game, show it on the
-- login screen. After a full reload (Ctrl+Shift+R) client_topmenu rebuilds the bar AFTER our init runs, so a
-- single hide fires too early and the rebuilt (black) bar stays - we re-hide on a few short delays to catch it.
local hideEvents = {}

local function hide()
  if modules.client_topmenu and modules.client_topmenu.hide then modules.client_topmenu.hide() end
end

local function show()
  if modules.client_topmenu and modules.client_topmenu.show then modules.client_topmenu.show() end
end

local function hideSoon()
  if not g_game.isOnline() then return end
  hide()
  for _, ms in ipairs({ 50, 200, 600, 1500 }) do
    table.insert(hideEvents, scheduleEvent(function() if g_game.isOnline() then hide() end end, ms))
  end
end

function init()
  connect(g_game, { onGameStart = hide, onGameEnd = show })
  hideSoon()   -- covers a reload while already online
end

function terminate()
  disconnect(g_game, { onGameStart = hide, onGameEnd = show })
  for _, e in ipairs(hideEvents) do removeEvent(e) end
  show()
end
