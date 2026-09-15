-- Named items and a supply list, so a route reads like a plan instead of a pile of numbers.
--
-- The client has no name -> id lookup we can trust (the trade window knows names, but only while it is open),
-- so the map is kept here and the player edits it. Anything the trade window teaches us is folded in
-- automatically the first time a shop is opened.
RouteItems = {}
RouteSupply = {}
RouteLoot = {}

local ITEM_DEFAULTS = {
  gold_coin = 3031, platinum_coin = 3035, crystal_coin = 3043,
  health_potion = 266, mana_potion = 268,
  strong_health_potion = 236, strong_mana_potion = 237,
  great_health_potion = 239, great_mana_potion = 238,
  great_spirit_potion = 7642, ultimate_health_potion = 7643,
  blank_rune = 3147, spellbook = 3059,
  sudden_death_rune = 3155, great_fireball_rune = 3191, explosion_rune = 3200,
  avalanche_rune = 3161, ultimate_healing_rune = 3160, intense_healing_rune = 3152,
  magic_wall_rune = 3180, wild_growth_rune = 3156, destroy_field_rune = 3148,
  paralyze_rune = 3165, heavy_magic_missile_rune = 3198, light_magic_missile_rune = 3174,
  rope = 3003, shovel = 3457, pick = 3456, machete = 3308, fishing_rod = 3483,
  depot_chest = 3502, depot_locker = 3497,
}

local data

-- g_settings returns array-like nodes STRING-keyed ({"1"=..,"2"=..}), and ipairs sees none of that - which
-- made saved loot/supply rows read as empty everywhere. Rebuild them as proper 1..n arrays on load.
local function toArray(v)
  if type(v) ~= 'table' then return {} end
  -- already a clean array?
  if #v > 0 or next(v) == nil then return v end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tonumber(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = v[k] or v[tostring(k)] end
  return out
end

local function load()
  data = g_settings.getNode('routeLibrary')
  if type(data) ~= 'table' then data = {} end
  if type(data.items) ~= 'table' then data.items = {} end
  data.supply = toArray(data.supply)
  data.loot = toArray(data.loot)
  -- each row's booleans also come back as strings sometimes; coerce
  for _, row in ipairs(data.loot) do
    for _, k in ipairs({ 'deposit', 'sell', 'keep' }) do
      if row[k] == 'true' then row[k] = true elseif row[k] == 'false' then row[k] = false end
    end
  end
  for name, id in pairs(ITEM_DEFAULTS) do
    if data.items[name] == nil then data.items[name] = id end
  end
end

local function persist()
  g_settings.setNode('routeLibrary', data)
  pcall(function() g_settings.save() end)
end

function RouteItems.init()
  load()
end

function RouteItems.all()
  if not data then load() end
  return data.items
end

-- The autoloot module ships an id -> name table for ~8800 items; a reverse of it lets any real item name
-- resolve, not just the handful we keep our own aliases for. Built once, lazily.
local autolootByName
local function autolootReverse()
  if autolootByName then return autolootByName end
  autolootByName = {}
  local al = modules.game_autoloot
  local src = al and al.AutolootNames
  if type(src) == 'table' then
    for id, nm in pairs(src) do
      if type(nm) == 'string' then autolootByName[nm:lower()] = tonumber(id) end
    end
  end
  return autolootByName
end

-- "great mana potion", "great_mana_potion" and 238 all resolve to 238; any autoloot-known item resolves too
-- names the server uses where the autoloot table has something else
local SERVER_NAMES = { [3040] = 'golden nugget', [35577] = 'raccoon backpack' }

function RouteItems.id(name)
  if not data then load() end
  if type(name) == 'number' then return name end
  local raw = tostring(name)
  for id, nm in pairs(SERVER_NAMES) do if nm == raw:lower():gsub('_', ' ') then return id end end
  local key = raw:lower():gsub('%s+', '_')
  local direct = data.items[key]
  if direct then return direct end
  local n = tonumber(raw)
  if n then return n end
  return autolootReverse()[raw:lower():gsub('_', ' '):gsub('%s+', ' ')]
