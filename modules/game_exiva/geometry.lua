-- Exiva geometry: parse the server reply, test map positions against it, rasterize the intersection
-- of several replies. Distances follow TFS (spells.cpp SearchPlayer): a "next to you" box, then rings
-- of 100 and 274 sqm; directions are 8 sectors of 45 degrees (tan 22.5 = 0.4142, tan 67.5 = 2.4142).
ExivaGeo = {}

ExivaGeo.BESIDE = 4          -- |dx| and |dy| below this = "standing next to you"
ExivaGeo.CLOSE = 100         -- "is to the": under this many sqm
ExivaGeo.FAR = 274           -- "far": under this, "very far": beyond
ExivaGeo.VERYFAR_CAP = 3000  -- "very far" is open-ended; draw this much (past the map edge in tests)
ExivaGeo.MAX_PX = 768        -- image side limit; bigger areas use cells of several sqm
ExivaGeo.MASK_MAX_CELL = 8   -- cells above this are too coarse to sample the minimap: drawn as plain fill
-- minimap colours nobody can stand on: trees, water, walls, lava. 0 and 255 = nothing known there.
ExivaGeo.BLOCKED = { [0] = true, [24] = true, [40] = true, [186] = true, [192] = true, [255] = true }

local OUTER = { beside = ExivaGeo.BESIDE, close = ExivaGeo.CLOSE, far = ExivaGeo.FAR, veryfar = ExivaGeo.VERYFAR_CAP }
local D = 0.70710678
local DIR_VECTORS = { N = { 0, -1 }, S = { 0, 1 }, E = { 1, 0 }, W = { -1, 0 }, NE = { D, -D }, NW = { -D, -D }, SE = { D, D }, SW = { -D, D } }

local DIRS = {
  north = 'N', south = 'S', east = 'E', west = 'W',
  ['north-east'] = 'NE', ['north-west'] = 'NW', ['south-east'] = 'SE', ['south-west'] = 'SW',
  northeast = 'NE', northwest = 'NW', southeast = 'SE', southwest = 'SW',
}

local PATTERNS = {
  { "^(.-) is standing next to you%.?$", 'beside', 'same' },
  { "^(.-) is above you%.?$", 'beside', 'higher' },
  { "^(.-) is below you%.?$", 'beside', 'lower' },
  { "^(.-) is on a higher level to the ([%a%-]+)%.?$", 'close', 'higher' },
  { "^(.-) is on a lower level to the ([%a%-]+)%.?$", 'close', 'lower' },
  { "^(.-) is very far to the ([%a%-]+)%.?$", 'veryfar', 'unknown' },
  { "^(.-) is far to the ([%a%-]+)%.?$", 'far', 'unknown' },
  { "^(.-) is to the ([%a%-]+)%.?$", 'close', 'same' },
}

-- "Bob is far to the north-east." -> { name = "Bob", band = "far", level = "unknown", dir = "NE" }
function ExivaGeo.parse(text)
  for _, p in ipairs(PATTERNS) do
    local name, dirWord = text:match(p[1])
    if name then
      local dir = dirWord and DIRS[dirWord:lower()]
      if dirWord and not dir then return nil end
      return { name = name, band = p[2], level = p[3], dir = dir }
    end
  end
end

-- dx, dy = caster minus target, as TFS computes them
local function directionOf(dx, dy)
  local tan = dx ~= 0 and (dy / dx) or 10
  local atan = math.abs(tan)
  if atan < 0.4142 then
    return dx > 0 and 'W' or 'E'
  elseif atan < 2.4142 then
    if tan > 0 then return dy > 0 and 'NW' or 'SE' end
    return dx > 0 and 'SW' or 'NE'
  end
  return dy > 0 and 'N' or 'S'
end
ExivaGeo.directionOf = directionOf

function ExivaGeo.satisfies(c, x, y)
  local dx, dy = c.pos.x - x, c.pos.y - y
  local beside = math.abs(dx) < ExivaGeo.BESIDE and math.abs(dy) < ExivaGeo.BESIDE
  if c.band == 'beside' then return beside end
  if beside then return false end
  local d2 = dx * dx + dy * dy
  local close2, far2 = ExivaGeo.CLOSE * ExivaGeo.CLOSE, ExivaGeo.FAR * ExivaGeo.FAR
  if c.band == 'close' then
    if d2 >= close2 then return false end
  elseif c.band == 'far' then
    if d2 < close2 or d2 >= far2 then return false end
  elseif d2 < far2 then
    return false
  end
  return directionOf(dx, dy) == c.dir
end

