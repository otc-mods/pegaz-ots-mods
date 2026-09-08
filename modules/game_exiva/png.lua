-- Minimal PNG writer for the overlay: 8-bit RGBA, white pixels with a per-pixel alpha, zlib "stored"
-- blocks (no compression - the image is small and the client tints it through image-color).
ExivaPNG = {}

local floor = math.floor
local schar, sbyte, concat = string.char, string.byte, table.concat
local bitlib = bit or _G.bit
local band, bxor, rshift = bitlib.band, bitlib.bxor, bitlib.rshift

local crcTable

local function crc32(s)
  if not crcTable then
    crcTable = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if band(c, 1) == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
      end
      crcTable[i] = c
    end
  end
  local crc = 0xFFFFFFFF
  for i = 1, #s do
    crc = bxor(crcTable[band(bxor(crc, sbyte(s, i)), 0xFF)], rshift(crc, 8))
  end
  return bxor(crc, 0xFFFFFFFF)
end

local function u32(n)
  n = n % 4294967296
  return schar(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

local function chunk(kind, data)
  return u32(#data) .. kind .. data .. u32(crc32(kind .. data))
end

local function adler32(s)
  local a, b = 1, 0
  local n, i = #s, 1
  while i <= n do
    local stop = math.min(i + 3999, n)
    for j = i, stop do
      a = a + sbyte(s, j)
      b = b + a
    end
    a, b = a % 65521, b % 65521
    i = stop + 1
  end
  return b * 65536 + a
end

local function zlibStored(raw)
  local parts = { schar(0x78, 0x01) }
  local n, pos = #raw, 1
  repeat
    local len = math.min(65535, n - pos + 1)
    local final = (pos + len > n) and 1 or 0
    parts[#parts + 1] = schar(final, len % 256, floor(len / 256), (65535 - len) % 256, floor((65535 - len) / 256))
    parts[#parts + 1] = raw:sub(pos, pos + len - 1)
    pos = pos + len
  until pos > n
  parts[#parts + 1] = u32(adler32(raw))
  return concat(parts)
end

-- alphaAt(x, y) -> 0..255 for x in 0..w-1, y in 0..h-1
function ExivaPNG.encode(w, h, alphaAt)
  local px = {}
  for a = 0, 255 do px[a] = schar(255, 255, 255, a) end
  local rows = {}
  for y = 0, h - 1 do
    local row = { "\0" }
    for x = 0, w - 1 do row[#row + 1] = px[alphaAt(x, y)] end
    rows[#rows + 1] = concat(row)
  end
  local ihdr = u32(w) .. u32(h) .. schar(8, 6, 0, 0, 0)
  return "\137PNG\r\n\26\n" .. chunk("IHDR", ihdr) .. chunk("IDAT", zlibStored(concat(rows))) .. chunk("IEND", "")
end
