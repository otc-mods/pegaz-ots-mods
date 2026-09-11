-- Move executor. Holds only the destinations open and streams the source bags through one at a time, so the
-- number of simultaneously open containers stays near (1 main + one bag per bucket + 1 sub + tree depth) no
-- matter how many bags exist. Opening everything at once only ever worked for a handful of bags.
--
-- Two kinds of move:
--   kind == 'item'  move an item out of fromPath into toPath
--   kind == 'bag'   move the whole (empty) backpack AT fromPath into toPath; the item to grab lives in the
--                   PARENT of fromPath, at the slot the path ends with
BagApply = {}

BagApply.debug = false       -- modules.game_bag_organizer.setDebug(true) traces every open
local OPEN_CAP = 13          -- server allows ~15 containers; leave headroom
local OPEN_TIMEOUT = 1500

-- shared with main.lua's drop routine: a path's parent plus the slot it sits in
function BagApply.parentOf(path)
  local parent, slot = path:match("^(.-)/(%d+)$")
  if not parent then return nil, nil end
  return parent, tonumber(slot)
end
local parentOf = BagApply.parentOf

local function minimizeOpen()
  local root = g_ui.getRootWidget()
  for cid in pairs(g_game.getContainers()) do
    local w = root:recursiveGetChildById('container' .. cid)
    if w and w.minimize then pcall(function() w:minimize() end) end
  end
end

