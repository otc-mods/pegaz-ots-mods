-- Bot presets are directories under /bot. The stock window only lets you pick one, and its tabs exist only
-- while the bot runs, so copying a preset used to mean closing the client. This takes over the bot's "Edit"
-- button (the config editor is still one click away inside) and adds copy / delete / auto-load.
local win, watchEvent
local hijacked                 -- the bot's edit button, with its original text and handler
local NODE = 'botPresets'

local function botPanel() return modules.game_bot and modules.game_bot.contentsPanel end

local function selected()
  local panel = botPanel()
  local ok, opt = pcall(function() return panel.config:getCurrentOption() end)
  return (ok and opt and opt.text) or nil
end

local function presets()
  local out = {}
  for _, name in ipairs(g_resources.listDirectoryFiles("/bot", false, false) or {}) do
    if g_resources.directoryExists("/bot/" .. name) then table.insert(out, name) end
  end
  table.sort(out)
  return out
end

-- ---- who starts on which preset ------------------------------------------------
-- Stored in the client settings under botPresets:
--   presets[name] = { chars = {"Nexo Pala"}, vocs = {"rp", "sniper"} }
--   vocNames["11"] = "sniper"      (the client only reports a vocation id, so the name is taught once)
-- A preset named exactly like the character still wins over both lists.
local VOCATIONS = { "Knight", "Elite Knight", "Gladiator",
                    "Paladin", "Royal Paladin", "Sniper",
                    "Sorcerer", "Master Sorcerer", "Wizard",
                    "Druid", "Elder Druid", "Priest" }
local DEFAULT_VOCS = {
  ek = { "Knight", "Elite Knight", "Gladiator" },
  rp = { "Paladin", "Royal Paladin", "Sniper" },
  ms = { "Sorcerer", "Master Sorcerer", "Wizard" },
  ed = { "Druid", "Elder Druid", "Priest" },
}
-- settings written before the names were spelled out
local OLD_NAMES = { k = "Knight", ek = "Elite Knight", gladiator = "Gladiator",
                    p = "Paladin", rp = "Royal Paladin", sniper = "Sniper",
                    s = "Sorcerer", ms = "Master Sorcerer", wizard = "Wizard",
                    d = "Druid", ed = "Elder Druid", priest = "Priest" }
local NODE = 'botPresets'

local function cfg()
  local node = g_settings.getNode(NODE) or {}
  local out = { presets = {}, vocNames = {} }
  if type(node.presets) == 'table' then
    for name, p in pairs(node.presets) do
      local entry = { chars = {}, vocs = {} }
      for _, v in pairs(type(p.chars) == 'table' and p.chars or {}) do table.insert(entry.chars, tostring(v)) end
      for _, v in pairs(type(p.vocs) == 'table' and p.vocs or {}) do
        table.insert(entry.vocs, OLD_NAMES[tostring(v)] or tostring(v))
      end
      out.presets[name] = entry
    end
  end
  if type(node.vocNames) == 'table' then
    for id, n in pairs(node.vocNames) do
      out.vocNames[tostring(id)] = OLD_NAMES[tostring(n)] or tostring(n)
    end
  end
  -- migrate the old single-binding format
  if type(node.byChar) == 'table' then
    for who, preset in pairs(node.byChar) do
      out.presets[preset] = out.presets[preset] or { chars = {}, vocs = {} }
      table.insert(out.presets[preset].chars, tostring(who))
    end
  end
  return out
end

local function saveCfg(c) g_settings.setNode(NODE, c) end

local function me()
  local p = g_game.getLocalPlayer()
  if not p then return nil, nil end
  local ok, voc = pcall(function() return p:getVocation() end)
  return p:getName(), ok and tostring(voc) or nil
end

local function has(list, value)
  for _, v in ipairs(list or {}) do if v == value then return true end end
  return false
end

local function presetCfg(c, name)
  if not c.presets[name] then
    local vocs = {}
    for _, v in ipairs(DEFAULT_VOCS[name] or {}) do table.insert(vocs, v) end   -- the four shipped presets
    c.presets[name] = { chars = {}, vocs = vocs }
  end
  return c.presets[name]
