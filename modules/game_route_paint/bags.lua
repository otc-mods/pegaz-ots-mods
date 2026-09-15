-- The one way this module touches containers. Facts the client forced on us, all verified live:
--  * g_game.open on a container that is already open CLOSES it (the server toggles) - so start by closing all
--  * an open window's own item has no position and Container has no getParent: a window cannot be matched
--    back to the bag it came from, so what was opened into which window id is remembered instead
--  * g_game.open sends the lowest free window id; two opens in flight land on the same id and the second
--    replaces the first - so one open at a time, and the id is predicted before sending
--  * the server holds ~16 windows and delays a second use right after the first by ~1.4 s; the cavebot ticks
--    every 20-50 ms, so every wait here is wall-clock
RouteBags = {}

local OPEN_TIMEOUT = 4000          -- a use queued behind another is delayed ~1.4 s by the server; two in a row pass 2.5 s
local CLOSE_TIMEOUT = 1500
local WINDOW_SOFT_CAP = 10

function RouteBags.log(msg)
  local line = 'BOT: ' .. msg
  pcall(function() modules.game_console.addText(line, { color = '#FFA24D' }, 'Server Log') end)
  -- also feed Better chat, which listens to message events and never sees a direct addText
  local bc = modules.game_better_chat
  if bc and bc.addServerLine then pcall(function() bc.addServerLine(line, '#F6A731') end) end
end
local log = RouteBags.log

-- one of your bags, as opposed to the depot, its locker, the store inbox or the market
function RouteBags.isMine(c)
  local n = c:getName():lower()
  return not n:find('depot') and not n:find('locker') and not n:find('inbox') and not n:find('market')
end

function RouteBags.byName(fragment)
  for _, c in pairs(g_game.getContainers()) do
    if c:getName():lower():find(fragment) then return c end
  end
end

function RouteBags.openCount()
  local n = 0
  for _ in pairs(g_game.getContainers()) do n = n + 1 end
  return n
end

-- collapsing the windows is what lets the next open land without pushing an older one out
function RouteBags.minimizeOpen()
  local root = g_ui.getRootWidget()
  for cid in pairs(g_game.getContainers()) do
    local w = root:recursiveGetChildById('container' .. cid)
    if w and w.minimize then pcall(function() w:minimize() end) end
  end
end

-- must match the client's own choice exactly (Game::open takes the lowest free id) - never skip ids here
function RouteBags.nextContainerId()
  local cs = g_game.getContainers()
  local id = 0
  while cs[id] do id = id + 1 end
  return id
end

-- an item inside an open container has a position (window id + slot); that is its key
function RouteBags.keyOf(item)
  local q = item:getPosition()
  return q and (q.x .. ':' .. q.y .. ':' .. q.z) or tostring(item)
end

function RouteBags.closeAll(st)
  st.closedAt = g_clock.millis()
  if RouteBags.openCount() > 0 then
    for _, c in pairs(g_game.getContainers()) do pcall(function() g_game.close(c) end) end
  end
end

-- true while the closes issued by closeAll have not all landed (bounded)
function RouteBags.closing(st)
  return RouteBags.openCount() > 0 and g_clock.millis() - st.closedAt < CLOSE_TIMEOUT
end

-- st.side[cid] remembers what was opened into each window; side is 'carried', 'depot', 'chest' or 'locker'
function RouteBags.issueOpen(st, item, side)
  st.side = st.side or {}
  local cid = RouteBags.nextContainerId()
  st.side[cid] = { side = side, itemId = item:getId() }
  if st.counted then st.counted[cid] = nil end       -- a reused window id is a new container
  st.opening = { id = item:getId(), cid = cid, side = side, since = g_clock.millis() }
  RouteBags.minimizeOpen()
  g_game.open(item)
end

local TIMEOUT_TEXT = {
  carried = 'a bag in your backpack did not open in time - skipping it',
  depot = 'a depot bag did not open in time - skipping it',
  chest = 'the depot chest did not open in time',
  locker = 'the depot locker did not open in time',
}

-- true while the last issued open has neither landed nor timed out
function RouteBags.openPending(st)
  local o = st.opening
  if not o then return false end
  local landed
  if o.side == 'locker' then landed = RouteBags.byName('locker') ~= nil
  elseif o.side == 'chest' then landed = RouteBags.byName('depot chest') ~= nil
  else
    local c = g_game.getContainers()[o.cid]
    local ci = c and c:getContainerItem()
    landed = ci ~= nil and ci:getId() == o.id
  end
  if landed then st.opening = nil return false end
  if g_clock.millis() - o.since > OPEN_TIMEOUT then
    -- give up waiting, but keep the side tag: if the window lands late it is still recognised as what it is
    st.opening = nil
    log(TIMEOUT_TEXT[o.side] or 'a container did not open in time')
    return false
  end
  return true
