-- The one way this module touches containers. Facts the client forced on us, all verified live:
--  * g_game.open on a container that is already open CLOSES it (the server toggles) - so start by closing all
--  * an open window's own item has no position and Container has no getParent: a window cannot be matched
--    back to the bag it came from, so what was opened into which window id is remembered instead
--  * g_game.open sends the lowest free window id; two opens in flight land on the same id and the second
--    replaces the first - so one open at a time, and the id is predicted before sending
--  * the server holds ~16 windows and delays a second use right after the first by ~1.4 s; the cavebot ticks
--    every 20-50 ms, so every wait here is wall-clock
RouteBags = {}

-- the server's last refusal ("Sorry, not possible.", "You cannot put more objects in this container.", ...),
-- so a job can tell a refused move from a slow one and say why it stopped
RouteBags.lastFailure = nil
-- only the texts a refused MOVE produces: the bot's own "You cannot use this object." must not count as one
connect(g_game, { onTextMessage = function(mode, text)
  local s = tostring(text or '')
  local l = s:lower()
  if l:find('not possible') or l:find('more objects') or l:find('enough room') or l:find('not enough') or l:find('too heavy')
     or l:find('cannot move') or l:find('cannot put') or l:find('depot') then
    RouteBags.lastFailure = { text = s, at = g_clock.millis() }
  end
end })

-- the one reason to turn the cavebot off: it cannot go on hunting. Everything else is logged and walked past.
function RouteBags.stopCavebot(why)
  local rp = modules.game_waypoint_editor
  local ok, ctx = pcall(function() return rp.botContext and rp.botContext() end)
  local cave = ok and ctx and ctx.CaveBot
  if cave and type(cave.setOff) == 'function' then pcall(function() cave.setOff() end) end
  log((why or 'cannot go on') .. ' - stopped the cavebot')
end

-- Items are moved on their own (the hunt-time sweep) only while the cavebot runs: with it off, your bags are yours.
function RouteBags.cavebotOn()
  local rp = modules.game_waypoint_editor
  local ok, ctx = pcall(function() return rp.botContext and rp.botContext() end)
  local cave = ok and ctx and ctx.CaveBot
  local ok2, on = pcall(function() return cave and cave.isOn and cave.isOn() end)
  return ok2 and on == true
end

-- what counts as a bag: the client's own word for it. (35577, unnamed in the old item table, is the raccoon backpack.)
function RouteBags.isBag(item) return item ~= nil and item:isContainer() end

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

-- An item inside an open window is known by window + slot. Window ids are reused as soon as a window closes,
-- so the id alone would make a bag in a later window look like one already opened in an earlier one at the
-- same slot - and skip it. The window's opening sequence number makes the key belong to one window only.
function RouteBags.keyOf(item, st)
  local q = item:getPosition()
  if not q then return tostring(item) end
  local cid = q.y - 64
  local seq = st and st.seq and st.seq[cid] or 0
  return seq .. ':' .. cid .. ':' .. q.z
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
function RouteBags.issueOpen(st, item, side, extra)
  st.side = st.side or {}
  local cid = RouteBags.nextContainerId()
  local rec = { side = side, itemId = item:getId() }
  for k, v in pairs(extra or {}) do rec[k] = v end
  st.side[cid] = rec
  if st.counted then st.counted[cid] = nil end       -- a reused window id is a new container
  st.seq = st.seq or {}
  st.seqN = (st.seqN or 0) + 1
  st.seq[cid] = st.seqN                              -- opening order: the newest window is searched first
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

-- The open windows, newest first. Looking for the next bag to open in this order goes DOWN a branch before
-- moving to the next sibling: a bag holding 19 bags then costs one window at a time, not 19 at once, which is
-- what kept the server's ~16-window limit from being hit and branches from being skipped.
function RouteBags.windowsDeepFirst(st)
  local list = {}
  for cid, c in pairs(g_game.getContainers()) do list[#list + 1] = { cid = cid, c = c, seq = (st.seq or {})[cid] or 0 } end
  table.sort(list, function(a, b) return a.seq > b.seq end)
  return list
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
          if RouteBags.isBag(it) and not st.opened[RouteBags.keyOf(it, st)] then pending = true end
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

  for _, w in ipairs(RouteBags.windowsDeepFirst(st)) do
    if RouteBags.isMine(w.c) then
      for _, it in ipairs(w.c:getItems()) do
        if RouteBags.isBag(it) and not st.opened[RouteBags.keyOf(it, st)] then
          st.opened[RouteBags.keyOf(it, st)] = true
          RouteBags.issueOpen(st, it, 'carried')
          return 'busy'
        end
      end
    end
  end
  return 'done'
end

-- "17x stone skin amulet, 9x winning lottery ticket, ..." - the most numerous ids in a counts table
function RouteBags.summarise(counts, limit)
  local rows = {}
  for id, n in pairs(counts or {}) do rows[#rows + 1] = { id = id, n = n } end
  table.sort(rows, function(a, b) return a.n > b.n end)
  local parts = {}
  for i = 1, math.min(limit or 6, #rows) do parts[#parts + 1] = ('%dx %s'):format(rows[i].n, RouteItems.name(rows[i].id)) end
  return #parts > 0 and table.concat(parts, ', ') or 'nothing'
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