function ExivaGeo.floorOk(c, z)
  if c.level == 'same' then return z == c.pos.z end
  if c.level == 'higher' then return z < c.pos.z end
  if c.level == 'lower' then return z > c.pos.z end
  return true
end

local function sampleExplored(x, y, cell, z, explored)
  if cell <= 1 then return explored(x, y, z) end
  local q, last, mid = math.floor(cell / 4), cell - 1, math.floor(cell / 2)
  return explored(x + q, y + q, z) or explored(x + last - q, y + q, z) or explored(x + q, y + last - q, z)
    or explored(x + last - q, y + last - q, z) or explored(x + mid, y + mid, z)
end

-- Intersection of the casts on floor z as a cell grid. nil when the bounding boxes do not overlap.
-- grid[j][i]: 0 outside, 1 inside but unexplored, 2 inside and explored; edge[j][i] marks the outline.
-- count = inside cells, explored = inside cells with known ground, cx/cy = centroid of the highlighted cells.
-- floorBlocked = the replies rule out floor z (drawn faint, unmasked).
function ExivaGeo.raster(casts, z, useMask, explored)
  local x0, y0, x1, y1 = -math.huge, -math.huge, math.huge, math.huge
  for _, c in ipairs(casts) do
    local r = OUTER[c.band]
    x0, x1 = math.max(x0, c.pos.x - r), math.min(x1, c.pos.x + r)
    y0, y1 = math.max(y0, c.pos.y - r), math.min(y1, c.pos.y + r)
  end
  if x1 < x0 or y1 < y0 then return nil end
  -- floors the replies rule out still get the wedge, only faint (no mask): you see the direction from any floor
  local floorPossible = true
  for _, c in ipairs(casts) do
    if not ExivaGeo.floorOk(c, z) then floorPossible = false break end
  end
  local w, h = x1 - x0 + 1, y1 - y0 + 1
  local cell = math.ceil(math.max(w, h) / ExivaGeo.MAX_PX)
  local cols, rows = math.ceil(w / cell), math.ceil(h / cell)
  local grid, edge = {}, {}
  local count, exploredCount = 0, 0
  local sumI, sumJ, sumEI, sumEJ = 0, 0, 0, 0
  local half = (cell - 1) / 2
  for j = 0, rows - 1 do
    local row = {}
    local cy = y0 + j * cell + half
    for i = 0, cols - 1 do
      local cx = x0 + i * cell + half
      local inside = true
      for _, c in ipairs(casts) do
        if not ExivaGeo.satisfies(c, cx, cy) then inside = false break end
      end
      local v = 0
      if inside then
        count = count + 1
        sumI, sumJ = sumI + i, sumJ + j
        v = 1
        if floorPossible and (not useMask or cell > ExivaGeo.MASK_MAX_CELL or sampleExplored(x0 + i * cell, y0 + j * cell, cell, z, explored)) then
          v = 2
          exploredCount = exploredCount + 1
          sumEI, sumEJ = sumEI + i, sumEJ + j
        end
      end
      row[i] = v
    end
    grid[j] = row
  end
  for j = 0, rows - 1 do
    local erow = {}
    local row, up, down = grid[j], grid[j - 1], grid[j + 1]
    for i = 0, cols - 1 do
      if row[i] > 0 then
        if row[i - 1] == nil or row[i - 1] == 0 or row[i + 1] == nil or row[i + 1] == 0
          or up == nil or up[i] == 0 or down == nil or down[i] == 0 then
          erow[i] = true
        end
      end
    end
    edge[j] = erow
  end
  -- label position: centroid of the highlighted cells (explored ones when there are any); for huge regions
  -- the centroid is thousands of sqm away, so use a point just past the inner ring on the sector's centre line
  local cx, cy
  local newest = casts[1]
  if cell > ExivaGeo.MASK_MAX_CELL and newest.dir and DIR_VECTORS[newest.dir] then
    local v = DIR_VECTORS[newest.dir]
    local d = ExivaGeo.FAR + 40
    cx, cy = math.floor(newest.pos.x + v[1] * d + 0.5), math.floor(newest.pos.y + v[2] * d + 0.5)
  elseif exploredCount > 0 then
    cx, cy = x0 + math.floor(sumEI / exploredCount * cell + half), y0 + math.floor(sumEJ / exploredCount * cell + half)
  elseif count > 0 then
    cx, cy = x0 + math.floor(sumI / count * cell + half), y0 + math.floor(sumJ / count * cell + half)
  end
  return { x0 = x0, y0 = y0, cell = cell, cols = cols, rows = rows, grid = grid, edge = edge,
           count = count, explored = exploredCount, cx = cx, cy = cy, floorBlocked = not floorPossible }
end