end

-- the worn bags loot lives in: back and ammo. The purse is the store inbox on this server - never touched.
function RouteBags.wornBags()
  local me = g_game.getLocalPlayer()
  local out = {}
  if not me then return out end
  for _, slot in ipairs({ InventorySlotBack, InventorySlotAmmo }) do
    local it = me:getInventoryItem(slot)
    if it and it:isContainer() then
      local n = it:getName() and it:getName():lower() or ''
      if not n:find('inbox') and not n:find('market') and not n:find('store') then out[#out + 1] = { slot = slot, item = it } end
    end
  end
  return out
end

-- Count what you carry: close all, open the worn bags, then every bag inside them once, adding up each window
-- the first time it is seen. Returns 'busy' until the walk is done, then 'done' with st.counts (id -> count).
-- Windows are kept under the server's cap by closing bags whose inner bags have all been opened. If st.enough
-- is given (counts -> bool) the walk stops as soon as it says so: 200 wanted and 200 seen means the rest of the
-- bags do not need opening, whatever else they hold.
function RouteBags.countStep(st)
  st.counts = st.counts or {}
  st.counted = st.counted or {}
  st.opened = st.opened or {}
  st.side = st.side or {}
  st.wornOpen = st.wornOpen or {}
  if not g_game.getLocalPlayer() then return 'busy' end
  if not st.closedAt then RouteBags.closeAll(st) return 'busy' end
  if RouteBags.closing(st) then return 'busy' end
  if RouteBags.openPending(st) then return 'busy' end

  -- every window is one we opened; add up each once
  for cid, c in pairs(g_game.getContainers()) do
    if RouteBags.isMine(c) and not st.counted[cid] then
      st.counted[cid] = true
      st.bags = (st.bags or 0) + 1
      for _, it in ipairs(c:getItems()) do
        st.counts[it:getId()] = (st.counts[it:getId()] or 0) + it:getCount()
      end
    end
  end
  if st.enough and st.enough(st.counts) then st.stoppedEarly = true return 'done' end

  -- room for the next window: close a bag whose inner bags are all opened (never a worn root)
  if RouteBags.openCount() > WINDOW_SOFT_CAP then
    for cid, c in pairs(g_game.getContainers()) do
      if RouteBags.isMine(c) and c:hasParent() and st.counted[cid] then
        local pending = false
        for _, it in ipairs(c:getItems()) do
          if it:isContainer() and not st.opened[RouteBags.keyOf(it)] then pending = true end
        end
        if not pending then pcall(function() g_game.close(c) end) return 'busy' end
      end
    end
  end

  for _, worn in ipairs(RouteBags.wornBags()) do
    if not st.wornOpen[worn.slot] then
      st.wornOpen[worn.slot] = true
      RouteBags.issueOpen(st, worn.item, 'carried')
      return 'busy'
    end
  end

  for _, c in pairs(g_game.getContainers()) do
    if RouteBags.isMine(c) then
      for _, it in ipairs(c:getItems()) do
        if it:isContainer() and not st.opened[RouteBags.keyOf(it)] then
          st.opened[RouteBags.keyOf(it)] = true
          RouteBags.issueOpen(st, it, 'carried')
          return 'busy'
        end
      end
    end
  end
  return 'done'
end

-- gold, platinum and crystal coins plus golden nuggets (100 cc each on this server) in a counts table, in gold
function RouteBags.moneyOf(counts)
  return (counts[3031] or 0) + (counts[3035] or 0) * 100 + (counts[3043] or 0) * 10000 + (counts[3040] or 0) * 1000000
end

-- the end of a job: every window closed, then only the main backpack opened again
function RouteBags.finishStep(st)
  st.side = st.side or {}
  if not st.closedAt then
    RouteBags.closeAll(st)
    return 'retry'
  end
  if RouteBags.closing(st) then return 'retry' end
  if not st.reopened then
    st.reopened = true
    local me = g_game.getLocalPlayer()
    local it = me and me:getInventoryItem(InventorySlotBack)
    if it and it:isContainer() then RouteBags.issueOpen(st, it, 'carried') end
    return 'retry'
  end
  if RouteBags.openPending(st) then return 'retry' end
  return true
end
