-- Module installer: lists the modules published at INDEX_URL, installs / updates / removes them into the
-- client's data directory (merged into the resource tree) and hot-loads them. No restart needed.

INDEX_URL = "https://otc-mods.github.io/pegaz-ots-mods/index.json"
REPO_URL = "https://github.com/otc-mods/pegaz-ots-mods"
ALLOWED_PREFIXES = { "modules/", "data/images/", "layouts/" }

local window, button
local index          -- decoded index.json
local installed = {} -- name -> { version=, files={path,...} }   (g_settings node 'moduleInstaller')
local busy = false
local rows = {}

-- state --------------------------------------------------------------------------------
local function load()
  local node = g_settings.getNode('moduleInstaller')
  installed = {}
  if type(node) == 'table' then
    for name, rec in pairs(node) do
      if type(rec) == 'table' then
        local files = {}
        if type(rec.files) == 'table' then for _, p in pairs(rec.files) do table.insert(files, p) end end
        installed[name] = { version = rec.version, files = files }
      end
    end
  end
end

local function save() g_settings.setNode('moduleInstaller', installed) end

local function setStatus(text, color)
  if not window then return end
  window.status:setText(text or "")
  window.status:setColor(color or '#ffffff')
end

local function safePath(p)
  if type(p) ~= 'string' or p:find("%.%.") or p:sub(1, 1) == "/" then return false end
  for _, pre in ipairs(ALLOWED_PREFIXES) do
    if p:sub(1, #pre) == pre then return true end
  end
  return false
end

local function ensureDirs(path)
  local acc = ""
  for seg in path:gmatch("[^/]+") do
    if seg:find("%.") and acc ~= "" and path:sub(-#seg) == seg then break end -- last segment = file
    acc = acc .. "/" .. seg
    -- always create: directoryExists also sees the client's own data/ and layouts/ folders, which do not exist
    -- in the write dir, and PhysFS refuses to write into a directory missing there
    g_resources.makeDir(acc)
  end
end

local function sha1(data)
  local ok, hex = pcall(function() return g_crypt.sha1Encode(data) end)
  if ok and type(hex) == 'string' then return hex:lower() end
  return nil
end

local function moduleState(entry)
  local m = g_modules.getModule(entry.name)
  local rec = installed[entry.name]
  if rec then
    if rec.version == entry.version then return "installed" else return "outdated" end
  end
  if m then return "bundled" end
  return "missing"
end

-- install / remove ------------------------------------------------------------------------------
local refreshRows

local function finishInstall(entry, paths)
  installed[entry.name] = { version = entry.version, files = paths }
  save()
  g_modules.discoverModules()
  local m = g_modules.getModule(entry.name)
  if m then
    if m:isLoaded() then m:reload() else g_modules.ensureModuleLoaded(entry.name) end
  end
  busy = false
  setStatus(entry.title .. " " .. entry.version .. " installed and loaded.", '#66ff66')
  refreshRows()
end

local function install(entry)
  if busy then return setStatus("busy, wait a moment", '#ffdd55') end
  if not g_game.isOnline() and false then return end
  local files = entry.files or {}
  if #files == 0 then return setStatus("nothing to install", '#ff5555') end
  for _, f in ipairs(files) do
    if not safePath(f.path) then return setStatus("refusing unexpected path: " .. tostring(f.path), '#ff5555') end
  end
  busy = true
  local paths = {}
  local i = 0
  local function nextFile()
    i = i + 1
    local f = files[i]
    if not f then return finishInstall(entry, paths) end
    setStatus(string.format("%s: downloading %d/%d %s", entry.title, i, #files, f.path))
    HTTP.get(index.base .. f.path, function(data, err)
      if err or type(data) ~= 'string' then
        busy = false
        return setStatus("download failed: " .. f.path .. " (" .. tostring(err) .. ")", '#ff5555')
      end
      if f.size and #data ~= f.size then
        busy = false
        return setStatus("size mismatch: " .. f.path, '#ff5555')
      end
      local h = f.sha1 and sha1(data)
      if h and h ~= f.sha1 then
        busy = false
        return setStatus("checksum mismatch: " .. f.path, '#ff5555')
      end
      ensureDirs(f.path)
      if not g_resources.writeFileContents("/" .. f.path, data) then
        busy = false
        return setStatus("cannot write: " .. f.path, '#ff5555')
      end
      table.insert(paths, f.path)
      nextFile()
    end)
  end
  nextFile()
end

local function remove(entry)
  if busy then return setStatus("busy, wait a moment", '#ffdd55') end
  local rec = installed[entry.name]
  if not rec then return end
  local m = g_modules.getModule(entry.name)
  if m and m:isLoaded() then m:unload() end
  local n = 0
  for _, p in ipairs(rec.files) do
    if g_resources.fileExists("/" .. p) and g_resources.deleteFile("/" .. p) then n = n + 1 end
  end
  installed[entry.name] = nil
  save()
  setStatus(entry.title .. " removed (" .. n .. " files deleted, empty folders stay).", '#ffdd55')
  refreshRows()
end

-- ui ---------------------------------------------------------------------------------------
refreshRows = function()
  if not window then return end
  window.list:destroyChildren()
  rows = {}
  if not index then return end
  for _, entry in ipairs(index.entries or {}) do
    local row = g_ui.createWidget('InstallerCard', window.list)
    local state = moduleState(entry)
    row.title:setText((entry.title or entry.name) .. "  (" .. entry.name .. ")")
    row.description:setText(entry.description or "")
    local rec = installed[entry.name]
    local vtext = "available " .. tostring(entry.version)
    if state == "installed" then vtext = "installed " .. rec.version .. ", up to date"
    elseif state == "outdated" then vtext = "installed " .. rec.version .. ", available " .. entry.version
    elseif state == "bundled" then vtext = ""
    end
    if entry.requires and #entry.requires > 0 then vtext = vtext .. (vtext ~= "" and "\n" or "") .. "needs: " .. table.concat(entry.requires, ", ") end
    row.buttons.install:setTooltip(vtext)
    if state == "installed" then
      row.buttons.install:setText("Reinstall")
    elseif state == "outdated" then
      row.buttons.install:setText("Update")
      row.buttons.install:setColor('#66ff66')
    else
      row.buttons.install:setText("Install")
    end
    row.buttons.install:setEnabled(state ~= "bundled")
    row.buttons.remove:setEnabled(state == "installed" or state == "outdated")
    row.buttons.install.onClick = function() install(entry) end
    row.buttons.remove.onClick = function() remove(entry) end
    if type(entry.screenshot) == 'string' and entry.screenshot:len() > 0 then
      local url = index.base .. entry.screenshot
      row.shotBox:setTooltip("click to enlarge")
      local iw, ih = 236, 132
      if type(entry.screenshotSize) == 'table' and tonumber(entry.screenshotSize[1]) and tonumber(entry.screenshotSize[2]) then
        iw, ih = tonumber(entry.screenshotSize[1]), tonumber(entry.screenshotSize[2])
      end
      HTTP.downloadImage(url, function(path, err)
        if err or not path or row:isDestroyed() or not row.shotBox then return end -- list may have been rebuilt meanwhile
        row.shotBox.noShot:hide()
        -- whole picture, proportions kept, never cropped: fit into the box, never upscaled
        local scale = math.min(236 / iw, 132 / ih, 1)
        row.shotBox.shot:setSize({ width = math.floor(iw * scale), height = math.floor(ih * scale) })
        row.shotBox.shot:setImageSource(path)
        row.shotBox.onMouseRelease = function(widget, mousePos, mouseButton)
          if mouseButton ~= MouseLeftButton then return false end
          local root = g_ui.getRootWidget()
          local maxW, maxH = root:getWidth() - 80, root:getHeight() - 120
          local s = math.min(1, maxW / iw, maxH / ih) -- native size when it fits, else scaled down
          local pw, ph = math.floor(iw * s), math.floor(ih * s)
          local w = g_ui.createWidget('InstallerPreview', root)
          w:setText(entry.title or entry.name)
          w:setSize({ width = pw + 40, height = ph + 80 })
          w.image:setSize({ width = pw, height = ph })
          w.image:setImageSource(path)
          w:show() w:raise() w:focus()
          return true
        end
      end)
    end
    rows[entry.name] = row
  end
end

function fetchIndex()
  if not window then return end
  setStatus("fetching list...")
  HTTP.getJSON(INDEX_URL .. "?t=" .. os.time(), function(data, err)
    if err or type(data) ~= 'table' or type(data.entries) ~= 'table' then
      index = nil
      refreshRows()
      return setStatus("cannot read the module list: " .. tostring(err or "bad format"), '#ff5555')
    end
    index = data
    if type(index.base) ~= 'string' then index.base = INDEX_URL:gsub("index%.json.*$", "") end
    refreshRows()
    setStatus(#index.entries .. " module(s) listed.")
  end)
end

function openRepo()
  g_platform.openUrl(REPO_URL)
end

function show()
  window:show()
  window:raise()
  window:focus()
  if button then button:setOn(true) end
  fetchIndex()
end

function hide()
  window:hide()
  if button then button:setOn(false) end
end

function toggle()
  if window:isVisible() then hide() else show() end
end

function init()
  load()
  window = g_ui.displayUI('installer')
  window:hide()
  button = modules.client_topmenu.addRightGameToggleButton('moduleInstallerButton', tr('Modules'), '/images/topbuttons/modulemanager', toggle, false, 1005)
  button:setOn(false)
  window.refresh.onClick = fetchIndex
  window.onClose = hide
end

function terminate()
  if button then button:destroy() button = nil end
  if window then window:destroy() window = nil end
end
