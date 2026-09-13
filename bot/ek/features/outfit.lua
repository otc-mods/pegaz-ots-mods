-- Outfit colours: cycle them, or copy someone else's.
--
-- The palette is the client's own 133 entries, 7 rows of 19. Row 4 (77..94) is the fully saturated one, so
-- that is the row the cycles walk: 77 orange, 79 yellow, 82 green, 85 cyan, 88 blue, 91 magenta, 94 red.
-- Every change is a real changeOutfit, so everyone sees it - which also means every tick is a packet.
setDefaultTab("Tools")

local tabPanel = panel
panel = UI.section("toolsOutfit", "Outfit", tabPanel)

local G = modules._G
local MODES = { "Random", "Rainbow", "RGB", "CMYK" }
local RAINBOW = {}
for i = 77, 94 do RAINBOW[#RAINBOW + 1] = i end
local RGB = { 94, 82, 88 }                      -- red, green, blue
local CMYK = { 85, 91, 79, 114 }                -- cyan, magenta, yellow, near-black (the palette has no black)
local MIN_SPEED, MAX_SPEED = 50, 1000

if type(storage.outfitCfg) ~= "table" then storage.outfitCfg = {} end
local cfg = storage.outfitCfg
cfg.mode = cfg.mode or "Rainbow"
if cfg.mode == "Copy" then cfg.mode = "Rainbow" end   -- Copy used to be a mode; it is a pause now
if cfg.paused == nil then cfg.paused = false end
cfg.speed = math.min(MAX_SPEED, math.max(MIN_SPEED, tonumber(cfg.speed) or 250))
if cfg.sync == nil then cfg.sync = true end     -- all four channels the same colour
cfg.transition = (cfg.transition == "Hue" or cfg.transition == "Pastel") and cfg.transition or "Jump"
if cfg.copyType == nil then cfg.copyType = false end
if cfg.copyAddons == nil then cfg.copyAddons = false end
if cfg.randomType == nil then cfg.randomType = false end
if cfg.randomAddons == nil then cfg.randomAddons = false end
cfg.lastTarget = type(cfg.lastTarget) == "string" and cfg.lastTarget or ""

local status, phase, lastAt = "off", 0, 0
local lastSent = nil            -- what we last put on the wire, so repeats are skipped

-- The server refuses any looktype you do not own, so the body pool is the outfit list it sends when the
-- outfit window is opened. It is read once, the window is closed again straight away, and the list is kept.
local owned = {}

local function learnOwnedOutfits()
  if #owned > 0 then return end
  local ok = pcall(function()
    local env = modules.game_outfit
    local seen, sd = {}, nil
    local function walk(fn, d)
      if type(fn) ~= "function" or d > 2 or seen[fn] or sd then return end
      seen[fn] = true
      local i = 1
      while true do
        local n, v = G.debug.getupvalue(fn, i)
        if not n then break end
        if n == "ServerData" and type(v) == "table" then sd = v end
        if type(v) == "function" then walk(v, d + 1) end
        i = i + 1
      end
    end
    for _, fn in pairs(env or {}) do walk(fn, 0) end
    local list = sd and sd.outfits
    if type(list) ~= "table" then return end
    for _, entry in pairs(list) do
      if type(entry) == "table" and tonumber(entry[1]) then
        owned[#owned + 1] = { type = tonumber(entry[1]), name = tostring(entry[2] or "?"),
                              addons = tonumber(entry[3]) or 0 }
      end
    end
  end)
  if #owned == 0 and ok then
    pcall(function() g_game.requestOutfit() end)          -- ask, then take the list on the next attempt
    schedule(1200, function()
      local w = G.g_ui.getRootWidget():recursiveGetChildById('outfitWindow')
      if w then pcall(function() w:destroy() end) end
      learnOwnedOutfits()
    end)
  end
end

-- Outfits come in pairs, one looktype per gender, and the gap between them is irregular: 8 apart for the
-- first block, 4 for Barbarian through Shaman, 1 for Nightmare, 35 for Yalaharian, -1 for Wayfarer. Guessing
-- by nearest number lands on the wrong outfit entirely - male Beggar 153 is four below female Wizard 149 -
-- so the pairs are spelled out. Anything not in the table is simply not swapped: colours only.
local GENDER_PAIR = {
  [128] = 136, [129] = 137, [130] = 138, [131] = 139, [132] = 140, [133] = 141, [134] = 142,
  [143] = 147, [144] = 148, [145] = 149, [146] = 150,
  [151] = 155, [152] = 156, [153] = 157, [154] = 158,
  [251] = 252, [268] = 269, [273] = 270, [278] = 279, [287] = 288, [289] = 324, [325] = 336,
  [367] = 366, [430] = 431, [432] = 433, [463] = 464, [465] = 466, [472] = 471,
}
for male, female in pairs(GENDER_PAIR) do GENDER_PAIR[female] = male end   -- works both ways

local function ownedEntry(t)
  for _, o in ipairs(owned) do
    if o.type == t then return o end
  end
end

local function wearableVersionOf(srcType)
  learnOwnedOutfits()
  local mine = ownedEntry(srcType)
  if mine then return mine end
  local other = GENDER_PAIR[srcType]
  if other then return ownedEntry(other) end
end

local function outfitOf(creature)
  local ok, o = pcall(function() return creature:getOutfit() end)
  return ok and o or nil
end

-- How RGB and CMYK travel between their key colours:
--   Jump   - straight from one key colour to the next (what the published presets do)
--   Hue    - along the bright hue ring (row 4), holding ~1s on each key colour
--   Pastel - fading out through the light tints and white, never through the dark rows
-- Linear rgb interpolation is deliberately NOT used: the midpoint of two pure hues is a dark colour
-- (ff0000 -> 00ff00 passes 7f7f00), which is why that version looked like black between the colours.
local TRANSITIONS = { "Jump", "Hue", "Pastel" }
local RING, ringPos = {}, {}
for i = 77, 94 do RING[#RING + 1] = i ringPos[i] = #RING end
local WHITE = 0
local PAL, smoothCache = nil, {}

local function palette()
  if PAL ~= nil then return PAL end
  local f = G.getOutfitColor
  if not f then PAL = false return PAL end
  PAL = {}
  for i = 0, 132 do
    local ok, c = pcall(f, i)
    if ok and c then PAL[i] = { c.r, c.g, c.b } end
  end
  return PAL
end

-- rows 5 and 6 are the dark tier: a fade that is meant to stay bright must not be allowed to land there
local function nearestLight(r, g, b)
  local best, bestD = 0, math.huge
  for i = 0, 94 do
    local p = PAL[i]
    if p then
      local dr, dg, db = p[1] - r, p[2] - g, p[3] - b
      local d = dr * dr + dg * dg + db * db
      if d < bestD then best, bestD = i, d end
    end
  end
  return best
end

local function hueList(wps, dwell)
  local out, n = {}, #RING
  for k = 1, #wps do
    local a, b = wps[k], wps[(k % #wps) + 1]
    local pa, pb = ringPos[a], ringPos[b]
    if not pa or not pb then return nil end
    for _ = 1, dwell do out[#out + 1] = a end
    local fwd, back = (pb - pa) % n, (pa - pb) % n
    local dir = (fwd <= back) and 1 or -1
    for s = 1, math.min(fwd, back) - 1 do
      out[#out + 1] = RING[((pa - 1 + dir * s) % n) + 1]
    end
  end
  return out
end

local function pastelList(wps, dwell, half)
  local out = {}
  for k = 1, #wps do
    local a, b = wps[k], wps[(k % #wps) + 1]
    local ca, cw, cb = PAL[a], PAL[WHITE], PAL[b]
    if not ca or not cb then return nil end
    for _ = 1, dwell do out[#out + 1] = a end
    for s = 1, half do
      local t = s / (half + 1)
      out[#out + 1] = nearestLight(ca[1] + (cw[1] - ca[1]) * t,
                                   ca[2] + (cw[2] - ca[2]) * t,
                                   ca[3] + (cw[3] - ca[3]) * t)
    end
    out[#out + 1] = WHITE
    for s = 1, half do
      local t = s / (half + 1)
      out[#out + 1] = nearestLight(cw[1] + (cb[1] - cw[1]) * t,
                                   cw[2] + (cb[2] - cw[2]) * t,
                                   cw[3] + (cb[3] - cw[3]) * t)
    end
  end
  return out
end

local function cycleList()
  if cfg.mode == "Rainbow" then return RAINBOW end
  local wps = (cfg.mode == "RGB") and RGB or CMYK
  if cfg.transition == "Jump" or not palette() then return wps end
  local dwell = math.max(1, math.floor(1000 / cfg.speed + 0.5))   -- hold each key colour about a second
  local key = cfg.mode .. cfg.transition .. dwell
  if smoothCache[key] then return smoothCache[key] end
  -- near-black is not on the bright ring and is what made CMYK look dark: the smooth versions drop it
  local base = (cfg.mode == "CMYK") and { 85, 91, 79 } or wps
  local out = (cfg.transition == "Hue") and hueList(base, dwell) or pastelList(base, dwell, 4)
  if not out or #out == 0 then return wps end
  smoothCache[key] = out
  return out
end

local function colorFor(list, channel)
  if cfg.mode == "Random" then return math.random(0, 132) end
  -- independent channels chase each other a quarter of the wheel apart
  local offset = cfg.sync and 0 or math.floor((channel - 1) * #list / 4)
  return list[((phase + offset) % #list) + 1]
end

local function applyCycle()
  local me = g_game.getLocalPlayer()
  if not me then return end
  local o = outfitOf(me)
  if not o then return end
  local list = cycleList()
  if cfg.sync and cfg.mode ~= "Random" then
    local c = colorFor(list, 1)
    o.head, o.body, o.legs, o.feet = c, c, c, c
  elseif cfg.sync then
    local c = math.random(0, 132)
    o.head, o.body, o.legs, o.feet = c, c, c, c
  else
    o.head = colorFor(list, 1)
    o.body = colorFor(list, 2)
    o.legs = colorFor(list, 3)
    o.feet = colorFor(list, 4)
  end
  if cfg.randomType or cfg.randomAddons then
    learnOwnedOutfits()
    if cfg.randomType and #owned > 0 then
      local pick = owned[math.random(1, #owned)]
      o.type = pick.type
      if cfg.randomAddons then o.addons = math.random(0, pick.addons or 0) end
    elseif cfg.randomAddons then
      o.addons = math.random(0, 3)
    end
  end
  -- an interpolated step often snaps to the same entry twice: no packet for a colour already worn
  local same = lastSent and lastSent.head == o.head and lastSent.body == o.body
               and lastSent.legs == o.legs and lastSent.feet == o.feet
               and lastSent.type == o.type and lastSent.addons == o.addons
  if not same then
    lastSent = { head = o.head, body = o.body, legs = o.legs, feet = o.feet, type = o.type, addons = o.addons }
    g_game.changeOutfit(o)
  end
  status = cfg.mode:lower() .. " " .. cfg.speed .. "ms" ..
    (cfg.randomType and (" +body(" .. #owned .. ")") or "")
end

-- Copy: one shot, never a loop. The server validates the looktype, so borrowing someone's body only works if
-- you own that outfit - the colours always apply, and the check below says so when the body snaps back.
local function copyFrom(creature)
  local src = outfitOf(creature)
  local me = g_game.getLocalPlayer()
  local mine = me and outfitOf(me)
  if not src or not mine then return end
  if (tonumber(src.type) or 0) == 0 then       -- invisible source: copying it would hide you too
    status = creature:getName() .. " has no visible outfit"
    return
  end
  mine.head, mine.body, mine.legs, mine.feet = src.head, src.body, src.legs, src.feet
  local wantType, note = mine.type, nil
  if cfg.copyType then
    local wearable = wearableVersionOf(src.type)
    if wearable then
      wantType = wearable.type
      mine.type = wantType
      if wearable.type ~= src.type then note = " (as " .. wearable.name .. ", your version)" end
      if cfg.copyAddons then mine.addons = math.min(tonumber(src.addons) or 0, wearable.addons or 0) end
    else
      note = " (you do not own that outfit - colours only)"
      if cfg.copyAddons then mine.addons = math.min(tonumber(src.addons) or 0, 3) end
    end
  elseif cfg.copyAddons then
    mine.addons = tonumber(src.addons) or 0
  end
  -- A copy is a one shot, so it has to stop the cycle: otherwise the next tick (as little as 50ms later)
  -- paints over it and the copy looks like it did nothing at all.
  if (tonumber(mine.type) or 0) == 0 then mine.type = (owned[1] and owned[1].type) or 128 end
  local wasCycling = not cfg.paused
  cfg.paused = true
  g_game.changeOutfit(mine)
  cfg.lastTarget = creature:getName()
  status = "copied " .. creature:getName() .. (note or "") .. (wasCycling and " - cycling stopped" or "")
  schedule(1200, function()
    local after = outfitOf(g_game.getLocalPlayer())
    if cfg.copyType and after and after.type ~= wantType then
      status = "server refused that body - colours applied"
      warning("[outfit] the server would not give you outfit " .. tostring(wantType) ..
              "; the colours were applied")
    end
  end)
end

local outfitMacro = macro(50, "Colour cycle", function()
  if cfg.paused then status = "paused - pick a mode to resume" return end
  if now - lastAt < cfg.speed then return end
  lastAt = now
  phase = phase + 1
  applyCycle()
end)

-- Copying a target never touches the game world: clicking a creature walks you to it, hovering breaks the
-- moment they move, and targeting or following has side effects you do not want mid-fight. Instead the
-- settings window lists the players it can currently see - clicking a name there is a click in our own UI.
-- Players and NPCs wear a real outfit (four colours, a body, addons). Most monsters are a bare looktype with
-- every colour at zero, but some are built on player outfits and do carry colours - so they are listed too,
-- just sorted last.
local function visibleTargets()
  local list = {}
  local me = g_game.getLocalPlayer()
  if not me then return list end
  -- one entry per name: a screen full of the same monster is one line, not fifteen. Player names are unique
  -- anyway, so this only ever collapses npcs and monsters.
  -- Looktype 0 means "the client cannot draw this": an invisible creature, or a gamemaster in ghost mode.
  -- The server still sends it, so it turns up here - but there is no outfit on it to copy, and wearing a 0
  -- makes your OWN character undrawable, which leaves the screen glitching until it is changed back.
  local seen = {}
  for _, c in ipairs(g_map.getSpectatorsInRange(me:getPosition(), false, 12, 9)) do
    local name = c:getName()
    local drawable = (tonumber(c:getOutfit().type) or 0) > 0
    if c:getId() ~= me:getId() and drawable and not seen[name] then
      seen[name] = true
      list[#list + 1] = c
    end
  end
  local function rank(c)
    if c:isPlayer() then return 0 end
    if c:isNpc() then return 1 end
    return 2
  end
  table.sort(list, function(a, b)
    local ra, rb = rank(a), rank(b)                                    -- players, then npcs, then monsters
    if ra ~= rb then return ra < rb end
    return a:getName() < b:getName()
  end)
  return list
end

local function creatureByName(name)
  if not name or name == "" then return nil end
  local want = name:lower()
  for _, c in ipairs(visibleTargets()) do
    if c:getName():lower() == want then return c end
  end
  return nil
end

-- ---- UI ----
local statusLabel

local function settings()
  -- a scrolling body: the list of targets grows with whoever is on screen, and a fixed panel simply drew
  -- them past its own bottom edge where nothing is visible
  local targets = visibleTargets()
  local height = math.min(560, 360 + math.max(1, #targets) * 24)
  UI.listPopup("Outfit", height, function(content, win)
    win.applyButton:hide()
    UI.Label("CYCLING - runs while the Colour cycle switch is on", content)
    local modeRow = UI.buttonRow({ MODES[1], MODES[2] }, content)
    local modeRow2 = UI.buttonRow({ MODES[3], MODES[4] }, content)
    local modeButtons = { modeRow.buttons[1], modeRow.buttons[2],
                          modeRow2.buttons[1], modeRow2.buttons[2] }
    local transRow = UI.buttonRow({ "Jump", "Hue", "Pastel" }, content)   -- how RGB/CMYK travel between colours
    local syncRow = UI.buttonRow({ "All same", "Independent" }, content)
    local randRow = UI.buttonRow({ "Random body", "Random addons" }, content)

    UI.scrollRow("Speed (ms)", MIN_SPEED, MAX_SPEED, cfg.speed, function(v)
      cfg.speed = math.max(MIN_SPEED, v)
      cfg.paused = false
    end, content)

    UI.Separator(content)
    UI.Label("COPY - one shot, stops the cycling", content)
    local copyRow = UI.buttonRow({ "Copy body", "Copy addons" }, content)
    local function paintModes()
      for i, b in ipairs(modeButtons) do UI.pick(b, MODES[i] == cfg.mode and not cfg.paused) end
      for i, b in ipairs(transRow.buttons) do UI.pick(b, TRANSITIONS[i] == cfg.transition) end
      UI.pick(syncRow.buttons[1], cfg.sync)
      UI.pick(syncRow.buttons[2], not cfg.sync)
      UI.pick(copyRow.buttons[1], cfg.copyType)
      UI.pick(copyRow.buttons[2], cfg.copyAddons)
      UI.pick(randRow.buttons[1], cfg.randomType)
      UI.pick(randRow.buttons[2], cfg.randomAddons)
    end
    for i, b in ipairs(modeButtons) do
      b.onClick = function()
        cfg.mode = MODES[i]
        cfg.paused = false                -- choosing a mode resumes what a copy stopped
        phase, lastAt = 0, 0
        paintModes()
      end
    end
    for i, b in ipairs(transRow.buttons) do
      b.onClick = function()
        cfg.transition = TRANSITIONS[i]
        phase, lastAt = 0, 0
        paintModes()
      end
    end
    syncRow.buttons[1].onClick = function() cfg.sync = true paintModes() end
    syncRow.buttons[2].onClick = function() cfg.sync = false paintModes() end
    copyRow.buttons[1].onClick = function() cfg.copyType = not cfg.copyType paintModes() end
    copyRow.buttons[2].onClick = function() cfg.copyAddons = not cfg.copyAddons paintModes() end
    randRow.buttons[1].onClick = function()
      cfg.randomType = not cfg.randomType
      if cfg.randomType then learnOwnedOutfits() end
      paintModes()
    end
    randRow.buttons[2].onClick = function() cfg.randomAddons = not cfg.randomAddons paintModes() end


    local whoLabel = UI.Label("", content)
    local nameButtons = {}
    local function refreshTargets()
      for _, b in ipairs(nameButtons) do b:destroy() end
      nameButtons = {}
      local targets = visibleTargets()
      whoLabel:setText(#targets > 0 and ("Copy from (" .. #targets .. " on screen):") or
        "Nothing on screen to copy")
      for _, c in ipairs(targets) do
        local name = c:getName()
        local tag = c:isNpc() and "  (npc)" or (c:isMonster() and "  (monster)" or "")
        local label = name .. tag
        local b = UI.Button(label, function()
          local target = creatureByName(name)
          if target then copyFrom(target) else status = name .. " is out of sight" end
        end, content)
        nameButtons[#nameButtons + 1] = b
      end
    end
    if cfg.lastTarget ~= "" then
      UI.Button("Copy " .. cfg.lastTarget .. " again", function()
        local target = creatureByName(cfg.lastTarget)
        if target then copyFrom(target) else status = cfg.lastTarget .. " is not on screen" end
      end, content)
    end
    UI.Button("Refresh list", refreshTargets, content)
    refreshTargets()

    schedule(60, function()
      UI.fitButtonRow(modeRow) UI.fitButtonRow(modeRow2)
      UI.fitButtonRow(syncRow) UI.fitButtonRow(copyRow) UI.fitButtonRow(randRow)
      paintModes()
    end)
  end)
end

Features.register{ id = "outfit", name = "Outfit", group = "Other", order = 70, action = settings }

UI.Button("Outfit settings...", settings)
statusLabel = UI.Label("Colours: off")
macro(500, function()
  statusLabel:setText("Colours: " .. (outfitMacro.isOn() and status or status))
end)

panel = tabPanel