end

-- what this preset is bound to, for the row label
local function bindingOf(name)
  local c = cfg()
  local who, voc = me()
  local p = c.presets[name]
  if not p then return nil end
  if who and has(p.chars, who) then return 'char', who end
  local vname = voc and c.vocNames[voc]
  if vname and has(p.vocs, vname) then return 'voc', vname end
  return nil
end

local function autoLoad()
  local panel = botPanel()
  if not panel or not g_game.isOnline() then return end
  local who, voc = me()
  local c = cfg()
  local want

  -- a preset named exactly like the character wins over everything
  if who then
    local flat = who:lower():gsub("[^%w]", "")
    for _, name in ipairs(presets()) do
      if name:lower() == who:lower() or name:lower():gsub("[^%w]", "") == flat then want = name end
    end
  end
  if not want and who then
    for name, p in pairs(c.presets) do
      if has(p.chars, who) then want = name break end
    end
  end
  if not want and voc and c.vocNames[voc] then
    local vname = c.vocNames[voc]
    for name, p in pairs(c.presets) do
      if has(p.vocs, vname) then want = name break end
    end
  end
  if not want or want == selected() then return end
  if not g_resources.directoryExists("/bot/" .. want) then return end
  pcall(function() panel.config:setCurrentOption(want) end)   -- the bot's own handler saves and reloads
end

-- ---- file work --------------------------------------------------------------------
local function copyTree(from, to)
  if not g_resources.directoryExists(to) then g_resources.makeDir(to) end
  for _, path in ipairs(g_resources.listDirectoryFiles(from, true, false) or {}) do
    local name = path:match("([^/]+)$")
    if g_resources.directoryExists(path) then
      copyTree(path, to .. "/" .. name)
    else
      local data = g_resources.readFileContents(path)
      if data then g_resources.writeFileContents(to .. "/" .. name, data) end
    end
  end
end

local function deleteTree(dir)
  for _, path in ipairs(g_resources.listDirectoryFiles(dir, true, false) or {}) do
    if g_resources.directoryExists(path) then deleteTree(path) else g_resources.deleteFile(path) end
  end
  g_resources.deleteFile(dir)
end

local refresh

local function afterChange()
  if g_game.isOnline() then pcall(function() modules.game_bot.refresh() end) end
  refresh()
end

local function askCopy(name)
  modules.client_textedit.edit(name .. "2", { title = tr('Copy preset'),
    description = tr('Name for the copy of') .. " '" .. name .. "'" }, function(text)
    local newName = (text or ""):gsub("[^%w_%-]", "")
    if newName == "" then return end
    if g_resources.directoryExists("/bot/" .. newName) then
      return displayErrorBox(tr('Copy preset'), "'" .. newName .. "' " .. tr('already exists.'))
    end
    copyTree("/bot/" .. name, "/bot/" .. newName)
    afterChange()
  end)
end

local function askDelete(name)
  local box
  box = displayGeneralBox(tr('Delete preset'), tr('Delete') .. " '" .. name .. "' " ..
    tr('and everything inside it?'), {
    { text = tr('Delete'), callback = function()
      box:destroy()
      for _ = 1, 3 do
        if not g_resources.directoryExists("/bot/" .. name) then break end
        deleteTree("/bot/" .. name)                      -- the client refuses non-empty folders, so repeat
      end
      if g_resources.directoryExists("/bot/" .. name) then
        displayErrorBox(tr('Delete preset'), tr('Could not remove') .. " bot/" .. name ..
          " - " .. tr('delete the folder by hand.'))
      end
      afterChange()
    end },
    { text = tr('Cancel'), callback = function() box:destroy() end },
  })
end


-- ---- per-preset settings --------------------------------------------------------
local setWin