function BagApply.newOpener(keep)
  local self = { open = {}, used = {}, keep = {}, protected = {}, tick = 0 }
  for _, p in ipairs(keep or {}) do self.keep[p] = true end

  -- Paths in active use. Eviction used to consider only the path being opened, so opening a destination could
  -- close the very source bag we were moving items out of - reported back as "bag could not open" and leaving
  -- the run half done. Reference-counted, because a source and a destination can be protected at once.
  function self.protect(path)
    if path then self.protected[path] = (self.protected[path] or 0) + 1 end
  end
  function self.unprotect(path)
    if path and self.protected[path] then
      self.protected[path] = self.protected[path] - 1
      if self.protected[path] <= 0 then self.protected[path] = nil end
    end
  end

  local function rootContainer()
    for _, c in pairs(g_game.getContainers()) do if not c:hasParent() then return c end end
  end

  local function count()
    local n = 0
    for _ in pairs(self.open) do n = n + 1 end
    return n
  end

  -- a path is needed if it is kept, protected, or an ancestor of something kept or protected
  local function isNeeded(path, extra)
    if path == "" or self.keep[path] then return true end
    if self.protected[path] then return true end
    if extra and (path == extra or extra:find("^" .. path .. "/")) then return true end
    for p in pairs(self.keep) do if p:find("^" .. path .. "/") then return true end end
    for p in pairs(self.protected) do if p:find("^" .. path .. "/") then return true end end
    return false
  end

  -- close the least recently used leaf we are allowed to drop
  local function evict(protect)
    while count() > OPEN_CAP do
      local victim, oldest
      for path, c in pairs(self.open) do
        if not isNeeded(path, protect) then
          local isPrefix = false
          for other in pairs(self.open) do
            if other ~= path and other:find("^" .. path .. "/") then isPrefix = true break end
          end
          if not isPrefix and (not oldest or (self.used[path] or 0) < oldest) then
            victim, oldest = path, self.used[path] or 0
          end
        end
      end
      if not victim then
        if BagApply.debug then print("[apply] evict: nothing droppable, " .. count() .. " open") end
        return
      end
      local c = self.open[victim]
      if c and not c:isClosed() then pcall(function() g_game.close(c) end) end
      self.open[victim], self.used[victim] = nil, nil
    end
  end

  local function containerIds()
    local set = {}
    for cid in pairs(g_game.getContainers()) do set[cid] = true end
    return set
  end

  local function openStep(parentContainer, slot, cb)
    local it = parentContainer:getItems()[slot + 1]
    if not it or not it:isContainer() then return cb(nil) end
    local wantId = it:getId()
    local before = containerIds()
    local done, conn, timer = false, nil, nil
    local function finish(c)
      if done then return end
      done = true
      if timer then removeEvent(timer) timer = nil end
      if conn then disconnect(Container, conn) conn = nil end
      if BagApply.debug then
        print(string.format("[apply] open slot %d of a %d-item bag -> %s",
          slot, parentContainer:getItemsCount(), c and "ok" or "FAILED"))
      end
      cb(c)
    end
    conn = { onOpen = function(c)
      local ci = c:getContainerItem()
      if ci and c:hasParent() and ci:getId() == wantId then minimizeOpen() finish(c) end
    end }
    connect(Container, conn)
    timer = scheduleEvent(function()
      if conn then disconnect(Container, conn) conn = nil end
      -- The client silently reuses a window when the container is already open, so onOpen never fires. Adopt a
      -- container that appeared while we were waiting - that is the one it handed us.
      local fresh
      for cid, c in pairs(g_game.getContainers()) do
        if not before[cid] then fresh = c break end
      end
      if fresh then minimizeOpen() end
      finish(fresh)
    end, OPEN_TIMEOUT)
    minimizeOpen()
    g_game.open(it, nil)
  end

  -- ensure `path` is open, opening ancestors as needed; cb(container) or cb(nil)
  function self.ensure(path, cb)
    self.tick = self.tick + 1
    if path == "" then
      local r = rootContainer()
      if r then self.open[""] = r self.used[""] = self.tick end
      return cb(r)
    end
    local have = self.open[path]
    if have and not have:isClosed() then
      self.used[path] = self.tick
      return cb(have)
    end
    local parentPath, slot = parentOf(path)
    if not parentPath then
      if BagApply.debug then print("[apply] ensure " .. path .. " -> no parent path") end
      return cb(nil)
    end
    self.ensure(parentPath, function(parent)
      if not parent or parent:isClosed() then
        if BagApply.debug then print("[apply] ensure " .. path .. " -> parent " .. parentPath .. " not open") end
        return cb(nil)
      end
      if BagApply.debug then
        print(string.format("[apply] ensure %s: parent %s has %d item(s), want slot %s",
          path, parentPath == "" and "(main)" or parentPath, parent:getItemsCount(), tostring(slot)))
      end
      evict(path)
      -- Retries: a container the client silently reused fires no onOpen, and a bag that just moved needs a
      -- moment before it opens through its new slot. A third attempt clears the decks first - a deep bag needs
      -- its whole ancestor chain open, and with the server's ~15 container limit there may simply be no room.
      local attempt = 0
      local function try()
        attempt = attempt + 1
        openStep(parent, slot, function(c)
          if not c and attempt == 1 and not parent:isClosed() then
            return scheduleEvent(try, 500)
          end
          if not c and attempt == 2 then
            for path2, c2 in pairs(self.open) do
              if path2 ~= "" and not isNeeded(path2, path) and c2 and not c2:isClosed() then
                pcall(function() g_game.close(c2) end)
                self.open[path2] = nil
              end
            end
            return scheduleEvent(function()
              if parent:isClosed() then return cb(nil) end
              try()
            end, 600)
          end
          if c then
            self.open[path] = c
            self.used[path] = self.tick
          end
          cb(c)
        end)
      end
      try()
    end)
  end

  function self.get(path) return self.open[path] end

  function self.closeAll()
    for path, c in pairs(self.open) do
      if path ~= "" and c and not c:isClosed() then pcall(function() g_game.close(c) end) end
    end
    self.open, self.used = {}, {}
  end

  function self.openCount() return count() end
  return self
end

