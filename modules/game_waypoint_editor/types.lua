-- Every waypoint type the cavebot understands, with the colour the bot itself gives it (cavebot/actions.lua)
-- and the titles from its editor (cavebot/editor.lua), so the map and the bot's own list agree.
--   spatial  = the value carries a position, so it can live on the map
--   editor   = which editor window the value needs
--   glyph    = one or two characters drawn on the map marker
RouteTypes = {}

RouteTypes.list = {
  { id = 'goto',      title = 'Go to',       glyph = 'G',  colour = '#3cc84b', spatial = 'pos',
    editor = 'pos',    hint = 'Walk to this tile.' },
  { id = 'use',       title = 'Use',         glyph = 'U',  colour = '#ffb272', spatial = 'pos',
    editor = 'pos',    hint = 'Use whatever is on this tile - ladder, hole, lever, rope spot.' },
  { id = 'usewith',   title = 'Use with',    glyph = 'UW', colour = '#eeb292', spatial = 'itempos',
    editor = 'itempos', hint = 'Use an item on this tile. Any item works - rope, shovel, machete, a key, a blood herb on an altar. Write an id or a name from the item table, then the tile.' },
  { id = 'label',     title = 'Label',       glyph = 'L',  colour = '#ffff55', spatial = false,
    editor = 'text',   hint = 'A name you can jump to from anywhere in the route.' },
  { id = 'gotolabel', title = 'Go to label', glyph = 'GL', colour = '#ffe14d', spatial = false,
    editor = 'text',   hint = 'Jump to a label - this is how loops and branches are built.' },
  { id = 'delay',     title = 'Delay',       glyph = 'D',  colour = '#aaaaaa', spatial = false,
    editor = 'number', hint = 'Wait this many milliseconds before the next action.' },
  { id = 'say',       title = 'Say',         glyph = 'S',  colour = '#ff55ff', spatial = false,
    editor = 'text',   hint = 'Say something: a spell, an npc word, a command like !autoloot.' },
  { id = 'function',  title = 'Function',    glyph = 'F',  colour = '#ff5555', spatial = false,
    editor = 'lua',    hint = 'Run lua. Anything the bot can do - buying, depositing, selling, luring.' },
}