local function refreshSettingsWindow(name)
  if not setWin or setWin:isDestroyed() then return end
  local c = cfg()
  local p = presetCfg(c, name)
  local who, voc = me()

  local chars = setWin:recursiveGetChildById('chars')
  chars:destroyChildren()
  table.sort(p.chars)
  for _, charName in ipairs(p.chars) do
    local row = g_ui.createWidget('BotPresetCharRow', chars)
    row.name:setText(charName)
    row.removeBtn.onClick = function()
      for i = #p.chars, 1, -1 do if p.chars[i] == charName then table.remove(p.chars, i) end end
      saveCfg(c)
      refreshSettingsWindow(name)
      refresh()
    end
  end
  if #p.chars == 0 then
    local row = g_ui.createWidget('BotPresetCharRow', chars)
    row.name:setText(tr('no characters yet'))
    row.name:setColor('#888888')
    row.removeBtn:hide()
  end

  local vocs = setWin:recursiveGetChildById('vocs')
  vocs:destroyChildren()
  for _, v in ipairs(VOCATIONS) do
    local row = g_ui.createWidget('BotPresetVocRow', vocs)
    row.box:setText(v .. ((voc and c.vocNames[voc] == v) and "   (you)" or ""))
    row.box:setChecked(has(p.vocs, v))
    row.box.onCheckChange = function(_, checked)
      for i = #p.vocs, 1, -1 do if p.vocs[i] == v then table.remove(p.vocs, i) end end
      if checked then table.insert(p.vocs, v) end
      saveCfg(c)
      refresh()
    end
  end

  local hint = setWin:recursiveGetChildById('hint')
  hint:setText(tr("Characters listed start on this preset; vocations cover every character of that vocation.") ..
    "\n" .. tr("A preset named exactly like a character always wins."))

  -- the client only reports a vocation id, so the name is picked here once and reused everywhere
  local label = setWin:recursiveGetChildById('mineLabel')
  local combo = setWin:recursiveGetChildById('mineCombo')
  if not voc then
    label:setText(who and tr("no vocation reported") or tr("not logged in"))
    combo:hide()
    return
  end
  combo:show()
  label:setText(tr("Your vocation") .. " (id " .. voc .. "):")   -- names vary in length, this never clips
  combo.onOptionChange = nil                       -- populating must not count as a choice
  combo:clearOptions()
  combo:addOption(tr('(not set)'))
  for _, v in ipairs(VOCATIONS) do combo:addOption(v) end
  combo:setCurrentOption(c.vocNames[voc] or tr('(not set)'), true)
  combo.onOptionChange = function(_, text)
    c.vocNames[voc] = (text ~= tr('(not set)')) and text or nil
    saveCfg(c)
    refreshSettingsWindow(name)
    refresh()
  end
end

function showSettings(name)
  if setWin and not setWin:isDestroyed() then setWin:destroy() end
  setWin = g_ui.createWidget('BotPresetSettings', g_ui.getRootWidget())
  setWin:setText(tr('Preset settings') .. " - " .. name)
  setWin:centerIn('parent')
  setWin.closeBtn2.onClick = function() setWin:destroy() setWin = nil end
  setWin.onEscape = setWin.closeBtn2.onClick
  setWin.addBtn.onClick = function()
    local who = me()
    if not who then return end
    local c = cfg()
    local p = presetCfg(c, name)
    if not has(p.chars, who) then table.insert(p.chars, who) end
    saveCfg(c)
    refreshSettingsWindow(name)
    refresh()
  end
  refreshSettingsWindow(name)
end

