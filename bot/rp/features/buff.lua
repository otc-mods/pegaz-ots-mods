-- Buffs: keep a buff spell up instead of firing it on cooldown. The first cast teaches the bot what the spell
-- does - which condition icons it adds and which skills it raises - and from then on it recasts only once that
-- signature is gone. Measured on Pegaz for utito tempo san: 2.0s cooldown, 450 mana, 10.3s duration, and the
-- icon bit tracks the skill bonus exactly, so one cast per ~10s replaces five.
setDefaultTab("Target")

local tabPanel = panel
panel = UI.section("targetBuffs", "Buffs", tabPanel)   -- declared here so the macro switch lands inside too

local SPELL_CD = 2200        -- server spell cooldown (measured 2.00s), used once a signature is known
local NEAR = 5               -- sqm: a monster this close counts as "in a fight" even before you target it
local LEARN_DELAY = 700
local BITS = { 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 }
-- bits that come and go for reasons of their own: zone flags, hunger, drunkenness and every damage condition
local IGNORE = { [1]=true, [2]=true, [4]=true, [8]=true, [32]=true, [64]=true, [256]=true, [512]=true,
                 [1024]=true, [2048]=true, [8192]=true, [16384]=true, [32768]=true, [65536]=true }
local MIN_DURATION = 4000    -- anything shorter than this is a side effect, not the buff we are keeping up

local function hasBit(v, b) return math.floor(v / b) % 2 == 1 end

if type(storage.buffs) ~= "table" then storage.buffs = {} end
for i = 1, 2 do
  local s = storage.buffs[i]
  if type(s) ~= "table" then s = {} end
  if type(s.text) ~= "string" then s.text = (i == 1) and "utito tempo san" or "" end
  s.interval = tonumber(s.interval) or 10
  s.on = nil                       -- dropped: the per-slot toggle only made the feature look broken
  storage.buffs[i] = s
end
if storage.buffOnlyAttacking == nil then storage.buffOnlyAttacking = true end
if type(storage.buffMinMana) ~= "number" then storage.buffMinMana = 15 end

-- `next` is not in the bot sandbox, so emptiness is checked the long way
local function any(t)
  if type(t) ~= "table" then return false end
  for _ in pairs(t) do return true end
  return false
end

local function learned(s)
  return any(s.bits) or any(s.skills)
end

local function active(s)
  local me = g_game.getLocalPlayer()
  if not me then return false end
  local st = me:getStates()
  for _, raw in pairs(s.bits or {}) do
    local b = tonumber(raw)
    if b and hasBit(st, b) then return true end
  end
  for key, raw in pairs(s.skills or {}) do
    local idx, base = tonumber(key), tonumber(raw)
    if idx and base and me:getSkillLevel(idx) > base then return true end
  end
  return false
end

local function snapshot()
  local me = g_game.getLocalPlayer()
  local sk = {}
  for i = 0, 6 do sk[i] = me:getSkillLevel(i) end
  return { states = me:getStates(), skills = sk }
end

local function learn(s, before)
  local after = snapshot()
  local bits, skills = {}, {}
  for _, b in ipairs(BITS) do
    if not IGNORE[b] and hasBit(after.states, b) and not hasBit(before.states, b) then
      table.insert(bits, b)
    end
  end
  for i = 0, 6 do
    if after.skills[i] > before.skills[i] then skills[tostring(i)] = before.skills[i] end
  end
  if any(bits) or any(skills) then
    s.bits, s.skills = bits, skills
    info("buff '" .. s.text .. "' learned: " .. #bits .. " icon(s), " ..
      (any(skills) and "skill bonus" or "no skill change"))
  end
end

local function inFight()
  if g_game.getAttackingCreature() then return true end
  local me = g_game.getLocalPlayer()
  local pos = me and me:getPosition()
  if not pos then return false end
  for _, c in ipairs(g_map.getSpectatorsInRange(pos, false, NEAR, NEAR)) do
    if c:isMonster() and c:getHealthPercent() > 0 then return true end
  end
  return false
end

local lastCast, wasActive, coldUntil = {}, {}, {}
local blockedSince = {}
local function cast(i, s)
  local before = snapshot()
  if TargetBot then
    if TargetBot.saySpell(s.text) == false then
      -- the targetbot talks constantly; after 3s of losing that race, say it ourselves - the server's own
      -- 2s spell cooldown is the real limit anyway
      blockedSince[i] = blockedSince[i] or now
      if now - blockedSince[i] < 3000 then return false end
      say(s.text)
    end
  else
    say(s.text)
  end
  blockedSince[i] = nil
  lastCast[i] = now
  schedule(LEARN_DELAY, function() if not learned(s) then learn(s, before) end end)
  return true
end

