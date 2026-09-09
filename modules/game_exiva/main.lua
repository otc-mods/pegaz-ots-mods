-- Exiva overlay: turns "X is far to the north-east." replies into a highlighted area on the minimap.
-- One reply = a ring sector (TFS distance band x 45 degree direction). Replies about the same player are
-- intersected, masked to explored minimap tiles of the viewed floor and drawn as one tinted blob whose
-- outline shows the raw geometry. Casts expire after CAST_TTL; a reply that contradicts older ones drops them.
-- Console: modules.game_exiva.clearAll(), modules.game_exiva.test("Bob is far to the north.")

dofile('png')
dofile('geometry')

MAX_TARGETS = 3
MAX_CASTS = 3
CAST_TTL = 90000       -- ms; a moving target makes old replies worthless
PENDING_MS = 3000      -- pair the "exiva X" we said with the reply that follows
COLORS = { '#ffd23c', '#4fd6ff', '#ff5ce6' }
ALPHA = { edge = 210, fill = 120, faint = 40 }
TICK_MS = 1000
CACHE_FLUSH_EVERY = 10 -- renders between g_textures.clearCache() calls (each render is a new file)
DIR = '/exiva'

local window, contents, button, minimap, hint, mapPanel
local useMarkers = true -- name floating at the edge of the game view, in the direction of the estimated spot
local targets = {}     -- { name, color, casts = { newest first }, overlay, label, dots, row, raster, file }
local pendingCast      -- { who (lower case), pos, t }
local tickEvent
local renderSeq = 0
local useMask = true
local lastFloor

local function now() return g_clock.millis() end

local function explored(x, y, z)
  local color = g_map.getMinimapColor({ x = x, y = y, z = z })
  return color ~= nil and not ExivaGeo.BLOCKED[color]
end

local function activeCasts(target)
  local out, t = {}, now()
  for _, c in ipairs(target.casts) do
    if t - c.t < CAST_TTL then table.insert(out, c) end
  end
  return out
end

local function levelText(c)
  if c.level == 'same' then return 'z' .. c.pos.z end
  if c.level == 'higher' then return 'above z' .. c.pos.z end
  if c.level == 'lower' then return 'below z' .. c.pos.z end
  return 'any floor'
end

local BAND_WORDS = { beside = 'next to you', close = 'close', far = 'far', veryfar = 'very far' }

local function infoText(target)
  local c = target.casts[1]
  if not c then return 'no reply yet' end
  local age = math.floor((now() - c.t) / 1000)
  if age >= CAST_TTL / 1000 then return 'expired - click to exiva again' end
  local where = BAND_WORDS[c.band] .. (c.dir and (' ' .. c.dir) or '')
  local floor = levelText(c)
  if target.raster and target.raster.floorBlocked then floor = floor .. ' (not this floor)' end
  return string.format('%s - %ds - %s', where, age, floor)
end

local function labelText(target)
  local c = target.casts[1]
  local suffix = ''
  if c and c.level == 'higher' then suffix = ' (up)' elseif c and c.level == 'lower' then suffix = ' (down)' end
  return target.name .. suffix
end

-- ---------------------------------------------------------------- minimap widgets

local function destroyDots(target)
  for _, d in ipairs(target.dots) do d:destroy() end
  target.dots = {}
end

local function hideOverlay(target)
  if target.overlay then target.overlay:hide() end
  if target.label then target.label:hide() end
  if target.marker then target.marker:hide() end
  destroyDots(target)
end

local function destroyWidgets(target)
  hideOverlay(target)
  if target.marker then target.marker:destroy() target.marker = nil end
  if target.row then target.row:destroy() target.row = nil end
  if target.overlay then target.overlay:destroy() target.overlay = nil end
  if target.label then target.label:destroy() target.label = nil end
  if target.file then g_resources.deleteFile(target.file) target.file = nil end
end

local function ensureWidgets(target)
  if target.overlay then return end
  target.overlay = g_ui.createWidget('ExivaOverlay', minimap)
  minimap:moveChildToIndex(target.overlay, 1)
  target.overlay:setImageColor(target.color)
  target.label = g_ui.createWidget('ExivaLabel', minimap)
  target.label:setColor(target.color)
end

local function refit(target)
  local r = target.raster
  if not r or not target.overlay then return end
  local scale = minimap:getScale()
  target.overlay:resize(math.max(1, math.floor(r.cols * r.cell * scale + 0.5)),
                        math.max(1, math.floor(r.rows * r.cell * scale + 0.5)))
end

