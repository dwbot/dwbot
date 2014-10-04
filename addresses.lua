-- ROM & RAM addresses
addr={}

-- data pointers
addr.rom = 0x8000
addr.wram = 0x6000

-- zones
addr.overworld = 0xa653
addr.charlock_lv1 = 0x80b0
addr.haukness = 0x8178
addr.tantegel = 0x8240
addr.tantegel_throne_room = 0x8402
addr.charlock_final = 0x8434
addr.kol = 0x85f6
addr.brecconary = 0x8716
addr.garinham = 0x8a9a
addr.cantlin = 0x88d8
addr.rimuldar = 0x8b62
addr.tantegel_b1 = 0x8d24

addr.mask_divider = 0x8d24              -- first zone that uses a different tile mask
addr.dungeons_start = 0x8dba            -- first 'dungeon' zone

-- variables
addr.zone_ptr = 0x11
addr.npc_tbl_start = 0x51
addr.npc_tbl_end = 0x8c
addr.map_width = 0x13
addr.map_height = 0x14
addr.player_exp_w = 0xba
addr.player_gold_w = 0xbc
addr.player_current_hp = 0xc5
addr.player_current_mp = 0xc6
addr.player_level = 0xc7
addr.player_str = 0xc8
addr.player_agi = 0xc9
addr.player_max_hp = 0xca
addr.player_max_mp = 0xcb
addr.player_atk = 0xcc
addr.player_def = 0xcd
addr.player_x = 0x8e
addr.player_y = 0x8f
addr.cursor_x = 0xd8
addr.cursor_y = 0xd9
addr.enemy_flags = 0xdf
addr.player_facing = 0x602f
addr.monster_number = 0xe0
addr.monster_hp = 0xe2
addr.keys = 0xbf
addr.herbs = 0xc0
addr.inventory_start = 0xc1
addr.inventory_end = 0xc4
addr.rng_lo = 0x94
addr.rng_hi = 0x95
addr.text_cursor_x = 0xd2
addr.text_cursor_y = 0xd3
addr.text_buffer = 0x657c
addr.monster_str = 0x100
addr.monster_agi = 0x101
addr.monster_max_hp = 0x102

-- code/return address pointers
addr.standing_still = 0xcb30+2
addr.more_dialog = 0xba65+2
addr.end_of_dialog = 0xcfee+2
addr.end_of_dialog2 = 0xcfe4+2
addr.final_dialog = 0xccbe+2
addr.menu_loop = 0xa8ed+2
addr.zone_out = 0xc218+2
addr.battle_start = 0xe43d+2
addr.battle_successful = 0xcfee+2
addr.battle_routine_lo = 0xe57c+2
addr.battle_routine_hi = 0xee7a+2
