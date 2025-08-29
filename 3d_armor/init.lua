local mod = foundation.new_module("armor", "1.0.0")

local worldpath = core.get_worldpath()
local last_punch_time = {}
local pending_players = {}
local timer = 0

-- local functions
local S = mod.S
local F = core.formspec_escape

mod:require("api.lua")

-- Legacy Config Support

local input = io.open(mod.modpath.."/armor.conf", "r")
if input then
	dofile(modpath.."/armor.conf")
	input:close()
	input = nil
end
input = io.open(worldpath.."/armor.conf", "r")
if input then
	dofile(worldpath.."/armor.conf")
	input:close()
	input = nil
end
for name, _ in pairs(armor.config) do
	local global = "ARMOR_"..name:upper()
	if core.global_exists(global) then
		mod.config[name] = _G[global]
	end
end
if core.global_exists("ARMOR_MATERIALS") then
	mod.materials = table.copy(ARMOR_MATERIALS)
end
if core.global_exists("ARMOR_FIRE_NODES") then
	mod.fire_nodes = table.copy(ARMOR_FIRE_NODES)
end

-- Load Configuration

for name, config in pairs(mod.config) do
	local setting = core.settings:get("armor_"..name)
	if type(config) == "number" then
		setting = tonumber(setting)
	elseif type(config) == "boolean" then
		setting = core.settings:get_bool("armor_"..name)
	end
	if setting ~= nil then
		mod.config[name] = setting
	end
end
for material, _ in pairs(mod.materials) do
	local key = "material_"..material
	if mod.config[key] == false then
		mod.materials[material] = nil
	end
end

-- Mod Compatibility

if core.get_modpath("technic") then
	mod.formspec = mod.formspec..
		"label[5,2.5;"..F(S("Radiation"))..":  armor_group_radiation]"
	mod:register_armor_group("radiation")
end
local skin_mods = {"skins", "u_skins", "simple_skins", "wardrobe"}
for _, mod in pairs(skin_mods) do
	local path = core.get_modpath(mod)
	if path then
		local dir_list = core.get_dir_list(path.."/textures")
		for _, fn in pairs(dir_list) do
			if fn:find("_preview.png$") then
				mod:add_preview(fn)
			end
		end
		mod.skin_mod = mod
	end
end
if not core.get_modpath("moreores") then
	mod.materials.mithril = nil
end
if not core.get_modpath("ethereal") then
	mod.materials.crystal = nil
end

mod:require("armor.lua")

-- Armor Initialization

mod.formspec = mod.formspec..
	"label[5,1;"..F(S("Level"))..": armor_level]"..
	"label[5,1.5;"..F(S("Heal"))..":  armor_attr_heal]"
if mod.config.fire_protect then
	mod.formspec = mod.formspec.."label[5,2;"..F(S("Fire"))..":  armor_attr_fire]"
end
mod:register_on_destroy(function(player, index, stack)
	local name = player:get_player_name()
	local def = stack:get_definition()
	if name and def and def.description then
		core.chat_send_player(name, S("Your @1 got destroyed!", def.description))
	end
end)

local function validate_armor_inventory(player)
	-- Workaround for detached inventory swap exploit
	local _, inv = mod:get_valid_player(player, "[validate_armor_inventory]")
	if not inv then
		return
	end
	local armor_prev = {}
	local armor_list_string = player:get_attribute("3d_armor_inventory")
	if armor_list_string then
		local armor_list = mod:deserialize_inventory_list(armor_list_string)
		for i, stack in ipairs(armor_list) do
			if stack:get_count() > 0 then
				armor_prev[stack:get_name()] = i
			end
		end
	end
	local elements = {}
	local player_inv = player:get_inventory()
	for i = 1, 6 do
		local stack = inv:get_stack("armor", i)
		if stack:get_count() > 0 then
			local item = stack:get_name()
			local element = mod:get_element(item)
			if element and not elements[element] then
				if armor_prev[item] then
					armor_prev[item] = nil
				else
					-- Item was not in previous inventory
					armor:run_callbacks("on_equip", player, i, stack)
				end
				elements[element] = true;
			else
				inv:remove_item("armor", stack)
				-- The following code returns invalid items to the player's main
				-- inventory but could open up the possibity for a hacked client
				-- to receive items back they never really had. I am not certain
				-- so remove the is_singleplayer check at your own risk :]
				if core.is_singleplayer() and player_inv and
						player_inv:room_for_item("main", stack) then
					player_inv:add_item("main", stack)
				end
			end
		end
	end
	for item, i in pairs(armor_prev) do
		local stack = ItemStack(item)
		-- Previous item is not in current inventory
		mod:run_callbacks("on_unequip", player, i, stack)
	end
