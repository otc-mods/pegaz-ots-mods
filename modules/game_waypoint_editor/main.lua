-- Waypoint editor on the map.
--
-- The cavebot's routes are ordered scripts of { action, value } pairs. This module edits them where they
-- live - on the map - instead of through a list of numbers: draw an area to get the walking waypoints, then
-- place the rest by hand (use, use with, say, function, label, delay) and edit each one in its own window.
--
-- Three layers are drawn over the minimap, all below the minimap's own buttons:
--   1. the painted area, one generated png per route+floor, cached by a version counter
--   2. the route line through the waypoints in walking order
--   3. the waypoint markers, pooled widgets coloured by action type
-- Nothing is re-encoded on zoom or pan: the images are built in tile space and the widget scales them.

local DIR = '/route_paint'
local BRUSHES = { 1, 3, 5, 9 }
local SPACINGS = { 5, 8, 12, 20 }
local MIN_SPACING, MAX_SPACING = 1, 100
local PAINT_COLOURS = { [1] = { 0, 229, 255 }, [2] = { 255, 40, 190 }, [3] = { 255, 60, 60 } }
local ALPHA = 26          -- the drawing is a tint over the map, not a coat of paint
local PIXEL_BUDGET = 45000
local STRAY_DISTANCE = 50
local SNAP_RADIUS = 6
local FLOOR_CHANGE_COLOUR = 210   -- the minimap's yellow: stairs, ladders, holes, ramps, teleports
local BLOCKED_COLOUR = { [0] = true, [24] = true, [40] = true, [186] = true, [192] = true, [255] = true }

local minimap, window, toolbar, button, mapButton, closeButton
local overlay, overlayFile, lineOverlay, lineFile
local markers, ghost = {}, nil
local data                       -- settings: masks per route name, spacing, brush
local route, routeTail = {}, {}  -- the actions being edited, and the cavebot's own config/extensions entries
local tailFrom = nil             -- which route file that tail was read from
local routeName = ''
local mode = 'move'              -- move | draw | place. move is the plain map, the way it was
local placeType = 'goto'
local chips = {}                 -- markers for the waypoints that carry no position of their own
local uiHidden = false           -- everything the editor draws is off, only the small button remains
local suppressMapUntil = 0       -- a click on our own ui must not reach the map underneath it
local liveIndex
local menuBackdrop               -- an invisible sheet under an open menu, so a click anywhere closes it
local mapLegend                  -- the colour key drawn on the map itself
local cursorGhost                -- what the next click will do, drawn under the pointer
local lineBox                    -- where the line image sits, so a zoom can resize it without redrawing
local liveWhy                    -- why the live highlight is off, said once rather than every tick
local lastLiveDrawn              -- the index the route line was last drawn with
local brush, paintWeight = 3, 1
local selected = nil             -- index into route
local recording = false
local renderSeq, renderedCols, renderedRows = 0, 0, 0
local layerVersion, routeVersion, lineKey = 0, 0, nil
local extentCache = {}
local tilesCache = {}
local dirty, lastPersist, dragging = false, 0, false
local syncEvent, renderEvent, lastFullmap, lastScale, lastFloor
local pendingArm = false
local seqRows = {}
local undoStack = {}
local gameHandlers, keyHandlers = nil, {}
local removeWaypoint
local buildToolbar, hideWindow, sweepOrphans, installHooks, hookCentreButton
local pickingFor        -- an editor waiting for a tile to be clicked on the map
local renderKeyCache
local strayCount, movedCount, droppedCount = 0, 0, 0