local function applyRaster(target, z)
  local r = target.raster
  if not r or r.count == 0 then hideOverlay(target) return end
  ensureWidgets(target)
  local grid, edge = r.grid, r.edge
  local data = ExivaPNG.encode(r.cols, r.rows, function(x, y)
    local v = grid[y][x]
    if v == 0 then return 0 end
    if edge[y][x] then return ALPHA.edge end
    if v == 2 then return ALPHA.fill end
    return ALPHA.faint
  end)
  renderSeq = renderSeq + 1
  local path = DIR .. '/ov' .. renderSeq .. '.png'
  if not g_resources.writeFileContents(path, data) then
    print('exiva: cannot write ' .. path)
    return
  end
  target.overlay:setImageSource(path)
  if target.file then g_resources.deleteFile(target.file) end
  target.file = path
  if renderSeq % CACHE_FLUSH_EVERY == 0 then g_textures.clearCache() end

  -- centre anchoring like the cross and flags: exact to the tile. Edge anchoring drifts (the tile rect
  -- the minimap hands out for edges is not one sqm wide).
  minimap:centerInPosition(target.overlay, { x = r.x0 + math.floor(r.cols * r.cell / 2),
                                             y = r.y0 + math.floor(r.rows * r.cell / 2), z = z })
  minimap:centerInPosition(target.label, { x = r.cx, y = r.cy, z = z })
  target.label:setText(labelText(target))
  refit(target)
  target.overlay:show()
  target.label:show()

  destroyDots(target)
  for _, c in ipairs(target.casts) do
    if c.pos.z == z then
      local dot = g_ui.createWidget('ExivaDot', minimap)
      dot:setBackgroundColor(target.color)
      minimap:centerInPosition(dot, { x = c.pos.x, y = c.pos.y, z = z })
      table.insert(target.dots, dot)
    end
  end
end

local function viewedFloor()
  local cam = minimap:getCameraPosition()
  if cam then return cam.z end
  local me = g_game.getLocalPlayer()
  return me and me:getPosition() and me:getPosition().z or 7
end

local function render(target)
  local z = viewedFloor()
  local casts = activeCasts(target)
  local r
  while #casts > 0 do
    r = ExivaGeo.raster(casts, z, useMask, explored)
    if r and r.count > 0 then break end
    table.remove(casts) -- newest first: the oldest reply contradicts the newest, the target moved
    r = nil
  end
  target.casts = casts
  target.raster = r
  applyRaster(target, z)
  updateMarker(target)
end

-- on-screen marker: the name slides along the edge of the game view, in the direction of the estimated spot
-- (centroid of the highlighted area, or the label point for a lone very-far reply), from your current position
local function updateMarker(target)
  local r = target.raster
  local me = g_game.getLocalPlayer()
  local pos = me and me:getPosition()
  if not useMarkers or not mapPanel or not r or not r.cx or not pos or #target.casts == 0 then
    if target.marker then target.marker:hide() end
    return
  end
  if not target.marker then
    target.marker = g_ui.createWidget('ExivaMarker', mapPanel)
    target.marker:setColor(target.color)
  end
  local m = target.marker
  local dx, dy = r.cx - pos.x, r.cy - pos.y
  -- honest distance: nearest and farthest point of the highlighted area from where you stand. The extremes of a
  -- region lie on its outline, so only the edge cells are checked (cached per raster).
  if not r.edgePoints then
    r.edgePoints = {}
    local half = (r.cell - 1) / 2
    for j, row in pairs(r.edge) do
      for i in pairs(row) do table.insert(r.edgePoints, { r.x0 + i * r.cell + half, r.y0 + j * r.cell + half }) end
    end
  end
  local dmin, dmax = math.huge, 0
  for _, pt in ipairs(r.edgePoints) do
    local ex, ey = pt[1] - pos.x, pt[2] - pos.y
    local d = math.sqrt(ex * ex + ey * ey)
    if d < dmin then dmin = d end
    if d > dmax then dmax = d end
  end
  local j, i = math.floor((pos.y - r.y0) / r.cell), math.floor((pos.x - r.x0) / r.cell)
  if r.grid[j] and r.grid[j][i] and r.grid[j][i] > 0 then dmin = 0 end -- standing inside the area
  -- "very far" is open-ended (the wedge is only drawn to a cap): no honest upper bound then
  local openEnded = false
  for _, c in ipairs(target.casts) do if c.band == 'veryfar' then openEnded = true end end
  local range = '?'
  if dmin ~= math.huge then
    range = openEnded and (math.floor(dmin) .. '+ sqm') or (math.floor(dmin) .. '-' .. math.ceil(dmax) .. ' sqm')
  end
  m:setText(labelText(target) .. '  ' .. range)
  local w, h = mapPanel:getWidth(), mapPanel:getHeight()
  local mw, mh = m:getWidth(), m:getHeight()
  if dx == 0 and dy == 0 then dy = -1 end
  local halfW, halfH = w / 2 - mw / 2 - 4, h / 2 - mh / 2 - 4
  local t = math.min(dx ~= 0 and halfW / math.abs(dx) or math.huge, dy ~= 0 and halfH / math.abs(dy) or math.huge)
  m:setMarginLeft(math.floor(w / 2 + dx * t - mw / 2))
  m:setMarginTop(math.floor(h / 2 + dy * t - mh / 2))
  m:show()