end

local function init_player_armor(player)
	local name = player:get_player_name()
	local pos = player:get_pos()
	if not name or not pos then
		return false
	end
	local armor_inv = core.create_detached_inventory(name.."_armor", {
		on_put = function(inv, listname, index, stack, player)
			validate_armor_inventory(player)
			mod:save_armor_inventory(player)
			mod:set_player_armor(player)
		end,
		on_take = function(inv, listname, index, stack, player)
			validate_armor_inventory(player)
			mod:save_mod_inventory(player)
			mod:set_player_armor(player)
		end,
		on_move = function(inv, from_list, from_index, to_list, to_index, count, player)
			validate_armor_inventory(player)
			mod:save_armor_inventory(player)
			mod:set_player_armor(player)
		end,
		allow_put = function(inv, listname, index, put_stack, player)
			local element = mod:get_element(put_stack:get_name())
			if not element then
				return 0
			end
			for i = 1, 6 do
				local stack = inv:get_stack("armor", i)
				local def = stack:get_definition() or {}
				if def.groups and def.groups["armor_"..element]
						and i ~= index then
					return 0
				end
			end
			return 1
		end,
		allow_take = function(inv, listname, index, stack, player)
			return stack:get_count()
		end,
		allow_move = function(inv, from_list, from_index, to_list, to_index, count, player)
			return count
		end,
	}, name)
	armor_inv:set_size("armor", 6)
	if not mod:load_armor_inventory(player) and armor.migrate_old_inventory then
		local player_inv = player:get_inventory()
		player_inv:set_size("armor", 6)
		for i=1, 6 do
			local stack = player_inv:get_stack("armor", i)
			armor_inv:set_stack("armor", i, stack)
		end
		mod:save_armor_inventory(player)
		player_inv:set_size("armor", 0)
	end
	for i=1, 6 do
		local stack = armor_inv:get_stack("armor", i)
		if stack:get_count() > 0 then
			armor:run_callbacks("on_equip", player, i, stack)
		end
	end
	mod.def[name] = {
		init_time = core.get_gametime(),
		level = 0,
		state = 0,
		count = 0,
		groups = {},
	}
	for _, phys in pairs(mod.physics) do
		mod.def[name][phys] = 1
	end
	for _, attr in pairs(mod.attributes) do
		mod.def[name][attr] = 0
	end
	for group, _ in pairs(mod.registered_groups) do
		mod.def[name].groups[group] = 0
	end
	local skin = mod:get_player_skin(name)
	mod.textures[name] = {
		skin = skin,
		armor = "3d_armor_trans.png",
		wielditem = "3d_armor_trans.png",
		preview = mod.default_skin.."_preview.png",
	}
	local texture_path = core.get_modpath("player_textures")
	if texture_path then
		local dir_list = core.get_dir_list(texture_path.."/textures")
		for _, fn in pairs(dir_list) do
			if fn == "player_"..name..".png" then
				mod.textures[name].skin = fn
				break
			end
		end
	end
	mod:set_player_armor(player)
	return true
end

-- Armor Player Model

player_api.register_model("3d_armor_character.b3d", {
	animation_speed = 30,
	textures = {
		mod.default_skin..".png",
		"3d_armor_trans.png",
		"3d_armor_trans.png",
	},
	animations = {
		stand = {x=0, y=79},
		lay = {x=162, y=166},
		walk = {x=168, y=187},
		mine = {x=189, y=198},
		walk_mine = {x=200, y=219},
		sit = {x=81, y=160},
	},
})

core.register_on_player_receive_fields(function(player, formname, fields)
	local name = mod:get_valid_player(player, "[on_player_receive_fields]")
	if not name then
		return
	end
	for field, _ in pairs(fields) do
		if string.find(field, "skins_set") then
			core.after(0, function(player)
				local skin = mod:get_player_skin(name)
				mod.textures[name].skin = skin
				mod:set_player_armor(player)
			end, player)
		end
	end
end)

core.register_on_joinplayer(function(player)
	player_api.set_model(player, "3d_armor_character.b3d")
	core.after(0, function(player)
		if init_player_armor(player) == false then
			pending_players[player] = 0
		end
	end, player)
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	if name then
		mod.def[name] = nil
		mod.textures[name] = nil
	end
	pending_players[player] = nil
end)

