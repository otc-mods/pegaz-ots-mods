-- ElfBot-style icons on the game screen. Each icon: item sprite, size S/M/L, label (none / item count /
-- text / lua), a left-click and a right-click action. Positions are fractions of the map panel (like the
-- stock bot icons); moving is only possible while the editor's Unlock mode is on, then clicks do nothing.
setDefaultTab("Tools")

local SIZES = { s = 32, m = 48, l = 64 }
local SIZE_NAMES = { {id = "s", text = "S (32)"}, {id = "m", text = "M (48)"}, {id = "l", text = "L (64)"} }
local LABEL_MODES = {
  {id = "none",  text = "no label"},
  {id = "count", text = "item count (client + server messages)"},
  {id = "probe", text = "item count, probe by using it (NOT for potions/runes)"},
  {id = "text",  text = "text"},
  {id = "lua",   text = "lua expression"},
  {id = "bless", text = "text, green/red by bless status"},
  {id = "bank",  text = "bank balance (from the banker's reply)"},
}
local PROBE_INTERVAL = 30000
local ACTIONS = {
  {id = "none",      text = "nothing"},
  {id = "use",       text = "use item"},
  {id = "useSelf",   text = "use item on yourself"},
  {id = "useTarget", text = "use item on current target"},
  {id = "crosshair", text = "crosshair (use item with...)"},
  {id = "useUnder",  text = "use item on the tile under you"},
  {id = "useAround", text = "use on a rope spot / hole / jungle grass next to you (rope, shovel, machete)"},
  {id = "equip",     text = "equip item"},
  {id = "probe",     text = "refresh item count (uses the item once - NOT for potions/runes)"},
  {id = "say",       text = "say lines (text, one per line)"},
  {id = "npc",       text = "NPC talk lines (text, one per line)"},
  {id = "toggle",    text = "toggle a bot feature"},
  {id = "rule",      text = "toggle the equip rules that use this item"},
  {id = "exiva",     text = "exiva the last person you exivaed"},
  {id = "exivaTarget", text = "exiva your current / last attacked player"},
  {id = "lua",       text = "run lua (text)"},
}
local GRID = 8
local ANCHOR_VCENTER, ANCHOR_HCENTER = 5, 6 -- corelib AnchorVerticalCenter / AnchorHorizontalCenter, not visible in the bot sandbox
local SAY_DELAY, NPC_DELAY, TOOL_RETRY_MS, TOOL_TRIES = 300, 100, 500, 10

if type(storage.icons) ~= "table" then storage.icons = { enabled = true, locked = true, list = {} } end
storage.icons.list = storage.icons.list or {}
if storage.icons.locked == nil then storage.icons.locked = true end
local cfg = storage.icons

