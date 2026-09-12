-- This client swaps hardware cursors (crosshair for "use with", resize arrows on borders and splitters) and
-- under Wine none of them are ever drawn. Worse, the client guards those swaps with g_mouse.isCursorChanged(),
-- so one unbalanced push leaves every resize border refusing to engage. We take cursor management over: the
-- real cursor is never touched, our own stack answers isCursorChanged(), and we draw the shapes ourselves.
local BOX = 32               -- the client's own cursor sheets are 32x32
local DRAWN = 25             -- our drawn shapes live in a 25x25 area inside it
-- where the pointer actually is inside each shape (the cursor's hot spot)
local HOTSPOT = { target = { x = 9, y = 9 }, vertical = { x = 12, y = 12 },
                  horizontal = { x = 12, y = 12 }, text = { x = 12, y = 12 } }

local holder, shapes, follow
local origPush, origPop, origChanged
local stack, seen = {}, {}
local hidMouse = false
local RESIZE = { horizontal = true, vertical = true }
local applyRef

-- Keep crosshair. The bot only sees its own useWith calls, so a wall thrown by hand (client crosshair, hotkey,
-- right-click) never repeated. Wrapping both game calls here catches every throw.
local keepCrosshair = false
local origUseWith, origUseInvWith
local lastUseWith = {}          -- itemId -> where it was last used, so "keep mwall" works for hand throws too
local rearmCount, lastRearm = 0, nil

function setKeepCrosshair(on) keepCrosshair = on and true or false end
function isKeepCrosshair() return keepCrosshair end

function getLastUseWithPos(itemId) return lastUseWith[itemId] end

function stats()
  local p = lastRearm and lastUseWith[lastRearm]
  return string.format("keep=%s rearms=%d lastItem=%s lastPos=%s", tostring(keepCrosshair), rearmCount,
    tostring(lastRearm), p and (p.x .. "," .. p.y .. "," .. p.z) or "none")
end


local function place()
  if not holder or not holder:isVisible() then return end
  if stack[#stack] == 'target' and not g_ui.isMouseGrabbed() then
    for i = #stack, 1, -1 do if stack[i] == 'target' then table.remove(stack, i) end end
    return applyRef(stack[#stack])
  end
  local p = g_window.getMousePosition()
  local hs = HOTSPOT[stack[#stack] or ''] or { x = math.floor(BOX / 2), y = math.floor(BOX / 2) }
  holder:setPosition({ x = p.x - hs.x, y = p.y - hs.y })
end

local function hideAll()
  if not holder then return end
  holder:hide()
  for _, s in pairs(shapes) do s:hide() end
  if follow then removeEvent(follow) follow = nil end
  if hidMouse then
    pcall(origPop, 'blank')
    g_window.restoreMouseCursor()   -- popping alone can uncover a cursor left on the C++ stack
    g_window.showMouse()
    hidMouse = false
  end
end

local function apply(name)
  if not holder then return end
  local shape = shapes[name]
  if not shape then return hideAll() end
  for key, s in pairs(shapes) do s:setVisible(key == name) end
  if not hidMouse then
    g_window.hideMouse()
    pcall(origPush, 'blank')      -- transparent cursor: hideMouse() alone does nothing under Wine
    hidMouse = true
  end
  holder:show()
  holder:raise()
  place()
  if not follow then follow = cycleEvent(place, 16) end
end
applyRef = apply

local function bar(parent, w, h)
  local outer = g_ui.createWidget('UIWidget', parent)
  outer:setPhantom(true)
  outer:setSize({ width = w + 2, height = h + 2 })
  outer:setBackgroundColor('#000000cc')
  local inner = g_ui.createWidget('UIWidget', outer)
  inner:setPhantom(true)
  inner:setBackgroundColor('#ffffffff')
  inner:addAnchor(AnchorTop, 'parent', AnchorTop)
  inner:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  inner:addAnchor(AnchorBottom, 'parent', AnchorBottom)
  inner:addAnchor(AnchorRight, 'parent', AnchorRight)
  inner:setMargin(1)
  return outer
end

local function shape(size)
  local s = g_ui.createWidget('UIWidget', holder)
  s:setPhantom(true)
  s:setSize({ width = size or DRAWN, height = size or DRAWN })
  s:addAnchor(AnchorTop, 'parent', AnchorTop)
  s:addAnchor(AnchorLeft, 'parent', AnchorLeft)
  s:hide()
  return s
end

local function centerH(w) w:addAnchor(AnchorHorizontalCenter, 'parent', AnchorHorizontalCenter) end
local function centerV(w) w:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter) end

local function noteUse(itemId, toThing)
  if type(itemId) ~= 'number' or itemId < 1 then return end
  lastRearm = itemId
  local ok, pos = pcall(function() return toThing and toThing:getPosition() end)
  if ok and pos then lastUseWith[itemId] = pos end
end

-- The originals are parked on the host table, not in a module local: if init ever runs twice without a
-- terminate (a double load, a failed unload), a local would capture our own wrapper and the next call would
-- recurse into itself forever. This keeps the true original no matter how often we are reloaded.
local function original(tbl, key)
  local slot = '__cursorOrig_' .. key
  if tbl[slot] == nil then tbl[slot] = tbl[key] end
  return tbl[slot]
end

local function restoreOriginal(tbl, key)
  local slot = '__cursorOrig_' .. key
  if tbl[slot] ~= nil then tbl[key] = tbl[slot] end
end

local function rearm(itemId, subType)
  if not keepCrosshair or type(itemId) ~= 'number' or itemId < 1 then return end
  rearmCount = rearmCount + 1
  scheduleEvent(function() pcall(armUseWith, itemId, subType) end, 60)
end

function init()
  holder = g_ui.createWidget('UIWidget', g_ui.getRootWidget())
  holder:setId('drawnCursor')
  holder:setPhantom(true)
  holder:setFocusable(false)
  holder:setSize({ width = BOX, height = BOX })
  holder:hide()
  shapes = {}

  -- targeting crosshair: the client's own 8.6 sheet, so it looks exactly like the stock one
  local target = shape(BOX)
  target:setImageSource('/cursors/targetcursor')
  shapes.target = target

  -- vertical resize: a double arrow, heads stacked out of three rows each
  local vert = shape()
  local stem = bar(vert, 3, 15)
  centerH(stem) centerV(stem)
  for row, w in ipairs({ 3, 7, 11 }) do
    local up = bar(vert, w, 2)
    up:addAnchor(AnchorTop, 'parent', AnchorTop) centerH(up) up:setMarginTop((row - 1) * 2)
    local dn = bar(vert, w, 2)
    dn:addAnchor(AnchorBottom, 'parent', AnchorBottom) centerH(dn) dn:setMarginBottom((row - 1) * 2)
  end
  shapes.vertical = vert

  -- horizontal resize: the same arrow turned on its side
  local horz = shape()
  local stemH = bar(horz, 15, 3)
  centerH(stemH) centerV(stemH)
  for col, h in ipairs({ 3, 7, 11 }) do
    local lf = bar(horz, 2, h)
    lf:addAnchor(AnchorLeft, 'parent', AnchorLeft) centerV(lf) lf:setMarginLeft((col - 1) * 2)
    local rt = bar(horz, 2, h)
    rt:addAnchor(AnchorRight, 'parent', AnchorRight) centerV(rt) rt:setMarginRight((col - 1) * 2)
  end
  shapes.horizontal = horz

  -- text caret and hand: small marks, enough to show the client reacted
  local text = shape()
  local caret = bar(text, 3, 17)
  centerH(caret) centerV(caret)
  shapes.text = text

  origPush = original(g_mouse, 'pushCursor')
  origPop = original(g_mouse, 'popCursor')
  origChanged = original(g_mouse, 'isCursorChanged')
  pcall(function() g_mouse.addCursor('blank', '/game_cursor/blank.png', { x = 0, y = 0 }) end)
  g_window.restoreMouseCursor()          -- clear whatever was left stuck before we took over
  g_mouse.pushCursor = function(name)
    local key = name or 'default'
    seen[key] = (seen[key] or 0) + 1
    table.insert(stack, key)
    pcall(apply, key)
  end
  g_mouse.popCursor = function(name)
    local key = name or 'default'
    for i = #stack, 1, -1 do
      if stack[i] == key then table.remove(stack, i) break end
    end
    pcall(apply, stack[#stack])
  end
  g_mouse.isCursorChanged = function() return RESIZE[stack[#stack] or ''] == true end

  origUseWith = original(g_game, 'useWith')
  origUseInvWith = original(g_game, 'useInventoryItemWith')
  g_game.useWith = function(item, toThing, subType)
    local ok, id = pcall(function()
      return type(item) == 'number' and item or (item and item:getId())
    end)
    id = ok and id or nil
    local r = origUseWith(item, toThing, subType)
    noteUse(id, toThing)
    rearm(id, subType)
    return r
  end
  g_game.useInventoryItemWith = function(itemId, toThing, subType)
    local r = origUseInvWith(itemId, toThing, subType)
    noteUse(itemId, toThing)
    rearm(itemId, subType)
    return r
  end
end

-- re-arm a "use with" by item id, the way the client's own crosshair hotkeys do it. Item.create works for
-- items the bot cannot see (closed bags), which findItemInContainers cannot.
function armUseWith(itemId, subType)
  if not itemId or itemId <= 0 then return false end
  local item = Item.create(itemId)
  if not item then return false end
  modules.game_interface.startUseWith(item, subType or 0)
  return true
end

-- diagnostics: which cursor names the client actually asks for
function cursorNames()
  local out = {}
  for k, v in pairs(seen) do out[#out + 1] = k .. " x" .. v end
  table.sort(out)
  return table.concat(out, ", ") .. " | stack=" .. #stack
end

function terminate()
  restoreOriginal(g_game, 'useWith')
  restoreOriginal(g_game, 'useInventoryItemWith')
  restoreOriginal(g_mouse, 'pushCursor')
  restoreOriginal(g_mouse, 'popCursor')
  restoreOriginal(g_mouse, 'isCursorChanged')
  if follow then removeEvent(follow) follow = nil end
  if holder and not holder:isDestroyed() then holder:destroy() end
  holder, shapes, stack, seen = nil, nil, {}, {}
  if hidMouse then g_window.showMouse() hidMouse = false end
  g_window.restoreMouseCursor()
  g_window.showMouse()
end