local status = "idle"
local buffMacro = macro(200, "Buffs", function()
  if storage.buffOnlyAttacking and not inFight() then status = "waiting for a fight" return end
  -- compute it ourselves: the cached player handle can report a stale/zero mana after a relog, and the old
  -- getManaPercent() call was what made this say "mana too low" at full mana
  local me = g_game.getLocalPlayer()
  if not me then status = "no player" return end
  local maxMana = math.max(1, me:getMaxMana())
  local manaPct = math.floor(100 * me:getMana() / maxMana)
  if manaPct < storage.buffMinMana then
    status = string.format("mana %d%% < %d%%", manaPct, storage.buffMinMana)
    return
  end
  for i = 1, 2 do
    local s = storage.buffs[i]
    if s.text ~= "" then
      if (coldUntil[i] or 0) > now then status = "waiting for the buff to lapse" return end
      local isAct = learned(s) and active(s)
      -- the buff's own length, learned the first time we watch it run out
      if wasActive[i] and not isAct and lastCast[i] then
        local d = now - lastCast[i]
        if d < MIN_DURATION then
          s.bits, s.skills, s.duration = nil, nil, nil   -- that was a side effect; relearn from a cold cast
          coldUntil[i] = now + 15000
        elseif d < 600000 then
          s.duration = d
        end
      end
      wasActive[i] = isAct
      -- recast a few seconds BEFORE it drops, so the buff never actually lapses
      local margin = math.min(5000, math.max(2000, (s.duration or 0) * 0.25))
      local due = s.duration and (now - (lastCast[i] or 0) >= s.duration - margin)
      local idle = not learned(s) and now - (lastCast[i] or 0) >= s.interval * 1000
      if (not isAct or due or idle) and now - (lastCast[i] or 0) >= SPELL_CD then
        status = cast(i, s) and ("cast " .. s.text) or "spell timing busy"
        return                            -- one spell per tick: the cooldown is shared
      end
      status = isAct and (s.duration and string.format("up, recast in %.1fs",
        math.max(0, (s.duration - margin - (now - (lastCast[i] or 0))) / 1000)) or "up") or "waiting on cooldown"
    end
  end
end)
Features.register{ id = "buffs", name = "Buffs", group = "HP", order = 5, macro = buffMacro }

-- ---- UI ----
-- the panel is ~180px wide, so every row has to say its piece in a couple of words
local rows = {}
for i = 1, 2 do
  local s = storage.buffs[i]
  local toggle                     -- shows the spell; a slot with no words is simply inactive
  local row = UI.buttonRow({ "edit", "every " .. s.interval .. "s" })
  row.buttons[1]:setTooltip("Change the spell words - leave it empty to switch this slot off")
  row.buttons[1].onClick = function()
    UI.SinglelineEditorWindow(s.text, { title = "Buff " .. i, description = "Spell words" }, function(text)
      s.text = (text or ""):gsub("^%s*(.-)%s*$", "%1")
      s.bits, s.skills, s.duration = nil, nil, nil
      toggle:setText(s.text ~= "" and s.text or "(no spell)")
    end)
  end
  row.buttons[2]:setTooltip("Fallback recast, used only until the buff's own length is known")
  row.buttons[2].onClick = function()
    UI.SinglelineEditorWindow(tostring(s.interval), { title = "Buff " .. i .. " recast",
      description = "Seconds between casts while the effect is not recognised" }, function(text)
      local v = tonumber((text or ""):match("%d+"))
      if v then s.interval = math.max(2, math.min(600, v)) end
      row.buttons[2]:setText("every " .. s.interval .. "s")
    end)
  end
  toggle = UI.Button(s.text ~= "" and s.text or "(no spell)", function() row.buttons[1].onClick() end)
  panel:moveChildToIndex(toggle, panel:getChildIndex(row))    -- spell name sits above its own buttons
  rows[i] = { toggle = toggle, row = row }
end

local guard = UI.switchPair("Only in fight")
guard.left.onClick = function()
  storage.buffOnlyAttacking = not storage.buffOnlyAttacking
  guard.left:setOn(storage.buffOnlyAttacking)
end
guard.left:setOn(storage.buffOnlyAttacking)

local manaBtn                      -- declared first: a closure cannot see the local it is being assigned to
manaBtn = UI.Button("Min mana " .. storage.buffMinMana .. "%", function()
  UI.SinglelineEditorWindow(tostring(storage.buffMinMana), { title = "Buff mana floor",
    description = "Do not cast buffs below this mana %" }, function(text)
    local v = tonumber((text or ""):match("%d+"))
    if v then storage.buffMinMana = math.max(0, math.min(95, v)) end
    manaBtn:setText("Min mana " .. storage.buffMinMana .. "%")
  end)
end)

local statusLabel = UI.Label("Buffs: off")
macro(500, function()
  for i, r in ipairs(rows) do
    UI.fitButtonRow(r.row)
    local s = storage.buffs[i]
    r.toggle:setOn(s.text ~= "")
    local tag = s.text ~= "" and s.text or "(no spell)"
    if s.duration then tag = tag .. "  " .. (math.floor(s.duration / 100) / 10) .. "s" end
    r.toggle:setText(tag)
  end
  statusLabel:setText("Buffs: " .. (buffMacro.isOn() and status or "off"))
end)

panel = tabPanel

-- Buffs belong next to the attack controls, not below looting
pcall(function()
  local body, header = UI.section("targetBuffs", "Buffs", tabPanel)
  tabPanel:moveChildToIndex(header, 4)
  tabPanel:moveChildToIndex(body, 5)
end)
