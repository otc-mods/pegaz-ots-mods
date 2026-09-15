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
local sweep = { st = nil, lastMove = 0 }     -- hunt-time loot sweep state (the sweep itself is further down)

local log = RouteBags.log
local isMine = RouteBags.isMine
local openCount = RouteBags.openCount
local minimizeOpen = RouteBags.minimizeOpen
local function keyOf(item) return RouteBags.keyOf(item, job) end

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

-- A depot problem is never a reason to stop hunting: the loot stays in the bags, the route goes on, and the
-- reason is in the log. (Running out of room for supplies is the stop - that lives in the supply job.)
local function giveUp(why) job.stopReason = why end

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
-- A move has landed when the source lost an item, the destination gained one, or the item in the source slot
-- changed. The slot alone is not enough: with identical items side by side the next one slides into the slot
-- with the same id and count and the move would look like it never happened.
local function movePending()
  local m = job.moving
  if not m then return false end
  local c = g_game.getContainers()[m.cid]
  local d = m.destCid and g_game.getContainers()[m.destCid]
  local it = c and c:getItem(m.slot)
  local landed = not it or it:getId() ~= m.id or it:getCount() ~= m.count
                 or (c and c:getItemsCount() < m.srcCount) or (d and d:getItemsCount() > m.destCount)
  if landed then job.moving = nil return false end
  local refusal = RouteBags.lastFailure
  local refused = refusal and refusal.at >= m.since and refusal.text or nil
  if refused and (refused:lower():find('depot') or refused:lower():find('room') or refused:lower():find('more objects')
                  or refused:lower():find('enough')) then
    job.tally[m.id] = job.tally[m.id] - m.tallied
    job.moved = job.moved - 1
    job.moving = nil
    giveUp('the depot has no room (the server said "' .. refused .. '")')
    return false
  end
  if refused or g_clock.millis() - m.since > MOVE_TIMEOUT then
    -- still there: the move was refused. Take it back out of the tally; after 3 refusals leave that slot alone.
    job.tally[m.id] = job.tally[m.id] - m.tallied
    job.moved = job.moved - 1
    if job.have and job.have[m.id] then job.have[m.id] = job.have[m.id] - m.tallied end
    job.moveFails[m.key] = (job.moveFails[m.key] or 0) + 1
    if job.moveFails[m.key] >= 3 then
      log(('could not move %s%s - skipping it'):format(RouteItems.name(m.id), refused and (' ("' .. refused .. '")') or ''))
    end
    job.moving = nil
    return false
  end
  return true
end

