-- Hunting tasks: keep a list of tasks running, claim each one the moment it completes, take it again.
-- The server's task system is a client window (game_tasks); its cards and buttons answer to their own onClick
-- handlers whether or not the window is on screen, so the whole loop runs with the window shut.
-- How many tasks can run at once varies per character (it is buyable), so the loop never assumes a number:
-- it takes what it can, and when an accept does not show up in the tracker it treats the slots as full and
-- waits for one to free up.
setDefaultTab("Tools")

local tabPanel = panel
panel = UI.section("toolsTasks", "Tasks", tabPanel)

local GOALS = { 50, 100, 200, 300, 500, 1000 }
local SETTLE = 1000          -- heartbeat: how often the loop re-examines the task state
local POLL = 120             -- mid-cycle: how soon it comes back after acting
local SLOTS_RETRY = 20000    -- after "no free slot", wait this long before trying again (a freed
                             -- slot clears it immediately, this is only the fallback)
local ROWS = 4               -- task rows the panel offers

if type(storage.taskCfg) ~= "table" then storage.taskCfg = {} end
local cfg = storage.taskCfg
cfg.done = tonumber(cfg.done) or 0
cfg.reward = (cfg.reward == "Gold") and "Gold" or "EXP"
if cfg.dropStray == nil then cfg.dropStray = false end
if type(cfg.list) ~= "table" then                    -- migrate the single-task config
  cfg.list = {}
  if type(cfg.monster) == "string" and cfg.monster ~= "" then
    table.insert(cfg.list, { monster = cfg.monster, goal = tonumber(cfg.goal) or 50, reward = cfg.reward })
  end
end

-- {name, lv, exp, outfit} of every task, straight from the client's own cache
local CATALOG_VERSION = 2
if type(cfg.catalog) ~= "table" or cfg.catalogVersion ~= CATALOG_VERSION then
  cfg.catalog = {}
  cfg.catalogVersion = CATALOG_VERSION
end

local parkUntil, status = 0, "off"

-- ---- where the numbers come from ------------------------------------------------------------------
-- The client already holds everything: game_tasks keeps the whole task list in a local (fullInfo), and the
-- server pushes progress as JSON on extended opcode 30 every couple of seconds. Both are reachable through
-- modules._G, so the loop reads facts instead of scraping widgets. Every access is wrapped: if the server
-- ships a different game_tasks one day, this quietly falls back to reading the tracker window.
local G = modules._G
local live, liveCount, liveAt = {}, 0, 0

local function upvalue(fn, want)
  if type(fn) ~= "function" or not G or type(G.debug) ~= "table" then return nil end
  local i = 1
  while true do
    local name, val = G.debug.getupvalue(fn, i)
    if not name then break end
    if name == want then return val end
    i = i + 1
  end
end

-- all 55 tasks, including the ones the card grid never renders
local function readCatalog()
  local ok, list = pcall(function()
    local full = upvalue(modules.game_tasks and modules.game_tasks.Taskoffline, 'fullInfo')
    if type(full) ~= "table" then return nil end
    local out = {}
    for _, e in pairs(full) do
      if type(e) == "table" and e.name then
        out[#out + 1] = { name = tostring(e.name), lv = tonumber(e.level) or 0,
                          exp = tonumber(e.expReward) or 0,
                          outfit = (type(e.outfit) == "table" and tonumber(e.outfit.type)) or nil }
      end
    end
    table.sort(out, function(a, b)
      if a.lv ~= b.lv then return a.lv < b.lv end
      return a.name < b.name
    end)
    return out
  end)
  if ok and type(list) == "table" and #list > 0 then
    cfg.catalog = list
    cfg.catalogVersion = CATALOG_VERSION
    return #list
  end
  return 0
end