if mod.config.drop == true or mod.config.destroy == true then
	core.register_on_dieplayer(function(player)
		local name, armor_inv = mod:get_valid_player(player, "[on_dieplayer]")
		if not name then
			return
		end
		local drop = {}
		for i=1, armor_inv:get_size("armor") do
			local stack = armor_inv:get_stack("armor", i)
			if stack:get_count() > 0 then
				table.insert(drop, stack)
				mod:run_callbacks("on_unequip", player, i, stack)
				mod_inv:set_stack("armor", i, nil)
			end
		end
		mod:save_armor_inventory(player)
		mod:set_player_armor(player)
		local pos = player:get_pos()
		if pos and mod.config.destroy == false then
			core.after(mod.config.bones_delay, function()
				local meta = nil
				local maxp = vector.add(pos, 8)
				local minp = vector.subtract(pos, 8)
				local bones = core.find_nodes_in_area(minp, maxp, {"bones:bones"})
				for _, p in pairs(bones) do
					local m = core.get_meta(p)
					if m:get_string("owner") == name then
						meta = m
						break
					end
				end
				if meta then
					local inv = meta:get_inventory()
					for _,stack in ipairs(drop) do
						if inv:room_for_item("main", stack) then
							inv:add_item("main", stack)
						else
							mod.drop_armor(pos, stack)
						end
					end
				else
					for _,stack in ipairs(drop) do
						mod.drop_armor(pos, stack)
					end
				end
			end)
		end
	end)
end

if mod.config.punch_damage == true then
	core.register_on_punchplayer(function(player, hitter,
			time_from_last_punch, tool_capabilities)
		local name = player:get_player_name()
		if name then
			mod:punch(player, hitter, time_from_last_punch, tool_capabilities)
			last_punch_time[name] = core.get_gametime()
		end
	end)
end

core.register_on_player_hpchange(function(player, hp_change)
	if player and hp_change < 0 then
		local name = player:get_player_name()
		if name then
			local heal = mod.def[name].heal
			if heal >= math.random(100) then
				hp_change = 0
			end
			-- check if armor damage was handled by fire or on_punchplayer
			local time = last_punch_time[name] or 0
			if time == 0 or time + 1 < core.get_gametime() then
				mod:punch(player)
			end
		end
	end
	return hp_change
end, true)

core.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer > mod.config.init_delay then
		for player, count in pairs(pending_players) do
			local remove = init_player_armor(player) == true
			pending_players[player] = count + 1
			if remove == false and count > armor.config.init_times then
				core.log("warning", S("3d_armor: Failed to initialize player"))
				remove = true
			end
			if remove == true then
				pending_players[player] = nil
			end
		end
		timer = 0
	end
end)

-- Fire Protection and water breating, added by TenPlus1

if mod.config.fire_protect == true then
	-- override hot nodes so they do not hurt player anywhere but mod
	for _, row in pairs(mod.fire_nodes) do
		if core.registered_nodes[row[1]] then
			core.override_item(row[1], {damage_per_second = 0})
		end
	end
else
	print (S("[3d_armor] Fire Nodes disabled"))
end

if mod.config.water_protect == true or mod.config.fire_protect == true then
	core.register_globalstep(function(dtime)
		mod.timer = mod.timer + dtime
		if mod.timer < mod.config.update_time then
			return
		end
		for _,player in pairs(core.get_connected_players()) do
			local name = player:get_player_name()
			local pos = player:get_pos()
			local hp = player:get_hp()
			if not name or not pos or not hp then
				return
			end
			-- water breathing
			if mod.config.water_protect == true then
				if mod.def[name].water > 0 and
						player:get_breath() < 10 then
					player:set_breath(10)
				end
			end
			-- fire protection
			if mod.config.fire_protect == true then
				local fire_damage = true
				pos.y = pos.y + 1.4 -- head level
				local node_head = core.get_node(pos).name
				pos.y = pos.y - 1.2 -- feet level
				local node_feet = core.get_node(pos).name
				-- is player inside a hot node?
				for _, row in pairs(mod.fire_nodes) do
					-- check fire protection, if not enough then get hurt
					if row[1] == node_head or row[1] == node_feet then
						if fire_damage == true then
							mod:punch(player, "fire")
							last_punch_time[name] = core.get_gametime()
							fire_damage = false
						end
						if hp > 0 and mod.def[name].fire < row[2] then
							hp = hp - row[3] * mod.config.update_time
							player:set_hp(hp)
							break
						end
					end
				end
			end
		end
		mod.timer = 0
	end)
end
