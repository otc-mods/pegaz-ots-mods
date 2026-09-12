-- UI helpers on top of the bot's UI table.

-- popup window for rarely used settings; build(content) fills the vertical panel
UI.popup = function(title, height, build)
  local w = UI.createWindow('RpPopup')
  w:setText(title)
  w:setHeight(height)
  w.closeButton.onClick = function() w:destroy() end
  w.onEscape = w.closeButton.onClick
  w.content:setPhantom(false)      -- the stock Panel style is phantom: clicks fell through the text fields
  build(w.content)
  return w
end

-- Same, but the body scrolls and the window carries its own Apply button: for lists that outgrow the screen.
UI.listPopup = function(title, height, build)
  local w = UI.createWindow('RpListPopup')
  w:setText(title)
  w:setHeight(height)
  w.closeButton.onClick = function() w:destroy() end
  w.onEscape = w.closeButton.onClick
  w.content:setPhantom(false)
  build(w.content, w)
  return w
end

-- Press-a-key hotkey picker. The bot hands key combos to onKeyPress as ready-made strings, so capturing one
-- is a flag plus the next key; Escape keeps the old combo.
local capturing = nil
onKeyPress(function(keys)
  if not capturing then return end
  local c = capturing
  capturing = nil
  if c.window and not c.window:isDestroyed() then c.window:destroy() end
  if keys ~= "Escape" then c.onPicked(keys) end
end)

UI.captureKey = function(label, current, onPicked, onClear)
  local w
  w = UI.popup(label, onClear and 150 or 110, function(content)
    UI.Label("Press the combination you want", content)
    UI.Label("now: " .. (current ~= "" and current or "none") .. "   (Escape keeps it)", content)
    if onClear then
      UI.Button("Clear this hotkey", function()
        capturing = nil
        w:destroy()
        onClear()
      end, content)
    end
  end)
  capturing = { window = w, onPicked = onPicked }
  w.onEscape = function() capturing = nil w:destroy() end
  return w
end

-- A collapsible section: header button + a body that everything else is parented into. Sections are shared by
-- id, so several feature files can drop controls into the same one, and the open/closed state is remembered.
UI.sections = {}
UI.sectionHeaders = {}
UI.section = function(id, title, parent)
  if UI.sections[id] then return UI.sections[id], UI.sectionHeaders[id] end
  local header = UI.createWidget('RpSectionHeader', parent)
  local body = UI.createWidget('RpSectionBody', parent)
  if type(storage.sections) ~= "table" then storage.sections = {} end
  local function apply()
    local open = storage.sections[id] ~= false
    header:setText((open and "- " or "+ ") .. title)
    body:setVisible(open)
  end
  header.onClick = function()
    storage.sections[id] = storage.sections[id] == false
    apply()
  end
  apply()
  UI.sections[id] = body
  UI.sectionHeaders[id] = header
  return body, header
end

UI.sectionHeaders = {}

-- two half-width switches on one row; returns {left, right}
UI.switchPair = function(leftText, rightText, parent)
  local row = UI.createWidget('RpSwitchPair', parent)
  row.left:setText(leftText or "")
  row.right:setText(rightText or "")
  if not rightText then row.right:hide() end
  return row
end

-- N equal switch-styled buttons on one row; widths are set by UI.fitButtonRow once the panel has a width
UI.buttonRow = function(texts, parent)
  local row = UI.createWidget('RpButtonRow', parent)
  row.buttons = {}
  for _, text in ipairs(texts) do
    local b = g_ui.createWidget('SmallBotSwitch', row)
    b:setText(text)
    b:setMarginTop(0)
    b:setHeight(22)
    table.insert(row.buttons, b)
  end
  return row
end

UI.fitButtonRow = function(row)
  local w = row:getWidth()
  if w <= 0 or w == row.fittedWidth then return end
  row.fittedWidth = w
  local n = #row.buttons
  local bw = math.floor((w - 2 * (n - 1)) / n)
  for _, b in ipairs(row.buttons) do b:setWidth(bw) end
end

-- label + slider; onChange(value)
UI.scrollRow = function(title, min, max, value, onChange, parent)
  local row = UI.createWidget('RpScrollRow', parent)
  row.scroll:setRange(min, max)
  row.scroll.onValueChange = function(scroll, v)
    row.text:setText(title .. ": " .. (v == 0 and "off" or v))
    if onChange then onChange(v) end
  end
  row.scroll:setValue(value)
  row.scroll.onValueChange(row.scroll, row.scroll:getValue())
  return row
end