-- progress for every task the character holds, finished ones included
local function onFeed(buffer)
  if type(buffer) ~= "string" or not G or type(G.json) ~= "table" then return end
  local ok, data = pcall(G.json.decode, buffer)
  if not ok or type(data) ~= "table" then return end
  -- both actions carry the same shape: "refreshTrackerKills" while tasks run, "refreshTracker" when the list
  -- changes - including the empty list. Ignoring the latter meant the loop never learned it had no tasks and
  -- kept trusting a stale tracker widget.
  if (data.action ~= "refreshTrackerKills" and data.action ~= "refreshTracker")
     or type(data.data) ~= "table" then return end
  local out, n = {}, 0
  for _, e in pairs(data.data) do
    if type(e) == "table" and e.name then
      out[tostring(e.name):lower()] = { name = tostring(e.name),
        have = tonumber(e.currentKills) or 0, want = tonumber(e.required) or 0 }
      n = n + 1
    end
  end
  live, liveCount, liveAt = out, n, now
end

-- Wrapping has to survive config reloads: the original is parked on the global table and restored before
-- every wrap, so reloading twenty times still leaves exactly one wrapper. (Stacking these once cost the
-- client 9,000 stack overflows.)
local function tapFeed()
  pcall(function()
    local cbs = upvalue(G.ProtocolGame and G.ProtocolGame.registerExtendedOpcode, 'extendedCallbacks')
    if type(cbs) ~= "table" then return end
    if G.__rpTaskOrigOp30 then cbs[30] = G.__rpTaskOrigOp30 end
    if type(cbs[30]) ~= "function" then return end
    G.__rpTaskOrigOp30 = cbs[30]
    local original = cbs[30]
    cbs[30] = function(protocol, opcode, buffer)
      pcall(onFeed, buffer)
      return original(protocol, opcode, buffer)
    end
  end)