-- count: a stack moves whole unless the caller (withdraw) asks for less; a single item moves as exactly one -
-- the server refuses any other count for it
local function startMove(item, cid, slot, dest, count)
  local okS, stackable = pcall(function() return item:isStackable() end)
  local n = (okS and stackable) and math.min(item:getCount(), count or item:getCount()) or 1
  job.tally[item:getId()] = (job.tally[item:getId()] or 0) + n
  job.moved = job.moved + 1
  if job.have and job.have[item:getId()] then job.have[item:getId()] = job.have[item:getId()] + n end
  local src = g_game.getContainers()[cid]
  local destCid
  for dc, w in pairs(g_game.getContainers()) do if w == dest then destCid = dc end end
  job.moving = { cid = cid, slot = slot, id = item:getId(), count = item:getCount(), key = keyOf(item),
                 srcCount = src and src:getItemsCount() or 0, destCid = destCid, destCount = dest:getItemsCount(),
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
        if RouteBags.isBag(it) and not job.triedDepot[keyOf(it)] then return nil, it end
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
  for _, w in ipairs(RouteBags.windowsDeepFirst(job)) do
    local cid, c = w.cid, w.c
    if isCarried(c) then
      for i, it in ipairs(c:getItems()) do
        if job.want[it:getId()] and not item and (job.moveFails[keyOf(it)] or 0) < 3 then
          item, itemCid, itemSlot = it, cid, i - 1
        end
        if RouteBags.isBag(it) and not job.opened[keyOf(it)] then subBag = subBag or it end
      end
    end
  end
  return item, subBag, itemCid, itemSlot
end

-- the next item we are still short of sitting on the OPEN depot side, and a depot bag not yet opened
local function findInDepot(short)
  local item, bag, itemCid, itemSlot
  for _, w in ipairs(RouteBags.windowsDeepFirst(job)) do
    local cid, c = w.cid, w.c
    if isDepotSide(c) then
      for i, it in ipairs(c:getItems()) do
        if short[it:getId()] and not item and (job.moveFails[keyOf(it)] or 0) < 3 then
          item, itemCid, itemSlot = it, cid, i - 1
        end
        if RouteBags.isBag(it) and not job.triedDepot[keyOf(it)] then bag = bag or it end
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
  if chest then
    job.reopen, job.noDepot = 0, 0
    -- the locker window only served to reach the chest; its id is worth more as room for a bag
    local locker = lockerContainer()
    if locker and not job.lockerClosed then job.lockerClosed = true pcall(function() g_game.close(locker) end) end
    return chest
  end
  local locker = lockerContainer()
  if locker then
    for _, it in ipairs(locker:getItems()) do
      if it:getId() == DEPOT_CHEST then
        job.chestTries = (job.chestTries or 0) + 1
        if job.chestTries > 4 then giveUp('the depot chest would not open') return nil, 'retry' end
        if job.chestTries == 1 then log('opening the depot chest') end
        issueOpen(it, 'chest')
        return nil, 'retry'
      end
    end
    giveUp('there is no depot chest inside this locker')
    return nil, 'retry'
  end
  local th = lockerNearby()
  if th then
    job.reopen = (job.reopen or 0) + 1
    if job.reopen > 4 then giveUp('the depot locker would not open') return nil, 'retry' end
    if job.reopen == 1 then log('opening the depot locker') end
    issueOpen(th, 'locker')
    return nil, 'retry'
  end
  job.noDepot = (job.noDepot or 0) + 1
  if job.noDepot % 15 == 0 then log('no depot in reach - waiting') end
  if job.noDepot > 90 then giveUp('no depot in reach') return nil, 'retry' end
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
        if RouteBags.isBag(it) and not job.opened[keyOf(it)] then hasUnopenedSub = true end
      end
      if not hasWanted and not hasUnopenedSub then pcall(function() g_game.close(c) end) return end
    elseif isDepotSide(c) and not c:getName():lower():find('depot chest') and c:getItemsCount() >= c:getCapacity() then
      local hasUntried = false
      for _, it in ipairs(c:getItems()) do
        if RouteBags.isBag(it) and not job.triedDepot[keyOf(it)] then hasUntried = true end
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
  if job.stopReason then
    reportDone()
    log(job.stopReason .. ' - the rest stays in your bags, carrying on with the route')
    job.stopReason = nil
    job.finishing = {}
    return 'retry'
  end

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
  if not chest then return r end
  if not job.announced then
    job.announced = true
    local names = {}
    for id in pairs(job.want) do names[#names + 1] = RouteItems.name(id) end
    table.sort(names)
    log('at the depot - looking for ' .. table.concat(names, ', ') .. ' in your bags')
  end

  -- 3. window count; and a note of everything seen, once per window, for the report
  closeFinished(root)
  job.held, job.seenWin = job.held or {}, job.seenWin or {}
  for cid, c in pairs(g_game.getContainers()) do
    local tag = cid .. ':' .. (job.seq and job.seq[cid] or 0)
    if isCarried(c) and not job.seenWin[tag] then
      job.seenWin[tag] = true
      job.bagsSeen = (job.bagsSeen or 0) + 1
      for _, it in ipairs(c:getItems()) do job.held[it:getId()] = (job.held[it:getId()] or 0) + it:getCount() end
    end
  end

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
      giveUp('the depot is full - no free slot in the chest or any depot bag')
      return 'retry'
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
    log(('looked into %d bags - nothing from the deposit list in them; they hold %s'):format(job.bagsSeen or 0, RouteBags.summarise(job.held or {}, 8)))
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
  if job.stopReason then
    reportTaken()
    log(job.stopReason .. ' - carrying on with the route')
    job.stopReason = nil
    job.finishing = {}
    return 'retry'
  end

  -- 2. the depot chest
  local chest, r = chestStep()
  if not chest then return r end
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

-- ---------------------------------------------------------------- loot by the backpack
-- Three backpack kinds, told apart by item id (colour): the LOOT bag carried at the top of the main backpack,
-- the FULL-STORE in the depot chest that collects full loot bags, and the EMPTY-STORE in the chest that hands
-- out ready empty ones. Dropping loot off is then two moves, whatever is inside the bag. Before the drop, loot
-- lying loose in the main backpack (autoloot puts some there) is swept into the loot bag, down into its inner
-- bags when the top is full.

local function bagCfg()
  local c = RouteLoot.bags()
  if not (c.loot and c.full and c.empty) then return nil end
  return c
end

-- the window of the bag worn on the back: the main backpack
local function mainWindow()
  for cid, c in pairs(g_game.getContainers()) do
    local rec = job.side[cid]
    if rec and rec.slot == InventorySlotBack and isMine(c) and not c:hasParent() then return c, cid end
  end
end

local function topItem(c, id, skip)
  for i, it in ipairs(c:getItems()) do
    if it:getId() == id and not (skip and skip[keyOf(it)]) then return it, i - 1 end
  end
end

-- the window we opened into cid, if it still shows that kind of container
local function windowAt(cid, itemId)
  local c = cid and g_game.getContainers()[cid]
  local ci = c and c:getContainerItem()
  if ci and ci:getId() == itemId then return c end
end

-- Choosing a storage when several bags of its kind sit at the chest top (the spare ones are plain material):
-- each candidate is opened once and the fullest wins - with `needRoom`, the fullest that still has a free slot.
-- Returns the item, or nil and 'probing' while candidates are being looked into, nil and 'none' if there is none.
local function chooseStore(chest, kind, needRoom)
  job.pick = job.pick or {}
  local st = job.pick[kind]
  if st and st.chosen then
    for _, it in ipairs(chest:getItems()) do if it == st.chosen then return st.chosen end end
    st.chosen = nil
  end
  local cands = {}
  for _, it in ipairs(chest:getItems()) do if it:getId() == kind then cands[#cands + 1] = it end end
  if #cands == 0 then return nil, 'none' end
  if #cands == 1 then job.pick[kind] = { chosen = cands[1], counts = {} } return cands[1] end
  st = st or { counts = {} }
  job.pick[kind] = st
  if st.probing then
    local w = windowAt(st.probing.cid, kind)
    st.counts[#st.counts + 1] = { item = st.probing.item, n = w and w:getItemsCount() or -1, room = w and (w:getItemsCount() < w:getCapacity()) }
    if w then pcall(function() g_game.close(w) end) end
    st.probing = nil
  end
  for _, it in ipairs(cands) do
    local seen = false
    for _, c in ipairs(st.counts) do if c.item == it then seen = true end end
    if not seen then
      RouteBags.issueOpen(job, it, 'depot')
      st.probing = { cid = job.opening.cid, item = it }
      return nil, 'probing'
    end
  end
  local best
  for _, c in ipairs(st.counts) do
    if (not needRoom or c.room) and (not best or c.n > best.n) then best = c end
  end
  if not best then return nil, 'full' end
  st.chosen = best.item
  log(('%d %ss at the top of the chest - the fullest is the storage (%d inside)'):format(#cands, RouteItems.name(kind), best.n))
  return st.chosen
end

-- clean state, worn bags open, main window found. Returns main, mainCid - or nil and what the step must return.
local function bagsPrologue()
  if not job.closedAt then
    if openCount() > 0 then log('closing your open bags to start from a clean state') end
    RouteBags.closeAll(job)
    return nil, 'retry'
  end
  if RouteBags.closing(job) then return nil, 'retry' end
  if openPending() then return nil, 'retry' end
  if movePending() then return nil, 'retry' end
  for _, worn in ipairs(RouteBags.wornBags()) do
    if not job.wornOpen[worn.slot] then
      job.wornOpen[worn.slot] = true
      job.wornIssued = job.wornIssued + 1
      RouteBags.issueOpen(job, worn.item, 'carried', { slot = worn.slot })
      return nil, 'retry'
    end
  end
  local main, mainCid = mainWindow()
  if not main then log('could not open your main backpack') return nil, true end
  return main, mainCid
end

-- The sweep: loose wanted items at the top of the main backpack go into the loot bag. Windows opened for it are
-- remembered in job.lootWins (cid -> bag id); when none has room the next inner bag is opened.
local function sweepStep(main, mainCid, cfg)
  job.lootWins = job.lootWins or {}
  -- the loot bag is opened first in any case: it is what says how much is being dropped off
  if not job.lootCid then
    local lootItem = topItem(main, cfg.loot)
    if not lootItem then return 'done' end
    RouteBags.issueOpen(job, lootItem, 'carried')
    job.lootCid = job.opening.cid
    job.lootWins[job.lootCid] = cfg.loot
    return 'busy'
  end
  local loose
  for i, it in ipairs(main:getItems()) do
    if job.want[it:getId()] and not it:isContainer() and (job.moveFails[keyOf(it)] or 0) < 3 then loose = { it = it, slot = i - 1 } break end
  end
  if not loose then return 'done' end
  local windows = {}
  for cid, id in pairs(job.lootWins) do
    local w = windowAt(cid, id)
    if w then windows[#windows + 1] = w end
  end
  if #windows == 0 then return 'done' end            -- the loot bag would not open: drop it off as it is
  for _, w in ipairs(windows) do
    if w:getItemsCount() < w:getCapacity() then
      startMove(loose.it, mainCid, loose.slot, w)
      job.swept = (job.swept or 0) + 1
      return 'busy'
    end
  end
  -- every open loot window is full: the next unopened bag inside one of them
  for _, w in ipairs(windows) do
    for _, it in ipairs(w:getItems()) do
      if RouteBags.isBag(it) and not job.opened[keyOf(it)] then
        job.opened[keyOf(it)] = true
        RouteBags.issueOpen(job, it, 'carried')
        job.lootWins[job.opening.cid] = it:getId()
        return 'busy'
      end
    end
  end
  local left = 0
  for _, it in ipairs(main:getItems()) do if job.want[it:getId()] and not it:isContainer() then left = left + 1 end end
  log(('your %s is full - %d loose loot item%s stay in the main backpack'):format(RouteItems.name(cfg.loot), left, left == 1 and '' or 's'))
  return 'done'
end

local function closeLootWindows()
  for cid, id in pairs(job.lootWins or {}) do
    local w = windowAt(cid, id)
    if w then pcall(function() g_game.close(w) end) end
  end
end

-- one step of "deposit loot (backpacks)"
-- A swap that ends changes the bag situation, so what the sweep knew about a full loot bag is void; and when
-- the depot handed out no loot bag to hunt with, the Loot window's switch has said whether hunting goes on.
local function swapEnded()
  sweep.full, sweep.st, sweep.fullWarned = false, nil, false
  if job.stopAfter then RouteBags.stopCavebot(job.stopAfter) end
end

-- the depot leaves you without a loot backpack to hunt with (none left, or it would not take yours):
-- stop the cavebot once the bags are closed (the default), or carry on, as the Loot window says
local function depotShort(cfg, why)
  if cfg.whenOut == 'hunt' then
    log(why .. ' - carrying on with the route (the Loot window says to keep hunting)')
    if not job.dropped then
      -- the full loot bag stays on your back: do not let the Refill check send you straight back for it
      sweep.muteFullUntil = g_clock.millis() + 20 * 60 * 1000
      log('the "loot backpack is full" check is muted for 20 minutes')
    end
  else
    log(why .. ' - stopping the cavebot once the bags are closed (the Loot window says so)')
    job.stopAfter = why
  end
  job.finishing = {}
  return 'retry'
end

local function swapStep()
  if job.fallback then
    local r = step()
    if r == true or r == false then swapEnded() end
    return r
  end
  if job.finishing then
    local r = RouteBags.finishStep(job.finishing)
    if r == true then swapEnded() end
    return r
  end
  local cfg = bagCfg()
  if not cfg then log('set the three loot backpack kinds in the Loot window first (loot, full storage, empty storage)') return true end
  if not g_game.getLocalPlayer() then return 'retry' end
  local main, mainCid = bagsPrologue()
  if not main then return mainCid end
  if job.stopReason then
    local why = job.stopReason
    job.stopReason = nil
    return depotShort(cfg, why)
  end
  local N = RouteItems.name

  -- 1. the loot bag at the top of the main backpack
  local lootItem, lootSlot = topItem(main, cfg.loot)
  if not job.dropped and not lootItem then
    if next(job.want) == nil then
      log(('no %s at the top of your main backpack - nothing to drop off'):format(N(cfg.loot)))
      job.finishing = {}
      return 'retry'
    end
    -- without a loot bag the loose loot is deposited item by item, the slow way, rather than not at all
    log(('no %s at the top of your main backpack - depositing the loose loot item by item instead'):format(N(cfg.loot)))
    local want = job.want
    job = newJob('swap', want)
    job.fallback = true
    return 'retry'
  end

  -- 2. loose loot into the loot bag first
  if not job.sweepDone then
    if not job.sweepLogged then job.sweepLogged = true log(('sweeping loose loot from the main backpack into your %s'):format(N(cfg.loot))) end
    if sweepStep(main, mainCid, cfg) == 'busy' then return 'retry' end
    job.sweepDone = true
    local lw = job.lootCid and windowAt(job.lootCid, cfg.loot)
    job.lootCount = lw and lw:getItemsCount()
    closeLootWindows()
    return 'retry'
  end

  -- 3. the depot chest and the full-store bag in it
  local chest, r = chestStep()
  if not chest then return r end
  if not job.storeCid then
    local a, why = chooseStore(chest, cfg.full, true)
    if not a then
      if why == 'probing' then return 'retry' end
      giveUp(why == 'full' and ('every %s in the depot chest is full'):format(N(cfg.full))
             or ('no %s (full loot storage) in the depot chest'):format(N(cfg.full)))
      return 'retry'
    end
    RouteBags.issueOpen(job, a, 'depot')
    job.storeCid = job.opening.cid
    return 'retry'
  end
  local store = windowAt(job.storeCid, cfg.full)
  if not store then giveUp(('the %s in the depot would not open'):format(N(cfg.full))) return 'retry' end

  -- 4. the loot bag goes in whole
  if not job.dropped then
    if store:getItemsCount() >= store:getCapacity() then giveUp(('the %s in the depot is full'):format(N(cfg.full))) return 'retry' end
    job.dropKey = keyOf(lootItem)
    startMove(lootItem, mainCid, lootSlot, store)
    job.dropped = true
    return 'retry'
  end
  if (job.moveFails[job.dropKey] or 0) > 0 then giveUp(('the depot did not take your %s'):format(N(cfg.loot))) return 'retry' end
  if not job.droppedLogged then
    job.droppedLogged = true
    log(('dropped your %s off in the depot (%s items at its top%s)'):format(N(cfg.loot), tostring(job.lootCount or '?'),
      (job.swept or 0) > 0 and (', %d loose ones swept in first'):format(job.swept) or ''))
  end

  -- 5. an empty loot bag out of the empty-store
  if not job.emptyCid then
    local b, why = chooseStore(chest, cfg.empty)
    if not b then
      if why == 'probing' then return 'retry' end
      return depotShort(cfg, ('no %s (empty storage) in the depot chest'):format(N(cfg.empty)))
    end
    RouteBags.issueOpen(job, b, 'depot')
    job.emptyCid = job.opening.cid
    return 'retry'
  end
  local emptyStore = windowAt(job.emptyCid, cfg.empty)
  if not emptyStore then return depotShort(cfg, 'the empty storage would not open') end
  if not job.took then
    local e, eslot = topItem(emptyStore, cfg.loot)
    if not e then return depotShort(cfg, ('no empty %s left in the depot'):format(N(cfg.loot))) end
    if main:getItemsCount() >= main:getCapacity() then return depotShort(cfg, 'no free slot in your main backpack for an empty loot backpack') end
    job.takeKey = keyOf(e)
    startMove(e, job.emptyCid, eslot, main)
    job.took = true
    return 'retry'
  end
  if (job.moveFails[job.takeKey] or 0) > 0 then return depotShort(cfg, 'could not take an empty loot backpack out') end
  -- 6. what the old bag had no room for goes into the fresh one, so nothing loose rides back to the hunt
  if not job.sweep2 then
    job.sweep2 = true
    log(('took an empty %s out'):format(N(cfg.loot)))
    job.lootCid, job.lootWins, job.swept = nil, {}, 0
    return 'retry'
  end
  if sweepStep(main, mainCid, cfg) == 'busy' then return 'retry' end
  closeLootWindows()
  log(('ready to hunt%s'):format((job.swept or 0) > 0 and (' - %d loose loot items moved into the fresh %s'):format(job.swept, N(cfg.loot)) or ''))
  job.finishing = {}
  return 'retry'
end

-- "Build sets", standing at the depot: every loot-kind bag in the depot ends up in the empty storage holding
-- exactly setSize plain bags - fewer only when the plain bags run out. Phases: the sets already parked in the
-- empty storage come back to the chest top; every non-storage bag at the top is unpacked (nested loot-kind bags
-- out, a loot bag holding items goes to the full store as it is, plain bags inside a loot bag stay there);
-- then the loot bags are opened and plain bags shuffled until each holds setSize; then all are parked again.
-- Items are remembered by identity (==), never by slot: the chest's slots shift with every move.
local function listHas(list, item) for _, x in ipairs(list or {}) do if x == item then return true end end return false end
local SET_BATCH = 10          -- loot bags open at once while equalizing; the server holds ~16 windows

local function setupStep()
  if job.finishing then return RouteBags.finishStep(job.finishing) end
  local cfg = bagCfg()
  if not cfg then log('set the three loot backpack kinds in the Loot window first (loot, full storage, empty storage)') return true end
  if not g_game.getLocalPlayer() then return 'retry' end
  local main, mainCid = bagsPrologue()
  if not main then return mainCid end
  if job.stopReason then log(job.stopReason) job.stopReason = nil job.finishing = {} return 'retry' end
  local N = RouteItems.name
  local chest, r = chestStep()
  if not chest then return r end
  local chestCid
  for cid, c in pairs(g_game.getContainers()) do if c == chest then chestCid = cid end end
  job.flat, job.skip, job.setCounts = job.flat or {}, job.skip or {}, job.setCounts or {}
  job.phase = job.phase or 'pull'
  local target = cfg.setSize or 0
  local function isStore(it)
    local p = job.pick or {}
    return (p[cfg.full] and it == p[cfg.full].chosen) or (p[cfg.empty] and it == p[cfg.empty].chosen) or false
  end
  local function isPlain(it) return it:isContainer() and it:getId() ~= cfg.loot and not isStore(it) end
  local function storeAtTop(kind) return (job.pick and job.pick[kind] and job.pick[kind].chosen) end
  local function slotOf(c, item)
    for i, it in ipairs(c:getItems()) do if it == item then return i - 1 end end
  end
  local function chestFull() return chest:getItemsCount() >= chest:getCapacity() end
  local function finish()
    local byCount, plainLeft = {}, 0
    for _, n in ipairs(job.setCounts) do byCount[n] = (byCount[n] or 0) + 1 end
    for _, it in ipairs(chest:getItems()) do if isPlain(it) then plainLeft = plainLeft + 1 end end
    local parts = {}
    for n = target, 0, -1 do if byCount[n] then parts[#parts + 1] = ('%d with %d inside'):format(byCount[n], n) end end
    local shortNote = ''
    if (job.incomplete or 0) > 0 then
      shortNote = ('; %d %s%s left at the top of the chest - %d more plain backpack%s needed to finish %s'):format(
        job.incomplete, N(cfg.loot), job.incomplete == 1 and '' or 's', job.missing or 0, (job.missing or 0) == 1 and '' or 's',
        job.incomplete == 1 and 'it' or 'them')
    end
    log(('sets in the %s: %s%s%s%s'):format(N(cfg.empty), #parts > 0 and table.concat(parts, ', ') or 'none',
      shortNote, plainLeft > 0 and (', %d plain backpack%s left at the top of the chest'):format(plainLeft, plainLeft == 1 and '' or 's') or '',
      (job.tidied or 0) > 0 and (', %d spare storage bag%s packed away'):format(job.tidied, job.tidied == 1 and '' or 's') or ''))
    job.finishing = {}
    return 'retry'
  end
  -- both storages in the chest (the fullest of their kind); a spare at the top of the main backpack is moved in
  for _, kind in ipairs({ { id = cfg.full, what = 'full loot storage' }, { id = cfg.empty, what = 'empty storage' } }) do
    local chosen, why = chooseStore(chest, kind.id)
    if not chosen then
      if why == 'probing' then return 'retry' end
      local spare, slot = topItem(main, kind.id)
      if spare then
        if (job.moveFails[keyOf(spare)] or 0) > 0 then giveUp(('the depot did not take the %s'):format(N(kind.id))) return 'retry' end
        if chestFull() then giveUp(('the depot chest has no free slot for the %s'):format(kind.what)) return 'retry' end
        log(('putting your %s (%s) into the depot chest'):format(N(kind.id), kind.what))
        startMove(spare, mainCid, slot, chest)
        return 'retry'
      end
      giveUp(('put a %s (%s) into the depot chest first'):format(N(kind.id), kind.what))
      return 'retry'
    end
  end
  -- the empty storage open, always
  if not job.emptyCid then
    RouteBags.issueOpen(job, (storeAtTop(cfg.empty)), 'depot')
    job.emptyCid = job.opening.cid
    return 'retry'
  end
  local B = windowAt(job.emptyCid, cfg.empty)
  if not B then giveUp(('the %s (empty storage) would not open'):format(N(cfg.empty))) return 'retry' end

  -- phase 1: the parked sets come back to the chest top
  if job.phase == 'pull' then
    for i, it in ipairs(B:getItems()) do
      if it:getId() == cfg.loot and (job.moveFails[keyOf(it)] or 0) == 0 then
        if chestFull() then giveUp('the depot chest is full - no room to take the parked sets out') return 'retry' end
        if not job.pullLogged then job.pullLogged = true log(('taking the parked sets out of the %s to rebuild them'):format(N(cfg.empty))) end
        startMove(it, job.emptyCid, i - 1, chest)
        return 'retry'
      end
    end
    job.phase = 'unpack'
    return 'retry'
  end

  -- phase 2: unpack the top of the chest
  if job.phase == 'unpack' then
    if not job.cur then
      for _, it in ipairs(chest:getItems()) do
        if it:isContainer() and not isStore(it) and not listHas(job.flat, it) then
          if not job.unpackLogged then job.unpackLogged = true log('unpacking the bags at the top of the depot chest') end
          RouteBags.issueOpen(job, it, 'depot')
          job.cur = { cid = job.opening.cid, item = it, id = it:getId() }
          return 'retry'
        end
      end
      job.phase = 'equalize'
      return 'retry'
    end
    local cw = windowAt(job.cur.cid, job.cur.id)
    if not cw then
      log(('one %s would not open - left as it is'):format(N(job.cur.id)))
      job.flat[#job.flat + 1] = job.cur.item
      job.cur = nil
      return 'retry'
    end
    -- out to the top: everything nested in a plain bag; only nested loot-kind bags from a loot bag
    for i, it in ipairs(cw:getItems()) do
      local pull = it:isContainer() and (job.cur.id ~= cfg.loot or it:getId() == cfg.loot)
      if pull and (job.moveFails[keyOf(it)] or 0) == 0 then
        if chestFull() then giveUp('the depot chest is full - no room to unpack the nested bags') return 'retry' end
        job.pulls = (job.pulls or 0) + 1
        startMove(it, job.cur.cid, i - 1, chest)
        return 'retry'
      end
    end
    local hasItems = false
    for _, it in ipairs(cw:getItems()) do if not it:isContainer() then hasItems = true end end
    if job.cur.id == cfg.loot and hasItems then
      -- a loot bag with things in it is a full one: into the full-loot storage as it is
      if not job.storeCid then
        RouteBags.issueOpen(job, (storeAtTop(cfg.full)), 'depot')
        job.storeCid = job.opening.cid
        return 'retry'
      end
      local store = windowAt(job.storeCid, cfg.full)
      if not store then giveUp(('the %s (full loot storage) would not open'):format(N(cfg.full))) return 'retry' end
      if store:getItemsCount() >= store:getCapacity() then giveUp(('the %s (full loot storage) is full'):format(N(cfg.full))) return 'retry' end
      pcall(function() g_game.close(cw) end)
      local slot = slotOf(chest, job.cur.item)
      if slot then
        log(('a %s with %d items in it goes to the %s'):format(N(cfg.loot), cw:getItemsCount(), N(cfg.full)))
        startMove(job.cur.item, chestCid, slot, store)
        job.fulls = (job.fulls or 0) + 1
      end
      job.cur = nil
      return 'retry'
    end
    pcall(function() g_game.close(cw) end)
    job.flat[#job.flat + 1] = job.cur.item
    job.cur = nil
    return 'retry'
  end

  -- phase 3: every loot bag at the top holds exactly `target` plain bags (a batch of SET_BATCH at a time)
  if job.phase == 'equalize' then
    job.batch = job.batch or {}
    -- open the batch
    local openCount_ = 0
    for _, m in ipairs(job.batch) do if windowAt(m.cid, cfg.loot) then openCount_ = openCount_ + 1 end end
    if openCount_ < SET_BATCH then
      for _, it in ipairs(chest:getItems()) do
        local inBatch = false
        for _, m in ipairs(job.batch) do if m.item == it then inBatch = true end end
        if it:getId() == cfg.loot and not inBatch and not listHas(job.skip, it) then
          RouteBags.issueOpen(job, it, 'depot')
          job.batch[#job.batch + 1] = { cid = job.opening.cid, item = it }
          return 'retry'
        end
        if #job.batch >= SET_BATCH then break end
      end
    end
    if #job.batch == 0 then return finish() end
    if not job.eqLogged then job.eqLogged = true log(('filling each %s up to %d plain backpack%s'):format(N(cfg.loot), target, target == 1 and '' or 's')) end
    -- a deficit, and a plain bag at the top: in
    for _, m in ipairs(job.batch) do
      local w = windowAt(m.cid, cfg.loot)
      if w and w:getItemsCount() < target then
        for i, it in ipairs(chest:getItems()) do
          if isPlain(it) and (job.moveFails[keyOf(it)] or 0) < 3 then startMove(it, chestCid, i - 1, w) return 'retry' end
        end
      end
    end
    -- a surplus, and room at the top: out
    for _, m in ipairs(job.batch) do
      local w = windowAt(m.cid, cfg.loot)
      if w and w:getItemsCount() > target and not chestFull() then
        local items = w:getItems()
        local it = items[#items]
        if it and (job.moveFails[keyOf(it)] or 0) < 3 then startMove(it, m.cid, #items - 1, chest) return 'retry' end
      end
    end
    job.phase = 'park'
    return 'retry'
  end

  -- phase 4: park the batch in the empty storage, then look for the next batch
  if job.phase == 'park' then
    for idx, m in ipairs(job.batch) do
      local w = windowAt(m.cid, cfg.loot)
      local slot = slotOf(chest, m.item)
      -- a set that could not be filled stays at the chest top: taken hunting it would run out of room
      if slot and w and w:getItemsCount() < target then
        job.incomplete = (job.incomplete or 0) + 1
        job.missing = (job.missing or 0) + (target - w:getItemsCount())
        pcall(function() g_game.close(w) end)
        job.skip[#job.skip + 1] = m.item
        table.remove(job.batch, idx)
        return 'retry'
      end
      if slot then
        if B:getItemsCount() >= B:getCapacity() then giveUp(('the %s (empty storage) is full'):format(N(cfg.empty))) return 'retry' end
        if (job.moveFails[keyOf(m.item)] or 0) > 0 then
          log(('could not move one %s into the %s - left in the chest'):format(N(cfg.loot), N(cfg.empty)))
          job.skip[#job.skip + 1] = m.item
          table.remove(job.batch, idx)
          return 'retry'
        end
        job.setCounts[#job.setCounts + 1] = w and w:getItemsCount() or -1
        if w then pcall(function() g_game.close(w) end) end
        startMove(m.item, chestCid, slot, B)
        table.remove(job.batch, idx)
        return 'retry'
      else
        table.remove(job.batch, idx)                   -- gone from the top already
        return 'retry'
      end
    end
    -- batch parked; more loot bags at the top means another round
    for _, it in ipairs(chest:getItems()) do
      if it:getId() == cfg.loot and not listHas(job.skip, it) then job.phase = 'equalize' job.batch = {} return 'retry' end
    end
    job.phase = 'tidy'
    return 'retry'
  end

  -- phase 5: exactly one storage of each kind stays at the chest top; a spare of that kind goes inside its
  -- storage, where the jobs never look for it
  if job.phase == 'tidy' then
    for _, kind in ipairs({ cfg.full, cfg.empty }) do
      local store = job.pick[kind] and job.pick[kind].chosen
      for i, it in ipairs(chest:getItems()) do
        if store and it:getId() == kind and not (it == store) and (job.moveFails[keyOf(it)] or 0) < 3 then
          local win
          if kind == cfg.empty then win = B
          else
            if not job.storeCid then RouteBags.issueOpen(job, store, 'depot') job.storeCid = job.opening.cid return 'retry' end
            win = windowAt(job.storeCid, cfg.full)
          end
          if win and win:getItemsCount() < win:getCapacity() then
            job.tidied = (job.tidied or 0) + 1
            startMove(it, chestCid, i - 1, win)
            return 'retry'
          elseif not job.tidyWarned then
            job.tidyWarned = true
            log(('a spare %s stays at the top of the chest - its storage is full'):format(N(kind)))
          end
        end
      end
    end
    return finish()
  end
  return finish()
end

local function runStep(mode, stepFn, label)
  if not job or job.mode ~= mode then
    local want = {}
    if mode == 'swap' then
      for _, id in ipairs(RouteLoot.depositIds()) do want[id] = true end
      local ok, ids = pcall(function() return RouteLoot.autolootItems() end)
      if ok then for _, id in ipairs(ids or {}) do want[id] = true end end
    end
    job = newJob(mode, want)
  end
  local ok, res = pcall(stepFn)
  if not ok then
    log(label .. ' error: ' .. tostring(res))
    job = nil
    return false
  end
  if res == true or res == false then job = nil end
  return res
end

-- tick driven, from a function waypoint
function RouteDepot.swapBags() return runStep('swap', swapStep, 'deposit (backpacks)') end
function RouteDepot.setupBags() return runStep('setup', setupStep, 'build loot sets') end

-- the same jobs from a button: they drive themselves until done
local runner
local function runJob(fn)
  if runner then removeEvent(runner) runner = nil end
  local function tick()
    runner = nil
    local r = fn()
    if r == 'retry' then runner = scheduleEvent(tick, 100) end
  end
  tick()
end
function RouteDepot.runSwap() runJob(RouteDepot.swapBags) end
function RouteDepot.runSetup() runJob(RouteDepot.setupBags) end

function RouteDepot.cancel()
  job = nil
  if runner then removeEvent(runner) runner = nil end
end

-- ---------------------------------------------------------------- loot sweep while hunting
-- Autoloot drops part of the loot into the main backpack. Every few seconds, when no depot or supply job owns
-- the windows, loose loot at the top of the main backpack is moved into the loot bag; when its top is full,
-- into inner bags the sweep opens one at a time. The loot bag stays open the way you hunt with it.
-- (the sweep state table is declared at the top of the file: the swap job resets it when it ends)

local function sweepWant()
  local want = {}
  for _, id in ipairs(RouteLoot.depositIds()) do want[id] = true end
  local ok, ids = pcall(function() return RouteLoot.autolootItems() end)
  if ok then for _, id in ipairs(ids or {}) do want[id] = true end end
  return want
end

local function sweepTick()
  sweep.timer = nil
  if not RouteLoot.bags().sweep then return end
  sweep.timer = scheduleEvent(sweepTick, 2500)
  if job or not g_game.isOnline() or not RouteBags.cavebotOn() then return end
  local cfg = bagCfg()
  if not cfg then return end
  local me = g_game.getLocalPlayer()
  local back = me and me:getInventoryItem(InventorySlotBack)
  if not back then return end
  local main, mainCid
  for cid, c in pairs(g_game.getContainers()) do
    local ci = c:getContainerItem()
    if not c:hasParent() and ci and ci:getId() == back:getId() then main, mainCid = c, cid end
  end
  if not main then return end                       -- the main backpack is closed: nothing to look at
  local st = sweep.st or { side = {}, opened = {}, wins = {} }
  sweep.st = st
  if RouteBags.openPending(st) then return end
  if st.opening == nil and st.justOpened then       -- the last open landed: remember its window
    st.wins[st.justOpened.cid] = st.justOpened.id
    st.justOpened = nil
  end
  local want = sweepWant()
  local loose, slot
  for i, it in ipairs(main:getItems()) do
    if want[it:getId()] and not it:isContainer() then loose, slot = it, i - 1 break end
  end
  if not loose then return end
  if g_clock.millis() - sweep.lastMove < 700 then return end   -- one move at a time, let it land
  -- the loot bag's window
  local lw, lwCid
  for cid, c in pairs(g_game.getContainers()) do
    local ci = c:getContainerItem()
    if c:hasParent() and ci and ci:getId() == cfg.loot then lw, lwCid = c, cid end
  end
  if not lw then
    local lootItem = topItem(main, cfg.loot)
    if not lootItem then
      if not sweep.warned then sweep.warned = true log(('loot sweep: no %s at the top of your main backpack'):format(RouteItems.name(cfg.loot))) end
      return
    end
    sweep.warned = false
    sweep.st = { side = {}, opened = {}, wins = {} }          -- a fresh loot bag window: fresh keys
    RouteBags.issueOpen(sweep.st, lootItem, 'carried')
    sweep.st.justOpened = { cid = sweep.st.opening.cid, id = cfg.loot }
    return
  end
  st.wins[lwCid] = cfg.loot
  -- room at the loot bag's top: in it goes. Putting things into the loot bag shifts its slots, so what the
  -- sweep knew about the inner bags is dropped: their windows are closed and forgotten
  if lw:getItemsCount() < lw:getCapacity() then
    for cid, id in pairs(st.wins) do
      if cid ~= lwCid then
        local w = windowAt(cid, id)
        if w then pcall(function() g_game.close(w) end) end
        st.wins[cid] = nil
      end
    end
    st.opened = {}
    sweep.full = false
    sweep.lastMove = g_clock.millis()
    g_game.move(loose, lw:getSlotPosition(lw:getItemsCount()), loose:getCount())
    log(('loot sweep: %dx %s into your %s'):format(loose:getCount(), RouteItems.name(loose:getId()), RouteItems.name(cfg.loot)))
    return
  end
  -- the top is full: an inner bag we opened with room
  for cid, id in pairs(st.wins) do
    if cid ~= lwCid then
      local w = windowAt(cid, id)
      if w and w:getItemsCount() < w:getCapacity() then
        sweep.full = false
        sweep.lastMove = g_clock.millis()
        g_game.move(loose, w:getSlotPosition(w:getItemsCount()), loose:getCount())
        log(('loot sweep: %dx %s into a bag inside your %s'):format(loose:getCount(), RouteItems.name(loose:getId()), RouteItems.name(cfg.loot)))
        return
      end
    end
  end
  -- none with room: open the next inner bag
  for _, it in ipairs(lw:getItems()) do
    if RouteBags.isBag(it) and not st.opened[RouteBags.keyOf(it, st)] then
      st.opened[RouteBags.keyOf(it, st)] = true
      RouteBags.issueOpen(st, it, 'carried')
      st.justOpened = { cid = st.opening.cid, id = it:getId() }
      return
    end
  end
  sweep.full = true
  if not sweep.fullWarned then
    sweep.fullWarned = true
    log(('loot sweep: your %s and the bags in it are full - loose loot stays in the main backpack until the depot'):format(RouteItems.name(cfg.loot)))
  end
end

-- Why the last Refill check sent you off ('cap', 'supplies', 'loot'); the depot jobs read it to decide whether
-- they have anything to do on this trip
RouteDepot.refillReason = nil

-- how loaded the loot bag is, from its open window: items at its top and its capacity; nil when it is closed
function RouteDepot.lootBagLoad()
  local cfg = bagCfg()
  if not cfg then return nil end
  for _, c in pairs(g_game.getContainers()) do
    local ci = c:getContainerItem()
    if c:hasParent() and ci and ci:getId() == cfg.loot then return c:getItemsCount(), c:getCapacity() end
  end
  return nil
end

-- For the Refill check: is the loot bag full? The sweep knows once it has tried; without it, the loot bag's
-- own window tells when its top is full and no inner bag with room is open.
function RouteDepot.lootBagFull()
  if sweep.muteFullUntil and g_clock.millis() < sweep.muteFullUntil then return false end
  if sweep.full then return true end
  local cfg = bagCfg()
  if not cfg then return false end
  local lw
  for _, c in pairs(g_game.getContainers()) do
    local ci = c:getContainerItem()
    if c:hasParent() and ci and ci:getId() == cfg.loot then lw = c end
  end
  if not lw or lw:getItemsCount() < lw:getCapacity() then return false end
  for cid, id in pairs(sweep.st and sweep.st.wins or {}) do
    local w = windowAt(cid, id)
    if w and w ~= lw and w:getItemsCount() < w:getCapacity() then return false end
  end
  return true
end

function RouteDepot.setHuntSweep(on)
  if sweep.timer then removeEvent(sweep.timer) sweep.timer = nil end
  sweep.st, sweep.warned, sweep.fullWarned = nil, false, false
  sweep.full = false
  if on then sweep.timer = scheduleEvent(sweepTick, 1000) end
end
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