-- ---- window ------------------------------------------------------------------------
refresh = function()
  if not win or win:isDestroyed() then return end
  local list = win:recursiveGetChildById('list')
  local bar = win:recursiveGetChildById('listScroll')
  local scroll = bar and bar:getValue() or 0
  list:destroyChildren()
  local current = selected()
  local ok, running = pcall(function() return botPanel().enableButton:isOn() end)
  running = ok and running or false
  local who, voc = me()
  if win.enableBtn then
    win.enableBtn:setText(running and tr('Disable bot') or tr('Enable bot'))
  end
  for _, name in ipairs(presets()) do
    local row = g_ui.createWidget('BotPresetRow', list)
    local kind, key = bindingOf(name)
    local tag = ""
    if name == current then tag = tag .. "  (selected)" end
    if kind == 'char' then tag = tag .. "  [" .. key .. "]"
    elseif kind == 'voc' then tag = tag .. "  [vocation " .. key .. "]" end
    row.name:setText(name .. tag)
    row.useBtn:setEnabled(name ~= current)
    row.useBtn:setTooltip(tr('Select this preset'))
    row.useBtn.onClick = function()
      pcall(function() botPanel().config:setCurrentOption(name) end)   -- the bot saves and reloads itself
      refresh()
    end
    row.copyBtn.onClick = function() askCopy(name) end
    row.delBtn:setEnabled(not (running and name == current))
    row.delBtn.onClick = function() askDelete(name) end
    row.setBtn:setTooltip(tr('Characters and vocations that start on this preset'))
    row.setBtn:setOn(kind ~= nil)
    row.setBtn.onClick = function() showSettings(name) end
  end
  if bar then bar:setValue(scroll) end
end

function show()
  if win and not win:isDestroyed() then win:raise() win:focus() refresh() return end
  win = g_ui.createWidget('BotPresetsWindow', g_ui.getRootWidget())
  win:centerIn('parent')
  win.closeBtn.onClick = function() win:destroy() win = nil end
  win.onEscape = win.closeBtn.onClick
  win.editBtn.onClick = function() pcall(function() modules.game_bot.edit() end) end
  win.enableBtn.onClick = function()
    local panel = botPanel()
    local btn = panel and panel.enableButton
    if btn and btn.onClick then pcall(function() btn.onClick(btn) end) end
    refresh()
  end
  refresh()
end

-- ---- attach to the bot window ------------------------------------------------------
local function attach()
  local panel = botPanel()
  local btn = panel and panel.editConfig
  if not btn or btn:isDestroyed() then hijacked = nil return false end
  if hijacked and hijacked.btn == btn then return true end
  local combo = panel.config
  hijacked = { btn = btn, text = btn:getText(), onClick = btn.onClick,
               combo = combo, comboMargin = combo and combo:getMarginRight() }
  if combo then combo:setMarginRight(108) end          -- widen the gap so the label fits the button
  btn:setText(tr('Presets'))
  btn:setTooltip(tr('Copy, delete and auto-load bot presets'))
  btn.onClick = show
  return true
end

-- Ctrl+Shift+R rebuilds every module: the bot window comes back but stays hidden, because only a login
-- triggers its autoOpen. We re-open it for the first few seconds after a reload, then leave it alone so a
-- window you closed on purpose stays closed.
local restoreUntil = 0

local function restoreBotWindow()
  if g_clock.millis() > restoreUntil or not g_game.isOnline() then return end
  local bw = modules.game_bot and modules.game_bot.botWindow
  if bw and not bw:isDestroyed() and not bw:isVisible() then pcall(function() bw:show() end) end
end

function init()
  g_ui.importStyle('presets.otui')
  restoreUntil = g_clock.millis() + 12000
  attach()
  -- the bot window is rebuilt on a module reload (Ctrl+Shift+R), so keep checking rather than attaching once
  watchEvent = cycleEvent(function() attach() autoLoad() restoreBotWindow() end, 1000)
  connect(g_game, { onGameStart = autoLoad })
end

function terminate()
  disconnect(g_game, { onGameStart = autoLoad })
  if watchEvent then removeEvent(watchEvent) watchEvent = nil end
  if win and not win:isDestroyed() then win:destroy() end
  win = nil
  if hijacked and hijacked.btn and not hijacked.btn:isDestroyed() then
    hijacked.btn:setText(hijacked.text)
    hijacked.btn.onClick = hijacked.onClick
    if hijacked.combo and not hijacked.combo:isDestroyed() and hijacked.comboMargin then
      hijacked.combo:setMarginRight(hijacked.comboMargin)
    end
  end
  hijacked = nil
end
