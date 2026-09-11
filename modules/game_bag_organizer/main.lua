-- Bag organizer: one click compacts and sorts your carried items into buckets across your backpacks, with a
-- read-only Preview first. Buckets come from the autoloot module's named lists (so you reuse the item lists you
-- already build there); anything not on a list is treated as loot. See scan.lua for the tree reader.

dofile('scan')
dofile('plan')
dofile('apply')
dofile('viz')
dofile('cache')

local MAX_PASSES = 5         -- apply gives up after this many passes; the simulator models the same cap
                             -- (fuzzing 300 random inventories: 296 need <= 4, none of the rest converge at all)
local MOVE_MS = 220          -- delay between move actions (server anti-spam)
local window, button, output
local prepareRoot          -- defined further down with the UI helpers; the apply phases and lootFirst need it
local tree                   -- last scan result: path -> node
local plan                   -- list of moves { itemId, count, fromPath, fromSlot, toPath, bucket }
local planDests              -- bucket -> ordered destination paths, used as fallbacks when a bag is full/closed
local planRoomMoves          -- phase A: park items out of a full category bag so a nested bag fits
local planBagMoves           -- phase B: empty bags to nest inside category bags / collect
local lastInfo               -- planner report: assigned bags per bucket, blocked count, bags empty afterwards
local applying = false
local scanGen = 0
local scanSeconds = 0
local lastScanTotal = 0   -- bags read last time; the ETA anchor (branch extrapolation lies until the fat branches open)
local scanning = false
local progWindow, progLastScanned, progLastMs = {}, 0, 0   -- bumped each preview / on terminate, so a stale scan callback is ignored
local stopRequested = false

-- ---- buckets ---------------------------------------------------------------------------------------
-- User-defined buckets. Each bucket = a name + a set of item CATEGORIES it claims (the client's market
-- categories are the vocabulary). Items in no bucket fall to "Loot". Stored in g_settings 'bagOrganizer'.
local CATS = {  -- {marketCategory, label}  the ones worth offering
  { MarketCategory.Potions, "Potions" }, { MarketCategory.Runes, "Runes" }, { MarketCategory.Food, "Food" },
  { MarketCategory.Amulets, "Amulets" }, { MarketCategory.Rings, "Rings" }, { MarketCategory.Armors, "Armors" },
  { MarketCategory.Legs, "Legs" }, { MarketCategory.Boots, "Boots" }, { MarketCategory.HelmetsHats, "Helmets" },
  { MarketCategory.Shields, "Shields" }, { MarketCategory.Swords, "Swords" }, { MarketCategory.Axes, "Axes" },
  { MarketCategory.Clubs, "Clubs" }, { MarketCategory.DistanceWeapons, "Distance" }, { MarketCategory.WandsRods, "Wands/Rods" },
  { MarketCategory.Ammunition, "Ammunition" }, { MarketCategory.Tools, "Tools" }, { MarketCategory.Containers, "Containers" },
  { MarketCategory.Valuables, "Valuables" }, { MarketCategory.Gold, "Gold/Coins" }, { MarketCategory.CreatureProducs, "Creature products" },
  { MarketCategory.Decoration, "Decoration" }, { MarketCategory.Others, "Others" },
}

local config   -- { buckets = { {name, cats = {marketCategory=true}}, ... } }

local function defaultConfig()
  return { buckets = {
    { name = "Potions",   cats = { [MarketCategory.Potions] = true } },
    { name = "Runes",     cats = { [MarketCategory.Runes] = true } },
    { name = "Supplies",  cats = { [MarketCategory.Food] = true, [MarketCategory.Ammunition] = true } },
    { name = "Jewelry",   cats = { [MarketCategory.Amulets] = true, [MarketCategory.Rings] = true } },
    { name = "Gear",      cats = { [MarketCategory.Armors] = true, [MarketCategory.Legs] = true, [MarketCategory.Boots] = true,
                                   [MarketCategory.HelmetsHats] = true, [MarketCategory.Shields] = true, [MarketCategory.Swords] = true,
                                   [MarketCategory.Axes] = true, [MarketCategory.Clubs] = true, [MarketCategory.DistanceWeapons] = true,
                                   [MarketCategory.WandsRods] = true } },
    { name = "Valuables", cats = { [MarketCategory.Valuables] = true, [MarketCategory.Gold] = true } },
  } }
end

local function loadConfig()
  local node = g_settings.getNode('bagOrganizer')
  config = defaultConfig()
  lastScanTotal = tonumber(g_settings.getNumber('bagOrganizerLastTotal')) or 0
  if type(node) == 'table' and type(node.buckets) == 'table' then
    config.buckets = {}
    -- settings arrays come back with string keys; iterate numerically
    local keys = {} for k in pairs(node.buckets) do table.insert(keys, k) end
    table.sort(keys, function(x, y) return (tonumber(x) or 0) < (tonumber(y) or 0) end)
    for _, k in ipairs(keys) do
      local bkt = node.buckets[k]
      if type(bkt) == 'table' and bkt.name then
        local cats = {}
        if type(bkt.cats) == 'table' then for ck, cv in pairs(bkt.cats) do if cv == true or cv == 'true' or cv == 1 then cats[tonumber(ck)] = true end end end
        table.insert(config.buckets, { name = tostring(bkt.name), cats = cats })
      end
    end
    if #config.buckets == 0 then config = defaultConfig() end
  end
end

local function saveConfig() g_settings.setNode('bagOrganizer', config) end

-- market category of an item id, cached
local categoryCache = {}
local function categoryOf(id)
  local c = categoryCache[id]
  if c ~= nil then return c end
  c = false
  local ok, tt = pcall(function() return g_things.getThingType(id, ThingCategoryItem) end)
  if ok and tt then local md pcall(function() md = tt:getMarketData() end) if md and md.category then c = md.category end end
  categoryCache[id] = c
  return c
end

local demoBuckets   -- set only by vizDemo(): the OTB (and with it market categories) loads on login
-- first bucket whose categories include this item; else "Loot"
local function bucketFor(id)
  if demoBuckets then return demoBuckets[id] or "Loot" end
  local cat = categoryOf(id)
  if cat then
    for _, b in ipairs(config.buckets) do if b.cats[cat] then return b.name end end
  end
  return "Loot"
end

local function bucketOrder()
  local o = {}
  for _, b in ipairs(config.buckets) do table.insert(o, b.name) end
  table.insert(o, "Loot")
  return o
end

local function autoloot() return modules.game_autoloot end
local function itemName(id)
  local al = autoloot()
  return (al and al.itemName and al.itemName(id)) or ("item " .. id)
end

-- ---- output ----------------------------------------------------------------------------------------

-- shown one at a time while a long scan runs, so it does not look frozen
local QUIPS = {
  "kto panu tak spierdolil?",
  "to je amelinum, tego nie pomalujesz",
  "jeszcze tylko tu nasrac",
  "boze, czy ty to widzisz?!",
  "spokojnie, wiem co robie",
  "kazdy plecak ma swoja historie",
  "liczymy szmelc...",
  "to sie samo nie posortuje",
  "gdzie ja to wszystko trzymam",
  "jeszcze chwilka, mistrzu",
  "otwieramy, zagladamy, zamykamy",
  "porzadek musi byc",
  "kto to pakowal, rece opadaja",
  "plecak w plecaku w plecaku...",
  "matrioszka level 6",
  "znowu ten sam badyl",
  "ile mozna miec plecakow czlowieku",
  "inwentarz jak po wojnie",
  "sortujemy jak pan bog przykazal",
  "to nie hoarding, to kolekcja",
  "diogenes by sie wstydzil",
  "chwila, tu cos blyszczy",
  "jeszcze te trzysta plecakow",
  "kto rano wstaje ten sortuje",
  "wszystko ma swoje miejsce, teoretycznie",
  "profesjonalny bajzel",
  "robimy z tego muzeum",
  "cierpliwosci, arcymistrzu",
  "grzebiemy w skarbach",
  "zaraz bedzie pieknie",
  "moment, licze do stu... plecakow",
  "tego by sie mario nie powstydzil",
  "banki maja mniej sejfow niz ty plecakow",
  "jeszcze nie teraz, jeszcze nie teraz",
  "porzadek to polowa sukcesu",
  "kazdy przedmiot na swoje miejsce",
  "ile ty tego masz, bracie",
  "plecak numer milion",
  "kolejny plecak, kolejna zagadka",
  "tu myszy juz nie ma, sprawdzone",
  "archeolog by placzem plakal",
  "znalazlem twoje zgubione sny",
  "to nie bajzel, to system",
  "gdzies tu byl sandwich...",
  "witaj w moim swiecie",
  "plecakoceptyon",
  "tu bylem, Tony Halik",
  "liczymy do nieskonczonosci",
  "kazdy plecak to nowa przygoda",
  "spokojnie, panuje nad sytuacja",
  "jeszcze ino te pare setek",
  "geologia warstw plecakowych",
  "kopiemy glebiej niz krasnoludy",
  "twoj bank byłby dumny",
  "nadal szukamy dna",
  "to juz prawie... zart, wcale nie",
}
local QUIP_MS = 5000     -- a new quip at most this often: counting BAGS made them flicker, because a fast
                         -- scan opens six of them in well under a second
local quipAt = 0
local lastQuip = ""

local logLines = {}
local function log(line)
  table.insert(logLines, line)
  if #logLines > 200 then table.remove(logLines, 1) end
  if output then output:setText(table.concat(logLines, "\n")) end
end

local function clearLog() logLines = {} if output then output:setText("") end end

-- ---- planning --------------------------------------------------------------------------------------

-- For each bucket, choose ONE destination bag: the bag already holding the most items of that bucket. Then every
-- item of that bucket living elsewhere is a move into the destination (compaction + sort in one).
-- ---- plan ------------------------------------------------------------------------------------------
-- Pack each bucket into the fewest of the bags that ALREADY hold it. No fresh empty bags, and nothing already
-- sitting in a fill target is touched: only the stragglers in the emptier bags of a bucket move into the fuller
-- ones, respecting each bag's real capacity (node.cap comes from getCapacity - 20 here, never hardcoded).
-- Returns perBucket (bucket -> path -> item count, for the preview), used (bags still holding it afterwards)
-- and the move count; fills the module-level `plan`.
local LOOT_BUCKET = "Loot"       -- items in no bucket; its bag collects the spare empties by default

