-- Bag layout planner. Pure logic: no client API, no side effects - so it is unit-tested offline.
--
-- Target layout: ONE first-level backpack per category, with overflow in bags NESTED INSIDE it.
--
--   Main backpack
--   |- [Jewelry bag]      <- exactly one per category at the top level
--   |   |- nested bag     <- overflow lives inside
--   |   |- nested bag
--   |   \- jewelry items...
--   |- [Potions bag]
--   \- [Empties]          <- leftover empty bags collected for dropping
--
-- A category bag holds `cap` slots; each nested bag costs one of them and adds its own, so
--     capacity = cap - subs + sum(cap of each sub)      (20 - s + 20s = 20 + 19s for cap 20)
--
-- Only first-level bags ("/3") may be a category bag. The main backpack ("") holds them and is never one.
-- Anything deeper is storage whose contents are pulled up into the category bags.
--
-- Two phases, because moving a bag CHANGES ITS PATH and would invalidate every later move:
--   phase 1  bagMoves   relocate empty bags into the category bags that need overflow
--   phase 2  moves      the item moves
-- Apply runs phase 1, rescans, then re-plans: with the sub-bags in place phase 1 comes back empty and only the
-- item moves remain. Nothing has to guess a post-move path.
BagPlan = {}

local CAP_FALLBACK = 20

local function isTop(path) return path ~= "" and path:match("^/%d+$") ~= nil end
local function depthOf(path) local _, n = path:gsub("/", "") return n end

