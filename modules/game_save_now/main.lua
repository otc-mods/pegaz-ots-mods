-- Save now: the client normally writes config.otml, the bot storage and the minimap on a clean exit, so a crash
-- loses everything changed since login. This asks every module that owns state to write it, then flushes
-- g_settings to disk. Manual only (button / Ctrl+Alt+S): the write stutters for a moment, which is not something
-- to trigger behind the player's back mid-fight.
-- every stock/our module with a save() that persists user state
SAVERS = { 'game_interface', 'game_console', 'game_hotkeys', 'game_actionbar', 'game_bot', 'game_questlog',
           'game_topbar', 'client_profiles', 'game_better_chat', 'game_player_info', 'game_autoloot' }

local button

local function callSave(name)
  local m = modules[name]
  if type(m) ~= 'table' then return false end
  local ok = false
  for _, fn in ipairs({ 'save', 'saveCommunicationSettings' }) do
    if type(m[fn]) == 'function' then
      local done = pcall(m[fn])
      ok = ok or done
    end
  end
  return ok
end

-- withMap = also rewrite minimap<version>.otmm (a few hundred KB, so not on every autosave)
function saveAll(withMap, quiet)
  if not g_game.isOnline() then return end
  local saved = 0
  for _, name in ipairs(SAVERS) do
    if callSave(name) then saved = saved + 1 end
  end
  if withMap and modules.game_minimap and modules.game_minimap.saveMap then
    pcall(modules.game_minimap.saveMap)
  end
  pcall(function() g_settings.save() end)
  if not quiet and modules.game_textmessage then
    modules.game_textmessage.displayStatusMessage('Saved: ' .. saved .. ' modules' .. (withMap and ' + minimap' or ''))
  end
  return saved
end

function init()
  local tip = tr('Save client settings now (Ctrl+Alt+S)') ..
    '\n' .. tr('window layout, chat tabs and channels, hotkeys, action bar, bot storage, module settings, minimap') ..
    '\n' .. tr('the client normally writes these only on a clean exit')
  button = modules.client_topmenu.addRightGameToggleButton('saveNowButton', tip,
    '/images/topbuttons/savenow', function() saveAll(true) end, false, 1007)
  if button then button:setOn(false) end
  g_keyboard.bindKeyDown('Ctrl+Alt+S', function() saveAll(true) end)
end

function terminate()
  g_keyboard.unbindKeyDown('Ctrl+Alt+S')
  if button then button:destroy() button = nil end
end
