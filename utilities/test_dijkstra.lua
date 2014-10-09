require "addresses"
require "dijkstra"

-- utilities ---------------------------

function readbyte (addr)
  local offset = 1 + addr - 0x8000 + 16
  return rom:byte(offset)
end

function readword (addr)
  local offset = 1 + addr - 0x8000 + 16
  return rom:byte(offset+1)*256 + rom:byte(offset)
end

overworld_tiles = {}

overworld_tile_costs = { 1, 1, 2, 0,    -- grass, sand, hill, mountain
                         0, 0, 1, 3,    -- water, wall, tree, swamp
                         1, 1, 1, 1,    -- town, cave, castle, bridge
                         1, 0, 0, 0 }   -- stairs, unused?

town_tile_costs = { 1, 1, 0, 1,         -- grass, sand, water, chest
                    0, 1, 1, 1,         -- wall, upstairs, path, downstairs
                    1, 2, 3, 1,         -- tree, swamp, trap, door
                    0, 0, 1, 0 }        -- sign, sign, bridge, countertop

dungeon_tile_costs = { 0, 1, 1, 1,      -- wall, upstairs, path, downstairs
                       1, 1, 0, 0 }     -- chest, door, princess, unused?

function overworld_move_cost (x, y)
  if x < 0 or x > 0x77 or y < 0 or y > 0x77 then return 0 end
  return overworld_tiles[y*0x78 + x]
end

function get_move_fn (zone_ptr)
  if zone_ptr == addr.overworld then
    -- special handling for the overworld
    return overworld_move_cost
  else
    -- todo: describe how map data is stored in the rom
    local mask, cost_tbl
    if zone_ptr >= addr.mask_divider then
      mask = 8
    else
      mask = 16
    end
    if zone_ptr >= addr.dungeons_start then
      cost_tbl = dungeon_tile_costs
    else
      cost_tbl = town_tile_costs
    end

    -- get zone size
    local width, height
    for i=0x801f,0x80af,5 do
      if (readword(i) == zone_ptr) then
        width, height = readbyte(i+2), readbyte(i+3)
        break
      end
    end

    local stride = math.floor((width+1)/2)              -- "width" is actually "rightmost x"
    return function (x, y)
      if x < 0 or x > width or y < 0 or y > height then
        return 0
      end
      local t = math.floor(x/2)
      local k = readbyte(zone_ptr + y*stride + t)
      if (x % 2) == 0 then
        k = math.floor(k / 16)
      end
      k = k % mask
      return cost_tbl[1 + k]
    end
  end
end


-- main --------------------------------

-- read decompressed overworld
-- fd = io.open("overworld_map.dat", "rb")
-- overworld_tiles = fd:read("*a")
-- fd:close()

-- read the rom
local fd = io.open("dw.nes", "rb")
rom = fd:read("*a")
fd:close()

-- decompress the overworld
for y=0,0x77 do
  local row_ptr = readword(addr.overworld + y*2)
  local x, k = 0, nil
  while x <= 0x77 do
    k = readbyte(row_ptr)
    row_ptr = row_ptr + 1
    local w = (k % 16) + 1
    local v = math.floor(k / 16) % 16
    for t=1,w do
      local z = overworld_tile_costs[1 + v]
      overworld_tiles[y*0x78 + x] = z
      x = x + 1
    end
  end
end

local zone_ptr = arg[1] or string.format("%x", addr.overworld);  zone_ptr = tonumber(zone_ptr, 16)
local x1 = arg[2] or "43";  x1 = tonumber(x1, 10)
local y1 = arg[3] or "43";  y1 = tonumber(y1, 10)
local x2 = arg[4] or "73";  x2 = tonumber(x2, 10)
local y2 = arg[5] or "102";  y2 = tonumber(y2, 10)

local cost_fn = get_move_fn(zone_ptr)

print(os.clock())
local result = dijkstra.reverse_dijkstra(x1, y1, x2, y2, cost_fn, zone_ptr)
print(os.clock())

for y=0,0x77 do
  local ln = ""
  for x=0,0x77 do
    local v=result[y*200+x]
    if v then
      ln = ln .. string.format("%04x", v)
    else
      ln = ln .. "    "
    end
  end
  print(ln)
end

print(os.clock())
-- check caching
local result = dijkstra.reverse_dijkstra(x1, y1, x2, y2, cost_fn, zone_ptr)
print(os.clock())


--    function Account.withdraw (self, v)
--      self.balance = self.balance - v
--    end
