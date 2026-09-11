-- Bag tree reader (v3): depth-first walk that always opens a bag through a LIVE path, never a stored item
-- reference (those go stale once other bags open, which made every nested bag time out). It keeps the current
-- root->...->node chain open and reuses it for siblings, so a flat tree costs ~1 extra open per bag. Read-only.
BagScan = {}

local OPEN_TIMEOUT = 1200
BagScanDebug = false
local function dbg(line)
  if not BagScanDebug then return end
  print(line)
  pcall(function()
    local prev = g_resources.fileExists("/bagscan.log") and g_resources.readFileContents("/bagscan.log") or ""
    g_resources.writeFileContents("/bagscan.log", prev .. line .. "\n")
  end)
end

-- Move a cached subtree from one path to another. Adding an item to a bag renumbers every slot after it, so
-- its sub-bags' paths shift even though nothing inside them changed - remapping keeps them out of the re-read.
local function remapSubtrees(nodes, renames)
  local moved = {}
  for _, pr in ipairs(renames) do
    local oldP, newP = pr[1], pr[2]
    for k, v in pairs(nodes) do
      if k == oldP or k:find("^" .. oldP .. "/") then
        moved[newP .. k:sub(#oldP + 1)] = v
        nodes[k] = nil
      end
    end
  end
  for k, v in pairs(moved) do
    v.path = k
    for _, e in ipairs(v.items or {}) do
      if e.isContainer then e.sub = k .. "/" .. tostring(e.slot) end
    end
    nodes[k] = v
  end
end

local function dropSubtree(nodes, root)
  for k in pairs(nodes) do
    if k == root or k:find("^" .. root .. "/") then nodes[k] = nil end
  end
end

local function childPaths(node)
  local out = {}
  for _, e in ipairs(node.items or {}) do
    if e.isContainer then table.insert(out, e.sub) end
  end
  return out
end

-- The sub-bags in order, by item id. Remapping cached subtrees onto new slots is only safe while this
-- signature is unchanged: matching counts alone would silently attach the wrong subtree to the wrong bag once
-- backpacks have been moved around, and every later move would then aim at a bag that is not there.
local function childSignature(node)
  local out = {}
  for _, e in ipairs(node.items or {}) do
    if e.isContainer then table.insert(out, tostring(e.id or 0)) end
  end
  return table.concat(out, ",")
end

BagScan.stats = nil
-- opts.into / opts.paths turn this into an incremental re-read: only the listed bags, plus any bag whose slot
-- layout actually changed, get opened; the rest is carried over from the cached tree.
function BagScan.run(rootContainer, onDone, onProgress, opts)
  opts = opts or {}
  local refresh = opts.into ~= nil
  local stats = { opens = 0, closes = 0, bags = 0, timeouts = 0, minimize = 0, start = g_clock.millis(),
                  refresh = refresh }
  BagScan.stats = stats
  local nodes = opts.into or {}          -- path -> { path, name, cap, items[] }
  local stack = {}          -- DFS: list of paths still to visit (leaves pushed as discovered)
  local chain = {}          -- currently-open chain: { {path, container}, ... } from root down
  local done = false
  local conn, timeout, safety
  local cancelled = false

  local function rootByNoParent()
    for _, c in pairs(g_game.getContainers()) do if not c:hasParent() then return c end end
  end

  local function minimizeOpen()
    stats.minimize = stats.minimize + 1
    local mt0 = g_clock.millis()
    local root = g_ui.getRootWidget()
    for cid in pairs(g_game.getContainers()) do
      local w = root:recursiveGetChildById('container' .. cid)
      if w and w.minimize then pcall(function() w:minimize() end) end
    end
    stats.minimizeMs = (stats.minimizeMs or 0) + (g_clock.millis() - mt0)
  end

  -- ensure the chain is open down to `path`, then call cb(container). Closes anything below the common prefix.
  local function openTo(path, cb)
    local steps = {}
    if path ~= "" then for seg in path:gmatch("[^/]+") do table.insert(steps, tonumber(seg)) end end
    -- chain[1] is always root
    local root = rootByNoParent()
    if not root then return cb(nil) end
    if #chain == 0 then chain[1] = { path = "", container = root } end
    chain[1].container = root
    -- find how deep the chain already matches the target
    local match = 0   -- number of steps already open (chain index = match+1)
    for i = 1, #steps do
      local want = table.concat({unpack(steps, 1, i)}, "/")
      local entry = chain[i + 1]
      if entry and entry.path == "/" .. want and not entry.container:isClosed() then match = i else break end
    end
    -- close everything below match
    for i = #chain, match + 2, -1 do
      local e = chain[i]
      if e and e.container and not e.container:isClosed() then
        stats.closes = stats.closes + 1
        g_game.close(e.container)
      end
      chain[i] = nil
    end
    -- open the remaining steps one at a time
    local function descend(i)
      if i > #steps then return cb(chain[#steps + 1] and chain[#steps + 1].container) end
      local parent = chain[i].container
      local slot = steps[i]
      local it = parent:getItems()[slot + 1]
      if not it or not it:isContainer() then return cb(nil) end
      local wantId = it:getId()
      local finished = false
      local function got(c)
        if finished then return end
        finished = true
        if stats.openAt then stats.waitMs = (stats.waitMs or 0) + (g_clock.millis() - stats.openAt) end
        if timeout then removeEvent(timeout) timeout = nil end
        if conn then disconnect(Container, conn) conn = nil end
        if not c then return cb(nil) end
        minimizeOpen()   -- collapse windows so a full panel does not drop the next (deeper) open
        local cpath = "/" .. table.concat({unpack(steps, 1, i)}, "/")
        if BagCache and BagCache.noteScan then pcall(function() BagCache.noteScan(c:getId(), cpath) end) end
        chain[i + 1] = { path = cpath, container = c }
        descend(i + 1)
      end
      conn = { onOpen = function(c)
        local ci = c:getContainerItem()
        if ci and c:hasParent() and ci:getId() == wantId then got(c) end
      end }
      connect(Container, conn)
      timeout = scheduleEvent(function()
        stats.timeouts = stats.timeouts + 1
        if conn then disconnect(Container, conn) conn = nil end
        got(nil)
      end, OPEN_TIMEOUT)
      stats.opens = stats.opens + 1
      stats.openAt = g_clock.millis()
      g_game.open(it, nil)
    end
    descend(match + 1)   -- chain[1..match+1] already open; open the next step
  end

  local topSlots, curTopSeen, completedBags = {}, nil, 0
  local function record(path, container)
    local ci = container:getContainerItem()
    local node = { path = path, name = container:getName(), cap = container:getCapacity(),
                   id = ci and ci:getId() or nil, items = {} }
    for slot, it in ipairs(container:getItems()) do
      local e = { id = it:getId(), count = it:getCount(), isContainer = it:isContainer(), slot = slot - 1 }
      node.items[#node.items + 1] = e
      if it:isContainer() then
        e.sub = path .. "/" .. (slot - 1)
        if not refresh then table.insert(stack, e.sub) end
        if path == "" then table.insert(topSlots, slot - 1) end
      end
    end
    local old = nodes[path]
    nodes[path] = node
    stats.bags = stats.bags + 1
    if refresh then
      if old then
        -- keep what did not change: remap children positionally, re-read only genuinely new bags
        local oldKids, newKids = childPaths(old), childPaths(node)
        if #oldKids == #newKids and childSignature(old) == childSignature(node) then
          local renames = {}
          for i = 1, #oldKids do
            if oldKids[i] ~= newKids[i] then table.insert(renames, { oldKids[i], newKids[i] }) end
          end
          if #renames > 0 then
            -- Carry the cached subtrees over to their new slots, then RE-READ each of them. Positional
            -- remapping is a guess: every leaf bag has the same (empty) child signature, so two of them can be
            -- swapped without the signature noticing, and the plan then moves items out of a bag that is
            -- actually empty. Re-reading one level is a handful of opens and makes the guess self-correcting -
            -- a child whose own layout still matches stops the cascade there.
            remapSubtrees(nodes, renames)
            for _, k in ipairs(newKids) do table.insert(stack, k) end
          else
            for _, k in ipairs(newKids) do
              if not nodes[k] then table.insert(stack, k) end
            end
          end
        else
          for _, k in ipairs(oldKids) do dropSubtree(nodes, k) end
          for _, k in ipairs(newKids) do table.insert(stack, k) end
        end
      else
        for _, k in ipairs(childPaths(node)) do
          if not nodes[k] then table.insert(stack, k) end
        end
      end
    end
    local curTop = tonumber((path:match("^/(%d+)")))
    local branchesDone = 0
    if curTop ~= nil then for _, sl in ipairs(topSlots) do if sl > curTop then branchesDone = branchesDone + 1 end end end
    if curTop ~= curTopSeen then completedBags = BagScan.size(nodes) - 1 curTopSeen = curTop end
    if onProgress then
      local pt0 = g_clock.millis()
      onProgress(BagScan.size(nodes), #stack, #topSlots, branchesDone, completedBags)
      stats.progressMs = (stats.progressMs or 0) + (g_clock.millis() - pt0)
    end
  end

  local function finish()
    if done then return end
    done = true
    stats.ms = g_clock.millis() - stats.start
    if conn then disconnect(Container, conn) end
    if timeout then removeEvent(timeout) end
    if safety then removeEvent(safety) end
    onDone(nodes)
  end

  local failed, sweep = {}, 0
  local MAX_SWEEPS = 4
  local step
  step = function()
    if done or cancelled then return end
    local path = table.remove(stack)
    if not path then
      -- a failed open loses its whole subtree; retry the failed paths in another sweep until none remain
      if #failed > 0 and sweep < MAX_SWEEPS then
        sweep = sweep + 1
        dbg("sweep " .. sweep .. ": retrying " .. #failed .. " failed branch(es)")
        for _, fp in ipairs(failed) do table.insert(stack, fp) end
        failed = {}
        return step()
      end
      if #failed > 0 then dbg("gave up on " .. #failed .. " branch(es) after " .. sweep .. " sweeps") end
      return finish()
    end
    openTo(path, function(container)
      if not container then dbg("FAIL '"..path.."' (retry later)") table.insert(failed, path) return step() end
      dbg("read '"..path.."' (total "..(BagScan.size(nodes)+1)..", stack "..#stack..")")
      record(path, container)
      step()
    end)
  end

  BagScan.cancel = function() cancelled = true finish() end

  if BagCache and BagCache.noteScan then pcall(function() BagCache.noteScan(rootContainer:getId(), "") end) end
  if refresh then
    local seeds = {}
    for _, p in ipairs(opts.paths or {}) do if p ~= "" then table.insert(seeds, p) end end
    table.sort(seeds, function(a, b)          -- deepest last: the stack is popped from the end
      local _, da = a:gsub("/", "")
      local _, db = b:gsub("/", "")
      if da ~= db then return da > db end
      return a > b
    end)
    for _, p in ipairs(seeds) do table.insert(stack, p) end
  end
  record("", rootContainer)      -- root: children are queued here on a full scan
  safety = scheduleEvent(function() if not done then finish() end end, 600000)
  step()
end

function BagScan.size(nodes)
  local n = 0
  for _ in pairs(nodes) do n = n + 1 end
  return n
end
