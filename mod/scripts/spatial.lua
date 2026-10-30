-- Spatial planning queries (v3): find_buildable_area (nearest clear rectangle
-- on explored ground) and describe_prototype (geometry/energy/fluid-connection
-- facts about items, entities, recipes and fluids by name). Instant and
-- read-only. Ported from llm-play-factorio (scripts/spatial.lua); can_place and
-- scan_area are covered by the existing can_place query and map_view.

AISpatial = {}
local M = AISpatial

local AREA_DEFAULT_DISTANCE = 50
local AREA_MAX_DISTANCE = 100
local AREA_MAX_SIDE = 100
local AREA_RING_STEP = 2
local DESCRIBE_MAX_NAMES = 10

local function require_position(pos, message)
  if type(pos) ~= "table" or tonumber(pos.x) == nil or tonumber(pos.y) == nil then
    error(message, 0)
  end
  return { x = tonumber(pos.x), y = tonumber(pos.y) }
end


-- Water test for one tile. 2.0 names the collision layer "water_tile"; we
-- probe once per session (falling back to the hyphenated spelling, then to
-- reading the prototype collision mask directly) so a rename never breaks us.
local water_layer -- nil = not probed yet, false = probing failed, string = layer id

local function tile_is_water(tile)
  if water_layer then
    local ok, res = pcall(function() return tile.collides_with(water_layer) end)
    if ok then return res == true end
  end
  if water_layer == nil then
    for _, layer in ipairs({ "water_tile", "water-tile" }) do
      local ok, res = pcall(function() return tile.collides_with(layer) end)
      if ok then
        water_layer = layer
        return res == true
      end
    end
    water_layer = false
  end
  local ok, mask = pcall(function() return tile.prototype.collision_mask end)
  if ok and type(mask) == "table" and type(mask.layers) == "table" then
    return mask.layers["water_tile"] == true or mask.layers["water-tile"] == true
  end
  return false
end

local function is_water_at(surface, x, y)
  local ok, tile = pcall(surface.get_tile, x, y)
  if not ok or not tile then return false end
  return tile_is_water(tile)
end

M.is_water_at = is_water_at


-- Normalize a Factorio Vector ({x=,y=} or {1,2}) to a plain {x, y} table.
local function vec_xy(v)
  if type(v) ~= "table" then return nil end
  local x = tonumber(v.x) or tonumber(v[1])
  local y = tonumber(v.y) or tonumber(v[2])
  if x == nil or y == nil then return nil end
  return { x = x, y = y }
end

