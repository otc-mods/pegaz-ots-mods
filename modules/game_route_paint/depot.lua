-- Depositing loot and taking it back out, done the way the bag organiser does it rather than the way a cavebot
-- function can.
--
-- A function waypoint can only sleep and retry, so it has to guess when a container finished opening. Here in
-- the module we can watch the windows, keep their count under the server's limit and open one thing at a time
-- (see bags.lua for the rules the client imposes). The waypoint just calls tick() / withdraw() and is told
-- 'retry' until the job is finished.
RouteDepot = {}
dofile('bags')   -- also listed in the .otmod, but a reload() keeps the first script list and the old env; loading it here keeps both in step

local OPEN_TIMEOUT = 2500
local MOVE_TIMEOUT = 800
local DEPOT_CHEST = 3502
local LOCKERS = { [3497] = true, [3499] = true, [3502] = true }

local job

local log = RouteBags.log
local isMine = RouteBags.isMine
local openCount = RouteBags.openCount
local minimizeOpen = RouteBags.minimizeOpen
local keyOf = RouteBags.keyOf

local function rootBackpack()
  for _, c in pairs(g_game.getContainers()) do
    if isMine(c) and not c:hasParent() then return c end
  end
end

local function chestContainer() return RouteBags.byName('depot chest') end
local function lockerContainer() return RouteBags.byName('locker') end

-- open one container and call back when the client says it is open, not when a timer says so
local function openItem(item, cb)
  local wantId = item:getId()
  local finished, conn, timer = false, nil, nil
  local function finish(c)
    if finished then return end
    finished = true
    if timer then removeEvent(timer) timer = nil end
    if conn then disconnect(Container, conn) conn = nil end
    cb(c)
  end
  conn = { onOpen = function(c)
    local ci = c:getContainerItem()
    if ci and ci:getId() == wantId then finish(c) end
  end }
  connect(Container, conn)
  timer = scheduleEvent(function() finish(nil) end, OPEN_TIMEOUT)
  minimizeOpen()                     -- collapse what is open first (bag-organiser discipline)
  g_game.open(item)
end

-- the depot chest, opening the locker first if it is not there yet
local function ensureChest(cb)
  local chest = chestContainer()
  if chest then return cb(chest) end
  local locker = lockerContainer()
  if locker then
    for _, it in ipairs(locker:getItems()) do
      if it:getId() == DEPOT_CHEST then                  -- the locker also holds the store inbox
        log('opening the depot chest')
        return openItem(it, function(c) cb(c or chestContainer()) end)
      end
    end
    return cb(nil)
  end
  local me = g_game.getLocalPlayer()
  local p = me and me:getPosition()
  if not p then return cb(nil) end
  for dx = -1, 1 do
    for dy = -1, 1 do
      local tile = g_map.getTile({ x = p.x + dx, y = p.y + dy, z = p.z })
      if tile then
        for _, thing in ipairs(tile:getThings()) do
          if LOCKERS[thing:getId()] then
            log('opening the depot locker')
            minimizeOpen()
            g_game.open(thing)
            return scheduleEvent(function() ensureChest(cb) end, 900)
          end
        end
      end
    end
  end
  cb(nil)
end

-- ---------------------------------------------------------------- the jobs (tick driven)
-- Everything advances on tick() only, never on a background timer, so a job can only make progress while the
-- cavebot is holding on its waypoint. The moment the waypoint stops being called (the bot moved on) the job
-- stops too - it can never wander off opening our own backpacks with no depot in sight.
--
-- Direction is guaranteed: for a deposit the source is always a CARRIED bag or a bag inside one and the
-- destination the depot chest or a container inside it; a withdraw is exactly the reverse. Nothing is ever
-- moved carried -> carried or depot -> depot, whatever the nesting depth on either end.