-- labels and jumps are the bot's bookkeeping: the editor shows them as flavour on real waypoints, never as
-- things of their own, so they are not offered for placing
function RouteTypes.hidden(entry) return entry ~= nil and (entry.action == 'label' or entry.action == 'gotolabel') end
RouteTypes.placeable = {}
for _, t in ipairs(RouteTypes.list) do
  if t.id ~= 'label' and t.id ~= 'gotolabel' then RouteTypes.placeable[#RouteTypes.placeable + 1] = t end
end

RouteTypes.byId = {}
for _, t in ipairs(RouteTypes.list) do RouteTypes.byId[t.id] = t end

function RouteTypes.get(id) return RouteTypes.byId[id] end

-- Position and description are recomputed only when the entry itself changed: a route of a few hundred
-- waypoints is walked on every redraw, and parsing each value every time is what made that O(n) expensive.
local function cacheKey(entry) return tostring(entry.action) .. '\0' .. tostring(entry.value) end

function RouteTypes.positionOf(entry)
  local key = cacheKey(entry)
  if entry._key == key then return entry._pos end
  entry._key, entry._desc = key, nil
  entry._pos = RouteTypes.parsePosition(entry)
  return entry._pos
end

-- A function has no position of its own - except the one-click jobs, which carry their tile in the script as
-- `local spot = { x = .., y = .., z = .. }`. That line is the position: the marker sits there, and moving the
-- marker (or picking a tile) rewrites that line and nothing else, so edited parameters stay.
local SPOT = 'local%s+spot%s*=%s*{%s*x%s*=%s*(%-?%d+)%s*,%s*y%s*=%s*(%-?%d+)%s*,%s*z%s*=%s*(%-?%d+)%s*}'

function RouteTypes.parsePosition(entry)
  local t = RouteTypes.byId[entry.action]
  if entry.action == 'function' then
    local x, y, z = tostring(entry.value or ''):match(SPOT)
    if x then return { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
    return nil
  end
  if not t or not t.spatial then return nil end
  local value = tostring(entry.value or '')
  if t.spatial == 'pos' then
    local x, y, z = value:match('^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$')
    if x then return { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
    -- "use" also accepts a bare item id, which simply has nowhere to sit on the map
  elseif t.spatial == 'itempos' then
    local item, x, y, z = value:match('^%s*(%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$')
    if x then return { x = tonumber(x), y = tonumber(y), z = tonumber(z), item = tonumber(item) } end
  end
  return nil
end

function RouteTypes.withPosition(entry, pos)
  local t = RouteTypes.byId[entry.action]
  if entry.action == 'function' then
    local value = tostring(entry.value or '')
    local new, n = value:gsub('(local%s+spot%s*=%s*{%s*x%s*=%s*)%-?%d+(%s*,%s*y%s*=%s*)%-?%d+(%s*,%s*z%s*=%s*)%-?%d+',
      ('%%1%d%%2%d%%3%d'):format(pos.x, pos.y, pos.z), 1)
    return n > 0 and new or value
  end
  if not t or not t.spatial then return entry.value end
  if t.spatial == 'pos' then
    return ('%d,%d,%d'):format(pos.x, pos.y, pos.z)
  end
  local item = tostring(entry.value or ''):match('^%s*(%d+)') or '0'
  return ('%s,%d,%d,%d'):format(item, pos.x, pos.y, pos.z)
end

-- what a freshly placed waypoint of this type starts with
function RouteTypes.defaultValue(id, pos)
  if id == 'goto' or id == 'use' then return ('%d,%d,%d'):format(pos.x, pos.y, pos.z) end
  if id == 'usewith' then return ('3003,%d,%d,%d'):format(pos.x, pos.y, pos.z) end
  if id == 'delay' then return '500' end
  if id == 'label' then return 'label' end
  if id == 'gotolabel' then return 'label' end
  if id == 'say' then return 'hi' end
  if id == 'function' then return 'return true' end
  return ''
end

-- one line describing a waypoint, for the sequence list
function RouteTypes.describe(entry)
  local key = cacheKey(entry)
  if entry._key == key and entry._desc then return entry._desc end
  if entry._key ~= key then
    entry._key = key
    entry._pos = RouteTypes.parsePosition(entry)
  end
  entry._desc = RouteTypes.buildDescription(entry)
  return entry._desc
end

function RouteTypes.buildDescription(entry)
  local q = RouteTypes.quickOf(entry)
  if q then
    local x, y, z = tostring(entry.value or ''):match('local spot = { x = (%d+), y = (%d+), z = (%d+) }')
    if x then return ('%s  at %s,%s,%s'):format(q.title, x, y, z) end
    local target = tostring(entry.value or ''):match("local label%s*=%s*'([^']*)'")
    if target then return ('%s  -> %s when low'):format(q.title, target) end
    return q.title
  end
  local t = RouteTypes.byId[entry.action]
  local value = tostring(entry.value or ''):gsub('\n', ' '):gsub('%s+', ' ')
  local room = 30 - #(t and t.title or entry.action)      -- the row is 281px: keep the line inside it
  if #value > room then value = value:sub(1, math.max(4, room - 3)) .. '...' end
  return ('%s  %s'):format(t and t.title or entry.action, value)
end

function RouteTypes.quickGet(id)
  for _, q in ipairs(RouteTypes.quick or {}) do if q.id == id then return q end end
  return nil
end

-- Waypoints you can drop in one click. They are ordinary function waypoints - the cavebot never sees anything
-- new - but the palette places them with their script already written, so a depot trip does not start with
-- "add function, open it, find the template, edit it".
-- Placed on the map, a job means "go there, then do it" - the position is written into the script when the
-- waypoint is placed (the %POS% below). Line one tags the job so the marker keeps its own glyph and colour.
local WALK = [[
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
local spot = %POS%
local me = player:getPosition()
if me.z == spot.z and math.max(math.abs(me.x - spot.x), math.abs(me.y - spot.y)) > 1 then
  if retries > 40 then botlog('could not reach the spot, carrying on') return false end
  if retries == 0 then botlog(('walking to %d,%d'):format(spot.x, spot.y)) end
  autoWalk(spot, 60, { precision = 1 })
  delay(400)
  return 'retry'
end
]]

-- A depot job needs a locker, not a square: get into the room the waypoint was dropped in, find the nearest
-- locker with nobody standing at it, go and stand there. Every depot job starts this way, so "deposit" can
-- never run without a depot in reach.
local DEPOT_WALK = [[
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
local spot = %POS%
local me = player:getPosition()
-- WALKING phase: only this phase gives up on too many retries. Once we are at the locker the deposit runs
-- for as many retries as it takes, so the retry counter must never abort it mid-drop.
if me.z ~= spot.z or math.max(math.abs(me.x - spot.x), math.abs(me.y - spot.y)) > 6 then
  if retries > 60 then botlog('could not reach the depot, carrying on') return false end
  if retries == 0 then botlog('heading to the depot') end
  autoWalk(spot, 80, { precision = 3 })
  delay(400)
  return 'retry'
end
local depot = modules.game_waypoint_editor.RouteDepot.nearestFreeLocker(8)
if not depot then
  if retries % 10 == 0 then botlog('waiting for a free depot locker') end
  delay(600)
  return 'retry'
end
if not (me.x == depot.stand.x and me.y == depot.stand.y) then
  botlog(('going to a free locker at %d,%d'):format(depot.stand.x, depot.stand.y))
  autoWalk(depot.stand, 30, { precision = 0 })
  delay(400)
  return 'retry'
end
]]
RouteTypes.quick = {
  { id = 'q_depot',    title = 'Open depot',      glyph = 'DP', colour = '#7fd4ff',
    body = "-- job:q_depot  go to the depot, find a free locker, open it and the chest inside\n" .. DEPOT_WALK ..
           "return modules.game_waypoint_editor.RouteDepot.openOnly()" },
  { id = 'q_deposit',  title = 'Deposit loot (individual items)', glyph = 'DL', colour = '#7fffb0',
    body = "-- job:q_deposit  go to the depot, find a free locker, put these away\n" .. DEPOT_WALK ..
           "-- the items ticked 'depot' in the Loot window\n" ..
           "return modules.game_waypoint_editor.RouteDepot.tick(modules.game_waypoint_editor.RouteLoot.depositIds())" },
  { id = 'q_deposit_bags', title = 'Deposit loot (backpacks)', glyph = 'DB', colour = '#5ce0a0',
    body = "-- job:q_deposit_bags  go to the depot, sweep loose loot into the loot backpack, drop it off whole, take an empty one\n" ..
           "local dropWhenAtLeast = 10   -- items at the loot bag's top; lighter than this it is kept when you only came for supplies\n" ..
           "local RP = modules.game_waypoint_editor\n" ..
           "if retries == 0 and RP.RouteDepot.refillReason == 'supplies' then\n" ..
           "  local n = RP.RouteDepot.lootBagLoad()\n" ..
           "  if n and n < dropWhenAtLeast and not RP.RouteDepot.lootBagFull() then\n" ..
           "    RP.RouteBags.log(('the loot backpack holds only %d items and you came for supplies - keeping it'):format(n))\n" ..
           "    return true\n  end\nend\n" .. DEPOT_WALK ..
           "return RP.RouteDepot.swapBags()" },
  { id = 'q_withdraw', title = 'Take from depot', glyph = 'TD', colour = '#b0e57c',
    body = "-- job:q_withdraw  go to the depot, find a free locker, take these out\n" .. DEPOT_WALK ..
           "local ids, want = { 268, 238 }, 100\n" ..
           "return modules.game_waypoint_editor.RouteDepot.withdraw(ids, want)" },
  { id = 'q_supplies', title = 'Buy supplies',    glyph = 'BS', colour = '#ffd166',
    body = "-- job:q_supplies  walk to the shop and buy what the supply list is short of\n" ..
           "-- nothing short (by the counts the game printed or the open bags) means no walk and no npc talk\n" ..
           "local RP = modules.game_waypoint_editor\n" ..
           "if #RP.RouteSupply.list() == 0 then return true end\n" ..
           "if retries == 0 and #RP.RouteSupply.anythingShort() == 0 then\n" ..
           "  RP.RouteBags.log('supplies are up to the list - skipping the shop')\n  return true\nend\n" .. WALK ..
           "return RP.RouteSupply.tick()" },
  { id = 'q_sell',     title = 'Sell loot',       glyph = 'SL', colour = '#ffb272',
    body = "-- job:q_sell  walk to the npc and sell all it buys except the 'keep' items in the Loot window\n" .. WALK ..
           "return modules.game_waypoint_editor.RouteLoot.sell()" },
  { id = 'q_refill',   title = 'Refill check',    glyph = 'RC', colour = '#ffd7a0',
    body = "-- job:q_refill  go to a label when free capacity or a supply runs low; otherwise carry on hunting\n" ..
           "local minCap = 300      -- oz of free capacity: below this you go and refill\n" ..
           "local lowPct = 25       -- a supply row below this percent of its target sends you too\n" ..
           "local label  = 'depo'   -- the label the depot trip starts at\n" ..
           "local lootFull = true   -- also go when the loot backpack (and the bags in it) is full\n" ..
           "local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end\n" ..
           [[
local RP = modules.game_waypoint_editor
local why, reason
local free = player:getFreeCapacity()
if free < minCap then why, reason = ('%.0f oz free, below %d'):format(free, minCap), 'cap' end
if not why then
  -- the count the game printed the last time you used the item, else what is visible in open bags
  for _, row in ipairs(RP.RouteSupply.list()) do
    local id = RP.RouteItems.id(row.item)
    if id and not row.fullCap and (row.amount or 0) > 0 then
      local n, src = RP.RouteSupply.carried(id)
      if n * 100 < row.amount * lowPct then why, reason = ('%d %s of %d, below %d%% (%s)'):format(n, row.item, row.amount, lowPct, src), 'supplies' break end
    end
  end
end
if not why and lootFull and RP.RouteDepot.lootBagFull() then why, reason = 'the loot backpack is full', 'loot' end
if why then
  RP.RouteDepot.refillReason = reason
  botlog('refill: ' .. why .. ' - going to ' .. label)
  if not gotoLabel(label) then botlog('there is no label "' .. label .. '" in this route - carrying on') end
end
return true]] },
  { id = 'q_pause',    title = 'Wait for fight',  glyph = 'WF', colour = '#aaaaaa',
    body = "-- job:q_pause  stand here until the targetbot is done\n" ..
           "local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end\n" ..
           "if TargetBot and TargetBot.isActive() then\n  if retries == 0 then botlog('waiting for the fight to end') end\n  delay(500)\n  return 'retry'\nend\nif retries > 0 then botlog('fight over, carrying on') end\nreturn true" },
}

-- the job a function waypoint was placed as, read off its tag line; nil for a hand written function
function RouteTypes.quickOf(entry)
  if not entry or entry.action ~= 'function' then return nil end
  local id = tostring(entry.value or ''):match('^%-%- job:([%w_]+)')   -- %w alone misses the underscore
  return id and RouteTypes.quickGet(id) or nil
end

-- what a waypoint looks like on the map: the job if it is one, the plain type otherwise
function RouteTypes.look(entry)
  return RouteTypes.quickOf(entry) or RouteTypes.byId[entry.action]
end

-- the script with the position written in
function RouteTypes.quickBody(q, pos)
  local lit = pos and ('{ x = %d, y = %d, z = %d }'):format(pos.x, pos.y, pos.z) or 'player:getPosition()'
  return (q.body:gsub('%%POS%%', lit))
end

-- Ready made function waypoints. A full afk system is mostly these: walk a loop, and at the right point
-- deposit, refill, sell, and come back. They are inserted into the function editor as a starting point.
RouteTypes.templates = {
  { title = 'Open the depot next to you', body = [[
-- What stands in the depot room is a locker (3497/3499); the depot chest (3502) is inside it. So this uses
-- the locker first, then opens the chest it finds in there.
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
local function minimizeOpen()
  local root = g_ui.getRootWidget()
  for cid in pairs(g_game.getContainers()) do
    local w = root:recursiveGetChildById('container' .. cid)
    if w and w.minimize then pcall(function() w:minimize() end) end
  end
end
if retries > 15 then botlog('gave up opening the depot') return false end
for _, c in pairs(g_game.getContainers()) do
  if c:getName():lower():find('depot chest') then return true end     -- already open
end
local locker
for _, c in pairs(g_game.getContainers()) do
  if c:getName():lower():find('locker') then locker = c end
end
if locker then
  for _, it in ipairs(locker:getItems()) do
    if it:getId() == 3502 then                 -- the locker also holds the store inbox and the market box
      botlog('opening the depot chest')
      minimizeOpen()
      g_game.open(it)
      delay(800)
      return 'retry'
    end
  end
  botlog('the locker is open but there is no chest in it')
  return false
end
local me = { x = posx(), y = posy(), z = posz() }
for dx = -1, 1 do
  for dy = -1, 1 do
    local tile = g_map.getTile({ x = me.x + dx, y = me.y + dy, z = me.z })
    if tile then
      for _, thing in ipairs(tile:getThings()) do
        local id = thing:getId()
        if id == 3497 or id == 3499 or id == 3502 then
          botlog('reached the depot, opening the locker')
          g_game.use(thing)
          delay(800)
          return 'retry'
        end
      end
    end
  end
end
botlog('no depot locker next to me')
return false
]] },
  { title = 'Deposit these items into the depot', body = [[
-- The preset's Depositer extension is an empty stub, so the work is done by the editor's own depositer. It
-- searches every bag you carry, however many and however deeply nested, waits for each container to really
-- open instead of guessing, keeps the window count under the client's limit, and never touches the store
-- inbox. Returns 'retry' until it has finished, exactly like any other waypoint.
local ids = { 3031, 3035, 3043 }          -- edit: what you want stored
return modules.game_waypoint_editor.RouteDepot.tick(ids)
]] },
  { title = 'Take these items out of the depot', body = [[
-- The editor's own withdraw engine: counts what you carry (closed bags too), opens the locker and the chest,
-- looks through the depot bags for these ids and moves them into your bags until you hold `want` of each.
-- Returns 'retry' until it has finished, exactly like any other waypoint.
local ids  = { 268, 238 }                 -- edit: what to withdraw
local want = 100                          -- how many of each you want to end up carrying
return modules.game_waypoint_editor.RouteDepot.withdraw(ids, want)
]] },
  { title = 'Buy supplies, as many as gold and capacity allow', body = [[
local id, want   = 268, 100      -- edit: what to buy, and the most you want
local leaveCap   = 200           -- stop before free capacity drops under this
local withBackpack = false       -- true buys them inside a fresh backpack: one slot instead of many
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if retries > 20 then botlog('gave up buying ' .. id) return false end
if not NPC.isTrading() then
  NPC.say('hi')
  NPC.say('trade')
  delay(600)
  return 'retry'
end
local entry
for _, b in ipairs(NPC.getBuyItems()) do if b.id == id then entry = b end end
if not entry then botlog('this npc does not sell ' .. id) return true end
local money = 0
for _, c in pairs(g_game.getContainers()) do
  if not c:getName():lower():find('store inbox') then
    for _, it in ipairs(c:getItems()) do
      local iid = it:getId()
      if iid == 3031 then money = money + it:getCount()
      elseif iid == 3035 then money = money + it:getCount() * 100
      elseif iid == 3043 then money = money + it:getCount() * 10000 end
    end
  end
end
local byGold = entry.price > 0 and math.floor(money / entry.price) or want
-- the trade window reports a weight of zero for a lot of items on this server, so a zero weight means
-- "cannot tell" rather than "weightless", and capacity simply does not limit the amount
local byCap = (entry.weight and entry.weight > 0)
              and math.floor(math.max(0, freecap() - leaveCap) / entry.weight) or want
local slots = 0
for _, c in pairs(g_game.getContainers()) do
  local n = c:getName():lower()
  if not n:find('depot') and not n:find('locker') and not n:find('store inbox') then
    slots = slots + math.max(0, c:getCapacity() - c:getItemsCount())
  end
end
local amount = math.min(want, byGold, byCap)
if amount < 1 then
  botlog(('cannot buy %s: %d gold buys %d, capacity allows %d'):format(entry.name, money, byGold, byCap))
  return true
end
-- only open containers can be counted, so this is a floor not a truth: keep your bags open, or set
-- withBackpack, which needs a single slot for the whole purchase
if slots < 1 and not withBackpack then
  botlog('no free slot in any open bag - open your bags or set withBackpack = true')
  return true
end
local take = math.min(amount, 100)
botlog(('buying %dx %s for %d gold'):format(take, entry.name, take * entry.price))
NPC.buy(id, take, false, withBackpack)
delay(800)
if amount > 100 then return 'retry' end       -- the protocol takes 100 at a time
return true
]] },
  { title = 'Sell only certain item ids', body = [[
local items = { 3031, 3035, 3043 }      -- edit: the ids you want sold
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if retries > 20 then botlog('gave up selling') return false end
if not NPC.isTrading() then
  NPC.say('hi')
  NPC.say('trade')
  delay(600)
  return 'retry'
end
local takes = {}
for _, s in ipairs(NPC.getSellItems()) do takes[s.id] = s end
local sold, skipped = {}, {}
for _, id in ipairs(items) do
  if takes[id] then
    NPC.sell(id, -1)                    -- -1 sells every one you carry, including bags you have not opened
    sold[#sold + 1] = takes[id].name
    delay(300)
  else
    skipped[#skipped + 1] = tostring(id)
  end
end
if #sold > 0 then botlog('sold ' .. table.concat(sold, ', ')) end
if #skipped > 0 then botlog('this npc does not buy: ' .. table.concat(skipped, ', ')) end
NPC.closeTrade()
NPC.say('bye')
return true
]] },
  { title = 'Sell everything this npc buys', body = [[
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if retries > 20 then botlog('gave up selling') return false end
if not NPC.isTrading() then
  NPC.say('hi')
  NPC.say('trade')
  delay(600)
  return 'retry'
end
local names = {}
for _, s in ipairs(NPC.getSellItems()) do names[#names + 1] = s.name end
botlog('selling everything this npc takes: ' .. table.concat(names, ', '))
NPC.sellAll()
delay(600)
NPC.closeTrade()
NPC.say('bye')
return true
]] },
  { title = 'Walk to a position', body = [[
local spot = { x = 1234, y = 5678, z = 7 }   -- edit: where to stand
local close = 1                              -- how near is near enough
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if retries > 25 then botlog('could not reach the spot') return false end
local p = player:getPosition()
if p.z ~= spot.z then botlog('wrong floor for that spot') return false end
if math.max(math.abs(p.x - spot.x), math.abs(p.y - spot.y)) <= close then
  if retries > 0 then botlog(('arrived at %d,%d'):format(spot.x, spot.y)) end
  return true
end
if retries == 0 then botlog(('walking to %d,%d'):format(spot.x, spot.y)) end
autoWalk(spot, 40, { precision = close })
delay(400)
return 'retry'
]] },
  { title = 'Walk to a named npc, then trade', body = [[
-- getCreatureByName only finds what is on screen, so from across town the name alone is not enough. Fill in
-- spot with a tile next to the npc and it walks there first, then talks once the npc comes into view.
local name = 'Eryn'                      -- edit: the npc name
local spot = nil                         -- edit: { x = 1234, y = 5678, z = 7 }, or leave nil if it is close
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if retries > 20 then botlog('could not reach ' .. name) return false end
local npc = getCreatureByName(name)
local dest = npc and npc:getPosition() or spot
if not dest then botlog(name .. ' is not on screen and no spot was set') return false end
local p = player:getPosition()
if math.max(math.abs(p.x - dest.x), math.abs(p.y - dest.y)) > 3 then
  if retries == 0 then botlog('walking to ' .. name) end
  autoWalk(dest, 30, { precision = 3 })  -- autoWalk(destination, maxDist, params): a table as the second
  delay(400)                             -- argument is read as maxDist and nothing walks
  return 'retry'
end
if not npc then
  delay(400)
  return 'retry'                         -- on the spot, waiting for the npc to come into view
end
if not NPC.isTrading() then
  NPC.say('hi')
  NPC.say('trade')
  delay(600)
  return 'retry'
end
botlog('trading with ' .. name)
return true
]] },
  { title = 'Travel with a boat npc', body = [[
local dest = 'venore'                    -- edit: the destination
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if retries == 0 then
  botlog('asking the boat for passage to ' .. dest)
  NPC.say('hi')
  delay(800)
  return 'retry'
end
NPC.say(dest)
delay(400)
NPC.say('yes')
delay(3000)
botlog('travelled to ' .. dest)
return true
]] },
  { title = 'Stop walking while the targetbot fights', body = [[
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if TargetBot and TargetBot.isActive() then
  if retries == 0 then botlog('a fight is on - waiting before I walk on') end
  delay(500)
  return 'retry'
end
if retries > 0 then botlog('fight over, carrying on') end
return true
]] },
  { title = 'Go to a label when supplies run out', body = [[
-- a closed backpack has nothing in it as far as the client is concerned, and counting zero would send you
-- to refill for no reason, so nothing is decided until a container is actually open
local ids  = { 268, 7590 }                 -- edit: your potion ids
local least = 20
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
local open, n = 0, 0
for _, c in pairs(g_game.getContainers()) do
  if not c:getName():lower():find('store inbox') then open = open + 1 end
end
if open == 0 then return true end
for _, c in pairs(g_game.getContainers()) do
  if not c:getName():lower():find('store inbox') then
    for _, it in ipairs(c:getItems()) do
      for _, id in ipairs(ids) do
        if it:getId() == id then n = n + it:getCount() end
      end
    end
  end
end
if n < least then
  botlog(('supplies low: %d left, going to the refill label'):format(n))
  gotoLabel('refill')
else
  botlog(('supplies fine: %d left, carrying on'):format(n))
end
return true
]] },
  { title = 'Wait until your backpack has room', body = [[
local function botlog(m) local l='BOT: '..m modules.game_console.addText(l,{color='#FFA24D'},'Server Log') local bc=modules.game_better_chat if bc and bc.addServerLine then bc.addServerLine(l,'#F6A731') end end
if freecap() < 100 then
  botlog(('capacity down to %.0f, going to the depot label'):format(freecap()))
  gotoLabel('depot')
end
return true
]] },

}

-- the examples the cavebot itself ships with, read out of the preset so they stay in sync
function RouteTypes.presetTemplates(botConfig)
  local out = {}
  local path = '/bot/' .. tostring(botConfig) .. '/cavebot/example_functions.lua'
  if not g_resources.fileExists(path) then return out end
  local text = tostring(g_resources.readFileContents(path))
  for title, body in text:gmatch('addExampleFunction%("([^"]+)",%s*%[%[(.-)%]%]') do
    out[#out + 1] = { title = title, body = body:gsub('^%s+', ''):gsub('%s+$', '') }
  end
  return out
end

-- Whole blocks of waypoints, not single ones. A full afk system is a handful of these stitched together,
-- so they are inserted complete and you fill in the positions by clicking the map.
RouteTypes.recipes = {
  -- A whole afk loop around the goto waypoints you drew: the label the hunt loops back to goes first in the
  -- route; the refill check and the depot trip go after the hunt. `quick` entries are one-click jobs placed
  -- where you stand when you insert the recipe - drag the depot and the shop ones to their real spots.
  { title = 'AFK loop - refill check, depot trip (deposit + supplies), back to the hunt', entries = {
      { action = 'label',     value = 'hunt', first = true },
      { quick = 'q_refill' },
      { action = 'gotolabel', value = 'hunt' },
      { action = 'label',     value = 'depo' },
      { quick = 'q_deposit_bags' },
      { quick = 'q_supplies' },
      { action = 'gotolabel', value = 'hunt' },
    } },
  { title = 'Supply check - jump to refill when potions run low', entries = {
      { action = 'function', value = [[
-- edit the ids and the amount for your character. A closed backpack counts as zero of everything, so the
-- check waits for a container to be open rather than running to refill on no information.
local open, n = 0, 0
for _ in pairs(g_game.getContainers()) do open = open + 1 end
if open == 0 then return true end
local ids = { 268, 7590 }
for _, c in pairs(g_game.getContainers()) do
  for _, it in ipairs(c:getItems()) do
    for _, id in ipairs(ids) do
      if it:getId() == id then n = n + it:getCount() end
    end
  end
end
if n < 30 then
  gotoLabel('refill')
end
return true]] },
    } },
  { title = 'Depot trip - deposit, sell, buy, then back to hunting', entries = {
      { action = 'label',    value = 'refill' },
      { action = 'function', value = "-- place goto waypoints from here to the depot, then this opens it\nreturn true" },
      { action = 'function', value = [[
-- the preset's Depositer extension is an empty stub, so the items are moved here
local ids = { 3031, 3035, 3043 }          -- edit: what you want stored
if retries > 20 then return false end
local depot
for _, c in pairs(g_game.getContainers()) do
  if c:getName():lower():find('depot chest') then depot = c end
end
if not depot then return false end
local moved = 0
for _, c in pairs(g_game.getContainers()) do
  local name = c:getName():lower()
  if not name:find('depot') and not name:find('locker') then
    for _, it in ipairs(c:getItems()) do
      for _, id in ipairs(ids) do
        if it:getId() == id then
          g_game.move(it, depot:getSlotPosition(depot:getItemsCount()), it:getCount())
          moved = moved + 1
        end
      end
    end
  end
end
if moved > 0 then delay(600) return 'retry' end
return true]] },
      { action = 'delay',    value = '1000' },
      { action = 'function', value = [[
-- sell loot: stand in front of the npc first
if retries > 10 then return false end
if not NPC.isTrading() then
  NPC.say('hi')
  NPC.say('trade')
  delay(600)
  return 'retry'
end
NPC.sellAll()
delay(600)
NPC.closeTrade()
NPC.say('bye')
return true]] },
      { action = 'function', value = [[
-- buy supplies
if retries > 10 then return false end
if not NPC.isTrading() then
  NPC.say('hi')
  NPC.say('trade')
  delay(600)
  return 'retry'
end
NPC.buy(268, 100)
schedule(1000, function()
  NPC.buy(268, 100)
  NPC.closeTrade()
  NPC.say('bye')
end)
delay(1200)
return true]] },
      { action = 'gotolabel', value = 'hunt' },
    } },
  { title = 'Lure block - turn luring on, wait, turn it off', entries = {
      { action = 'function', value = "if TargetBot then TargetBot.enableLuring() end\nreturn true" },
      { action = 'delay',    value = '2000' },
      { action = 'function', value = "if TargetBot then TargetBot.disableLuring() end\nreturn true" },
    } },
  { title = 'Hunting loop - label at the start, jump at the end', entries = {
      { action = 'label',     value = 'hunt' },
      { action = 'gotolabel', value = 'hunt' },
    } },
  { title = 'Pause here while the targetbot is fighting', entries = {
      { action = 'function', value = "if TargetBot and TargetBot.isActive() then\n  delay(500)\n  return 'retry'\nend\nreturn true" },
    } },
  { title = 'Log out when the backpack is full', entries = {
      { action = 'function', value = "if freecap() < 100 then\n  g_game.safeLogout()\n  delay(1000)\n  return 'retry'\nend\nreturn true" },
    } },
}

-- The cavebot loads every function waypoint with only these extras in scope (see cavebot/actions.lua),
-- everything else has to come from the bot context. A template that calls a function the preset does not
-- have fails silently at the worst moment, so the selftest audits them against the running bot.
local INJECTED = { retries = true, prev = true, delay = true, gotoLabel = true, macro = true, storage = true }
-- `and (`, `or (`, `not (` all look like a call to a name-followed-by-bracket scan
local LUA_KEYWORDS = {
  ['and'] = true, ['or'] = true, ['not'] = true, ['return'] = true, ['then'] = true, ['do'] = true,
  ['end'] = true, ['if'] = true, ['else'] = true, ['elseif'] = true, ['while'] = true, ['repeat'] = true,
  ['until'] = true, ['break'] = true, ['in'] = true, ['local'] = true, ['function'] = true, ['nil'] = true,
  ['true'] = true, ['false'] = true, ['for'] = true,
}
local LUA_BUILTINS = {
  math = true, string = true, table = true, os = true, io = true, bit = true, coroutine = true, debug = true,
  ipairs = true, pairs = true, next = true, type = true, tostring = true, tonumber = true, select = true,
  pcall = true, xpcall = true, error = true, assert = true, unpack = true, rawget = true, rawset = true,
  setmetatable = true, getmetatable = true, print = true, require = true, load = true, loadstring = true,
}

local function stripLiterals(body)
  body = body:gsub('%-%-%[%[.-%]%]', ' ')
  body = body:gsub('%-%-[^\n]*', ' ')
  body = body:gsub('%[%[.-%]%]', '""')
  body = body:gsub("'[^'\n]*'", '""')
  body = body:gsub('"[^"\n]*"', '""')
  return body
end

local function localsOf(code)
  local locals = {}
  for names in code:gmatch('local%s+([%a_][%w_%s,]*)') do
    for n in names:gmatch('[%a_][%w_]*') do
      if n ~= 'function' then locals[n] = true end
    end
  end
  for names in code:gmatch('for%s+([%a_][%w_%s,]*)') do
    for n in names:gmatch('[%a_][%w_]*') do locals[n] = true end
  end
  -- both 'function(a, b)' and 'local function name(a, b)' - the name form needs the gap
  for params in code:gmatch('function%s*[%a_][%w_]*%s*%b()') do
    for n in params:gmatch('[%a_][%w_]*') do locals[n] = true end
  end
  for params in code:gmatch('function%s*%b()') do
    for n in params:gmatch('[%a_][%w_]*') do locals[n] = true end
  end
  for name in code:gmatch('function%s+([%a_][%w_]*)') do locals[name] = true end
  return locals
end

-- returns a list of { where, name } for every global a body calls that the bot does not define
function RouteTypes.auditApi(ctx, extensions)
  local unknown, seen = {}, {}
  local function known(name)
    if INJECTED[name] or LUA_BUILTINS[name] or LUA_KEYWORDS[name] then return true end
    if extensions and extensions[name] then return true end
    if ctx and ctx[name] ~= nil then return true end
    return _G[name] ~= nil
  end
  local function scan(where, body)
    local code = stripLiterals(tostring(body))
    local locals = localsOf(code)
    local pos = 1
    while true do
      local s, _, name = code:find('([%a_][%w_]*)%s*[%(%.%:]', pos)
      if not s then break end
      pos = s + 1
      local before = s > 1 and code:sub(s - 1, s - 1) or ''
      -- a name after a dot or colon is a field or method, not a global; a name after a word char is a tail
      if not before:match('[%w_%.%:]') and not locals[name] and not known(name)
         and not seen[where .. '|' .. name] then
        seen[where .. '|' .. name] = true
        unknown[#unknown + 1] = { where = where, name = name }
      end
    end
  end
  for _, t in ipairs(RouteTypes.templates) do scan('template: ' .. t.title, t.body) end
  for _, q in ipairs(RouteTypes.quick or {}) do scan('job: ' .. q.title, RouteTypes.quickBody(q, { x = 1, y = 1, z = 1 })) end
  for _, r in ipairs(RouteTypes.recipes) do
    for _, e in ipairs(r.entries) do
      if e.action == 'function' then scan('recipe: ' .. r.title, e.value) end
      if e.quick then
        local q = RouteTypes.quickGet(e.quick)
        if q then scan('recipe: ' .. r.title, RouteTypes.quickBody(q, { x = 0, y = 0, z = 0 })) end
      end
    end
  end
  return unknown
end