end

function RouteItems.name(id)
  if SERVER_NAMES[id] then return SERVER_NAMES[id] end
  if not data then load() end
  for name, value in pairs(data.items) do
    if value == id then return (name:gsub('_', ' ')) end
  end
  local al = modules.game_autoloot
  if al and al.itemName then
    local nm = al.itemName(id)
    if nm and nm ~= '' and nm ~= 'unknown' then return nm end
  end
  return tostring(id)
end

function RouteItems.set(name, id)
  if not data then load() end
  local key = tostring(name):lower():gsub('%s+', '_')
  if not id or id == 0 then data.items[key] = nil else data.items[key] = tonumber(id) end
  persist()
end

-- Everything the npc is selling, with its real name: opening one shop teaches us more ids than any bundled
-- table ever will.
function RouteItems.learnFromTrade(entries)
  if not data then load() end
  local added = 0
  for _, e in ipairs(entries or {}) do
    local key = tostring(e.name or ''):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    if key ~= '' and data.items[key] == nil then
      data.items[key] = e.id
      added = added + 1
    end
  end
  if added > 0 then persist() end
  return added
end

-- ---------------------------------------------------------------- the supply list
-- Each row is { item = 'great_mana_potion', amount = 200 } or { item = ..., fullCap = 200 }, which means
-- "buy as many as fit, leaving 200 capacity free". Only one row may use fullCap.
function RouteSupply.list()
  if not data then load() end
  return data.supply
end