local function stopCavebot(why)
  local rp = modules.game_route_paint
  local ok, ctx = pcall(function() return rp.botContext and rp.botContext() end)
  local cave = ok and ctx and ctx.CaveBot
  if cave and type(cave.setOff) == 'function' then pcall(function() cave.setOff() end) end
  log((why or 'the job could not finish') .. ' - stopped the cavebot so nothing is lost')
end

-- the depot chest, and every container we opened out of it (the window ids are remembered in job.side)
local function isDepotSide(c)
  if c:getName():lower():find('depot chest') then return true end
  local rec = job and job.side and job.side[c:getId()]
  if not rec or rec.side ~= 'depot' then return false end
  local ci = c:getContainerItem()
  return ci ~= nil and ci:getId() == rec.itemId
end

-- a carried container is one of ours that is NOT on the depot side and NOT the inbox/market
local function isCarried(c)
  return isMine(c) and not isDepotSide(c)
end

local function issueOpen(item, side) RouteBags.issueOpen(job, item, side) end
local function openPending() return RouteBags.openPending(job) end

-- One move in flight at a time: the item stays in its slot until the server confirms, and re-sending it every
-- tick both spams the server and counts the same item several times over.
local function movePending()
  local m = job.moving
  if not m then return false end
  local c = g_game.getContainers()[m.cid]
  local it = c and c:getItem(m.slot)
  if not it or it:getId() ~= m.id or it:getCount() ~= m.count then job.moving = nil return false end
  if g_clock.millis() - m.since > MOVE_TIMEOUT then
    -- still there: the move was refused. Take it back out of the tally; after 3 refusals leave that slot alone.
    job.tally[m.id] = job.tally[m.id] - m.tallied
    job.moved = job.moved - 1
    if job.have and job.have[m.id] then job.have[m.id] = job.have[m.id] - m.tallied end
    job.moveFails[m.key] = (job.moveFails[m.key] or 0) + 1
    if job.moveFails[m.key] >= 3 then
      log(('could not move %s - skipping it'):format(RouteItems.name(m.id)))
    end
    job.moving = nil
    return false
  end
  return true
end

local function startMove(item, cid, slot, dest, count)
  local okS, stackable = pcall(function() return item:isStackable() end)
  local n = (okS and stackable) and math.min(item:getCount(), count or item:getCount()) or 1
  job.tally[item:getId()] = (job.tally[item:getId()] or 0) + n
  job.moved = job.moved + 1
  if job.have and job.have[item:getId()] then job.have[item:getId()] = job.have[item:getId()] + n end
  job.moving = { cid = cid, slot = slot, id = item:getId(), count = item:getCount(), key = keyOf(item),
                 tallied = n, since = g_clock.millis() }
  g_game.move(item, dest:getSlotPosition(dest:getItemsCount()), n)
end

-- A destination on the depot side with room. Walks the whole depot tree, however deeply the depot bags are
-- nested: any open depot-side container with a free slot is a destination; if none has room, the next
-- unopened bag anywhere on the depot side (in the chest, a depot box, or a bag inside one) is returned to open.
local function depotDestination()
  for _, c in pairs(g_game.getContainers()) do
    if isDepotSide(c) and c:getItemsCount() < c:getCapacity() then return c, nil end
  end
  for _, c in pairs(g_game.getContainers()) do
    if isDepotSide(c) then
      for _, it in ipairs(c:getItems()) do
        if it:isContainer() and not job.triedDepot[keyOf(it)] then return nil, it end
      end
    end
  end
  return nil, nil    -- every depot bag is open and full
end

-- a carried container with room to take things into: a worn root first, then any bag inside one
local function carriedDestination()
  for _, c in pairs(g_game.getContainers()) do
    if isCarried(c) and not c:hasParent() and c:getItemsCount() < c:getCapacity() then return c end
  end
  for _, c in pairs(g_game.getContainers()) do
    if isCarried(c) and c:getItemsCount() < c:getCapacity() then return c end
  end