-- A bucket whose categories include Containers cannot receive items, so it becomes the home for the spare
-- empty backpacks instead - that is the only sensible reading of "a bucket for backpacks".
local function planOpts()
  local o = { lootBucket = LOOT_BUCKET }
  for _, b in ipairs(config.buckets) do
    if b.cats and b.cats[MarketCategory.Containers] then o.gatherBucket = b.name break end
  end
  return o
end

local function buildPlan()
  local moves, info, bagMoves, roomMoves = BagPlan.build(tree, bucketFor, planOpts())
  plan, lastInfo, planBagMoves, planRoomMoves = moves, info, bagMoves, roomMoves

  planDests = {}
  for b, paths in pairs(info.dests or {}) do
    planDests[b] = {}
    for _, path in ipairs(paths) do table.insert(planDests[b], path) end
  end

  local perBucket = {}
  for path, node in pairs(tree) do
    if node.items then
      for _, e in ipairs(node.items) do
        if not e.isContainer then
          local b = bucketFor(e.id)
          perBucket[b] = perBucket[b] or {}
          perBucket[b][path] = (perBucket[b][path] or 0) + 1   -- slots, not stack sizes
        end
      end
    end
  end
  return perBucket, info, #moves + #bagMoves + #roomMoves
end

-- A handful of real (id, bucket) pairs plus the real backpack ids, so vizDemo() can draw actual sprites
-- while offline: raw dat ids render as walls and fire until the OTB loads on login.
local function rememberRealIds()
  local seen, items, bags = {}, {}, {}
  for _, node in pairs(tree or {}) do
    if node.id and not seen['b' .. node.id] then seen['b' .. node.id] = true table.insert(bags, node.id) end
    for _, e in ipairs(node.items or {}) do
      if not e.isContainer and not seen[e.id] and #items < 20 then
        seen[e.id] = true
        table.insert(items, { id = e.id, bucket = bucketFor(e.id) })
      end
    end
  end
  if #items > 0 then
    g_settings.setNode('bagOrganizerRealIds', { items = items, bags = bags })
    g_settings.save()
  end
end

local function realIdsByBucket()
  local node = g_settings.getNode('bagOrganizerRealIds')
  if type(node) ~= 'table' then return nil end
  local byBucket, bags = {}, {}
  for _, e in pairs(node.items or {}) do
    if type(e) == 'table' and e.id then
      local b = tostring(e.bucket or "Loot")
      byBucket[b] = byBucket[b] or {}
      table.insert(byBucket[b], tonumber(e.id))
    end
  end
  for _, id in pairs(node.bags or {}) do table.insert(bags, tonumber(id)) end
  return byBucket, bags
end

local MIN_W, MIN_H, MAX_W, MAX_H = 700, 460, 1900, 1400
local renderViews
local relayoutEvent

local paneFraction = 0.5      -- where the vertical splitter sits, as a share of the window width

local function clamp(v, lo, hi) return math.min(math.max(v, lo), math.max(lo, hi)) end

-- Three splitters own the section sizes: buckets / previews / log vertically, and the two halves horizontally.
-- A UISplitter drags its OWN margin, so the sections anchor to the splitters and this only has to keep the
-- margins sane when the window itself is resized.
local function layoutPanes()
  if not window or not window.paneSplit then return end
  local H, W = window:getHeight(), window:getWidth()
  window.paneSplit:setMarginRight(clamp(math.floor(W * paneFraction), 260, W - 300))
  window.logSplit:setMarginBottom(clamp(window.logSplit:getMarginBottom(), 60, math.max(60, H - 300)))
  window.bucketsSplit:setMarginBottom(clamp(window.bucketsSplit:getMarginBottom(),
    window.logSplit:getMarginBottom() + 150, math.max(200, H - 90)))
end

local function saveSplitters()
  if not window or not window.paneSplit then return end
  paneFraction = window.paneSplit:getMarginRight() / math.max(1, window:getWidth())
  g_settings.set('bagOrganizerPaneFraction', paneFraction)
  g_settings.set('bagOrganizerBucketsSplit', window.bucketsSplit:getMarginBottom())
  g_settings.set('bagOrganizerLogSplit', window.logSplit:getMarginBottom())
end

local onResized

local function setupSplitters()
  local bs, ls, ps = window.bucketsSplit, window.logSplit, window.paneSplit
  if not bs or not ls or not ps then return end
  bs.canUpdateMargin = function(_, m)
    return clamp(m, ls:getMarginBottom() + 150, math.max(200, window:getHeight() - 90))
  end
  ls.canUpdateMargin = function(_, m)
    return clamp(m, 60, math.max(60, bs:getMarginBottom() - 150))
  end
  ps.canUpdateMargin = function(_, m)
    return clamp(m, 260, math.max(260, window:getWidth() - 300))
  end
  for _, sp in ipairs({ bs, ls, ps }) do
    local orig = sp.onMouseRelease
    sp.onMouseRelease = function(w, pos, btn)
      local r = orig and orig(w, pos, btn)
      saveSplitters()
      if onResized then onResized() end
      return r
    end
  end
  if g_settings.exists('bagOrganizerPaneFraction') then
    paneFraction = clamp(tonumber(g_settings.getNumber('bagOrganizerPaneFraction')) or 0.5, 0.2, 0.8)
  end
  if g_settings.exists('bagOrganizerLogSplit') then
    ls:setMarginBottom(g_settings.getNumber('bagOrganizerLogSplit'))
  end
  if g_settings.exists('bagOrganizerBucketsSplit') then
    bs:setMarginBottom(g_settings.getNumber('bagOrganizerBucketsSplit'))
  else
    bs:setMarginBottom(math.max(200, window:getHeight() - 290))   -- ~140 px of bucket list to start with
  end
  layoutPanes()
end

-- the grip drags both dimensions; the first press breaks the centre anchors so the top-left corner stays put
local function setupCornerGrip()
  local grip = window:getChildById('cornerGrip')
  if not grip then return end
  grip.onMousePress = function(w, pos, mouseButton)
    if mouseButton ~= MouseLeftButton then return false end
    local r = window:getRect()
    window:breakAnchors()
    window:setRect(r)
    w.drag = { x = pos.x, y = pos.y, w = r.width, h = r.height }
    return true
  end
  grip.onMouseMove = function(w, pos)
    local d = w.drag
    if not d then return false end
    window:setWidth(math.min(math.max(d.w + pos.x - d.x, MIN_W), MAX_W))
    window:setHeight(math.min(math.max(d.h + pos.y - d.y, MIN_H), MAX_H))
    return true
  end
  grip.onMouseRelease = function(w) w.drag = nil return false end
end

onResized = function()
  layoutPanes()
  if relayoutEvent then removeEvent(relayoutEvent) end
  relayoutEvent = scheduleEvent(function()      -- debounced: a drag fires this on every pixel
    relayoutEvent = nil
    g_settings.set('bagOrganizerW', window:getWidth())
    g_settings.set('bagOrganizerH', window:getHeight())
    if tree then renderViews() end
  end, 200)
end

renderViews = function()
  if not window or not tree then return end
  if not demoBuckets then rememberRealIds() end
  BagViz.render(window.leftView, tree,
    { ownerOf = (lastInfo and lastInfo.owner) or {}, itemName = itemName, width = window.leftView:getWidth() })
  window.leftSummary:setText(BagViz.summary(tree))

  local target, rep = BagPlan.simulate(tree, bucketFor, MAX_PASSES, planOpts())
  BagViz.render(window.rightView, target,
    { ownerOf = (rep.info and rep.info.owner) or {}, itemName = itemName, width = window.rightView:getWidth() })
  local mv = rep.moves or { room = 0, bag = 0, item = 0, total = 0 }
  local stuck = (rep.info and ((rep.info.unplaced or 0) + (rep.info.blocked or 0))) or 0
  window.rightSummary:setText(string.format("%d move(s) to get here: %d room / %d bag / %d item  -  %d pass(es)%s",
    mv.total, mv.room, mv.bag, mv.item, rep.passes,
    stuck > 0 and string.format("  -  %d homeless, add %d bag(s)", stuck, rep.info.shortBags or 0) or ""))
end

-- ---- dropping surplus empty backpacks ---------------------------------------------------------------
-- Empty bags are spare capacity, so a number of them is worth keeping; past that they are just weight and
-- clutter. Bags nested inside a bucket's own tree are that bucket's overflow room, so they are kept in
-- preference to the gathered pile, which is dropped first.
local KEEP_DEFAULT = 10
local dropping = false

local function savedKeep()
  -- g_settings.getNumber returns 0 for a key that was never set, and 0 is truthy in Lua - so an unset keep
  -- count would read as "drop every empty bag". Ask whether the key exists first.
  if g_settings.exists('bagOrganizerKeepEmpty') then
    return math.max(0, math.floor(tonumber(g_settings.getNumber('bagOrganizerKeepEmpty')) or KEEP_DEFAULT))
  end
  return KEEP_DEFAULT
end

local function keepCount()
  local typed = window and window.keepEmpty and tonumber(window.keepEmpty:getText())
  if typed and typed >= 0 then return math.floor(typed) end
  return savedKeep()
end

local function emptyBags()
  if not tree then return {} end
  local inBucketTree = {}
  for _, paths in pairs((lastInfo and lastInfo.dests) or {}) do
    for _, p in ipairs(paths) do inBucketTree[p] = true end
  end
  local gather = lastInfo and lastInfo.collector
  local out = {}
  for path, node in pairs(tree) do
    if path ~= "" and #(node.items or {}) == 0 then
      local inPile = gather and (path == gather or path:find("^" .. gather .. "/") ~= nil) or false
      table.insert(out, { path = path, rank = inPile and 0 or (inBucketTree[path] and 2 or 1) })
    end
  end
  -- drop the gathered pile first, then loose spares, and only then a bucket's own reserve; deepest first so
  -- taking one out never renumbers the slot of another still to come
  table.sort(out, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    local _, da = a.path:gsub("/", "")
    local _, db = b.path:gsub("/", "")
    if da ~= db then return da > db end
    return a.path > b.path
  end)
  return out
