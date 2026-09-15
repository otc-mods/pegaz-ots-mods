-- Reading and writing cavebot configs. A config is an ordered list of { action, value } pairs, written one
-- per line as "action:value", or "action:[[" + lines + "]]" when the value spans lines. The trailing
-- "config" and "extensions" entries belong to the cavebot and its extensions: they are carried through
-- untouched, otherwise saving a route from here would wipe the supply and depositer setup.
RouteCfg = {}

function RouteCfg.parse(text)
  local list = {}
  if not text then return list end
  local lines = {}
  text = (tostring(text):gsub('^\239\187\191', ''))   -- a config saved by a windows editor starts with a BOM
  for line in text:gmatch('([^\n]*)\n?') do
    lines[#lines + 1] = (line:gsub('\r$', ''))      -- a config written on windows keeps its carriage returns
  end
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local action, value = line:match('^([%w_ ]+):(.*)$')
    if action then
      if value == '[[' then
        local body, closed = {}, false
        i = i + 1
        while i <= #lines do
          if lines[i] == ']]' then closed = true break end
          body[#body + 1] = lines[i]
          i = i + 1
        end
        list[#list + 1] = { action = action, value = table.concat(body, '\n') }
        if not closed then list.unterminated = action end
      elseif line ~= '' then
        list[#list + 1] = { action = action, value = value }
      end
    end
    i = i + 1
  end
  return list
end

-- a value holding a line of exactly ]] would close its own block when read back
function RouteCfg.unwritable(list)
  for i, entry in ipairs(list) do
    local value = tostring(entry.value or '')
    if value:find('\n') and (value:match('^%]%]$') or value:find('\n%]%]\n') or value:match('\n%]%]$')) then
      return i, entry
    end
  end
  return nil
end

function RouteCfg.serialise(list)
  local out = {}
  for _, entry in ipairs(list) do
    local value = tostring(entry.value or '')
    if value:find('\n') then
      out[#out + 1] = entry.action .. ':[['
      out[#out + 1] = value
      out[#out + 1] = ']]'
    else
      out[#out + 1] = entry.action .. ':' .. value
    end
  end
  return table.concat(out, '\n') .. '\n'
end

-- the actions the route is made of, with the cavebot's own bookkeeping kept aside
function RouteCfg.split(list)
  local actions, tail = {}, {}
  for _, entry in ipairs(list) do
    if entry.action == 'config' or entry.action == 'extensions' then
      tail[#tail + 1] = entry
    else
      actions[#actions + 1] = entry
    end
  end
  return actions, tail
end

function RouteCfg.join(actions, tail)
  local list = {}
  for _, a in ipairs(actions) do list[#list + 1] = a end
  for _, t in ipairs(tail or {}) do list[#list + 1] = t end
  return list
end