-- opts: moveMs, keep (paths held open), onStatus(text, done, total), onDone(summary), isStopped()
function BagApply.execute(moves, opts)
  opts = opts or {}
  local moveMs = opts.moveMs or 220

  -- Clean slate. The scan leaves its last chain open and a fresh opener knows nothing about those windows, so
  -- the client reuses them instead of firing onOpen - which reads to us as "could not open". Close everything
  -- except the main backpack so every open from here is genuinely new.
  local closed = 0
  for _, c in pairs(g_game.getContainers()) do
    if c:hasParent() then pcall(function() g_game.close(c) end) closed = closed + 1 end
  end

  local opener = BagApply.newOpener(opts.keep)
  local total = #moves
  local done, moved = 0, 0
  local skipped = { noRoom = 0, notOpen = 0, gone = 0, paths = {} }
  local function noteSkip(path)          -- which bag refused to open, so a failure is diagnosable
    if #skipped.paths < 8 then table.insert(skipped.paths, tostring(path)) end
  end

  -- source-major: every source bag is opened once, then everything that leaves it goes at once
  local bySource, sourceOrder = {}, {}
  for _, m in ipairs(moves) do
    local key = (m.kind == 'bag') and (parentOf(m.fromPath) or "") or m.fromPath
    if not bySource[key] then bySource[key] = {} table.insert(sourceOrder, key) end
    table.insert(bySource[key], m)
  end
  -- DEEPEST source first, the main backpack last. Taking a loose item out of a container renumbers every slot
  -- after it, and those slots include the bag entries that other moves use as their path - so emptying a shallow
  -- container first makes every deeper path in this batch point at the wrong bag.
  table.sort(sourceOrder, function(a, b)
    local _, da = a:gsub("/", "")
    local _, db = b:gsub("/", "")
    if da ~= db then return da > db end
    return a < b
  end)

  -- Taking a bag out of a parent renumbers every slot after it, so a recorded slot goes stale as soon as an
  -- earlier one is removed. Highest slot first keeps the remaining slots valid.
  local function slotOf(path)
    local _, sl = parentOf(path)
    return sl or 0
  end
  for _, list in pairs(bySource) do
    table.sort(list, function(x, y)
      local xb, yb = x.kind == 'bag', y.kind == 'bag'
      if xb ~= yb then return xb end
      if xb and yb then return slotOf(x.fromPath) > slotOf(y.fromPath) end
      return false
    end)
  end

  -- Destinations are opened BEFORE the first move and stay protected: once a container is open its identity
  -- survives its parent renumbering, but a stale PATH does not, and re-resolving one mid-batch is what made
  -- apply chase bags that had shifted slot.
  local PREOPEN_CAP = 10
  local destUse, destList = {}, {}
  for _, m in ipairs(moves) do
    local d = m.toPath
    if d and d ~= "" then
      if not destUse[d] then destUse[d] = 0 table.insert(destList, d) end
      destUse[d] = destUse[d] + 1
    end
  end
  table.sort(destList, function(a, b) return destUse[a] > destUse[b] end)
  while #destList > PREOPEN_CAP do table.remove(destList) end
  table.sort(destList, function(a, b)                     -- ancestors before children
    local _, da = a:gsub("/", "")
    local _, db = b:gsub("/", "")
    if da ~= db then return da < db end
    return a < b
  end)

  local function status(extra)
    if not opts.onStatus then return end
    local parts = {}
    if skipped.noRoom > 0 then table.insert(parts, skipped.noRoom .. " no room") end
    if skipped.notOpen > 0 then table.insert(parts, skipped.notOpen .. " bag not open") end
    if skipped.gone > 0 then table.insert(parts, skipped.gone .. " gone") end
    opts.onStatus(extra, moved, total, table.concat(parts, ", "), opener.openCount())
  end

  local function finish(reason)
    opener.closeAll()
    if opts.onDone then opts.onDone({ moved = moved, total = total, skipped = skipped, reason = reason }) end
  end

  local si, mi, current, currentKey = 0, 0, nil, nil
  local nextSource, nextMove

  nextMove = function()
    if opts.isStopped and opts.isStopped() then return finish("stopped") end
    mi = mi + 1
    local m = current and current[mi]
    if not m then return scheduleEvent(nextSource, 30) end
    done = done + 1

    if m.kind == 'bag' then
      local parentPath, slot = parentOf(m.fromPath)
      opener.protect(m.toPath)
      opener.ensure(m.toPath, function(dst)
        local parent = opener.get(parentPath or "")
        opener.unprotect(m.toPath)
        if not parent or not dst or parent:isClosed() or dst:isClosed() then
          if BagApply.debug then
            print(string.format("[apply] BAG %s -> %s FAILED: parent(%s)=%s dst=%s",
              m.fromPath, m.toPath, tostring(parentPath),
              parent and (parent:isClosed() and "closed" or "ok") or "nil",
              dst and (dst:isClosed() and "closed" or "ok") or "nil"))
          end
          skipped.notOpen = skipped.notOpen + 1 noteSkip(m.toPath) status() return scheduleEvent(nextMove, 30)
        end
        local it = parent:getItems()[slot + 1]
        if not it or not it:isContainer() then
          skipped.gone = skipped.gone + 1 status() return scheduleEvent(nextMove, 30)
        end
        if dst:getItemsCount() >= dst:getCapacity() then
          skipped.noRoom = skipped.noRoom + 1 status() return scheduleEvent(nextMove, 30)
        end
        g_game.move(it, dst:getSlotPosition(dst:getItemsCount()), 1)
        moved = moved + 1
        status()
        scheduleEvent(nextMove, moveMs)
      end)
      return
    end

    opener.ensure(m.toPath, function(dst)
      if not dst or dst:isClosed() then
        if BagApply.debug then
          print(string.format("[apply] ITEM %s -> %s FAILED: dest %s",
            m.fromPath, m.toPath, dst and "closed" or "nil"))
        end
        skipped.notOpen = skipped.notOpen + 1 noteSkip(m.toPath) status() return scheduleEvent(nextMove, 30)
      end
      opener.protect(m.toPath)
      opener.ensure(m.fromPath, function(src)
        if not src or src:isClosed() then
          if BagApply.debug then
            print(string.format("[apply] ITEM %s -> %s FAILED: source %s",
              m.fromPath, m.toPath, src and "closed" or "nil"))
          end
          opener.unprotect(m.toPath)
          skipped.notOpen = skipped.notOpen + 1 noteSkip(m.toPath) status() return scheduleEvent(nextMove, 30)
        end
        local it
        for _, x in ipairs(src:getItems()) do if x:getId() == m.id then it = x break end end
        if not it then
          opener.unprotect(m.toPath)
          skipped.gone = skipped.gone + 1 status() return scheduleEvent(nextMove, 30)
        end
      -- merge onto a partial stack of the same item; else the first free slot
      local slot
      for si2, x in ipairs(dst:getItems()) do
        if x:getId() == m.id and x:isStackable() and x:getCount() < 100 then slot = si2 - 1 break end
      end
      if not slot and dst:getItemsCount() < dst:getCapacity() then slot = dst:getItemsCount() end
        if not slot then
          opener.unprotect(m.toPath)
          skipped.noRoom = skipped.noRoom + 1 status() return scheduleEvent(nextMove, 30)
        end
        g_game.move(it, dst:getSlotPosition(slot), it:getCount())
        opener.unprotect(m.toPath)
        moved = moved + 1
        status()
        scheduleEvent(nextMove, moveMs)
      end)
    end)
  end

  nextSource = function()
    if opts.isStopped and opts.isStopped() then return finish("stopped") end
    if currentKey then opener.unprotect(currentKey) currentKey = nil end
    si = si + 1
    local key = sourceOrder[si]
    if not key then return finish("done") end
    currentKey = key
    opener.protect(key)
    current, mi = bySource[key], 0
    status(("opening bag %d/%d..."):format(si, #sourceOrder))
    opener.ensure(key, function(c)
      if not c then
        skipped.notOpen = skipped.notOpen + #current
        noteSkip(key == "" and "(main)" or key)
        status()
        return scheduleEvent(nextSource, 30)
      end
      nextMove()
    end)
  end

  if total == 0 then return finish("nothing to do") end
  -- Closing is a network action. Starting immediately means the client can hand back the same window on a
  -- reopen, and then onOpen never fires - which surfaces as "bag could not open".
  local function preopenDests(i, cb)
    local path = destList[i]
    if not path then return cb() end
    opener.ensure(path, function(c)
      if c then opener.protect(path) elseif BagApply.debug then print("[apply] preopen " .. path .. " FAILED") end
      scheduleEvent(function() preopenDests(i + 1, cb) end, 30)
    end)
  end

  if closed > 0 then
    if BagApply.debug then print("[apply] closed " .. closed .. " container(s), settling") end
    scheduleEvent(function() preopenDests(1, nextSource) end, 400)
  else
    preopenDests(1, nextSource)
  end
end

-- ---- single-plan executor ------------------------------------------------------------------------
-- Replays BagPlan.fullPlan's list. Each move names its bags by the path they had AT SCAN TIME; this keeps the
-- same structural model the planner used, so it can turn an identity back into the live path at the moment it
-- needs it. That is what removes the rescan between passes: 400 bags cost one scan, not one per pass.
function BagApply.executePlan(list, scanTree, opts)
  opts = opts or {}
  local moveMs = opts.moveMs or 220
  local total = #list

  local closed = 0
  for _, c in pairs(g_game.getContainers()) do
    if c:hasParent() then pcall(function() g_game.close(c) end) closed = closed + 1 end
  end

  local opener = BagApply.newOpener(opts.keep)
  local root = BagPlan.toTree(scanTree)
  local byOrig = BagPlan.index(root)
  local i, moved = 0, 0
  local skipped = { noRoom = 0, notOpen = 0, gone = 0, paths = {} }
  -- A skipped move invalidates every later move that assumed it happened, so stop consuming the list after a
  -- few and hand the model back: the caller re-plans from it (offline, no rescan) and carries on from reality.
  -- Stalling early wastes the moves further down the list that were still valid, so allow a proportional
  -- number of refusals before handing the model back for a re-plan.
  local STALL_AFTER = opts.stallAfter or math.max(30, math.floor(total / 8))
  -- every refusal, with the live state that caused it: the bridge cannot capture prints from a callback
  local skipLog = {}
  local function flushSkipLog()
    pcall(function() g_resources.writeFileContents('/bagorg_skips.txt', table.concat(skipLog, "\n")) end)
  end
  local stalls = 0
  local function noteSkip(p)
    if #skipped.paths < 8 then table.insert(skipped.paths, tostring(p)) end
  end
  local finished = false
  local watchdog

  local function finish(reason)
    if finished then return end
    finished = true
    if watchdog then removeEvent(watchdog) watchdog = nil end
    opener.closeAll()
    flushSkipLog()
    if opts.onDone then
      -- The model mirrors every accepted move, and a move that failed changed nothing - so the model is an
      -- accurate picture of the inventory either way, and the caller can re-plan from it without re-reading.
      opts.onDone({ moved = moved, total = total, skipped = skipped, reason = reason,
                    tree = BagPlan.derive(root), stalled = reason == "stalled" })
    end
  end

  local function status()
    if not opts.onStatus then return end
    local parts = {}
    if skipped.noRoom > 0 then table.insert(parts, skipped.noRoom .. " no room") end
    if skipped.notOpen > 0 then table.insert(parts, skipped.notOpen .. " could not open") end
    if skipped.gone > 0 then table.insert(parts, skipped.gone .. " gone") end
    opts.onStatus(nil, moved, total, table.concat(parts, ", "), opener.openCount())
  end

  -- keep the model in step with reality: only applied for moves the server accepted
  local function applyToModel(m, src, dst)
    if m.kind == 'bag' then
      local parent = src.parent
      if parent then
        for k, e in ipairs(parent.items) do if e.bag == src then table.remove(parent.items, k) break end end
      end
      table.insert(dst.items, { bag = src })
      src.parent = dst
    else
      local at
      for k, e in ipairs(src.items) do
        if not e.bag and e.id == m.id and (e.count or 1) == (m.count or 1) then at = k break end
      end
      if not at then
        for k, e in ipairs(src.items) do if not e.bag and e.id == m.id then at = k break end end
      end
      if at then table.insert(dst.items, table.remove(src.items, at)) end
    end
  end

  -- A watchdog. Any single step that never calls back - a container open that neither succeeds nor times out -
  -- would otherwise leave the run half done with the buttons disabled and no way to tell what happened.
  local lastSeen, lastAt = -1, g_clock.millis()
  watchdog = cycleEvent(function()
    if finished then removeEvent(watchdog) return end
    local progress = moved + skipped.noRoom + skipped.notOpen + skipped.gone
    if progress ~= lastSeen then
      lastSeen = progress
      lastAt = g_clock.millis()
    elseif g_clock.millis() - lastAt > 20000 then
      removeEvent(watchdog)
      table.insert(skipLog, string.format("stuck after %d of %d moves - giving up on this round", i, total))
      flushSkipLog()
      finish("stuck")
    end
  end, 2000)

  local step
  step = function()
    if opts.isStopped and opts.isStopped() then return finish("stopped") end
    i = i + 1
    local m = list[i]
    if not m then return finish("done") end

    local function skip(what, path, detail)
      skipped[what] = skipped[what] + 1
      if path then noteSkip(path) end
      stalls = stalls + 1
      table.insert(skipLog, string.format("%-8s %s%s", what, tostring(path), detail and ("  " .. detail) or ""))
      flushSkipLog()
      status()
      if stalls >= STALL_AFTER then return finish("stalled") end
      return scheduleEvent(step, 10)
    end

    local src, dst = byOrig[m.fromOrig], byOrig[m.toOrig]
    if not src or not dst then return skip('gone') end
    local srcPath, dstPath = BagPlan.pathOf(src), BagPlan.pathOf(dst)
    if not srcPath or not dstPath then return skip('gone') end

    -- a bag move grabs the bag out of its PARENT; an item move reads the source bag itself
    local openPath = srcPath
    local slot
    if m.kind == 'bag' then
      local p, sl = parentOf(srcPath)
      openPath, slot = p or "", sl
    end

    opener.protect(dstPath)
    opener.ensure(dstPath, function(dstC)
      if not dstC or dstC:isClosed() then
        opener.unprotect(dstPath)
        return skip('notOpen', dstPath, string.format("destination; open=%d", opener.openCount()))
      end
      opener.ensure(openPath, function(srcC)
        opener.unprotect(dstPath)
        if not srcC or srcC:isClosed() then
          return skip('notOpen', openPath, string.format("source for a %s move; open=%d, dst=%s",
            m.kind, opener.openCount(), dstPath))
        end
        if dstC:getItemsCount() >= dstC:getCapacity() then
          return skip('noRoom', dstPath, string.format("live %d/%d, the plan expected %d; move %d/%d (%s)",
            dstC:getItemsCount(), dstC:getCapacity(), #dst.items, i, total, m.kind))
        end
        local thing
        if m.kind == 'bag' then
          thing = srcC:getItems()[(slot or 0) + 1]
          if not thing or not thing:isContainer() then
            return skip('gone', srcPath, string.format("no bag at slot %s of %s (%d items there)",
              tostring(slot), openPath, srcC:getItemsCount()))
          end
        else
          for _, it in ipairs(srcC:getItems()) do
            if it:getId() == m.id and not it:isContainer() then
              if it:getCount() == (m.count or 1) then thing = it break end
              thing = thing or it
            end
          end
          if not thing then
            return skip('gone', srcPath, string.format("no item %s in %s (%d items there)",
              tostring(m.id), srcPath, srcC:getItemsCount()))
          end
        end
        g_game.move(thing, dstC:getSlotPosition(dstC:getItemsCount()),
                    m.kind == 'bag' and 1 or (m.count or 1))
        applyToModel(m, src, dst)
        moved = moved + 1
        status()
        scheduleEvent(step, moveMs)
      end)
    end)
  end

  if total == 0 then return finish("nothing to do") end
  if closed > 0 then scheduleEvent(step, 400) else step() end
end