-- title 18 + two button rows 46 + margins; Place adds a button per type and per job, plus its heading
-- the toolbar is sized to the panel that is showing; move/select fit their hint, draw fits its rows,
-- place fits a button per type and per job
local TOOLBAR_HEIGHT = { move = 132, draw = 224 }
TOOLBAR_HEIGHT.place = 74 + (#RouteTypes.placeable + #RouteTypes.quick) * 24 + 22
local closeMenus, setUiHidden, suppressMap, refreshLive, refreshBotSwitch

local function now() return g_clock.millis() end

-- ---------------------------------------------------------------- settings and state
local function defaults() return { masks = {}, spacing = 12, autoLoad = true, showLive = true } end

local function copyTable(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copyTable(x) end
  return out
end

local function load()
  data = g_settings.getNode('routePaint') or defaults()
  data.masks = data.masks or {}
  -- one drawing = one route: masks[name] is what you are drawing on, saved[name] is what Save wrote with the
  -- route. Drawings from before this split count as saved.
  if not data.saved then
    data.saved = {}
    for key, m in pairs(data.masks) do if key ~= '(unnamed)' then data.saved[key] = copyTable(m) end end
  end
  data.spacing = tonumber(data.spacing) or 12
  data.lastRoute = data.lastRoute or ''
  -- auto-load was off by default for a while and that false got persisted without anyone ticking anything;
  -- until the box has actually been used, the default wins
  if not data.autoLoadChosen then data.autoLoad = true end
end

local function persist() g_settings.setNode('routePaint', data) end

local function viewedFloor()
  local cam = minimap and minimap:getCameraPosition()
  if cam then return cam.z end
  local me = g_game.getLocalPlayer()
  local p = me and me:getPosition()
  return p and p.z or 7
end

local function maskKey(name) return (name ~= '' and name) or '(unnamed)' end

local function maskFor(name, create)
  local key = maskKey(name)
  local m = data.masks[key]
  if not m and create then m = { floors = {} } data.masks[key] = m end
  if m then m.floors = m.floors or {} end
  return m
end

local function layerFor(z, create)
  local m = maskFor(routeName, create)
  if not m then return nil end
  local key = tostring(z)
  local layer = m.floors[key]
  if not layer and create then layer = { tiles = {}, order = {} } m.floors[key] = layer end
  if layer then
    layer.tiles = layer.tiles or {}
    layer.order = layer.order or {}
  end
  return layer
end

local function layerCount(layer)
  local n = 0
  for _ in pairs((layer or {}).tiles or {}) do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------- the bot side
local function botConfigName()
  local w = g_ui.getRootWidget():recursiveGetChildById('botWindow')
  local combo = w and w:recursiveGetChildById('config')
  local ok, opt = pcall(function() return combo:getCurrentOption() end)
  if ok and opt and opt.text and opt.text ~= '' then return opt.text end
  local fallback = g_settings.getString('bot_config')
  if fallback and fallback ~= '' then return fallback end
  return nil
end

local function routeDir()
  local cfg = botConfigName()
  return cfg and ('/bot/' .. cfg .. '/cavebot_configs') or nil, cfg
end

local function listRoutes()
  local dir, cfg = routeDir()
  if not dir then return {}, nil end
  local names = {}
  for _, file in ipairs(g_resources.listDirectoryFiles(dir) or {}) do
    local name = tostring(file):match('^(.+)%.cfg$')
    if name then names[#names + 1] = name end
  end
  table.sort(names)
  return names, cfg
end

-- Saving a route writes a file the cavebot has already read. Refreshing the whole bot rebuilds its panels but
-- leaves the waypoint list as it was, so pressing start would run the version from before the save. The
-- cavebot's own config object knows how to re-read itself - it is reachable through the upvalue of any
-- CaveBot function that closes over it.
local function cavebotConfigObject()
  local ctx = botContext and botContext()
  local cave = ctx and ctx.CaveBot
  if not cave or not debug or not debug.getupvalue then return nil end
  for _, name in ipairs({ 'save', 'setOn', 'isOn' }) do
    local fn = cave[name]
    if type(fn) == 'function' then
      local i = 1
      while true do
        local key, value = debug.getupvalue(fn, i)
        if not key then break end
        if key == 'config' and type(value) == 'table' and type(value.reload) == 'function' then return value end
        i = i + 1
      end
    end
  end
  return nil
end

-- The combo the cavebot picks its route with. Config.setup's refresh closure captured the widget it was given,
-- and that widget's .list is the combo; selecting an option there is exactly what a click on it does.
local function cavebotCombo()
  local cfg = cavebotConfigObject()
  if not cfg or type(cfg.refresh) ~= 'function' then return nil end
  local i = 1
  while true do
    local key, value = debug.getupvalue(cfg.refresh, i)
    if not key then break end
    if key == 'widget' and value and value.list then return value.list end
    i = i + 1
  end
  return nil
end

local function botRouteName()
  local ctx = botContext and botContext()
  local cave = ctx and ctx.CaveBot
  if cave and type(cave.getConfigName) == 'function' then return cave.getConfigName() end
  return nil
end

-- make the cavebot's selected route this one; true if it took
function selectBotRoute(name)
  if not name or name == '' then return false end
  if botRouteName() == name then return true end
  local combo = cavebotCombo()
  if not combo then return false end
  local ok = pcall(function() combo:setCurrentOption(name) end)
  return ok and botRouteName() == name
end

local function reloadBot()
  scheduleEvent(function()
    local cfg = cavebotConfigObject()
    if cfg then
      local ok = pcall(function() cfg.reload() end)
      if ok then return end
    end
    pcall(function() modules.game_bot.refresh() end)
  end, 250)
end

-- ---------------------------------------------------------------- painting
local function cellFor(cols, rows)
  return math.max(1, math.min(3, math.floor(math.sqrt(PIXEL_BUDGET / math.max(1, cols * rows)))))
end

local function scheduleRender(soon)
  if renderEvent then return end
  renderEvent = scheduleEvent(function() renderEvent = nil modules.game_waypoint_editor.render() end, soon and 40 or 110)
end

local function paintAround(pos, erase)
  if not pos or not pos.x then return end
  local layer = layerFor(pos.z, true)
  if not layer then return end
  local weight = erase and 0 or paintWeight
  local r = math.floor(brush / 2)
  for dx = -r, r do
    for dy = -r, r do
      local key = (pos.x + dx) .. ',' .. (pos.y + dy)
      if weight == 0 then
        layer.tiles[key] = nil
      else
        if not layer.tiles[key] then layer.order[#layer.order + 1] = key end
        layer.tiles[key] = weight
      end
    end
  end
  dirty = true
  layerVersion = layerVersion + 1
  scheduleRender(true)
  if data.livePreview then schedulePreview() end
end

local function screenSize(tiles)
  return math.max(1, math.floor(tiles * (minimap:getScale() or 1) + 0.5))
end

local needRestack = true
local prof = {}
function _prof() return prof end
local function markDirtyStack() needRestack = true end

local function ensureOverlay()
  if overlay and not overlay:isDestroyed() then return end
  local orphan = minimap:getChildById('rpPaint')
  if orphan then orphan:destroy() end
  overlay = g_ui.createWidget('RpOverlay', minimap)
  overlay:setId('rpPaint')
  overlay:setImageSmooth(false)
  markDirtyStack()
end

-- Center, zoom, the floor arrows and the position hud belong above anything we draw, whenever we draw it.
function raiseMapControls()
  if not minimap or minimap:isDestroyed() then return end
  for _, c in ipairs(minimap:getChildren()) do
    local id = c:getId()
    if id == 'resetWidget' or id == 'zoomInWidget' or id == 'zoomOutWidget'
       or id == 'floorUpWidget' or id == 'floorDownWidget' or id == 'posHud' then c:raise() end
  end
end

-- bottom to top: the map, the drawing, the lines between waypoints, the waypoints, the map's own buttons
local function restack()
  if not needRestack then return end
  needRestack = false
  if overlay and not overlay:isDestroyed() then overlay:lower() end
  if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:raise() end
  for _, c in ipairs(minimap:getChildren()) do
    if c:getId() == 'rpMarker' then c:raise() end
  end
  -- ours first, then the map's own buttons on top of everything, so Center, zoom and the floor arrows are
  -- never buried under the toolbar or the legend
  for _, c in ipairs(minimap:getChildren()) do
    local id = c:getId()
    if id == 'rpToolbar' or id == 'rpLegend' or id == 'rpOpen' or id == 'rpCloseMap' then c:raise() end
  end
  raiseMapControls()
end

-- everything the editor draws stays off the small minimap unless the option says otherwise
function drawSuppressed()
  return not modules.game_minimap.fullmapView and not (data and data.showOnMinimap)
end

function hideDrawings()
  for _, m in ipairs(markers) do if not m:isDestroyed() then m:hide() end end
  for _, c in ipairs(chips) do if not c:isDestroyed() then c:hide() end end
  if overlay and not overlay:isDestroyed() then overlay:hide() end
  if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:hide() end
  if mapLegend and not mapLegend:isDestroyed() then mapLegend:hide() end
  if cursorGhost and not cursorGhost:isDestroyed() then cursorGhost:hide() end
end

function render(force)
  if drawSuppressed() then hideDrawings() return end
  if not minimap then return end
  local z = viewedFloor()
  local layer = layerFor(z, false)
  ensureOverlay()
  local key = ('%s:%d:%d'):format(routeName, z, layerVersion)
  if not force and key == renderKeyCache and overlay:isVisible() then
    if renderedCols > 0 then overlay:resize(screenSize(renderedCols), screenSize(renderedRows)) end
    return
  end
  if not layer or layerCount(layer) == 0 then
    overlay:hide()
    renderKeyCache = key
    return
  end
  renderKeyCache = key

  local ex = extentCache[layerVersion]
  if not ex then
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    for tkey in pairs(layer.tiles) do
      local x, y = tkey:match('^(-?%d+),(-?%d+)$')
      x, y = tonumber(x), tonumber(y)
      if x then
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
      end
    end
    ex = { x0 = x0, x1 = x1, y0 = y0, y1 = y1 }
    extentCache = { [layerVersion] = ex }
  end
  local minX, maxX, minY, maxY = ex.x0, ex.x1, ex.y0, ex.y1
  local cols, rows = maxX - minX + 1, maxY - minY + 1
  if cols < 1 or rows < 1 or cols * rows > 400000 then overlay:hide() return end
  local cell = cellFor(cols, rows)
  local t0 = g_clock.micros()

  local grid, edges = {}, {}
  for tkey, w in pairs(layer.tiles) do
    local x, y = tkey:match('^(-?%d+),(-?%d+)$')
    x, y = tonumber(x), tonumber(y)
    if x then grid[(y - minY) * cols + (x - minX)] = w end
  end
  if cell >= 2 then
    for i in pairs(grid) do
      local gx = i % cols
      local gy = (i - gx) / cols
      local l = (gx > 0) and grid[i - 1] or nil
      local r = (gx < cols - 1) and grid[i + 1] or nil
      local u = (gy > 0) and grid[i - cols] or nil
      local d = (gy < rows - 1) and grid[i + cols] or nil
      if not (l and r and u and d) then edges[i] = { not l, not r, not u, not d } end
    end
  end

  -- rows are built from precomputed colour runs: one string.rep per tile instead of a call per pixel
  local function colour(c, a) return RoutePNG.pixel(c[1] - c[1] % 1, c[2] - c[2] % 1, c[3] - c[3] % 1, a) end
  local fill, dark, fillRun, darkRun, midRun = {}, {}, {}, {}, {}
  for weight, c in pairs(PAINT_COLOURS) do
    -- the no-go brush is drawn solid rather than as a tint, so it reads as a wall and not as an area
    local alpha = (weight == 3) and 90 or ALPHA
    fill[weight] = colour(c, alpha)
    dark[weight] = colour({ c[1] * 0.35, c[2] * 0.35, c[3] * 0.35 }, 255)
    fillRun[weight] = string.rep(fill[weight], cell)
    darkRun[weight] = string.rep(dark[weight], cell)
    midRun[weight] = cell > 2 and string.rep(fill[weight], cell - 2) or ''
  end
  local blank = string.rep('\0\0\0\0', cell)
  local png = RoutePNG.encodeRows(cols * cell, rows * cell, function(py)
    local gy = (py - py % cell) / cell
    local oy = py % cell
    local base = gy * cols
    local parts = {}
    for gx = 0, cols - 1 do
      local w = grid[base + gx]
      if not w or not fillRun[w] then
        parts[gx + 1] = blank
      else
        local e = edges[base + gx]
        if e and ((oy == 0 and e[3]) or (oy == cell - 1 and e[4])) then
          parts[gx + 1] = darkRun[w]
        elseif e and cell > 1 and (e[1] or e[2]) then
          parts[gx + 1] = (e[1] and dark[w] or fill[w]) .. midRun[w] .. (e[2] and dark[w] or fill[w])
        else
          parts[gx + 1] = fillRun[w]
        end
      end
    end
    return table.concat(parts)
  end)
  prof.encode = g_clock.micros() - t0

  local t1 = g_clock.micros()
  renderSeq = renderSeq + 1
  local path = DIR .. '/mask' .. renderSeq .. '.png'
  if not g_resources.writeFileContents(path, png) then return end
  prof.write = g_clock.micros() - t1
  local t2 = g_clock.micros()
  overlay:setImageSource(path)
  prof.upload = g_clock.micros() - t2
  if overlayFile then pcall(function() g_resources.deleteFile(overlayFile) end) end
  overlayFile = path
  if renderSeq % 400 == 0 then g_textures.clearCache() end
  local t3 = g_clock.micros()
  minimap:centerInPosition(overlay, { x = minX + math.floor(cols / 2), y = minY + math.floor(rows / 2), z = z })
  renderedCols, renderedRows = cols, rows
  overlay:resize(screenSize(cols), screenSize(rows))
  overlay:show()
  restack()
  prof.place = g_clock.micros() - t3
end

-- The segment the bot is walking, as a pair of indices into `pts` (the positioned waypoints on this floor,
-- in route order). The bot is heading to the first positioned waypoint at or after its row; the segment is
-- from the one before that. Heading to the first one, or past the last one, means the closing segment.
function liveSegmentFor(pts, idx)
  if not idx or #pts < 2 then return nil end
  local to = nil
  for i = 1, #pts do
    if pts[i].index >= idx then to = i break end
  end
  if not to or to == 1 then return #pts, 1 end
  return to - 1, to
end

local function drawRouteLine()
  if drawSuppressed() then if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:hide() end return end
  local pts = {}
  local z = viewedFloor()
  for index, entry in ipairs(route) do
    local p = RouteTypes.positionOf(entry)
    if p and p.z == z then pts[#pts + 1] = { x = p.x, y = p.y, z = p.z, index = index } end
  end
  if #pts < 2 then
    if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:hide() end
    return
  end
  -- The segment the bot is walking is part of this same image, in a brighter colour, so it always lies
  -- exactly on the route line. A second image drawn over the top never matched: a different bounding box
  -- meant a different cell size and a different rasterisation.
  local key = routeVersion .. ':' .. z .. ':' .. tostring(liveIndex)
  if key == lineKey and lineOverlay and not lineOverlay:isDestroyed() and lineOverlay:isVisible() then return end
  -- an image that could not be drawn must not stay on screen as if it were current: hide it and try again
  -- on the next pass (the key is only taken once the new image is really up)
  local function stale()
    lineKey = nil
    if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:hide() end
  end
  local liveFrom, liveTo = liveSegmentFor(pts, liveIndex)

  local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
  for _, p in ipairs(pts) do
    if p.x < minX then minX = p.x end
    if p.x > maxX then maxX = p.x end
    if p.y < minY then minY = p.y end
    if p.y > maxY then maxY = p.y end
  end
  local cols, rows = maxX - minX + 1, maxY - minY + 1
  if cols * rows > 400000 then stale() return end
  local cell = cellFor(cols, rows)
  local lit = {}
  local W = cols * cell
  local H = rows * cell
  local function segment(a, b, live)
    local x0 = (a.x - minX) * cell + math.floor(cell / 2)
    local y0 = (a.y - minY) * cell + math.floor(cell / 2)
    local x1 = (b.x - minX) * cell + math.floor(cell / 2)
    local y1 = (b.y - minY) * cell + math.floor(cell / 2)
    local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
      if live then
        lit[y0 * W + x0] = 2              -- the same one pixel line, in white
      elseif lit[y0 * W + x0] ~= 2 then
        lit[y0 * W + x0] = 1
      end
      if x0 == x1 and y0 == y1 then break end
      local e2 = 2 * err
      if e2 >= dy then err = err + dy x0 = x0 + sx end
      if e2 <= dx then err = err + dx y0 = y0 + sy end
    end
  end
  for i = 1, #pts - 1 do segment(pts[i], pts[i + 1], false) end
  segment(pts[#pts], pts[1], false)
  if liveFrom then segment(pts[liveFrom], pts[liveTo], true) end
  -- the line is a handful of pixels per row: build each row from its lit columns instead of scanning all
  local litRows = {}
  for key, kind in pairs(lit) do
    local x = key % W
    local y = (key - x) / W
    litRows[y] = litRows[y] or {}
    litRows[y][#litRows[y] + 1] = x
  end
  local dot = RoutePNG.pixel(255, 224, 102, 225)
  local bold = RoutePNG.pixel(255, 255, 255, 255)
  local emptyRow = string.rep('\0\0\0\0', W)
  local png = RoutePNG.encodeRows(W, rows * cell, function(py)
    local xs = litRows[py]
    if not xs then return emptyRow end
    table.sort(xs)
    local parts, last = {}, -1
    local base = py * W
    for _, x in ipairs(xs) do
      if x > last then
        if x - last - 1 > 0 then parts[#parts + 1] = string.rep('\0\0\0\0', x - last - 1) end
        parts[#parts + 1] = (lit[base + x] == 2) and bold or dot
        last = x
      end
    end
    if W - last - 1 > 0 then parts[#parts + 1] = string.rep('\0\0\0\0', W - last - 1) end
    return table.concat(parts)
  end)
  renderSeq = renderSeq + 1
  local path = DIR .. '/line' .. renderSeq .. '.png'
  if not g_resources.writeFileContents(path, png) then stale() return end
  if not lineOverlay or lineOverlay:isDestroyed() then
    lineOverlay = g_ui.createWidget('RpOverlay', minimap)
    lineOverlay:setId('rpLine')
    lineOverlay:setImageSmooth(false)
  end
  lineOverlay:setImageSource(path)
  lineKey = key
  if lineFile then pcall(function() g_resources.deleteFile(lineFile) end) end
  lineFile = path
  lineBox = { x = minX + math.floor(cols / 2), y = minY + math.floor(rows / 2), z = z, cols = cols, rows = rows }
  minimap:centerInPosition(lineOverlay, lineBox)
  lineOverlay:resize(screenSize(cols), screenSize(rows))
  lineOverlay:show()
end

-- ---------------------------------------------------------------- waypoint markers
local openEditor, refreshSeq, selectIndex, showMenu
local lineEvent
function scheduleLine()
  if lineEvent then return end
  lineEvent = scheduleEvent(function() lineEvent = nil drawRouteLine() end, 120)
end

local function upvalueOf(fn, want)
  if type(fn) ~= 'function' or not debug or not debug.getupvalue then return nil end
  local i = 1
  while true do
    local name, value = debug.getupvalue(fn, i)
    if not name then return nil end
    if name == want then return value end
    i = i + 1
  end
end

-- The cavebot marks where it is by focusing a row in its own list; that is the only handle it offers, and it
-- is enough to follow it live.
local function cavebotIndex()
  if not data or data.showLive == false then return nil end
  local ok, idx = pcall(function()
    local ctx = botContext and botContext()
    local cave = ctx and ctx.CaveBot
    if not cave or type(cave.isOn) ~= 'function' or not cave.isOn() then return nil end
    -- the bot's row number only means something here if it is running the route we have open, otherwise the
    -- highlight lands on whichever waypoint happens to share that position in the list
    if type(cave.getConfigName) == 'function' and cave.getConfigName() ~= routeName then return nil end
    local ui = upvalueOf(cave.gotoLabel, 'ui')
    local list = ui and ui.list
    if not list or list:isDestroyed() then return nil end
    local focused = list:getFocusedChild()
    if not focused then return nil end
    return list:getChildIndex(focused)
  end)
  return ok and idx or nil
end


function refreshBotSwitch()
  local b = window and window.botSwitch
  if not b or b:isDestroyed() then return end
  local ctx = botContext()
  local cave = ctx and ctx.CaveBot
  local on = cave and type(cave.isOn) == 'function' and cave.isOn() or false
  local text = cave and ('Bot: ' .. (on and 'on' or 'off')) or 'Bot: ?'
  if b:getText() ~= text then b:setText(text) end
  b:setImageColor(on and '#55c957' or '#8a8a8a')
  b:setColor(on and '#ffffff' or '#c8c8c8')
end

function refreshLive()
  local idx = (not uiHidden) and cavebotIndex() or nil
  liveIndex = idx
  -- the highlight needs the bot to be running the route you have open; say so once rather than look broken
  local ctx = botContext and botContext()
  local cave = ctx and ctx.CaveBot
  local running = cave and type(cave.isOn) == 'function' and cave.isOn()
  local selected = cave and type(cave.getConfigName) == 'function' and cave.getConfigName() or nil
  local why = nil
  if running and not idx then
    if routeName == '' then
      why = 'this route is unsaved, so the bot cannot be following it - save it to see the live highlight'
    elseif selected and selected ~= routeName then
      why = ('the bot is running "%s", not "%s" - no live highlight'):format(selected, routeName)
    end
  end
  if why ~= liveWhy then
    liveWhy = why
    if why then info(why) end
  end
  local function markOne(w)
    if not w or w:isDestroyed() then return end
    local on = (w.index == idx)
    if on == w.liveOn then return end
    w.liveOn = on
    w:setBorderWidth(on and 2 or 1)
    if on then
      w:setBorderColor('#ffffff')
      w:raise()
    else
      w:setBorderColor(w.index == selected and '#ffffff' or '#101010')
    end
  end
  for _, m in ipairs(markers) do markOne(m) end
  for _, c in ipairs(chips) do
    if not c:isDestroyed() and c.face then c.face.index = c.index markOne(c.face) end
  end
  -- the walked segment lives inside the route line image; its cache key carries the index, so a change of
  -- index is a redraw of that one image and nothing else
  if idx ~= lastLiveDrawn then
    lastLiveDrawn = idx
    drawRouteLine()
    refreshSeq()
  end
end

-- moving a waypoint to a different place in the order, which is what dropping one onto another means
function reorderWaypoint(from, to)
  if not route[from] or not route[to] or from == to then return false end
  if isHidden(route[to]) then to = visibleNeighbour(to, to > from and 1 or -1) or to end
  pushUndo('reordering waypoints')
  local at = moveBlock(from, to)
  selected = at
  routeVersion = routeVersion + 1
  drawMarkers()
  refreshSeq()
  info(('moved waypoint %d to position %d'):format(shownNumber(from), shownNumber(at)))
  return true
end

-- "7 G" fits the 32 px box, "122 BS" does not: the box grows with its text
local function fitMarker(w)
  w:setWidth(math.max(32, w:getTextSize().width + 8))
end

local function markerAt(mousePos)
  for _, m in ipairs(markers) do
    if not m:isDestroyed() and m:isVisible() and m:containsPoint(mousePos) then return m end
  end
  for _, c in ipairs(chips) do
    if not c:isDestroyed() and c:isVisible() and c.face and c.face:containsPoint(mousePos) then return c end
  end
  return nil
end

-- The five types that carry no position of their own (label, go to label, delay, say, function) used to be
-- invisible on the map. They run between two goto waypoints, so they are drawn as small chips hanging off
-- the waypoint before them - several in a row when a block of them sits at the same point.
-- Labels and jumps are shown on real waypoints: a label tags the waypoint it lands on (the next visible row),
-- a jump hangs off the waypoint it follows (the previous visible row). Rows for them are not shown, and the
-- numbers you see count only visible rows.
local isHidden = RouteTypes.hidden

local function flavourOf(index)
  local tags, jumps = {}, {}
  local i = index - 1
  while i >= 1 and isHidden(route[i]) do
    if route[i].action == 'label' then table.insert(tags, 1, tostring(route[i].value)) end
    i = i - 1
  end
  i = index + 1
  while i <= #route and isHidden(route[i]) do
    if route[i].action == 'gotolabel' then jumps[#jumps + 1] = tostring(route[i].value) end
    i = i + 1
  end
  return tags, jumps
end

local function flavourText(index)
  local tags, jumps = flavourOf(index)
  local s = ''
  if #tags > 0 then s = s .. ('  [label %s]'):format(table.concat(tags, ', ')) end
  if #jumps > 0 then s = s .. ('  -> jump to %s'):format(table.concat(jumps, ', ')) end
  return s
end

function shownNumber(index)
  local n = 0
  for i = 1, math.min(index, #route) do if not isHidden(route[i]) then n = n + 1 end end
  return n
end

-- the labels right before a row and the jumps right after it move with it
local function blockRange(index)
  local s, e = index, index
  while s > 1 and route[s - 1].action == 'label' do s = s - 1 end
  while e < #route and route[e + 1].action == 'gotolabel' do e = e + 1 end
  return s, e
end

local function visibleNeighbour(index, dir)
  local i = index + dir
  while i >= 1 and i <= #route do
    if not isHidden(route[i]) then return i end
    i = i + dir
  end
  return nil
end

-- move the block of `from` next to the block of `to`: before it when moving up, after it when moving down.
-- Returns the new index of the moved row.
local function moveBlock(from, to)
  local fs, fe = blockRange(from)
  local block = {}
  for i = fs, fe do block[#block + 1] = route[i] end
  for i = fe, fs, -1 do table.remove(route, i) end
  local shift = (to > fe) and (fe - fs + 1) or 0
  local ts, te = blockRange(to - shift)
  local at = (from < to) and (te + 1) or ts
  for k, e in ipairs(block) do table.insert(route, at + k - 1, e) end
  return at + (from - fs)
end

local function drawChips(z)
  -- Each flat waypoint hangs off the positioned one before it; the ones that open a route (a label, usually)
  -- have nothing before them, so they borrow the first position that comes after instead. Slots are counted
  -- per anchor tile, so two runs that land on the same tile do not draw on top of each other.
  local anchors, last = {}, nil
  for i = 1, #route do
    local p = RouteTypes.positionOf(route[i])
    if p then last = p else anchors[i] = route[i]._pin or last end
  end
  local nextPos = nil
  for i = #route, 1, -1 do
    local p = RouteTypes.positionOf(route[i])
    if p then nextPos = p elseif not anchors[i] then anchors[i] = nextPos end
  end

  local used, taken = 0, {}
  for index, entry in ipairs(route) do
    local anchor = anchors[index]
    if anchor and anchor.z == z and not isHidden(entry) then
      local key = anchor.x .. ',' .. anchor.y
      taken[key] = (taken[key] or 0) + 1
      local slot = taken[key]
      local t = RouteTypes.look(entry)
      used = used + 1
      local c = chips[used]
      if not c or c:isDestroyed() then
        c = g_ui.createWidget('RpChip', minimap)
        c:setId('rpMarker')            -- restack treats it like any other marker
        chips[used] = c
        markDirtyStack()
        -- the face takes the clicks; it reads the index off its container
        c.face.onMousePress = function(widget, mousePos, mouseButton)
          local holder = widget:getParent()
          if mouseButton == MouseRightButton then
            showMenu(mousePos, holder.index)
            return true
          end
          if pickingFor then return false end
          selectIndex(holder.index)
          return true
        end
        c.face.onDragEnter = function(widget, mousePos)
          if pickingFor then return false end
          dragging = true
          selectIndex(widget:getParent().index)
          ghost = g_ui.createWidget('RpGhost', g_ui.getRootWidget())
          ghost:setText(widget:getText())
          ghost:setBackgroundColor(widget:getBackgroundColor())
          ghost:setPosition({ x = mousePos.x - 9, y = mousePos.y - 9 })
          return true
        end
        c.face.onDragMove = function(widget, mousePos)
          local s = g_window.getMousePosition() or mousePos
          if ghost and not ghost:isDestroyed() then ghost:setPosition({ x = s.x - 9, y = s.y - 9 }) end
          return true
        end
        c.face.onDragLeave = function(widget, dropped, mousePos)
          if ghost and not ghost:isDestroyed() then ghost:destroy() end
          ghost = nil
          scheduleEvent(function() dragging = false end, 150)
          local index2 = widget:getParent().index
          local screen = g_window.getMousePosition() or mousePos
          local onto = markerAt(screen)
          if onto and onto.index and onto.index ~= index2 then
            reorderWaypoint(index2, onto.index)
            return true
          end
          local pos = minimap:getTilePosition(screen)
          local entry2 = route[index2]
          if not pos or not entry2 then info('dropped outside the map - nothing moved') return true end
          pushUndo('moving a waypoint')
          entry2._pin = { x = pos.x, y = pos.y, z = pos.z }
          -- a job carries its tile in its script: only that line moves, edited parameters stay
          entry2.value = RouteTypes.withPosition(entry2, pos)
          routeVersion = routeVersion + 1
          drawMarkers()
          refreshSeq()
          info(('moved waypoint %d to %d,%d'):format(index2, pos.x, pos.y))
          return true
        end
      end
      local stamp = ('%s:%d:%d:%d:%s'):format(entry.action, anchor.x, anchor.y, slot, tostring(index == selected))
      if c.stamp ~= stamp then
        c.stamp = stamp
        c.face:setText(('%d %s'):format(shownNumber(index), t and t.glyph or '?'))
        fitMarker(c.face)
        c.face:setTooltip(RouteTypes.describe(entry) .. flavourText(index))
        c.face:setBackgroundColor(t and t.colour or '#ffffff')
        c.face:setBorderColor(index == selected and '#ffffff' or '#101010')
        c.face.liveOn = nil
        minimap:centerInPosition(c, anchor)
        -- the container is 160x72 with the tile at its centre (80,36): the face sits to the lower right of
        -- the marker, one slot along per chip on the same tile, four to a row
        c.face:setMarginLeft(80 + 4 + ((slot - 1) % 4) * 15)
        c.face:setMarginTop(36 + 10 + math.floor((slot - 1) / 4) * 15)
      end
      c.index = index
      c.face.index = index
      if not c:isVisible() then c:show() end
    end
  end
  for i = used + 1, #chips do
    if chips[i] and not chips[i]:isDestroyed() then chips[i]:hide() end
  end
end

function drawMarkers()
  if drawSuppressed() then hideDrawings() return end
  local z = viewedFloor()
  local used = 0
  for index, entry in ipairs(route) do
    local p = RouteTypes.positionOf(entry)
    if p and p.z == z then
      local t = RouteTypes.look(entry)
      used = used + 1
      local m = markers[used]
      if not m or m:isDestroyed() then
        m = g_ui.createWidget('RpMarker', minimap)
        m:setId('rpMarker')
        markers[used] = m
        markDirtyStack()
        -- handlers are wired once per widget, not per redraw: they read the index off the widget itself
        m.onMousePress = function(widget, mousePos, mouseButton)
          if mouseButton == MouseRightButton then
            showMenu(mousePos, widget.index)       -- the waypoint menu works in any mode
            return true
          end
          if pickingFor then return false end      -- a position pick must reach the map underneath
          selectIndex(widget.index)
          return true
        end
        m.onDragEnter = function(widget, mousePos)
          if pickingFor then return false end
          dragging = true
          selectIndex(widget.index)
          ghost = g_ui.createWidget('RpGhost', g_ui.getRootWidget())
          local face = widget.face or widget
          ghost:setText(face:getText())
          ghost:setBackgroundColor(face:getBackgroundColor())
          ghost:setPosition({ x = mousePos.x - 9, y = mousePos.y - 9 })
          return true
        end
        m.onDragMove = function(widget, mousePos)
          local s = g_window.getMousePosition() or mousePos
          if ghost and not ghost:isDestroyed() then ghost:setPosition({ x = s.x - 9, y = s.y - 9 }) end
          return true
        end
        m.onDragLeave = function(widget, dropped, mousePos)
          if ghost and not ghost:isDestroyed() then ghost:destroy() end
          ghost = nil
          scheduleEvent(function() dragging = false end, 150)
          -- dropped on another waypoint: that is a reorder, not a move. It is the only way to fix an order
          -- that came out wrong without counting rows in the list.
          local onto = markerAt(mousePos)
          if onto and onto.index and onto.index ~= widget.index then
            reorderWaypoint(widget.index, onto.index)
            return true
          end
          local screen = g_window.getMousePosition() or mousePos
          local pos = minimap:getTilePosition(screen)
          local entry2 = route[widget.index]
          if not pos then info('dropped outside the map - nothing moved') return true end
          if pos and entry2 then
            pushUndo('moving a waypoint')
            entry2.value = RouteTypes.withPosition(entry2, { x = pos.x, y = pos.y, z = pos.z })
            entry2._pin = { x = pos.x, y = pos.y, z = pos.z }
            routeVersion = routeVersion + 1
            drawMarkers()
            refreshSeq()
            info(('moved waypoint %d to %d,%d'):format(widget.index, pos.x, pos.y))
          end
          return true
        end
      end
      -- the index is part of the stamp: inserting a label above a goto changes its number but not its tile
      local flavour = flavourText(index)
      local stamp = ('%d:%s:%d:%d:%s:%s'):format(index, entry.action, p.x, p.y, tostring(index == selected), flavour)
      if m.stamp ~= stamp then
        m.stamp = stamp
        m.index = index
        m:setText(('%d %s'):format(shownNumber(index), t and t.glyph or '?'))
        fitMarker(m)
        m:setTooltip(RouteTypes.describe(entry) .. flavour)
        m:setBackgroundColor(t and t.colour or '#ffffff')
        m:setBorderColor(index == selected and '#ffffff' or '#101010')
        minimap:centerInPosition(m, p)
      end
      m.index = index
      if not m:isVisible() then m:show() end
    end
  end
  for i = used + 1, #markers do
    if markers[i] and not markers[i]:isDestroyed() then markers[i]:hide() end
  end
  drawChips(z)
  scheduleLine()
  restack()
  if refreshLive then refreshLive() end
end

function clearMarkers()
  if ghost and not ghost:isDestroyed() then ghost:destroy() ghost = nil end
  for _, m in ipairs(markers) do if not m:isDestroyed() then m:destroy() end end
  for _, c in ipairs(chips) do if not c:isDestroyed() then c:destroy() end end
  markers, chips = {}, {}
  for _, c in ipairs(minimap:getChildren()) do
    if c:getId() == 'rpMarker' then c:destroy() end
  end
  if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:hide() end
end

-- Undo for the route: Remove, New, Generate, a template, a drag and a value edit all take a snapshot
-- first. Ten deep, which is as far as anyone remembers what they did.
function pushUndo(what)
  local copy = {}
  for i, e in ipairs(route) do copy[i] = { action = e.action, value = e.value, _pin = e._pin } end
  undoStack[#undoStack + 1] = { route = copy, name = routeName, what = what }
  if #undoStack > 10 then table.remove(undoStack, 1) end
end

function undo()
  local last = table.remove(undoStack)
  if not last then info('nothing to undo') return false end
  route = last.route
  routeName = last.name or routeName
  if window then window.nameEdit:setText(routeName) end
  selected = nil
  routeVersion = routeVersion + 1
  drawMarkers()
  refreshSeq()
  info(('undid: %s  (%d waypoints back)'):format(last.what or 'the last change', #route))
  return true
end

-- ---------------------------------------------------------------- the sequence list
function info(text)
  if window and window:isVisible() then window.infoLabel:setText(text) window.infoLabel:setColor('#c8c8c8') end
end

-- a refusal: same line, in red, so "it did nothing" always says why
function warn(text)
  if window and window:isVisible() then window.infoLabel:setText(text) window.infoLabel:setColor('#ff6b6b') end
end

local seqDrag
local function seqRowAt(mousePos)
  for i, r in ipairs(seqRows) do
    if r and not r:isDestroyed() and r:isVisible() and r:containsPoint(mousePos) then return r.index or i end
  end
  return nil
end

-- The gotos around a waypoint are a cycle, so making one of them the last is a rotation of that block: the
-- path stays the same, only where the loop "ends" changes - which is where the refill check belongs.
function makeLoopEnd(index)
  local entry = route[index]
  if not entry or entry.action ~= 'goto' then warn('select a Go to inside the hunt loop first') return end
  local first, last = index, index
  while first > 1 and route[first - 1].action == 'goto' do first = first - 1 end
  while last < #route and route[last + 1].action == 'goto' do last = last + 1 end
  if index == last then info('this Go to is already the last of its block') return end
  pushUndo('rotating the loop')
  local block = {}
  for i = index + 1, last do block[#block + 1] = route[i] end
  for i = first, index do block[#block + 1] = route[i] end
  for k, e in ipairs(block) do route[first + k - 1] = e end
  selected = last
  routeVersion = routeVersion + 1
  drawMarkers()
  refreshSeq()
  local p = RouteTypes.positionOf(entry)
  info(('the loop now ends at %s (waypoint %d) - %d gotos rotated, their order kept; put the Refill check right after it')
    :format(p and (p.x .. ',' .. p.y) or '?', last, last - first + 1))
end

function refreshSeq()
  if not window then return end
  local list = window.seqList
  for index, entry in ipairs(route) do
    local t = RouteTypes.look(entry)
    local row = seqRows[index]
    if not row or row:isDestroyed() then
      row = g_ui.createWidget('RpSeqRow', list)
      seqRows[index] = row
      row.onMousePress = function(widget, mousePos, mouseButton)
        if mouseButton == MouseRightButton then showMenu(mousePos, widget.index) return true end
        selectIndex(widget.index)
        return true
      end
      row.onDoubleClick = function(widget) openEditor(widget.index) return true end
      -- dragging a row is the other way to reorder: a label three screens away from its goto is easier to
      -- move here than on the map
      row.onDragEnter = function(widget)
        seqDrag = widget.index
        return true
      end
      row.onDragMove = function(widget, mousePos)
        local target = seqRowAt(mousePos)
        if target then window.seqHeader:setText(('  MOVE %d TO %d'):format(seqDrag or 0, target)) end
        return true
      end
      row.onDragLeave = function(widget, dropped, mousePos)
        local from, to = seqDrag, seqRowAt(mousePos)
        seqDrag = nil
        if from and to and from ~= to then reorderWaypoint(from, to) else refreshSeq() end
        return true
      end
    end
    local live = (index == liveIndex)
    if isHidden(entry) then
      row:hide()
      row.index = index
      row.stamp = nil
    else
    -- a waypoint with no position of its own runs wherever the one above leaves you: shown indented under it
    local attached = RouteTypes.positionOf(entry) == nil
    local text = ('%d. %s%s'):format(shownNumber(index), RouteTypes.describe(entry), flavourText(index))
    local stamp = text .. (live and '|live' or '') .. (attached and '|attached' or '')
    if row.stamp ~= stamp then
      row.stamp = stamp
      row.dot:setText(t and t.glyph or '?')
      row.dot:setBackgroundColor(t and t.colour or '#888888')
      row.dot:setMarginLeft(attached and 20 or 2)
      row.text:setText((live and '> ' or '') .. text)
      row.text:setColor(live and '#ffffff' or (attached and '#b8b8b8' or '#d8d8d8'))
      row.dot:setBorderWidth(live and 1 or 0)
      row.dot:setBorderColor('#ffffff')
      row:setTooltip(attached and 'No position of its own: it runs where the waypoint above leaves you. Put a Go to before it to run it somewhere specific.' or '')
    end
    if not row:isVisible() then row:show() end
    row.index = index
    if index == selected then
      row:focus()
      pcall(function() window.seqList:ensureChildVisible(row) end)   -- a selection you cannot see is no help
    end
    end
  end
  for i = #route + 1, #seqRows do
    if seqRows[i] and not seqRows[i]:isDestroyed() then seqRows[i]:hide() end
  end
  local shown = routeName ~= '' and routeName or 'unsaved route'
  local running = botRouteName()
  if running and running ~= '' and running ~= routeName then
    window.seqHeader:setText(('  WAYPOINTS - %d in %s   (bot is on "%s")'):format(#route, shown, running))
  else
    window.seqHeader:setText(('  WAYPOINTS - %d in %s'):format(#route, shown))
  end
  refreshLegend()
  refreshMapLegend()
end

-- The legend also belongs on the map: when the window is closed or pushed aside, the colours still have to
-- mean something. It lists only the types this route actually uses.
local legendLines = {}
function refreshMapLegend()
  if not minimap or minimap:isDestroyed() then return end
  if uiHidden or not window or not window:isVisible() then
    if mapLegend and not mapLegend:isDestroyed() then mapLegend:hide() end
    return
  end
  local counts = {}
  for _, entry in ipairs(route) do counts[entry.action] = (counts[entry.action] or 0) + 1 end
  if not mapLegend or mapLegend:isDestroyed() then
    mapLegend = g_ui.createWidget('RpMapLegend', minimap)
    mapLegend:setId('rpLegend')
    -- bottom left, above the Waypoints button: the top right corner belongs to the map's own controls
    mapLegend:addAnchor(AnchorBottom, 'parent', AnchorBottom)
    mapLegend:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    mapLegend:setMarginBottom(26)
    mapLegend:setMarginLeft(6)
    legendLines = {}
    markDirtyStack()
  end
  -- every type, always: a key you have to earn by placing a waypoint is not a key
  local used = 0
  for _, ty in ipairs(RouteTypes.list) do
    used = used + 1
    local line = legendLines[used]
    if not line or line:isDestroyed() then
      line = g_ui.createWidget('RpLegendLine', mapLegend)
      legendLines[used] = line
    end
    local n = counts[ty.id] or 0
    line:setText((' %-3s %-12s %s'):format(ty.glyph, ty.title, n > 0 and n or ''))
    line:setColor(n > 0 and ty.colour or '#6a6a6a')
    line:show()
  end
  for i = used + 1, #legendLines do
    if legendLines[i] and not legendLines[i]:isDestroyed() then legendLines[i]:hide() end
  end
  mapLegend:show()
  mapLegend:raise()
  raiseMapControls()
end

-- one chip per type that the route actually uses, in that type's colour, with how many there are
local legendChips = {}
function refreshLegend()
  if not window or not window.legendRow then return end
  local counts, floors = {}, {}
  local here = viewedFloor()
  for _, entry in ipairs(route) do
    counts[entry.action] = (counts[entry.action] or 0) + 1
    local p = RouteTypes.positionOf(entry)
    if p and p.z ~= here then floors[p.z] = (floors[p.z] or 0) + 1 end
  end
  local used = 0
  for _, t in ipairs(RouteTypes.list) do
    if counts[t.id] then
      used = used + 1
      local chip = legendChips[used]
      if not chip or chip:isDestroyed() then
        chip = g_ui.createWidget('RpLegendChip', window.legendRow)
        legendChips[used] = chip
      end
      chip:setText(('%s %d'):format(t.glyph, counts[t.id]))
      chip:setBackgroundColor(t.colour)
      chip:setTooltip(('%s - %s'):format(t.title, t.hint))
      chip:show()
    end
  end
  for i = used + 1, #legendChips do
    if legendChips[i] and not legendChips[i]:isDestroyed() then legendChips[i]:hide() end
  end
  local other = {}
  for z, n in pairs(floors) do other[#other + 1] = ('floor %d: %d'):format(z, n) end
  if #other > 0 then
    window.seqHeader:setText(window.seqHeader:getText() .. ('  [%s]'):format(table.concat(other, ', ')))
  end
end

function selectIndex(index)
  if route[index] and isHidden(route[index]) then index = visibleNeighbour(index, 1) or visibleNeighbour(index, -1) end
  selected = index
  local entry = route[index]
  if entry then
    local p = RouteTypes.positionOf(entry)
    info(('%d. %s%s%s'):format(shownNumber(index), RouteTypes.describe(entry), flavourText(index),
      p and '' or '   (no position - it runs in order)'))
  end
  drawMarkers()
  refreshSeq()
end

-- ---------------------------------------------------------------- value editors


function openEditor(index)
  local entry = route[index]
  if not entry then return end
  local t = RouteTypes.get(entry.action)
  if not t then return end
  local w = g_ui.createWidget('RpValueWindow', g_ui.getRootWidget())
  w:setText(('%s  -  waypoint %d'):format(t.title, index))
  w.hint:setText(t.hint)
  local multi = (t.editor == 'lua')
  w.valueMulti:setVisible(multi)
  w.valueEdit:setVisible(not multi)
  -- use and use with carry an item id: show the item so you can see what you typed
  local wantsItem = (t.id == 'usewith') or (t.id == 'use' and not tostring(entry.value or ''):find(','))
  w.itemPreview:setVisible(wantsItem and not multi)
  local function showItem(text)
    if not wantsItem then return end
    local raw = tostring(text)
    if t.id == 'use' and raw:find(',') then w.itemPreview:setItemId(0) return end
    local id = tonumber(raw:match('^%s*(%d+)') or '')
    if not id then
      local head = raw:match('^(.-),') or raw
      if head and head ~= '' and RouteItems then id = RouteItems.id(head) end
    end
    w.itemPreview:setItemId((id and id > 100) and id or 0)
    w.itemPreview:setTooltip(id and ('item id ' .. id) or 'no item id in this value')
  end
  if wantsItem then
    showItem(entry.value)
    w.valueEdit.onTextChange = function(widget, text) showItem(text) end
  end
  if multi then
    w:resize(640, 420)
    w.valueMulti:setText(tostring(entry.value or ''))
  else
    w:resize(440, 190)
    w.valueEdit:setText(tostring(entry.value or ''))
    w.valueEdit:focus()
  end
  -- the extra button is a position picker for spatial types, and a template library for lua
  if multi then
    w.extraButton:setVisible(true)
    w.extraButton:setText('Templates')
    w.extraButton:setWidth(110)
    w.extraButton.onClick = function()
      local menu = g_ui.createWidget('RpMenu', g_ui.getRootWidget())
      menu:setWidth(340)
      local all = {}
      for _, tpl in ipairs(RouteTypes.templates) do all[#all + 1] = tpl end
      for _, tpl in ipairs(RouteTypes.presetTemplates(botConfigName())) do all[#all + 1] = tpl end
      for _, tpl in ipairs(all) do
        local row = g_ui.createWidget('RpMenuRow', menu)
        row:setText(tpl.title)
        row.onClick = function()
          closeMenus()
          w.valueMulti:setText(tpl.body)
        end
      end
      menu:setPosition({ x = w:getX() + 8, y = w:getY() + 60 })
      openPopup(menu)
    end
  else
    w.extraButton:setVisible(t.spatial ~= false)
    w.extraButton:setText('Pick on map')
    w.extraButton.onClick = function()
      pickingFor = { index = index, window = w }
      info('click a tile on the map to set the position of waypoint ' .. index)
    end
    -- Aiming help. A rope spot or a hole is one square, and hitting it on a zoomed out map is luck. This
    -- looks around the position you gave it for a tile that actually holds something usable, and moves the
    -- waypoint there.
    if t.spatial then
      local snap = g_ui.createWidget('RpSmall', w)
      snap:setText('Snap to stairs')
      snap:setWidth(96)
      snap:addAnchor(AnchorBottom, 'parent', AnchorBottom)
      snap:addAnchor(AnchorLeft, 'extraButton', AnchorRight)
      snap:setMarginLeft(6)
      snap:setTooltip('Move the waypoint onto the nearest floor change within three squares: the yellow tiles of the minimap (stairs, ladder, hole, ramp, teleport) anywhere on the map, or a usable item on a tile near you. It changes the position now - the bot does not search while it runs.')
      snap.onClick = function()
        local value = w.valueEdit:getText()
        local px, py, pz = tostring(value):match('(-?%d+),%s*(-?%d+),%s*(-?%d+)%s*$')
        if not px then info('this waypoint has no x,y,z to search around') return end
        local base = { x = tonumber(px), y = tonumber(py), z = tonumber(pz) }
        local found, foundName
        -- first the minimap: a floor change is yellow, and the minimap is known for the whole explored map
        for r = 0, 3 do
          for dx = -r, r do
            for dy = -r, r do
              if math.max(math.abs(dx), math.abs(dy)) == r and not found then
                local q = { x = base.x + dx, y = base.y + dy, z = base.z }
                if g_map.getMinimapColor(q) == FLOOR_CHANGE_COLOUR then found, foundName = q, 'a floor change (yellow on the minimap)' end
              end
            end
          end
          if found then break end
        end
        -- then real tiles, which the client only has around you: anything usable
        for r = 0, 3 do
          for dx = -r, r do
            for dy = -r, r do
              if math.max(math.abs(dx), math.abs(dy)) == r and not found then
                local tile = g_map.getTile({ x = base.x + dx, y = base.y + dy, z = base.z })
                if tile then
                  for _, thing in ipairs(tile:getThings()) do
                    if not thing:isCreature() and not found then
                      local ok, usable = pcall(function() return thing:isUsable() end)
                      if ok and usable then
                        found = { x = base.x + dx, y = base.y + dy, z = base.z }
                        foundName = 'item ' .. thing:getId()
                      end
                    end
                  end
                end
              end
            end
          end
          if found then break end
        end
        if not found then warn('no floor change (yellow on the minimap) and nothing usable within three squares - the waypoint was left where it was') return end
        local entry2 = route[index]
        local newValue = RouteTypes.withPosition(entry2, found)
        w.valueEdit:setText(newValue)
        info(('found %s at %d,%d,%d - press OK to keep it'):format(tostring(foundName), found.x, found.y, found.z))
      end
    end
  end
  w.cancelButton.onClick = function() w:destroy() end
  w.okButton.onClick = function()
    pushUndo('editing a waypoint')
    local text = multi and w.valueMulti:getText() or w.valueEdit:getText()
    -- "great mana potion,123,456,7" is easier to write than "238,123,456,7", so resolve the item part
    if not multi and (t.id == 'usewith' or t.id == 'use') then
      local head, tail = tostring(text):match('^(.-)(,%s*-?%d+,%s*-?%d+,%s*-?%d+)%s*$')
      if head and head ~= '' and not tonumber(head) then
        local id = RouteItems and RouteItems.id(head)
        if id then
          text = id .. tail
          info(('%s is item %d'):format(head, id))
        else
          info(('"%s" is not in the item table - add it in Supplies, or write the id'):format(head))
        end
      end
    end
    entry.value = text
    routeVersion = routeVersion + 1
    w:destroy()
    drawMarkers()
    refreshSeq()
    local t2 = RouteTypes.get(entry.action)
    if t2 and t2.spatial and not RouteTypes.positionOf(entry) then
      info(('waypoint %d updated - there is no x,y,z in that value, so it has no marker on the map'):format(index))
    else
      info(('waypoint %d updated'):format(index))
    end
  end
  return w
end

-- ---------------------------------------------------------------- supplies, loot and named items
-- The named item picker under both windows: a search box that filters the table, a click adds the item to
-- the caller's list. Learned names show up here as soon as a shop has been opened.
local function buildItemPicker(w, onPick)
  local itemRows = {}
  local function refreshItems(filter)
    for _, r in ipairs(itemRows) do if not r:isDestroyed() then r:destroy() end end
    itemRows = {}
    filter = tostring(filter or ''):lower():gsub('%s+', '_')
    local names, shown = {}, 0
    for name in pairs(RouteItems.all()) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local id = RouteItems.all()[name]
      if filter == '' or name:find(filter, 1, true) or tostring(id):find(filter, 1, true) then
        shown = shown + 1
        local line = g_ui.createWidget('RpItemLine', w.itemList)
        line.icon:setItemId(id)
        line.text:setText(('%-28s %d'):format(name:gsub('_', ' '), id))
        line.onMousePress = function() onPick((name:gsub('_', ' ')), id) return true end
        itemRows[#itemRows + 1] = line
      end
    end
    w.itemList:updateLayout()
    if w.searchNote then
      w.searchNote:setText(('%d of %d items shown - click one to add it to the list above'):format(shown, #names))
    end
  end
  refreshItems()
  w.nameEdit.onTextChange = function(widget, text) refreshItems(text) end
  return refreshItems
end

function openLootWindow()
  closeMenus()
  local old = g_ui.getRootWidget():recursiveGetChildById('rpLootWindow')
  if old then old:destroy() end
  local w = g_ui.createWidget('RpLootWindow', g_ui.getRootWidget())
  local rows = {}
  local function addRow(entry)
    local r = g_ui.createWidget('RpLootRow', w.lootList)
    local function showIcon(text)
      local id = RouteItems.id(text)
      r.icon:setItemId((id and id > 100) and id or 0)
    end
    r.itemEdit.onTextChange = function(widget, text) showIcon(text) end
    r.itemEdit:setText(tostring(entry and entry.item or ''))
    showIcon(entry and entry.item or '')
    r.depositBox:setChecked(entry and entry.deposit or false)
    r.sellBox:setChecked(entry and entry.sell or false)
    r.keepBox:setChecked(entry and entry.keep or false)
    r.removeButton.onClick = function()
      for i, other in ipairs(rows) do if other == r then table.remove(rows, i) break end end
      r:destroy()
      w.lootList:updateLayout()
    end
    rows[#rows + 1] = r
    w.lootList:updateLayout()
    return r
  end
  for _, entry in ipairs(RouteLoot.list()) do addRow(entry) end
  if #rows == 0 then for _ = 1, 3 do addRow(nil) end end
  -- the three backpack kinds of the by-the-backpack deposit
  local bags = RouteLoot.bags()
  local bagRows = { { row = w.bagLoot, key = 'loot', label = 'loot bag (top of main bp)' },
                    { row = w.bagFull, key = 'full', label = 'full-loot storage (chest)' },
                    { row = w.bagEmpty, key = 'empty', label = 'empty-set storage (chest)' } }
  for _, br in ipairs(bagRows) do
    br.row.label:setText(br.label)
    local function showIcon(text)
      local id = RouteItems.id(text)
      br.row.icon:setItemId((id and id > 100) and id or 0)
    end
    br.row.itemEdit.onTextChange = function(widget, text) showIcon(text) end
    br.row.itemEdit:setText(bags[br.key] and RouteItems.name(bags[br.key]) or '')
    showIcon(br.row.itemEdit:getText())
  end
  w.bagsTools.setSizeEdit:setText(tostring(bags.setSize or 4))
  w.sweepBox:setChecked(bags.sweep and true or false)
  w.stopBox:setChecked(bags.whenOut ~= 'hunt')
  local function bagsFromUi()
    return { loot = RouteItems.id(w.bagLoot.itemEdit:getText()), full = RouteItems.id(w.bagFull.itemEdit:getText()),
             empty = RouteItems.id(w.bagEmpty.itemEdit:getText()), setSize = tonumber(w.bagsTools.setSizeEdit:getText()) or 4,
             sweep = w.sweepBox:isChecked(), whenOut = w.stopBox:isChecked() and 'stop' or 'hunt' }
  end
  w.stopBox.onCheckChange = function(widget, checked)
    RouteLoot.setBags(bagsFromUi())
    info(checked and 'no loot backpack to be had at the depot: the cavebot is stopped'
                  or 'no loot backpack to be had at the depot: hunting goes on without one')
  end
  w.sweepBox.onCheckChange = function(widget, checked)
    RouteLoot.setBags(bagsFromUi())
    RouteDepot.setHuntSweep(checked)
    info(checked and 'loot sweep on: loose loot in the main backpack goes into the loot bag every few seconds'
                  or 'loot sweep off')
  end
  w.bagsTools.setupButton.onClick = function()
    RouteLoot.setBags(bagsFromUi())
    info('building loot sets at the depot - the server log says what happens')
    RouteDepot.runSetup()
  end
  w.bagsTools.swapButton.onClick = function()
    RouteLoot.setBags(bagsFromUi())
    info('dropping the loot backpack off at the depot - the server log says what happens')
    RouteDepot.runSwap()
  end
  w.addButton.onClick = function()
    local r = addRow(nil)
    pcall(function() w.lootList:ensureChildVisible(r) end)
  end
  local function fillFrom(ids, source)
    for i = #rows, 1, -1 do
      local r = rows[i]
      if not r:isDestroyed() and r.itemEdit:getText() == '' then r:destroy() table.remove(rows, i) end
    end
    local have = {}
    for _, r in ipairs(rows) do have[RouteItems.id(r.itemEdit:getText())] = true end
    local added = 0
    for _, id in ipairs(ids) do
      if not have[id] then addRow({ item = RouteItems.name(id), deposit = true }) have[id] = true added = added + 1 end
    end
    w.lootList:updateLayout()
    info(('loaded %d items from %s - tick sell or keep, then Save'):format(added, source))
  end
  w.autolootButton.onClick = function()
    local ids, source = RouteLoot.autolootItems()
    if #ids > 0 then fillFrom(ids, source) return end
    -- nothing cached: send the request FIRST, then poll the module's parsed reply for up to 3s. Polling a
    -- persistent cache means an early reply is caught whenever the poll next runs - no race, no miss.
    local sent = RouteLoot.requestServerList()
    if not sent then info('no autoloot module and not online - type item names here instead') return end
    info('asking the server for its !autoloot list...')
    w.autolootButton:setText('Fetching...')
    local tries = 0
    local function poll()
      tries = tries + 1
      local got, src = RouteLoot.autolootItems()
      if #got > 0 then
        w.autolootButton:setText('Load from autoloot')
        fillFrom(got, src)
      elseif tries < 12 then
        scheduleEvent(poll, 250)
      else
        w.autolootButton:setText('Load from autoloot')
        info('the server sent no autoloot list in 3s - type item names here instead')
      end
    end
    scheduleEvent(poll, 200)
  end
  buildItemPicker(w, function(name)
    for _, r in ipairs(rows) do
      if not r:isDestroyed() and r.itemEdit:getText() == '' then r.itemEdit:setText(name) return end
    end
    addRow({ item = name, deposit = true })
  end)
  w.okButton.onClick = function()
    local list = {}
    for _, r in ipairs(rows) do
      if not r:isDestroyed() and r.itemEdit:getText() ~= '' then
        list[#list + 1] = { item = r.itemEdit:getText(), deposit = r.depositBox:isChecked(),
                            sell = r.sellBox:isChecked(), keep = r.keepBox:isChecked() }
      end
    end
    local bad = {}
    for _, row in ipairs(list) do
      if not RouteItems.id(row.item) then bad[#bad + 1] = row.item end
    end
    local saved = RouteLoot.set(list)
    RouteLoot.setBags(bagsFromUi())
    w:destroy()
    if #bad > 0 then
      info(('loot saved, but these names are not recognised and were ignored: %s'):format(table.concat(bad, ', ')))
    else
      info(('loot saved - %d lines: %d depot, %d sell, %d keep'):format(#saved,
        #RouteLoot.depositIds(), #RouteLoot.sellIds(), #RouteLoot.keepIds()))
    end
  end
  w.cancelButton.onClick = function() w:destroy() end
  w:raise() w:focus()
  g_keyboard.bindKeyDown('Escape', function() if w and not w:isDestroyed() then w:destroy() end end, w)
  return w
end

function openSupplyWindow()
  closeMenus()
  local old = g_ui.getRootWidget():recursiveGetChildById('rpSupplyWindow')
  if old then old:destroy() end
  local w = g_ui.createWidget('RpSupplyWindow', g_ui.getRootWidget())
  local rows = {}
  w.walkBox:setChecked(RouteSupply.walkMode())
  w.walkBox.onCheckChange = function(widget, checked)
    RouteSupply.setWalkMode(checked)
    info(checked and 'Buy supplies will open every bag to count' or 'Buy supplies trusts the counts the game prints; bags are opened only for items it has not seen you use')
  end

  local function addRow(entry)
    local r = g_ui.createWidget('RpSupplyRow', w.supplyList)
    local function showIcon(text)
      local id = RouteItems.id(text)
      r.icon:setItemId((id and id > 100) and id or 0)
    end
    r.itemEdit.onTextChange = function(widget, text) showIcon(text) end
    r.itemEdit:setText(tostring(entry and entry.item or ''))
    showIcon(entry and entry.item or '')
    r.amountEdit:setText(tostring(entry and entry.amount or 100))
    r.capEdit:setText(tostring(entry and entry.fullCap or 200))
    r.fullCapBox:setChecked(entry and entry.fullCap ~= nil or false)
    -- one column or the other, never both: whichever is greyed out is the one being ignored
    local function syncRow()
      local full = r.fullCapBox:isChecked()
      r.amountEdit:setEnabled(not full)
      r.capEdit:setEnabled(full)
      r.capNote:setColor(full and '#9d9d9d' or '#5a5a5a')
    end
    r.fullCapBox.onCheckChange = function(widget, checked)
      if checked then
        for _, other in ipairs(rows) do
          if other ~= r and not other:isDestroyed() and other.fullCapBox:isChecked() then
            other.fullCapBox:setChecked(false)
          end
        end
      end
      syncRow()
    end
    syncRow()
    r.removeButton.onClick = function()
      for i, other in ipairs(rows) do if other == r then table.remove(rows, i) break end end
      r:destroy()
    end
    rows[#rows + 1] = r
    w.supplyList:updateLayout()          -- the scroll range only settles once the layout has run
    return r
  end

  for _, entry in ipairs(RouteSupply.list()) do addRow(entry) end
  if #rows == 0 then for _ = 1, 3 do addRow(nil) end end
  w.supplyList:updateLayout()
  w.addButton.onClick = function()
    local r = addRow(nil)
    pcall(function() w.supplyList:ensureChildVisible(r) end)
  end

  local refreshItems = buildItemPicker(w, function(name)
    for _, r in ipairs(rows) do
      if not r:isDestroyed() and r.itemEdit:getText() == '' then r.itemEdit:setText(name) return end
    end
    addRow({ item = name, amount = 100 })
  end)

  w.learnButton.onClick = function()
    local name = w.nameEdit:getText()
    local id = tonumber(w.idEdit:getText())
    if not name or name == '' then info('give the item a name first') return end
    RouteItems.set(name, id)
    w.idEdit:setText('')
    refreshItems(w.nameEdit:getText())
    info(id and ('%s is item %d'):format(name, id) or ('removed ' .. name))
  end

  w.okButton.onClick = function()
    local list = {}
    for _, r in ipairs(rows) do
      if not r:isDestroyed() then
        local item = r.itemEdit:getText()
        if item and item ~= '' then
          if r.fullCapBox:isChecked() then
            list[#list + 1] = { item = item, fullCap = tonumber(r.capEdit:getText()) or 200 }
          else
            list[#list + 1] = { item = item, amount = tonumber(r.amountEdit:getText()) or 0 }
          end
        end
      end
    end
    local saved = RouteSupply.set(list)
    w:destroy()
    info(('supply list saved - %d lines'):format(#saved))
  end
  w.cancelButton.onClick = function() w:destroy() end
  w:raise() w:focus()
  g_keyboard.bindKeyDown('Escape', function() if w and not w:isDestroyed() then w:destroy() end end, w)
  return w
end

-- ---------------------------------------------------------------- adding and removing
local function insertAt(index, action, value, quiet)
  local entry = { action = action, value = value }
  table.insert(route, index, entry)
  routeVersion = routeVersion + 1
  if not quiet then
    drawMarkers()
    refreshSeq()
  end
  return entry
end

function addWaypoint(action, pos, openIt)
  pushUndo('placing a waypoint')
  local where = (selected and selected < #route) and (selected + 1) or (#route + 1)
  -- a one click type is an ordinary function waypoint that arrives with its script already written
  local quick = RouteTypes.quickGet(action)
  local value
  if quick then
    local me = g_game.getLocalPlayer()
    local at = pos or (me and me:getPosition())
    action, value = 'function', RouteTypes.quickBody(quick, at)
  else
    value = RouteTypes.defaultValue(action, pos or { x = 0, y = 0, z = viewedFloor() })
  end
  insertAt(where, action, value, true)
  -- label, say, delay and function carry no position, so remember where the click was: otherwise they would
  -- only ever be drawn hanging off some other waypoint
  local placed = route[where]
  if placed and not RouteTypes.positionOf(placed) then
    local me = g_game.getLocalPlayer()
    local at = pos or (me and me:getPosition())
    if at then placed._pin = { x = at.x, y = at.y, z = at.z } end
  end
  selected = where
  drawMarkers()
  refreshSeq()
  local t = quick or RouteTypes.get(action)
  info(('added %s as waypoint %d'):format(t and t.title or action, shownNumber(where)))
  if openIt then openEditor(where) end
  return where
end

function removeWaypoint(index)
  if not route[index] then return end
  pushUndo('removing a waypoint')
  table.remove(route, index)
  if selected and selected > #route then selected = #route end
  routeVersion = routeVersion + 1
  drawMarkers()
  refreshSeq()
  info(('removed waypoint %d'):format(shownNumber(index)))
end

-- ---------------------------------------------------------------- the right click menu
local openMenu

function closeMenus()
  openMenu, menuBackdrop = nil, nil
  -- sweep by id: every menu and every sheet, however it was opened
  local root = g_ui.getRootWidget()
  for _, c in ipairs(root:getChildren()) do
    local id = c:getId()
    if (id == 'rpMenu' or id == 'rpMenuBackdrop') and not c:isDestroyed() then c:destroy() end
  end
end

-- Every menu is put up this way: an invisible sheet fills the screen underneath it, so a click anywhere
-- outside closes the menu instead of leaving it stuck on the map.
function openPopup(menu)
  local root = g_ui.getRootWidget()
  local back = g_ui.createWidget('UIWidget', root)
  back:setId('rpMenuBackdrop')
  back:addAnchor(AnchorTop, 'parent', AnchorTop)
  back:addAnchor(AnchorBottom, 'parent', AnchorBottom)
  back:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  back:addAnchor(AnchorRight, 'parent', AnchorRight)
  back:setBackgroundColor('#00000001')
  back:setPhantom(false)
  back:setFocusable(false)
  back.onMousePress = function() closeMenus() return true end
  -- above everything that was there (the map included), and then the menu is raised above the sheet
  menuBackdrop = back
  openMenu = menu
  menu:raise()
  menu:focus()
end

function showMenu(mousePos, index)
  closeMenus()
  local menu = g_ui.createWidget('RpMenu', g_ui.getRootWidget())
  openMenu = menu
  local function row(text, colour, fn)
    local b = g_ui.createWidget('RpMenuRow', menu)
    b:setText(text)
    if colour then b:setColor(colour) end
    -- close everything that is open, then act: a row that only destroyed its own menu left the click
    -- catching sheet behind it
    b.onClick = function() closeMenus() fn() end
    return b
  end
  if index then
    local entry = route[index]
    local t = RouteTypes.get(entry.action)
    local head = row(('%s  (waypoint %d)'):format(t and t.title or entry.action, index), t and t.colour or nil, function() end)
    if head then head:setEnabled(false) end
    row('Edit value', nil, function() openEditor(index) end)
    row('Duplicate', nil, function()
      local copy = insertAt(index + 1, entry.action, entry.value)
      copy._pin = entry._pin
      selectIndex(index + 1)
    end)
    row('Move up', nil, function()
      local prev = visibleNeighbour(index, -1)
      if prev then pushUndo('moving a waypoint up') local at = moveBlock(index, prev) routeVersion = routeVersion + 1 selectIndex(at) end
    end)
    row('Move down', nil, function()
      local nxt = visibleNeighbour(index, 1)
      if nxt then pushUndo('moving a waypoint down') local at = moveBlock(index, nxt) routeVersion = routeVersion + 1 selectIndex(at) end
    end)
    if entry.action == 'goto' then row('Make this the loop end', nil, function() makeLoopEnd(index) end) end
    -- labels and jumps live on the waypoint: a label lands here, a jump leaves from here
    local tags, jumps = flavourOf(index)
    if #tags == 0 then
      row('Label this waypoint...', '#ffff55', function()
        pushUndo('labelling a waypoint')
        table.insert(route, index, { action = 'label', value = 'hunt' })
        routeVersion = routeVersion + 1
        selectIndex(index + 1)
        openEditor(index)
      end)
    else
      row(('Remove label %s'):format(table.concat(tags, ', ')), '#ffff55', function()
        pushUndo('removing a label')
        local i = index - 1
        while i >= 1 and isHidden(route[i]) do
          if route[i].action == 'label' then table.remove(route, i) index = index - 1 end
          i = i - 1
        end
        routeVersion = routeVersion + 1
        selectIndex(index)
      end)
    end
    if #jumps == 0 then
      row('After this, jump to label...', '#ffe14d', function()
        pushUndo('adding a jump')
        table.insert(route, index + 1, { action = 'gotolabel', value = 'hunt' })
        routeVersion = routeVersion + 1
        selectIndex(index)
        openEditor(index + 1)
      end)
    else
      row(('Remove jump to %s'):format(table.concat(jumps, ', ')), '#ffe14d', function()
        pushUndo('removing a jump')
        local i = index + 1
        while i <= #route and isHidden(route[i]) do
          if route[i].action == 'gotolabel' then table.remove(route, i) else i = i + 1 end
        end
        routeVersion = routeVersion + 1
        selectIndex(index)
      end)
    end
    row('Change type...', nil, function()
      closeMenus()
      local sub = g_ui.createWidget('RpMenu', g_ui.getRootWidget())
      sub:setWidth(230)
      local choices = {}
      for _, nt in ipairs(RouteTypes.list) do choices[#choices + 1] = nt end
      for _, q in ipairs(RouteTypes.quick) do choices[#choices + 1] = q end
      for _, nt in ipairs(choices) do
        local r = g_ui.createWidget('RpMenuRow', sub)
        r:setText(nt.title .. (nt.id == entry.action and '   (current)' or ''))
        r:setColor(nt.colour)
        r.onClick = function()
          closeMenus()
          if nt.id == entry.action then return end
          -- a one click job is a function waypoint with its script already written
          if nt.body then
            pushUndo('changing a waypoint type')
            local keep = RouteTypes.positionOf(entry) or entry._pin
            entry.action = 'function'
            entry.value = RouteTypes.quickBody(nt, keep)
            entry._pin = keep and { x = keep.x, y = keep.y, z = keep.z } or entry._pin
            routeVersion = routeVersion + 1
            drawMarkers()
            refreshSeq()
            info(('waypoint %d is now %s'):format(index, nt.title))
            return
          end
          pushUndo('changing a waypoint type')
          local pos = RouteTypes.positionOf(entry)
          entry.action = nt.id
          -- a position is worth keeping when the new type has one, otherwise start the value clean
          if nt.spatial and pos then
            entry.value = RouteTypes.withPosition(entry, pos)
            entry._pin = nil
          elseif nt.spatial then
            entry.value = ''
            entry._pin = nil
          else
            entry.value = RouteTypes.defaultValue(nt.id, pos) or ''
            -- the new type has no position of its own, so remember the tile it was on: otherwise it jumps
            -- back to whichever waypoint happens to come before it
            entry._pin = pos and { x = pos.x, y = pos.y, z = pos.z } or nil
          end
          routeVersion = routeVersion + 1
          drawMarkers()
          refreshSeq()
          info(('waypoint %d is now a %s'):format(index, nt.title))
          openEditor(index)
        end
      end
      sub:setPosition({ x = mousePos.x + 20, y = mousePos.y + 10 })
      openPopup(sub)
    end)
    row('Remove', '#ff8080', function() removeWaypoint(index) end)
  else
    local pos = minimap:getTilePosition(mousePos)
    if not pos then menu:destroy() return end
    local head = row(('Add here  (%d,%d,%d)'):format(pos.x, pos.y, pos.z), '#cccccc', function() end)
    if head then head:setEnabled(false) end
    for _, t in ipairs(RouteTypes.placeable) do
      row(t.title, t.colour, function() addWaypoint(t.id, pos, false) end)
    end
    local sep = row('one click jobs', '#9a9a9a', function() end)
    if sep then sep:setEnabled(false) end
    for _, q in ipairs(RouteTypes.quick) do
      row(q.title, q.colour, function() addWaypoint(q.id, pos, false) end)
    end
  end
  menu:setPosition({ x = mousePos.x, y = mousePos.y })
  openPopup(menu)
  return menu
end

-- ---------------------------------------------------------------- generating goto waypoints
local function walkable(x, y, z)
  return not BLOCKED_COLOUR[g_map.getMinimapColor({ x = x, y = y, z = z })]
end

local function noGoAt(x, y, z)
  local layer = layerFor(z, false)
  return layer and layer.tiles[x .. ',' .. y] == 3
end

local function snapToGround(p, tiles)
  if walkable(p.x, p.y, p.z) and not noGoAt(p.x, p.y, p.z) then return p end
  local fallback
  for r = 1, SNAP_RADIUS do
    for dx = -r, r do
      for dy = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r then
          local x, y = p.x + dx, p.y + dy
          if walkable(x, y, p.z) and not noGoAt(x, y, p.z) then
            if tiles[x .. ',' .. y] then return { x = x, y = y, z = p.z, w = p.w } end
            fallback = fallback or { x = x, y = y, z = p.z, w = p.w }
          end
        end
      end
    end
  end
  return fallback
end

local function withoutStrays(tiles)
  if #tiles < 2 then return tiles, 0 end
  local index, groups, seen = {}, {}, {}
  for i, p in ipairs(tiles) do index[p.x .. ',' .. p.y] = i end
  for i in ipairs(tiles) do
    if not seen[i] then
      local group, queue = {}, { i }
      seen[i] = true
      while #queue > 0 do
        local cur = table.remove(queue)
        local c = tiles[cur]
        group[#group + 1] = c
        for dx = -1, 1 do
          for dy = -1, 1 do
            local j = index[(c.x + dx) .. ',' .. (c.y + dy)]
            if j and not seen[j] then seen[j] = true queue[#queue + 1] = j end
          end
        end
      end
      groups[#groups + 1] = group
    end
  end
  local main = groups[1]
  for _, g in ipairs(groups) do if #g > #main then main = g end end
  local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
  for _, p in ipairs(main) do
    if p.x < minX then minX = p.x end
    if p.x > maxX then maxX = p.x end
    if p.y < minY then minY = p.y end
    if p.y > maxY then maxY = p.y end
  end
  local kept, dropped = {}, 0
  for _, g in ipairs(groups) do
    local near = false
    for _, p in ipairs(g) do
      local dx = math.max(0, math.max(minX - p.x, p.x - maxX))
      local dy = math.max(0, math.max(minY - p.y, p.y - maxY))
      if math.max(dx, dy) <= STRAY_DISTANCE then near = true break end
    end
    for _, p in ipairs(g) do
      if near then kept[#kept + 1] = p else dropped = dropped + 1 end
    end
  end
  return kept, dropped
end

-- parsing "x,y" for every tile is the bulk of the work on a big drawing, so it is done once per change
local function parsedTiles(layer, z)
  local key = z .. ':' .. layerVersion
  if tilesCache.key == key then return tilesCache.tiles end
  local tiles = {}
  for tkey, w in pairs(layer.tiles) do
    local x, y = tkey:match('^(-?%d+),(-?%d+)$')
    -- weight 3 is the no-go brush: it is drawn, but a waypoint is never put on it
    if x and w ~= 3 then tiles[#tiles + 1] = { x = tonumber(x), y = tonumber(y), z = z, w = w } end
  end
  tilesCache = { key = key, tiles = tiles }
  return tiles
end

local function sampleWaypoints()
  local z = viewedFloor()
  local layer = layerFor(z, false)
  if not layer then return {} end
  local source = parsedTiles(layer, z)
  local tiles = {}
  for i, p in ipairs(source) do tiles[i] = { x = p.x, y = p.y, z = p.z, w = p.w } end
  tiles, strayCount = withoutStrays(tiles)
  table.sort(tiles, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  local base = data.spacing or 12
  local function room(w) return (w == 2) and math.max(2, math.floor(base / 2)) or base end
  -- Each waypoint claims a bubble, and the next one may not land inside it. Checking that against every
  -- point already chosen is O(n*k); the chosen points go into buckets one bubble wide, so only the nine
  -- buckets around a tile have to be looked at.
  local cell = math.max(1, base)
  local buckets, picked = {}, {}
  for _, p in ipairs(tiles) do
    local bx, by = math.floor(p.x / cell), math.floor(p.y / cell)
    local free = true
    for dx = -1, 1 do
      for dy = -1, 1 do
        local bucket = buckets[(bx + dx) .. ':' .. (by + dy)]
        if bucket then
          for _, q in ipairs(bucket) do
            if math.max(math.abs(p.x - q.x), math.abs(p.y - q.y)) < math.min(room(p.w), room(q.w)) then
              free = false break
            end
          end
        end
        if not free then break end
      end
      if not free then break end
    end
    if free then
      picked[#picked + 1] = p
      local key = bx .. ':' .. by
      buckets[key] = buckets[key] or {}
      table.insert(buckets[key], p)
    end
  end
  local onGround, taken = {}, {}
  movedCount, droppedCount = 0, 0
  for _, p in ipairs(picked) do
    local q = snapToGround(p, layer.tiles)
    if not q then
      droppedCount = droppedCount + 1
    else
      local key = q.x .. ',' .. q.y
      if taken[key] then
        droppedCount = droppedCount + 1     -- two bubbles snapped onto the same ground tile
      else
        taken[key] = true
        if q.x ~= p.x or q.y ~= p.y then movedCount = movedCount + 1 end
        onGround[#onGround + 1] = q
      end
    end
  end
  return onGround
end

-- nearest unvisited first, then 2-opt until it stops improving. Euclidean on purpose: with chebyshev a
-- crossing costs the same as a clean loop, so nothing ever pulls the crossings apart.
local function orderRoute(pts)
  if #pts < 3 then return pts end
  local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
  end
  local me = g_game.getLocalPlayer()
  local from = (me and me:getPosition()) or pts[1]
  local left, tour = {}, {}
  for i, p in ipairs(pts) do left[i] = p end
  while #left > 0 do
    local best, bestD = 1, math.huge
    for i, p in ipairs(left) do
      local d = dist(p, from)
      if d < bestD then best, bestD = i, d end
    end
    from = table.remove(left, best)
    tour[#tour + 1] = from
  end
  local n = #tour
  if n > 600 then return tour end
  -- the pass is O(n^2); allow fewer of them as the route grows so a huge cave still generates quickly
  local budget = math.max(6, math.min(60, math.floor(4000000 / (n * n))))
  local rounds, improved = 0, true
  while improved and rounds < budget do
    improved = false
    rounds = rounds + 1
    for i = 1, n - 1 do
      local last = (i > 1) and n or (n - 1)
      for k = i + 2, last do
        local a, b, c = tour[i], tour[i + 1], tour[k]
        local d = tour[k + 1] or tour[1]
        if dist(a, c) + dist(b, d) < dist(a, b) + dist(c, d) - 0.0001 then
          local lo, hi = i + 1, k
          while lo < hi do
            tour[lo], tour[hi] = tour[hi], tour[lo]
            lo, hi = lo + 1, hi - 1
          end
          improved = true
        end
      end
    end
  end
  return tour
end

-- Generated waypoints are plain goto entries, appended in walking order. Anything the user placed by hand
-- on this floor is replaced; waypoints on other floors and every non-goto action are left alone.
local MAX_GENERATED = 500

-- Regenerate the goto waypoints while you paint, so the route you are building is the route you can see.
-- Hand placed waypoints are kept, exactly as pressing Generate would.
local previewEvent
local previewCap = 250
function schedulePreview()
  if previewEvent then removeEvent(previewEvent) end
  -- wait for the brush to go quiet: generating in the middle of a stroke is what made it stutter
  previewEvent = scheduleEvent(function()
    previewEvent = nil
    if not (data.livePreview and mode == 'draw' and window and window:isVisible() and not uiHidden) then return end
    local sampled = sampleWaypoints()
    if #sampled > previewCap then
      warn(('that drawing would make %d waypoints - too many to preview while you draw, press Generate goto when you are done')
        :format(#sampled))
      return
    end
    pcall(function() generateGotos(true) end)
  end, 700)
end

function generateGotos(quiet)
  local sampled = sampleWaypoints()
  -- spacing 1 on a big drawing means one waypoint per tile: thousands of markers, a huge cfg, and a route
  -- no cavebot should walk. Say so instead of building it.
  if #sampled > MAX_GENERATED then
    warn(('that drawing at one waypoint per %d squares would make %d waypoints - raise the spacing')
      :format(data.spacing, #sampled))
    return 0
  end
  local pts = orderRoute(sampled)
  if #pts > 0 and not quiet then pushUndo('generating goto waypoints') end
  if #pts == 0 then
    warn('nothing painted on this floor yet - press Draw in the map toolbar, then drag over the map')
    return 0
  end
  local z = viewedFloor()
  local kept, insertAtIndex, replaced = {}, nil, 0
  for _, entry in ipairs(route) do
    local p = RouteTypes.positionOf(entry)
    if entry.action == 'goto' and p and p.z == z then
      replaced = replaced + 1
      insertAtIndex = insertAtIndex or (#kept + 1)     -- the new block goes where the old one started
    else
      kept[#kept + 1] = entry
    end
  end
  insertAtIndex = insertAtIndex or (#kept + 1)
  for i, p in ipairs(pts) do
    table.insert(kept, insertAtIndex + i - 1, { action = 'goto', value = ('%d,%d,%d'):format(p.x, p.y, p.z) })
  end
  route = kept
  routeVersion = routeVersion + 1
  selected = nil
  drawMarkers()
  refreshSeq()
  local txt = ('%d goto waypoints, one per %d squares'):format(#pts, data.spacing)
  if replaced > 0 then txt = txt .. (' - replaced the %d goto waypoints that were on this floor'):format(replaced) end
  if movedCount > 0 then txt = txt .. (' - %d moved onto ground'):format(movedCount) end
  if droppedCount > 0 then txt = txt .. (' - %d dropped'):format(droppedCount) end
  if strayCount > 0 then txt = txt .. (' - %d stray tiles ignored'):format(strayCount) end
  if not quiet then info(txt) end
  return #pts
end

-- ---------------------------------------------------------------- load and save
-- one drawing = one route: starting over drops the open route's unsaved strokes and the unnamed scratch drawing
function newRoute()
  pushUndo('starting a new route')
  data.masks[maskKey(routeName)] = nil
  data.masks['(unnamed)'] = nil
  route, routeTail, selected = {}, {}, nil
  tailFrom = nil
  routeName = ''
  if window then window.nameEdit:setText('') end     -- an empty name, so Save cannot quietly hit the route you loaded
  routeVersion = routeVersion + 1
  layerVersion = layerVersion + 1
  persist()
  render(true)
  drawMarkers() refreshSeq()
  info('empty route - name it, draw an area and press Generate goto, or place waypoints by hand')
end

function loadRoute(name)
  local dir, cfg = routeDir()
  if not dir then warn('no bot config selected') return false end
  local path = dir .. '/' .. name .. '.cfg'
  if not g_resources.fileExists(path) then warn('no route called "' .. name .. '"') return false end
  local list = RouteCfg.parse(g_resources.readFileContents(path))
  if list.unterminated then
    warn(('"%s" has a %s waypoint whose [[ block is never closed - fix the file before editing it here')
      :format(name, list.unterminated))
    return false
  end
  route, routeTail = RouteCfg.split(list)
  tailFrom = name
  if maskKey(routeName) ~= maskKey(name) then data.masks[maskKey(routeName)] = nil end   -- unsaved strokes go
  data.masks['(unnamed)'] = nil
  data.masks[maskKey(name)] = copyTable(data.saved[maskKey(name)])
  routeName = name
  data.lastRoute = name
  selected = nil
  routeVersion = routeVersion + 1
  layerVersion = layerVersion + 1
  if window then window.nameEdit:setText(name) end
  -- look at where the route actually is
  for _, entry in ipairs(route) do
    local p = RouteTypes.positionOf(entry)
    if p then minimap:setCameraPosition(p) break end
  end
  drawMarkers()
  refreshSeq()
  render(true)
  local counts = {}
  for _, e in ipairs(route) do counts[e.action] = (counts[e.action] or 0) + 1 end
  local parts = {}
  for _, t in ipairs(RouteTypes.list) do
    if counts[t.id] then parts[#parts + 1] = ('%s %d'):format(t.title, counts[t.id]) end
  end
  info(('loaded "%s" from %s: %d waypoints (%s)'):format(name, cfg, #route, table.concat(parts, ', ')))
  persist()
  return true
end

function saveRoute(name)
  name = name or routeName
  if not name or name == '' then warn('give the route a name first') return false end
  local dir, cfg = routeDir()
  if not dir then warn('no bot config selected') return false end
  if #route == 0 then warn('nothing to save - draw an area and press Generate goto, or place waypoints') return false end
  pcall(function() g_resources.makeDir(dir) end)
  local path = dir .. '/' .. name .. '.cfg'
  -- An existing route keeps its own cavebot settings and supply/depositer data. The cached tail belongs to
  -- the route it was read from: saving under another name must never carry that route's settings across.
  if tailFrom ~= name then
    routeTail = {}
    if g_resources.fileExists(path) then
      local ok, parsed = pcall(function() return RouteCfg.parse(g_resources.readFileContents(path)) end)
      if ok and parsed then
        local _, tail = RouteCfg.split(parsed)
        routeTail = tail
      end
    end
    tailFrom = name
  end
  local bad, entry = RouteCfg.unwritable(route)
  if bad then
    warn(('waypoint %d (%s) has a line of just ]] in it - the cavebot could not read that file back, so nothing was saved')
      :format(bad, entry.action))
    return false
  end
  -- a route written before the rename: its function waypoints move to the new module name as it is saved
  for _, e in ipairs(route) do
    if type(e.value) == 'string' and e.value:find('modules.game_route_paint', 1, true) then
      e.value = e.value:gsub('modules%.game_route_paint', 'modules.game_waypoint_editor')
    end
  end
  local text = RouteCfg.serialise(RouteCfg.join(route, routeTail))
  if not g_resources.writeFileContents(path, text) then
    -- the client refuses a name holding / \ : * ? " < > | and returns false rather than raising
    warn(('could not write "%s" - a route name cannot contain / \\ : * ? " < > or |'):format(name))
    return false
  end
  local from, to = maskKey(routeName), maskKey(name)
  if from ~= to then
    data.masks[to] = data.masks[from]
    data.masks[from] = nil
    layerVersion = layerVersion + 1
  end
  data.saved[to] = copyTable(data.masks[to])
  routeName = name
  data.lastRoute = name
  persist()
  pcall(function() g_settings.save() end)
  local ctx = botContext and botContext()
  local cave = ctx and ctx.CaveBot
  local selected = botRouteName()
  if selected and selected ~= name then
    if cave and type(cave.isOn) == 'function' and not cave.isOn() and selectBotRoute(name) then
      info(('saved "%s" to %s (%d waypoints) - the cavebot is now set to it, Bot: on runs it'):format(name, cfg, #route))
    else
      info(('saved "%s" to %s (%d waypoints) - the cavebot is running "%s"; press Bot: off, then Bot: on to switch')
        :format(name, cfg, #route, selected))
    end
  else
    info(('saved "%s" to %s (%d waypoints) - the cavebot has re-read it'):format(name, cfg, #route))
  end
  reloadBot()
  return true
end

-- ---------------------------------------------------------------- map interaction
local hooks = {}

-- A press that lands on our own toolbar, menu or window must never also reach the map: in Place mode the
-- map would drop a waypoint under the button you just clicked.
local function overUI(mousePos)
  local function hit(w)
    return w and not w:isDestroyed() and w:isVisible() and w:containsPoint(mousePos)
  end
  if hit(toolbar) or hit(openMenu) or hit(window) or hit(mapButton) or hit(closeButton) then return true end
  for _, c in ipairs(g_ui.getRootWidget():getChildren()) do
    local id = c:getId()
    if (id == 'rpMenu' or id == 'rpValueWindow' or id == 'rpSupplyWindow' or id == 'rpLootWindow') and hit(c) then return true end
  end
  return false
end

-- clicking any of our buttons arms this, so the press that follows cannot fall through to the map
function suppressMap() suppressMapUntil = now() + 150 end

-- The right button does two things in every mode: a click opens the menu, a press-and-drag pans the map (the
-- left button is busy painting or placing in Draw and Place). The menu therefore opens on release, and only
-- when the pointer did not move.
local rightDrag

local function handleMapPress(widget, mousePos, mouseButton)
  if uiHidden then return false end
  if openMenu and not openMenu:isDestroyed() then closeMenus() return true end   -- belt and braces
  if now() < suppressMapUntil or overUI(mousePos) then return true end
  local pos = minimap:getTilePosition(mousePos)
  if mouseButton == MouseRightButton then
    if markerAt(mousePos) then return false end        -- the marker handles its own menu
    rightDrag = { start = mousePos, last = mousePos, moved = false, ax = 0, ay = 0 }
    return true
  end
  if pickingFor then
    local target = pickingFor
    pickingFor = nil
    local entry = route[target.index]
    if entry and pos then
      local value = RouteTypes.withPosition(entry, pos)
      if target.window and not target.window:isDestroyed() then
        target.window.valueEdit:setText(value)     -- the editor is open: Apply commits it, Cancel drops it
        info(('picked %d,%d,%d - press Apply to keep it'):format(pos.x, pos.y, pos.z))
      else
        entry.value = value
        routeVersion = routeVersion + 1
        drawMarkers()
        refreshSeq()
        info(('waypoint %d now points at %d,%d,%d'):format(target.index, pos.x, pos.y, pos.z))
      end
    end
    return true
  end
  if mode == 'move' then return false end
  if mode == 'place' and pos then
    addWaypoint(placeType, pos, g_keyboard.isCtrlPressed())
    return true
  end
  if mode == 'draw' and recording and not dragging then
    paintAround(pos)
    dirty = false persist()
    return true
  end
  -- Draw and Place take the click. Letting it through would send the character walking across the map
  -- every time you missed a waypoint.
  return true
end

-- What the next click will do, drawn under the pointer: the brush footprint in Draw, the marker that will be
-- dropped in Place. Nothing in Default, because Default is the plain map.
function updateCursor(mousePos)
  if not minimap or minimap:isDestroyed() then return end
  local wanted = (not uiHidden) and window and window:isVisible()
                 and (mode == 'draw' or mode == 'place') and mousePos and not overUI(mousePos)
  if not wanted then
    if cursorGhost and not cursorGhost:isDestroyed() then cursorGhost:hide() end
    return
  end
  if not cursorGhost or cursorGhost:isDestroyed() then
    cursorGhost = g_ui.createWidget('RpGhost', minimap)
    cursorGhost:setId('rpCursor')
    cursorGhost:setPhantom(true)
  end
  if mode == 'draw' then
    local side = screenSize(brush)
    cursorGhost:setText('')
    cursorGhost:resize(side, side)
    local c = PAINT_COLOURS[paintWeight] or { 200, 200, 200 }
    cursorGhost:setBackgroundColor(('#%02x%02x%02x66'):format(c[1], c[2], c[3]))
    cursorGhost:setBorderColor(paintWeight == 0 and '#ff6666' or '#ffffff')
    cursorGhost:setPosition({ x = mousePos.x - math.floor(side / 2), y = mousePos.y - math.floor(side / 2) })
  else
    local q = RouteTypes.quickGet(placeType)
    local ty = q or RouteTypes.get(placeType)
    cursorGhost:resize(18, 18)
    cursorGhost:setText(ty and ty.glyph or '?')
    cursorGhost:setBackgroundColor(ty and ty.colour or '#ffffff')
    cursorGhost:setBorderColor('#ffffff')
    cursorGhost:setPosition({ x = mousePos.x + 10, y = mousePos.y + 10 })
  end
  cursorGhost:show()
  cursorGhost:raise()
end

function installHooks()
  if hooks.installed then return end
  hooks.installed = true
  hooks.press, hooks.dragEnter, hooks.dragMove, hooks.dragLeave =
    minimap.onMousePress, minimap.onDragEnter, minimap.onDragMove, minimap.onDragLeave
  hooks.move = minimap.onMouseMove
  minimap.onMouseMove = function(widget, mousePos, moved)
    if rightDrag then
      local d = rightDrag
      local dx, dy = mousePos.x - d.last.x, mousePos.y - d.last.y
      d.last = mousePos
      if math.abs(mousePos.x - d.start.x) + math.abs(mousePos.y - d.start.y) > 4 then d.moved = true end
      if d.moved then
        -- pixels dragged become tiles of camera movement; the remainder is kept so slow drags still move
        local scale = minimap:getScale() or 1
        d.ax, d.ay = d.ax - dx / scale, d.ay - dy / scale
        local tx = d.ax >= 0 and math.floor(d.ax) or math.ceil(d.ax)
        local ty = d.ay >= 0 and math.floor(d.ay) or math.ceil(d.ay)
        if tx ~= 0 or ty ~= 0 then
          local cam = minimap:getCameraPosition()
          minimap:setCameraPosition({ x = cam.x + tx, y = cam.y + ty, z = cam.z })
          d.ax, d.ay = d.ax - tx, d.ay - ty
        end
      end
      return true
    end
    updateCursor(mousePos)
    return hooks.move and hooks.move(widget, mousePos, moved) or false
  end
  hooks.release = minimap.onMouseRelease
  minimap.onMouseRelease = function(widget, mousePos, mouseButton)
    if mouseButton == MouseRightButton and rightDrag then
      local d = rightDrag
      rightDrag = nil
      if not d.moved and not uiHidden then showMenu(mousePos, nil) end
      return true
    end
    return hooks.release and hooks.release(widget, mousePos, mouseButton) or false
  end

  minimap.onMousePress = function(widget, mousePos, mouseButton)
    if handleMapPress(widget, mousePos, mouseButton) then return true end
    return hooks.press and hooks.press(widget, mousePos, mouseButton) or false
  end
  minimap.onDragEnter = function(widget, mousePos)
    if not uiHidden and mode == 'draw' and recording and not dragging and not overUI(mousePos) then return true end
    return hooks.dragEnter and hooks.dragEnter(widget, mousePos) or false
  end
  minimap.onDragMove = function(widget, mousePos, moved)
    if not uiHidden and mode == 'draw' and recording and not dragging and not overUI(mousePos) then
      paintAround(minimap:getTilePosition(mousePos))
      return true
    end
    return hooks.dragMove and hooks.dragMove(widget, mousePos, moved) or false
  end
  minimap.onDragLeave = function(widget, dropped, mousePos)
    if mode == 'draw' and recording then
      modules.game_waypoint_editor.render(true)
      dirty = false persist()
      return true
    end
    return hooks.dragLeave and hooks.dragLeave(widget, dropped, mousePos) or false
  end
end

local function removeHooks()
  if hooks.resetWidget and not hooks.resetWidget:isDestroyed() then
    hooks.resetWidget.onClick = hooks.reset           -- nil if it had none, never `false`
    hooks.resetWidget, hooks.reset = nil, nil
  end
  if not hooks.installed then return end
  minimap.onMousePress, minimap.onDragEnter, minimap.onDragMove, minimap.onDragLeave =
    hooks.press, hooks.dragEnter, hooks.dragMove, hooks.dragLeave
  minimap.onMouseMove = hooks.move
  minimap.onMouseRelease = hooks.release
  if cursorGhost and not cursorGhost:isDestroyed() then cursorGhost:destroy() cursorGhost = nil end
  hooks.installed = false
end

function hookCentreButton()
  local reset = minimap:getChildById('resetWidget')
  if not reset or hooks.resetWidget == reset then return end
  hooks.reset = reset.onClick
  hooks.resetWidget = reset
  reset.onClick = function(widget)
    if hooks.reset then hooks.reset(widget) end
    local me = g_game.getLocalPlayer()
    local p = me and me:getPosition()
    if p then minimap:setCameraPosition(p) end    -- the stock button keeps the floor you were looking at
  end
end

-- ---------------------------------------------------------------- toolbar and panel
local modeButtons, brushButtons, weightButtons, typeButtons, spacingButtons = {}, {}, {}, {}, {}

local function tint(b, on, colour)
  b:setImageColor(on and (colour or '#55c957') or '#8a8a8a')
  b:setColor(on and '#ffffff' or '#c8c8c8')
end

local function paintButtons()
  for _, b in ipairs(modeButtons) do tint(b, b.mode == mode) end
  for _, b in ipairs(brushButtons) do tint(b, b.size == brush) end
  for _, b in ipairs(weightButtons) do tint(b, b.weight == paintWeight, b.colour) end
  for _, b in ipairs(typeButtons) do tint(b, b.type == placeType, b.colour) end
  for _, b in ipairs(spacingButtons) do tint(b, b.value == data.spacing) end
  if toolbar then
    toolbar.drawPanel:setVisible(mode == 'draw')
    toolbar.placePanel:setVisible(mode == 'place')
    toolbar.selectPanel:setVisible(mode == 'move')
    if toolbar.selectPanel then
      toolbar.selectPanel:setText('Drag to pan, wheel to zoom.\n'
        .. 'Click a waypoint to select it, drag it to move it, drop it on another to reorder.\n'
        .. 'Right click a waypoint for its menu, or an empty tile to add one.')
    end
  end
  if window and window.spacingEdit and window.spacingEdit:getText() ~= tostring(data.spacing) then
    window.spacingEdit:setText(tostring(data.spacing))
  end
end

function setMode(m)
  mode = m
  recording = (m == 'draw')
  if pickingFor then info('position pick cancelled') end
  pickingFor = nil
  closeMenus()
  suppressMap()
  paintButtons()
  if toolbar and not toolbar:isDestroyed() then
    toolbar:setHeight(TOOLBAR_HEIGHT[m] or 200)
  end
  if m == 'move' then info('plain map - drag to look around; waypoints can still be grabbed and dragged')
  elseif m == 'draw' then info('drag on the map to paint the area you hunt')
  elseif m == 'place' then
    local t = RouteTypes.get(placeType)
    info(('click the map to drop a %s waypoint - ctrl+click opens its editor right away'):format(t and t.title or placeType))
  end
end

function setPlaceType(id)
  placeType = id
  if mode ~= 'place' then setMode('place') else paintButtons() end
  local q = RouteTypes.quickGet(id)
  if q then
    info(('placing %s - a function waypoint with the job already written'):format(q.title))
    return
  end
  local t = RouteTypes.get(id)
  info(('placing %s: %s'):format(t.title, t.hint))
end

function buildToolbar()
  if toolbar and not toolbar:isDestroyed() then toolbar:destroy() end
  toolbar = g_ui.createWidget('RpToolbar', minimap)
  toolbar:addAnchor(AnchorTop, 'parent', AnchorTop)
  toolbar:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  toolbar:setMarginTop(30)        -- the map's own Center button sits at 4,4; do not cover it
  toolbar:setMarginLeft(6)
  markDirtyStack()

  modeButtons = {}
  for _, m in ipairs({ { 'move', 'Default' }, { 'draw', 'Draw' }, { 'place', 'Place' } }) do
    local b = g_ui.createWidget('RpSmall', toolbar.modeRow)
    b:setText(m[2])
    b.mode = m[1]
    b:setWidth(m[1] == 'move' and 74 or 70)
    b:setTooltip(m[1] == 'move' and 'The map as it always was - and you can still grab, drag and right click waypoints' or nil)
    b.onClick = function() setMode(m[1]) end
    modeButtons[#modeButtons + 1] = b
  end

  local panel = toolbar.toolPanel
  -- draw tools
  local draw = g_ui.createWidget('UIWidget', panel)
  draw:setId('drawPanel')
  draw:addAnchor(AnchorTop, 'parent', AnchorTop)
  draw:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  draw:addAnchor(AnchorRight, 'parent', AnchorRight)
  draw:setHeight(140)
  toolbar.drawPanel = draw
  local l1 = g_ui.createWidget('RpNote', draw)
  l1:setText('brush size')
  l1:addAnchor(AnchorTop, 'parent', AnchorTop)
  l1:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  l1:addAnchor(AnchorRight, 'parent', AnchorRight)
  brushButtons = {}
  local y = 16
  for i, size in ipairs(BRUSHES) do
    local b = g_ui.createWidget('RpSmall', draw)
    b:setText(size .. 'x' .. size)
    b:setWidth(40)
    b.size = size
    b:addAnchor(AnchorTop, 'parent', AnchorTop)
    b:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    b:setMarginTop(y)
    b:setMarginLeft((i - 1) * 43)
    b.onClick = function() brush = size paintButtons() end
    brushButtons[#brushButtons + 1] = b
  end
  local l2 = g_ui.createWidget('RpNote', draw)
  l2:setText('paint as')
  l2:addAnchor(AnchorTop, 'parent', AnchorTop)
  l2:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  l2:addAnchor(AnchorRight, 'parent', AnchorRight)
  l2:setMarginTop(42)
  weightButtons = {}
  for i, w in ipairs({ { 1, 'Normal', '#00e5ff' }, { 2, 'Hot', '#ff28be' },
                       { 3, 'No-go', '#ff3c3c' }, { 0, 'Erase', '#ff6666' } }) do
    local b = g_ui.createWidget('RpSmall', draw)
    b:setText(w[2])
    b:setWidth(52)
    b.weight = w[1]
    b.colour = w[3]
    b:addAnchor(AnchorTop, 'parent', AnchorTop)
    b:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    b:setMarginTop(58)
    b:setMarginLeft((i - 1) * 54)
    b.onClick = function() paintWeight = w[1] paintButtons() end
    weightButtons[#weightButtons + 1] = b
  end
  local prev = g_ui.createWidget('CheckBox', draw)
  prev:setText('preview waypoints while drawing')
  prev:addAnchor(AnchorTop, 'parent', AnchorTop)
  prev:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  prev:addAnchor(AnchorRight, 'parent', AnchorRight)
  prev:setMarginTop(80)
  prev:setHeight(16)
  prev:setChecked(data.livePreview and true or false)
  prev:setTooltip('Every few seconds, show where Generate would put waypoints. It does not change the route.')
  prev.onCheckChange = function(widget, checked)
    data.livePreview = checked
    persist()
    if checked then schedulePreview() end
  end

  local l3 = g_ui.createWidget('RpHint', draw)
  l3:setText('then press Generate goto')
  l3:addAnchor(AnchorTop, 'parent', AnchorTop)
  l3:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  l3:addAnchor(AnchorRight, 'parent', AnchorRight)
  l3:setMarginTop(100)

  -- place tools: one button per waypoint type, in the bot's own colours
  local place = g_ui.createWidget('UIWidget', panel)
  place:setId('placePanel')
  place:addAnchor(AnchorTop, 'parent', AnchorTop)
  place:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  place:addAnchor(AnchorRight, 'parent', AnchorRight)
  place:addAnchor(AnchorBottom, 'parent', AnchorBottom)
  toolbar.placePanel = place
  typeButtons = {}
  for i, t in ipairs(RouteTypes.placeable) do
    local b = g_ui.createWidget('RpTypeButton', place)
    b:setText(' ' .. t.glyph .. '   ' .. t.title)
    b:addAnchor(AnchorTop, 'parent', AnchorTop)
    b:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    b:addAnchor(AnchorRight, 'parent', AnchorRight)
    b:setMarginTop((i - 1) * 24)
    b.type = t.id
    b.colour = t.colour
    b:setTooltip(t.hint .. '   (ctrl+click the map to place it and open its editor right away)')
    b.onClick = function() suppressMap() setPlaceType(t.id) end
    typeButtons[#typeButtons + 1] = b
  end

  -- the one click block: a whole job per button, no editing needed to get going
  local head = g_ui.createWidget('RpNote', place)
  head:setText('one click jobs')
  head:addAnchor(AnchorTop, 'parent', AnchorTop)
  head:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  head:addAnchor(AnchorRight, 'parent', AnchorRight)
  head:setMarginTop(#RouteTypes.placeable * 24 + 4)
  for i, q in ipairs(RouteTypes.quick) do
    local b = g_ui.createWidget('RpTypeButton', place)
    b:setText(' ' .. q.glyph .. '   ' .. q.title)
    b:addAnchor(AnchorTop, 'parent', AnchorTop)
    b:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    b:addAnchor(AnchorRight, 'parent', AnchorRight)
    b:setMarginTop(#RouteTypes.placeable * 24 + 20 + (i - 1) * 24)
    b.type = q.id
    b.colour = q.colour
    b:setTooltip('Drops a function waypoint with this job already written in it')
    b.onClick = function() suppressMap() setPlaceType(q.id) end
    typeButtons[#typeButtons + 1] = b
  end

  -- placing at your own feet is how half of a route gets built: no hunting for the tile on the map
  local here = g_ui.createWidget('RpSmall', toolbar.actionRow)
  here:setText('At me')
  here:setWidth(70)
  here.onClick = function()
    suppressMap()
    local me = g_game.getLocalPlayer()
    local p = me and me:getPosition()
    if not p then return end
    addWaypoint(placeType, p, false)
  end
  here:setTooltip('Add a waypoint of the selected type at the tile you are standing on')

  local centre = g_ui.createWidget('RpSmall', toolbar.actionRow)
  centre:setText('Centre')
  centre:setWidth(70)
  centre:setTooltip('Centre the map on your character')
  centre.onClick = function()
    suppressMap()
    local me = g_game.getLocalPlayer()
    local p = me and me:getPosition()
    if not p then return end
    minimap:setCameraPosition(p)
    render(true)
    drawMarkers()
  end

  local hide = g_ui.createWidget('RpSmall', toolbar.actionRow)
  hide:setText('Hide')
  hide:setWidth(70)
  hide:setTooltip('Hide everything the editor draws and go back to the plain map')
  hide.onClick = function() suppressMap() setUiHidden(true) end

  local sel = g_ui.createWidget('RpHint', panel)
  sel:setId('selectPanel')
  sel:addAnchor(AnchorTop, 'parent', AnchorTop)
  sel:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  sel:addAnchor(AnchorRight, 'parent', AnchorRight)
  sel:setHeight(80)
  sel:setTextWrap(true)
  toolbar.selectPanel = sel

  -- Drag the toolbar by its title strip. The drag lives on the toolbar itself rather than on the title label:
  -- a Label does not take part in the drag system, which is why grabbing the title did nothing.
  toolbar:setDraggable(true)
  toolbar.onDragEnter = function(widget, mousePos)
    if mousePos.y - widget:getY() > 20 then return false end     -- only the title strip moves it
    widget.grabX, widget.grabY = mousePos.x - widget:getX(), mousePos.y - widget:getY()
    widget:breakAnchors()
    return true
  end
  toolbar.onDragMove = function(widget, mousePos)
    widget:setPosition({ x = mousePos.x - (widget.grabX or 0), y = mousePos.y - (widget.grabY or 0) })
    return true
  end
  toolbar.onDragLeave = function(widget)
    data.toolbarPos = { x = widget:getX(), y = widget:getY() }
    persist()
    suppressMap()
    return true
  end
  if data.toolbarPos then
    local reset = minimap:getChildById('resetWidget')
    local rx, ry = reset and reset:getX() or 0, reset and reset:getY() or 0
    local rw, rh = reset and reset:getWidth() or 0, reset and reset:getHeight() or 0
    local pos = data.toolbarPos
    -- a spot saved before this was fixed can still sit on the Center button: move it down once
    if reset and pos.x < rx + rw and pos.y < ry + rh and pos.x + toolbar:getWidth() > rx
       and pos.y + toolbar:getHeight() > ry then
      pos = { x = pos.x, y = ry + rh + 6 }
      data.toolbarPos = pos
      persist()
    end
    toolbar:breakAnchors()
    toolbar:setPosition(pos)
  end
  toolbar:setHeight(TOOLBAR_HEIGHT[mode] or 200)
end

local function buildPanel()
  local function small(parent, text, tip, fn, width)
    local b = g_ui.createWidget('RpSmall', parent)
    b:setText(text)
    if tip then b:setTooltip(tip) end
    if width then b:setWidth(width) end
    b.onClick = fn
    return b
  end

  -- A destructive button asks twice, and looks like it: the first press turns it red and says what the second
  -- press will do. It goes back to normal on its own after five seconds.
  local ARM_MS = 5000
  local function arm(parent, text, tip, prompt, action, width)
    local b = small(parent, text, tip, nil, width)
    b.baseText = text
    local function disarm()
      if b:isDestroyed() then return end
      b.armedAt = nil
      b:setText(b.baseText)
      b:setImageColor('#8a8a8a')
      b:setColor('#c8c8c8')
    end
    b.disarm = disarm
    b.onClick = function()
      suppressMap()
      if not b.armedAt then
        b.armedAt = now()
        b:setText('Sure?')
        b:setImageColor('#e03b3b')
        b:setColor('#ffffff')
        info(prompt .. ' - press again within 5 seconds')
        scheduleEvent(function()
          if b:isDestroyed() or not b.armedAt then return end
          if now() - b.armedAt >= ARM_MS - 50 then
            disarm()
            info('cancelled - nothing was changed')
          end
        end, ARM_MS)
        return
      end
      disarm()
      action()
    end
    return b
  end

  small(window.routeRow, 'Running', 'Load the route the cavebot is set to right now.', function()
    suppressMap()
    local name = botRouteName()
    if not name or name == '' then warn('the cavebot has no route selected') return end
    if name == routeName then info(('"%s" is already open'):format(name)) return end
    loadRoute(name)
  end, 70)
  small(window.routeRow, 'Load', 'Pick one of this preset\'s cavebot routes and edit it here.', function()
    local names, cfg = listRoutes()
    if #names == 0 then info(cfg and ('no routes saved in ' .. cfg) or 'no bot config selected') return end
    closeMenus()
    local menu = g_ui.createWidget('RpMenu', g_ui.getRootWidget())
    menu:setWidth(240)
    for _, name in ipairs(names) do
      local b = g_ui.createWidget('RpMenuRow', menu)
      b:setText(name)
      b.onClick = function() closeMenus() loadRoute(name) end
    end
    menu:setPosition({ x = window:getX() + 10, y = window:getY() + 60 })
    openPopup(menu)
  end, 60)
  local saveArmed, saveArmedName = 0, nil
  small(window.routeRow, 'Save', 'Write this route to the name in the box. Overwrites an existing route of that name, and keeps its cavebot settings and extensions.',
    function()
      local name = window.nameEdit:getText()
      local dir = routeDir()
      local exists = dir and name ~= '' and g_resources.fileExists(dir .. '/' .. name .. '.cfg')
      if exists and name ~= routeName and not (saveArmedName == name and g_clock.millis() - saveArmed < 3000) then
        saveArmed, saveArmedName = g_clock.millis(), name
        warn(('"%s" already exists and is not the route you loaded - press Save again to overwrite it'):format(name))
        return
      end
      saveArmed, saveArmedName = 0, nil
      saveRoute(name)
    end, 60)
  small(window.routeRow, 'Save as', 'Save under a new name. It refuses if a route of that name already exists, so nothing is overwritten by accident.',
    function()
      local name = window.nameEdit:getText()
      local dir = routeDir()
      if not dir then warn('no bot config selected') return end
      if name == '' then warn('type a name for the new route first') return end
      if g_resources.fileExists(dir .. '/' .. name .. '.cfg') then
        warn(('"%s" already exists - change the name, or press Save to overwrite it'):format(name))
        return
      end
      routeTail, tailFrom = {}, name
      saveRoute(name)
    end, 76)
  local newArmed = 0
  arm(window.routeRow, 'New', 'Start an empty route.', 'this throws away every waypoint and the drawing you have open',
      function() newRoute() end, 56)

  spacingButtons = {}
  for _, n in ipairs(SPACINGS) do
    local b = small(window.spacingRow, tostring(n), 'One waypoint per ' .. n .. ' squares', function()
      data.spacing = n paintButtons() persist()
    end, 40)
    b.value = n
    spacingButtons[#spacingButtons + 1] = b
  end
  local edit = g_ui.createWidget('TextEdit', window.spacingRow)
  edit:setId('spacingEdit')
  edit:setWidth(60)
  edit:setText(tostring(data.spacing))
  edit:setTooltip('One waypoint per N squares - type any number from 1 to 100')
  edit.onTextChange = function(widget, text)
    local n = tonumber(text)
    if n and n >= MIN_SPACING and n <= MAX_SPACING and math.floor(n) ~= data.spacing then
      data.spacing = math.floor(n)
      paintButtons()
      persist()
    end
  end
  window.spacingEdit = edit

  small(window.genRow, 'Generate goto', 'Turn the painted area into goto waypoints on this floor.',
    function() suppressMap() generateGotos() end, 110)
  small(window.genRow, 'Recipes', 'Insert a whole block of waypoints: a depot trip, a supply check, a hunting loop.',
    function()
      closeMenus()
      suppressMap()
      local menu = g_ui.createWidget('RpMenu', g_ui.getRootWidget())
      openMenu = menu
      menu:setWidth(330)
      for _, recipe in ipairs(RouteTypes.recipes) do
        local row = g_ui.createWidget('RpMenuRow', menu)
        row:setText(recipe.title)
        row.onClick = function()
          closeMenus()
          pushUndo('inserting ' .. recipe.title)
          local at = (selected or #route) + 1
          local me = g_game.getLocalPlayer()
          local here = (me and me:getPosition()) or { x = 0, y = 0, z = viewedFloor() }
          local placed, quicks = 0, 0
          for _, e in ipairs(recipe.entries) do
            local action, value = e.action, e.value
            if e.quick then
              local q = RouteTypes.quickGet(e.quick)
              action, value = 'function', RouteTypes.quickBody(q, here)
              quicks = quicks + 1
            end
            if e.first then
              insertAt(1, action, value, true)
              at = at + 1
            else
              insertAt(at + placed, action, value, true)
              placed = placed + 1
            end
          end
          selected = at
          routeVersion = routeVersion + 1
          drawMarkers()
          refreshSeq()
          info(('inserted "%s" - %d waypoints%s'):format(recipe.title, #recipe.entries,
            quicks > 0 and '; the depot and shop jobs sit where you stand - drag them to the depot and the npc, then Save' or ''))
        end
      end
      menu:setPosition({ x = window:getX() + 10, y = window:getY() + 150 })
      openPopup(menu)
    end, 74)
  -- start and stop the cavebot without leaving the map: the same switch as the one on the bot panel
  local botSwitch = small(window.routeRow, 'Bot: ?', 'Turn the cavebot on or off while you edit.', function()
    local ctx = botContext()
    local cave = ctx and ctx.CaveBot
    if not cave or type(cave.isOn) ~= 'function' then warn('the bot is not running') return end
    if cave.isOn() then
      cave.setOff()
      info('cavebot off')
    else
      -- Bot: on next to Save means "run what I am looking at", so the cavebot is pointed at this route first
      local dir = routeDir()
      local onDisk = dir and routeName ~= '' and g_resources.fileExists(dir .. '/' .. routeName .. '.cfg')
      if routeName == '' or not onDisk then
        warn(('this route is not saved yet - Save it, then Bot: on will run it (the bot is set to "%s")')
          :format(tostring(botRouteName())))
        return
      end
      if botRouteName() ~= routeName then
        if selectBotRoute(routeName) then
          info(('cavebot switched to "%s" and started'):format(routeName))
        else
          warn(('could not point the cavebot at "%s" - it will run "%s"'):format(routeName, tostring(botRouteName())))
        end
      else
        info(('cavebot on - running "%s"'):format(routeName))
      end
      cave.setOn()
    end
    refreshBotSwitch()
  end, 62)
  window.botSwitch = botSwitch
  refreshBotSwitch()

  small(window.genRow, 'Supplies', 'What to keep in the backpack, and the item names your scripts can use.',
    function() suppressMap() openSupplyWindow() end, 84)
  small(window.genRow, 'Loot', 'Which items the Deposit loot job puts away and the Sell loot job sells.',
    function() suppressMap() openLootWindow() end, 60)
  arm(window.clearRow, 'Clear waypoints', 'Remove every waypoint but keep the route name, the drawing and the cavebot settings.',
      'this removes every waypoint in the route', function()
    if #route == 0 then warn('there are no waypoints to clear') return end
    pushUndo('clearing every waypoint')
    local had = #route
    route = {}
    selected = nil
    routeVersion = routeVersion + 1
    drawMarkers()
    refreshSeq()
    refreshLegend()
    info(('cleared %d waypoints - the name, the drawing and the cavebot settings are still here'):format(had))
  end, 130)
  arm(window.clearRow, 'Clear drawing', 'Remove the painted area on this floor. Waypoints are untouched.',
      'this wipes the drawing on this floor', function()
    local m = maskFor(routeName, false)
    local z = viewedFloor()
    local had = m and layerCount(m.floors[tostring(z)]) or 0
    if m then m.floors[tostring(z)] = nil end
    layerVersion = layerVersion + 1
    persist()
    render(true)
    if had > 0 then
      info(('cleared %d painted tiles on floor %d'):format(had, z))
    else
      local others = {}
      for key, layer in pairs(m and m.floors or {}) do
        local n = layerCount(layer)
        if n > 0 then others[#others + 1] = ('floor %s: %d'):format(key, n) end
      end
      table.sort(others)
      warn(('nothing drawn on floor %d%s'):format(z, #others > 0 and (' - the drawing is on ' .. table.concat(others, ', ') .. '; switch the map there to clear it') or ''))
    end
  end, 120)

  small(window.seqTools, 'Edit', 'Edit the selected waypoint.', function()
    if selected then openEditor(selected) else info('select a waypoint first') end
  end, 56)
  small(window.seqTools, 'Up', 'Move the selected waypoint earlier in the route (its label and jump move with it).', function()
    if not selected then warn('select a waypoint first') return end
    local prev = visibleNeighbour(selected, -1)
    if not prev then return end
    pushUndo('moving a waypoint up')
    local at = moveBlock(selected, prev)
    routeVersion = routeVersion + 1
    selectIndex(at)
  end, 46)
  small(window.seqTools, 'Down', 'Move the selected waypoint later in the route (its label and jump move with it).', function()
    if not selected then warn('select a waypoint first') return end
    local nxt = visibleNeighbour(selected, 1)
    if not nxt then return end
    pushUndo('moving a waypoint down')
    local at = moveBlock(selected, nxt)
    routeVersion = routeVersion + 1
    selectIndex(at)
  end, 56)
  small(window.seqTools, 'Loop end', 'Make the selected Go to the last one of its block: the gotos are rotated, their order is kept. Put the Refill check after it.',
    function() if selected then makeLoopEnd(selected) else warn('select a waypoint first') end end, 70)
  small(window.seqTools, 'Remove', 'Remove the selected waypoint.', function()
    if not selected then info('select a waypoint first') return end
    if selected then
      pushUndo('removing a waypoint')
      table.remove(route, selected)
      if selected > #route then selected = #route end
      routeVersion = routeVersion + 1
      drawMarkers() refreshSeq()
    end
  end, 74)
  small(window.seqTools, 'Undo', 'Undo the last change to this route (up to ten).', function() undo() end, 56)
  small(window.seqTools, 'Centre', 'Centre the map on the selected waypoint.', function()
    if not selected then info('select a waypoint first') return end
    local entry = route[selected]
    local p = entry and RouteTypes.positionOf(entry)
    if not p then info('that waypoint has no position - it runs in order') return end
    minimap:setCameraPosition(p)
    render(true)
    drawMarkers()
  end, 74)

  local auto = g_ui.createWidget('CheckBox', window.optRow)
  auto:setText('open the route the bot is running when the client starts')
  auto:addAnchor(AnchorTop, 'parent', AnchorTop)
  auto:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  auto:addAnchor(AnchorRight, 'parent', AnchorRight)
  auto:setHeight(16)
  auto:setChecked(data.autoLoad and true or false)
  auto.onCheckChange = function(widget, checked)
    data.autoLoad = checked
    data.autoLoadChosen = true
    persist()
    info(checked and 'the editor will open with this route next time' or 'the editor will start empty next time')
  end
  window.autoBox = auto
  -- the small minimap is for playing; the route is drawn there only when asked
  local mini = g_ui.createWidget('CheckBox', window.optRow)
  mini:setText('also draw the route on the small minimap (off: full map only)')
  mini:addAnchor(AnchorTop, 'parent', AnchorTop)
  mini:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  mini:addAnchor(AnchorRight, 'parent', AnchorRight)
  mini:setMarginTop(18)
  mini:setHeight(16)
  mini:setChecked(data.showOnMinimap and true or false)
  mini.onCheckChange = function(widget, checked)
    data.showOnMinimap = checked
    persist()
    render(true)
    drawMarkers()
  end
  window.miniBox = mini

  -- the editor opens on an empty route: the name box is only filled in once something is loaded
  window.nameEdit:setText(data.autoLoad and (data.lastRoute or '') or '')
  routeName = data.autoLoad and (data.lastRoute or '') or ''
end

-- ---------------------------------------------------------------- window plumbing
local showWindow, hideWindow

function showWindow(arm)
  if not window then return end
  window:show()
  window:raise()
  window:focus()
  if button then button:setOn(true) end
  if toolbar then
    toolbar:show()
    markDirtyStack()
    if data.toolbarPos then
      toolbar:breakAnchors()
      toolbar:setPosition(data.toolbarPos)
    end
  end
  -- the map always opens in Default: no drawing, no placing until you pick a tool
  setMode('move')
  render(true)
  drawMarkers()
  refreshSeq()
end

-- the value, supply and loot windows float free of the map, so closing the map has to take them too
local function closeFloatingWindows()
  local root = g_ui.getRootWidget()
  for _, id in ipairs({ 'rpValueWindow', 'rpSupplyWindow', 'rpLootWindow' }) do
    while true do
      local wnd = root:recursiveGetChildById(id)
      if not wnd then break end
      wnd:destroy()
    end
  end
end

function hideWindow()
  if window then window:hide() end
  if toolbar then toolbar:hide() end
  if mapLegend and not mapLegend:isDestroyed() then mapLegend:hide() end
  if cursorGhost and not cursorGhost:isDestroyed() then cursorGhost:hide() end
  closeMenus()
  closeFloatingWindows()
  if button then button:setOn(false) end
  recording = false
  pickingFor = nil
end

function hide()
  closeMenus()
  hideWindow()
  if modules.game_minimap.fullmapView then modules.game_minimap.toggleFullMap() end
end

-- Everything we draw goes away and the plain map comes back. The small Waypoints button stays, and brings
-- it all back exactly as it was.
function setUiHidden(hidden)
  uiHidden = hidden and true or false
  data.uiHidden = uiHidden
  persist()
  closeMenus()
  closeFloatingWindows()
  if uiHidden then
    if window then window:hide() end
    if toolbar then toolbar:hide() end
    for _, m in ipairs(markers) do if not m:isDestroyed() then m:hide() end end
    for _, c in ipairs(chips) do if not c:isDestroyed() then c:hide() end end
    if overlay and not overlay:isDestroyed() then overlay:hide() end
    if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:hide() end
    if mapLegend and not mapLegend:isDestroyed() then mapLegend:hide() end
    if cursorGhost and not cursorGhost:isDestroyed() then cursorGhost:hide() end
    if mapButton then mapButton:show() mapButton:raise() end
    info('editor hidden - press Waypoints to bring it back')
  else
    if window then window:show() window:raise() end
    if toolbar then toolbar:show() end
    render(true)
    drawMarkers()
    refreshSeq()
  end
end

function show(arm, name)
  pendingArm = (arm ~= false)
  if not modules.game_minimap.fullmapView then modules.game_minimap.toggleFullMap() end
  showWindow(pendingArm)
  if name and name ~= '' and name ~= routeName then loadRoute(name) end
end

function toggle()
  if window and window:isVisible() then hide() else show(true) end
end

local function closeFullMap()
  if modules.game_minimap.fullmapView then modules.game_minimap.toggleFullMap() end
end

local escBound = false
local function syncFullmap()
  local full = modules.game_minimap.fullmapView
  if full ~= lastFullmap then
    lastFullmap = full
    if closeButton then closeButton:setVisible(full) end
    -- while the editor is hidden the small button is the only way back, so it stays on the full map too
    if mapButton then mapButton:setVisible(not full or uiHidden) end
    if full then
      if not uiHidden then showWindow(pendingArm) end
      pendingArm = false
      if not escBound then g_keyboard.bindKeyDown('Escape', closeFullMap) escBound = true end
    else
      hideWindow()
      if escBound then g_keyboard.unbindKeyDown('Escape', closeFullMap) escBound = false end
    end
    render(true)
    drawMarkers()
  end
  local scale, floor = minimap:getScale(), viewedFloor()
  if scale ~= lastScale or floor ~= lastFloor then
    local floorChanged = floor ~= lastFloor
    lastScale, lastFloor = scale, floor
    render()
    drawMarkers()
    if lineOverlay and not lineOverlay:isDestroyed() and lineBox then
      if floorChanged then
        -- the image on screen belongs to the floor we just left; a big route takes seconds to encode, so
        -- showing the old one meanwhile draws another floor's route over this one
        lineOverlay:hide()
      else
        -- a zoom only: the line images are built in tile space, rescale rather than encode again
        minimap:centerInPosition(lineOverlay, lineBox)
        lineOverlay:resize(screenSize(lineBox.cols), screenSize(lineBox.rows))
      end
    end
  end
  if dirty and now() - lastPersist > 5000 then
    dirty = false
    lastPersist = now()
    persist()
  end
  if window and window:isVisible() then refreshLive() refreshBotSwitch() raiseMapControls() end
  -- never leave a full screen click catcher behind: it would make the whole client unclickable
  local sheets, menus = 0, 0
  for _, c in ipairs(g_ui.getRootWidget():getChildren()) do
    local id = c:getId()
    if id == 'rpMenuBackdrop' then sheets = sheets + 1 end
    if id == 'rpMenu' then menus = menus + 1 end
  end
  if sheets > 0 and (menus == 0 or sheets > menus) then closeMenus() end
  syncEvent = scheduleEvent(syncFullmap, 300)
end

-- ---------------------------------------------------------------- module lifecycle
-- a load that failed halfway leaves widgets on screen whose handlers point at the dead instance: clicking
-- one of those is an error with no explanation, so every id we own is swept before building anything
function sweepOrphans()
  local root = g_ui.getRootWidget()
  for _, id in ipairs({ 'rpEditorWindow', 'rpToolbar', 'rpValueWindow', 'rpMenu', 'rpMenuBackdrop',
                        'rpSupplyWindow', 'rpLootWindow', 'rpOpen', 'rpCloseMap',
                        'routePaintWindow', 'routePaintPicker', 'routePaintOpen', 'routePaintClose' }) do
    while true do
      local w = root:recursiveGetChildById(id)
      if not w then break end
      w:destroy()
    end
  end
  local mm = modules.game_minimap.minimapWidget
  for _, c in ipairs(mm:getChildren()) do
    local id = c:getId()
    if id == 'rpMarker' or id == 'rpPaint' or id == 'rpLine' or id == 'rpWet' or id == 'rpLive'
       or id == 'rpLegend' or id == 'rpCursor'
       or id == 'rpOpen' or id == 'rpCloseMap' or id == 'rpToolbar'
       or id == 'routePaintPin' or id == 'routePaintOverlay' or id == 'routePaintLine'
       or id == 'routePaintWet' or id == 'routePaintOpen' or id == 'routePaintClose' then
      c:destroy()
    end
  end
end

local function setup()
  load()
  sweepOrphans()
  pcall(function() g_resources.makeDir(DIR) end)
  -- the generated images are disposable; a reload loses track of the old ones, so the folder is cleared
  pcall(function()
    for _, file in ipairs(g_resources.listDirectoryFiles(DIR) or {}) do
      if tostring(file):match('%.png$') then g_resources.deleteFile(DIR .. '/' .. file) end
    end
  end)
  minimap = modules.game_minimap.minimapWidget

  window = g_ui.displayUI('editor')
  window:breakAnchors()
  if data.windowPos and data.windowPos.x then
    window:setPosition(data.windowPos)
  else
    window:addAnchor(AnchorTop, 'parent', AnchorTop)
    window:addAnchor(AnchorRight, 'parent', AnchorRight)
    window:setMarginTop(40)
    window:setMarginRight(12)
  end
  -- a MainWindow is dragged by its title bar; remember where the user leaves it
  window.onGeometryChange = function(widget)
    if widget:isVisible() then
      data.windowPos = { x = widget:getX(), y = widget:getY() }
      dirty = true
    end
  end
  window:hide()

  buildPanel()
  buildToolbar()
  if toolbar then toolbar:hide() end
  paintButtons()

  closeButton = g_ui.createWidget('RpButton', minimap)
  closeButton:setId('rpCloseMap')
  closeButton:setText('Close map')
  closeButton:setWidth(86)
  closeButton:addAnchor(AnchorTop, 'parent', AnchorTop)
  closeButton:addAnchor(AnchorRight, 'parent', AnchorRight)
  closeButton:setMarginTop(34)          -- below the position hud, which owns this corner
  closeButton:setMarginRight(6)
  closeButton.onClick = closeFullMap
  closeButton:hide()

  mapButton = g_ui.createWidget('RpButton', minimap)
  mapButton:setId('rpOpen')
  mapButton:setText('Waypoints')
  mapButton:setWidth(78)
  mapButton:setHeight(18)
  mapButton:addAnchor(AnchorBottom, 'parent', AnchorBottom)
  mapButton:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  mapButton:setMarginBottom(4)
  mapButton:setMarginLeft(4)
  mapButton.onClick = function()
    suppressMap()
    if uiHidden then setUiHidden(false) else show(true) end
  end

  button = modules.client_topmenu.addRightGameToggleButton('routePaintButton', tr('Waypoint editor'),
                                                           '/images/topbuttons/minimap', toggle, false, 1007)
  -- a relog rebuilds the game interface: drop what we drew, then pick the minimap up again and redraw
  gameHandlers = {
    onGameEnd = function()
      pcall(clearMarkers)
      lastFullmap = nil          -- so the watcher shows the editor again after the next login
      if overlay and not overlay:isDestroyed() then overlay:hide() end
      if lineOverlay and not lineOverlay:isDestroyed() then lineOverlay:hide() end
      hideWindow()
    end,
    onGameStart = function()
      scheduleEvent(function()
        local mm = modules.game_minimap.minimapWidget
        if mm and mm ~= minimap then
          minimap = mm
          hooks.installed = false
          hooks.reset, hooks.resetWidget = nil, nil
          overlay, lineOverlay = nil, nil
          markers = {}
          pcall(sweepOrphans)
          pcall(buildToolbar)
          pcall(installHooks)
          pcall(hookCentreButton)
        end
        renderKeyCache = nil
        pcall(function() render(true) end)
        pcall(drawMarkers)
      end, 1500)
    end,
  }
  gameHandlers.onOpenNpcTrade = function(items)
    local learn = {}
    for _, item in ipairs(items or {}) do
      if item.ptr then learn[#learn + 1] = { id = item.ptr:getId(), name = item.name } end
    end
    local added = RouteItems.learnFromTrade(learn)
    if added > 0 then info(('learned %d item names from this shop'):format(added)) end
  end
  connect(g_game, gameHandlers)

  installHooks()
  hookCentreButton()
  -- bound to the editor window, not to the root: a bare Delete bound globally also fires while you are
  -- typing in a text box, and would remove the selected waypoint mid-word
  keyHandlers.escape = function()
    closeMenus()
    if window and window:isVisible() and mode ~= 'move' then setMode('move') end
  end
  keyHandlers.del = function()
    if window and window:isVisible() and selected then removeWaypoint(selected) end
  end
  keyHandlers.undo = function()
    if window and window:isVisible() then undo() end
  end
  g_keyboard.bindKeyDown('Escape', keyHandlers.escape)
  g_keyboard.bindKeyDown('Delete', keyHandlers.del, window)
  g_keyboard.bindKeyDown('Ctrl+Z', keyHandlers.undo, window)
  syncFullmap()
  -- On a cold start the bot window can be built after this module, so routeDir() is nil for a moment. Giving
  -- up there leaves the editor showing the route's name and drawing with an empty waypoint list, and a
  -- Generate plus Save on top of that would wipe the real route. Keep asking until the bot is there.
  local function restoreLastRoute(tries)
    if not data.autoLoad then return end          -- untick the box and the editor starts empty
    -- the bot's route first, the last one edited as a fallback
    local dir = routeDir()
    local want = botRouteName()
    if not want or want == '' then want = data.lastRoute end
    if dir and want and want ~= '' and g_resources.fileExists(dir .. '/' .. want .. '.cfg') then
      loadRoute(want)
      return
    end
    if tries < 10 then scheduleEvent(function() restoreLastRoute(tries + 1) end, 500) end
  end
  restoreLastRoute(0)
  if data.uiHidden then setUiHidden(true) end
  render(true)
end

function init()
  -- routes saved before the rename still call modules.game_route_paint from their function waypoints
  pcall(function() modules.game_route_paint = modules.game_waypoint_editor or getfenv(1) end)
  local ok, err = pcall(setup)
  pcall(function() RouteDepot.setHuntSweep(RouteLoot.bags().sweep) end)
  if not ok then
    -- autoload runs this at boot: an error thrown here would stop the client from starting at all
    g_logger.error('game_waypoint_editor: ' .. tostring(err))
    pcall(terminate)
  end
end

function terminate()
  pcall(function() if modules.game_route_paint == (modules.game_waypoint_editor or getfenv(1)) then modules.game_route_paint = nil end end)
  pcall(function() RouteDepot.setHuntSweep(false) end)
  pcall(removeHooks)
  if syncEvent then removeEvent(syncEvent) end
  if renderEvent then removeEvent(renderEvent) end
  -- a pending line redraw or preview would fire against a dead module
  if lineEvent then removeEvent(lineEvent) lineEvent = nil end
  if previewEvent then removeEvent(previewEvent) previewEvent = nil end
  if escBound then pcall(function() g_keyboard.unbindKeyDown('Escape', closeFullMap) end) escBound = false end
  if data then pcall(persist) end
  pcall(clearMarkers)
  for _, w in ipairs({ overlay, lineOverlay, mapLegend, cursorGhost,
                       toolbar, closeButton, mapButton, button, window }) do
    if w and not w:isDestroyed() then w:destroy() end
  end
  overlay, lineOverlay = nil, nil
  toolbar, closeButton, mapButton, button, window = nil, nil, nil, nil, nil
  pcall(sweepOrphans)
  local root = g_ui.getRootWidget()
  for _, id in ipairs({ 'rpMenu', 'rpValueWindow', 'rpMenuBackdrop', 'rpSupplyWindow', 'rpLootWindow' }) do
    while true do
      local w = root:recursiveGetChildById(id)
      if not w then break end
      w:destroy()
    end
  end
end

-- ---------------------------------------------------------------- test surface
-- everything the bridge needs to drive this module without a mouse
function _state()
  return { mode = mode, placeType = placeType, brush = brush, weight = paintWeight, spacing = data.spacing,
           routeName = routeName, count = #route, selected = selected, markers = #markers, chips = #chips,
           uiHidden = uiHidden, autoLoad = data.autoLoad, liveIndex = liveIndex,
           layerVersion = layerVersion, routeVersion = routeVersion }
end
function _route() return route end
function _tail() return routeTail end
function _paintAt(pos) paintAround(pos) end
function _depot() return RouteDepot end
function _setUiHidden(v) setUiHidden(v) end
function _showMenu(pos, index) return showMenu(pos, index) end
function _closeMenus() closeMenus() end
function _setMode(m) setMode(m) end
function _refreshLive() refreshLive() end
function _clearMask(name)
  local key = name or routeName
  if key == '' then key = '(unnamed)' end
  data.masks[key] = nil
  layerVersion = layerVersion + 1
  extentCache, tilesCache = {}, {}
end
function _fillArea(x0, y0, x1, y1, z, weight)
  local layer = layerFor(z, true)
  for x = x0, x1 do
    for y = y0, y1 do
      local key = x .. ',' .. y
      if not layer.tiles[key] then layer.order[#layer.order + 1] = key end
      layer.tiles[key] = weight or 1
    end
  end
  layerVersion = layerVersion + 1
  return (x1 - x0 + 1) * (y1 - y0 + 1)
end
function _refreshSeq() refreshSeq() end
function _selectIndex(i) selectIndex(i) end
function _openEditor(i) return openEditor(i) end
function _templates() return RouteTypes.templates end
function _recipes() return RouteTypes.recipes end
function _types() return RouteTypes.list end
function _setName(name) routeName = name if window then window.nameEdit:setText(name) end end
function _setRoute(list) route = list routeVersion = routeVersion + 1 drawMarkers() refreshSeq() end

-- A self test that can be run at any time from the console:
--   modules.game_waypoint_editor.selftest()
-- It works on a throwaway route, touches nothing of yours, and reports what it checked.
-- The bot keeps its function scope private (G.botContext only exists while the executor is built), so the
-- only way to audit against the live preset is the executor's own upvalue.
function botContext()
  if not debug or not debug.getupvalue then return nil end
  local function upvalue(fn, want)
    local i = 1
    while true do
      local name, value = debug.getupvalue(fn, i)
      if not name then return nil end
      if name == want then return value end
      i = i + 1
    end
  end
  local executor
  for _, v in pairs(modules.game_bot or {}) do
    if type(v) == 'function' then
      local found = upvalue(v, 'botExecutor')
      if found then executor = found break end
    end
  end
  if not executor or type(executor.script) ~= 'function' then return nil end
  local ctx = upvalue(executor.script, 'context')
  if not ctx then return nil end
  local extensions = {}
  local cave = ctx.CaveBot
  if cave and cave.Extensions then
    for name in pairs(cave.Extensions) do extensions[name] = true end
  end
  return ctx, extensions
end

function selftest()
  local report, failures = {}, 0
  local restore
  local function check(name, ok, detail)
    if not ok then failures = failures + 1 end
    report[#report + 1] = ('%s %-44s %s'):format(ok and '  ok ' or 'FAIL', name, detail or '')
  end

  local savedRoute, savedTail, savedName = route, routeTail, routeName
  restore = function()
    data.masks['__selftest'] = nil
    route, routeTail, routeName = savedRoute, savedTail, savedName
    layerVersion = layerVersion + 1
    selected = nil
    pcall(drawMarkers)
    pcall(refreshSeq)
    pcall(function() render(true) end)
  end
  local me = g_game.getLocalPlayer()
  local pos = (me and me:getPosition()) or { x = 1000, y = 1000, z = 7 }
  -- work on the floor the map is showing, not the one the character stands on: the drawing, the markers and
  -- the chips all live on the viewed floor, so a test that mixes the two fails for no real reason
  pos = { x = pos.x, y = pos.y, z = viewedFloor() }

  -- the type registry matches what the cavebot itself registers
  check('waypoint types registered', #RouteTypes.list == 8, #RouteTypes.list .. ' types')

  -- every type can be placed and produces a value the cavebot can read back
  route, routeTail, routeName = {}, {}, '__selftest'
  for _, t in ipairs(RouteTypes.list) do
    addWaypoint(t.id, pos, false)
  end
  check('every type places', #route == 8, #route .. ' waypoints')
  local spatial = 0
  for _, entry in ipairs(route) do
    if RouteTypes.positionOf(entry) then spatial = spatial + 1 end
  end
  check('spatial types carry a position', spatial == 3, spatial .. ' of goto, use, usewith')

  -- writing and reading the cavebot format is lossless, including multiline values
  route[#route + 1] = { action = 'function', value = 'local a = 1\nreturn true' }
  local text = RouteCfg.serialise(RouteCfg.join(route, { { action = 'config', value = '{"a":1}' } }))
  local back = RouteCfg.parse(text)
  local actions, tail = RouteCfg.split(back)
  check('config round trip', #actions == #route and #tail == 1,
        ('%d actions, %d tail'):format(#actions, #tail))
  local sameValues = true
  for i, entry in ipairs(route) do
    if actions[i].action ~= entry.action or actions[i].value ~= entry.value then sameValues = false end
  end
  check('values survive the round trip', sameValues)

  -- generating from a drawing produces goto waypoints only, and leaves the rest alone
  local before = #route
  local layer = layerFor(pos.z, true)
  for x = pos.x - 6, pos.x + 6 do
    for y = pos.y - 6, pos.y + 6 do layer.tiles[x .. ',' .. y] = 1 end
  end
  layerVersion = layerVersion + 1
  local made = generateGotos()
  local nonGoto = 0
  for _, entry in ipairs(route) do
    if entry.action ~= 'goto' then nonGoto = nonGoto + 1 end
  end
  check('generate makes goto waypoints', made > 0, made .. ' from a 13x13 area')
  check('generate keeps hand placed waypoints', nonGoto == before - 1,
        ('%d non goto kept'):format(nonGoto))

  -- waypoints land on ground
  local offGround = 0
  for _, entry in ipairs(route) do
    local p = RouteTypes.positionOf(entry)
    if entry.action == 'goto' and p and not walkable(p.x, p.y, p.z) then offGround = offGround + 1 end
  end
  check('generated waypoints are walkable', offGround == 0, offGround .. ' on blocked tiles')

  -- drawing and markers
  local t0 = g_clock.micros()
  render(true)
  local renderMs = (g_clock.micros() - t0) / 1000
  check('drawing renders', renderMs < 60, ('%.1f ms'):format(renderMs))
  t0 = g_clock.micros()
  drawMarkers()
  local markerMs = (g_clock.micros() - t0) / 1000
  check('markers redraw', markerMs < 30, ('%.1f ms for %d'):format(markerMs, #markers))

  -- every type has to draw something on the map: a marker if it has a position, a chip if it does not
  route, routeTail, routeName = {}, {}, '__selftest'
  for i, ty in ipairs(RouteTypes.list) do
    addWaypoint(ty.id, { x = pos.x + i, y = pos.y, z = pos.z }, false)
  end
  drawMarkers()
  local drawn = 0
  for _, m in ipairs(markers) do if not m:isDestroyed() and m:isVisible() then drawn = drawn + 1 end end
  for _, c in ipairs(chips) do if not c:isDestroyed() and c:isVisible() then drawn = drawn + 1 end end
  check('every placeable type draws on the map', drawn == #RouteTypes.placeable,
        ('%d of %d types drawn'):format(drawn, #RouteTypes.placeable))

  -- the waypoints that carry no position still show on the map, hanging off the one before them
  route, routeTail, routeName = {}, {}, '__selftest'
  addWaypoint('goto', pos, false)
  addWaypoint('label', pos, false)
  addWaypoint('say', pos, false)
  addWaypoint('goto', { x = pos.x + 3, y = pos.y, z = pos.z }, false)
  drawMarkers()
  local chipCount = 0
  for _, c in ipairs(chips) do if not c:isDestroyed() and c:isVisible() then chipCount = chipCount + 1 end end
  check('flat waypoints get a chip', chipCount >= 2, chipCount .. ' chips for 2 flat waypoints')

  -- dropping a waypoint onto another one reorders the route
  local firstAction = route[1].action
  reorderWaypoint(1, 3)
  check('reorder moves a waypoint', route[3].action == firstAction and #route == 4,
        ('%s is now at 3, %d waypoints'):format(route[3].action, #route))

  -- a style that changes on hover has to say what it goes back to, or the highlight sticks - this has
  -- slipped through ten times by hand, so the file is checked, not the reviewer
  local stuck = {}
  for _, name in ipairs({ 'RpSmall', 'RpTypeButton', 'RpMenuRow', 'RpSeqRow', 'RpItemLine', 'RpMarker', 'RpChip',
                          'RpLegendLine', 'RpSupplyRow', 'RpLootRow', 'RpHeader', 'RpNote', 'RpHint' }) do
    local st = g_ui.getStyle(name)
    if st and st['$hover'] and not st['$!hover'] then stuck[#stuck + 1] = name end
  end
  check('every hover style reverts', #stuck == 0, #stuck == 0 and 'all have $!hover' or table.concat(stuck, ' '))

  -- every template and recipe only calls functions the running bot actually has
  local ctx, extensions = botContext()
  if ctx then
    local unknown = RouteTypes.auditApi(ctx, extensions)
    local detail = #unknown == 0 and 'all calls resolve'
      or (unknown[1].name .. ' in ' .. unknown[1].where .. (#unknown > 1 and (' (+%d more)'):format(#unknown - 1) or ''))
    check('templates call real bot functions', #unknown == 0, detail)
  else
    check('templates call real bot functions', true, 'skipped - bot not running')
  end

  restore()

  local summary = ('%s - %d checks, %d failed'):format(failures == 0 and 'PASS' or 'FAIL', #report, failures)
  table.insert(report, 1, summary)
  local text2 = table.concat(report, '\n')
  pcall(function() g_resources.writeFileContents('/waypoint_editor_selftest.txt', text2) end)
  info(summary .. ' (written to userdata/waypoint_editor_selftest.txt)')
  return text2
end
