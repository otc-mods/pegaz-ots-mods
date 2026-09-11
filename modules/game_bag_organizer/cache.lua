-- Persisted scan. Reading 400 backpacks costs 86 s of server round-trips, and nothing in them changes unless
-- somebody moves something - which always happens through an OPEN container, and open containers raise events.
-- So the tree is written to disk and reused until an event says otherwise.
BagCache = {}

local FILE = '/bagorg_scan.txt'
-- Starts CLEAN: a module reload does not move anybody's backpacks, and the saved file carries a wall-clock
-- stamp so its age is honest across reloads. Container events are what make it dirty.
local dirty, loadedFor, stamp = false, nil, 0
local dirtyPaths = {}        -- the bags known to have changed; dirty with none listed means "read everything"
local idToPath = {}          -- live container id -> path, learned by watching what gets opened
local pendingOpen = nil      -- the path the next onOpen belongs to

local function keyFor()
  local p = g_game.getLocalPlayer()
  return (p and p:getName() or "?") .. "@" .. tostring(g_game.getWorldName and g_game.getWorldName() or "")
end

function BagCache.markDirty(why, path)
  dirty = true
  BagCache.lastReason = why
  if path then
    dirtyPaths[path] = true
  else
    dirtyPaths = {}          -- unidentified change: nothing short of a full read is trustworthy
    BagCache.blind = true
  end
end

function BagCache.isDirty() return dirty end

-- The bags worth re-reading, or nil when a change could not be pinned down.
function BagCache.changed()
  if BagCache.blind then return nil end
  local list = {}
  for path in pairs(dirtyPaths) do table.insert(list, path) end
  return list
end

function BagCache.clearChanges()
  dirtyPaths = {}
  BagCache.blind = false
end

-- Which bag is this container? An item inside a container reports its position as
-- { x = 65535, y = 64 + parent container id, z = slot }, so wrapping g_game.open tells us that the bag being
-- opened is "<parent's path>/<slot>". The parentless container is always the main backpack.
function BagCache.pathOfContainer(c)
  if not c then return nil end
  if not c:hasParent() then return "" end
  return idToPath[c:getId()]
end

-- The main backpack may have been open since before this module loaded, so no onOpen ever told us its id.
-- It is recognisable at any time: it is the container without a parent.
local function pathOfId(id)
  if idToPath[id] then return idToPath[id] end
  for _, c in pairs(g_game.getContainers()) do
    if c:getId() == id and not c:hasParent() then idToPath[id] = "" return "" end
  end
  return nil
end

function BagCache.watchOpens()
  if BagCache.openWrapped then return end
  BagCache.openWrapped = true
  local orig = g_game.open
  g_game.open = function(item, previous)
    pendingOpen = nil
    if item then
      local ok, pos = pcall(function() return item:getPosition() end)
      if ok and pos and pos.x == 65535 then
        local parentId, slot = pos.y - 64, pos.z
        local parentPath = pathOfId(parentId)
        if parentPath ~= nil then pendingOpen = parentPath .. "/" .. slot end
      end
    end
    return orig(item, previous)
  end
end

function BagCache.noteOpened(c)
  if not c then return end
  if not c:hasParent() then idToPath[c:getId()] = "" return end
  if pendingOpen then
    idToPath[c:getId()] = pendingOpen
    pendingOpen = nil
  else
    -- container ids get reused; without a path for this one, drop any stale mapping rather than trust it
    idToPath[c:getId()] = nil
  end
end

function BagCache.noteScan(id, path) idToPath[id] = path end
function BagCache.age() return stamp > 0 and math.max(0, os.time() - stamp) or nil end

function BagCache.attach()
  if BagCache.conn then return end
  BagCache.conn = {
    onOpen = function(c) BagCache.noteOpened(c) end,
    onAddItem = function(c) BagCache.markDirty("an item appeared in a bag", BagCache.pathOfContainer(c)) end,
    onRemoveItem = function(c) BagCache.markDirty("an item left a bag", BagCache.pathOfContainer(c)) end,
    onUpdateItem = function(c) BagCache.markDirty("an item changed in a bag", BagCache.pathOfContainer(c)) end,
    onSizeChange = function(c) BagCache.markDirty("a bag changed size", BagCache.pathOfContainer(c)) end,
  }
  connect(Container, BagCache.conn)
  BagCache.watchOpens()