function RouteSupply.set(list)
  if not data then load() end
  local seenFullCap = false
  local clean = {}
  for _, row in ipairs(list or {}) do
    local item = row.item
    if item and item ~= '' then
      local entry = { item = item }
      if row.fullCap and not seenFullCap then
        seenFullCap = true
        entry.fullCap = tonumber(row.fullCap) or 200
      else
        entry.amount = math.max(0, tonumber(row.amount) or 0)
      end
      clean[#clean + 1] = entry
    end
  end
  data.supply = clean
  persist()
  return clean
end

function RouteSupply.describe()
  local out = {}
  for _, row in ipairs(RouteSupply.list()) do
    out[#out + 1] = ('%s %s'):format(tostring(row.item),
      row.fullCap and ('full cap minus ' .. row.fullCap) or ('x' .. tostring(row.amount)))
  end
  return out
end

-- What is still missing, given what the character carries and what the shop sells. `carried` is id -> count,
-- `shop` is id -> { price, weight }. Returns the buys { id, count, price, name } and the shortfalls - rows that
-- cannot be filled and why: { name, want, count, why = 'capacity' | 'gold' }.
function RouteSupply.plan(carried, shop, freeCapacity, money)
  local plan, short = {}, {}
  local budget = money or 0
  local cap = freeCapacity or 0
  for _, row in ipairs(RouteSupply.list()) do
    local id = RouteItems.id(row.item)
    local offer = id and shop and shop[id]
    if id and offer then
      local have = (carried and carried[id]) or 0
      local want
      local weight = (offer.weight and offer.weight > 0) and offer.weight or nil
      if row.fullCap then
        -- without a usable weight there is nothing to compute a full-cap amount from, so the row is skipped
        want = weight and math.floor(math.max(0, cap - row.fullCap) / weight) or nil
      else
        want = math.max(0, (row.amount or 0) - have)
      end
      if want and want > 0 then
        local price = offer.price or 0
        local byGold = price > 0 and math.floor(budget / price) or want
        local byCap = weight and math.floor(cap / weight) or want
        local count = math.min(want, byGold, byCap)
        if count < want and not row.fullCap then
          short[#short + 1] = { name = RouteItems.name(id), want = want, count = count, why = (byCap < byGold) and 'capacity' or 'gold' }
        end
        if count > 0 then
          plan[#plan + 1] = { id = id, count = count, price = price, name = RouteItems.name(id) }
          budget = budget - count * price
          if weight then cap = cap - count * weight end
        end
      end
    end
  end
  return plan, short
end

-- ---------------------------------------------------------------- buying against the supply list
local log = RouteBags.log

local function tradeOpen()
  local t = modules.game_npctrade
  return t and t.npcWindow and t.npcWindow:isVisible()
end

local function shopTable()
  local t = modules.game_npctrade
  local shop = {}
  if not tradeOpen() then return shop end
  for _, item in ipairs(t.tradeItems[t.BUY] or {}) do
    shop[item.ptr:getId()] = { price = item.price, weight = (item.weight or 0) / 100, name = item.name }
  end
  return shop
end

-- Say hi and trade until the npc opens its window. Paced by the clock, not by the tick: the waypoint calls
-- this every few tens of ms and the npc needs a moment to answer. true once open, 'retry' while waiting,
-- false after 15 s of silence.
local function openTrade(j)
  if tradeOpen() then return true end
  local now = g_clock.millis()
  j.greetAt = j.greetAt or 0
  j.greetSince = j.greetSince or now
  if now - j.greetSince > 15000 then log('no npc would open a trade window') return false end
  if now - j.greetAt >= 1500 then
    j.greetAt = now
    if g_game.getClientVersion() >= 810 then
      g_game.talkChannel(11, 0, 'hi')
      g_game.talkChannel(11, 0, 'trade')
    else
      g_game.talk('hi')
      g_game.talk('trade')
    end
  end
  return 'retry'
end

-- what you hold of these ids in the windows open right now (bought items land in the open main backpack)
local function openTotals(ids)
  local totals = {}
  for _, c in pairs(g_game.getContainers()) do
    if RouteBags.isMine(c) then
      for _, it in ipairs(c:getItems()) do
        if ids[it:getId()] then totals[it:getId()] = (totals[it:getId()] or 0) + it:getCount() end
      end
    end
  end
  return totals
end

-- The game says how many you have left whenever you use something - "Using one of 100 great mana potions..."
-- - so the count of every supply you actually use is known without opening a single bag. Remembered per item
-- id with its time; the Buy supplies job and the Refill check trust a count that is at most CHAT_FRESH_MS old.
RouteSupply.seen = {}
local CHAT_FRESH_MS = 45 * 60 * 1000

local function idFromPlural(name)
  local n = tostring(name or ''):lower()
  return RouteItems.id(n) or RouteItems.id((n:gsub('ies$', 'y'))) or RouteItems.id((n:gsub('es$', ''))) or RouteItems.id((n:gsub('s$', '')))
end

connect(g_game, { onTextMessage = function(mode, text)
  local n, name = tostring(text or ''):match('^Using one of (%d+) (.-)%.%.%.%s*$')
  if not n then return end
  local id = idFromPlural(name)
  if id then RouteSupply.seen[id] = { count = math.max(0, tonumber(n) - 1), at = g_clock.millis() } end
end })

-- how many of an item you carry, and where that number comes from: a fresh chat count, else the open bags
function RouteSupply.carried(id)
  local s = RouteSupply.seen[id]
  if s and g_clock.millis() - s.at < CHAT_FRESH_MS then
    return s.count, ('chat %d min ago'):format(math.floor((g_clock.millis() - s.at) / 60000))
  end
  local n = 0
  for _, c in pairs(g_game.getContainers()) do
    if RouteBags.isMine(c) then for _, it in ipairs(c:getItems()) do if it:getId() == id then n = n + it:getCount() end end end
  end
  return n, 'open bags'
end

-- is any supply row below its target, by the count the game printed or the open bags? Rows whose item is not
-- known count as short: better a walk to the shop than a skipped purchase on no information.
function RouteSupply.anythingShort()
  local short = {}
  for _, row in ipairs(RouteSupply.list()) do
    local id = RouteItems.id(row.item)
    if row.fullCap then short[#short + 1] = row.item
    elseif not id then short[#short + 1] = row.item
    else
      local n = RouteSupply.carried(id)
      if n < (row.amount or 0) then short[#short + 1] = ('%s %d/%d'):format(row.item, n, row.amount or 0) end
    end
  end
  return short
end

-- true when the Buy supplies job must open every bag to count (the exact, slow way)
function RouteSupply.walkMode()
  if not data then load() end
  return data.supplyWalk == true
end
function RouteSupply.setWalkMode(on)
  if not data then load() end
  data.supplyWalk = on and true or false
  persist()
end

-- every supply row's count from chat, and the rows no fresh chat count exists for
function RouteSupply.chatCounts()
  local counts, missing = {}, {}
  for _, row in ipairs(RouteSupply.list()) do
    local id = RouteItems.id(row.item)
    if id and not row.fullCap then
      local s = RouteSupply.seen[id]
      if s and g_clock.millis() - s.at < CHAT_FRESH_MS then counts[id] = s.count else missing[#missing + 1] = row.item end
    end
  end
  return counts, missing
end

-- Called from a "buy supplies" waypoint. Counts what you carry first (closed bags included), then greets the
-- npc and buys what the supply list is short of - once - and checks what arrived. It never re-plans from a
-- stale count: that is how it used to buy the same amount several times over.
local supplyJob
function RouteSupply.tick()
  local me = g_game.getLocalPlayer()
  if not me then return false end
  if #RouteSupply.list() == 0 then log('the supply list is empty - nothing to buy') supplyJob = nil return true end
  supplyJob = supplyJob or { count = {}, since = g_clock.millis() }
  local j = supplyJob
  if j.finishing then
    local r = RouteBags.finishStep(j.finishing)
    if r == true then
      if j.stopAfter then RouteBags.stopCavebot(j.stopAfter) end
      supplyJob = nil
      return true
    end
    return r
  end

  -- 1. count first: a long bag walk would idle the npc out if its window were already open
  if not j.counted then
    if not j.countLogged then
      j.countLogged = true
      -- the game's own counts first, unless told to open every bag
      if not RouteSupply.walkMode() then
        local counts, missing = RouteSupply.chatCounts()
        if #missing == 0 then
          j.counted, j.counts, j.fromChat = true, counts, true
          local parts = {}
          for _, row in ipairs(RouteSupply.list()) do
            local id = RouteItems.id(row.item)
            if id and not row.fullCap then parts[#parts + 1] = ('%dx %s (target %d)'):format(counts[id] or 0, row.item, row.amount or 0) end
          end
          log('supplies from the counts the game printed when you used them: ' .. (#parts > 0 and table.concat(parts, ', ') or 'nothing on the list'))
          return 'retry'
        end
        if #missing < #RouteSupply.list() or #missing > 0 then
          log(('no recent chat count for %s - opening the bags to count'):format(table.concat(missing, ', ')))
        end
      end
      log('counting your supplies (closed bags too) before buying')
      -- stop opening bags once every target on the list is met; capacity rows do not depend on the count
      j.count.enough = function(counts)
        for _, row in ipairs(RouteSupply.list()) do
          local id = RouteItems.id(row.item)
          if id and not row.fullCap and (counts[id] or 0) < (row.amount or 0) then return false end
        end
        return true
      end
    end
    local phase = RouteBags.countStep(j.count)
    if phase == 'busy' then
      if g_clock.millis() - j.since < 40000 then return 'retry' end
      log('counting took too long - buying with what was counted so far')
    end
    j.counted = true
    j.counts = j.count.counts or {}
    local parts = {}
    for _, row in ipairs(RouteSupply.list()) do
      local id = RouteItems.id(row.item)
      if id and not row.fullCap then
        parts[#parts + 1] = ('%dx %s (target %d)'):format(j.counts[id] or 0, row.item, row.amount or 0)
      end
    end
    log(('you carry %s - %d gold (%d bags counted%s)'):format(#parts > 0 and table.concat(parts, ', ') or 'nothing from the supply list',
      RouteBags.moneyOf(j.counts), j.count.bags or 0, j.count.stoppedEarly and ', enough found - stopped opening bags' or ''))
    return 'retry'
  end

  -- 2. the npc
  local open = openTrade(j)
  if open ~= true then
    if open == false then supplyJob = nil end
    return open
  end

  -- 3. plan once, from the walk
  if not j.plan then
    local shop = shopTable()
    for _, row in ipairs(RouteSupply.list()) do
      local id = RouteItems.id(row.item)
      if not id then log(('"%s" is not a known item name - skipped'):format(tostring(row.item)))
      elseif not shop[id] then log(('this npc does not sell %s - skipped'):format(row.item)) end
    end
    -- the shop window reports your money as the server sees it (bank included where the server trades from it);
    -- the coins counted in your bags are the fallback
    local t = modules.game_npctrade
    local money = (type(t.playerMoney) == 'number' and t.playerMoney > 0) and t.playerMoney or RouteBags.moneyOf(j.counts)
    log(('%d gold to spend, %.0f oz free'):format(money, me:getFreeCapacity()))
    j.plan, j.short = RouteSupply.plan(j.counts, shop, me:getFreeCapacity(), money)
    for _, s in ipairs(j.short) do
      warn(('%s: short of %d, %s for %d (%s)'):format(s.name, s.want, s.count > 0 and 'room' or 'no room', s.count, s.why))
    end
    if #j.plan == 0 then
      if #j.short == 0 then log('supplies are already up to the list') end
      local capShort = {}
      for _, s in ipairs(j.short) do if s.why == 'capacity' then capShort[#capShort + 1] = ('%dx %s'):format(s.want - s.count, s.name) end end
      if #capShort > 0 then j.stopAfter = 'no capacity for supplies: still short of ' .. table.concat(capShort, ', ') end
      modules.game_npctrade.closeNpcTrade()
      j.finishing = {}
      return 'retry'
    end
    j.queue, j.ids = {}, {}
    for _, buy in ipairs(j.plan) do
      j.ids[buy.id] = true
      log(('buying %dx %s for %d gold (you have %d)'):format(buy.count, buy.name, buy.count * buy.price, j.counts[buy.id] or 0))
      local left = buy.count
      while left > 0 do
        local n = math.min(left, 100)
        j.queue[#j.queue + 1] = { id = buy.id, count = n }
        left = left - n
      end
    end
    j.before = openTotals(j.ids)
    return 'retry'
  end

  -- 4. one purchase per tick, spaced out
  if #j.queue > 0 then
    if j.lastBuy and g_clock.millis() - j.lastBuy < 200 then return 'retry' end
    local b = table.remove(j.queue, 1)
    local t = modules.game_npctrade
    for _, item in ipairs(t.tradeItems[t.BUY] or {}) do
      if item.ptr:getId() == b.id then g_game.buyItem(item.ptr, b.count, false, false) break end
    end
    j.lastBuy = g_clock.millis()
    return 'retry'
  end

  -- 5. what arrived
  if g_clock.millis() - (j.lastBuy or 0) < 800 then return 'retry' end
  local after = openTotals(j.ids)
  for _, buy in ipairs(j.plan) do
    local got = (after[buy.id] or 0) - (j.before[buy.id] or 0)
    if got >= buy.count then log(('bought %dx %s'):format(got, buy.name))
    elseif got > 0 then log(('bought %s: only %d of %d arrived in your open bags - out of gold or capacity, or they went into a closed bag'):format(buy.name, got, buy.count))
    else log(('nothing of %s arrived - out of gold or capacity?'):format(buy.name)) end
  end
  modules.game_npctrade.closeNpcTrade()
  -- the one reason to stop hunting: no room left for the supplies you are short of
  local capShort = {}
  for _, s in ipairs(j.short or {}) do
    if s.why == 'capacity' then capShort[#capShort + 1] = ('%dx %s'):format(s.want - s.count, s.name) end
  end
  if #capShort > 0 then j.stopAfter = 'no capacity for supplies: still short of ' .. table.concat(capShort, ', ') end
  log('done - closing the bags, leaving your backpack open')
  j.finishing = {}
  return 'retry'
end

function RouteSupply.cancel() supplyJob = nil end

-- Sell everything the npc in front of you is willing to take.
function RouteSupply.sellAll()
  supplyJob = supplyJob or {}
  local open = openTrade(supplyJob)
  if open ~= true then
    if open == false then supplyJob = nil end
    return open
  end
  supplyJob = nil
  local t = modules.game_npctrade
  local names = {}
  for _, item in ipairs(t.tradeItems[t.SELL] or {}) do names[#names + 1] = item.name end
  log('selling everything this npc takes: ' .. (#names > 0 and table.concat(names, ', ') or 'nothing'))
  t.sellAll()
  t.closeNpcTrade()
  return true
end


-- ---------------------------------------------------------------- the loot list
-- Each row is { item = 'gold coin', deposit = true, sell = false }. The Deposit loot job puts the deposit
-- items away; the Sell loot job sells the sell items to whatever npc is in front of you.
function RouteLoot.list()
  if not data then load() end
  return data.loot
end

function RouteLoot.set(list)
  if not data then load() end
  local clean = {}
  for _, row in ipairs(list or {}) do
    if row.item and row.item ~= '' and (row.deposit or row.sell or row.keep) then
      clean[#clean + 1] = { item = row.item, deposit = row.deposit and true or false,
                            sell = row.sell and true or false, keep = row.keep and true or false }
    end
  end
  data.loot = clean
  persist()
  return clean
end

local function lootIds(field)
  local ids = {}
  for _, row in ipairs(RouteLoot.list()) do
    if row[field] then
      local id = RouteItems.id(row.item)
      if id then ids[#ids + 1] = id end
    end
  end
  return ids
end
-- The three backpack kinds of the by-the-backpack deposit, by item id: loot (the bag you carry loot in),
-- full (the depot bag that collects full loot bags), empty (the depot bag that hands out empty ones), and how
-- many plain bags a fresh loot bag is filled with.
function RouteLoot.bags()
  if not data then load() end
  local b = data.lootBags or {}
  return { loot = tonumber(b.loot), full = tonumber(b.full), empty = tonumber(b.empty), setSize = tonumber(b.setSize) or 4,
           sweep = (b.sweep == true or b.sweep == 'true'),
           whenOut = (b.whenOut == 'hunt') and 'hunt' or 'stop' }    -- no loot backpack to be had at the depot: stop the cavebot, or hunt on
end

function RouteLoot.setBags(t)
  if not data then load() end
  data.lootBags = { loot = tonumber(t.loot), full = tonumber(t.full), empty = tonumber(t.empty), setSize = tonumber(t.setSize) or 4,
                    sweep = t.sweep and true or false, whenOut = (t.whenOut == 'hunt') and 'hunt' or 'stop' }
  persist()
  return RouteLoot.bags()
end

function RouteLoot.depositIds() return lootIds('deposit') end
function RouteLoot.sellIds() return lootIds('sell') end
-- what must never be sold: anything ticked keep, plus anything meant for the depot (selling it first would
-- empty the backpack before the depot job ran)
function RouteLoot.keepIds()
  local ids, seen = {}, {}
  for _, row in ipairs(RouteLoot.list()) do
    if row.keep or row.deposit then
      local id = RouteItems.id(row.item)
      if id and not seen[id] then seen[id] = true ids[#ids + 1] = id end
    end
  end
  return ids
end

-- Sell to the npc in front of you. If the loot list has any items ticked "sell", sells exactly those.
-- Otherwise sells everything the npc buys except the "keep" items (and depot items, never sold). Says hello.
function RouteLoot.sell()
  supplyJob = supplyJob or {}
  local open = openTrade(supplyJob)
  if open ~= true then
    if open == false then supplyJob = nil end
    return open
  end
  supplyJob = nil
  local t = modules.game_npctrade
  local whitelist = {}
  for _, id in ipairs(RouteLoot.sellIds()) do whitelist[id] = true end
  local onlyThese = next(whitelist) ~= nil
  local keep = {}
  for _, id in ipairs(RouteLoot.keepIds()) do keep[id] = true end
  local sold, kept = {}, {}
  for _, item in ipairs(t.tradeItems[t.SELL] or {}) do
    local id = item.ptr:getId()
    local wanted = onlyThese and whitelist[id] or (not onlyThese and not keep[id])
    if wanted then
      local count = t.getSellQuantity(item.ptr)
      if count and count > 0 then
        g_game.sellItem(item.ptr, count, true)
        sold[#sold + 1] = ('%dx %s'):format(count, item.name)
      end
    elseif not onlyThese and keep[id] then
      kept[#kept + 1] = item.name
    end
  end
  if #sold > 0 then log('sold ' .. table.concat(sold, ', '))
  else log(onlyThese and 'this npc buys none of your sell list' or 'this npc buys nothing you are carrying') end
  if #kept > 0 then log('kept (not sold): ' .. table.concat(kept, ', ')) end
  t.closeNpcTrade()
  return true
end

-- Whether the autoloot module is present at all. Its settings are where both its own UI and the server's
-- !autoloot sync land, so that node is our source; with no module there is nothing to read.
function RouteLoot.hasAutoloot()
  return modules.game_autoloot ~= nil or (g_settings.getNode('autoloot') ~= nil)
end

-- Item ids to preload into the Loot window, tried in the order the user asked for:
--   1. the autoloot module's active list (its own UI)
--   2. the !autoloot server list the module keeps in sync
--   3. nothing - the user's own typed rows stand
-- Returns ids, a source label, and whether a server refresh was kicked off (async, so try again shortly).
function RouteLoot.autolootItems()
  local al = modules.game_autoloot
  local ids, seen = {}, {}
  local function add(id)
    id = tonumber(id)
    if id and not seen[id] then seen[id] = true ids[#ids + 1] = id end
  end

  -- 1. the module's active list
  if al and al.getActiveItems then
    local ok, items = pcall(function() return al.getActiveItems() end)
    if ok and type(items) == 'table' then for _, id in pairs(items) do add(id) end end
  end
  if #ids > 0 then return ids, 'the active autoloot list' end

  -- 1b. every autoloot list the module has (all backpacks), when the active one is empty
  local n = g_settings.getNode('autoloot')
  if type(n) == 'table' and type(n.lists) == 'table' then
    for _, list in pairs(n.lists) do
      if type(list) == 'table' and type(list.items) == 'table' then
        for _, id in pairs(list.items) do add(id) end
      end
    end
  end
  if #ids > 0 then return ids, 'all autoloot lists' end

  -- 2. the !autoloot server list the module already holds (read only - no request here)
  if al and al.getServerItems then
    local ok, srv = pcall(function() return al.getServerItems() end)
    if ok and type(srv) == 'table' then for _, e in ipairs(srv) do add(e.id) end end
    if #ids > 0 then return ids, 'the !autoloot server list' end
  end

  -- 3. nothing yet
  return ids, 'nothing'
end

-- Ask the server to send its !autoloot list. Returns true if the request went out. The reply is parsed by
-- the autoloot module and lands in getServerItems(), so the caller polls that rather than the chat.
function RouteLoot.requestServerList()
  local al = modules.game_autoloot
  if al and al.refreshServerList then
    local ok, sent = pcall(function() return al.refreshServerList(true) end)
    if ok and sent ~= false then return true end
  end
  -- no module: send it ourselves; whatever parses !autoloot replies elsewhere will still catch it
  if g_game.isOnline() then pcall(function() g_game.talk('!autoloot') end) return true end
  return false
end