end

local DROP_TARGETS = { { 'depot', 'depot only' }, { 'ground', 'ground only' }, { 'both', 'depot, then ground' } }

local function dropTargetMode()
  local saved = g_settings.exists('bagOrganizerDropTarget') and g_settings.getString('bagOrganizerDropTarget') or 'both'
  for _, t in ipairs(DROP_TARGETS) do if t[1] == saved then return saved end end
  return 'both'
end

-- A scan closes every container to get a clean slate, the player's depot included. A closed container reports
-- capacity 0, which read as "your depot is full" - so only ever accept a live one.
-- The LOCKER is only the 3-slot wrapper holding the depot chest, mailbox and inbox - it is always full, and
-- matching it read as "your depot is full". Take the roomiest depot chest / inbox instead, never the locker.
-- Only the depot CHEST accepts things. The locker is the 3-slot wrapper around it (always full, so matching it
-- read as "your depot is full"), and the inbox looks roomy but is receive-only - every move into it is silently
-- refused. A full chest is not a dead end either: a backpack put inside it adds 20 more slots, which is what
-- the queue in dropEmpties uses.
local function depotTarget()
  for _, c in pairs(g_game.getContainers()) do
    local name = (c:getName() or ""):lower()
    if name:find("depot") and not name:find("locker") and not c:isClosed() and c:getCapacity() > 0 then
      return c
    end
  end
  return nil
end

-- With the locker open, the depot chest inside it still has to be opened. Item names are unreliable here -
-- plenty of them come back blank - so just try each container in the locker and see which one opens as a
-- depot: the CONTAINER name the server sends ("depot chest") is trustworthy, the item name is not.
local function openChestInLocker(done)
  local locker
  for _, c in pairs(g_game.getContainers()) do
    if (c:getName() or ""):lower():find("locker") and not c:isClosed() then locker = c break end
  end
  if not locker then return done(nil) end
  local candidates = {}
  for _, it in ipairs(locker:getItems()) do
    if it:isContainer() then table.insert(candidates, it) end
  end
  local k = 0
  local function tryNext()
    k = k + 1
    local it = candidates[k]
    if not it then return done(nil) end
    g_game.open(it, nil)
    local n, ev = 0, nil
    ev = cycleEvent(function()
      n = n + 1
      local fresh = depotTarget()
      if fresh then removeEvent(ev) return done(fresh) end
      if n > 8 then removeEvent(ev) return tryNext() end
    end, 150)
  end
  tryNext()
end

-- Open the depot for the player if they are standing on or next to one, so the button does not just refuse.
local function openNearbyDepot(done)
  local me = g_game.getLocalPlayer()
  if not me then return done(nil) end
  local p = me:getPosition()
  local found
  for dx = -1, 1 do
    for dy = -1, 1 do
      if not found then
        local tile = g_map.getTile({ x = p.x + dx, y = p.y + dy, z = p.z })
        for _, thing in ipairs(tile and tile:getThings() or {}) do
          if thing:isItem() then
            local nm = itemName(thing:getId()):lower()
            if nm:find("depot") or nm:find("locker") then found = thing break end
          end
        end
      end
    end
  end
  if not found then return openChestInLocker(done) end
  g_game.use(found)
  local n, ev = 0, nil
  ev = cycleEvent(function()
    n = n + 1
    local fresh = depotTarget()
    if fresh then removeEvent(ev) return done(fresh) end
    if n > 10 then
      removeEvent(ev)
      return openChestInLocker(done)      -- the locker opened; the chest inside it is the actual target
    end
  end, 150)
end

local function surplusCount()
  local n = #emptyBags() - keepCount()
  return math.max(0, n)
end

local groundConfirmed = false

