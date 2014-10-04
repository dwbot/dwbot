------------------------------------------------------------
-- Play and beat Dragon Warrior
--
-- Use FCEUX 2.2.2+ and Dragon Warrior (U) (PRG 0)
--   (ROM MD5:  0xe8382f82570bc616b0bcc02c843c1b79)
------------------------------------------------------------

require "addresses"
require "dijkstra"
require "monsters"

----------------------------------------
-- globals
----------------------------------------

show_time = true                        -- if set, draw the time for the current run in the GUI
yolo = false                            -- if set, the bot doesn't do any safety-saving

dir_button = {e="right", s="down", w="left", n="up"}
reserved_mp = 0
goldmen = nil
last_goldman = nil
found_stairs = false                    -- whether we already revealed the stairs in charlock

----------------------------------------
-- utilities
----------------------------------------

-- format hours/minutes/seconds
function format_time (nframe)
  local hrs = math.floor(nframe / (60*60*60))
  local mins = math.floor(nframe / (60*60)) % 60
  local secs = (nframe % 3600) / 60
  return string.format("%d:%02d:%05.2f", hrs, mins, secs)
end

-- extract numbers from a string
function get_numbers (s)
  r = {}
  for d in string.gmatch(s, "%d+") do
    r[#r+1] = tonumber(d)
  end
  return r
end

-- turn an address into a direct ROM pointer
function rom_ptr (a)
  return a - addr.rom + 16
end

-- not defined in the rom module, annoyingly
function rom.readwordunsigned (a)
  return rom.readbyteunsigned(a+1)*256 + rom.readbyteunsigned(a)
end

-- look at the top word on the stack
function peek_stack_w (offset)
  offset = offset or 0
  return memory.readwordunsigned(0x101 + offset + memory.getregister("s"))
end

-- set the rng
function set_rng (rng)
  memory.writebyte(addr.rng_lo, rng % 256)
  memory.writebyte(addr.rng_hi, math.floor(rng / 256))
end

-- wait n frames
function wait (n)
  for i=1,n do
    coroutine.yield("frameadvance")
  end
end

-- tap a button on the joypad then release
function tap (k)
  local a={}
  a[k]=true
  joypad.set(1,a)
  coroutine.yield("frameadvance")
  coroutine.yield("frameadvance")
end

-- advance a frame while holding down a particular button
function hold (k)
  local a={}
  a[k] = true
  joypad.set(1,a)
  coroutine.yield("frameadvance")
end

-- iterate over NPCs
function npcs (start_n, end_n)
  local start_ptr = start_n*3
  local end_ptr = end_n*3
  local iter_fn = function()
    if start_ptr >= end_ptr then return end
    local cx = memory.readwordunsigned(addr.npc_tbl_start+start_ptr) % 0x20
    local cy = memory.readwordunsigned(addr.npc_tbl_start+start_ptr+1) % 0x20
    start_ptr = start_ptr + 3
    return cx, cy
  end

  return iter_fn, 0, 0
end

-- IMPORTANT: the following tables assume you can move through doors.
-- the script must ensure the door is open before attempting to move
-- through it.
-- FIXME: take the different encounter rates for each tile into account
--        for the move cost function?
overworld_tile_costs = { 1, 1, 2, 0,    -- grass, sand, hill, mountain
                         0, 0, 1, 3,    -- water, wall, tree, swamp
                         2, 1, 2, 1,    -- town, cave, castle, bridge
                         1, 0, 0, 0 }   -- stairs, unused?

town_tile_costs = { 1, 1, 0, 1,         -- grass, sand, water, chest
                    0, 1, 1, 1,         -- wall, upstairs, path, downstairs
                    1, 2, 3, 1,         -- tree, swamp, trap, door
                    0, 0, 1, 0 }        -- sign, sign, bridge, countertop

dungeon_tile_costs = { 0, 1, 1, 1,      -- wall, upstairs, path, downstairs
                       1, 1, 0, 0 }     -- chest, door, princess, unused?

overworld_map = {}
overworld_width = 0x78
overworld_height = 0x78

-- The overworld map is stored in the rom in an RLE-compressed format.
-- First is a table of 120 pointers that points to the compressed row
-- data for each row.  For each byte in the row, the upper nibble
-- contains the tile number, and the lower nibble contains the length
-- of the run minus one.  e.g.
--   21 (hex)
-- means "two copies of the hill tile"
function decompress_overworld_map ()
  for y=0,overworld_height-1 do
    local y_ptr = rom_ptr(addr.overworld + y*2)
    local row_ptr = rom_ptr(rom.readwordunsigned(y_ptr))
    local x, k = 0, nil
    while x < overworld_width do
      k = rom.readbyteunsigned(row_ptr)
      row_ptr = row_ptr + 1
      local w = (k % 16) + 1
      local v = math.floor(k / 16) % 16
      for t=1,w do
        local z = overworld_tile_costs[1 + v]
        overworld_map[1 + y*overworld_width + x] = z
        x = x + 1
      end
    end
  end
end

function overworld_move_fn (x, y)
  if x < 0 or x >= overworld_width or y < 0 or y >= overworld_height then
    return 0
  end
  return overworld_map[1 + y*overworld_width + x]
end

-- list of zones that have NPCs we may collide against
npc_zones = {}
npc_zones[addr.tantegel] = true
npc_zones[addr.tantegel_throne_room] = true
npc_zones[addr.kol] = true
npc_zones[addr.brecconary] = true
npc_zones[addr.garinham] = true
npc_zones[addr.cantlin] = true
npc_zones[addr.rimuldar] = true
npc_zones[addr.tantegel_b1] = true

-- returns the function that computes move cost for a*
function get_move_fn (zone_ptr)
  if zone_ptr == addr.overworld then
    -- special handling for the overworld
    return overworld_move_fn
  else
    local mask, cost_tbl
    -- Map tiles are stored in the rom packed into nibbles.  i.e., each byte contains
    -- a pair of tiles, and the upper nibble contains the left tile number and the lower
    -- nibble contains the right tile number.  Certain maps use only 3 bits of the nibble
    -- to represent a tile number (i.e., tiles 0-7).
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
    local npc_tbl = nil
    if npc_zones[zone_ptr] then
      -- collide with stationary NPCs (numbers 10-20)
      npc_tbl = {}
      for cx,cy in npcs(10,20) do
        npc_tbl[cx .. "," .. cy] = true
      end
    end

    local width = memory.readbyteunsigned(addr.map_width)
    local height = memory.readbyteunsigned(addr.map_height)
    local stride = math.floor((width+1)/2)              -- "width" is actually "rightmost x"
    local ptr = rom_ptr(zone_ptr)
    return function (x, y)
      if x < 0 or x > width or y < 0 or y > height then
        return 0
      end
      if npc_tbl and npc_tbl[x .. "," .. y] then
        return 0
      end
      local t = math.floor(x/2)
      local k = rom.readbyteunsigned(ptr + y*stride + t)
      if (x % 2) == 0 then
        k = math.floor(k / 16)
      end
      k = k % mask
      return cost_tbl[1 + k]
    end
  end
end

-- run the game until it's safe to move again
function clear_to_move ()
  -- wait until it's clear to move
  local r = peek_stack_w()
  while (r ~= addr.end_of_dialog and
         r ~= addr.end_of_dialog2 and
         r ~= addr.standing_still and
         r ~= addr.battle_start) do
    coroutine.yield("frameadvance")
    r = peek_stack_w()
  end

  if r == addr.end_of_dialog2 then
    tap("A")
  end

  return r
end

-- an NPC is permanently stuck.  move back and
-- wait for them to get out of the way.
function get_unstuck(x, y, move_back_to, ...)
  script("move " .. move_back_to)

  reserved_spots = {}
  for i=1,#arg do
    reserved_spots[arg[i]] = true
  end

  while true do
    still_stuck = false
    for cx,cy in npcs(0,10) do
      if reserved_spots[cx .. "," .. cy] then
        still_stuck = true
      end
    end

    if still_stuck then
      coroutine.yield("frameadvance")
    else
      break
    end
  end

  script("move " .. x .. "," .. y)
end

-- certain NPCs can block us permanently
function check_for_stuck_npcs (zone_ptr, x, y, dir)
  if not npc_zones[zone_ptr] then return end

  if zone_ptr == addr.tantegel_throne_room then
    local lvl = memory.readbyteunsigned(addr.player_level)
    -- throne room, in front of the door
    if lvl == 1 and x == 4 and y == 6 then
      get_unstuck(x, y, "5,5", "4,6", "4,5")
    end
    -- throne room, in front of the stairs
    if lvl > 1 and y == 8 and dir == "e" then
      get_unstuck(x, y, "3,8", "4,8", "5,8", "6,8", "7,8", "8,8")
    end
  end

  -- kol, in front of the tool shop
  if zone_ptr == addr.kol and x == 12 and y == 21 then
    get_unstuck(x, y, "8,21", "9,21", "10,21", "11,21", "12,21")
  end

  -- brecconary, in the doorway of the tool shop
  if zone_ptr == addr.brecconary and x == 22 and y == 23 and dir == "s" then
    get_unstuck(x, y, "22,21", "22,22", "22,23")
  end
end

function move_to (x2, y2, stop_to_fight, dont_wait)

  local r
  if dont_wait then
    r = peek_stack_w()
  else
    local r = clear_to_move()
  end

  local x = memory.readbyteunsigned(addr.player_x)
  local y = memory.readbyteunsigned(addr.player_y)
  local zone_ptr = memory.readwordunsigned(addr.zone_ptr)
  local cost_fn = get_move_fn(zone_ptr)
  local map = dijkstra.reverse_dijkstra(x, y, x2, y2, cost_fn, zone_ptr)
  local dxs = {1,0,-1,0}
  local dys = {0,1,0,-1}
  local dirs = {"e","s","w","n"}

  while x ~= x2 or y ~= y2 do
    -- find our new target square
    local best = nil
    for i=1,4 do
      local nx = x + dxs[i]
      local ny = y + dys[i]
      local dir = dirs[i]
      local blocked = false

      -- is this square blocked by an NPC?
      if npc_zones[zone_ptr] then
        for cx,cy in npcs(0,10) do
          if cx == nx and cy == ny then
            blocked = true
            break
          end
        end
      end

      -- choose lower-distance squares over higher-distance ones.
      -- or choose unblocked squares over blocked squares if they have the same distance.
      local ndist = map[ny*200+nx]
      if ndist then
        if not best or ndist < best.dist or (ndist == best.dist and ((not blocked) and best.blocked)) then
          best = { dist=ndist, blocked=blocked, dir=dir, x=nx, y=ny }
        end
      end
    end

    blocked, dir, x, y = best.blocked, best.dir, best.x, best.y

    -- check for stuck NPCs
    if blocked then
      check_for_stuck_npcs(zone_ptr, x, y, dir)
    end

    repeat
      if (r == addr.battle_start) then
        if (not stop_to_fight) then
          run_away()
        else
          return false                                    -- false = move stopped due to battle
        end
      elseif (r == addr.end_of_dialog) or (r == addr.end_of_dialog2) then
        tap("A")                                          -- fairy water ran out
      else
        hold(dir_button[dir])
      end
      r = peek_stack_w()
    until (memory.readbyteunsigned(addr.player_x) == x and
           memory.readbyteunsigned(addr.player_y) == y)
  end

  return true           -- true = move completed
end

-- move to a point and stay healthy
function move_heal (x, y, min_hp, emergency_hp)
  local heal_and_run = function()
    local monster_num = memory.readbyteunsigned(addr.monster_number)
    local monster = monsters[1 + monster_num]
    local run_fn = run_strategy[monster.name]
    local cmd
    repeat
      local me = get_player_vars()
      if emergency_hp and me.player_current_hp <= emergency_hp and can_use_herb() then
        cmd = "use herb"
      elseif emergency_hp and me.player_current_hp <= emergency_hp and can_cast(me, "heal") then
        cmd = "cast heal"
      elseif run_fn then
        cmd = run_fn(me, monster)
      else
        cmd = "run"
      end
    until battle_command(cmd) == true
  end

  local stay_healthy = function ()
    while true do               -- keep healing as long as needed
      -- do we need to heal?
      local me = get_player_vars()
      local do_heal = nil
      if can_cast(me, "heal") and ((me.player_current_hp < min_hp) or ((me.player_max_hp - me.player_current_hp) >= 17)) then
        do_heal = "cast heal"
      elseif can_use_herb() and ((me.player_current_hp < min_hp) or ((me.player_max_hp - me.player_current_hp) >= 38)) then
        do_heal = "use herb"
      end
      
      if do_heal then
        script(do_heal)
      else
        break
      end
    end                         -- loop back around and heal again
  end

  -- start healthy
  stay_healthy()

  -- do the move
  while not move_to(x, y, true, false) do
    heal_and_run()
    stay_healthy()
  end

  -- make sure we haven't got into a battle on the last tile
  local r = clear_to_move()
  if r == addr.battle_start then
    heal_and_run()
    stay_healthy()
  end
end

-- face a certain direction (used to face shopkeepers/doors/etc)
function face(dir)
  local dirs = {"n","e","s","w"}
  local current_facing = memory.readbyteunsigned(addr.player_facing)
  if dirs[1 + current_facing] == dir then return end            -- already facing this way

  while (peek_stack_w() ~= addr.standing_still) do
    coroutine.yield("frameadvance")
  end
  tap(dir_button[dir])
end

-- mash dialog prompts until we hit the end or a menu pops up
function mash_dialog ()
  while true do
    local r = peek_stack_w()
    if r == addr.end_of_dialog then break
    elseif r == addr.end_of_dialog2 then break
    elseif r == addr.standing_still then break -- no menu
    elseif r == addr.menu_loop then break     -- menu has popped up
    elseif r == addr.more_dialog then         -- prompt for more dialog
      tap("A")
    else
      coroutine.yield("frameadvance")
    end
  end

  if peek_stack_w() == addr.end_of_dialog2 then
    tap("A")
  end
end

menu_commands = { -- normal command menu
                  talk = { 0, 0 },   spell = { 1, 0 },
                  status = { 0, 1 }, item = { 1, 1 },
                  stairs = { 0, 2 }, door = { 1, 2 },
                  search = { 0, 3 }, take = { 1, 3 },
                  -- yes/no
                  yes = { 0, 0 },    no = { 0, 1 },
                  -- buy/sell
                  buy = { 0, 0 },    sell = { 0, 1 },
                  -- battle menu
                  fight = { 0, 0 },  -- spell = { 1, 0 },       -- spell is same as above
                  run = { 0, 1 },    -- item = { 1, 1 },        -- item is same as above
                  -- spells
                  heal = { 0, 0 },
                  hurt = { 0, 1 },
                  sleep = { 0, 2 },
                  radiant = { 0, 3 },
                  stopspell = { 0, 4 },
                  outside = { 0, 5 },
                  -- return = { 0, 6 },                      -- "return" is a keyword
                  repel = { 0, 7 },
                  healmore = { 0, 8 },
                  hurtmore = { 0, 9 } }
menu_commands["return"] = { 0, 6 }

-- select an item from the menu
function menu_select (x, y)
  if type(x) == "string" then
    x, y = unpack(menu_commands[x])
  end
  -- move the cursor to the item
  while memory.readbyteunsigned(addr.cursor_x) < x do
    tap("right")
  end
  while memory.readbyteunsigned(addr.cursor_y) < y do
    tap("down")
  end
  repeat
    hold("A")           -- then select it
  until peek_stack_w() ~= addr.menu_loop
end

-- open the menu before issuing a command
function open_menu ()
  local r = peek_stack_w()
  while r ~= addr.menu_loop do
    hold("A")
    r = peek_stack_w()
  end
end

--         name        lv      mp
spells = {"heal         3       4",
          "hurt         4       2",
          "sleep        7       2",
          "radiant      9       3",
          "stopspell   10       2",
          "outside     12       6",
          "return      13       8",
          "repel       15       2",
          "healmore    17      10",
          "hurtmore    19       5"}

-- have we got the spell and the mp to use it?
function can_cast (me, spell)
  local level, mp
  for i=1,#spells do
    if string.sub(spells[i],1,#spell) == spell then
      level, mp = unpack(get_numbers(spells[i]))
      break
    end
  end

  if me.player_level < level or me.player_current_mp < (mp + reserved_mp) then
    return false
  end
  return true
end

-- have we got an herb?
function can_use_herb ()
  if num_herbs() < 1 then return false end
  return true
end

local items_table = ("herb            " ..
                     "torch           " ..              -- 1
                     "fairy water     " ..
                     "wings           " ..
                     "dragon's scale  " ..
                     "fairy flute     " ..
                     "fighter's ring  " ..
                     "erdrick's token " ..
                     "gwaelin's love  " ..
                     "cursed belt     " ..
                     "silver harp     " ..
                     "death necklace  " ..
                     "stones of sun   " ..
                     "staff of rain   " ..
                     "rainbow drop    ")                -- e

-- returns the first index in the inventory for the named item
function get_inventory_index (item_name)
  local idx = 0

  -- herbs always appear first
  if item_name == "herb" then
    if num_herbs() < 1 then return end
    return idx
  elseif num_herbs() > 0 then
    idx = idx + 1
  end

  -- magic keys always appear after herbs
  if item_name == "magic key" then
    if num_keys() < 1 then return end
    return idx
  elseif num_keys() > 0 then
    idx = idx + 1
  end

  local item_number = string.find(items_table, item_name, 1, true)
  assert(item_number, "Don't know what item " .. item_name .. " is!")
  item_number = math.floor(item_number / 16)

  for i=addr.inventory_start,addr.inventory_end do
    -- item numbers are packed into nibbles
    local v = memory.readbyteunsigned(i)

    if (v % 16) == item_number then
      return idx
    elseif (v % 16) > 0 then
      idx = idx + 1                     -- only count occupied slots
    end

    if math.floor(v / 16) == item_number then
      return idx
    elseif math.floor(v / 16) > 0 then
      idx = idx + 1                     -- only count occupied slots
    end
  end
end

-- script interpreter
--   move x,y                           move to the specified coordinates, running from battles along the way
--   moveheal x,y,min_hp,emergency_hp   same as above but heal along the way, trying to stay alive with healing
--   fairy water                        use some fairy water if we have it
--   command <cmd>                      open the command menu and select the named command
--   select <name or coordinates>       select a menu option by name or coordinate
--   exit <dir>                         exit a zone by moving in the specified direction
--   face <dir>                         turn to face a direction (used for shopping/doors/etc)
--   wait <n>                           wait n frames
--   tap <button>                       tap a button
--   mash                               mash dialog
--   cast <spell>                       cast a spell by name
--   use <item>                         open the "item" menu and use the specified item
function script (...)
  for i,v in ipairs(arg) do
    if string.sub(v,1,5) == "move " then
      -- move to x,y
      local x, y = unpack(get_numbers(v))
      move_to(x, y, false, false)
    elseif string.sub(v,1,8) == "moveheal" then
      -- move to x,y
      local x, y, min_hp, emergency_hp = unpack(get_numbers(v))
      move_heal(x, y, min_hp, emergency_hp)
    elseif string.sub(v,1,11) == "fairy water" then             -- use fairy water if we have it
      local item_index = get_inventory_index("fairy water")
      if item_index then
        script("command item")
        menu_select(0, item_index)
      end
    elseif string.sub(v,1,7) == "command" then
      -- "command" opens the command menu then selects an option
      open_menu()
      script("select " .. string.sub(v,9))
    elseif string.sub(v,1,6) == "select" then
      -- select a menu command by name or number
      local which = get_numbers(v)
      if #which > 0 then
        menu_select(unpack(which))              -- coordinates
      else
        menu_select(string.sub(v,8))            -- named option
      end
      mash_dialog()             -- we almost always have to mash dialog after a menu command
    elseif string.sub(v,1,4) == "exit" then
      -- exit the zone
      local dir = string.sub(v,6)
      repeat
        hold(dir_button[dir])
      until peek_stack_w() == addr.zone_out
      clear_to_move()
    elseif string.sub(v,1,4) == "face" then
      -- face this direction
      local dir = string.sub(v,6)
      face(dir)
    elseif string.sub(v,1,4) == "wait" then
      -- wait n frames
      local n = tonumber(string.sub(v,6))
      wait(n)
    elseif string.sub(v,1,3) == "tap" then
      -- tap a direction
      local dir = string.sub(v,5)
      tap(dir)
    elseif string.sub(v,1,4) == "mash" then
      mash_dialog()
    elseif string.sub(v,1,4) == "cast" then
      local spell_name = string.sub(v,6)
      script("command spell", "select " .. spell_name)
    elseif string.sub(v,1,3) == "use" then
      local item_name = string.sub(v,5)
      script("command item")
      local item_index = get_inventory_index(item_name)
      assert(item_index, "Tried to use " .. item_name .. " but we have none!")
      menu_select(0, item_index)
      mash_dialog()             -- we almost always have to mash dialog after a menu command
    else
      assert(false, "Unrecognized script command: " .. v)             -- bomb on unrecognized commands
    end
  end
end

-- returns the number of herbs in our inventory
function num_herbs ()
  return memory.readbyteunsigned(addr.herbs)
end

-- returns the number of magic keys in our inventory
function num_keys ()
  return memory.readbyteunsigned(addr.keys)
end

-- returns the number of items we have in our inventory
function num_items_in_inventory (which)
  local result = 0
  for i=addr.inventory_start,addr.inventory_end do
    -- item numbers are packed into nibbles
    local v = memory.readbyteunsigned(i)

    if (v % 16) == which then result = result + 1 end
    if math.floor(v / 16) == which then result = result + 1 end
  end
  return result
end

-- returns the number of empty invetory slots.
-- (not counting keys or herbs)
function num_empty_slots ()
  return num_items_in_inventory(0)
end

-- returns how many fairy waters we have.
function num_fairy_water ()
  return num_items_in_inventory(2)
end

-- reads a set of variables from RAM at once
function get_vars(...)
  local result = {}
  for i,v in ipairs(arg) do
    -- special naming is used to distinguish word vars from byte vars
    if string.sub(v,-2) == "_w" then
      result[v] = memory.readwordunsigned(addr[v])
    else
      result[v] = memory.readbyteunsigned(addr[v])
    end
  end
  return result
end

-- get common player variables
function get_player_vars ()
  return get_vars("player_exp_w", "player_gold_w",
                  "player_current_hp", "player_max_hp",
                  "player_current_mp", "player_max_mp",
                  "player_level")
end

-- get monster status flags (sleep, stopspell'd)
function get_monster_flag (flag)
  local m_flags = memory.readbyteunsigned(addr.enemy_flags)
  local div

  if flag == "stopspell" then
    div = 32
  elseif flag == "sleep" then
    div = 64
  else
    assert(false, "Unknown monster flag: " .. flag)
  end

  return math.floor(m_flags / div) % 2
end

-- wait for the fairy water vendor in brecconary to move
-- to the spot where we can talk to her.
function wait_for_fairy_water_vendor ()
  while true do
    for cx,cy in npcs(0,10) do
      if cx == 24 and cy == 4 then return end
    end
    coroutine.yield("frameadvance")
  end
end

function respawn_after_death ()
  script("wait 386", "tap A",                               -- wait for the death message
         "wait 90", "tap A", "mash",                        -- chat with the king
         "move 8,8", "command stairs",                      -- leave the throne room
         "move 10,29", "exit s")                            -- leave tantegel
end

-- returns true if we have a prob% chance to kill
-- the monster with the next attack.
-- caveats: does not take into account the monster's
-- dodge chance, nor does it correctly handle monsters
-- that heal themselves.
function chip_damage (prob, damage_dealt)
  local prob_sq = math.sqrt(prob)
  local player_atk = memory.readbyteunsigned(addr.player_atk)
  local monster_agi = memory.readbyteunsigned(addr.monster_agi)
  local monster_max_hp = memory.readbyteunsigned(addr.monster_max_hp)
  local pow_diff = player_atk - math.floor(monster_agi / 2)
  if pow_diff < 2 then
    return false                -- minimal damage
  end

  -- figure out (prob^0.5) chance the monster has <= N hp
  -- and (prob^0.5) chance we do >= N damage with our next attack

  -- monster hp = max_hp - ((rng*max_hp)>>8)>>2
  local prob_rng = math.floor((1-prob_sq)*256)
  local prob_hp = monster_max_hp - math.floor(prob_rng * monster_max_hp / 1024) - damage_dealt

  -- damage formula is:
  --   (((rng*(pow_diff+1))>>8) + pow_diff) >> 2
  -- where rng is 0-255
  local prob_rng = math.floor((1-prob_sq)*256)
  local rng_roll = math.floor(prob_rng * (pow_diff+1) / 256)
  local prob_dmg = math.floor((rng_roll + pow_diff) / 4)

  return prob_dmg >= prob_hp
end

-- compute the melee damage we have against the current monster.
-- (min roll, max roll)
function get_player_melee_damage ()
  local player_atk = memory.readbyteunsigned(addr.player_atk)
  local monster_agi = memory.readbyteunsigned(addr.monster_agi)
  local pow_diff = player_atk - math.floor(monster_agi / 2)
  if pow_diff < 2 then
    return 0, 1                 -- minimal damage 0-1
  end

  -- damage formula is:
  --   (((rng*(pow_diff+1))>>8) + pow_diff) >> 2
  -- where rng is 0-255
  local lo_roll = math.floor(pow_diff / 4)
  local rng_roll = math.floor(255 * (pow_diff+1) / 256)
  local hi_roll = math.floor((rng_roll + pow_diff) / 4)
  return lo_roll, hi_roll
end

-- compute the melee damage the monster can do against us.
-- (min roll, max roll)
function get_monster_melee_damage ()
  local player_def = memory.readbyteunsigned(addr.player_def)
  local monster_str = memory.readbyteunsigned(addr.monster_str)
  local monster_pow = math.floor(monster_str / 2) + 1
  local pow_diff = monster_str - math.floor(player_def / 2)
  if pow_diff < monster_pow then
    -- minimal damage
    local rng_roll = math.floor(255 * monster_pow / 256) + 2
    return 0, math.floor(rng_roll / 3)
  end

  -- damage formula is the same as above
  local lo_roll = math.floor(pow_diff / 4)
  local rng_roll = math.floor(255 * (pow_diff+1) / 256)
  local hi_roll = math.floor((rng_roll + pow_diff) / 4)
  return lo_roll, hi_roll
end

-- run function fn in a sub-thread until it either
-- completes or exits out because the player died.
function catch_deaths(fn)
  local co = coroutine.create(fn)
  while true do
    local r1, r2, r3 = coroutine.resume(co)

    if r1 and not r2 then
      return "done"                                     -- fn completed successfully
    elseif r2 == "dead" then
      return "dead"                                     -- fn exited because of a death
    elseif r2 == "frameadvance" then
      -- a quirk of FCEUX: only the main thread can call emu.frameadvance.
      -- so here we propagate the frameadvance signal up the stack and
      -- let the main thread handle it.
      coroutine.yield("frameadvance")
    else
      -- error.  bomb out
      assert(false, r2)
    end
  end
end

----------------------------------------
-- battle
----------------------------------------

-- issue a battle command.  returns true if the battle completed.
function battle_command (cmd)
  while true do
    local r = peek_stack_w()
    if memory.readbyteunsigned(addr.player_current_hp) == 0 then
      -- cancel the script if the player dies
      coroutine.yield("dead")
    elseif (r == addr.menu_loop) and (not cmd) then
      -- battle not complete; need another command
      return false              
    elseif (r == addr.menu_loop) then
      if string.sub(cmd,1,4) == "cast" then
        menu_select("spell")
        while peek_stack_w() ~= addr.menu_loop do coroutine.yield("frameadvance") end
        menu_select(string.sub(cmd,6))
      elseif string.sub(cmd,1,3) == "use" then
        menu_select("item")
        while peek_stack_w() ~= addr.menu_loop do coroutine.yield("frameadvance") end
        local item_index = get_inventory_index(string.sub(cmd,5))
        menu_select(0,item_index)
      else
        menu_select(cmd)
      end
      cmd = nil
    elseif (r == addr.more_dialog) then
      mash_dialog()
    elseif (r == addr.standing_still) or (r == addr.battle_successful) then
      -- battle complete
      return true
    else
      coroutine.yield("frameadvance")
    end
  end
end

function run_away ()
  local monster_num = memory.readbyteunsigned(addr.monster_number)
  local monster = monsters[1 + monster_num]
  local run_fn = run_strategy[monster.name]

  if run_fn then
    local cmd = nil
    while battle_command(cmd) do
      local me = get_player_vars()
      cmd = run_fn(me, monster)
    end
  else
    repeat until battle_command("run") == true           -- keep running until successful
  end
end

function fight_monster ()
  local monster_num = memory.readbyteunsigned(addr.monster_number)
  local monster = monsters[1 + monster_num]
  local monster_start_hp
  local strategy_fn = battle_strategy[monster.name]

  -- no strategy = run instead
  if not strategy_fn then
    return run_away()
  end

  local cmd = nil                                       -- do nothing at first.  gives the monster a chance to run from us.
  monster.damage_dealt = nil                            -- reset damage dealt from previous battles
  local last_hp = nil
  while not battle_command(cmd) do                      -- issue commands until the battle ends
    -- pretend we don't know how much hp a monster has.
    -- instead, keep track of how much damage we've dealt.
    local monster_hp = memory.readbyteunsigned(addr.monster_hp)
    if not last_hp then
      last_hp = monster_hp
      monster.damage_dealt = 0
    elseif monster_hp < last_hp then
      monster.damage_dealt = monster.damage_dealt + (last_hp - monster_hp)
      last_hp = monster_hp
    else
      last_hp = monster_hp
    end

    local me = get_player_vars()
    cmd = strategy_fn(me, monster)
  end
end

-- walk back and forth between points until we die
function death_warp(points)
  local pt_idx = 1
  local pt_incr = 2
  points = get_numbers(points)

  local fight_until_dead = function()
    while true do
      if move_to(points[pt_idx], points[pt_idx + 1], true, true) then
        -- move successful.  switch directions
        if (pt_idx + pt_incr) >= #points or (pt_idx + pt_incr) < 1 then
          pt_incr = -pt_incr
        end
        pt_idx = pt_idx + pt_incr
      else
        -- fight!
        repeat until battle_command("fight")
      end
    end
  end

  -- ignore the result code, because fight_until_dead can
  -- only end in death.
  catch_deaths(fight_until_dead)

  script("wait 386", "tap A",                               -- wait for the death message
         "wait 90", "tap A", "mash")                        -- chat with the king
end

-- common function used by fight_axe_knight and fight_golem
function start_fight (dir)
  while true do
    -- start fully healed
    local me = get_player_vars()
    while me.player_current_hp < me.player_max_hp do
      if me.player_current_mp < 4 then
        coroutine.yield("dead")         -- give up
      end
      script("cast heal")
      me = get_player_vars()
    end

    -- start the fight
    local x = memory.readbyteunsigned(addr.player_x)
    local y = memory.readbyteunsigned(addr.player_y)

    repeat
      hold(dir)
    until (memory.readbyteunsigned(addr.player_x) ~= x or
           memory.readbyteunsigned(addr.player_y) ~= y)

    local r = peek_stack_w()
    while r ~= addr.menu_loop do
      if memory.readbyteunsigned(addr.player_current_hp) == 0 then
        -- the axe knight can kill us before we even get a turn
        coroutine.yield("dead")
      end
      coroutine.yield("frameadvance")
      r = peek_stack_w()
    end

    -- if the enemy got the first attack, run away and try again
    me = get_player_vars()
    if me.player_current_hp < me.player_max_hp then
      repeat until battle_command("run") == true
    else
      return true               -- success
    end
  end
end

-- fight the axe knight guarding erdrick's armor
function fight_axe_knight ()
  while true do
    start_fight("right")

    -- cast stopspell.  if it doesn't work, then run
    battle_command("cast stopspell")
    if get_monster_flag("stopspell") == 0 then
      repeat until battle_command("run") == true
    else
      break           -- proceed to the actual fight
    end
  end
      
  -- the actual fight
  local lo_dmg, hi_dmg = get_monster_melee_damage()
  local done = false
  while not done do
    local me = get_player_vars()
    if can_use_herb() and me.player_current_hp <= hi_dmg then
      battle_command("use herb")
    -- if we're out of herbs, we've probably already lost
    -- elseif me.player_current_hp <= 35 and me.player_current_mp >= 4 then
    --   battle_command("cast heal")
    else
      done = battle_command("fight")
    end
  end
end

-- fight the golem outside cantlin
function fight_golem ()
  start_fight("down")

  -- the actual fight
  local lo_dmg, hi_dmg = get_monster_melee_damage()
  local done = false
  while not done do
    local me = get_player_vars()
    if get_monster_flag("sleep") == 0 then
      script("use fairy flute")
    elseif can_use_herb() and me.player_current_hp <= hi_dmg then
      battle_command("use herb")
    else
      done = battle_command("fight")
    end
  end
end

function fight_dragonlord()
  -- dismiss any dialogs
  if peek_stack_w() == addr.end_of_dialog then
    script("tap A")
  end
  -- start the battle
  script("face w", "command talk", "mash", "select no")
  repeat coroutine.yield("frameadvance") until peek_stack_w() == addr.menu_loop

  -- first form
  while memory.readbyteunsigned(addr.monster_number) == 0x26 do
    local me = get_player_vars()
    if me.player_current_hp <= 75 and can_use_herb() then
      battle_command("use herb")                        -- try to stay healthy
    else
      battle_command("fight")
    end
  end

  -- second form
  local done = false
  while not done do
    local me = get_player_vars()
    if me.player_current_hp <= 49 and me.player_current_mp >= 10 then
      battle_command("cast healmore")
    else
      done = battle_command("fight")
    end
  end
end

-- save before trying risky function fn.  if it
-- fails, reload the game and try again.
function save_and_retry (name, fn)
  if yolo then
    return fn()
  end

  local rng = memory.readwordunsigned(addr.rng_lo)          -- save the rng
  -- first, save
  script("move 43,43", "move 7,7", "command stairs",
         "move 3,4", "face n", "command talk",
         "mash", "select yes", "select yes")

  -- for some weird reason, saving the game resets the rng.
  -- so we restore it here
  set_rng(rng)

  -- leave tangegel
  script("move 8,8", "command stairs",
         "move 10,29", "exit s")

  local n_attempt = 0
  while true do
    n_attempt = n_attempt + 1
    print(name .. " attempt #" .. string.format("%d", n_attempt))

    local result = catch_deaths(fn)

    if result == "done" then
      -- success
      break
    else
      -- death
      script("wait 386")                                        -- wait for the death message
      local rng = memory.readwordunsigned(addr.rng_lo)          -- save the rng
      coroutine.yield("reset")                                  -- reset the game

      -- load the game
      script("wait 60", "tap start", "wait 30", "tap start",
             "wait 30", "tap A", "wait 30", "tap A")            -- load the save

      set_rng(rng)                                              -- restore the rng

      script("wait 90", "tap A", "mash",                        -- chat with the king
             "move 8,8", "command stairs",
             "move 10,29", "exit s")                            -- leave tantegel
    end
  end
end

----------------------------------------
-- per-monster battle strategies
----------------------------------------

-- for certain monsters, it's better to cast sleep before running away
run_strategy = {}
run_strategy["Magiwyvern"] = function(me, monster)
  if get_monster_flag("stopspell") == 0 and can_cast(me, "stopspell") then
    return "cast stopspell"
  end
  return "run"
end

function melee_to_death ()
  return "fight"
end

-- cast hurt against a monster, unless it's more efficient
-- to melee.
function hurt_or_melee (me, monster)
  -- are we in the danger zone for hp?
  local lo, hi = get_monster_melee_damage()
  if me.player_current_hp <= hi then
    -- emergency healing
    if can_use_herb() then return "use herb"
    elseif can_cast(me, "heal") then return "cast heal"
    else return "run"
    end
  end

  -- is it more efficient to melee or cast hurt?
  -- hurt damage is 5-12
  lo, hi = get_player_melee_damage()
  if lo >= 5 and hi >= 10 then                  -- slightly prefer melee because it's quicker
    return "fight"
  end

  -- do we have chip damage?
  if chip_damage(0.9, monster.damage_dealt) then
    return "fight"
  end

  if can_cast(me, "hurt") then
    return "cast hurt"
  end
  return "fight"
end

-- if any entry in this array is nil, we just run from the fight
battle_strategy = {}

battle_strategy["Slime"] = melee_to_death
battle_strategy["Red Slime"] = melee_to_death

battle_strategy["Drakee"] = function(me, monster)
  if me.player_level < 2 then return "run" end
  if me.player_current_hp <= 6 and monster.damage_dealt < 1 then return "run" end
  return "fight"
end

battle_strategy["Ghost"] = battle_strategy["Drakee"]

battle_strategy["Metal Scorpion"] = hurt_or_melee
battle_strategy["Skeleton"] = hurt_or_melee
battle_strategy["Wolf"] = hurt_or_melee

battle_strategy["Warlock"] = function(me, monster)
  if me.player_level < 9 then
    return "run"
  end
  return "fight"
end

battle_strategy["Goldman"] = function (me, monster)
  -- fight 7 goldmen.  we need the extra gold.
  if me.player_level >= 12 and goldmen and goldmen < 7 then
    if not last_goldman or me.player_gold_w ~= last_goldman then
      goldmen = goldmen + 1
    end
    last_goldman = me.player_gold_w
    if goldmen < 7 then
      return "fight"
    end
  end
  return "run"
end

battle_strategy["Wolflord"] = melee_to_death
battle_strategy["Wraith"] = melee_to_death
battle_strategy["Wyvern"] = melee_to_death
battle_strategy["Rogue Scorpion"] = melee_to_death
battle_strategy["Knight"] = melee_to_death
battle_strategy["Wraith Knight"] = melee_to_death

battle_strategy["Demon Knight"] = function (me, monster)
  if me.player_level < 15 then return "run" end
  return "fight"
end

battle_strategy["Werewolf"] = function (me, monster)
  if me.player_level < 16 then return "run" end
  return "fight"
end

battle_strategy["Metal Slime"] = melee_to_death

battle_strategy["Green Dragon"] = function (me, monster)
  if me.player_level < 17 then return "run" end
  return "fight"
end

battle_strategy["Wizard"] = function (me, monster)
  if me.player_level < 17 then return "run" end
  return "fight"
end

battle_strategy["Starwyvern"] = function (me, monster)
  if me.player_level < 18 then
    -- below level 18 starwyverns have a good chance of casting healmore,
    -- so preemptively stopspell them.
    if get_monster_flag("stopspell") == 0 and can_cast(me, "stopspell") then
      return "cast stopspell"
    elseif stopspell_flag == 0 then
      return "run"
    end
  else
    -- starwyverns should have only about a 30% chance to
    -- healmore on us when we're at level 18.  so our
    -- strategy is to try killing them outright, and if
    -- they heal on us, respond by stopspelling them.
    -- if we don't stopspell them after a heal, the chance
    -- that they heal again is quite high.

    -- have they healed on us?  we're going to cheat a
    -- bit by looking at their current hp, but it's
    -- the easiest way to check.
    if (monster.damage_dealt > 1 and
        memory.readbyteunsigned(addr.monster_hp) == monster.hp_max and
        get_monster_flag("stopspell") == 0 and
        can_cast(me, "stopspell")) then
      return "cast stopspell"
    end
  end
    
  return "fight"
end

----------------------------------------
-- grinding
----------------------------------------

-- generic function to use while we're grinding
function heal_while_grinding (me, cast_heal_at, return_to_inn_at, inn_script_fn, min_mp)
  -- heal opportunistically w/ the heal spell
  while can_cast(me, "heal") and (me.player_current_hp) <= cast_heal_at do
    script("cast heal")
    me.player_current_mp = memory.readbyteunsigned(addr.player_current_mp)
    me.player_current_hp = memory.readbyteunsigned(addr.player_current_hp)
  end

  -- rest at the inn if needed
  if min_mp and me.player_current_mp < min_mp then
    inn_script_fn()
  elseif (not can_cast(me, "heal")) and (me.player_current_hp) <= return_to_inn_at then
    inn_script_fn()
  end
end

-- get to level 4 and 59 gold before heading to rimular
function ready_for_rimuldar (me)
  if me.player_level < 4 or me.player_gold_w < 59 then
    return false
  end
  return true
end

-- get to level 13 and 14,800 gold before heading to cantlin
function ready_for_cantlin (me)
  if me.player_level < 13 or me.player_gold_w < 14850 then
    return false
  end
  return true
end

-- get to level 13 and 15,100 gold before finishing the grind at rimuldar
function ready_for_erdricks_armor (me)
  if me.player_level < 13 or me.player_gold_w < (15235 - (num_herbs() * 24)) then
    return false
  end
  return true
end

-- sleep at the inn in brecconary
function rest_at_brecconary ()
  -- walk back to brecconary and rest at the inn
  script("move 48,41", "move 8,21", "face e",
         "command talk", "select yes",                -- rest at the inn
         "move 0,16", "exit w")
end

-- healing when grinding outside brecconary
function healing_at_brecconary (me)
  -- heal opportunistically w/ the heal spell
  if can_cast(me, "heal") and (me.player_max_hp - me.player_current_hp) >= 17 then
    script("cast heal")
    return
  end

  -- don't rest unless needed
  if me.player_level >= 3 and me.player_current_hp >= 8 then return
  elseif me.player_level == 2 and me.player_current_hp >= 6 then return
  elseif me.player_level == 1 and me.player_current_hp >= 4 then return
  end

  -- rest at inn.  save the herb for the rimuldar run
  rest_at_brecconary()                                -- use the inn
end

-- rest at the inn at garinham
function rest_at_rimuldar ()
  script("move 102,72", "move 18,18",
         "face w", "command talk", "select yes")

  -- during one of our trips to the inn at rimuldar,
  -- we should stop to buy keys.
  local gold = memory.readwordunsigned(addr.player_gold_w)
  if num_keys() < 6 and gold > 400 then
    script("move 4,5", "face s", "command talk")
    while num_keys() < 6 do
      script("select yes")
    end
    script("select no", "move 0,3", "exit w")
  else
    script("move 29,15", "exit e")
  end
end

-- healing when grinding outside rimuldar
function healing_at_rimuldar (me)
  -- need to be slightly conservative at rimuldar
  if me.player_level <= 8 then
    heal_while_grinding (me, 25, 30, rest_at_rimuldar, 6)
  else
    heal_while_grinding (me, me.player_max_hp - 17, 30, rest_at_rimuldar)
  end
end

-- rest at the inn at garinham
function rest_at_garinham ()
  local me = get_player_vars()
  if me.player_level >= 15 and can_cast(me, "repel") then
    script("cast repel")
  else
    script("fairy water")
  end

  script("move 2,2", "move 15,15", "face e",
         "command talk", "select yes",
         "move 19,13", "exit e")
end

-- healing when grinding outside garinham
function healing_at_garinham (me)
  heal_while_grinding (me, me.player_max_hp - 17, 40, rest_at_garinham)
end

-- rest at the inn at cantlin
function rest_at_cantlin ()
  script("move 73,102", "move 8,5", "face n",
         "command talk", "select yes",
         "move 5,0", "exit n")
end

-- healing when grinding outside cantlin
function healing_at_cantlin (me)
  heal_while_grinding (me, me.player_max_hp - 17, 115, rest_at_cantlin)
end

-- walk back and forth between points, fighting random battles
-- until we reach the specified level (if to is a number), or
-- the to predicate returns true.  use heal_fn after battle to heal.
function grind(to, points, heal_fn)
  local pt_idx = 1
  local pt_incr = 2
  points = get_numbers(points)

  function done ()
    local me = get_player_vars()
    if type(to) == "number" then
      return me.player_level >= to
    else
      return to(me)
    end
  end

  function do_heal ()
    local me = get_player_vars()
    if not done() then
      local x1, y1 = memory.readbyteunsigned(addr.player_x), memory.readbyteunsigned(addr.player_y)
      heal_fn(me)
      local x2, y2 = memory.readbyteunsigned(addr.player_x), memory.readbyteunsigned(addr.player_y)
      -- if the healing function moved us, then reset which point we move towards
      if (x1 ~= x2) or (y1 ~= y2) then
        pt_idx, pt_incr = 1, 2
      end
    end
  end

  while not done() do
    -- walk back and forth between the supplied points
    if move_to(points[pt_idx], points[pt_idx + 1], true, true) then
      -- move successful.  switch directions
      if (pt_idx + pt_incr) >= #points or (pt_idx + pt_incr) < 1 then
        pt_incr = -pt_incr
      end
      pt_idx = pt_idx + pt_incr
    else
      -- fight & heal
      fight_monster()
      do_heal()
    end
  end
end

-- special function used for the final grind outside haukness
function grind_at_haukness ()
  local heal_fn = function (me)
    -- we can be very loose with the healing now that we have erdrick's armor
    local min_hp = 30
    if me.player_level >= 18 then
      min_hp = 50                       -- inside haukness is a bit more dangerous
    end
    while me.player_current_hp < min_hp and can_cast(me, "heal") do
      script("cast heal")
      me.player_current_mp = memory.readbyteunsigned(addr.player_current_mp)
      me.player_current_hp = memory.readbyteunsigned(addr.player_current_hp)
    end
  end

  local grind_fn = function ()
    local me = get_player_vars()
    if can_cast(me, "repel") then
      script("cast repel")
    else
      script("fairy water")
    end

    if me.player_level < 18 then
      -- outside haukness (Zone 10)
      grind(18, "{16,90} {18,90}", heal_fn)
    end

    if me.player_level < 19 then
      -- inside haukness (Zone 13)
      script("move 25,89", "wait 60")
      grind(19, "{1,4} {0,4}", heal_fn)
    end
  end

  -- we are actually going to tank deaths during the final
  -- grind rather than return to town to heal.  it's faster
  -- and there's no downside.
  while true do
    local result = catch_deaths(grind_fn)
    if result == "done" then
      break
    else
      -- death
      respawn_after_death()
    end
  end
end

-- rest, buy herbs and fairy water
function restock_at_brecconary (howmany_fairy_water)
  script("move 48,41")

  -- rest at the inn if needed
  local me = get_player_vars()
  if (me.player_gold_w >= 6 and
      (me.player_current_hp < me.player_max_hp or
       me.player_current_mp < me.player_max_mp)) then
    script("move 8,21", "face e", "command talk", "select yes")
  end
  
  -- restock herbs
  local me = get_player_vars()
  if num_herbs() < 6 and me.player_gold_w >= 24 then
    script("move 23,25", "face e", "command talk")
    while num_herbs() < 6 and me.player_gold_w >= 24 do
      script("select 0,0", "select 0,0")
      me.player_gold_w = memory.readwordunsigned(addr.player_gold_w)
    end
    script("select no")
  end
  
  -- restock fairy water
  local me = get_player_vars()
  if me.player_gold_w >= 38 and num_keys() > 0 then
    script("move 21,7", "face n", "command door",
           "move 22,4", "face e")
    
    -- buy 2 fairy waters
    wait_for_fairy_water_vendor()
    script("command talk")
    while num_fairy_water() < howmany_fairy_water and me.player_gold_w >= 38 do
      script("select yes")
      me.player_gold_w = memory.readwordunsigned(addr.player_gold_w)
    end
    
    script("select no")
  end
  script("move 16,0", "exit n")            -- leave town
end

----------------------------------------
-- beat the game!
----------------------------------------

function beat_the_game (rng)
  -- start the game
  script("wait 30", "tap start",                              -- wait for title screen
         "wait 30", "tap start",                              -- start game
         "wait 30", "tap A",                                  -- "begin a new quest"
         "wait 30", "tap A",                                  -- "adventure log 1"
         "wait 30", "tap right", "wait 4", "tap right", "wait 4", "tap right",
         "wait 4", "tap right", "wait 4", "tap right", "wait 4", "tap right",
         "wait 4", "tap right", "wait 4", "tap right", "wait 4", "tap right",       -- pick "J"
         "wait 4", "tap A",
         "wait 4", "tap down", "wait 4", "tap down", "wait 4", "tap down",
         "wait 4", "tap down", "wait 4", "tap down",
         "wait 4", "tap A",                                   -- pick "end"
         "wait 30", "tap up", "wait 4", "tap A")              -- fast message speed
  
  -- set the rng
  set_rng(rng)
  
  script("wait 90", "tap A", "mash",                              -- chat with the king
         "move 4,4", "command take",                              -- grab treasure #1
         -- "move 5,4", "command take",                           -- skip the torch
         "move 6,1", "command take",                              -- grab treasure #3
         "move 4,6", "face s", "command door",
         "move 8,8", "command stairs",                            -- leave throne room
         "move 10,29", "exit s",                                  -- leave tantegel
         "move 48,41")                                            -- head to brecconary
  
  ----------------------------------------
  -- brecconary
  ----------------------------------------
  
  -- buy the club and clothes
  script("move 5,6", "face n", "command talk", "select yes",      -- walk to the shop and open it
         "select 0,1", "select yes",                              -- buy the club
         "select yes",                                            -- buy more
         "select 0,3", "select yes",                              -- buy the clothes
         "select no")                                             -- done shopping
  
  -- buy the dragon's scale and herb
  script("move 23,25", "face e", "command talk", "select buy",            -- open the shop
         "select 0,2", "select no")                                       -- buy the scale, close shop
  local scale_index = get_inventory_index("dragon's scale")
  script("command item", "select 0," .. scale_index,                      -- equip the scale
         "command talk", "select sell",                                   -- reopen the shop
         "select 0," .. scale_index, "select yes",                        -- sell the scale
         "select no",                                                     -- close the shop
         "command talk", "select buy",                                    -- reopen the shop
         "select 0,0",                                                    -- buy the herb
         "select no")                                                     -- close the shop
  
  -- leave town
  script("move 29,15", "exit e")
  
  --- grinding #1 - get level 3 & 4 ---
  grind(3, "{36,54} {34,54}", healing_at_brecconary)
  grind(ready_for_rimuldar, "{29,26} {28,26}", healing_at_brecconary)
  coroutine.yield("split", "Level 4")
  
  -- rest and save before attempting the run to rimuldar
  rest_at_brecconary()

  print("Checkpoint: run to rimuldar")
  
  local reach_rimuldar = function()  
    -- head to rimuldar
    script("moveheal 95,39,10",
           "moveheal 98,39,20", "moveheal 101,41,20", "moveheal 104,43,20",               -- walk carefully through the swamp
           "exit s", "moveheal 0,29,10", "command stairs",
           "moveheal 102,72,25,8")
  end
  
  save_and_retry("Run to Rimuldar", reach_rimuldar)
  
  -- buy a key
  script("move 4,5", "face s", "command talk",
         "select yes", "select no",
         "move 0,3", "exit w")
  
  -- death warp back to tantegel
  death_warp("{106,72} {104,72}")

  print("Checkpoint: rock mountain cave")
  
  -- head to rock mountain cave
  script("move 8,8", "command stairs", "move 10,29", "exit s",
         "moveheal 29,57,15",
         "moveheal 13,5,15", "command take",
         "moveheal 6,5,15", "command stairs",
         "moveheal 10,9,15", "command take")
  
  -- death warp again
  death_warp("{6,9} {10,9}")

  -- do the treasure chest glitch
  script("move 8,8", "command stairs", "move 5,13", "face w", "command door",
         "move 1,13", "command take",
         "move 2,14", "command take",
         "move 1,15", "command take",
         "move 3,15")
  
  -- grind some gold
  while memory.readwordunsigned(addr.player_gold_w) < 5530 do
    script("command take")
  end
  coroutine.yield("split", "5530 Gold")

  -- head to garinham and buy a large shield
  script("move 10,29", "exit s",
         "moveheal 2,2,10",
         "move 10,16", "face s", "command talk", "select yes",
         "select 0,6", "select yes",
         "select no",
         "move 19,13", "exit e")
  
  -- head to kol.  do some shopping. 
  town_tile_costs[12] = 0                       -- HACK for kol : don't attempt to path through doors
  script("moveheal 90,37,10", "moveheal 104,10,15",
         "move 20,12", "face e", "command talk", "select yes",          -- open the weapon shop
         "select 0,3", "select yes",                                    -- buy the full plate
         "select no", "move 9,6", "command search",                     -- get the fairy flute
         "move 12,21", "face e", "command talk", "select buy")
  
  -- max out herbs
  while num_herbs() < 6 do
    script("select 0,0", "select yes")                  -- select the herb, buy more
  end
  
  script("select 0,3", "select no",                     -- buy wings
         "move 0,22", "exit w")                         -- leave kol
  town_tile_costs[12] = 1                       -- HACK for kol : don't attempt to path through doors
  
  ----------------------------------------
  -- rimuldar
  ----------------------------------------
  
  -- head to rimuldar
  script("moveheal 98,39,20", "moveheal 101,41,20", "moveheal 104,43,20",               -- walk carefully through the swamp
         "exit s", "moveheal 0,29,10", "command stairs",
         "moveheal 102,72,25")
  
  -- buy the broadsword
  script("move 23,9", "face n", "command talk", "select yes",
         "select 0,2", "select yes", "select no")
  
  -- rest at the inn
  script("move 18,18", "face w", "command talk", "select yes",
         "move 29,15", "exit e")
  
  -- grinding #2 : grind at rimuldar to level 10
  grind(10, "{106,72} {104,72}", healing_at_rimuldar)
  
  -- grinding #3 : grind south of rimuldar to level 13 and 15,235 gold
  goldmen = 0                                           -- keep track of the number of goldmen killed
  grind(ready_for_erdricks_armor, "{110,90} {112,90}", healing_at_rimuldar)
  goldmen = nil
  coroutine.yield("split", "Level 13")
  
  ----------------------------------------
  -- erdrick's armor
  ----------------------------------------
  
  -- return to brecconary
  script("use wings")
  restock_at_brecconary(num_empty_slots() - 1)
 
  local get_armor = function()
    -- reset tile movement costs with each attempt
    overworld_tile_costs[8] = 3           -- swamp
    town_tile_costs[10] = 2               -- swamp
    town_tile_costs[11] = 3               -- trap
  
    script("fairy water", "moveheal 25,89,30",
           -- no emergency healing for the final move.  we need to save mp/herbs for the axe knight
           "moveheal 17,12,55")
    fight_axe_knight()
    script("command search")
  
    -- now that we have erdrick's armor, adjust tile movement costs
    overworld_tile_costs[8] = 1           -- swamp
    town_tile_costs[10] = 1               -- swamp
    town_tile_costs[11] = 1               -- trap
  
    script("moveheal 12,19,50", "exit s")       -- leave haukness
  end

  print("Checkpoint: Erdrick's armor")  
  save_and_retry("Get erdrick's armor", get_armor)
  
  ----------------------------------------
  -- garinham's grave
  ----------------------------------------
  
  -- head to garinham to rest and restock
  script("fairy water", "moveheal 2,2,20")
  
  -- restock on herbs
  if num_herbs() < 5 then
    script("move 3,11", "face e", "command talk")
    while num_herbs() < 5 do
      script("select 0,0", "select 0,0")
    end
    script("select no")
  end
  
  script("move 15,15", "face e", "command talk", "select yes",          -- rest at inn
         "move 17,11", "face n", "command door")
  
  if num_herbs() < 6 then
    script("move 8,6", "command take")          -- grab a free herb
  end
  
  -- grab the harp
  print("Checkpoint: Garinham's grave")
  reserved_mp = 14                               -- reserve MP for outside + return
  script("move 19,0", "command stairs",
         "moveheal 17,16,40", "face s", "command door", "moveheal 1,18,40", "command stairs",
         "moveheal 1,10,40", "command stairs",
         "moveheal 9,5,40", "command stairs",
         "moveheal 5,4,40", "command stairs",
         "moveheal 13,6,40", "command take", "cast outside", "exit e",          -- grab the harp and leave
         "cast return")
  
  reserved_mp = 0
  rest_at_brecconary()
  
  ----------------------------------------
  -- cantlin & token
  ----------------------------------------
  
  local fetch_token = function ()
    script("fairy water", "moveheal 73,99,53")
    fight_golem()
    script("moveheal 73,102,50")
  
    -- buy the silver shield
    script("move 25,9", "face e", "command door",
           "move 26,12", "face w", "command talk",
           "select yes", "select 0,1", "select yes", "select no")
    
    -- restock fairy water
    if num_empty_slots() > 2 then
      script("move 20,13", "face e", "command talk")
      while num_empty_slots() > 2 do        -- leave room for the token and the stones of sunlight
        script("select yes")
      end
      script("select no")
    end
    
    -- restock herbs
    if num_herbs() < 6 then
      script("move 4,7", "face w", "command talk")
      while num_herbs() < 6 do
        script("select 0,0", "select 0,0")
      end
      script("select no")
    end
    
    -- rest at the inn then leave town
    script("move 8,5", "face n", "command talk", "select yes",
           "move 5,1", "exit n")
  
    -- fetch erdrick's token
    reserved_mp = 8                       -- save mp for return
    script("moveheal 83,113,50", "command search", "cast return")
  end

  print("Checkpoint: Erdrick's token")  
  save_and_retry("Get the token", fetch_token)
  
  ----------------------------------------
  -- fetch quests & erdrick's sword
  ----------------------------------------
  
  script("move 43,43", "move 18,5", "face s", "command door",
         "move 24,3", "face n", "command talk",
         "select yes", "select no")             -- buy another key while we're here
  
  -- fetch the stones of sunlight
  script("move 29,29", "command stairs",
         "move 4,5", "command take",
         "move 0,4", "command stairs",
         "exit e")
  
  -- fetch the staff of rain
  reserved_mp = 8
  script("fairy water", "moveheal 81,1,20", "command stairs",
         "move 5,4", "face w", "command talk",
         "move 3,4", "command take",
         "move 4,9", "command stairs")
  
  -- fetch the rainbow drop
  script("fairy water", "moveheal 104,44,20",
         "moveheal 0,29,10", "command stairs",
         "moveheal 108,109,50", "command stairs",
         "move 3,5", "face e", "command talk",
         "move 0,4", "command stairs")
  
  local fetch_sword = function()
    script("moveheal 48,48,50", "moveheal 10,1,50")
    if not found_stairs then
      script("command search")
      found_stairs = true
    end
    script("command stairs",
           "moveheal 8,19,50", "command stairs",       -- b1
           "moveheal 3,0,50", "command stairs",        -- b2
           "moveheal 1,6,50", "command stairs",        -- b3
           "moveheal 7,7,50", "command stairs",        -- b4
           "moveheal 2,2,50", "command stairs",        -- b3
           "moveheal 8,0,50", "command stairs",        -- b2
           "moveheal 13,7,50", "command stairs",       -- b1
           "moveheal 5,5,50", "command take")          -- the sword
  end

  local fetch_sword2 = function()
    script("fairy water", "moveheal 104,44,20",
           "moveheal 0,29,10", "command stairs",
           "fairy water")
    return fetch_sword()
  end

  -- rest at rimuldar
  script("fairy water", "moveheal 102,72,50",
         "move 18,18", "face w", "command talk", "select yes",
         "move 29,15", "exit e")

  -- we'll deathwarp back
  reserved_mp = 0

  -- use the rainbow drop
  script("fairy water", "moveheal 65,49,50", "face w", "use rainbow drop")
  
  -- modify the overworld map now that the bridge is there
  overworld_map[1 + 49*overworld_width + 64] = 1

  -- make a dash for the sword once without saving
  print("Fetch Erdrick's sword attempt #0")
  if catch_deaths(fetch_sword) == "dead" then
    if yolo then
      coroutine.yield("dead")
    end

    -- head to brecconary to restock on the items we spent
    -- in the last attempt
    respawn_after_death()
    restock_at_brecconary(2)

    -- this time, safety save
    save_and_retry("Fetch Erdrick's sword", fetch_sword2)
  end

  -- back to tantegel  
  death_warp("{4,5} {5,5}")
  coroutine.yield("split", "Erdrick gear")
  
  -- leave tantegel
  script("move 8,8", "command stairs", "move 10,29", "exit s", "fairy water")
  
  ----------------------------------------
  -- final grind & battle
  ----------------------------------------

  print("Checkpoint: level 19 grind")
 
  reserved_mp = 0
  grind_at_haukness()  
  coroutine.yield("split", "Level 19")
 
  -- back to tantegel
  local me = get_player_vars()
  if can_cast(me, "return") then
    script("cast return")
  else
    death_warp("{0,4} {1,4}")
    script("move 8,8", "command stairs",                    -- leave the throne room
           "move 10,29", "exit s")                          -- leave tantegel
  end
  
  -- rest at brecconary and restock
  restock_at_brecconary(2)

  local final_fight = function()  
    -- make our way to the dragonlord fight
    reserved_mp = 100                                     -- save ALL mp for the final battle
    script("fairy water", "moveheal 104,44,10",
           "moveheal 0,29,10", "command stairs",
           "fairy water", "moveheal 48,48,50")

    -- traverse charlock castle
    script("moveheal 10,1,50", "command stairs",
           "moveheal 8,19,50", "command stairs",          -- b1
           "moveheal 3,0,50", "command stairs",           -- b2
           "moveheal 1,6,50", "command stairs",           -- b3
           "moveheal 2,2,50", "command stairs",           -- b4
           "moveheal 0,0,50", "command stairs",           -- b5
           "moveheal 9,6,50", "command stairs",           -- b6
           "moveheal 17,24,50")                           -- final
    
    -- heal up!
    local me = get_player_vars()
    while me.player_current_hp < me.player_max_hp and num_herbs() > 1 do
      script("use herb")
      me.player_current_hp = memory.readbyteunsigned(addr.player_current_hp)
    end
    
    -- final battle!
    fight_dragonlord()
  end

  print("Checkpoint: Dragonlord")
  save_and_retry("Beat the Dragonlord", final_fight)

  -- warp back to tantegel
  script("tap A", "cast return", "move 43,43", "move 11,8")

  -- mash the final textbox
  while true do
    local r = peek_stack_w()
    if r == addr.final_dialog then break
    elseif r == addr.more_dialog then         -- prompt for more dialog
      tap("A")
    else
      coroutine.yield("frameadvance")
    end
  end
  coroutine.yield("split", "End")

end

----------------------------------------
-- start
----------------------------------------

local n_attempt = 0
local best_time = nil
local best_rng = nil

while true do
  if best_time then
    print(string.format("Best time: %s   Best RNG : %04x (YOLO=%s)", format_time(best_time), best_rng, tostring(yolo)))
  end

  emu.softreset()

  -- reset parameters that might have changed in the last attempt.
  reserved_mp = 0
  overworld_tile_costs[8] = 3           -- swamp
  town_tile_costs[10] = 2               -- swamp
  town_tile_costs[11] = 3               -- trap
  town_tile_costs[12] = 1               -- doors
  found_stairs = false
  
  for i=0x30,0x45 do            -- nuke the save data
    memory.writebyte(addr.wram + i, 0)
  end

  for i=1,60 do
    emu.frameadvance()          -- give the game time to initialize
  end

  -- decompress the overworld map
  overworld_map = {}
  decompress_overworld_map()

  local nframe = 0
  -- a fixed RNG is boring.  so reseed randomly every attempt.
  local rng = math.random(0, 65535)
  if (math.floor(rng / 2) % 2) == 0 then
    rng = rng + 2                       -- ensure bit 1 is set
  end

  n_attempt = n_attempt + 1
  print(string.format("Attempt #%d   RNG seed: %04x   YOLO: %s", n_attempt, rng, tostring(yolo)))

  -- run the script as a coroutine.  if the script dies,
  -- pause for dramatic effect then try again
  local co = coroutine.create(beat_the_game)
  local r1, r2, r3 = coroutine.resume(co, rng)
  while r2 == "frameadvance" or r2 == "reset" or r2 == "split" do
    if r2 == "reset" then
      emu.softreset()
    elseif r2 == "split" then
      print(string.format("Split: %-20s %s", r3, format_time(nframe)))
    else
      if show_time then
        gui.text(10, 10, format_time(nframe))
      end
      emu.frameadvance()
      nframe = nframe + 1
      -- read_text()
    end
    r1, r2, r3 = coroutine.resume(co)
  end

  if not r1 then
    print(r2)                   -- print the script error and bomb
    break
  elseif r2 == "dead" then
    for i=1,120 do
      emu.frameadvance()        -- pause at death, then try again!
    end
    print("Dead")
  else
    -- we did it!
    print(string.format("Successful run!   Total time: %s   RNG seed: %04x   YOLO: %s", format_time(nframe), rng, tostring(yolo)))
    if (not best_time) or nframe < best_time then
      best_time = nframe
      best_rng = rng
    end
    -- let the ending play out then do it again
    for i=1,(60*60*3) do
      if show_time then
        gui.text(10, 10, format_time(nframe))
      end
      emu.frameadvance()
    end
  end
end