-- Sorted list of the keys of a {name = true} dictionary (nil when empty).
local function sorted_keys(dict)
  if type(dict) ~= "table" then return nil end
  local keys = {}
  for k in pairs(dict) do keys[#keys + 1] = k end
  if #keys == 0 then return nil end
  table.sort(keys)
  return keys
end

local function ring_offsets(d)
  if d == 0 then return { { 0, 0 } } end
  local offsets = {}
  for x = -d, d, AREA_RING_STEP do
    offsets[#offsets + 1] = { x, -d }
    offsets[#offsets + 1] = { x, d }
  end
  for y = -d + AREA_RING_STEP, d - AREA_RING_STEP, AREA_RING_STEP do
    offsets[#offsets + 1] = { -d, y }
    offsets[#offsets + 1] = { d, y }
  end
  return offsets
end

-- ctx = query context ({surface, force, character})
function M.find_buildable_area(ctx, params)
  local c = ctx.character
  local surface = ctx.surface

  local width = math.floor(tonumber(params.width) or 0)
  local height = math.floor(tonumber(params.height) or 0)
  if width < 1 or height < 1 then
    error("find_buildable_area requires width and height (whole tile counts, at least 1)", 0)
  end
  if width > AREA_MAX_SIDE or height > AREA_MAX_SIDE then
    error(string.format(
      "that rectangle is huge — keep width and height at %d tiles or less", AREA_MAX_SIDE))
  end
  local near = require_position(params.near, "find_buildable_area requires near = {x, y}")
  local max_distance = math.floor(tonumber(params.max_distance) or AREA_DEFAULT_DISTANCE)
  max_distance = math.max(0, math.min(max_distance, AREA_MAX_DISTANCE))

  -- Candidate rectangles are centered on `near`, then shifted in expanding
  -- rings. Water is memoized per tile since neighboring candidates overlap.
  local base_x = math.floor(near.x) - math.floor(width / 2)
  local base_y = math.floor(near.y) - math.floor(height / 2)

  local water_memo = {}
  local function memo_water(x, y)
    local key = x .. "," .. y
    local v = water_memo[key]
    if v == nil then
      v = is_water_at(surface, x, y)
      water_memo[key] = v
    end
    return v
  end

  local known_memo = {}
  local function rect_known(tlx, tly)
    for cy = math.floor(tly / 32), math.floor((tly + height - 1) / 32) do
      for cx = math.floor(tlx / 32), math.floor((tlx + width - 1) / 32) do
        local k = cx .. "," .. cy
        local v = known_memo[k]
        if v == nil then
          v = not AIVision.enabled() or AIVision.is_known(surface, ctx.force, { x = cx * 32, y = cy * 32 })
          known_memo[k] = v
        end
        if not v then return false end
      end
    end
    return true
  end

  -- Returns the tree count when the rect works, nil when it doesn't.
  -- Only explored ground counts (fog of war).
  local function try_spot(tlx, tly)
    if not rect_known(tlx, tly) then return nil end
    local trees = 0
    local found = surface.find_entities_filtered({
      area = { { tlx, tly }, { tlx + width, tly + height } },
    })
    for _, e in ipairs(found) do
      if e.valid and e ~= c and e.type ~= "character" then
        if e.type == "tree" then
          trees = trees + 1
        else
          return nil
        end
      end
    end
    for ty = tly, tly + height - 1 do
      for tx = tlx, tlx + width - 1 do
        if memo_water(tx, ty) then return nil end
      end
    end
    return trees
  end

  for d = 0, max_distance, AREA_RING_STEP do
    for _, off in ipairs(ring_offsets(d)) do
      local tlx, tly = base_x + off[1], base_y + off[2]
      local trees = try_spot(tlx, tly)
      if trees then
        return {
          center = { x = tlx + width / 2, y = tly + height / 2 },
          top_left = { x = tlx, y = tly },
          trees_in_area = trees,
        }
      end
    end
  end

  error(string.format(
    "no free %dx%d spot on explored ground within %d tiles of (%.0f, %.0f)",
    width, height, max_distance, near.x, near.y))
end


local function describe_entity(ent, item_name)
  local out = { kind = "entity", entity = ent.name, type = ent.type }

  if not item_name then
    -- Which item places this entity (nice to know when the caller asked by
    -- entity name).
    local ok, items = pcall(function() return ent.items_to_place_this end)
    if ok and type(items) == "table" and type(items[1]) == "table" and items[1].name then
      item_name = items[1].name
    end
  end
  if item_name then out.placed_by_item = item_name end

  local ok, v

  ok, v = pcall(function() return ent.tile_width end)
  if ok and type(v) == "number" then out.tile_width = v end
  ok, v = pcall(function() return ent.tile_height end)
  if ok and type(v) == "number" then out.tile_height = v end

  -- Mining drills: where the ore comes out, at direction 0 (rotate with the
  -- entity — 4:(x,y)->(-y,x), 8:(-x,-y), 12:(y,-x)).
  ok, v = pcall(function() return ent.vector_to_place_result end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.drop_offset = offset end
  end

  local burner, electric
  ok, v = pcall(function() return ent.burner_prototype end)
  if ok then burner = v end
  ok, v = pcall(function() return ent.electric_energy_source_prototype end)
  if ok then electric = v end
  out.energy = (burner and "burner") or (electric and "electric") or "none"
  if burner then
    ok, v = pcall(function() return burner.fuel_categories end)
    if ok then out.fuel_categories = sorted_keys(v) end
  end

  ok, v = pcall(function() return ent.mining_speed end)
  if ok and type(v) == "number" then out.mining_speed = v end

  ok, v = pcall(function() return ent.crafting_categories end)
  if ok then out.crafting_categories = sorted_keys(v) end

  -- Gun range lives on the ITEM prototype; turrets carry theirs on the entity.
  if item_name then
    local it = prototypes.item[item_name]
    if it then
      ok, v = pcall(function() return it.attack_parameters end)
      if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
    end
  end
  if out.range == nil then
    ok, v = pcall(function() return ent.attack_parameters end)
    if ok and type(v) == "table" and type(v.range) == "number" then out.range = v.range end
  end

  ok, v = pcall(function() return ent.inserter_pickup_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_pickup_offset = offset end
  end
  ok, v = pcall(function() return ent.inserter_drop_position end)
  if ok then
    local offset = vec_xy(v)
    if offset then out.inserter_drop_offset = offset end
  end

  ok, v = pcall(function() return ent.belt_speed end)
  if ok and type(v) == "number" then out.belt_speed = v end

  -- Fluid connections for the entity facing north: where a pipe must sit
  -- (offset from the entity's centre) and which way fluid may flow. Rotate
  -- the offsets with the entity's facing.
  pcall(function()
    local fbs = ent.fluidbox_prototypes
    if not fbs or #fbs == 0 then return end
    local conns = {}
    for i, fb in ipairs(fbs) do
      for _, pc in ipairs(fb.pipe_connections or {}) do
        local at = pc.positions and pc.positions[1]
        if at then
          local d = pc.direction or 0
          local u = ({ [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } })[d] or { 0, 0 }
          conns[#conns + 1] = {
            fluidbox = i,
            role = fb.production_type,          -- "input", "output", "input-output" or "none"
            filter = fb.filter and fb.filter.name or nil,
            flow = pc.flow_direction,           -- "input", "output" or "input-output"
            type = pc.connection_type,          -- "normal" or "underground"
            at = { x = at.x, y = at.y },        -- the entity's own connection tile
            pipe_at = { x = at.x + u[1], y = at.y + u[2] }, -- where the pipe goes
            side = ({ [0] = "north", [4] = "east", [8] = "south", [12] = "west" })[d],
          }
        end
      end
    end
    if #conns > 0 then out.fluid_connections = conns end
  end)

  return out
end

local function describe_recipe(rec, force)
  local ingredients, products = {}, {}
  for _, ing in ipairs(rec.ingredients or {}) do
    if ing.name then
      ingredients[ing.name] = (ingredients[ing.name] or 0) + (ing.amount or 1)
    end
  end
  for _, p in ipairs(rec.products or {}) do
    if p.name then
      products[p.name] = (products[p.name] or 0) + (p.amount or p.amount_max or 1)
    end
  end
  local force_recipe = force.recipes[rec.name]
  -- category was a string on 2.0; 2.1 dropped it (recipes list several categories)
  local ok, category = pcall(function() return rec.category end)
  if not ok then
    local ok2, cats = pcall(function() return rec.categories end)
    category = ok2 and sorted_keys(cats) or nil
  end
  return {
    name = rec.name,
    ingredients = ingredients,
    products = products,
    energy = rec.energy,
    category = category,
    enabled = (force_recipe and force_recipe.enabled) or false,
  }
end

local function describe_item(it)
  local out = { name = it.name, stack_size = it.stack_size }
  local ok, v = pcall(function() return it.fuel_value end)
  if ok and type(v) == "number" and v > 0 then
    out.fuel_value_mj = v / 1e6
    pcall(function() out.fuel_category = it.fuel_category end)
  end
  pcall(function() if it.place_result then out.places = it.place_result.name end end)
  return out
end

-- Power/speed facts shared by every entity kind (J/tick -> kW = x * 60 / 1000).
local function energy_facts(ent, out)
  local ok, v = pcall(function() return ent.get_max_energy_usage() end)
  if ok and type(v) == "number" and v > 0 then out.power_kw = v * 60 / 1000 end
  ok, v = pcall(function() return ent.get_max_energy_production() end)
  if ok and type(v) == "number" and v > 0 then out.power_output_kw = v * 60 / 1000 end
  ok, v = pcall(function() return ent.get_crafting_speed() end)
  if ok and type(v) == "number" and v > 0 then out.crafting_speed = v end
  ok, v = pcall(function() return ent.get_mining_drill_radius() end)
  if ok and type(v) == "number" and v > 0 then out.mining_area = math.floor(2 * v + 0.5) end
  ok, v = pcall(function() return ent.resource_categories end)
  if ok and type(v) == "table" then out.resource_categories = sorted_keys(v) end
  ok, v = pcall(function() return ent.module_inventory_size end)
  if ok and type(v) == "number" and v > 0 then out.module_slots = v end
  ok, v = pcall(function() return ent.get_inserter_rotation_speed() end)
  if ok and type(v) == "number" and v > 0 then out.inserter_rotation_speed = v end
  ok, v = pcall(function() return ent.get_inventory_size(defines.inventory.chest) end)
  if ok and type(v) == "number" and v > 0 then out.inventory_slots = v end
  ok, v = pcall(function() return ent.get_researching_speed() end)
  if ok and type(v) == "number" and v > 0 then out.researching_speed = v end
end

-- Every view of a name at once: the item (stack size, fuel value), the
-- entity it places (geometry, power, speeds) and the recipe that makes it.
function M.describe_prototype(ctx, params)
  local names = params.names
  if type(names) ~= "table" or #names == 0 then
    error('describe_prototype requires names = ["burner-mining-drill", ...]')
  end
  if #names > DESCRIBE_MAX_NAMES then
    error(string.format(
      "describe_prototype takes at most %d names per call — split the list and call again",
      DESCRIBE_MAX_NAMES))
  end

  local force = ctx.force

  local out = {}
  for _, name in ipairs(names) do
    if type(name) == "string" then
      local r = {}
      local item = prototypes.item[name]
      if item then r.item = describe_item(item) end
      local ent = (item and item.place_result) or prototypes.entity[name]
      if ent then
        r.entity = describe_entity(ent, item and item.place_result and name or nil)
        energy_facts(ent, r.entity)
      end
      if prototypes.recipe[name] then r.recipe = describe_recipe(prototypes.recipe[name], force) end
      local fluid = prototypes.fluid[name]
      if fluid then
        r.fluid = { name = name, default_temperature = fluid.default_temperature, max_temperature = fluid.max_temperature }
      end
      if next(r) == nil then r.unknown = true end
      out[name] = r
    end
  end
  return out
end

return AISpatial
