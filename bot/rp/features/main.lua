-- Main tab: one switch per registered feature, grouped and ordered. Action features (mwall, keep mwall) show
-- as plain buttons. "Hotkeys..." binds a key to any of them; bound keys are shown on the switch itself, so
-- this tab doubles as the cheat sheet.
setDefaultTab("Main")

local GROUPS = { "Engine", "HP", "PvP", "Other" }

if type(storage.featureKeys) ~= "table" then storage.featureKeys = {} end

local tabPanel = panel
-- hotkey() draws its own row wherever `panel` points; ours are listed here already, so park them out of sight
local hiddenBin = UI.createWidget('Panel', tabPanel)
hiddenBin:setHeight(0)
hiddenBin:hide()

local function keyOf(id)
  local k = storage.featureKeys[id]
  return type(k) == "string" and k ~= "" and k or nil
end

-- the switch is about half the panel wide, so a bound key goes on its own line instead of running off the edge
local function label(f)
  local k = keyOf(f.id)
  return k and (f.name .. "\n[" .. k .. "]") or f.name
end

local function fire(f)
  if f.action then return f.action() end
  if f.setOn and f.isOn then f.setOn(not f.isOn()) end
end

for _, f in ipairs(Features.list) do
  local k = keyOf(f.id)
  if k then
    local ok = pcall(hotkey, k, f.name, function() fire(f) end, hiddenBin)
    if not ok then
      warning("'" .. k .. "' is not a usable hotkey, dropped from " .. f.name)
      storage.featureKeys[f.id] = nil
    end
  end
end

-- Hotkeys are bound when the config loads, so applying one means reloading the config. Collect the changes
-- here and reload once, instead of once per key.
local function hotkeyDialog()
  local pending = {}                       -- id -> combo, or false for "unbind"
  local rows = {}

  local function shown(f)
    local p = pending[f.id]
    if p == false then return "not set" end
    return p or keyOf(f.id) or "not set"
  end

  local function paint()
    for _, r in ipairs(rows) do
      local changed = pending[r.f.id] ~= nil
      r.key:setText(shown(r.f))
      r.key:setColor(changed and "#ffdd55" or (keyOf(r.f.id) and "#55ff55" or "#ff6666"))
    end
  end

  local function assign(f)
    local current = pending[f.id] or keyOf(f.id) or ""
    UI.captureKey(f.name .. " hotkey", current ~= false and current or "", function(combo)
      if combo == current then
        pending[f.id] = false                          -- same key again = unbind
      else
        for _, r in ipairs(rows) do                    -- one combo, one feature
          if r.f.id ~= f.id and (pending[r.f.id] or keyOf(r.f.id)) == combo then pending[r.f.id] = false end
        end
        pending[f.id] = combo
      end
      paint()
    end, (keyOf(f.id) or pending[f.id]) and function() pending[f.id] = false paint() end or nil)
  end

  local listed = {}
  for _, group in ipairs(GROUPS) do
    for _, f in ipairs(Features.inGroup(group)) do table.insert(listed, f) end
  end

  UI.listPopup("Feature hotkeys", math.min(560, 104 + #listed * 24), function(content, win)
    UI.Label("Set as many as you like, then Apply.", content)
    for _, f in ipairs(listed) do
      local row = UI.buttonRow({ f.name, "-" }, content)
      row.buttons[1].onClick = function() assign(f) end
      row.buttons[2].onClick = function() assign(f) end
      row.buttons[2]:setTooltip("Click, then press the combination. The same key again removes it.")
      table.insert(rows, { f = f, key = row.buttons[2], row = row })
    end
    win.applyButton.onClick = function()
      local changed = false
      for id, combo in pairs(pending) do
        storage.featureKeys[id] = combo or nil
        changed = true
      end
      if changed then reload() else win:destroy() end  -- one reload for the whole batch
    end
    schedule(60, function()
      for _, r in ipairs(rows) do UI.fitButtonRow(r.row) end
      paint()
    end)
  end)
end

local switches = {} -- {widget, feature}

for _, group in ipairs(GROUPS) do
  local members = Features.inGroup(group)
  if #members > 0 then
    local groupLabel = UI.createWidget('RpGroupLabel')
    groupLabel:setText(group)
    for i = 1, #members, 2 do
      local a, b = members[i], members[i + 1]
      local row = UI.switchPair(label(a), b and label(b))
      if keyOf(a.id) or (b and keyOf(b.id)) then                -- two lines need the room
        row:setHeight(34)
        row.left:setHeight(32)
        if b then row.right:setHeight(32) end
      end
      row.left.onClick = function() fire(a) end
      row.left:setTooltip(a.action and ("Run " .. a.name) or a.name)
      if a.isOn then table.insert(switches, { row.left, a }) end
      if b then
        row.right.onClick = function() fire(b) end
        row.right:setTooltip(b.action and ("Run " .. b.name) or b.name)
        if b.isOn then table.insert(switches, { row.right, b }) end
      end
    end
  end
end

-- mirror the real state (switches on the other tabs, engine config switches)
macro(500, function()
  for _, s in ipairs(switches) do
    s[1]:setOn(s[2].isOn())
    local want = label(s[2])
    if s[1]:getText() ~= want then
      s[1]:setText(want)
      local tall = want:find("\n") ~= nil
      s[1]:setHeight(tall and 32 or 26)
      local row = s[1]:getParent()
      if row then row:setHeight(tall and 34 or 28) end
    end
  end
end)

UI.Button("Hotkeys...", hotkeyDialog)