end

function BagCache.detach()
  if BagCache.conn then disconnect(Container, BagCache.conn) BagCache.conn = nil end
end

-- one line per bag:  path|cap|id|entry,entry,...   entry = i:id:count  or  b:sub:id
function BagCache.save(tree)
  local paths = {}
  for path in pairs(tree) do table.insert(paths, path) end
  table.sort(paths)
  local out = { string.format("v2 %s %d", keyFor(), os.time()) }
  for _, path in ipairs(paths) do
    local node = tree[path]
    local parts = {}
    for _, e in ipairs(node.items or {}) do
      if e.isContainer then
        table.insert(parts, string.format("b:%s:%s", e.sub or "", tostring(e.id or 0)))
      else
        table.insert(parts, string.format("i:%d:%d", e.id or 0, e.count or 1))
      end
    end
    table.insert(out, string.format("%s|%d|%s|%s", path, node.cap or 20, tostring(node.id or 0),
      table.concat(parts, ",")))
  end
  local ok = pcall(function() g_resources.writeFileContents(FILE, table.concat(out, "\n")) end)
  if ok then
    dirty = false
    loadedFor = keyFor()
    stamp = os.time()
    BagCache.clearChanges()
  end
  return ok
end

function BagCache.load(ignoreDirty)
  if dirty and not ignoreDirty then return nil, "changed since the last scan" end
  if not g_resources.fileExists(FILE) then return nil, "no saved scan" end
  local txt
  local ok = pcall(function() txt = g_resources.readFileContents(FILE) end)
  if not ok or not txt or txt == "" then return nil, "could not read the saved scan" end
  local lines = {}
  for line in txt:gmatch("[^\n]+") do table.insert(lines, line) end
  local header = table.remove(lines, 1) or ""
  local who, when = header:match("^v2 (.*) (%d+)$")
  if not who then return nil, "saved scan is in an older format" end
  if who ~= keyFor() then return nil, "saved scan belongs to another character" end
  stamp = tonumber(when) or 0
  local tree = {}
  for _, line in ipairs(lines) do
    local path, cap, id, rest = line:match("^([^|]*)|(%d+)|([^|]*)|(.*)$")
    if not path then return nil, "saved scan is damaged" end
    local node = { path = path, cap = tonumber(cap), id = tonumber(id), items = {} }
    if rest ~= "" then
      for part in rest:gmatch("[^,]+") do
        local kind, a, b = part:match("^(%a):([^:]*):(.*)$")
        if kind == "b" then
          table.insert(node.items, { id = tonumber(b) or 0, isContainer = true, sub = a,
                                     slot = #node.items })
        elseif kind == "i" then
          table.insert(node.items, { id = tonumber(a) or 0, count = tonumber(b) or 1,
                                     isContainer = false, slot = #node.items })
        end
      end
    end
    tree[path] = node
  end
  if not tree[""] then return nil, "saved scan has no main backpack" end

  -- Integrity check. Changes made while this module was unloaded raise no events, so trust in the file has to
  -- be earned: the main backpack is always open, so compare it. A mismatch there is the usual case (loot, or a
  -- bag added or taken out), and it points the incremental re-read at the right place.
  local live
  if not ignoreDirty then
    for _, c in pairs(g_game.getContainers()) do if not c:hasParent() then live = c break end end
  end
  if live then
    local cachedRoot = tree[""]
    local same = #(cachedRoot.items or {}) == live:getItemsCount()
    if same then
      for i, it in ipairs(live:getItems()) do
        local e = cachedRoot.items[i]
        if not e or e.id ~= it:getId() or (e.isContainer or false) ~= it:isContainer() then same = false break end
      end
    end
    if not same then
      dirty = true
      dirtyPaths = { [""] = true }
      BagCache.blind = false
      return nil, "the main backpack does not match the saved scan"
    end
  end
  return tree
end

function BagCache.forget()
  dirty = true
  stamp = 0
  pcall(function() if g_resources.fileExists(FILE) then g_resources.deleteFile(FILE) end end)
end