function BagPlan.build(bags, bucketOf, opts)
  opts = opts or {}
  local info = { buckets = {}, blocked = 0, unplaced = 0, shortBags = 0, emptiesMoved = 0, deferred = 0 }

  local order = {}
  for path in pairs(bags) do table.insert(order, path) end
  table.sort(order, function(a, b)
    local da, db = depthOf(a), depthOf(b)
    if da ~= db then return da < db end
    return a < b
  end)

  local function capOf(path) return (bags[path] and bags[path].cap) or CAP_FALLBACK end

  -- ---- 1. stock take -------------------------------------------------------------------------------
  local movable, subs = {}, {}
  for _, path in ipairs(order) do
    movable[path], subs[path] = {}, {}
    for idx, e in ipairs(bags[path].items or {}) do
      if e.isContainer then
        table.insert(subs[path], e.sub or (path .. "/" .. tostring(e.slot or (idx - 1))))
      else
        table.insert(movable[path], { id = e.id, count = e.count, bucket = bucketOf(e.id), path = path })
      end
    end
  end

  local need, holds = {}, {}
  for _, path in ipairs(order) do
    for _, it in ipairs(movable[path]) do
      need[it.bucket] = (need[it.bucket] or 0) + 1
      holds[it.bucket] = holds[it.bucket] or {}
      holds[it.bucket][path] = (holds[it.bucket][path] or 0) + 1
    end
  end

  -- a bag is spare if it holds nothing at all: those become overflow containers or get collected
  local spare = {}
  for _, path in ipairs(order) do
    if path ~= "" and #movable[path] == 0 and #subs[path] == 0 then table.insert(spare, path) end
  end

  -- ---- 2. one category bag per bucket -------------------------------------------------------------
  local bucketList = {}
  for b, n in pairs(need) do table.insert(bucketList, { b = b, n = n }) end
  table.sort(bucketList, function(x, y)
    if x.n ~= y.n then return x.n > y.n end
    return x.b < y.b
  end)
  -- A bucket the user pointed at Containers never receives items (a backpack is a shelf, not goods), so it
  -- would silently stay empty. Give it a home for the SPARE BAGS instead, and claim it last so buckets that
  -- actually hold items get their backpacks first.
  if opts.gatherBucket and not need[opts.gatherBucket] and #spare > 0 then
    table.insert(bucketList, { b = opts.gatherBucket, n = #spare, bagsOnly = true })
  end

  local owner, home = {}, {}
  local spareTaken = {}
  local bagMoves = {}
  local promoted, promotedFor = 0, {}
  for _, entry in ipairs(bucketList) do
    local b = entry.b
    local best, bestScore
    for _, path in ipairs(order) do
      if isTop(path) and not owner[path] then
        local has = (holds[b] or {})[path] or 0
        local foreign = #movable[path] - has
        -- most of this bucket already inside wins; then the least foreign content to evict
        local score = has * 1000 - foreign
        if not bestScore or score > bestScore then best, bestScore = path, score end
      end
    end
    if best then
      owner[best] = b
      home[b] = best
    else
      -- No first-level bag left for this bucket, so promote a spare empty one INTO the main backpack. The next
      -- pass sees a new first-level bag and claims it. Without this, an extra bucket simply had nowhere to go
      -- even with empty backpacks sitting nested somewhere - and buckets are the user's to define.
      local mainFree = capOf("") - #(bags[""].items or {}) - promoted
      local picked
      if mainFree > 0 then
        for i, path in ipairs(spare) do
          if not spareTaken[path] then picked = path table.remove(spare, i) break end
        end
      end
      if picked then
        spareTaken[picked] = true
        promoted = promoted + 1
        table.insert(bagMoves, { kind = 'bag', fromPath = picked, toPath = "", promote = true, bucket = b })
        promotedFor[b] = true                        -- its items are placed next pass, against the new path
      else
        info.unplaced = info.unplaced + entry.n
        info.shortBags = info.shortBags + 1
      end
    end
  end

  -- ---- 3. build each bucket's storage tree --------------------------------------------------------
  -- A bucket's storage is a TREE of backpacks, not one bag with things nested a single level deep. A 20-slot
  -- bag cannot hold 83 sub-bags, which is what the flat model happily "planned" for a 1595-item hoard. n bags
  -- arranged as a tree hold 19n + 1 item slots, and the tree grows shallowest-first so no move needs a long
  -- chain of ancestors open.
  --
  -- Bags are also relocated WHOLE when they already hold nothing but this bucket: one move instead of twenty.
  local roomMoves = {}        -- park items out of a full bag so a sub-bag can go in
  local destsOf = {}
  local parkedBags = {}       -- moved whole; the items inside them are already home
  local subCount, used = {}, {}
  for _, path in ipairs(order) do
    subCount[path] = #subs[path]
    used[path] = #(bags[path].items or {})
  end

  local PARK_PER_BUCKET = 4

  for _, entry in ipairs(bucketList) do
    local b, c = entry.b, home[entry.b]
    if c then
      local treeBags, inTree = { c }, { [c] = true }
      for _, path in ipairs(order) do
        if path ~= c and path:find("^" .. c .. "/") then
          table.insert(treeBags, path)
          inTree[path] = true
        end
      end

      local function itemCapacity()
        local total = 0
        for _, p in ipairs(treeBags) do total = total + math.max(0, capOf(p) - (subCount[p] or 0)) end
        return total
      end
      -- Shallowest bag with a physically free slot, and among those the one with the LEAST room left: fill a
      -- bag before starting the next. Preferring the emptiest instead spread five or six sub-bags across a
      -- dozen siblings, and a bag left with fourteen free slots can never take a twenty-item group - that is
      -- how 192 item slots ended up stranded in half-built branch bags.
      local function host()
        local best, bestKey
        for _, p in ipairs(treeBags) do
          local free = capOf(p) - (used[p] or 0)
          if free > 0 then
            local _, d = p:gsub("/", "")
            local key = d * 1000 + free
            if not bestKey or key < bestKey then best, bestKey = p, key end
          end
        end
        return best
      end
      local function attach(path, whole)
        local h = host()
        if not h then return false end
        spareTaken[path] = true
        table.insert(bagMoves, { kind = 'bag', fromPath = path, toPath = h, bucket = b, whole = whole })
        used[h] = (used[h] or 0) + 1
        subCount[h] = (subCount[h] or 0) + 1
        table.insert(treeBags, path)
        inTree[path] = true
        if whole then parkedBags[path] = true end
        return true
      end

      -- 3a. leaf bags outside the tree holding ONLY this bucket: relocate the bag, not its items
      local whole = {}
      for _, path in ipairs(order) do
        if path ~= "" and not inTree[path] and not owner[path] and not spareTaken[path]
           and #subs[path] == 0 and #movable[path] > 0 then
          local mine = 0
          for _, it in ipairs(movable[path]) do if it.bucket == b then mine = mine + 1 end end
          if mine == #movable[path] then table.insert(whole, path) end
        end
      end
      table.sort(whole, function(x, y)         -- fullest first: most items brought home per move
        if #movable[x] ~= #movable[y] then return #movable[x] > #movable[y] end
        return x < y
      end)
      for _, path in ipairs(whole) do
        if not attach(path, true) then break end
      end

      -- 3b. top up the remaining capacity with empty spares, then with mixed leaf bags
      local parks, guard = 0, 0
      while itemCapacity() < entry.n and guard < 1000 do
        guard = guard + 1
        if not host() then
          -- every bag in the tree is physically full: park a few items out so a sub-bag can go in
          if parks >= PARK_PER_BUCKET then break end
          local fullest, mostItems
          for _, p in ipairs(treeBags) do
            local items = (used[p] or 0) - (subCount[p] or 0)
            if items > 0 and (not mostItems or items > mostItems) then fullest, mostItems = p, items end
          end
          local parkTo
          for _, cand in ipairs(order) do
            if cand ~= fullest and not inTree[cand] and not owner[cand]
               and (capOf(cand) - (used[cand] or 0)) > 0 then parkTo = cand break end
          end
          local it = fullest and movable[fullest] and movable[fullest][1]
          if not fullest or not parkTo or not it then break end
          table.insert(roomMoves, { kind = 'item', id = it.id, count = it.count,
                                    fromPath = fullest, toPath = parkTo, bucket = it.bucket })
          used[fullest] = used[fullest] - 1
          used[parkTo] = (used[parkTo] or 0) + 1
          parks = parks + 1
        else
          local picked
          for i, path in ipairs(spare) do
            if not spareTaken[path] and not inTree[path] and path ~= c
               and not c:find("^" .. path .. "/") then picked = path table.remove(spare, i) break end
          end
          if not picked then
            -- no empty bag left: adopt a leaf bag that owns no bucket, least foreign content first. A bag
            -- nested inside another bucket's home is that home's storage - taking it starts a tug-of-war.
            local best, bestScore
            for _, path in ipairs(order) do
              local parentPath = path:match("^(.*)/%d+$")
              local servingAnother = parentPath and parentPath ~= "" and owner[parentPath] and owner[parentPath] ~= b
              if path ~= "" and not inTree[path] and not owner[path] and not spareTaken[path]
                 and #subs[path] == 0 and not servingAnother and not c:find("^" .. path .. "/") then
                local mine = (holds[b] or {})[path] or 0
                local foreign = #movable[path] - mine
                local score = -foreign * 1000 + mine
                if not bestScore or score > bestScore then best, bestScore = path, score end
              end
            end
            picked = best
          end
          if not picked then break end
          if not attach(picked, false) then break end
        end
      end

      if itemCapacity() < entry.n then
        info.shortBags = info.shortBags + math.ceil((entry.n - itemCapacity()) / 19)
      end

      table.sort(treeBags, function(x, y)      -- shallow bags first, so items land near the top
        local _, dx = x:gsub("/", "")
        local _, dy = y:gsub("/", "")
        if dx ~= dy then return dx < dy end
        return x < y
      end)
      destsOf[b] = treeBags
      -- bags stays 1: one FIRST-LEVEL bag per bucket is the contract. tree counts the whole storage tree.
      info.buckets[b] = { need = entry.n, bags = 1, tree = #treeBags,
                          nested = #treeBags - 1, capacity = itemCapacity() }
    end
  end

  -- ---- 4. place items, keeping identical ones together --------------------------------------------
  -- Within a bucket the items are dealt id-group by id-group, biggest group first, each group going to the
  -- destination that already holds most of it. First-fit placement used to leave 12 rings in one bag and 8 in
  -- the next; dealing whole groups keeps a type in one backpack whenever it fits.
  local moving = {}
  for _, m in ipairs(bagMoves) do moving[m.fromPath] = true end

  local pending = {}
  for _, entry in ipairs(bucketList) do
    local b = entry.b
    local dests = {}
    for _, d in ipairs(destsOf[b] or {}) do if not moving[d] then table.insert(dests, d) end end

    -- slots a destination can give to items: capacity minus the bags nested in it (now and after phase 1)
    local slotsLeft = {}
    for _, d in ipairs(dests) do
      local nested = #(subs[d] or {})
      for _, m in ipairs(bagMoves) do if m.toPath == d then nested = nested + 1 end end
      slotsLeft[d] = math.max(0, capOf(d) - nested)
    end

    local groups, byId = {}, {}
    for _, path in ipairs(order) do
      for _, it in ipairs(movable[path]) do
        -- items inside a bag being relocated whole travel with it: they are already home
        if it.bucket == b and not parkedBags[path] then
          if not byId[it.id] then byId[it.id] = { id = it.id, items = {} } table.insert(groups, byId[it.id]) end
          table.insert(byId[it.id].items, it)
        end
      end
    end
    table.sort(groups, function(x, y)
      if #x.items ~= #y.items then return #x.items > #y.items end
      return x.id < y.id
    end)

    for _, g in ipairs(groups) do
      local hasIn = {}
      for _, it in ipairs(g.items) do hasIn[it.path] = (hasIn[it.path] or 0) + 1 end
      local ranked = {}
      for _, d in ipairs(dests) do table.insert(ranked, d) end
      local pool = {}
      for _, it in ipairs(g.items) do table.insert(pool, it) end

      -- Deal the group bag by bag. While the rest cannot fit anywhere whole, fill the emptiest bag; once it
      -- fits, use the SMALLEST bag that still holds it. That best-fit remainder matters: dealing the 42
      -- amulets first used to leave their 2-item tail in a bag that could have taken 20 rings whole, so the
      -- rings then split 18/18/4 instead of 20/20.
      while #pool > 0 do
        local rem = #pool
        local pick
        local function better(d, cmp)
          if not pick then return true end
          local rd, rp = slotsLeft[d] or 0, slotsLeft[pick] or 0
          if rd ~= rp then return cmp(rd, rp) end
          local hd, hp = hasIn[d] or 0, hasIn[pick] or 0
          if hd ~= hp then return hd > hp end
          return d < pick
        end
        for _, d in ipairs(dests) do
          if (slotsLeft[d] or 0) >= rem and better(d, function(a, b) return a < b end) then pick = d end
        end
        if not pick then
          for _, d in ipairs(dests) do
            if (slotsLeft[d] or 0) > 0 and better(d, function(a, b) return a > b end) then pick = d end
          end
        end
        if not pick then break end
        local take = math.min(slotsLeft[pick], #pool)
        local chosen = 0
        for i = #pool, 1, -1 do                                  -- the ones already here cost no move
          if chosen >= take then break end
          if pool[i].path == pick then pool[i].to = pick table.remove(pool, i) chosen = chosen + 1 end
        end
        for i = #pool, 1, -1 do
          if chosen >= take then break end
          pool[i].to = pick table.remove(pool, i) chosen = chosen + 1
        end
        slotsLeft[pick] = slotsLeft[pick] - chosen
        if chosen == 0 then break end
      end

      -- Regroup only when it actually reduces the number of bags this type sits in. Otherwise the items are
      -- already as gathered as they can be, and repacking them into exactly-full bags is churn for nothing: a
      -- bucket holding one item type would move a dozen items to turn 16+7+20+20+20 into 20+20+20+20+3.
      local quota, seenBefore, seenAfter, before, after = {}, {}, {}, 0, 0
      for _, it in ipairs(g.items) do
        if it.to then quota[it.to] = true end
        if not seenBefore[it.path] then seenBefore[it.path] = true before = before + 1 end
      end
      for _, it in ipairs(g.items) do
        if it.to and not seenAfter[it.to] then seenAfter[it.to] = true after = after + 1 end
      end
      if after >= before then
        for _, it in ipairs(g.items) do
          if it.to and it.to ~= it.path and quota[it.path] then it.to = it.path end
        end
      end

      for _, it in ipairs(pool) do
        local waiting = promotedFor[b] or false
        for _, d in ipairs(destsOf[b] or {}) do if moving[d] then waiting = true break end end
        if waiting then info.deferred = info.deferred + 1 else info.unplaced = info.unplaced + 1 end
      end
    end

    for _, path in ipairs(order) do
      if not parkedBags[path] then
        for _, it in ipairs(movable[path]) do
          if it.bucket == b and it.to and it.to ~= it.path then table.insert(pending, it) end
        end
      end
    end
  end

  -- ---- 5. order the item moves by simulation ------------------------------------------------------
  local liveFree = {}
  for _, path in ipairs(order) do
    liveFree[path] = math.max(0, capOf(path) - #(bags[path].items or {}))
  end
  for _, m in ipairs(bagMoves) do
    liveFree[m.toPath] = math.max(0, (liveFree[m.toPath] or 0) - 1)
  end

  local destBucket = {}
  for b, list in pairs(destsOf) do for _, d in ipairs(list) do destBucket[d] = b end end

  local moves, remaining = {}, {}
  for _, it in ipairs(pending) do if it.to then table.insert(remaining, it) end end
  local parks, PARK_LIMIT = 0, 4
  while #remaining > 0 do
    local progress, still = false, {}
    for _, it in ipairs(remaining) do
      if (liveFree[it.to] or 0) > 0 then
        table.insert(moves, { kind = 'item', id = it.id, count = it.count,
                              fromPath = it.path, toPath = it.to, bucket = it.bucket })
        liveFree[it.to] = liveFree[it.to] - 1
        liveFree[it.path] = (liveFree[it.path] or 0) + 1
        progress = true
      else
        table.insert(still, it)
      end
    end
    remaining = still
    if #remaining == 0 then break end
    if not progress then
      if parks >= PARK_LIMIT then break end
      -- Deadlock: every remaining item wants a destination that is full. Park an item that is SITTING IN one of
      -- those destinations - that frees the slot the queue is waiting on. Parking the blocked item instead
      -- (what this did before) frees a slot nobody needs, and two such parks trade places pass after pass.
      local blockedDests = {}
      for _, it in ipairs(remaining) do blockedDests[it.to] = true end
      local victim
      for _, cand in ipairs(remaining) do
        if blockedDests[cand.path] then victim = cand break end
      end
      local scratch
      if victim then
        -- somewhere neutral first; in a tight inventory every bag with room is somebody's destination, so fall
        -- back to one of those rather than give up (never a bag the queue is waiting on)
        for _, path in ipairs(order) do
          if path ~= victim.path and path ~= victim.to and (liveFree[path] or 0) > 0
             and not blockedDests[path] and not destBucket[path] then
            scratch = path break
          end
        end
        if not scratch then
          for _, path in ipairs(order) do
            if path ~= victim.path and path ~= victim.to and (liveFree[path] or 0) > 0
               and not blockedDests[path] then
              scratch = path break
            end
          end
        end
      end
      if not victim or not scratch then break end
      table.insert(moves, { kind = 'item', id = victim.id, count = victim.count,
                            fromPath = victim.path, toPath = scratch, bucket = victim.bucket })
      liveFree[scratch] = liveFree[scratch] - 1
      liveFree[victim.path] = (liveFree[victim.path] or 0) + 1
      victim.path = scratch
      parks = parks + 1
    end
  end
  info.blocked = #remaining

  -- ---- 6. gather the still-spare empty bags so they can be dropped -------------------------------
  -- Everything spare ends up in ONE place, under the loot bag. A spare bag that is already somewhere in that
  -- subtree counts as gathered: without this the empties inside a full loot bag get shuffled between each
  -- other, a different one is picked each pass, and the plan never reaches zero.
  local gatherRoot
  if opts.gatherBucket and home[opts.gatherBucket] then
    gatherRoot = home[opts.gatherBucket]          -- the user named a bucket for bags: empties live there
  elseif opts.lootBucket and home[opts.lootBucket] then
    gatherRoot = home[opts.lootBucket]
  end
  if not gatherRoot then
    for _, path in ipairs(order) do
      if isTop(path) and not owner[path] and not spareTaken[path] then gatherRoot = path break end
    end
  end
  local collector = gatherRoot
  if collector and (liveFree[collector] or 0) <= 0 then
    -- the loot bag is full: gather into an empty bag already inside it, which costs no loot capacity
    for _, sp in ipairs(subs[collector] or {}) do
      if #((bags[sp] or {}).items or {}) == 0 then collector = sp break end
    end
  end
  if collector then
    spareTaken[collector] = true
    for _, path in ipairs(spare) do
      local gathered = path == gatherRoot or path:find("^" .. gatherRoot .. "/") ~= nil
      -- Only gather an empty bag that is IN THE WAY: squatting in some bucket's storage tree, where it steals
      -- a slot from that bucket's items, or loose in the main backpack, where slots are reserved for bucket
      -- homes. A hoard's other 170 empties are building material, not clutter - hauling them all into one
      -- nested chain costs a move each and never finishes.
      local parentPath = path:match("^(.*)/%d+$")
      local inTheWay = parentPath and (parentPath == "" or destBucket[parentPath] ~= nil)
      if not spareTaken[path] and not gathered and inTheWay
         and not collector:find("^" .. path .. "/") then
        if (liveFree[collector] or 0) > 0 then
          table.insert(bagMoves, { kind = 'bag', fromPath = path, toPath = collector, empties = true })
          liveFree[collector] = liveFree[collector] - 1
          info.emptiesMoved = info.emptiesMoved + 1
        end
      end
    end
  end
  info.collector = collector
  info.owner, info.home, info.dests = owner, home, destsOf
  info.bagMoves, info.roomMoves = bagMoves, roomMoves

  return moves, info, bagMoves, roomMoves
end

-- ---- simulation ------------------------------------------------------------------------------------
-- The planner reads a flat path->bag map, but a bag move relocates a whole subtree and renumbers every path
-- below it. So rebuild the inventory as a real tree, replay the moves on it, and re-derive the paths. Used by
-- the visualizer to show the converged TARGET layout and by the offline convergence test.

function BagPlan.toTree(bags)
  local function node(path, parent)
    local src = bags[path] or { cap = CAP_FALLBACK, items = {} }
    local n = { cap = src.cap or CAP_FALLBACK, name = src.name, id = src.id, orig = path,
                parent = parent, items = {} }
    for idx, e in ipairs(src.items or {}) do
      if e.isContainer then
        local child = node(e.sub or (path .. "/" .. tostring(e.slot or (idx - 1))), n)
        child.id = e.id or child.id
        table.insert(n.items, { bag = child })
      else
        table.insert(n.items, { id = e.id, count = e.count })
      end
    end
    return n
  end
  return node("", nil)
end

-- Where a bag lives RIGHT NOW, walking up the parent links. The scan-time path is the bag's identity; this
-- turns it back into the live path after any number of earlier moves.
function BagPlan.pathOf(node)
  if not node.parent then return "" end
  local slot
  for i, e in ipairs(node.parent.items) do
    if e.bag == node then slot = i - 1 break end
  end
  if not slot then return nil end
  return BagPlan.pathOf(node.parent) .. "/" .. slot
end

function BagPlan.index(root)
  local byOrig = {}
  local function walk(n)
    byOrig[n.orig] = n
    for _, e in ipairs(n.items) do if e.bag then walk(e.bag) end end
  end
  walk(root)
  return byOrig
end

function BagPlan.derive(root)
  local bags, byPath = {}, {}
  local function walk(node, path)
    local entry = { path = path, name = node.name, cap = node.cap or CAP_FALLBACK, id = node.id,
                    orig = node.orig, items = {} }
    for i, e in ipairs(node.items) do
      if e.bag then
        local childPath = path .. "/" .. (i - 1)
        table.insert(entry.items, { id = e.bag.id, count = 1, isContainer = true, sub = childPath, slot = i - 1 })
        walk(e.bag, childPath)
      else
        table.insert(entry.items, { id = e.id, count = e.count or 1, isContainer = false, slot = i - 1 })
      end
    end
    bags[path] = entry
    byPath[path] = node
  end
  walk(root, "")
  return bags, byPath
end

local function simItemMoves(byPath, moves)
  for i, m in ipairs(moves) do
    local src, dst = byPath[m.fromPath], byPath[m.toPath]
    if not src or not dst then return false, ("move %d: %s -> %s missing"):format(i, m.fromPath, m.toPath) end
    local at
    for k, e in ipairs(src.items) do if not e.bag and e.id == m.id and e.count == m.count then at = k break end end
    if not at then for k, e in ipairs(src.items) do if not e.bag and e.id == m.id then at = k break end end end
    if not at then return false, ("move %d: id %s not in %s"):format(i, tostring(m.id), m.fromPath) end
    if #dst.items >= (dst.cap or CAP_FALLBACK) then return false, ("move %d: %s full"):format(i, m.toPath) end
    table.insert(dst.items, table.remove(src.items, at))
  end
  return true
end

-- highest slot first inside a parent: removing an entry renumbers the ones after it
function BagPlan.sortBagMoves(moves)
  local sorted = {}
  for _, m in ipairs(moves) do table.insert(sorted, m) end
  table.sort(sorted, function(a, b)
    local pa, sa = a.fromPath:match("^(.-)/(%d+)$")
    local pb, sb = b.fromPath:match("^(.-)/(%d+)$")
    if pa ~= pb then return (pa or "") < (pb or "") end
    return tonumber(sa or 0) > tonumber(sb or 0)
  end)
  return sorted
end

local function simBagMoves(byPath, moves)
  local sorted = BagPlan.sortBagMoves(moves)
  for i, m in ipairs(sorted) do
    local parentPath, slot = m.fromPath:match("^(.-)/(%d+)$")
    local parent, dst = byPath[parentPath], byPath[m.toPath]
    if not parent or not dst then return false, ("bag %d: %s -> %s missing"):format(i, m.fromPath, m.toPath) end
    local e = parent.items[tonumber(slot) + 1]
    if not e or not e.bag then return false, ("bag %d: no bag at %s"):format(i, m.fromPath) end
    if #dst.items >= (dst.cap or CAP_FALLBACK) then return false, ("bag %d: %s full"):format(i, m.toPath) end
    table.remove(parent.items, tonumber(slot) + 1)
    table.insert(dst.items, e)
  end
  return true
end

-- One Apply press: bounded passes, each = free slots -> place bags -> re-derive/re-plan -> sort items.
-- Returns the final flat tree plus a report { passes, history, remaining, err, info }.
function BagPlan.simulate(bags, bucketOf, maxPasses, opts)
  maxPasses = maxPasses or 3
  local root = BagPlan.toTree(bags)
  local history, passes, err = {}, 0, nil
  local applied = { room = 0, bag = 0, item = 0 }
  for _ = 1, maxPasses do
    local flat, byPath = BagPlan.derive(root)
    local moves, _, bagMoves, roomMoves = BagPlan.build(flat, bucketOf, opts)
    table.insert(history, #moves + #bagMoves + #roomMoves)
    if history[#history] == 0 then break end
    passes = passes + 1
    local ok, e2 = simItemMoves(byPath, roomMoves)
    if not ok then err = "roomMoves: " .. e2 break end
    applied.room = applied.room + #roomMoves
    ok, e2 = simBagMoves(byPath, bagMoves)
    if not ok then err = "bagMoves: " .. e2 break end
    applied.bag = applied.bag + #bagMoves
    -- the bag moves changed the paths, so the item moves come from a fresh plan: those count too
    local flat2, byPath2 = BagPlan.derive(root)
    local itemMoves = BagPlan.build(flat2, bucketOf, opts)
    ok, e2 = simItemMoves(byPath2, itemMoves)
    if not ok then err = "itemMoves: " .. e2 break end
    applied.item = applied.item + #itemMoves
  end
  local flat = BagPlan.derive(root)
  local moves, info, bagMoves, roomMoves = BagPlan.build(flat, bucketOf, opts)
  local left = #moves + #bagMoves + #roomMoves
  if history[#history] ~= 0 then table.insert(history, left) end
  applied.total = applied.room + applied.bag + applied.item
  return flat, { passes = passes, history = history, remaining = left, err = err, info = info, moves = applied }
end

-- ---- one plan, start to finish -------------------------------------------------------------------
-- Every move is addressed by the path a bag had AT SCAN TIME, which never changes. Live paths do: pulling one
-- item out of a bag renumbers every slot after it, and moving a bag renumbers everything below it - which is
-- why a plan built against live paths goes stale by its third move and needed a rescan per pass.
--
-- The executor replays this list against the same structural model, so it can turn each identity back into a
-- live path at the moment it needs it. One scan, one stream of moves.
function BagPlan.fullPlan(bags, bucketOf, maxPasses, opts)
  maxPasses = maxPasses or 8
  local root = BagPlan.toTree(bags)
  local out, err, rounds = {}, nil, 0

  local function record(kind, m, byPath)
    local src, dst = byPath[m.fromPath], byPath[m.toPath]
    if not src or not dst then return false end
    table.insert(out, { kind = kind, fromOrig = src.orig, toOrig = dst.orig, id = m.id, count = m.count,
                        bucket = m.bucket, whole = m.whole, empties = m.empties, promote = m.promote })
    return true
  end

  for _ = 1, maxPasses do
    local flat, byPath = BagPlan.derive(root)
    local moves, _, bagMoves, roomMoves = BagPlan.build(flat, bucketOf, opts)
    if #moves + #bagMoves + #roomMoves == 0 then break end
    rounds = rounds + 1

    for _, m in ipairs(roomMoves) do record('item', m, byPath) end
    local ok, e = simItemMoves(byPath, roomMoves)
    if not ok then err = "roomMoves: " .. e break end

    local sorted = BagPlan.sortBagMoves(bagMoves)
    for _, m in ipairs(sorted) do record('bag', m, byPath) end
    ok, e = simBagMoves(byPath, sorted)
    if not ok then err = "bagMoves: " .. e break end

    -- the bag moves changed the paths, so the item moves come from a fresh plan of the new structure
    local flat2, byPath2 = BagPlan.derive(root)
    local itemMoves = BagPlan.build(flat2, bucketOf, opts)
    for _, m in ipairs(itemMoves) do record('item', m, byPath2) end
    ok, e = simItemMoves(byPath2, itemMoves)
    if not ok then err = "itemMoves: " .. e break end
  end

  local flat = BagPlan.derive(root)
  local moves, info, bagMoves, roomMoves = BagPlan.build(flat, bucketOf, opts)
  return out, { rounds = rounds, remaining = #moves + #bagMoves + #roomMoves, err = err, info = info }
end

-- ---- consolidating branch bags -------------------------------------------------------------------
-- A bag holding only sub-bags with room to spare is a backpack the job does not need, and a carried backpack
-- costs 18 oz whether it holds anything or not. This packs those sub-bags into as few branches as possible and
-- returns the emptied bags, which are then spares to drop.
--
-- Deliberately NOT part of BagPlan.build: the target layout is about where items live, and mixing an optional
-- tidy-up into it broke convergence - every pass found another merge to plan.
function BagPlan.consolidate(bags, maxMoves)
  maxMoves = (type(maxMoves) == 'number' and maxMoves) or 60   -- derive() returns two values; guard against the second landing here
  local root = BagPlan.toTree(bags)
  local out, freed = {}, {}

  local function branches(flat)
    local list = {}
    for path, node in pairs(flat) do
      if path ~= "" then
        local subs, items = 0, 0
        for _, e in ipairs(node.items) do
          if e.isContainer then subs = subs + 1 else items = items + 1 end
        end
        if subs > 0 and items == 0 and subs < (node.cap or CAP_FALLBACK) then
          table.insert(list, { path = path, subs = subs, free = (node.cap or CAP_FALLBACK) - subs })
        end
      end
    end
    table.sort(list, function(a, b)
      if a.subs ~= b.subs then return a.subs > b.subs end
      return a.path < b.path
    end)
    return list
  end

  for _ = 1, maxMoves do
    local flat, byPath = BagPlan.derive(root)
    local list = branches(flat)
    if #list < 2 then break end
    local target = list[1]
    local donor
    for i = #list, 2, -1 do
      local cand = list[i]
      -- Partial merges count: requiring the whole donor to fit stalled as soon as the target had three slots
      -- left while every donor held five. Direction is fixed - toward the fuller bag, or toward the earlier
      -- path when they are equally full - so a pair can never trade sub-bags back and forth.
      if cand.path ~= target.path
         and not target.path:find("^" .. cand.path .. "/")
         and not cand.path:find("^" .. target.path .. "/")
         and (cand.subs < target.subs or (cand.subs == target.subs and cand.path > target.path)) then
        donor = cand break
      end
    end
    if not donor then break end

    -- move the donor's sub-bags across, highest slot first so the earlier ones keep their slots
    local kids = {}
    for i, e in ipairs(byPath[donor.path].items) do
      if e.bag then table.insert(kids, { slot = i - 1, node = e.bag }) end
    end
    table.sort(kids, function(a, b) return a.slot > b.slot end)
    local moved = 0
    for _, k in ipairs(kids) do
      local srcPath = BagPlan.pathOf(k.node)
      local dst = byPath[target.path]
      if srcPath and dst and #dst.items < (dst.cap or CAP_FALLBACK) then
        table.insert(out, { kind = 'bag', fromOrig = k.node.orig, toOrig = dst.orig, consolidate = true })
        local parent = k.node.parent
        for idx, e in ipairs(parent.items) do
          if e.bag == k.node then table.remove(parent.items, idx) break end
        end
        table.insert(dst.items, { bag = k.node })
        k.node.parent = dst
        moved = moved + 1
      end
    end
    if moved == 0 then break end
    table.insert(freed, donor.path)
    if #out >= maxMoves then break end
  end

  return out, { freed = #freed, moves = #out }
end