end
tapFeed()
schedule(2000, function() if #cfg.catalog == 0 then readCatalog() end end)
local slotsFullUntil = 0
local taskMacro, bump


local function window()
  local root = g_ui.getRootWidget()
  return root and root:recursiveGetChildById('tasksWindow'), root
end



-- Fallback only: the tracker mini window, read if the opcode tap could not be installed at all.
local function activeTasks()
  local _, root = window()
  local tr = root and root:recursiveGetChildById('taskTracker')
  local out, n = {}, 0
  if not tr then return out, n end
  local pendingName
  local function walk(w, d)
    if d > 4 then return end
    for _, c in ipairs(w:getChildren()) do
      local ok, t = pcall(function() return c:getText() end)
      if ok and type(t) == "string" and t ~= "" then
        local a, b = t:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
        if a and pendingName then
          out[pendingName:lower()] = { name = pendingName, have = tonumber(a), want = tonumber(b) }
          n = n + 1
          pendingName = nil
        elseif not a then
          pendingName = t
        end
      end
      walk(c, d + 1)
    end
  end
  walk(tr, 0)
  return out, n
end

-- "Task started / Reward: ..." boxes stack over the map if nobody clicks them. A box is hidden the moment it
-- is seen and only then answered, so the loop never leaves one on screen.
local function dismissPopups()
  local root = g_ui.getRootWidget()
  if not root then return end
  for _, c in ipairs(root:getChildren()) do
    local ok, title = pcall(function() return c:getText() end)
    if ok and title == "Task" and c:isVisible() then
      pcall(function() c:hide() end)
      local btn
      local function find(w, d)
        if d > 3 or btn then return end
        for _, k in ipairs(w:getChildren()) do
          local okk, t = pcall(function() return k:getText() end)
          if okk and type(t) == "string" and t:lower():find("ok") and k:getClassName():find("Button") then
            btn = k return
          end
          find(k, d + 1)
        end
      end
      find(c, 0)
      if btn then
        local h = btn.onClick
        if type(h) == "function" then pcall(h, btn)
        elseif type(h) == "table" then for _, f in ipairs(h) do pcall(f, btn) end end
      end
    end
  end
end

-- ---- talking to the server directly ---------------------------------------------------------------
-- The task window is only a view: taking, claiming and cancelling are three JSON messages on the same
-- extended opcode the progress feed arrives on. Driving those directly means the loop never opens a window,
-- never clicks a card, and cannot be derailed by the client's list being empty or stale.
--   {"action":"start",     "data":{"name":"hellhound","goal":50}}
--   {"action":"getReward", "data":{"name":"hellhound"}}                 (add rewardType="gold" for coins)
--   {"action":"cancel",    "data":{"name":"hellhound"}}
local function send(action, data)
  local ok = pcall(function()
    local proto = g_game.getProtocolGame()
    if not proto then return end
    proto:sendExtendedOpcode(30, G.json.encode({ action = action, data = data }))
  end)
  return ok
end

local function startTask(name, goal) return send("start", { name = name, goal = goal }) end
local function cancelTask(name) return send("cancel", { name = name }) end
local function claimTask(name, reward)
  if reward == "Gold" then return send("getReward", { name = name, rewardType = "gold" }) end
  return send("getReward", { name = name })
end

-- ---- the loop -------------------------------------------------------------------------------------
local waitUntil = {}         -- monster -> do not act on it again before this time
local lastChangeAt, lastShape, resyncAt = 0, "", 0
local actedAt = {}           -- monster -> when we last sent something about it

-- The feed arrives every couple of seconds, so right after we act its contents still describe the world as
-- it was BEFORE our message. Acting again on that picture is what produced "No completed tasks to claim"
-- and "You already have this task active": the task looked finished (or missing) only because the server
-- had not been heard from since. So a task is only acted on once the feed has spoken after our last move.
local function fresh(key)
  -- with the feed running, "fresh" means the server has spoken since we acted. Without it (the tap could not
  -- be installed, or the feed went quiet) that test can never pass, so fall back to a plain cooldown -
  -- otherwise the loop deadlocks on a finished task it refuses to claim.
  if now - liveAt >= 15000 then return now - (actedAt[key] or 0) > 3000 end
  return liveAt > (actedAt[key] or 0)
end
local sentClaim = {}         -- monster -> when we asked for its reward (to notice a claim that did not land)
local sentStart = {}         -- monster -> when we asked to start it (to notice "no free slot")

local function entryFor(key)
  for _, e in ipairs(cfg.list) do
    if e.monster:lower() == key then return e end
  end
end

local function feedActive()
  if now - liveAt < 15000 then return live, liveCount end
  if liveAt > 0 then return live, liveCount end   -- the feed worked once: a gap is silence, not new facts
  return activeTasks()                            -- no tap at all: read the tracker window instead
end

local run
local fastBooked, running = false, false

local function bump(ms)
  if fastBooked then return end
  fastBooked = true
  schedule(ms or POLL, function()
    fastBooked = false
    if taskMacro and taskMacro.isOn() then run() end
  end)
end

run = function()
  if running then return end
  running = true
  local ok, err = pcall(function()
    dismissPopups()
    if #cfg.list == 0 then status = "no tasks set" return end
    if now < parkUntil then status = "paused after errors" return end

    local active, count = feedActive()

    -- Watchdog. Every stall so far looked the same from here: the picture stops changing while there is
    -- clearly something to do. Rather than trust that the state is right, ask the server to restate it
    -- ({"action":"open"} is what the client itself sends) and drop every in-flight assumption.
    local shape = tostring(count)
    for key, a in pairs(active) do shape = shape .. "|" .. key .. a.have .. "/" .. a.want end
    if shape ~= lastShape then
      lastShape, lastChangeAt = shape, now
    elseif now - lastChangeAt > 30000 and now - resyncAt > 30000 then
      local todo = false
      for key, a in pairs(active) do
        if a.want > 0 and a.have >= a.want then todo = true end
      end
      for _, e in ipairs(cfg.list) do
        if not active[e.monster:lower()] then todo = true end
      end
      if todo then
        resyncAt, lastChangeAt = now, now
        sentClaim, sentStart, waitUntil, actedAt = {}, {}, {}, {}
        slotsFullUntil = 0
        send("open", {})
        warning("[tasks] nothing moved for 30s - asked the server to restate the task list")
        status = "resyncing"
        return
      end
    end

    -- a claim that landed: the task is gone from the feed
    for key, at in pairs(sentClaim) do
      if not active[key] then
        sentClaim[key] = nil
        cfg.done = cfg.done + 1
        slotsFullUntil = 0
        waitUntil[key] = 0                          -- the slot is free now: retake without waiting
      elseif now - at > 4000 then
        sentClaim[key] = nil                      -- did not land; the loop will simply ask again
        waitUntil[key] = now + 1000
      end
    end
    -- a start that landed (or did not, which means the slots are full)
    for key, at in pairs(sentStart) do
      if active[key] then
        sentStart[key] = nil
      elseif now - at > 4000 then
        sentStart[key] = nil
        slotsFullUntil = now + SLOTS_RETRY
      end
    end

    -- 1. claim anything finished, ours or not: a finished task holds a slot until someone takes the reward
    for key, a in pairs(active) do
      -- sentClaim means the reward was already requested: the feed lags a couple of seconds behind, and
      -- asking twice earns a "no completed task to claim" box
      if a.want > 0 and a.have >= a.want and not sentClaim[key] and fresh(key)
         and now >= (waitUntil[key] or 0) then
        local e = entryFor(key)
        claimTask(a.name, e and e.reward or cfg.reward)
        sentClaim[key] = now
        actedAt[key] = now
        waitUntil[key] = now + 2500
        status = "claiming " .. a.name
        return
      end
    end

    -- A claim takes a moment to register, and until it does the slot is still occupied - starting anything
    -- in that window just makes the server refuse it and pop a warning. So: nothing is taken while a claim
    -- is in flight. (`next` is missing from the bot sandbox, hence the counter.)
    local claimsInFlight = 0
    for _ in pairs(sentClaim) do claimsInFlight = claimsInFlight + 1 end
    if claimsInFlight > 0 then
      status = "waiting for reward"
      return
    end

    -- 2. take what is configured and not running
    if now >= slotsFullUntil then
      for _, e in ipairs(cfg.list) do
        local key = e.monster:lower()
        -- sentStart means a start is already on the wire: the feed only refreshes every ~2s, and asking
        -- twice earns a "You already have this task active" box
        -- a start may also be needed when nothing is active at all, and then the feed goes quiet: after
        -- four seconds of silence we stop waiting for a refresh that is not coming
        if not active[key] and not sentStart[key] and now >= (waitUntil[key] or 0)
           and (fresh(key) or now - (actedAt[key] or 0) > 4000) then
          startTask(e.monster, e.goal)
          sentStart[key] = now
          actedAt[key] = now
          waitUntil[key] = now + 3000
          status = "taking " .. e.monster
          return
        end
      end
    elseif cfg.dropStray then
      -- 3. no slot for a task we want, so drop the least-advanced task we did not ask for
      local wanted = false
      for _, e in ipairs(cfg.list) do
        if not active[e.monster:lower()] then wanted = true end
      end
      local worst
      if wanted then
        for key, a in pairs(active) do
          if not entryFor(key) and (not worst or a.have < worst.have) then worst = a end
        end
      end
      if worst and now >= (waitUntil[worst.name:lower()] or 0) then
        cancelTask(worst.name)
        actedAt[worst.name:lower()] = now
        waitUntil[worst.name:lower()] = now + 3000
        slotsFullUntil = 0
        status = "dropping " .. worst.name
        return
      end
    end

    local parts = {}
    for _, e in ipairs(cfg.list) do
      local a = active[e.monster:lower()]
      parts[#parts + 1] = a and (a.have .. "/" .. a.want) or "-"
    end
    local why = ""
    if now < slotsFullUntil then
      why = "  no free slot " .. math.ceil((slotsFullUntil - now) / 1000) .. "s"
    end
    local src = (now - liveAt < 15000) and "" or "  (no feed)"
    status = count .. " active  " .. table.concat(parts, " ") .. why .. src
  end)
  running = false
  if not ok then warning("[tasks] " .. tostring(err)) end
end

-- The server's own "Task started / Reward" boxes appear a frame or two after a claim or a start. Clearing
-- them on the 1s tick left them on screen for up to a second; this unnamed macro just sweeps them away.
macro(100, function()
  if taskMacro and taskMacro.isOn() then dismissPopups() end
end)

-- No setOn(false) here: the bot persists macro state in storage._macros, so forcing it off at load also
-- overwrote the player's choice - the switch turned itself off on every config reload.
taskMacro = macro(SETTLE, "Auto tasks", function() run() end)

Features.register{ id = "tasks", name = "Auto tasks", group = "Other", order = 60, macro = taskMacro }

-- ---- UI ----
-- One block per task: the name button doubles as the progress readout, below it the goal and the reward.
-- The first unused block shows "+ add task", so the list grows without an editor window.
local blocks, statusLabel = {}, nil
local paint

local function setRow(i, name)
  local entry = cfg.list[i]
  if name == "" then
    if entry then table.remove(cfg.list, i) end
  elseif entry then
    entry.monster = name
  else
    table.insert(cfg.list, { monster = name, goal = 50, reward = cfg.reward })
  end
  slotsFullUntil = 0
  waitUntil = {}
  sentStart, sentClaim = {}, {}
  paint()
end

local function typeRow(i)
  local entry = cfg.list[i]
  UI.SinglelineEditorWindow(entry and entry.monster or "", { title = "Task monster",
    description = "Name as the task list spells it; empty removes" }, function(text)
    setRow(i, (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", ""))
  end)
end

-- Pick from what the server offers. The list is the client's own cache, so it is complete and instant; the
-- category rule (Easy <= 60, Medium <= 110, Hard <= 164, Expert above) is the one the client itself uses -
-- read out of game_tasks' getCategoryForLevel rather than guessed.
local CATEGORIES = { { "All" }, { "Easy", 0, 60 }, { "Medium", 61, 110 }, { "Hard", 111, 164 },
                     { "Expert", 165, 9999 } }

local function editRow(i)
  UI.pickPopup("Pick a task", function(win)
    local rows = cfg.catalog or {}
    local listed, catButtons = {}, {}
    local chosenCat = 1

    local function inCategory(e, idx)
      local c = CATEGORIES[idx]
      if not c[2] then return true end
      local lv = tonumber(e.lv) or 0
      return lv >= c[2] and lv <= c[3]
    end

    local function fill()
      for _, b in ipairs(listed) do b:destroy() end
      listed = {}
      local filter = (win.search:getText() or ""):lower()
      local shown = 0
      for _, e in ipairs(rows) do
        if inCategory(e, chosenCat) and (filter == "" or e.name:lower():find(filter, 1, true)) then
          local card = g_ui.createWidget('RpTaskCard', win.content)
          card.name:setText(e.name)
          card.lv:setText("lv " .. (e.lv or "?"))
          if e.outfit then
            pcall(function()
              card.creature:setOutfit({ type = e.outfit })
              card.creature:setCenter(true)          -- otherwise big monsters hang off the top-left
              card.creature:setFixedCreatureSize(true)
            end)
          end
          card.onClick = function()
            win.closeButton.onClick()
            setRow(i, e.name:lower())
          end
          local exp = tonumber(e.exp) or 0
          card:setTooltip(e.name .. " - level " .. (e.lv or "?") ..
            (exp > 0 and ("\n" .. exp .. " exp for the listed goal") or ""))
          listed[#listed + 1] = card
          shown = shown + 1
        end
      end
      win.info:setText(shown .. " of " .. #rows .. " tasks")
      for idx, b in ipairs(catButtons) do UI.pick(b, idx == chosenCat) end
    end

    -- buttons are sized here, not in the style: three or five of them have to share a fixed strip, and the
    -- stock Button width (106) overflowed the window
    -- The stock button is 106px wide and a horizontalBox keeps that width, so a row of them overflowed the
    -- window. Widths are forced here and the layout is told to re-run, which is the only way it sticks.
    local function strip(parent, labels, width, onPick)
      local made = {}
      local n = #labels
      local each = math.max(40, math.floor((width - 4 * (n - 1)) / n))
      for idx, text in ipairs(labels) do
        local b = g_ui.createWidget('BotButton', parent)
        b:setText(text)
        b:setMarginTop(0)
        b:setHeight(20)
        b:setWidth(each)
        b.onClick = function() onPick(idx) end
        made[#made + 1] = b
      end
      pcall(function()
        local layout = parent:getLayout()
        if layout then layout:update() end
      end)
      schedule(30, function()                       -- the layout can re-apply style widths a frame later
        for _, b in ipairs(made) do
          if not b:isDestroyed() then b:setWidth(each) end
        end
      end)
      return made
    end

    local actionLabels = { "Reload", "Type name" }
    if cfg.list[i] then actionLabels[#actionLabels + 1] = "Remove" end
    win.actions:setWidth(#actionLabels * 106 + (#actionLabels - 1) * 4)
    strip(win.actions, actionLabels, win.actions:getWidth(), function(idx)
      local label = actionLabels[idx]
      if label == "Reload" then
        local n = readCatalog()
        rows = cfg.catalog or {}
        fill()
        if n == 0 then win.info:setText("task list unavailable") end
      elseif label == "Type name" then
        win.closeButton.onClick()
        typeRow(i)
      else
        win.closeButton.onClick()
        setRow(i, "")
      end
    end)

    local catLabels = {}
    for _, c in ipairs(CATEGORIES) do catLabels[#catLabels + 1] = c[1] end
    catButtons = strip(win.filters, catLabels, win:getWidth() - 32, function(idx)
      chosenCat = idx
      fill()
    end)

    win.search.onTextChange = function(_, text)
      win.hint:setVisible(text == "")
      fill()
    end
    fill()
  end)
end

for i = 1, ROWS do
  local nameBtn = UI.Button("+ add task", function() editRow(i) end)
  local row = UI.buttonRow({ "Goal 50", "EXP" })
  blocks[i] = { name = nameBtn, row = row, goal = row.buttons[1], reward = row.buttons[2] }
  row.buttons[1].onClick = function()
    local entry = cfg.list[i]
    if not entry then return end
    local at = 1
    for k, v in ipairs(GOALS) do if v == entry.goal then at = k end end
    entry.goal = GOALS[(at % #GOALS) + 1]
    paint()
  end
  row.buttons[2].onClick = function()
    local entry = cfg.list[i]
    if not entry then return end
    entry.reward = (entry.reward == "EXP") and "Gold" or "EXP"
    cfg.reward = entry.reward                       -- newest choice becomes the default for new rows
    paint()
  end
end

paint = function()
  local active = feedActive()          -- the same source the loop uses; the tracker walk was both slower
                                       -- and occasionally stale (it showed 164/50 for a 200-goal task)
  for i, b in ipairs(blocks) do
    local entry = cfg.list[i]
    if entry then
      local a = active[entry.monster:lower()]
      b.name:setText(entry.monster .. (a and ("  " .. a.have .. "/" .. a.want) or ""))
      b.goal:setText("Goal " .. ((entry.goal == 1000) and "1k" or entry.goal))
      b.reward:setText(entry.reward)
      UI.plain(b.goal) UI.plain(b.reward)          -- these cycle values, they are not on/off
      b.row:show()
    else
      b.name:setText("+ add task")
      b.row:hide()
    end
    -- only one empty slot is offered at a time
    b.name:setVisible(entry ~= nil or i == #cfg.list + 1)
  end
end

local scanBtn
scanBtn = UI.Button("Refresh task list", function()
  local n = readCatalog()
  scanBtn:setText(n > 0 and (n .. " tasks loaded") or "task list unavailable")
  schedule(2500, function() scanBtn:setText("Refresh task list") end)
end)
scanBtn:setTooltip("Re-read the task list the client received from the server")

local strayBtn = UI.Button(cfg.dropStray and "Drop stray tasks" or "Keep stray tasks", function()
  cfg.dropStray = not cfg.dropStray
  slotsFullUntil = 0
end)
strayBtn:setTooltip("When a task you did not ask for blocks the last slot, cancel it (its kills are lost)")

statusLabel = UI.Label("Auto tasks: off")
macro(500, function()
  for _, b in ipairs(blocks) do UI.fitButtonRow(b.row) end
  paint()
  strayBtn:setText(cfg.dropStray and "Drop stray tasks" or "Keep stray tasks")
  UI.pick(strayBtn, cfg.dropStray)
  statusLabel:setText("Auto tasks: " .. (taskMacro.isOn() and status or "off") ..
    (cfg.done > 0 and ("  -  " .. cfg.done .. " done") or ""))
end)

panel = tabPanel