end

local function updateMarkers()
  for _, t in ipairs(targets) do updateMarker(t) end
end

local function fade(target)
  local c = target.casts[1]
  if not c or not target.overlay then return end
  local op = math.max(0.35, 1 - 0.65 * (now() - c.t) / CAST_TTL)
  target.overlay:setOpacity(op)
  target.label:setOpacity(op)
  if target.marker then target.marker:setOpacity(math.max(0.5, op)) end
end

-- ---------------------------------------------------------------- panel

local function updateRow(target)
  if not target.row then return end
  target.row:getChildById('info'):setText(infoText(target))
end

local function rebuildRows()
  for _, child in ipairs(contents:getChildren()) do
    if child ~= hint then child:destroy() end
  end
  for _, t in ipairs(targets) do t.row = nil end
  hint:setVisible(#targets == 0)
  for _, t in ipairs(targets) do
    local row = g_ui.createWidget('ExivaRow', contents)
    row:getChildById('swatch'):setBackgroundColor(t.color)
    row:getChildById('name'):setText(t.name)
    row:getChildById('name'):setColor(t.color)
    row:setTooltip('Click: exiva ' .. t.name .. ' again')
    local name = t.name
    local removeButton = row:getChildById('removeButton')
    row.onMouseRelease = function(_, mousePos, mouseButton)
      if removeButton:containsPoint(mousePos) then return false end
      if mouseButton == MouseLeftButton and g_game.isOnline() then g_game.talk('exiva "' .. name .. '"') end
      return true
    end
    removeButton.onClick = function() modules.game_exiva.forget(name) end
    t.row = row
    updateRow(t)
  end
end

local function findTarget(name)
  local lname = name:lower()
  for i, t in ipairs(targets) do
    if t.name:lower() == lname then return t, i end
  end
end

local function freeColor()
  for _, color in ipairs(COLORS) do
    local used = false
    for _, t in ipairs(targets) do if t.color == color then used = true break end end
    if not used then return color end
  end
  return COLORS[1]
end

local function removeTarget(target)
  destroyWidgets(target)
  for i, t in ipairs(targets) do
    if t == target then table.remove(targets, i) break end
  end
end

local function addCast(name, cast)
  local target, index = findTarget(name)
  if target then
    table.remove(targets, index)
  else
    while #targets >= MAX_TARGETS do removeTarget(targets[#targets]) end
    target = { name = name, color = freeColor(), casts = {}, dots = {} }
  end
  table.insert(targets, 1, target)
  table.insert(target.casts, 1, cast)
  while #target.casts > MAX_CASTS do table.remove(target.casts) end
  render(target)
  fade(target)
  rebuildRows()
end

-- ---------------------------------------------------------------- game events

local function onTalk(name, level, mode, text, channelId, pos)
  local me = g_game.getLocalPlayer()
  if not me or name ~= me:getName() or type(text) ~= 'string' then return end
  local who = text:match('^[Ee]xiva%s+"?(.-)"?%s*$')
  if who and #who > 0 then
    pendingCast = { who = who:lower(), pos = pos or me:getPosition(), t = now() }
  end
end

local function onTextMessage(mode, text)
  if type(text) ~= 'string' then return end
  local parsed = ExivaGeo.parse(text)
  if not parsed then return end
  local me = g_game.getLocalPlayer()
  if not me then return end
  local origin = me:getPosition()
  if pendingCast and now() - pendingCast.t < PENDING_MS and pendingCast.pos then
    local n = parsed.name:lower()
    if n:sub(1, #pendingCast.who) == pendingCast.who or pendingCast.who:sub(1, #n) == n then
      origin = pendingCast.pos
    end
  end
  pendingCast = nil
  if not origin then return end
  addCast(parsed.name, { pos = { x = origin.x, y = origin.y, z = origin.z }, band = parsed.band,
                         dir = parsed.dir, level = parsed.level, t = now(), text = text })
end

local function onZoom()
  for _, t in ipairs(targets) do refit(t) end
end

local function onCamera(_, pos)
  if not pos or pos.z == lastFloor then return end
  lastFloor = pos.z
  for _, t in ipairs(targets) do render(t) end
  for _, t in ipairs(targets) do updateRow(t) end
end

local function tick()
  for _, t in ipairs(targets) do
    local before = #t.casts
    local active = activeCasts(t)
    if #active ~= before then
      if #active == 0 then t.casts = {} t.raster = nil hideOverlay(t) else render(t) end
    end
    fade(t)
    updateRow(t)
  end
end

-- ---------------------------------------------------------------- public

function clearAll()
  for _, t in ipairs(targets) do destroyWidgets(t) end
  targets = {}
  pendingCast = nil
  if contents then rebuildRows() end
end

function forget(name)
  local t = findTarget(name)
  if t then removeTarget(t) rebuildRows() end
end

function setMask(on)
  useMask = on and true or false
  g_settings.set('exivaMask', useMask)
  for _, t in ipairs(targets) do render(t) end
end

-- feed a reply line by hand, origin = your position
function test(text)
  onTextMessage(nil, text)
end

function showMenu()
  local menu = g_ui.createWidget('PopupMenu')
  menu:setGameMenu(true)
  menu:addOption((useMask and '[x] ' or '[ ] ') .. tr('Only explored tiles'), function() setMask(not useMask) end)
  menu:addOption((useMarkers and '[x] ' or '[ ] ') .. tr('Name at the edge of the game view'), function()
    useMarkers = not useMarkers
    g_settings.set('exivaMarker', useMarkers)
    updateMarkers()
  end)
  menu:addOption(tr('Full map (Ctrl+Shift+M)'), function() modules.game_minimap.toggleFullMap() end)
  menu:addSeparator()
  menu:addOption(tr('Forget everyone'), clearAll)
  local b = window:getChildById('menuButton')
  local p = b:getPosition()
  menu:display({ x = p.x, y = p.y + b:getHeight() })
end

function toggle()
  if window:isVisible() then window:close() else window:open() end
end

function onMiniWindowClose()
  if button then button:setOn(false) end
end

function init()
  minimap = modules.game_minimap.minimapWidget
  if not minimap then
    print('exiva: minimap widget not found, module idle')
    return
  end
  if g_settings.exists('exivaMask') then useMask = g_settings.getBoolean('exivaMask') end
  if g_settings.exists('exivaMarker') then useMarkers = g_settings.getBoolean('exivaMarker') end
  mapPanel = modules.game_interface.getMapPanel()
  if not g_map.getMinimapColor then
    print('exiva: g_map.getMinimapColor missing in this client, explored-tiles mask disabled')
    useMask = false
  end
  if not g_resources.directoryExists(DIR) then g_resources.makeDir(DIR) end
  minimap:setClipping(true)

  local root = modules.game_interface.getRootPanel()
  local parent = root:recursiveGetChildById('leftPanel2') or modules.game_interface.getLeftPanel()
  window = g_ui.loadUI('exiva', parent)
  contents = window:getChildById('contentsPanel')
  hint = contents:getChildById('hint')
  button = modules.client_topmenu.addRightGameToggleButton('exivaButton', tr('Exiva'), '/images/topbuttons/ciclopedia', toggle, false, 1006)
  window.onOpen = function() if button then button:setOn(true) end end
  window:setup()
  if button then button:setOn(window:isVisible()) end

  connect(g_game, { onTextMessage = onTextMessage, onTalk = onTalk, onGameEnd = clearAll })
  connect(minimap, { onZoomChange = onZoom, onCameraPositionChange = onCamera })
  connect(LocalPlayer, { onPositionChange = updateMarkers })
  if mapPanel then connect(mapPanel, { onGeometryChange = updateMarkers }) end
  local cam = minimap:getCameraPosition() -- nil before the first login
  lastFloor = cam and cam.z
  tickEvent = cycleEvent(tick, TICK_MS)
end

function terminate()
  if not minimap then return end
  disconnect(g_game, { onTextMessage = onTextMessage, onTalk = onTalk, onGameEnd = clearAll })
  disconnect(minimap, { onZoomChange = onZoom, onCameraPositionChange = onCamera })
  disconnect(LocalPlayer, { onPositionChange = updateMarkers })
  if mapPanel then disconnect(mapPanel, { onGeometryChange = updateMarkers }) end
  removeEvent(tickEvent)
  clearAll()
  if button then button:destroy() button = nil end
  if window then window:destroy() window = nil end
  minimap = nil
end
