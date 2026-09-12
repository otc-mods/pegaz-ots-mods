-- Feature registry: every switchable thing registers once; the Main tab and presets only talk to this.
Features = { list = {}, byId = {} }

-- spec: {id, name, group, macro} or {id, name, group, isOn=function, setOn=function(bool)}
--       {id, name, group, action=function} for things that fire instead of toggling (mwall, keep mwall)
--       optional: order = number, position inside its group on the Main tab
Features.register = function(spec)
  if spec.macro then
    spec.isOn = spec.isOn or function() return spec.macro.isOn() end
    spec.setOn = spec.setOn or function(v) spec.macro.setOn(v and true or false) end
  end
  spec.group = spec.group or "Other"
  spec.order = tonumber(spec.order) or 100
  Features.byId[spec.id] = spec
  table.insert(Features.list, spec)
  return spec
end

Features.isOn = function(id)
  local f = Features.byId[id]
  return f and f.isOn() and true or false
end

Features.setOn = function(id, v)
  local f = Features.byId[id]
  if f then f.setOn(v and true or false) end
end

Features.snapshot = function()
  local s = {}
  for _, f in ipairs(Features.list) do
    if f.isOn then s[f.id] = f.isOn() and true or false end
  end
  return s
end

-- the features of one group, in the order they should be shown
Features.inGroup = function(group)
  local out = {}
  for _, f in ipairs(Features.list) do
    if f.group == group and not f.hidden then table.insert(out, f) end
  end
  table.sort(out, function(a, b)
    if a.order == b.order then return a.name < b.name end
    return a.order < b.order
  end)
  return out
end

Features.apply = function(map)
  for id, v in pairs(map or {}) do Features.setOn(id, v) end
end
