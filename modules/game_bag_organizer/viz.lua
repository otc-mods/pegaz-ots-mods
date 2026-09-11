-- Sprite view of a bag tree: one row per backpack, indented by depth, showing that bag's real slots.
-- Renders the same shape for the scanned tree (BEFORE) and the simulated target (AFTER), so the two panels
-- are directly comparable. Positions are computed here rather than left to a layout: a grid layout would
-- re-flow after the fact and the row heights have to be known up front for the vertical box to stack them.
BagViz = {}

local CELL = 34
local HEADER_W = 96          -- bag sprite + its caption
local INDENT = 20
local EMPTY_SHOWN = 0        -- free slots are one "+N" cell: individual dim cells read as noise
local DEFAULT_BAG = 2854

local PALETTE = { '#e0913c', '#4fa3d1', '#7bc96f', '#c586c0', '#d6c14a', '#d97070', '#5fc9bd', '#9a9ae8' }

local function tintFor(name)
  if not name or name == "" then return '#6d7378' end
  local h = 0
  for i = 1, #name do h = (h * 31 + name:byte(i)) % 65536 end
  return PALETTE[(h % #PALETTE) + 1]
end

-- children of `path`, in slot order
local function subsOf(node)
  local out = {}
  for _, e in ipairs(node.items or {}) do
    if e.isContainer then table.insert(out, e) end
  end
  return out
end

-- identical ids collapse into one cell carrying the total count
local function groupItems(node)
  local order, byId = {}, {}
  for _, e in ipairs(node.items or {}) do
    if not e.isContainer then
      if not byId[e.id] then byId[e.id] = { id = e.id, n = 0 } table.insert(order, byId[e.id]) end
      byId[e.id].n = byId[e.id].n + (e.count or 1)
    end
  end
  table.sort(order, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.id < b.id end)
  return order
end

local function cellAt(row, style, index, cols)
  local w = g_ui.createWidget(style, row)
  w:setMarginLeft(HEADER_W + (index % cols) * CELL)
  w:setMarginTop(math.floor(index / cols) * CELL)
  return w
end

local function addRow(parent, path, node, depth, opts)
  local row = g_ui.createWidget('BagOrgVizRow', parent)
  row:setMarginLeft(depth * INDENT)

  local bucket = opts.ownerOf and opts.ownerOf[path]
  local tint = tintFor(bucket or (path == "" and "" or nil))

  local bag = g_ui.createWidget('BagOrgVizBag', row)
  bag:setItemId(node.id or DEFAULT_BAG)
  bag:setItemCount(1)
  bag:setBorderColor(tint)

  local used, cap = #(node.items or {}), node.cap or 20
  local name = g_ui.createWidget('BagOrgVizName', row)
  local loose, subs = 0, 0
  for _, e in ipairs(node.items or {}) do
    if e.isContainer then subs = subs + 1 else loose = loose + 1 end
  end
  name:setText(bucket or (path == "" and "main" or (loose + subs == 0 and "empty" or "spare")))
  name:setColor(bucket and tint or '#cccccc')
  local sub = g_ui.createWidget('BagOrgVizSub', row)
  sub:setText(string.format("%d/%d", used, cap))
  bag:setTooltip(string.format("%s\n%s\n%d/%d slots used",
    node.name or "backpack", path == "" and "(main)" or path, used, cap))

  local avail = math.max(120, (opts.width or 440) - HEADER_W - depth * INDENT - 8)
  local cols = math.max(3, math.floor(avail / CELL))

  local idx = 0
  for _, e in ipairs(subsOf(node)) do
    local c = cellAt(row, 'BagOrgVizBag', idx, cols)
    c:setItemId(e.id or DEFAULT_BAG)
    c:setItemCount(1)
    c:setBorderColor(opts.ownerOf and opts.ownerOf[e.sub] and tintFor(opts.ownerOf[e.sub]) or '#3d4348')
    c:setTooltip("backpack -> " .. tostring(e.sub))
    idx = idx + 1
  end
  for _, g in ipairs(groupItems(node)) do
    local c = cellAt(row, 'BagOrgVizCell', idx, cols)
    c:setItemId(g.id)
    c:setItemCount(1)
    local label = c:getChildById('count')
    if label then label:setText(g.n > 1 and ("x" .. g.n) or "") end
    local nm = opts.itemName and opts.itemName(g.id) or tostring(g.id)
    c:setTooltip(string.format("%s%s\nid %d", nm, g.n > 1 and (" x" .. g.n) or "", g.id))
    idx = idx + 1
  end
  local free = math.max(0, cap - used)
  local shown = math.min(free, EMPTY_SHOWN)
  for _ = 1, shown do
    cellAt(row, 'BagOrgVizEmpty', idx, cols) idx = idx + 1
  end
  if free > shown then
    local c = cellAt(row, 'BagOrgVizEmpty', idx, cols)
    local label = c:getChildById('count')
    if label then label:setText("+" .. (free - shown)) end
    c:setTooltip((free - shown) .. " more free slot(s)")
    idx = idx + 1
  end

  local lines = math.max(1, math.ceil(idx / cols))
  row:setHeight(math.max(CELL, lines * CELL) + 2)
end

-- bags: path -> { id, name, cap, items }   opts: { ownerOf, itemName, width }
function BagViz.render(panel, bags, opts)
  if not panel then return end
  panel:destroyChildren()
  if not bags or not bags[""] then return end
  opts = opts or {}
  opts.width = opts.width or panel:getWidth()
  if not opts.width or opts.width < 200 then opts.width = 440 end

  local function walk(path, depth)
    local node = bags[path]
    if not node then return end
    addRow(panel, path, node, depth, opts)
    for _, e in ipairs(subsOf(node)) do walk(e.sub, depth + 1) end
  end
  walk("", 0)
end

-- one-line stock take of a tree
function BagViz.summary(bags)
  local nbags, items, empty = 0, 0, 0
  for path, node in pairs(bags or {}) do
    nbags = nbags + 1
    local loose, subs = 0, 0
    for _, e in ipairs(node.items or {}) do
      if e.isContainer then subs = subs + 1 else loose = loose + 1 items = items + 1 end
    end
    if path ~= "" and loose == 0 and subs == 0 then empty = empty + 1 end
  end
  return string.format("%d bag(s) - %d item(s) - %d empty bag(s)", nbags, items, empty)
end
