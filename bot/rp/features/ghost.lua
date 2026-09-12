-- Ghost watch: the server keeps sending creatures it will not let the client draw - a gamemaster in ghost
-- mode arrives with looktype 0, name and position intact. The battle list quietly drops them, so nothing on
-- screen tells you someone is standing there. This marks the tile they are on and says who it is.
setDefaultTab("Tools")

local tabPanel = panel
panel = UI.section("toolsOther", "Utility", tabPanel)

local MARK_COLOR = '#ff5555'
local RANGE_X, RANGE_Y = 30, 25
local marked, announced, status = {}, {}, "off"

local function tileKey(p) return p.x .. "," .. p.y .. "," .. p.z end

local function clearMarks()
  for key in pairs(marked) do
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    local tile = x and g_map.getTile({ x = tonumber(x), y = tonumber(y), z = tonumber(z) })
    if tile then pcall(function() tile:setText("") end) end
    marked[key] = nil
  end
end

local ghostMacro = macro(500, "Ghost watch", function()
  local me = g_game.getLocalPlayer()
  if not me then return end
  local found, stillMarked = {}, {}
  for _, c in ipairs(g_map.getSpectatorsInRange(me:getPosition(), false, RANGE_X, RANGE_Y)) do
    if (tonumber(c:getOutfit().type) or 0) == 0 and c:getId() ~= me:getId() then
      local p = c:getPosition()
      local name = c:getName()
      if p then
        local key = tileKey(p)
        local tile = g_map.getTile(p)
        if tile then
          pcall(function() tile:setText("GHOST\n" .. name, MARK_COLOR) end)
          stillMarked[key] = true
          marked[key] = true
        end
        found[#found + 1] = name
        if not announced[name] then
          announced[name] = true
          warning("[ghost] " .. name .. " is here in ghost mode (" .. p.x .. "," .. p.y .. "," .. p.z .. ")")
        end
      end
    end
  end
  -- tiles they have left
  for key in pairs(marked) do
    if not stillMarked[key] then
      local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
      local tile = x and g_map.getTile({ x = tonumber(x), y = tonumber(y), z = tonumber(z) })
      if tile then pcall(function() tile:setText("") end) end
      marked[key] = nil
    end
  end
  if #found > 0 then
    status = table.concat(found, ", ") .. " watching"
  else
    status = "clear"
    announced = {}                     -- let the next arrival announce itself again
  end
end)
ghostMacro.setOff()
clearMarks()

Features.register{ id = "ghostwatch", name = "Ghost watch", group = "Other", order = 80, macro = ghostMacro }

local statusLabel = UI.Label("Ghost watch: off")
macro(500, function()
  statusLabel:setText("Ghost watch: " .. (ghostMacro.isOn() and status or "off"))
end)

panel = tabPanel