end

-- the next wanted item sitting in an OPEN carried bag, and a carried sub-bag we have not opened yet
local function findCarried()
  local item, subBag, itemCid, itemSlot
  for cid, c in pairs(g_game.getContainers()) do
    if isCarried(c) then
      for i, it in ipairs(c:getItems()) do
        if job.want[it:getId()] and not item and (job.moveFails[keyOf(it)] or 0) < 3 then
          item, itemCid, itemSlot = it, cid, i - 1
        end
        if it:isContainer() and not job.opened[keyOf(it)] then subBag = subBag or it end
      end
    end
  end
  return item, subBag, itemCid, itemSlot
end

-- the next item we are still short of sitting on the OPEN depot side, and a depot bag not yet opened
local function findInDepot(short)
  local item, bag, itemCid, itemSlot
  for cid, c in pairs(g_game.getContainers()) do
    if isDepotSide(c) then
      for i, it in ipairs(c:getItems()) do
        if short[it:getId()] and not item and (job.moveFails[keyOf(it)] or 0) < 3 then
          item, itemCid, itemSlot = it, cid, i - 1
        end
        if it:isContainer() and not job.triedDepot[keyOf(it)] then bag = bag or it end
      end
    end
  end
  return item, bag, itemCid, itemSlot
end

local function tallyText()
  local parts = {}
  for id, n in pairs(job.tally) do if n > 0 then parts[#parts + 1] = n .. 'x ' .. RouteItems.name(id) end end
  return (#parts > 0) and table.concat(parts, ', ') or 'nothing'
end

local function reportDone()
  local where = job.depotBags > 0 and (' (the chest was full, %d depot bags used)'):format(job.depotBags) or ''
  log(('deposited %s%s'):format(tallyText(), where))
end

local function lockerNearby()
  local me = g_game.getLocalPlayer()
  local p = me and me:getPosition()
  if not p then return nil end
  for dx = -1, 1 do
    for dy = -1, 1 do
      local tile = g_map.getTile({ x = p.x + dx, y = p.y + dy, z = p.z })
      if tile then
        for _, th in ipairs(tile:getThings()) do if LOCKERS[th:getId()] then return th end end
      end
    end
  end
end

-- The depot chest has to be open, and we have to actually be at a depot (a locker in reach). Returns the chest,
-- or nil plus what the step should return ('retry' while opening, false when giving up). If there is no locker
-- nearby we are NOT at a depot - we hold and wait to be walked back (DEPOT_WALK owns walking), bounded.
local function chestStep()
  local chest = chestContainer()
  if chest then job.reopen, job.noDepot = 0, 0 return chest end
  local locker = lockerContainer()
  if locker then
    for _, it in ipairs(locker:getItems()) do
      if it:getId() == DEPOT_CHEST then
        job.chestTries = (job.chestTries or 0) + 1
        if job.chestTries > 4 then stopCavebot('the depot chest would not open') return nil, false end
        if job.chestTries == 1 then log('opening the depot chest') end
        issueOpen(it, 'chest')
        return nil, 'retry'
      end
    end
    stopCavebot('there is no depot chest inside this locker')
    return nil, false
  end
  local th = lockerNearby()
  if th then
    job.reopen = (job.reopen or 0) + 1
    if job.reopen > 4 then stopCavebot('the depot locker would not open') return nil, false end
    if job.reopen == 1 then log('opening the depot locker') end
    issueOpen(th, 'locker')
    return nil, 'retry'
  end
  job.noDepot = (job.noDepot or 0) + 1
  if job.noDepot % 15 == 0 then log('no depot in reach - waiting') end
  if job.noDepot > 90 then stopCavebot('lost the depot') return nil, false end
  return nil, 'retry'
end

-- keep the open windows under the server's limit: a carried bag with no wanted items left and every inner bag
-- opened is finished; so is a full depot bag once every bag inside it has been tried (bag-organiser discipline)
local function closeFinished(root)
  if openCount() <= 10 then return end
  for cid, c in pairs(g_game.getContainers()) do
    if isCarried(c) and c ~= root and c:hasParent() then
      local hasWanted, hasUnopenedSub = false, false
      for _, it in ipairs(c:getItems()) do
        if job.want[it:getId()] then hasWanted = true end
        if it:isContainer() and not job.opened[keyOf(it)] then hasUnopenedSub = true end
      end
      if not hasWanted and not hasUnopenedSub then pcall(function() g_game.close(c) end) return end
    elseif isDepotSide(c) and not c:getName():lower():find('depot chest') and c:getItemsCount() >= c:getCapacity() then
      local hasUntried = false
      for _, it in ipairs(c:getItems()) do
        if it:isContainer() and not job.triedDepot[keyOf(it)] then hasUntried = true end
      end
      if not hasUntried then job.side[cid] = nil pcall(function() g_game.close(c) end) return end
    end
  end
end

-- one step of a deposit; returns 'retry', true, or false
local function step()
  if job.finishing then return RouteBags.finishStep(job.finishing) end

  -- 1. start from a known state: close everything, then open the worn bags one at a time (bags.lua explains why)
  local me = g_game.getLocalPlayer()
  if not me then return 'retry' end
  if not job.closedAt then
    if openCount() > 0 then log('closing your open bags to start from a clean state') end
    RouteBags.closeAll(job)
    return 'retry'
  end
  if RouteBags.closing(job) then return 'retry' end
  if openPending() then return 'retry' end
  if movePending() then return 'retry' end

  for _, worn in ipairs(RouteBags.wornBags()) do
    if not job.wornOpen[worn.slot] then
      job.wornOpen[worn.slot] = true
      if not job.wornLogged then job.wornLogged = true log('opening your backpacks to check them') end
      job.wornIssued = job.wornIssued + 1
      issueOpen(worn.item, 'carried')
      return 'retry'
    end
  end
  if job.wornIssued == 0 then log('you wear no backpack to deposit from') return false end
  local root = rootBackpack()
  if not root then log('could not open your backpack') return false end

  -- 2. the depot chest
  local chest, r = chestStep()
  if not chest then
    if r == false then reportDone() end
    return r
  end
  if not job.announced then job.announced = true log('at the depot - checking your bags to deposit') end

  -- 3. window count
  closeFinished(root)

  -- 4. a wanted item in an open carried bag: move it to the depot side
  local item, subBag, itemCid, itemSlot = findCarried()
  if item then
    local dest, toOpen = depotDestination()
    if not dest then
      if toOpen then
        if job.depotBags == 0 then log('the depot chest is full - using the bags inside it') end
        job.depotBags = job.depotBags + 1
        job.triedDepot[keyOf(toOpen)] = true
        issueOpen(toOpen, 'depot')
        return 'retry'
      end
      reportDone()
      stopCavebot('the depot is full - no free slot in the chest or any depot bag')
      return false
    end
    startMove(item, itemCid, itemSlot, dest)
    return 'retry'
  end

  -- 5. no wanted item in anything open: open the next carried sub-bag so we can see inside it
  if subBag then
    if not job.loggedOpen then job.loggedOpen = true log('opening a bag inside your backpack to check it') end
    job.opened[keyOf(subBag)] = true
    issueOpen(subBag, 'carried')
    return 'retry'
  end

  -- 6. no wanted item anywhere open and no carried sub-bag left to open: every bag has been seen, done
  if job.moved == 0 then
    local parts = {}
    for _, c in pairs(g_game.getContainers()) do
      parts[#parts + 1] = ('%s[%s, %d items]'):format(c:getName(), isCarried(c) and 'carried' or 'depot/other', c:getItemsCount())
    end
    log('open now: ' .. (#parts > 0 and table.concat(parts, ', ') or 'nothing'))
    log('checked the bags, none held anything on your deposit list')
  end
  reportDone()
  log('done - closing the bags, leaving your backpack open')
  job.finishing = {}
  return 'retry'
end

local function newJob(mode, want)
  return { mode = mode, want = want, tally = {}, moved = 0, side = {}, opened = {}, triedDepot = {}, wornOpen = {},
           wornIssued = 0, moveFails = {}, depotBags = 0 }
end

-- Called from a function waypoint. Starts the job on the first call, then steps it once per call.
function RouteDepot.tick(ids)
  local want, n = {}, 0
  for _, id in ipairs(ids or {}) do want[id] = true n = n + 1 end
  if not job or job.mode ~= 'deposit' then
    if n == 0 then log('nothing is ticked "depot" in the Loot window, so there is nothing to deposit') return true end
    job = newJob('deposit', want)
  else
    job.want = want    -- keep it fresh in case the list changed
  end
  local ok, res = pcall(step)
  if not ok then
    log('deposit error: ' .. tostring(res))
    job = nil
    return false
  end
  if res == true or res == false then job = nil end
  return res
end

-- ---------------------------------------------------------------- taking things out
local function reportTaken()
  local parts, short = {}, {}
  for id, n in pairs(job.tally) do if n > 0 then parts[#parts + 1] = n .. 'x ' .. RouteItems.name(id) end end
  for id in pairs(job.want) do
    local missing = job.target - (job.have[id] or 0)
    if missing > 0 then short[#short + 1] = ('%dx %s'):format(missing, RouteItems.name(id)) end
  end
  local text = ('took %s out of the depot'):format((#parts > 0) and table.concat(parts, ', ') or 'nothing')
  if #short > 0 then text = text .. ' - still short of ' .. table.concat(short, ', ') end
  log(text)
end

-- one step of a withdraw; returns 'retry', true, or false
local function withdrawStep()
  if job.finishing then return RouteBags.finishStep(job.finishing) end

  -- 1. count what you carry, closed bags included, so the target is measured against the truth
  if not job.countDone then
    job.count = job.count or {}
    if not job.countLogged then
      job.countLogged = true
      log('counting what you carry before taking things out')
      job.count.enough = function(counts)
        for id in pairs(job.want) do if (counts[id] or 0) < job.target then return false end end
        return true
      end
    end
    if RouteBags.countStep(job.count) == 'busy' then return 'retry' end
    job.countDone = true
    job.have = {}
    local parts = {}
    for id in pairs(job.want) do
      job.have[id] = job.count.counts[id] or 0
      parts[#parts + 1] = ('%dx %s'):format(job.have[id], RouteItems.name(id))
    end
    log(('you carry %s (target %d each, %d bags counted)'):format(table.concat(parts, ', '), job.target, job.count.bags or 0))
  end
  if openPending() then return 'retry' end
  if movePending() then return 'retry' end

  -- 2. the depot chest
  local chest, r = chestStep()
  if not chest then
    if r == false then reportTaken() end
    return r
  end
  local root = rootBackpack()
  closeFinished(root)

  -- 3. what are we still short of?
  local short, any = {}, false
  for id in pairs(job.want) do
    if job.target - (job.have[id] or 0) > 0 then short[id] = true any = true end
  end
  if not any then
    reportTaken()
    log('done - closing the bags, leaving your backpack open')
    job.finishing = {}
    return 'retry'
  end

  -- 4. one of them on the open depot side: move what is needed into a carried bag
  local item, bag, itemCid, itemSlot = findInDepot(short)
  if item then
    local dest = carriedDestination()
    if not dest then
      reportTaken()
      log('your bags are full - stopped taking things out')
      job.finishing = {}
      return 'retry'
    end
    startMove(item, itemCid, itemSlot, dest, job.target - (job.have[item:getId()] or 0))
    return 'retry'
  end

  -- 5. not in anything open: look inside the next depot bag
  if bag then
    if job.depotBags == 0 then log('not in the chest itself - looking inside the depot bags') end
    job.depotBags = job.depotBags + 1
    job.triedDepot[keyOf(bag)] = true
    issueOpen(bag, 'depot')
    return 'retry'
  end

  -- 6. the whole depot has been seen
  reportTaken()
  log('done - closing the bags, leaving your backpack open')
  job.finishing = {}
  return 'retry'
end

-- Take things out of the depot until you carry `want` of each id. Called from a function waypoint, tick driven
-- like the deposit.
function RouteDepot.withdraw(ids, want)
  if not job or job.mode ~= 'withdraw' then
    local w, n = {}, 0
    for _, id in ipairs(ids or {}) do w[id] = true n = n + 1 end
    if n == 0 then log('nothing to take out of the depot') return true end
    job = newJob('withdraw', w)
    job.target = want or 100
  end
  local ok, res = pcall(withdrawStep)
  if not ok then
    log('withdraw error: ' .. tostring(res))
    job = nil
    return false
  end
  if res == true or res == false then job = nil end
  return res
end

function RouteDepot.cancel() job = nil end
function RouteDepot.status() return job and ('%s running: %d moved'):format(job.mode, job.moved) or 'idle' end

-- ---------------------------------------------------------------- the one click helpers
local openJob

-- Just open the depot: the locker, then the chest inside it. Nothing is moved.
function RouteDepot.openOnly()
  if chestContainer() then openJob = nil return true end
  if not openJob then
    openJob = { tries = 0, failed = false }
    ensureChest(function(c)
      if not c then openJob.failed = true end
      openJob.settled = true
    end)
    return 'retry'
  end
  openJob.tries = openJob.tries + 1
  if openJob.failed or openJob.tries > 20 then
    local failed = openJob.failed
    openJob = nil
    if failed then log('could not open the depot here') return false end
    log('gave up waiting for the depot to open')
    return false
  end
  if openJob.settled and not chestContainer() then
    openJob = nil
    log('the depot did not open')
    return false
  end
  return 'retry'
end

-- ---------------------------------------------------------------- getting to a depot
-- A depot job is placed anywhere in the depot room, not on one exact square. This finds the nearest locker
-- with a free walkable tile beside it - free meaning nobody is standing there - and says where to stand.
-- Returns { locker = pos, stand = pos } or nil when no locker is in view.
function RouteDepot.nearestFreeLocker(radius)
  radius = radius or 8
  local me = g_game.getLocalPlayer()
  local p = me and me:getPosition()
  if not p then return nil end
  local best, bestD
  for dx = -radius, radius do
    for dy = -radius, radius do
      local tile = g_map.getTile({ x = p.x + dx, y = p.y + dy, z = p.z })
      if tile then
        local isLocker = false
        for _, thing in ipairs(tile:getThings()) do
          if LOCKERS[thing:getId()] then isLocker = true break end
        end
        if isLocker then
          -- the four tiles around it; a diagonal stand works for use() too, but the straight ones are safer
          for _, o in ipairs({ { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }) do
            local sx, sy = p.x + dx + o[1], p.y + dy + o[2]
            local st = g_map.getTile({ x = sx, y = sy, z = p.z })
            local okWalk = st and pcall(function() return st:isWalkable() end) and st:isWalkable()
            local okFree = st and pcall(function() return st:getCreatures() end) and #st:getCreatures() == 0
            if okWalk and (okFree or (sx == p.x and sy == p.y)) then
              local d = math.max(math.abs(sx - p.x), math.abs(sy - p.y))
              if not bestD or d < bestD then
                bestD = d
                best = { locker = { x = p.x + dx, y = p.y + dy, z = p.z }, stand = { x = sx, y = sy, z = p.z } }
              end
            end
          end
        end
      end
    end
  end
  return best
end
