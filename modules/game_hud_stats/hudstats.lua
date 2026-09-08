-- EXP/H and DPS lines appended to the game_stats overlay (below FPS / Ping).
EXP_WINDOW = 15 * 60   -- seconds of rolling window for "current" exp/h
DPS_WINDOW = 10        -- seconds of rolling window for "current" dps
KILLS_WINDOW = 60 * 60 -- seconds of rolling window for kills per hour
GRAPH_MINUTES = 15     -- history shown in the inline graphs (one point per second)
-- Server Log lines for damage you take (hitpoints, or mana while on mana shield)
DAMAGE_RECEIVED_PATTERNS = {
  "You lose (%d+) hitpoints? due to",
  "You lose (%d+) mana due to",
  "You lose (%d+) mana blocking",
}
MIN_DIVISOR = 60       -- rates use at least this many seconds of time: a fresh window can only undershoot,
                       -- never inflate, so records may update from the first second without any gate
-- Server Log lines that carry damage dealt by you; first capture = damage.
DAMAGE_PATTERNS = {
  "loses (%d+) hitpoints? due to your attack",
}
-- Server exp stages: { minLevel, maxLevel, multiplier }. Raw exp/h = exp/h / multiplier for your level.
-- FILL IN with the server's real stages; until then everything is treated as x1.
EXP_STAGES = {
  -- { 1, 50, 5 },
  -- { 51, 100, 3 },
}
EXP_RATE_DEFAULT = 1
-- Ask the server for the live rate (TFS "!serverinfo" -> "Exp rate: 2"); beats the table when present.
SERVERINFO_COMMAND = "!serverinfo"
SERVERINFO_PATTERN = "Exp rate:%s*([%d%.]+)"
-- Kill detection: "health" = a monster on screen drops to 0% HP (works on any server, counts
-- other players' kills too); "messages" = one kill per Server Log line matching KILL_PATTERNS.
KILL_SOURCE = "health"
KILL_PATTERNS = {
  "^Loot of ",
}
HEADER_COLOR = '#ffdd55'  -- default theme color (headers + graph lines); the picker overrides it
THEME_COLORS = { r = '#ff5555', g = '#55ff55', b = '#5599ff', c = '#55ffff', m = '#ff55ff', y = '#ffdd55' }
VALUE_COLOR = '#ffffff'
SECTION_SPACING = 6       -- px above each "-- SECTION" header
MIN_CONTENT = 60          -- px: smallest content height the window can be dragged to

local labels = {}
local rows = {}          -- name -> label
local exp = { current = 0, maxLifetime = 0, maxSession = 0, samples = {} }
local dps = { current = 0, maxLifetime = 0, maxSession = 0, hits = {} }
local raw = { current = 0, maxLifetime = 0, maxSession = 0 }
local extra = { expLeft = 0, etaSeconds = nil, killsPerHour = 0, expPerKill = nil }
local kill = { total = 0 } -- lifetime kills, persisted per character
local hps = { current = 0, maxLifetime = 0, maxSession = 0 } -- health gained per second (potions, spells, regen)
local mps = { current = 0, maxLifetime = 0, maxSession = 0 } -- mana gained per second
local drps = { current = 0, maxLifetime = 0, maxSession = 0 } -- damage received per second
local rateOverride = nil -- set from the terminal with setExpRate(x)
local rateFromServer = nil -- parsed from the !serverinfo reply
local serverInfoEvent = nil

-- stamina multiplies the exp the server hands out on top of the stage rate; raw exp must strip it too.
-- Tibia default: > 40 h = 150 %, 14-40 h = 100 %, < 14 h = 50 % (minutes; tune for Pegaz if different)
STAMINA_BONUS = { { minMinutes = 2400, factor = 1.5 }, { minMinutes = 840, factor = 1.0 }, { minMinutes = 0, factor = 0.5 } }
local function staminaFactor()
  local p = g_game.getLocalPlayer()
  local stamina = p and p:getStamina() or 0
  for _, step in ipairs(STAMINA_BONUS) do
    if stamina >= step.minMinutes then return step.factor end
  end
  return 1
end

local function expRate(level)
  if rateOverride then return rateOverride end
  if rateFromServer then return rateFromServer end
  for _, stage in ipairs(EXP_STAGES) do
    if level >= stage[1] and level <= stage[2] then return stage[3] end
  end
  return EXP_RATE_DEFAULT
end

-- per-session state kept on the LocalPlayer, like the built-in exp counter does
local function sessionState(player)
  local st = player.hudStats or {}
  player.hudStats = st
  -- backfill: the state survives module reloads, so it may predate newer fields
  st.expSamples = st.expSamples or {}
  st.dpsHits = st.dpsHits or {}
  st.kills = st.kills or {}
  st.killsSession = st.killsSession or 0
  st.expMax = st.expMax or 0
  st.dpsMax = st.dpsMax or 0
  st.rawMax = st.rawMax or 0
  st.hpsHits = st.hpsHits or {}
  st.mpsHits = st.mpsHits or {}
  st.hpsMax = st.hpsMax or 0
  st.mpsMax = st.mpsMax or 0
  st.drpsHits = st.drpsHits or {}
  st.drpsMax = st.drpsMax or 0
  st.rawCum = st.rawCum or 0        -- cumulative exp converted to raw at the rate of the second it was earned
  st.pendingExp = st.pendingExp or 0 -- exp earned while the new rate after a level-up is still unknown
  return st
end
local updateEvent = nil
local lastSave = 0
local charKey = nil

local function fmtBig(n)
  if n >= 1e9 then return string.format("%.2fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
  return tostring(math.floor(n))
end

local window, contents, button = nil, nil, nil
local graphs = {}          -- key -> { widget = UIGraph, vals = ring of raw values, lmax/lmin = axis labels }
local headerLabels = {}
local sections, currentSection = {}, nil -- key -> { title, header, rows, graph, visible, graphVisible }
local themeColor = HEADER_COLOR
local graphsVisible = true
local fitHeight -- defined below; header click handlers close over it
local clearGraphs -- defined below; onGameStart uses it

local function fmtDuration(seconds)
  if seconds >= 86400 then return string.format("%dd %dh", seconds / 86400, (seconds % 86400) / 3600) end
  if seconds >= 3600 then return string.format("%dh %02dm", seconds / 3600, (seconds % 3600) / 60) end
  return string.format("%dm %02ds", seconds / 60, seconds % 60)
end

local function expForLevel(level)
  if modules.game_skills and modules.game_skills.expForLevel then
    return modules.game_skills.expForLevel(level)
  end
  return math.floor((50 * level * level * level) / 3 - 100 * level * level + (850 * level) / 3 - 200)
end

local function sectionHeaderText(sec)
  return sec.visible and ("-- " .. sec.title .. " --") or ("+ " .. sec.title .. " +")
end

local function applySections()
  for _, sec in pairs(sections) do
    sec.header:setText(sectionHeaderText(sec))
    for _, row in ipairs(sec.rows) do row:setVisible(sec.visible) end
    if sec.graph then sec.graph.widget:setVisible(graphsVisible and sec.visible and sec.graphVisible) end
  end
end

local function saveSections()
  local node = {}
  for key, sec in pairs(sections) do node[key] = { show = sec.visible, graph = sec.graphVisible } end
  g_settings.setNode('hudStatsSections', node)
end

-- left click: collapse/expand the section; right click: toggle only its graph
local function addHeader(title, key)
  local label = g_ui.createWidget('HudStatsHeader', contents)
  label:setColor(themeColor)
  label:setMarginTop(SECTION_SPACING)
  local saved = (g_settings.getNode('hudStatsSections') or {})[key] or {}
  local sec = { title = title, header = label, rows = {}, graph = nil,
                visible = saved.show ~= false, graphVisible = saved.graph ~= false }
  sections[key] = sec
  currentSection = sec
  label:setText(sectionHeaderText(sec))
  label.onClick = function()
    sec.visible = not sec.visible
    saveSections(); applySections(); fitHeight()
  end
  label.onMouseRelease = function(widget, mousePos, mouseButton)
    if mouseButton == MouseRightButton then
      sec.graphVisible = not sec.graphVisible
      saveSections(); applySections(); fitHeight()
      return true
    end
    return false
  end
  table.insert(labels, label)
  table.insert(headerLabels, label)
  return label
end

-- one line: name at the left, value right-aligned; returns the value label
local function addRow(name)
  local row = g_ui.createWidget('HudStatsRow', contents)
  row.name:setText(name)
  table.insert(labels, row)
  if currentSection then table.insert(currentSection.rows, row) end
  return row.value
end

-- fixed window height = all lines + their margins
fitHeight = function()
  if not window or not contents then return end
  local h = 4
  for _, child in ipairs(contents:getChildren()) do
    if child:isExplicitlyVisible() then -- not isVisible(): a hidden parent panel would zero the height
      h = h + child:getHeight() + child:getMarginTop() + child:getMarginBottom()
    end
  end
  -- resizable between MIN_CONTENT and the full content; the contents panel scrolls when shorter
  local wasAtMax = window.hudMax and window:getHeight() >= window.hudMax
  window:setContentMinimumHeight(math.min(MIN_CONTENT, h))
  window:setContentMaximumHeight(h)
  window.hudMax = window:getMaximumHeight()
  local cur = window:getHeight()
  if not window.hudSized then
    window.hudSized = true
    local saved = g_settings.getNode('MiniWindows')
    saved = saved and saved[window:getId()]
    if not (saved and saved.height) then window:setContentHeight(h) end -- first run: show everything
  elseif wasAtMax then
    window:setContentHeight(h) -- was showing everything, keep showing everything
  end
  cur = window:getHeight()
  if cur < window:getMinimumHeight() then window:setHeight(window:getMinimumHeight())
  elseif cur > window:getMaximumHeight() then window:setHeight(window:getMaximumHeight()) end
end

local function addGraph(key)
  local g = g_ui.createWidget('HudGraph', contents)
  g:setCapacity(GRAPH_MINUTES * 60)
  pcall(function() g:setShowLabels(false) end) -- the rows above already show the exact values
  g:setColor(themeColor)
  g:addValue(0)
  g:setVisible(graphsVisible)
  -- own axis labels: window max (top-right) and min (bottom-right); the built-in labels stay off
  local lmax = g_ui.createWidget('HudGraphLabel', g)
  lmax:addAnchor(AnchorTop, 'parent', AnchorTop)
  lmax:addAnchor(AnchorRight, 'parent', AnchorRight)
  local lmin = g_ui.createWidget('HudGraphLabel', g)
  lmin:addAnchor(AnchorBottom, 'parent', AnchorBottom)
  lmin:addAnchor(AnchorRight, 'parent', AnchorRight)
  graphs[key] = { widget = g, vals = {}, lmax = lmax, lmin = lmin }
  if currentSection then currentSection.graph = graphs[key] end
  table.insert(labels, g)
  return g
end

-- remember raw values for the axis labels and refresh them
local function trackGraph(gr, rawValue)
  table.insert(gr.vals, rawValue)
  if #gr.vals > GRAPH_MINUTES * 60 then table.remove(gr.vals, 1) end
  local lo, hi = gr.vals[1], gr.vals[1]
  for _, v in ipairs(gr.vals) do
    if v < lo then lo = v end
    if v > hi then hi = v end
  end
  gr.lmax:setText(fmtBig(hi))
  gr.lmin:setText(fmtBig(lo))
end

-- UIGraph draws one value per pixel column, so GRAPH_MINUTES only fit if we add one point
-- every `step` seconds (average of those seconds), with step derived from the graph's width
local function pushPoint(gr, plotValue)
  local width = math.max(60, gr.widget:getWidth() - 8)
  local step = math.max(1, math.ceil(GRAPH_MINUTES * 60 / width))
  gr.accSum = (gr.accSum or 0) + plotValue
  gr.accN = (gr.accN or 0) + 1
  if gr.accN >= step then
    gr.widget:addValue(math.floor(gr.accSum / gr.accN + 0.5))
    gr.accSum, gr.accN = 0, 0
  end
end

local function feedGraph(key, value)
  local gr = graphs[key]
  if not gr then return end
  pushPoint(gr, value)
  trackGraph(gr, value)
end

-- exp/h graphs are drawn in K or M so the axis numbers stay short; the graph title names the unit
local function expGraphScale(maxValue)
  if maxValue >= 1e6 then return 1e6, "M" end
  return 1e3, "K"
end

local function feedExpGraph(key, value, maxValue)
  local gr = graphs[key]
  if not gr then return end
  local div, unit = expGraphScale(math.max(maxValue, value))
  if gr.unit ~= unit then
    gr.unit = unit
    gr.widget:clear()
  end
  pushPoint(gr, value / div)
  trackGraph(gr, value)
end

local function applyGraphsVisibility()
  applySections()
  local btn = window and window:recursiveGetChildById('graphs')
  if btn then btn:setText(graphsVisible and tr('Hide graphs') or tr('Show graphs')) end
  fitHeight()
end

local function loadLifetime()
  charKey = g_game.getCharacterName() or "unknown"
  local node = g_settings.getNode('hudStats') or {}
  local mine = node[charKey] or {}
  exp.maxLifetime = tonumber(mine.expMax) or 0
  dps.maxLifetime = tonumber(mine.dpsMax) or 0
  raw.maxLifetime = tonumber(mine.rawMax) or 0
  kill.total = tonumber(mine.killsTotal) or 0
  hps.maxLifetime = tonumber(mine.hpsMax) or 0
  mps.maxLifetime = tonumber(mine.mpsMax) or 0
  drps.maxLifetime = tonumber(mine.drpsMax) or 0
end

local function saveLifetime(force)
  if not charKey then return end
  local node = g_settings.getNode('hudStats') or {}
  node[charKey] = { expMax = exp.maxLifetime, dpsMax = dps.maxLifetime, rawMax = raw.maxLifetime, killsTotal = kill.total,
                    hpsMax = hps.maxLifetime, mpsMax = mps.maxLifetime, drpsMax = drps.maxLifetime }
  g_settings.setNode('hudStats', node)
  -- flush to disk at most every 30 s: a freeze + force quit must not lose a new record
  if force or g_clock.seconds() - lastSave > 30 then
    g_settings.save()
    lastSave = g_clock.seconds()
  end
end

local function refresh()
  rows.expCur:setText(fmtBig(exp.current))
  rows.expSes:setText(fmtBig(exp.maxSession))
  rows.expLif:setText(fmtBig(exp.maxLifetime))
  rows.lvlExp:setText(fmtBig(extra.expLeft))
  rows.lvlTime:setText(extra.etaSeconds and fmtDuration(extra.etaSeconds) or "-")
  local player = g_game.getLocalPlayer()
  local rate = expRate(player and player:getLevel() or 0)
  local src = rateOverride and " manual" or (rateFromServer and "" or " table")
  if sections.raw then
    -- raw is always the 1x figure (stage rate and stamina are divided out per second); flag only a non-server rate
    sections.raw.title = "Raw Exp/H (x1)"
    sections.raw.header:setText(sectionHeaderText(sections.raw))
  end
  rows.rawCur:setText(fmtBig(raw.current))
  rows.rawSes:setText(fmtBig(raw.maxSession))
  rows.rawLif:setText(fmtBig(raw.maxLifetime))
  rows.dpsCur:setText(fmtBig(dps.current))
  rows.dpsSes:setText(fmtBig(dps.maxSession))
  rows.dpsLif:setText(fmtBig(dps.maxLifetime))
  local sessionKills = player and sessionState(player).killsSession or 0
  rows.killTotal:setText(fmtBig(kill.total))
  rows.killSession:setText(tostring(sessionKills))
  rows.killPerH:setText(tostring(math.floor(extra.killsPerHour + 0.5)))
  rows.hpsCur:setText(fmtBig(hps.current))
  rows.hpsSes:setText(fmtBig(hps.maxSession))
  rows.hpsLif:setText(fmtBig(hps.maxLifetime))
  rows.mpsCur:setText(fmtBig(mps.current))
  rows.mpsSes:setText(fmtBig(mps.maxSession))
  rows.mpsLif:setText(fmtBig(mps.maxLifetime))
  rows.drpsCur:setText(fmtBig(drps.current))
  rows.drpsSes:setText(fmtBig(drps.maxSession))
  rows.drpsLif:setText(fmtBig(drps.maxLifetime))
end

local function update()
  updateEvent = scheduleEvent(update, 1000)
  local player = g_game.getLocalPlayer()
  if not player or not g_game.isOnline() then return end
  local now = g_clock.seconds()
  local st = sessionState(player)
  exp.samples, dps.hits = st.expSamples, st.dpsHits

  -- raw accounting: convert this second's gain with the rate in effect now (or park it while the
  -- rate after a level-up is still unknown), so a stage change never rescales old exp
  local expNow = player:getExperience()
  if st.lastExp and expNow > st.lastExp then
    local delta = expNow - st.lastExp
    if st.awaitingRate and now < st.awaitingRate then
      st.pendingExp = st.pendingExp + delta
    else
      if st.awaitingRate then -- no answer in time: convert what was parked with the rate we know
        st.rawCum = st.rawCum + st.pendingExp / (expRate(player:getLevel()) * staminaFactor())
        st.pendingExp, st.awaitingRate = 0, nil
      end
      st.rawCum = st.rawCum + delta / (expRate(player:getLevel()) * staminaFactor())
    end
  end
  st.lastExp = expNow
  if exp.samples[1] and exp.samples[1][3] == nil then st.expSamples = {}; exp.samples = st.expSamples end -- old format
  -- exp/h: oldest sample inside the window vs now; samples = { time, exp, rawCum }
  table.insert(exp.samples, { now, expNow, st.rawCum })
  while #exp.samples > 2 and exp.samples[1][1] < now - EXP_WINDOW do
    table.remove(exp.samples, 1)
  end
  local first = exp.samples[1]
  local dt = now - first[1]
  local gained = expNow - first[2]
  local rawGained = st.rawCum - first[3]
  if gained < 0 then -- death or level loss: restart the window
    st.expSamples = { { now, expNow, st.rawCum } }
    exp.samples, gained, rawGained, dt = st.expSamples, 0, 0, 0
  end
  exp.current = gained / math.max(dt, MIN_DIVISOR) * 3600

  -- dps / hps / mps: events inside a DPS_WINDOW-second window
  local function windowRate(hits)
    local cutoff = now - DPS_WINDOW
    while #hits > 0 and hits[1][1] < cutoff do table.remove(hits, 1) end
    local sum = 0
    for _, hit in ipairs(hits) do sum = sum + hit[2] end
    return sum / DPS_WINDOW
  end
  dps.current = windowRate(dps.hits)
  hps.current = windowRate(st.hpsHits)
  mps.current = windowRate(st.mpsHits)
  drps.current = windowRate(st.drpsHits)

  raw.current = (rawGained + st.pendingExp / (expRate(player:getLevel()) * staminaFactor())) / math.max(dt, MIN_DIVISOR) * 3600

  -- level ETA at the current exp/h
  extra.expLeft = math.max(0, expForLevel(player:getLevel() + 1) - player:getExperience())
  extra.etaSeconds = exp.current > 0 and (extra.expLeft / exp.current * 3600) or nil

  -- kills per hour over their own (longer) rolling window; before the window is full,
  -- the divisor is the time since login so early numbers are not inflated by a short span
  local kills = st.kills
  while #kills > 0 and kills[1] < now - KILLS_WINDOW do table.remove(kills, 1) end
  -- anchor: login time, or the oldest retained kill if the state predates this field (reload mid-session)
  st.loginTime = math.min(st.loginTime or now, kills[1] or now)
  local killSpan = math.max(math.min(now - st.loginTime, KILLS_WINDOW), MIN_DIVISOR)
  extra.killsPerHour = #kills / killSpan * 3600

  local record = false
  if exp.current > st.expMax then st.expMax = exp.current end
  if raw.current > st.rawMax then st.rawMax = raw.current end
  if dps.current > st.dpsMax then st.dpsMax = dps.current end
  if hps.current > st.hpsMax then st.hpsMax = hps.current end
  if mps.current > st.mpsMax then st.mpsMax = mps.current end
  if drps.current > st.drpsMax then st.drpsMax = drps.current end
  exp.maxSession, dps.maxSession, raw.maxSession = st.expMax, st.dpsMax, st.rawMax
  hps.maxSession, mps.maxSession, drps.maxSession = st.hpsMax, st.mpsMax, st.drpsMax
  if exp.maxSession > exp.maxLifetime then exp.maxLifetime = exp.maxSession; record = true end
  if raw.maxSession > raw.maxLifetime then raw.maxLifetime = raw.maxSession; record = true end
  if hps.maxSession > hps.maxLifetime then hps.maxLifetime = hps.maxSession; record = true end
  if mps.maxSession > mps.maxLifetime then mps.maxLifetime = mps.maxSession; record = true end
  if drps.maxSession > drps.maxLifetime then drps.maxLifetime = drps.maxSession; record = true end
  if dps.maxSession > dps.maxLifetime then dps.maxLifetime = dps.maxSession; record = true end
  if record then saveLifetime(false) end
  feedExpGraph('exp', exp.current, exp.maxSession)
  feedExpGraph('raw', raw.current, raw.maxSession)
  feedGraph('dps', dps.current)
  feedGraph('hps', hps.current)
  feedGraph('mps', mps.current)
  feedGraph('drps', drps.current)
  feedGraph('kills', extra.killsPerHour)
  refresh()
end

local function queryServerRate(delay)
  removeEvent(serverInfoEvent)
  serverInfoEvent = scheduleEvent(function()
    if g_game.isOnline() then g_game.talk(SERVERINFO_COMMAND) end
  end, delay or 3000)
end

local function onHealthChange(localPlayer, health, maxHealth)
  local st = sessionState(localPlayer)
  if st.lastHealth and st.lastMaxHealth == maxHealth then
    if health > st.lastHealth then
      table.insert(st.hpsHits, { g_clock.seconds(), health - st.lastHealth })
    end
  end
  st.lastHealth, st.lastMaxHealth = health, maxHealth
end

local function onManaChange(localPlayer, mana, maxMana)
  local st = sessionState(localPlayer)
  if st.lastMana and st.lastMaxMana == maxMana and mana > st.lastMana then
    table.insert(st.mpsHits, { g_clock.seconds(), mana - st.lastMana })
  end
  st.lastMana, st.lastMaxMana = mana, maxMana
end

local function onLevelChange(localPlayer, level, percent)
  if not rateOverride and #EXP_STAGES == 0 then -- rate comes from the server: it may have changed
    sessionState(localPlayer).awaitingRate = g_clock.seconds() + 6
    queryServerRate(0)
  end
end

local recentDeaths = {} -- creature id -> time, so one death is counted once

local function recordKill()
  local player = g_game.getLocalPlayer()
  if not player then return end
  local st = sessionState(player)
  table.insert(st.kills, g_clock.seconds())
  st.killsSession = st.killsSession + 1
  kill.total = kill.total + 1
  saveLifetime(false) -- throttled write, so a force-quit loses at most 30 s of kills
end

local function onCreatureHealthPercentChange(creature, percent)
  if KILL_SOURCE ~= "health" or percent > 0 then return end
  if not creature:isMonster() then return end
  local id, now = creature:getId(), g_clock.seconds()
  if recentDeaths[id] and now - recentDeaths[id] < 10 then return end
  recentDeaths[id] = now
  recordKill()
end

local function onTextMessage(mode, text)
  for _, pattern in ipairs(DAMAGE_RECEIVED_PATTERNS) do
    local dmg = text:match(pattern)
    if dmg then
      local player = g_game.getLocalPlayer()
      if player then table.insert(sessionState(player).drpsHits, { g_clock.seconds(), tonumber(dmg) }) end
      return
    end
  end
  if KILL_SOURCE == "messages" then
    for _, pattern in ipairs(KILL_PATTERNS) do
      if text:match(pattern) then recordKill() return end
    end
  end
  local rate = text:match(SERVERINFO_PATTERN)
  if rate then
    rateFromServer = tonumber(rate)
    local player = g_game.getLocalPlayer()
    if player then
      local st = sessionState(player)
      if st.awaitingRate then
        st.rawCum = st.rawCum + st.pendingExp / (rateFromServer * staminaFactor())
        st.pendingExp, st.awaitingRate = 0, nil
      end
    end
    refresh()
    return
  end
  local player = g_game.getLocalPlayer()
  if not player then return end
  for _, pattern in ipairs(DAMAGE_PATTERNS) do
    local dmg = text:match(pattern)
    if dmg then
      table.insert(sessionState(player).dpsHits, { g_clock.seconds(), tonumber(dmg) })
      return
    end
  end
end

local function onGameStart()
  exp.current, exp.maxSession, dps.current, dps.maxSession = 0, 0, 0, 0
  raw.current, raw.maxSession = 0, 0
  hps.current, hps.maxSession, mps.current, mps.maxSession = 0, 0, 0, 0
  drps.current, drps.maxSession = 0, 0
  rateFromServer = nil
  if clearGraphs then clearGraphs() end -- a new character must not inherit the previous one's lines
  loadLifetime()
  refresh()
  if fitHeight then fitHeight() end
  queryServerRate(3000)
end

-- Console helpers (Lua terminal, Ctrl+T):
--   modules.game_hud_stats.setLifetime(expPerHour, dps, rawPerHour)  -- nil keeps a value
--   modules.game_hud_stats.resetLifetime()                           -- lifetime = this session's peaks
--   modules.game_hud_stats.setExpRate(2)                             -- override the stage table (nil = back to table)
function setLifetime(expMax, dpsMax, rawMax, killsTotal, hpsMax, mpsMax, drpsMax)
  if expMax then exp.maxLifetime = tonumber(expMax) end
  if dpsMax then dps.maxLifetime = tonumber(dpsMax) end
  if rawMax then raw.maxLifetime = tonumber(rawMax) end
  if killsTotal then kill.total = tonumber(killsTotal) end
  if hpsMax then hps.maxLifetime = tonumber(hpsMax) end
  if mpsMax then mps.maxLifetime = tonumber(mpsMax) end
  if drpsMax then drps.maxLifetime = tonumber(drpsMax) end
  saveLifetime(true)
  refresh()
end

-- wipe lifetime records; the current session's peaks re-seed them on the next tick
function resetLifetime()
  setLifetime(0, 0, 0, 0, 0, 0, 0)
end

function confirmResetLifetime()
  local box
  local yes = function() resetLifetime() box:destroy() end
  local no = function() box:destroy() end
  box = displayGeneralBox(tr('Reset lifetime stats'),
    tr('Clear the lifetime records of this character?\n(exp/h, raw exp/h, dps and total kills)'),
    { { text = tr('Yes'), callback = yes }, { text = tr('No'), callback = no } }, yes, no)
end

clearGraphs = function()
  for _, gr in pairs(graphs) do
    gr.widget:clear()
    gr.widget:addValue(0)
    gr.vals = {}
    gr.unit = nil
    gr.accSum, gr.accN = 0, 0
    gr.lmax:setText("")
    gr.lmin:setText("")
  end
end

-- start the session over: windows, session maxes and session kills
function resetSession()
  local player = g_game.getLocalPlayer()
  if player then player.hudStats = nil end
  exp.current, exp.maxSession, raw.current, raw.maxSession = 0, 0, 0, 0
  dps.current, dps.maxSession, extra.killsPerHour = 0, 0, 0
  hps.current, hps.maxSession, mps.current, mps.maxSession = 0, 0, 0, 0
  drps.current, drps.maxSession = 0, 0
  clearGraphs()
  refresh()
end

function setExpRate(rate)
  rateOverride = tonumber(rate)
  refresh()
end

function refreshServerRate()
  queryServerRate(0)
end

local function onGameEnd()
  saveLifetime(true)
end


-- color picker (dots under the buttons): recolors section headers and graph lines
function setColor(hex)
  themeColor = hex
  g_settings.set('hudStatsColor', hex)
  for _, l in ipairs(headerLabels) do l:setColor(hex) end
  for _, gr in pairs(graphs) do gr.widget:setColor(hex) end
end

function toggleGraphs()
  graphsVisible = not graphsVisible
  g_settings.set('hudStatsGraphs', graphsVisible)
  applyGraphsVisibility()
end

function toggle()
  if window:isVisible() then
    window:close()
  else
    window:open()
  end
end

function onMiniWindowClose()
  if button then button:setOn(false) end
end

function init()
  -- second left panel if it exists, else whatever left panel there is; the user can drag it anywhere,
  -- the mini-window remembers its place (&save: true)
  local root = modules.game_interface.getRootPanel()
  local parent = root:recursiveGetChildById('leftPanel2') or modules.game_interface.getLeftPanel()
  window = g_ui.loadUI('hudstats', parent)
  contents = window:getChildById('contentsPanel')
  button = modules.client_topmenu.addRightGameToggleButton('hudStatsButton', tr('Stats'), '/images/topbuttons/analyzers', toggle, false, 1001)
  window.onOpen = function() if button then button:setOn(true) end end
  window:setup()
  if button then button:setOn(window:isVisible()) end
  if g_settings.exists('hudStatsGraphs') then graphsVisible = g_settings.getBoolean('hudStatsGraphs') end
  if g_settings.exists('hudStatsColor') then themeColor = g_settings.getString('hudStatsColor') end

  addHeader("Next Level", "lvl")
  rows.lvlExp = addRow("Exp:")
  rows.lvlTime = addRow("Time:")
  addHeader("Exp/H", "exp")
  rows.expCur = addRow("Current:")
  rows.expSes = addRow("Max session:")
  rows.expLif = addRow("Max lifetime:")
  addGraph('exp')
  rows.rawHdr = addHeader("Raw Exp/H", "raw")
  rows.rawCur = addRow("Current:")
  rows.rawSes = addRow("Max session:")
  rows.rawLif = addRow("Max lifetime:")
  addGraph('raw')
  addHeader("DPS", "dps")
  rows.dpsCur = addRow("Current:")
  rows.dpsSes = addRow("Max session:")
  rows.dpsLif = addRow("Max lifetime:")
  addGraph('dps')
  addHeader("HPS", "hps")
  rows.hpsCur = addRow("Current:")
  rows.hpsSes = addRow("Max session:")
  rows.hpsLif = addRow("Max lifetime:")
  addGraph('hps')
  addHeader("MPS", "mps")
  rows.mpsCur = addRow("Current:")
  rows.mpsSes = addRow("Max session:")
  rows.mpsLif = addRow("Max lifetime:")
  addGraph('mps')
  addHeader("Dmg Received/s", "drps")
  rows.drpsCur = addRow("Current:")
  rows.drpsSes = addRow("Max session:")
  rows.drpsLif = addRow("Max lifetime:")
  addGraph('drps')
  addHeader("Kills", "kills")
  rows.killTotal = addRow("Total:")
  rows.killSession = addRow("Session:")
  rows.killPerH = addRow("Per H:")
  addGraph('kills')
  currentSection = nil
  table.insert(labels, g_ui.createWidget('HudStatsButtons', contents))
  local picker = g_ui.createWidget('HudColorPicker', contents)
  for key, hex in pairs(THEME_COLORS) do
    local dot = picker:recursiveGetChildById(key)
    if dot then
      dot:setImageColor(hex) -- tints the white disc
      dot.onClick = function() setColor(hex) end
    end
  end
  local help = picker:recursiveGetChildById('help')
  if help then
    help:setTooltip(tr("Section headers:\n  left click  - collapse / expand the section\n  right click - show / hide only its graph\n\nGraphs button: all graphs on / off\nColor dots: theme for headers and graph lines\nGraph corners: max (top) and min (bottom) of the shown window"))
  end
  table.insert(labels, picker)
  applyGraphsVisibility()

  connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd, onTextMessage = onTextMessage })
  connect(LocalPlayer, { onLevelChange = onLevelChange, onHealthChange = onHealthChange, onManaChange = onManaChange })
  connect(Creature, { onHealthPercentChange = onCreatureHealthPercentChange })
  if g_game.isOnline() then onGameStart() else refresh() end
  updateEvent = scheduleEvent(update, 1000)
end

function terminate()
  disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd, onTextMessage = onTextMessage })
  disconnect(LocalPlayer, { onLevelChange = onLevelChange, onHealthChange = onHealthChange, onManaChange = onManaChange })
  disconnect(Creature, { onHealthPercentChange = onCreatureHealthPercentChange })
  removeEvent(updateEvent)
  removeEvent(serverInfoEvent)
  saveLifetime(true)
  if button then button:destroy() button = nil end
  if window then window:destroy() window = nil end
  graphs = {}
  labels, rows, contents, headerLabels, sections, currentSection = {}, {}, nil, {}, {}, nil
end