-- starter set. A SEED_VERSION bump only ADDS starter icons that do not exist yet; icons already on screen are
-- never modified (positions, labels, actions and deletions belong to the user).
local SEED_VERSION = 17
local function starterIcons()
  local function icon(item, lmb, rmb, label, count)
    return { item = item, count = count, size = "s", lmb = lmb or { type = "none" }, rmb = rmb or { type = "none" }, label = label or { mode = "none", text = "" } }
  end
  local A = function(t, param) return { type = t, param = param } end
  local T = function(text) return { mode = "text", text = text } end
  local travel = function(dest, label) return icon(2822, A("npc", "hi\n" .. dest .. "\nyes"), nil, T(label or dest)) end
  local seeds = {
    icon(3308, A("useAround"), A("crosshair")),                                    -- machete
    icon(3003, A("useAround"), A("crosshair")),                                    -- rope
    icon(3457, A("useAround"), A("crosshair")),                                    -- shovel
    icon(3051, A("equip"), A("probe"), { mode = "probe" }),                        -- energy ring (right click = recount)
    icon(3082, A("equip"), nil, { mode = "count" }),                               -- elven amulet (charged: server count is useless, client count)
    icon(7642, A("useSelf"), A("crosshair"), { mode = "count" }),                  -- great spirit potion
    icon(3043, A("npc", "hi\ndeposit all\nyes\nbalance"), A("npc", "hi\ntrade"), { mode = "bank", text = "Bank" }, 100), -- banker: pile of 100 cc, label = balance
    icon(3101, A("exiva"), nil, T("Exiva")),                                       -- exiva last name
    icon(648, A("say", "exani hur up\nexani hur down"), nil, T("Up/Dn")),          -- levitate both ways
    icon(3264, { type = "toggle", feature = "targetbot" }, nil, T("TB")),           -- ElfBot-style toggle
    icon(6561, A("say", "!bless"), nil, { mode = "bless", text = "Bless" }),        -- ceremonial ankh, green/red by bless status
    travel("averain", "Averain"),
    travel("hell city", "Hell City"),
    travel("exodar", "Exodar"),
    travel("future exodar", "F.Exodar"),
    travel("darnassus", "Darnassus"),
    travel("broken", "Broken"),
    travel("yalahar", "Yalahar"),
    travel("majsteria", "Majsteria"),
    travel("asgard", "Asgard"),
    travel("supilamia", "Supilamia"),
    -- new starter icons go at the END only: ids are positional and existing ones must not shift
    icon(3031, A("npc", "hi\ntrade"), nil, T("Trade")),                          -- open NPC trade
    icon(3081, A("equip"), nil, { mode = "count" }),                               -- stone skin amulet, like the elven amulet
    icon(3048, A("equip"), A("probe"), { mode = "probe" }),                        -- might ring, like the energy ring
    travel("vulcanic island", "Vulcanic"),
    travel("passage", "Passage"),
    icon(3076, A("exivaTarget"), nil, T("Ex.Tgt")),                                -- crystal ball: exiva your target
  }
  -- Where each starter icon goes. The old grid dropped them across the middle of the map; this is the layout
  -- that survived actual use: tools and equipment down the right edge, travel down the left.
  local HOME = {
    [1] = {0.992, 0.622}, [2] = {0.992, 0.677}, [3] = {0.992, 0.733}, [4] = {0.992, 0.306},
    [5] = {0.992, 0.232}, [6] = {0.992, 0.854}, [7] = {0.012, 0.915}, [8] = {0.992, 0.380},
    [9] = {0.992, 0.525}, [10] = {0.992, 0.960}, [11] = {0.992, 0.009}, [12] = {0.012, 0.111},
    [13] = {0.012, 0.744}, [14] = {0.012, 0.575}, [15] = {0.012, 0.631}, [16] = {0.012, 0.688},
    [17] = {0.012, 0.176}, [18] = {0.012, 0.436}, [19] = {0.012, 0.241}, [20] = {0.012, 0.371},
    [21] = {0.012, 0.306}, [22] = {0.012, 0.981}, [23] = {0.992, 0.102}, [24] = {0.992, 0.167},
    [25] = {0.012, 0.499}, [26] = {0.012, 0.820}, [27] = {0.992, 0.443},
  }
  for i, ic in ipairs(seeds) do
    ic.id = "seed" .. i
    local home = HOME[i]
    if home then
      ic.x, ic.y = home[1], home[2]
    else                                   -- anything added later: continue down the right edge
      ic.x = 0.992
      ic.y = 0.05 + ((i - #seeds) % 16) * 0.056
    end
  end

  -- Supplies for this vocation come from /vocation.lua. x is a fraction of the MAP view, not the screen, so
  -- anything below ~0.99 lands on top of the game world - they belong in the same right-hand column as the
  -- icons above, stacked downwards from the first free slot.
  local SUPPLY_X, SUPPLY_TOP, SUPPLY_STEP = 0.992, 0.790, 0.056
  local taken = {}                       -- items you already have an icon for: no duplicates
  for _, ic in ipairs(cfg.list or {}) do taken[ic.item] = true end
  local slot = 0
  for i, v in ipairs(type(VOCATION_ICONS) == "table" and VOCATION_ICONS or {}) do
    if not taken[v.item] then
      local lmb = v.lmb == "crosshair" and A("crosshair") or A("useSelf")
      local ic = icon(v.item, lmb, A("crosshair"), { mode = "count" })
      ic.id = "sup" .. i
      ic.x = SUPPLY_X
      ic.y = SUPPLY_TOP + slot * SUPPLY_STEP
      slot = slot + 1
      table.insert(seeds, ic)
    end
  end
  return seeds
end
-- drop the misplaced vocation icons (both attempts) before seeding: "voc1..." landed mid-screen, "sup1..."
-- landed on the map because x is relative to the map view, not the window
for i = #cfg.list, 1, -1 do
  local id = cfg.list[i] and cfg.list[i].id
  if type(id) == "string" and (id:match("^voc%d+$") or id:match("^sup%d+$")) then table.remove(cfg.list, i) end
end

-- presets seeded before the layout existed sit on the old grid: put those back where they belong, but never
-- touch an icon the player has dragged somewhere of their own
local function onOldGrid(ic, i)
  local gx = 0.02 + math.floor((i - 1) / 7) * 0.07
  local gy = 0.05 + ((i - 1) % 7) * 0.09
  return math.abs((ic.x or 0) - gx) < 0.005 and math.abs((ic.y or 0) - gy) < 0.005
end

if cfg.seedVersion ~= SEED_VERSION then
  cfg.removedSeeds = cfg.removedSeeds or {}
  local existing = {}
  for _, ic in ipairs(cfg.list) do existing[ic.id] = true end
  local canonical = {}
  for _, seed in ipairs(starterIcons()) do
    canonical[seed.id] = { seed.x, seed.y }
    if not existing[seed.id] and not cfg.removedSeeds[seed.id] then table.insert(cfg.list, seed) end
  end
  -- a preset seeded before the layout existed has its icons across the map: move exactly those
  for _, ic in ipairs(cfg.list) do
    local n = tonumber(tostring(ic.id):match("^seed(%d+)$"))
    if n and canonical[ic.id] and onOldGrid(ic, n) then
      ic.x, ic.y = canonical[ic.id][1], canonical[ic.id][2]
    end
  end
  cfg.seedVersion = SEED_VERSION
  cfg.seeded = true
end

-- one-time repair (2026-09-07): earlier starter-set rebuilds overwrote the user's labels with lowercase defaults
if cfg.labelRepair ~= 1 then
  local wanted = { ["exiva"] = "Exiva", ["up/dn"] = "Up/Dn", ["bank"] = "Bank" }
  for _, ic in ipairs(cfg.list) do
    if ic.label and ic.label.text and wanted[ic.label.text] then ic.label.text = wanted[ic.label.text] end
  end
  cfg.labelRepair = 1
end

-- 2026-09-07: a wrong repair briefly pointed the amulet icon at 2854 (a backpack id) - undo it, and use the
-- client count for the amulet: charged items answer "Using the last ..." per charge state, so the probe is useless
if cfg.amuletRepair ~= 2 then
  for _, ic in ipairs(cfg.list) do
    if ic.item == 2854 then ic.item = 3082 end
    if ic.item == 3082 and ic.label and ic.label.mode == "probe" then ic.label.mode = "count" end
  end
  if storage.equipWornIds then storage.equipWornIds["2854"] = nil end
  cfg.amuletRepair = 2
end

local widgets = {}     -- icon.id -> widget
local probeNow         -- function(itemId), defined with the count code below
local lastExiva = nil
local editorWindow

local function byId(list, id) for _, e in ipairs(list) do if e.id == id then return e end end return list[1] end

-- helpers -------------------------------------------------------------------------------
local function subTypeFor(itemId)
  local tt = g_things.getThingType(itemId)
  if tt and tt:isFluidContainer() then return -1 end
  return g_game.getClientVersion() >= 860 and 0 or 1
end

-- equipment + OPEN containers (the client knows nothing about closed backpacks); a worn ring counts under
-- its worn id (storage.equipWornIds, learned by the Equip feature)
local function countItems(itemId)
  local worn = storage.equipWornIds and storage.equipWornIds[tostring(itemId)]
  local n = 0
  for slot = 1, 10 do
    local it = getInventoryItem(slot)
    if it and (it:getId() == itemId or it:getId() == worn) then n = n + it:getCount() end
  end
  for _, container in pairs(g_game.getContainers()) do
    for _, it in ipairs(container:getItems()) do
      if it:getId() == itemId then n = n + it:getCount() end
    end
  end
  return n
end

local function lines(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n|]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line:len() > 0 then table.insert(out, line) end
  end
  return out
end

local function echoNpc(line)
  pcall(function()
    local console = modules.game_console
    console.addTabText(player:getName() .. " (to NPC): " .. line, console.SpeakTypesSettings.privatePlayerToNpc, console.getCurrentTab())
  end)
end

local function sayLines(list, delay, npc)
  for i, line in ipairs(list) do
    schedule((i - 1) * delay, function()
      if npc then sayNpc(line); echoNpc(line) else say(line) end
    end)
  end
end

-- tools: the server only reacts to specific spots, so find one next to you and use the tool on exactly that thing.
-- Ids are 8.60 client ids taken from a TFS items.otb (rope/shovel handlers check the tile GROUND, so a corpse or
-- a field lying on the spot does not matter; the machete needs the grass item itself).
local TOOL_TARGETS = {
  [3003] = { what = "rope spot",     ground = true,  ids = {386, 421, 7762} },
  [3457] = { what = "hole to dig",   ground = true,  ids = {593, 606, 608, 867} },
  [3308] = { what = "jungle grass",  ground = false, ids = {3695, 3696, 3701, 3702, 2130, 10182} },
}
-- the tile you face first, then the one under you, then the rest
local FACING = { [0] = {0,-1}, [1] = {1,0}, [2] = {0,1}, [3] = {-1,0}, [4] = {1,-1}, [5] = {1,1}, [6] = {-1,1}, [7] = {-1,-1} }
local function tilesAround()
  local ppos = player:getPosition()
  local order, seen = {}, {}
  local function add(dx, dy)
    local key = dx .. "," .. dy
    if seen[key] then return end
    seen[key] = true
    table.insert(order, g_map.getTile({x = ppos.x + dx, y = ppos.y + dy, z = ppos.z}))
  end
  local f = FACING[player:getDirection()] or {0,-1}
  add(f[1], f[2])
  add(0, 0)
  for _, d in ipairs({{0,-1},{1,0},{0,1},{-1,0},{1,-1},{1,1},{-1,1},{-1,-1}}) do add(d[1], d[2]) end
  return order
end

local function findToolTarget(spec)
  local wanted = {}
  for _, id in ipairs(spec.ids) do wanted[id] = true end
  for _, tile in ipairs(tilesAround()) do
    if tile then
      if spec.ground then
        local g = tile:getGround()
        if g and wanted[g:getId()] then return g end
      else
        for _, it in ipairs(tile:getItems()) do
          if wanted[it:getId()] then return it end
        end
      end
    end
  end
end

local function useAround(itemId)
  local spec = TOOL_TARGETS[itemId]
  local sub = subTypeFor(itemId)
  if not spec then -- unknown tool: single use on the tile you face
    local tile = tilesAround()[1]
    local thing = tile and tile:getTopUseThing()
    if not thing then return end
    return g_game.useInventoryItemWith(itemId, thing, sub)
  end
  local target = findToolTarget(spec)
  if not target then return end -- no spot next to you: nothing happens
  local tpos, tid, start = target:getPosition(), target:getId(), player:getPosition()
  local tries = 0
  local function attempt()
    tries = tries + 1
    g_game.useInventoryItemWith(itemId, target, sub)
    if tries >= TOOL_TRIES then return end
    schedule(TOOL_RETRY_MS, function()
      local now = player:getPosition()
      if now.x ~= start.x or now.y ~= start.y or now.z ~= start.z then return end -- rope worked / we moved
      local tile = g_map.getTile(tpos)
      if not tile then return end
      local still
      if spec.ground then
        still = tile:getGround() and tile:getGround():getId() == tid
      else
        still = false
        for _, it in ipairs(tile:getItems()) do if it:getId() == tid then still = true target = it end end
      end
      if not still then return end -- dug / cut: the spot changed
      if spec.ground then target = tile:getGround() end
      attempt()
    end)
  end
  attempt()
end

-- counts learned from the server: "Using one of 162 energy rings..." / "Using the last energy ring..."
-- (sent for every hotkey-style use, i.e. every potion the bot drinks and every probe)
local serverCounts = {}     -- item id -> { n = count, t = now, stale = true if carried over from the last session }
cfg.counts = cfg.counts or {} -- last server-confirmed counts, survive relogs (shown with "~" until confirmed again)
for id, n in pairs(cfg.counts) do
  if tonumber(id) and tonumber(n) then serverCounts[tonumber(id)] = { n = tonumber(n), t = 0, stale = true } end
end
local function setServerCount(id, n)
  serverCounts[id] = { n = n, t = now }
  cfg.counts[tostring(id)] = n
end
local learnedNames = {}     -- plural/singular name -> item id, learned from our own probes
local pendingProbe = nil    -- { id = , due = } while a probe reply is expected
local probeAt = {}          -- icon id -> next probe time

local learnedNamesById = {}  -- item id -> name as the server spells it (from probes)
local nameIndex              -- lower-case item name -> id, built once from the autoloot name table
local nameToIdCache = {}     -- queried name -> id / false
local probeMismatch = {}     -- item id -> foreign name seen on its last probe (accepted if it repeats)

-- does the server's (plural) name belong to this item? nil = unknown item, cannot tell
local function nameMatches(reported, itemId)
  local names = modules.game_autoloot and modules.game_autoloot.AutolootNames
  local known = learnedNamesById[itemId] or (names and names[itemId])
  if not known then return nil end
  local r, k = reported:lower(), known:lower()
  return r == k or r == k .. "s" or r == k .. "es" or r:gsub("s$", "") == k or r:gsub("es$", "") == k or r:gsub("ies$", "y") == k
end

-- items whose count we learn from real uses (bot potions, count-labelled icons)
local function passivelyTracked(itemId)
  for _, key in ipairs({"hpitem1", "hpitem2", "manaitem1", "manaitem2"}) do
    local p = storage[key]
    if type(p) == "table" and p.item == itemId then return true end
  end
  for _, ic in ipairs(cfg.list) do
    if ic.item == itemId and ic.label and ic.label.mode == "count" then return true end
  end
  return false
end

local function nameToId(name)
  name = name:lower()
  if learnedNames[name] then return learnedNames[name] end
  local hit = nameToIdCache[name]
  if hit ~= nil then return hit or nil end -- false = known miss
  if not nameIndex then                    -- 8800+ names: index them once instead of scanning per message
    local names = modules.game_autoloot and modules.game_autoloot.AutolootNames
    if not names then return nil end
    nameIndex = {}
    for id, n in pairs(names) do
      local low = n:lower()
      if not nameIndex[low] then nameIndex[low] = id end
    end
  end
  local id = nameIndex[name] or nameIndex[(name:gsub("s$", ""))] or nameIndex[(name:gsub("es$", ""))]
    or nameIndex[(name:gsub("ies$", "y"))] or nameIndex[(name:gsub("ves$", "fe"))]
  nameToIdCache[name] = id or false
  return id
end

onTextMessage(function(mode, text)
  if type(text) ~= "string" then return end
  local count, name = text:match("^Using one of (%d+) (.+)%.%.%.$")
  if not count then
    name = text:match("^Using the last (.+)%.%.%.$")
    if name then count = 1 end
  end
  if not name then return end
  count = tonumber(count)
  -- a pending probe owns this line unless the name clearly belongs to another item: one the icons track passively
  -- (potions the bot drinks), or any known 8.60 item while the probed item's own name is known and different.
  -- Pegaz may rename items on reused ids, so the same "foreign" name on two consecutive probes is accepted as ours.
  local other = nameToId(name)
  local stolen = false
  if pendingProbe and other and other ~= pendingProbe.id then
    local mine = nameMatches(name, pendingProbe.id) -- true / false / nil = no name known for the probed item
    if passivelyTracked(other) and mine ~= true then
      stolen = true
    elseif mine == false then
      local m = probeMismatch[pendingProbe.id]
      if m == name:lower() then probeMismatch[pendingProbe.id] = nil else probeMismatch[pendingProbe.id] = name:lower() stolen = true end
    end
  end
  if pendingProbe and pendingProbe.due > now and not stolen then
    local id = pendingProbe.id                         -- the probe's own answer: nothing was consumed
    learnedNames[name:lower()] = id
    learnedNamesById[id] = name
    pendingProbe = nil
    -- charged items: the server counts only pieces in the same charge state. A half-used ring (worn, or put
    -- back on top of the bag by a take-off) answers "the last" although the bag is full, so "the last" never
    -- lowers a bigger known count - the running count (minus one per equip, plus one per take-off) stays.
    local sc = serverCounts[id]
    if not (count == 1 and sc and sc.n > 1) then setServerCount(id, count) end
    return
  end
  local id = nameToId(name)                            -- somebody's real use (bot potion, icon click): one consumed
  if id then setServerCount(id, math.max(0, count - 1)) end
end)

probeNow = function(itemId)
  if not itemId or itemId <= 100 then return end
  pendingProbe = { id = itemId, due = now + 1500 }
  g_game.useInventoryItem(itemId)
end

-- running count: every landed equip consumes one spare; the Equip feature's occasional pre-equip probe resyncs it
Hunt.onEquipped(function(itemId)
  local sc = serverCounts[itemId]
  if sc then setServerCount(itemId, math.max(0, sc.n - 1)) end -- one spare left the bag
end)
Hunt.onUnequipped(function(itemId)
  local sc = serverCounts[itemId]
  if sc then setServerCount(itemId, sc.n + 1) end -- the piece came back to the bag
end)
Hunt.onEquipProbe(function(itemId)
  pendingProbe = { id = itemId, due = now + 1500 }
end)
local function registerTrackedItems()
  for _, ic in ipairs(cfg.list) do
    if ic.item and ic.item > 100 and ic.label and (ic.label.mode == "count" or ic.label.mode == "probe") then
      Hunt.wantEquipProbe(ic.item, true)
    end
  end
end
registerTrackedItems()

local function knownCount(itemId)
  local client = countItems(itemId) -- exact while the bag is open, never too high
  local sc = serverCounts[itemId]
  if sc and client > sc.n then setServerCount(itemId, client); sc = serverCounts[itemId] end
  if sc then return (sc.stale and "~" or "") .. sc.n end
  return tostring(client)
end

-- bank balance: parsed from whatever the banker answers after "deposit all" / "balance"
local BALANCE_PATTERNS = { "balance is (%d+)", "balance of (%d+)", "saldo[^%d]*(%d+)", "wynosi (%d+)", "masz (%d+) gold", "have (%d+) gold" }
local function fmtGold(n)
  if n >= 1000000 then return string.format("%.2fkk", n / 1000000):gsub("%.?0+kk$", "kk") end
  if n >= 1000 then return string.format("%.1fk", n / 1000):gsub("%.0k$", "k") end
  return tostring(n)
end

onTalk(function(name, level, mode, text)
  if name ~= player:getName() and type(text) == "string" then
    local lower = text:lower()
    for _, pat in ipairs(BALANCE_PATTERNS) do
      local n = lower:match(pat)
      if n then cfg.bankBalance = tonumber(n); cfg.bankBalanceAt = os.time() break end
    end
  end
  if name == player:getName() then
    local who = text:match('^exiva%s+"?([^"]+)"?%s*$')
    if who then lastExiva = who end
  end
end)

-- equip rules (features/equip.lua, storage.equipRules) whose item is this icon's item, bag id or worn id
local function equipRulesFor(item)
  local out = {}
  for _, r in ipairs(storage.equipRules or {}) do
    if r.item == item or r.worn == item or (storage.equipWornIds or {})[tostring(r.item)] == item then table.insert(out, r) end
  end
  return out
end

local function anyRuleOn(rs)
  for _, r in ipairs(rs) do if r.on then return true end end
  return false
end

local function run(icon, action)
  if not action or action.type == "none" then return end
  local t, item = action.type, icon.item or 0
  if t == "use" then g_game.useInventoryItem(item)
  elseif t == "useSelf" then g_game.useInventoryItemWith(item, player, subTypeFor(item))
  elseif t == "useTarget" then
    local target = g_game.getAttackingCreature()
    if not target then return end
    g_game.useInventoryItemWith(item, target, subTypeFor(item))
  elseif t == "crosshair" then modules.game_interface.startUseWith(Item.create(item), -1)
  elseif t == "useUnder" then
    local tile = g_map.getTile(player:getPosition())
    local thing = tile and tile:getTopUseThing()
    if thing then g_game.useInventoryItemWith(item, thing, subTypeFor(item)) end
  elseif t == "useAround" then useAround(item)
  elseif t == "equip" then g_game.equipItemId(item)
  elseif t == "probe" then probeNow(item)
  elseif t == "say" then sayLines(lines(action.param), SAY_DELAY, false)
  elseif t == "npc" then sayLines(lines(action.param), NPC_DELAY, true)
  elseif t == "toggle" then
    if action.feature and Features.byId[action.feature] then Features.setOn(action.feature, not Features.isOn(action.feature)) end
  elseif t == "rule" then
    local rs = equipRulesFor(item)
    if #rs == 0 then return end -- no rule for this item: the border colour says so, no chat spam
    local on = not anyRuleOn(rs)
    for _, r in ipairs(rs) do r.on = on end
  elseif t == "exiva" then
    if lastExiva then say('exiva "' .. lastExiva .. '"') end
  elseif t == "exivaTarget" then
    local c = g_game.getAttackingCreature()
    local who = (c and c:isPlayer() and (c.playerInfoName or c:getName())) or Hunt.lastTargetName
    if who then lastExiva = who say('exiva "' .. who .. '"') end
  elseif t == "lua" then
    local ok, err = pcall(function() load(action.param or "")() end)
    if not ok then warn("icons: lua error: " .. tostring(err)) end
  end
end

-- icon widgets -----------------------------------------------------------------------------
local function place(widget, icon)
  local parent = widget:getParent()
  local rect = parent:getRect()
  local width = rect.width - widget:getWidth()
  local height = rect.height - widget:getHeight()
  widget:setMarginTop(math.max(height * (-0.5) - parent:getMarginTop(), height * (-0.5 + icon.y)))
  widget:setMarginLeft(width * (-0.5 + icon.x))
end

local function createIcon(icon)
  local panel = modules.game_interface.gameMapPanel
  local w = g_ui.createWidget('RpIcon', panel)
  w.botWidget = true
  local px = SIZES[icon.size or "m"] or 48
  w:setSize({width = px, height = px + 14})
  w.item:setSize({width = px, height = px})
  w.item:setItemId(icon.item or 0)
  if icon.count and icon.count > 1 then
    w.item:setItemCount(icon.count)
    w.item:setShowCount(false)
  end
  w:addAnchor(ANCHOR_HCENTER, 'parent', ANCHOR_HCENTER)
  w:addAnchor(ANCHOR_VCENTER, 'parent', ANCHOR_VCENTER)
  icon.x = icon.x or 0.05
  icon.y = icon.y or 0.1
  w.onGeometryChange = function(widget) if not widget:isDragging() then place(widget, icon) end end
  place(w, icon)

  w:setDraggable(not cfg.locked)
  w.onDragEnter = function(widget, mousePos)
    if cfg.locked then return false end
    widget:breakAnchors()
    widget.moveRef = { x = mousePos.x - widget:getX(), y = mousePos.y - widget:getY() }
    return true
  end
  w.onDragMove = function(widget, mousePos)
    local pr = widget:getParent():getRect()
    local x = math.min(math.max(pr.x, mousePos.x - widget.moveRef.x), pr.x + pr.width - widget:getWidth())
    local y = math.min(math.max(pr.y, mousePos.y - widget.moveRef.y), pr.y + pr.height - widget:getHeight())
    widget:move(x - (x - pr.x) % GRID, y - (y - pr.y) % GRID)
    return true
  end
  w.onDragLeave = function(widget)
    local parent = widget:getParent()
    local pr = parent:getRect()
    local width = pr.width - widget:getWidth()
    local height = pr.height - widget:getHeight()
    icon.x = math.min(1, math.max(0, (widget:getX() - pr.x) / math.max(1, width)))
    icon.y = math.min(1, math.max(0, (widget:getY() - pr.y) / math.max(1, height)))
    widget:addAnchor(ANCHOR_HCENTER, 'parent', ANCHOR_HCENTER)
    widget:addAnchor(ANCHOR_VCENTER, 'parent', ANCHOR_VCENTER)
    place(widget, icon)
    return true
  end
  w.onMouseRelease = function(widget, mousePos, mouseButton)
    if not cfg.locked then return true end
    if mouseButton == 1 then run(icon, icon.lmb) elseif mouseButton == 2 then run(icon, icon.rmb) end
    return true
  end
  widgets[icon.id] = w
  return w
end

local function destroyAll()
  for id, w in pairs(widgets) do w:destroy() end
  widgets = {}
end

local function rebuild()
  destroyAll()
  registerTrackedItems()
  if not cfg.enabled then return end
  for _, icon in ipairs(cfg.list) do createIcon(icon) end
end

local function refreshLabels()
  for _, icon in ipairs(cfg.list) do
    local w = widgets[icon.id]
    if w then
      local mode = icon.label and icon.label.mode or "none"
      local text = ""
      if mode == "count" then text = knownCount(icon.item or 0)
      elseif mode == "probe" then
        text = knownCount(icon.item or 0)
        if pendingProbe and pendingProbe.due <= now then pendingProbe = nil end -- unanswered probe must not block the others
        if cfg.locked and (probeAt[icon.id] or 0) <= now and not pendingProbe and icon.item and icon.item > 100 then
          probeAt[icon.id] = now + PROBE_INTERVAL + math.random(0, 2000)
          pendingProbe = { id = icon.item, due = now + 1500 }
          g_game.useInventoryItem(icon.item)
        end
      elseif mode == "text" then text = icon.label.text or ""
      elseif mode == "bank" then text = cfg.bankBalance and fmtGold(cfg.bankBalance) or (icon.label.text or "Bank")
      elseif mode == "bless" then
        text = icon.label.text or "Bless"
        w.label:setColor(Hunt.blessed == true and '#00ee00' or (Hunt.blessed == false and '#ff4444' or '#ffffff'))
      elseif mode == "lua" then
        local ok, v = pcall(function() return load("return " .. (icon.label.text or "''"))() end)
        text = ok and tostring(v) or "err"
      end
      if mode ~= "bless" then w.label:setColor('#ffffff') end
      w.label:setText(text)
      local toggled = (icon.lmb and icon.lmb.type == "toggle" and icon.lmb.feature) or (icon.rmb and icon.rmb.type == "toggle" and icon.rmb.feature)
      local ruleToggle = (icon.lmb and icon.lmb.type == "rule") or (icon.rmb and icon.rmb.type == "rule")
      if toggled then
        w:setBorderColor(Features.isOn(toggled) and '#00cc00' or '#cc0000')
      elseif ruleToggle then
        w:setBorderColor(anyRuleOn(equipRulesFor(icon.item)) and '#00cc00' or '#cc0000')
      elseif not cfg.locked then
        w:setBorderColor('#ffdd55')
      else
        w:setBorderColor('alpha')
      end
    end
  end
end

macro(500, function() if cfg.enabled then refreshLabels() end end)

Features.register{ id = "icons", name = "Icons", group = "Other",
  isOn = function() return cfg.enabled end,
  setOn = function(v) cfg.enabled = v; rebuild() end }

-- editor ---------------------------------------------------------------------------------
local refreshEditor

local function actionSummary(a)
  if not a or a.type == "none" then return "-" end
  local s = byId(ACTIONS, a.type).text:gsub(" %(.*", "")
  if a.type == "toggle" and a.feature then s = s .. " " .. (Features.byId[a.feature] and Features.byId[a.feature].name or a.feature) end
  return s
end

local function editIcon(icon, isNew)
  local w = UI.createWindow('RpIconForm')
  local draft = {
    item = icon.item or 0, size = icon.size or "m", count = icon.count or 1,
    label = { mode = icon.label and icon.label.mode or "none", text = icon.label and icon.label.text or "" },
    lmb = { type = icon.lmb and icon.lmb.type or "none", param = icon.lmb and icon.lmb.param or "", feature = icon.lmb and icon.lmb.feature },
    rmb = { type = icon.rmb and icon.rmb.type or "none", param = icon.rmb and icon.rmb.param or "", feature = icon.rmb and icon.rmb.feature },
  }

  local itemRow = UI.createWidget('EquipRuleEditorItemRow', w.content)
  itemRow.text:setText("Item")
  itemRow.item:setItemId(draft.item)
  itemRow.item.onItemChange = function() draft.item = itemRow.item:getItemId() end

  local function comboRow(label, options, current, onChange)
    local row = UI.createWidget('RpFormComboRow', w.content)
    row.text:setText(label)
    for i, o in ipairs(options) do
      row.combo:addOption(o.text, o.id)
      if o.id == current then row.combo:setCurrentIndex(i) end
    end
    row.combo.onOptionChange = function(widget, text, data) onChange(data) end
    return row
  end

  local function textRow(label, holder, key, title)
    local row = UI.createWidget('RpFormButtonRow', w.content)
    row.text:setText(label)
    local function refresh() local v = holder[key] or ""; row.button:setText(v:len() > 0 and v:gsub("[\r\n]+", " | "):sub(1, 40) or "(edit...)") end
    row.button.onClick = function()
      UI.MultilineEditorWindow(holder[key] or "", {title = title}, function(text) holder[key] = text; refresh() end)
    end
    refresh()
    return row
  end

  comboRow("Size", SIZE_NAMES, draft.size, function(v) draft.size = v end)
  -- stackable sprites only change at these counts, so these are all the distinct piles
  local stackOptions = {}
  for _, n in ipairs({1, 2, 3, 4, 5, 10, 25, 50, 100}) do table.insert(stackOptions, {id = n, text = tostring(n)}) end
  comboRow("Stack", stackOptions, draft.count, function(v) draft.count = tonumber(v) or 1 end)
  local labelText
  comboRow("Label", LABEL_MODES, draft.label.mode, function(v) draft.label.mode = v; labelText:setVisible(v == "text" or v == "lua" or v == "bless") end)
  labelText = textRow("Label text", draft.label, "text", "Label text (lua mode: expression, e.g. countItems(3031))")
  labelText:setVisible(draft.label.mode == "text" or draft.label.mode == "lua" or draft.label.mode == "bless")

  local featureOptions = {}
  for _, f in ipairs(Features.list) do table.insert(featureOptions, {id = f.id, text = f.name}) end
  if #featureOptions == 0 then featureOptions = {{id = "", text = "-"}} end

  local function actionRows(label, holder)
    local paramRow, featureRow
    comboRow(label, ACTIONS, holder.type, function(v)
      holder.type = v
      paramRow:setVisible(v == "say" or v == "npc" or v == "lua")
      featureRow:setVisible(v == "toggle")
    end)
    paramRow = textRow(label .. " text", holder, "param", label .. ": lines (say / NPC) or lua code")
    featureRow = comboRow(label .. " feature", featureOptions, holder.feature or featureOptions[1].id, function(v) holder.feature = v end)
    paramRow:setVisible(holder.type == "say" or holder.type == "npc" or holder.type == "lua")
    featureRow:setVisible(holder.type == "toggle")
    if holder.type == "toggle" and not holder.feature then holder.feature = featureOptions[1].id end
  end
  actionRows("Left click", draft.lmb)
  actionRows("Right click", draft.rmb)

  w.cancel.onClick = function() w:destroy() end
  w.onEscape = w.cancel.onClick
  w.ok.onClick = function()
    if draft.item <= 100 then return warn("icons: pick an item first") end
    icon.item, icon.size, icon.label, icon.lmb, icon.rmb = draft.item, draft.size, draft.label, draft.lmb, draft.rmb
    icon.count = (draft.count and draft.count > 1) and draft.count or nil
    if draft.lmb.type == "toggle" and not draft.lmb.feature then draft.lmb.feature = featureOptions[1].id end
    if draft.rmb.type == "toggle" and not draft.rmb.feature then draft.rmb.feature = featureOptions[1].id end
    if isNew then
      icon.id = tostring(os.time()) .. "_" .. math.random(1000, 9999)
      table.insert(cfg.list, icon)
    end
    w:destroy()
    rebuild()
    refreshEditor()
  end
end

refreshEditor = function()
  if not editorWindow then return end
  editorWindow.content:destroyChildren()
  for i, icon in ipairs(cfg.list) do
    local row = UI.createWidget('RpIconRow', editorWindow.content)
    row.item:setItemId(icon.item or 0)
    row.item.onItemChange = function() icon.item = row.item:getItemId(); rebuild() end
    row.text:setText("L: " .. actionSummary(icon.lmb) .. "\nR: " .. actionSummary(icon.rmb))
    row.edit.onClick = function() editIcon(icon, false) end
    row.remove.onClick = function()
      if tostring(icon.id):find("^seed") then
        cfg.removedSeeds = cfg.removedSeeds or {}
        cfg.removedSeeds[icon.id] = true
      end
      table.remove(cfg.list, i)
      rebuild()
      refreshEditor()
    end
  end
  editorWindow.lock:setText(cfg.locked and "Unlock: drag" or "Lock: click")
  editorWindow.lock:setColor(cfg.locked and '#dfdfdf' or '#ffdd55')
  editorWindow:setHeight(70 + math.min(10, math.max(1, #cfg.list)) * 38) -- at most 10 rows tall, the rest scrolls
end

local function openEditor()
  if editorWindow then editorWindow:raise() return end
  editorWindow = UI.createWindow('RpIconEditor')
  editorWindow.add.onClick = function() editIcon({}, true) end
  editorWindow.lock.onClick = function()
    cfg.locked = not cfg.locked
    for _, w in pairs(widgets) do w:setDraggable(not cfg.locked) end
    refreshEditor()
    refreshLabels()
  end
  editorWindow.closeButton.onClick = function()
    if not cfg.locked then cfg.locked = true; for _, w in pairs(widgets) do w:setDraggable(false) end end
    editorWindow:destroy()
    editorWindow = nil
  end
  editorWindow.onEscape = editorWindow.closeButton.onClick
  refreshEditor()
end

panel = UI.section("toolsEditors", "Editors", panel)   -- same section as the macro/hotkey editors
UI.Button("Icons editor...", openEditor)

rebuild()