-- Merge half-built branch bags first: each emptied branch is a whole backpack freed, which is 18 oz back and
-- one more bag for the drop. Runs through the same identity-addressed executor as Apply.
local function consolidateThen(cb)
  local list, rep = BagPlan.consolidate(tree, 60)
  if #list == 0 then return cb() end
  log(string.format("Merging %d half-filled backpack(s) first - frees %d bag(s)...", #list, rep.freed))
  dropping = true
  window.stop:setEnabled(true)
  BagApply.executePlan(list, tree, {
    moveMs = MOVE_MS,
    isStopped = function() return stopRequested end,
    onStatus = function(_, moved, tot)
      output:setText(string.format("Merging backpacks...\n\n%d / %d done", moved, tot))
    end,
    onDone = function(sum)
      dropping = false
      log(string.format("  merged %d/%d%s", sum.moved, sum.total, skipText(sum)))
      if (sum.skipped.gone or 0) > 0 then
        -- the bags are not where the tree said: it was planned against an out-of-date picture, so nothing
        -- below this can be trusted either
        BagCache.forget()
        window.stop:setEnabled(false)
        return log("The saved layout is out of date - press Rescan, then try again. Nothing was dropped.")
      end
      if sum.tree then
        tree = sum.tree
        scanFromCache = false
        BagCache.save(tree)
        buildPlan()
      end
      if stopRequested then
        window.stop:setEnabled(false)
        return log("Stopped.")
      end
      cb()
    end,
  })
end

function dropEmpties(skipMerge)
  if applying or dropping or scanning then return end
  if not tree then log("scan first") return end
  if not skipMerge then
    -- merge first, then drop what that frees; the flag has to survive the recursive call, so it is a parameter
    return consolidateThen(function() dropEmpties(true) end)
  end
  local list = emptyBags()
  local keep = keepCount()
  local surplus = #list - keep
  if surplus <= 0 then
    log(string.format("%d empty backpack(s), keeping %d - nothing to drop", #list, keep))
    return
  end
  local mode = dropTargetMode()
  local depot = depotTarget()
  if not depot and mode ~= 'ground' then
    -- try to open it for them before refusing
    dropping = true
    return openNearbyDepot(function(opened)
      dropping = false
      if opened then log("Opened your depot.") return dropEmpties() end
      -- Not finding the depot is never a reason to use the floor: that is how a 'depot, then ground' run
      -- ended up dumping everything outside. Ground happens only when the chest is genuinely full, or when
      -- 'ground only' was chosen deliberately.
      log("Could not open your depot - stand next to it (or set 'put in' to ground only). Nothing was dropped.")
    end)
  end
  local toGround = (mode == 'ground')
  if not toGround and not depot then
    log("Could not open your depot - stand next to it (or set 'put in' to ground only). Nothing was dropped.")
    return
  end

  local victims = {}
  for i = 1, surplus do table.insert(victims, list[i].path) end
  log(string.format("Dropping %d of %d empty backpack(s) %s, keeping %d...", surplus, #list,
    toGround and "on the ground" or "in your depot", keep))

  -- the same identity model the executor uses, so the tree stays exact without another scan
  local root = BagPlan.toTree(tree)
  local byOrig = BagPlan.index(root)
  dropping = true
  stopRequested = false
  window.stop:setEnabled(true)
  window.dropEmpties:setEnabled(false)

  -- Ground dumping spreads over nearby tiles: a few hundred backpacks on one square is how a server starts
  -- refusing the moves, and every refusal costs a move slot for nothing.
  local PER_TILE = 5              -- a tile stops accepting objects well before it looks full
  local tiles, tileIdx, onTile = {}, 1, 0
  do
    local me = g_game.getLocalPlayer()
    local p = me and me:getPosition()
    if p then
      local ring = { {0,0}, {1,0}, {0,1}, {-1,0}, {0,-1}, {1,1}, {-1,1}, {1,-1}, {-1,-1} }
      for _, d in ipairs(ring) do
        local pos = { x = p.x + d[1], y = p.y + d[2], z = p.z }
        local tile = g_map.getTile(pos)
        local walkable = true
        if tile then pcall(function() walkable = tile:isWalkable() end) end
        if tile and walkable then table.insert(tiles, pos) end
      end
      if #tiles == 0 then table.insert(tiles, p) end
    end
  end

  -- A backpack dropped in the depot is itself 20 more depot slots, so the chest never really runs out: fill
  -- it, then fill the bags already inside it, breadth first. Depth stays at 2 for 400 backpacks, so the open
  -- chain never gets long enough to hit the server's container limit.
  local dq = depot and { { container = depot } } or {}
  local function headContainer(cb)
    local e = dq[1]
    if not e then return cb(nil) end
    if e.container then
      if e.container:isClosed() then table.remove(dq, 1) return headContainer(cb) end
      if e.container:getItemsCount() < e.container:getCapacity() then return cb(e.container) end
      local kids = {}
      for slot = 0, e.container:getItemsCount() - 1 do
        local it = e.container:getItems()[slot + 1]
        if it and it:isContainer() then table.insert(kids, { parent = e.container, slot = slot }) end
      end
      table.remove(dq, 1)
      for _, k in ipairs(kids) do table.insert(dq, k) end
      tr("   depot level full, %d bag(s) inside it become the next targets", #kids)
      return headContainer(cb)
    end
    local parent = e.parent
    if not parent or parent:isClosed() then table.remove(dq, 1) return headContainer(cb) end
    local it = parent:getItems()[e.slot + 1]
    if not it or not it:isContainer() then table.remove(dq, 1) return headContainer(cb) end
    local seen, wantId = {}, it:getId()
    for cid in pairs(g_game.getContainers()) do seen[cid] = true end
    g_game.open(it, nil)
    local n, ev = 0, nil
    ev = cycleEvent(function()
      n = n + 1
      -- a brand new window is the normal case; the client silently REUSES one when the bag is already open,
      -- in which case no new id appears and the only sign is a container holding that same bag
      for cid, c in pairs(g_game.getContainers()) do
        if not seen[cid] then
          removeEvent(ev)
          dq[1] = { container = c }
          return headContainer(cb)
        end
      end
      if n > 8 then
        for _, c in pairs(g_game.getContainers()) do
          local ci = c:getContainerItem()
          if ci and ci:getId() == wantId and c:hasParent() and c:getItemsCount() < c:getCapacity() then
            removeEvent(ev)
            tr("   adopted a reused window for the depot bag")
            dq[1] = { container = c }
            return headContainer(cb)
          end
        end
        removeEvent(ev)
        tr("   depot bag would not open, trying the next one")
        table.remove(dq, 1)
        return headContainer(cb)
      end
    end, 150)
  end

  local opener = BagApply.newOpener()
  local i, moved, failed = 0, 0, 0
  local retryTile, refusedRun = 0, 0
  local trace = {}
  local function tr(...)
    table.insert(trace, string.format(...))
    pcall(function() g_resources.writeFileContents('/bagorg_drop.txt', table.concat(trace, "\n")) end)
  end
  tr("victims: %s", table.concat(victims, " ", 1, math.min(#victims, 8)))
  local ground = g_game.getLocalPlayer():getPosition()

  local function finish(msg)
    if not dropping then return end
    dropping = false
    opener.closeAll()
    if window then
      window.stop:setEnabled(false)
      window.dropEmpties:setEnabled(surplusCount() > 0)
    end
    log(msg)
    tree = BagPlan.derive(root)
    BagCache.save(tree)
    buildPlan()
    renderViews()
  end

  -- a watchdog: without it a step that never calls back would leave the button disabled forever
  local watchdog, lastProgress, lastSeen = nil, g_clock.millis(), -1
  watchdog = cycleEvent(function()
    if not dropping then removeEvent(watchdog) return end
    if moved + failed ~= lastSeen then
      lastSeen = moved + failed
      lastProgress = g_clock.millis()
    elseif g_clock.millis() - lastProgress > 25000 then
      removeEvent(watchdog)
      finish(string.format("Stopped: nothing happened for 8s after %d backpack(s) - see bagorg_skips.txt", moved))
    end
  end, 1000)

  local step
  step = function()
    if stopRequested then return finish(string.format("Stopped after dropping %d backpack(s).", moved)) end
    if retryTile > 0 then i = i - 1 retryTile = retryTile - 1 end   -- same bag, different tile
    i = i + 1
    local path = victims[i]
    if not path then
      return finish(string.format("Dropped %d of %d empty backpack(s)%s.", moved, #victims,
        failed > 0 and (", " .. failed .. " refused") or ""))
    end
    local node = byOrig[path]
    local live = node and BagPlan.pathOf(node)
    if not live then
      failed = failed + 1
      pcall(function() g_resources.writeFileContents('/bagorg_skips.txt',
        string.format("drop: %s has no live path", tostring(path))) end)
      return scheduleEvent(step, 20)
    end
    local parentPath, slot = BagApply.parentOf(live)
    tr("%d: %s -> opening parent %s (slot %s)", i, live, tostring(parentPath), tostring(slot))
    opener.ensure(parentPath or "", function(parent)
      tr("   parent %s: %s", tostring(parentPath), parent and (parent:isClosed() and "closed" or "open") or "nil")
      if not parent or parent:isClosed() then failed = failed + 1 return scheduleEvent(step, 30) end
      local it = parent:getItems()[(slot or 0) + 1]
      if not it or not it:isContainer() then failed = failed + 1 return scheduleEvent(step, 30) end
      local function withDest(dest, destC)
      if destC and (destC:isClosed() or destC:getItemsCount() >= destC:getCapacity()) then
        -- it filled up or closed between choosing it and moving: ask the queue again
        tr("   destination went stale, re-picking")
        return headContainer(function(c2)
          if not c2 then return finish(string.format("Nowhere left in the depot - dropped %d.", moved)) end
          depot = c2
          withDest(c2:getSlotPosition(c2:getItemsCount()), c2)
        end)
      end
      local before = parent:getItemsCount()
      g_game.move(it, dest, 1)
      -- Confirm it actually left: a refused move leaves the bag where it was, and pretending otherwise would
      -- desync the model from the game and poison the next plan.
      scheduleEvent(function()
        if parent:isClosed() or parent:getItemsCount() >= before then
          refusedRun = refusedRun + 1
          tr("   REFUSED: dest=%s src %s held %d now %d",
            destC and string.format("'%s' %d/%d closed=%s", tostring(destC:getName()), destC:getItemsCount(),
              destC:getCapacity(), tostring(destC:isClosed())) or "ground",
            tostring(parentPath), before, parent:getItemsCount())
          if toGround and tileIdx < #tiles then
            -- the floor here is full: move to the next tile and try THIS bag again rather than losing it
            tileIdx = tileIdx + 1
            onTile = 0
            retryTile = 1
            tr("   refused - next tile (%d of %d)", tileIdx, #tiles)
            return step()
          end
          -- a destination that refuses twice is unusable (a depot bag the server will not accept into);
          -- take it out of the queue so the run moves on instead of burning every remaining bag on it
          if destC and not toGround then
            destC.bagorgRefusals = (destC.bagorgRefusals or 0) + 1
            if destC.bagorgRefusals >= 2 and dq[1] and dq[1].container == destC then
              table.remove(dq, 1)
              tr("   dropping that depot bag from the queue after 2 refusals")
            end
          end
          failed = failed + 1
          tr("   refused (source still holds %d)", parent:getItemsCount())
          if refusedRun >= math.max(3, #tiles) then
            if toGround then
              return finish(string.format(
                "No free floor space here - dropped %d, %d refused. Stand somewhere open and press again.",
                moved, failed))
            end
            return finish(string.format(
              "The depot refused %d backpack(s) in a row - dropped %d. It may not accept nested bags this deep.",
              failed, moved))
          end
          return step()
        end
        refusedRun = 0
        local p = node.parent
        if p then
          for k, e in ipairs(p.items) do if e.bag == node then table.remove(p.items, k) break end end
        end
        node.parent = nil
        moved = moved + 1
        output:setText(string.format("Dropping empty backpacks...\n\n%d / %d done%s", moved, #victims,
          failed > 0 and ("\n" .. failed .. " refused") or ""))
        step()
      end, MOVE_MS)
      end   -- withDest

      if toGround then
        if onTile >= PER_TILE and tileIdx < #tiles then tileIdx = tileIdx + 1 onTile = 0 end
        onTile = onTile + 1
        return withDest(tiles[tileIdx] or ground)
      end
      headContainer(function(c)
        if not c then
          if mode == 'both' then
            toGround = true
            log(string.format("Depot chain exhausted after %d - carrying on on the ground.", moved))
            return withDest(tiles[tileIdx] or ground)
          end
          return finish(string.format("Nowhere left in the depot - dropped %d backpack(s).", moved))
        end
        depot = c
        tr("   into '%s' %d/%d", tostring(c:getName()), c:getItemsCount(), c:getCapacity())
        withDest(c:getSlotPosition(c:getItemsCount()), c)
      end)
    end)
  end
  step()
end

local function waitUntil(test, done, tries)
  local n, ev = 0, nil
  ev = cycleEvent(function()
    n = n + 1
    if test() then removeEvent(ev) done(true)
    elseif n > (tries or 25) then removeEvent(ev) done(false) end
  end, 150)
end

-- The loot bag belongs in the main backpack's first slot, so a hunt fills main, then cascades straight into it
-- (and from there into the empties nested inside it). This server front-inserts: whatever was moved in last
-- sits at slot 0 - verified live - so "make it first" is one move out and one move back.
-- Returns lootPath, tempPath when a reorder is due; the temp bag must sit at a LOWER slot than the loot bag,
-- otherwise taking the loot bag out renumbers it.
local function lootFirstNeeded()
  if not tree or not lastInfo or not lastInfo.home then return nil end
  local loot = lastInfo.home[LOOT_BUCKET]
  if not loot or not loot:match("^/%d+$") or loot == "/0" then return nil end
  local lootSlot = tonumber(loot:match("^/(%d+)$"))
  for slot = 0, lootSlot - 1 do
    local path = "/" .. slot
    local node = tree[path]
    if node and #(node.items or {}) < (node.cap or 20) then return loot, path end
  end
  return nil
end

local function lootFirst(cb)
  local loot, temp = lootFirstNeeded()
  if not loot then return cb(false) end
  local lootSlot, tempSlot = tonumber(loot:match("^/(%d+)$")), tonumber(temp:match("^/(%d+)$"))
  log(string.format("  moving the loot bag from slot %d to slot 0", lootSlot))
  prepareRoot(function(root)
    if not root then return cb(false) end
    local tempItem, lootItem = root:getItems()[tempSlot + 1], root:getItems()[lootSlot + 1]
    if not tempItem or not tempItem:isContainer() or not lootItem or not lootItem:isContainer() then
      return cb(false)
    end
    local seen = {}
    for cid in pairs(g_game.getContainers()) do seen[cid] = true end
    g_game.open(tempItem)
    waitUntil(function()
      for cid in pairs(g_game.getContainers()) do if not seen[cid] then return true end end
    end, function(opened)
      local tempC
      for cid, c in pairs(g_game.getContainers()) do if not seen[cid] then tempC = c end end
      if not opened or not tempC then return cb(false) end
      local was = tempC:getItemsCount()
      g_game.move(lootItem, tempC:getSlotPosition(was), 1)
      waitUntil(function() return tempC:getItemsCount() > was end, function(landed)
        if not landed then return cb(false) end
        local moved = tempC:getItems()[1]
        if not moved or not moved:isContainer() then return cb(false) end
        g_game.move(moved, root:getSlotPosition(root:getItemsCount()), 1)
        scheduleEvent(function() cb(true) end, 700)
      end, 20)
    end, 20)
  end)
end

local scanFromCache = false

local refreshOnly, staleTree     -- set by preview() when only a few bags need re-reading
local scanNote                   -- how the tree was obtained, printed by showPreview (clearLog eats anything earlier)

local function showPreview()
  local perBucket, info, totalMoves = buildPlan()
  clearLog()
  if scanNote then
    log(scanNote)
  elseif scanFromCache then
    local age = BagCache.age()
    log(string.format("Saved scan of %d bags%s - Rescan to read them again.",
      BagScan.size(tree), age and (", " .. age .. "s old") or ""))
  else
    log("Scanned " .. BagScan.size(tree) .. " bags in " .. scanSeconds .. "s.")
  end
  log("")
  log("target: one backpack per category, overflow nested inside it")
  log("")
  for _, b in ipairs(bucketOrder()) do
    local d = info.buckets and info.buckets[b]
    if perBucket[b] then
      local spread, slots = 0, 0
      for _, n in pairs(perBucket[b]) do spread = spread + 1 slots = slots + n end
      if d then
        log(string.format("%-11s %4d slot(s) in %d bag(s) -> 1 bag + %d nested", b, slots, spread, d.nested or 0))
      else
        log(string.format("%-11s %4d slot(s) in %d bag(s) -> no bag free!", b, slots, spread))
      end
    end
  end
  log("")
  log(string.format("moves: %d to free slots + %d bag(s) to nest/collect + %d item(s)",
    #(planRoomMoves or {}), #(planBagMoves or {}), #plan))
  if (info.emptiesMoved or 0) > 0 and info.collector then
    log(string.format("%d empty bag(s) gathered into slot %s for dropping",
      info.emptiesMoved, (info.collector:gsub("^/", ""))))
  end
  local stuck = (info.blocked or 0) + (info.unplaced or 0)
  if stuck > 0 then log(string.format("%d item(s) have nowhere to go", stuck)) end
  if (info.deferred or 0) > 0 then
    log(string.format("%d item(s) wait for a backpack being placed (handled after step 2)", info.deferred))
  end
  if (info.shortBags or 0) > 0 then
    log(string.format("add %d more empty backpack(s) to fit everything", info.shortBags))
  end
  for _, m in ipairs(planBagMoves or {}) do
    if m.promote then
      log(string.format("%-11s gets an empty backpack moved into the main backpack (then Apply again)",
        tostring(m.bucket)))
    end
  end
  local empties = emptyBags()
  local keep = keepCount()
  local surplus = math.max(0, #empties - keep)
  if window.emptyInfo then
    window.emptyInfo:setText(string.format("%d empty, keeping %d%s", #empties, math.min(keep, #empties),
      surplus > 0 and string.format(", %d surplus", surplus) or " - none spare"))
  end
  if window.dropEmpties then window.dropEmpties:setEnabled(surplus > 0) end
  local lootPath = lootFirstNeeded()
  if lootPath then
    log(string.format("the loot bag (%s) will move to the first slot (2 moves)", lootPath))
    totalMoves = totalMoves + 1
  end
  if totalMoves == 0 then
    if stuck > 0 then
      log("Nothing can be moved: add an empty backpack to the main backpack for the bucket marked above.")
    else
      log("Nothing to do - already matches the target layout.")
    end
  end
  window.apply:setEnabled(totalMoves > 0)
  renderViews()
end

-- ---- apply -----------------------------------------------------------------------------------------
-- The old pass re-opened bags per move group through a ref-counted opener and spent all its time failing to open
-- deep ones (0 of 63 moves in 19 s). The server keeps ~15 containers open at once, so instead: open every bag the
-- plan touches EXACTLY ONCE, keep them all open (minimized, so the panel can hold them), then move directly
-- between live containers. No re-opening, no stale item references.
local OPEN_CAP = 15
local OPEN_TIMEOUT = 1500


-- Three phases, in dependency order. Nesting a bag needs a free slot in the category bag, and when that bag is
-- full the items which would free one are the very items destined for the nested bag - so room is made first.
-- Bag moves change paths, so the tree is rescanned and the plan rebuilt before the item moves run.
-- Apply runs in passes, because one pass cannot finish the job: bags freed by this pass become the overflow
-- containers the next one needs. A single pass therefore leaves an intermediate, half-sorted-looking state.
--
-- Within a pass the order is forced by dependency:
--   1 free slots   park items out of a full category bag so a nested bag can go in
--   2 place bags   nest the overflow bags, collect the empties
--     rescan       bag moves change paths, so the plan is rebuilt against reality
--   3 sort items   move everything to its category bag
--
-- Bounded three ways so it can never spin: a hard pass cap, a stop when a pass achieves nothing, and a stop when
-- the remaining work is not shrinking.
local PLAN_ROUNDS = 14       -- planning rounds, done offline: they cost milliseconds, not a scan each
local MAX_RUNS = 8           -- plan/execute rounds; they re-plan from the executor's model, never rescanning

local function skipText(sum)
  local sk = {}
  if sum.skipped.noRoom > 0 then table.insert(sk, sum.skipped.noRoom .. " no room") end
  if sum.skipped.notOpen > 0 then
    local where = (sum.skipped.paths and #sum.skipped.paths > 0)
      and (" [" .. table.concat(sum.skipped.paths, " ") .. "]") or ""
    table.insert(sk, sum.skipped.notOpen .. " could not open" .. where)
  end
  if sum.skipped.gone > 0 then table.insert(sk, sum.skipped.gone .. " already gone") end
  return #sk > 0 and (" - " .. table.concat(sk, ", ")) or ""
end

-- ONE plan, then one stream of moves. The planner works out the whole job offline - including the rounds that
-- used to need a rescan each, because a bag move renumbers live paths - and every move names its bags by the
-- path they had at scan time. A 400-bag hoard therefore costs one scan, not one per pass.
local function applyPlan()
  applying = true
  stopRequested = false
  local applyStart = g_clock.millis()
  local run = 0
  window.apply:setEnabled(false)
  window.preview:setEnabled(false)
  window.stop:setEnabled(true)

  local function elapsed() return math.floor((g_clock.millis() - applyStart) / 1000) end

  local function finishRun(msg)
    log(string.format("%s  (%ds)", msg, elapsed()))
    applying = false
    if window then
      window.preview:setEnabled(true)
      window.stop:setEnabled(false)
      window.apply:setEnabled(false)
    end
    renderViews()
  end

  local function rescanThen(cb)
    if stopRequested then return finishRun("Stopped.") end
    output:setText("rescanning to check the result...")
    prepareRoot(function(root)
      if not root then return finishRun("lost the main backpack - scan and apply again") end
      BagScan.run(root, function(nodes)
        if stopRequested then return finishRun("Stopped.") end
        tree = nodes
        BagCache.save(tree)
        buildPlan()
        cb()
      end, function(scanned)
        output:setText(string.format("rescanning to check the result... %d bags", scanned))
      end)
    end)
  end

  local function finishWithLootFirst()
    lootFirst(function(did)
      if did then log("  loot bag is now first in the main backpack") end
      finishRun(did and "Done - sorted, loot bag first" or "Done - everything is in its category bag")
    end)
  end

  local runOnce
  runOnce = function()
    if stopRequested then return finishRun("Stopped.") end
    run = run + 1
    local list, rep = BagPlan.fullPlan(tree, bucketFor, PLAN_ROUNDS, planOpts())
    log(string.format("run %d: %d move(s) planned (%d planning round(s))%s", run, #list, rep.rounds,
      rep.err and (" - " .. rep.err) or ""))
    if #list == 0 then return finishWithLootFirst() end

    BagApply.executePlan(list, tree, {
      moveMs = MOVE_MS,
      isStopped = function() return stopRequested end,
      onStatus = function(_, moved, tot, skips, openNow)
        output:setText(string.format("Round %d/%d - moving\n\n%d / %d done%s\n\n%d bag(s) open",
          run, MAX_RUNS, moved, tot, skips ~= "" and ("\n" .. skips) or "", openNow))
      end,
      onDone = function(sum)
        log(string.format("  moved %d/%d%s", sum.moved, sum.total, skipText(sum)))
        if sum.reason == "stopped" then
          -- the run stopped part way, so the tree no longer describes the game
          if sum.moved > 0 then BagCache.forget() end
          return finishRun("Stopped - press Rescan before the next run.")
        end
        -- "already gone" means the model and the game disagree about where something is, so the tree cannot be
        -- trusted for planning: throw it away and read the bags for real. Anything else (no room, would not
        -- open) left the game untouched, so the model is still accurate and the next round is planned from it
        -- offline, in milliseconds.
        if (sum.skipped.gone or 0) > 0 then
          log("  the game disagreed with the saved layout - reading every backpack again")
          BagCache.forget()
          return rescanThen(function()
            local l = #(plan or {}) + #(planBagMoves or {}) + #(planRoomMoves or {})
            if l == 0 then return finishWithLootFirst() end
            if run >= MAX_RUNS then
              return finishRun(string.format("%d move(s) left after %d round(s) - Apply again to continue", l, run))
            end
            log(string.format("  %d move(s) left, planning round %d from a fresh read", l, run + 1))
            runOnce()
          end)
        end
        if sum.tree then
          tree = sum.tree
          scanFromCache = false
          scanNote = nil
          BagCache.save(tree)
          buildPlan()
        end
        local left = #(plan or {}) + #(planBagMoves or {}) + #(planRoomMoves or {})
        if left == 0 then return finishWithLootFirst() end
        local stuck = (lastInfo and ((lastInfo.unplaced or 0) + (lastInfo.blocked or 0))) or 0
        if run >= MAX_RUNS or sum.moved == 0 then
          -- A round that moved nothing means the model no longer matches the game - usually a tree carried over
          -- from a cache that missed a structural change. Throw it away and read the bags for real.
          if sum.moved == 0 then
            log("  the saved layout no longer matches the game - reading every backpack again")
            BagCache.forget()
          end
          return rescanThen(function()
            local l2 = #(plan or {}) + #(planBagMoves or {}) + #(planRoomMoves or {})
            if l2 == 0 then return finishWithLootFirst() end
            finishRun(string.format("%d move(s) left after %d round(s)%s - Apply again to continue",
              l2, run, stuck > 0 and (", " .. stuck .. " item(s) have nowhere to go") or ""))
          end)
        end
        log(string.format("  %d move(s) left, planning round %d from the result", left, run + 1))
        runOnce()
      end,
    })
  end

  runOnce()
end


-- ---- bucket UI ------------------------------------------------------------------------------------
local refreshBuckets

local function catLabel(mc)
  for _, c in ipairs(CATS) do if c[1] == mc then return c[2] end end
  return "?"
end

local function bucketSummary(b)
  local names = {}
  for _, c in ipairs(CATS) do if b.cats[c[1]] then table.insert(names, c[2]) end end
  if #names == 0 then return "(no categories - matches nothing)" end
  local s = table.concat(names, ", ")
  if #s > 52 then s = s:sub(1, 50) .. "..." end
  return s
end

-- The category NAMES are not what this server's items actually report: paws and cloth come back as Others,
-- not Creature products. So the editor shows how many of your carried items are really in each category -
-- ticking a category with (0) is how a bucket ends up silently empty.
local function categoryCounts()
  local counts = {}
  for _, node in pairs(tree or {}) do
    for _, e in ipairs(node.items or {}) do
      if not e.isContainer then
        local cat = categoryOf(e.id)
        if cat then counts[cat] = (counts[cat] or 0) + 1 end
      end
    end
  end
  return counts
end

local function editBucket(bucket, isNew)
  local w = g_ui.createWidget('BagOrgEditor', g_ui.getRootWidget())
  w.nameEdit:setText(bucket.name or "")
  local counts = categoryCounts()
  local boxes = {}
  for _, c in ipairs(CATS) do
    local cb = g_ui.createWidget('BagOrgCatCheck', w.cats)
    local n = counts[c[1]] or 0
    cb:setText(n > 0 and string.format("%s  (%d)", c[2], n) or string.format("%s  (0)", c[2]))
    if n == 0 then cb:setColor('#8a9298') end
    cb:setChecked(bucket.cats[c[1]] == true)
    boxes[c[1]] = cb
  end
  w.cancelBtn.onClick = function() w:destroy() end
  w.saveBtn.onClick = function()
    bucket.name = w.nameEdit:getText():trim()
    if bucket.name == "" then bucket.name = "Bucket" end
    bucket.cats = {}
    for mc, cb in pairs(boxes) do if cb:isChecked() then bucket.cats[mc] = true end end
    if isNew then table.insert(config.buckets, bucket) end
    saveConfig()
    refreshBuckets()
    w:destroy()
  end
end

refreshBuckets = function()
  if not window then return end
  window.buckets:destroyChildren()
  for _, b in ipairs(config.buckets) do
    local row = g_ui.createWidget('BagOrgBucketRow', window.buckets)
    row.name:setText(b.name)
    row.sub:setText(bucketSummary(b))
    row.editBtn.onClick = function() editBucket(b, false) end
    row.removeBtn.onClick = function()
      for i, x in ipairs(config.buckets) do if x == b then table.remove(config.buckets, i) break end end
      saveConfig() refreshBuckets()
    end
  end
end

-- ---- run -------------------------------------------------------------------------------------------

local function mainContainer()
  for _, c in pairs(g_game.getContainers()) do
    if not c:hasParent() then return c end
  end
  -- else the first open container
  for _, c in pairs(g_game.getContainers()) do return c end
  return nil
end

-- close every open container, then open the worn backpack fresh, then run cb(rootContainer). This guarantees we
-- start from the real main backpack with a clean slate (no leftover windows eating the 16-container budget).
prepareRoot = function(cb)
  for _, c in pairs(g_game.getContainers()) do g_game.close(c) end
  local me = g_game.getLocalPlayer()
  local bp = me and me:getInventoryItem(InventorySlotBack)
  if not bp then clearLog() log("No backpack equipped in the back slot.") return end
  scheduleEvent(function()
    g_game.open(bp)
    -- wait for it to open, then hand back the root
    local tries = 0
    local waitEvent
    waitEvent = cycleEvent(function()
      tries = tries + 1
      local root
      for _, c in pairs(g_game.getContainers()) do if not c:hasParent() then root = c break end end
      if root then removeEvent(waitEvent) cb(root)
      elseif tries > 30 then removeEvent(waitEvent) clearLog() log("Could not open the main backpack.") end
    end, 150)
  end, 250)
end

-- modules.game_bag_organizer.diagnose() - prints exactly what the scan saw, so the plan can be checked against
-- reality: per bucket, every bag holding it with slots used / capacity, and how much free space actually exists.
-- modules.game_bag_organizer.testOpen()
-- Opens every path the current plan touches, one at a time, and reports which fail. Moves NOTHING: this isolates
-- the opener from the move logic, so a failure here is an opening bug and a failure only during apply is not.
function testOpen()
  if not plan then print("[bagorg] preview first") return end
  local seen, paths = {}, {}
  local function add(p)
    if p and not seen[p] then seen[p] = true table.insert(paths, p) end
  end
  for _, m in ipairs(planBagMoves or {}) do
    add((m.fromPath:match("^(.-)/%d+$")))
    add(m.toPath)
  end
  for _, m in ipairs(plan) do add(m.fromPath) add(m.toPath) end
  table.sort(paths, function(a, b)
    local _, da = a:gsub("/", "")
    local _, db = b:gsub("/", "")
    if da ~= db then return da < db end
    return a < b
  end)

  for _, c in pairs(g_game.getContainers()) do
    if c:hasParent() then pcall(function() g_game.close(c) end) end
  end

  local opener = BagApply.newOpener({ "" })
  local i, okN, failN = 0, 0, 0
  local step
  step = function()
    i = i + 1
    local path = paths[i]
    if not path then
      print(string.format("[bagorg] open test done: %d ok, %d FAILED, %d container(s) open at the end",
        okN, failN, opener.openCount()))
      opener.closeAll()
      return
    end
    opener.ensure(path, function(c)
      if c then okN = okN + 1 print(string.format("[bagorg] OK   %-10s (%d open)", path, opener.openCount()))
      else failN = failN + 1 print(string.format("[bagorg] FAIL %-10s (%d open)", path, opener.openCount())) end
      scheduleEvent(step, 150)
    end)
  end
  print(string.format("[bagorg] opening %d path(s) from the plan - nothing will be moved", #paths))
  step()
end

-- modules.game_bag_organizer.classify()
-- Every distinct item the scan found, with the market category it reports and the bucket it lands in. If items
-- you would call jewelry show up as "Loot" or with no category, the classifier is wrong and no amount of move
-- logic can sort them correctly.
-- modules.game_bag_organizer.dumpState() - scan, plan, and write the real tree plus the planner's target to
-- userdata/bridge_dump.txt. Lives here because BagScan/BagPlan/bucketFor are inside this module's sandbox.
-- modules.game_bag_organizer.dumpLog() - the window's log to a file, so a run can be inspected without the UI
function dumpLog()
  pcall(function()
    g_resources.writeFileContents('/bridge_applylog.txt',
      table.concat(logLines or {}, "\n") .. "\n[applying=" .. tostring(applying) .. "]\n")
  end)
  print("[bagorg] log written")
end

function dumpState()
  prepareRoot(function(root)
    if not root then print("[bagorg] no main backpack") return end
    BagScan.run(root, function(nodes)
      tree = nodes
      local paths = {}
      for path in pairs(nodes) do table.insert(paths, path) end
      table.sort(paths, function(a, b)
        local _, da = a:gsub("/", "")
        local _, db = b:gsub("/", "")
        if da ~= db then return da < db end
        return a < b
      end)

      local out = {}
      local function w(...) out[#out + 1] = string.format(...) end

      w("=== REAL TREE (%d bags) ===", #paths)
      for _, path in ipairs(paths) do
        local n = nodes[path]
        local subs, loose, byB = 0, 0, {}
        for _, e in ipairs(n.items or {}) do
          if e.isContainer then subs = subs + 1
          else
            loose = loose + 1
            local b = bucketFor(e.id)
            byB[b] = (byB[b] or 0) + 1
          end
        end
        local mix = {}
        for b, c in pairs(byB) do table.insert(mix, b .. "=" .. c) end
        table.sort(mix)
        w("%-10s cap=%-3d used=%-3d subs=%d loose=%-3d %s",
          path == "" and "(main)" or path, n.cap or 20, #(n.items or {}), subs, loose,
          table.concat(mix, "  "))
      end

      local moves, info, bagMoves, roomMoves = BagPlan.build(nodes, bucketFor, planOpts())
      w("")
      w("=== PLANNER TARGET ===")
      for _, b in ipairs(bucketOrder()) do
        local d = info.buckets and info.buckets[b]
        if d then
          w("%-14s home=%-6s need=%-4d nested=%d capacity=%d",
            b, tostring(info.home and info.home[b]), d.need, d.nested, d.capacity)
        end
      end
      w("roomMoves=%d bagMoves=%d itemMoves=%d blocked=%d unplaced=%d shortBags=%d",
        #roomMoves, #bagMoves, #moves, info.blocked, info.unplaced, info.shortBags or 0)
      w("collector=%s", tostring(info.collector))
      w("")
      w("=== BAG MOVES ===")
      for _, m in ipairs(bagMoves) do
        w("  %-10s -> %-10s %s", m.fromPath, m.toPath, m.empties and "(collect empty)" or "(nest overflow)")
      end
      w("")
      w("=== ITEM MOVES (first 40) ===")
      for i, m in ipairs(moves) do
        if i > 40 then w("  ... %d more", #moves - 40) break end
        w("  %-10s -> %-10s id=%-6d %s", m.fromPath, m.toPath, m.id, m.bucket)
      end

      pcall(function() g_resources.writeFileContents('/bridge_dump.txt', table.concat(out, "\n") .. "\n") end)
      print("[bagorg] dumped " .. #paths .. " bags + plan to bridge_dump.txt")
    end, function() end)
  end)
end

function classify()
  if not tree then print("[bagorg] preview first") return end
  local seen, rows = {}, {}
  for _, node in pairs(tree) do
    for _, e in ipairs(node.items or {}) do
      if not e.isContainer and not seen[e.id] then
        seen[e.id] = true
        local cat = categoryOf(e.id)
        table.insert(rows, {
          id = e.id,
          name = itemName(e.id) or ("item " .. e.id),
          cat = cat and tostring(cat) or "NONE",
          bucket = bucketFor(e.id),
        })
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.bucket ~= b.bucket then return a.bucket < b.bucket end
    return a.name < b.name
  end)
  local perBucket, noCat = {}, 0
  for _, r in ipairs(rows) do
    perBucket[r.bucket] = (perBucket[r.bucket] or 0) + 1
    if r.cat == "NONE" then noCat = noCat + 1 end
  end
  print(string.format("[bagorg] %d distinct item(s); %d have NO market category", #rows, noCat))
  local last
  for _, r in ipairs(rows) do
    if r.bucket ~= last then print("[bagorg] --- " .. r.bucket .. " ---") last = r.bucket end
    print(string.format("[bagorg]   %-28s id=%-5d cat=%s", r.name:sub(1, 28), r.id, r.cat))
  end
  print("[bagorg] per bucket:")
  for b, n in pairs(perBucket) do print(string.format("[bagorg]   %-14s %d distinct item(s)", b, n)) end
end

function diagnose()
  if not tree then print("[bagorg] no scan yet - press Preview first") return end
  local byBucket = {}
  for path, node in pairs(tree) do
    if node.items then
      local counts = {}
      for _, e in ipairs(node.items) do
        if not e.isContainer then
          local b = bucketFor(e.id)
          counts[b] = (counts[b] or 0) + 1
        end
      end
      for b, n in pairs(counts) do
        byBucket[b] = byBucket[b] or {}
        table.insert(byBucket[b], { path = path, used = #node.items, cap = node.cap or 20, n = n })
      end
    end
  end
  print("[bagorg] ===== bag occupancy as the scan saw it =====")
  for b, list in pairs(byBucket) do
    table.sort(list, function(x, y) return x.n > y.n end)
    local freeHere, slotsHere = 0, 0
    for _, e in ipairs(list) do
      freeHere = freeHere + math.max(0, e.cap - e.used)
      slotsHere = slotsHere + e.n
    end
    print(string.format("[bagorg] %s: %d slot(s) of it, across %d bag(s), %d free slot(s) in those bags",
      b, slotsHere, #list, freeHere))
    for _, e in ipairs(list) do
      print(string.format("[bagorg]    %-12s %2d/%2d used, %2d of them %s, %2d free",
        e.path == "" and "(main)" or e.path, e.used, e.cap, e.n, b, math.max(0, e.cap - e.used)))
    end
    print(string.format("[bagorg]    minimum bags this bucket can fit in: %d",
      math.max(1, math.ceil(slotsHere / 20))))
  end
  local totalFree, bags = 0, 0
  for _, node in pairs(tree) do
    if node.items then bags = bags + 1 totalFree = totalFree + math.max(0, (node.cap or 20) - #node.items) end
  end
  print(string.format("[bagorg] %d bag(s), %d free slot(s) in total; plan holds %d move(s)",
    bags, totalFree, plan and #plan or 0))
end

function preview(force)
  if applying then return end
  refreshOnly, staleTree, scanNote = nil, nil, nil
  demoBuckets = nil        -- a real scan classifies by market category, never by the demo map
  clearLog()
  if not force then
    local cached, why = BagCache.load()
    if cached then
      tree = cached
      scanSeconds = 0
      scanFromCache = true
      scanNote = nil
      showPreview()
      return
    end
    -- Something changed. If we know WHICH bags, re-read only those: one open costs ~200 ms of server time,
    -- so 400 bags is 85 s while three bags is under a second.
    local changed = BagCache.changed()
    local stale = BagCache.load(true)
    if stale and changed and #changed > 0 and #changed <= 24 then
      refreshOnly = changed
      staleTree = stale
      log(string.format("Re-reading %d changed bag(s) (%s)...", #changed, why or "changed"))
    elseif why then
      log("Reading your backpacks (" .. why .. ")...")
    end
  end
  log("Closing bags and opening the main backpack...")
  window.preview:setEnabled(false)
  if BagScan.cancel then BagScan.cancel() end   -- stop any scan still running
  scanGen = scanGen + 1
  local myGen = scanGen
  local scanStart = g_clock.millis()
  quipAt = 0 lastQuip = ""
  prepareRoot(function(root)
    if myGen ~= scanGen or not window then return end
    scanStart = g_clock.millis()
    progWindow = {} progLastScanned = 0 progLastMs = 0
    scanning = true
    window.stop:setEnabled(true)
    if not refreshOnly then log("Scanning (opening each bag, moving nothing)...") end
    BagScan.run(root, function(nodes)
      if myGen ~= scanGen or not window then scanning = false return end
      scanning = false
      tree = nodes
      scanFromCache = false
      local wasRefresh, refreshCount = refreshOnly ~= nil, refreshOnly and #refreshOnly or 0
      refreshOnly, staleTree = nil, nil
      BagCache.save(tree)
      scanSeconds = math.floor((g_clock.millis() - scanStart) / 1000)
      scanNote = wasRefresh and string.format("Re-read %d changed bag(s) in %ds - %d bags known, the rest came from the saved scan.",
        refreshCount, scanSeconds, BagScan.size(nodes)) or nil
      lastScanTotal = BagScan.size(nodes)
      g_settings.set('bagOrganizerLastTotal', lastScanTotal)
      window.preview:setEnabled(true)
      window.stop:setEnabled(false)
      showPreview()
    end, function(scanned, queued, topTotal, branchesDone, completedBags)
      if myGen ~= scanGen or not window then return end
      -- only exact, confirmed numbers: bags opened so far, and which top backpack we are in (both known for sure).
      -- No total / percent / ETA - the total is unknowable until every bag is opened.
      local now = g_clock.millis()
      if now - quipAt >= QUIP_MS then quipAt = now lastQuip = QUIPS[math.random(1, #QUIPS)] end
      output:setText(string.format("%s\n\n%d bags opened\n\n%s",
        refreshOnly and "Re-reading the bags that changed..." or "Scanning your bags...", scanned, lastQuip))
    end, refreshOnly and { into = staleTree, paths = refreshOnly } or nil)
  end)
end

function apply()
  if applying then return end
  if scanning then log("still reading your backpacks - wait for the scan to finish") return end
  local n = #(plan or {}) + #(planBagMoves or {}) + #(planRoomMoves or {})
  if n == 0 then
    -- nothing to sort, but the loot bag may still be in the wrong slot
    if not lootFirstNeeded() then return end
    applying = true
    window.apply:setEnabled(false)
    log("Moving the loot bag to the first slot...")
    return lootFirst(function(did)
      applying = false
      log(did and "  loot bag is now first in the main backpack" or "  could not move the loot bag")
      if window then window.preview:setEnabled(true) end
      preview()
    end)
  end
  log(string.format("Applying %d move(s)...", n))
  applyPlan()
end

function stop()
  if dropping then stopRequested = true log("Stopping...") return end
  stopRequested = true
  if BagScan.cancel then BagScan.cancel() end
  if scanning then
    scanning = false
    scanGen = scanGen + 1   -- drop the in-flight scan's onDone
    if window then
      window.preview:setEnabled(true)
      window.stop:setEnabled(false)
      log("Scan stopped.")
    end
  end
  if applying then
    -- every phase checks stopRequested between moves, so it halts within one move interval
    log("Stopping after the current move...")
  end
end

-- Renders a synthetic inventory into both panes so the view can be checked without a server.
function vizDemo(messy)
  local t = {}
  local function bag(path, id, cap)
    t[path] = { path = path, id = id or 2854, cap = cap or 20, items = {} }
    return t[path]
  end
  local function put(path, id, count)
    table.insert(t[path].items, { id = id, count = count or 1, isContainer = false, slot = #t[path].items })
  end
  local function nest(parent, child, id)
    table.insert(t[parent].items, { id = id or 2854, isContainer = true, sub = child, slot = #t[parent].items })
    bag(child, id)
  end
  local COIN, HP, MP, ERING, LRING, ROPE, SHOVEL, MEAT = 2148, 7618, 7620, 2167, 2168, 2120, 2554, 2666
  local real, realBags = realIdsByBucket()
  local usedReal = {}
  local function pick(bucket, nth, fallback)
    local list = real and real[bucket]
    local id = list and list[nth]
    if id and not usedReal[id] then usedReal[id] = true return id end
    return fallback
  end
  ERING  = pick("Jewelry", 1, ERING)
  LRING  = pick("Jewelry", 2, LRING)
  HP     = pick("Potions & Runes", 1, pick("Potions", 1, HP))
  MP     = pick("Potions & Runes", 2, pick("Potions", 2, MP))
  COIN   = pick("Loot", 1, COIN)
  MEAT   = pick("Loot", 2, MEAT)
  ROPE   = pick("Tools", 1, ROPE)
  SHOVEL = pick("Tools", 2, SHOVEL)
  local BAG_A = (realBags and realBags[1]) or 2854
  local BAG_B = (realBags and realBags[2]) or 1987
  demoBuckets = { [ERING] = "Jewelry", [LRING] = "Jewelry", [HP] = "Potions", [MP] = "Potions",
                  [COIN] = "Valuables", [MEAT] = "Supplies", [ROPE] = "Tools", [SHOVEL] = "Tools" }
  bag("")
  for i = 0, 4 do nest("", "/" .. i, i == 0 and BAG_B or BAG_A) end
  if messy then
    for i = 0, 3 do nest("/0", "/0/" .. i, BAG_B) end
    for _ = 1, 6 do put("/0", ERING) end
    for _ = 1, 4 do put("/1", HP) end
    for _ = 1, 9 do put("/1", COIN, 42) end
    for _ = 1, 3 do put("/1", LRING) end
    put("/2", ROPE) put("/2", SHOVEL)
    for _ = 1, 5 do put("/2", MEAT) end
    for _ = 1, 7 do put("/3", MP) end
    for _ = 1, 8 do put("/3", ERING) end
    for _ = 1, 11 do put("/4", LRING) end
    for _ = 1, 4 do put("/0/1", HP) end
    for _ = 1, 12 do put("/0/2", ERING) end
  else
    for i = 0, 3 do nest("/0", "/0/" .. i, BAG_B) end
    for _ = 1, 12 do put("/1", COIN, 87) end
    for _ = 1, 6 do put("/1", MEAT) end
    put("/2", ROPE) put("/2", SHOVEL)
    for _ = 1, 6 do put("/3", HP) end
    for _ = 1, 16 do put("/4", ERING) end
    for i = 0, 3 do nest("/4", "/4/" .. i, BAG_A) end
    for _ = 1, 7 do put("/4/0", LRING) end
    for _ = 1, 20 do put("/4/1", ERING) end
  end

  show()            -- before the tree is set: show() blanks the panes
  tree = t
  scanSeconds = 0
  showPreview()
  local rows, tallest, total = 0, 0, 0
  for _, r in ipairs(window.leftView:getChildren()) do
    rows = rows + 1
    total = total + r:getHeight()
    tallest = math.max(tallest, r:getHeight())
  end
  local lines = { string.format("demo rendered: %s", messy and "messy" or "sorted") }
  table.insert(lines, string.format("left rows=%d content=%dpx pane=%dpx tallest row=%dpx",
    rows, total, window.leftView:getHeight(), tallest))
  table.insert(lines, "left:  " .. window.leftSummary:getText())
  table.insert(lines, "right: " .. window.rightSummary:getText())
  local wide = 0
  for _, r in ipairs(window.leftView:getChildren()) do
    for _, c in ipairs(r:getChildren()) do
      if c:getMarginLeft() + c:getWidth() > window.leftView:getWidth() then wide = wide + 1 end
    end
  end
  table.insert(lines, string.format("cells past the right edge: %d", wide))
  local txt = table.concat(lines, "\n")
  g_resources.writeFileContents('/vizdemo.txt', txt)
  print(txt)
  return txt
end

-- modules.game_bag_organizer.groups() - per item type: how many bags hold it, from the last scan. One bag per
-- type is the goal; more than ceil(count/20) means placement split a type that could have stayed together.
function groups()
  if not tree then print("[bagorg] scan first") return "scan first" end
  local per = {}
  for path, node in pairs(tree) do
    for _, e in ipairs(node.items or {}) do
      if not e.isContainer then
        per[e.id] = per[e.id] or { n = 0, slots = 0, where = {} }
        per[e.id].n = per[e.id].n + (e.count or 1)
        per[e.id].slots = per[e.id].slots + 1
        per[e.id].where[path] = (per[e.id].where[path] or 0) + 1
      end
    end
  end
  local rows, bad = {}, 0
  for id, rec in pairs(per) do
    local bags, parts = 0, {}
    for path, n in pairs(rec.where) do
      bags = bags + 1
      table.insert(parts, string.format("%s=%d", path == "" and "(main)" or path, n))
    end
    table.sort(parts)
    local need = math.max(1, math.ceil(rec.slots / 20))
    if bags > need then bad = bad + 1 end
    table.insert(rows, { id = id, bags = bags, need = need, slots = rec.slots,
                         line = string.format("%-24s %3d slot(s) in %d bag(s)%s  %s",
                           itemName(id) .. " [" .. id .. "]", rec.slots, bags,
                           bags > need and (" SPLIT (needs " .. need .. ")") or "", table.concat(parts, " ")) })
  end
  table.sort(rows, function(a, b) if a.bags ~= b.bags then return a.bags > b.bags end return a.slots > b.slots end)
  local out = { string.format("=== ITEM GROUPING (%d type(s), %d split) ===", #rows, bad) }
  for _, r in ipairs(rows) do table.insert(out, "  " .. r.line) end
  local txt = table.concat(out, "\n")
  g_resources.writeFileContents('/bridge_groups.txt', txt)
  print(txt)
  return txt
end

-- modules.game_bag_organizer.dumpTree() - every bag with its items in slot order, ids and all, so a live
-- layout can be reproduced offline exactly.
function dumpTree()
  if not tree then return "scan first" end
  local paths = {}
  for p in pairs(tree) do table.insert(paths, p) end
  table.sort(paths)
  local out = {}
  for _, p in ipairs(paths) do
    local node = tree[p]
    local parts = {}
    for _, e in ipairs(node.items or {}) do
      table.insert(parts, e.isContainer and ("bag->" .. tostring(e.sub)) or (tostring(e.id) .. "x" .. tostring(e.count or 1)))
    end
    table.insert(out, string.format("%-10s cap=%d id=%s  %s", p == "" and "(main)" or p,
      node.cap or 0, tostring(node.id), table.concat(parts, " ")))
  end
  local txt = table.concat(out, "\n")
  g_resources.writeFileContents('/bridge_tree.txt', txt)
  return txt
end

-- modules.game_bag_organizer.testApply(n) - plans the whole job, then executes only the first n moves.
-- Proves the executor's identity->live-path resolution on real containers without committing to a long run.
function testApply(n)
  if not tree then return "scan first" end
  if applying then return "busy" end
  n = tonumber(n) or 20
  local list, rep = BagPlan.fullPlan(tree, bucketFor, PLAN_ROUNDS, planOpts())
  local short = {}
  for i = 1, math.min(n, #list) do table.insert(short, list[i]) end
  local kinds = { bag = 0, item = 0 }
  for _, m in ipairs(short) do kinds[m.kind] = kinds[m.kind] + 1 end
  applying = true
  local startedAt = g_clock.millis()
  log(string.format("test: %d of %d planned move(s) (%d bag, %d item)", #short, #list, kinds.bag, kinds.item))
  BagApply.executePlan(short, tree, {
    moveMs = MOVE_MS,
    isStopped = function() return stopRequested end,
    onStatus = function(_, moved, tot, skips, openNow)
      output:setText(string.format("test run\n\n%d / %d done%s\n\n%d bag(s) open",
        moved, tot, skips ~= "" and ("\n" .. skips) or "", openNow))
    end,
    onDone = function(sum)
      applying = false
      local txt = string.format("test: moved %d/%d in %.1fs%s", sum.moved, sum.total,
        (g_clock.millis() - startedAt) / 1000, skipText(sum))
      log(txt)
      g_resources.writeFileContents('/bridge_testapply.txt', txt)
    end,
  })
  return string.format("running %d move(s) of %d", #short, #list)
end

function scanStats()
  local st = BagScan and BagScan.stats
  if not st then return "no scan yet" end
  local txt = string.format("bags=%d opens=%d closes=%d timeouts=%d ms=%s | waiting=%s minimize=%s(%d calls) progress=%s",
    st.bags, st.opens, st.closes, st.timeouts, tostring(st.ms), tostring(st.waitMs),
    tostring(st.minimizeMs), st.minimize, tostring(st.progressMs))
  g_resources.writeFileContents('/scanstats.txt', txt)
  return txt
end

-- modules.game_bag_organizer.cacheStatus() - is the saved scan still good, and which bags changed?
function cacheStatus()
  local changed = BagCache.changed()
  local txt = string.format("dirty=%s age=%ss reason=%s changed=%s",
    tostring(BagCache.isDirty()), tostring(BagCache.age()), tostring(BagCache.lastReason),
    changed and ("[" .. table.concat(changed, " ") .. "]") or "UNKNOWN (needs a full read)")
  g_resources.writeFileContents('/bridge_cache.txt', txt)
  return txt
end

function setDebug(v)
  if BagApply then BagApply.debug = v and true or false end
  BagScanDebug = v and true or false
  print("bag organizer debug: " .. tostring(BagScanDebug))
end

function killScan() if BagScan.cancel then BagScan.cancel() end scanGen = scanGen + 1 print("scan killed") end

function toggle() if window:isVisible() then hide() else show() end end
-- Opening the window must not show the last scan: those sprites would be a picture of backpacks as they were
-- minutes ago, which reads as the truth. Blank until Scan.
local function clearViews()
  if not window then return end
  if window.leftView then window.leftView:destroyChildren() end
  if window.rightView then window.rightView:destroyChildren() end
  if window.leftSummary then window.leftSummary:setText("hit Scan to read your backpacks") end
  if window.rightSummary then window.rightSummary:setText("") end
  clearLog()
  tree, plan, planBagMoves, planRoomMoves, planDests, lastInfo = nil, nil, nil, nil, nil, nil
  if window.apply then window.apply:setEnabled(false) end
end

function show()
  if not scanning and not applying then clearViews() end
  window:show() window:raise() window:focus()
  if button then button:setOn(true) end
end
function hide() window:hide() if button then button:setOn(false) end end
function onMiniWindowClose() if button then button:setOn(false) end end

function init()
  window = g_ui.displayUI('bag_organizer')
  window:hide()
  for _, id in ipairs({ 'output', 'preview', 'apply', 'stop', 'addBucket', 'buckets',
                        'leftView', 'rightView', 'leftSummary', 'rightSummary', 'leftPane', 'rightPane',
                        'rescan', 'dropEmpties', 'keepEmpty', 'dropTarget', 'emptyInfo', 'emptyBox' }) do
    window[id] = window:recursiveGetChildById(id)
  end
  output = window.output
  if g_settings.exists('bagOrganizerW') and g_settings.exists('bagOrganizerH') then
    window:resize(math.min(math.max(g_settings.getNumber('bagOrganizerW'), MIN_W), MAX_W),
                  math.min(math.max(g_settings.getNumber('bagOrganizerH'), MIN_H), MAX_H))
  end
  setupCornerGrip()
  for _, id in ipairs({ 'bucketsSplit', 'logSplit', 'paneSplit' }) do
    window[id] = window:recursiveGetChildById(id)
  end
  setupSplitters()
  window.onGeometryChange = onResized
  button = modules.client_topmenu.addRightGameToggleButton('bagOrganizerButton', tr('Bag organizer'),
    '/images/topbuttons/sortbars', toggle, false, 1008)
  button:setOn(false)
  window.preview.onClick = function() preview(false) end
  window.rescan.onClick = function() preview(true) end
  window.dropEmpties.onClick = dropEmpties
  window.keepEmpty:setText(tostring(savedKeep()))
  for _, t in ipairs(DROP_TARGETS) do window.dropTarget:addOption(t[2]) end
  for _, t in ipairs(DROP_TARGETS) do
    if t[1] == dropTargetMode() then window.dropTarget:setCurrentOption(t[2]) end
  end
  window.dropTarget.onOptionChange = function(_, text)
    for _, t in ipairs(DROP_TARGETS) do
      if t[2] == text then g_settings.set('bagOrganizerDropTarget', t[1]) end
    end
    groundConfirmed = false
  end
  window.keepEmpty.onTextChange = function(w, text)
    local n = tonumber(text)
    if n and n >= 0 then
      g_settings.set('bagOrganizerKeepEmpty', math.floor(n))
      if tree and window.dropEmpties then
        window.dropEmpties:setEnabled(#emptyBags() - math.floor(n) > 0)
      end
    end
  end
  BagCache.attach()
  window.apply.onClick = apply
  window.stop.onClick = stop
  window.addBucket.onClick = function() editBucket({ name = "New bucket", cats = {} }, true) end
  loadConfig()
  refreshBuckets()
end

function terminate()
  BagCache.detach()
  scanGen = scanGen + 1
  if button then button:destroy() button = nil end
  if window then window:destroy() window = nil end
  window = nil
end
