-- Asynchronous walking (v3).
--
-- Skills run synchronously inside one tick, but walking takes many: the
-- character has to hold a walking_state every tick until it arrives. walk_to()
-- records the destination in storage.ai_player.walk and step() (called from
-- on_tick) steers toward it. There is deliberately no pathfinding: a straight
-- line that gets blocked fails and the caller decides what to do next.
--
-- Outcome of the last walk lives in storage.ai_player.walk_result:
--   {status = "arrived"|"timeout"|"blocked"|"cancelled"|"lost", tick, target, pos}

AIMovement = {}

local LOG_FILE = "ai-player/errors.log"

local REACH         = 1.5   -- tiles from the target counted as arrived
local STUCK_TICKS   = 45    -- ticks without real progress before giving up
local STUCK_EPSILON = 0.02  -- tiles per tick below which we count as not moving
local GRACE_TICKS   = 120   -- slack added on top of the estimated travel time
local MAX_TIMEOUT   = 60 * 60 * 5  -- hard cap: 5 minutes of game time
local WALK_SPEED    = 0.15  -- tiles per tick of an unboosted character (conservative)

local function debug_print(msg)
  if settings.global["ai-player-debug-chat"] and settings.global["ai-player-debug-chat"].value then
    game.print("[AI] " .. msg, {r=0.7, g=0.9, b=1})
  end
end

local function log_line(msg)
  helpers.write_file(LOG_FILE, string.format("[tick=%d] walk: %s\n", game.tick, msg), true)
end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- Eight-way direction closest to the vector (dx, dy). Factorio's y axis points
-- south, so north is -y.
local function direction_to(dx, dy)
  local angle = math.atan2(dx, -dy)  -- 0 = north, clockwise positive
  local octant = math.floor(angle / (math.pi / 4) + 0.5) % 8
  return octant * 2  -- defines.direction.north == 0, northeast == 2, ...
end

local function finish(character, status, extra)
  local w = storage.ai_player.walk
  storage.ai_player.walk = nil
  if character and character.valid then
    character.walking_state = {walking = false}
  end
  local pos = character and character.valid and character.position or nil
  storage.ai_player.walk_result = {
    status = status, tick = game.tick, target = w and w.target, pos = pos,
  }
  local line = string.format("%s target=(%.1f,%.1f) pos=%s", status,
    w and w.target.x or 0, w and w.target.y or 0,
    pos and string.format("(%.1f,%.1f)", pos.x, pos.y) or "none")
  log_line(line)
  debug_print("walk " .. line)
  -- Surface the outcome in the next decision's E1 feedback, since the skill that
  -- started the walk returned long ago.
  local mem = storage.ai_player.memory
  if mem then
    mem.last_action_results = mem.last_action_results or {}
    table.insert(mem.last_action_results, {
      action = "walk", ok = (status == "arrived"), detail = line,
    })
  end
end

-- Start walking toward target ({x=,y=}). Replaces any walk in progress.
-- Returns (ok, detail) like a skill. ok=true only means the walk started (or
-- we are already there); the outcome arrives later via walk_result.
function AIMovement.walk_to(character, target, timeout)
  if not (character and character.valid) then return false, "walk: no valid character" end
  local x, y = tonumber(target and target.x), tonumber(target and target.y)
  if not (x and y) then return false, "walk: target must be {x=N, y=N}" end
  target = {x = x, y = y}

  local d = dist(character.position, target)
  if d <= REACH then
    storage.ai_player.walk = nil
    return true, string.format("already at (%.0f, %.0f)", x, y)
  end

  local speed = (character.character_running_speed or WALK_SPEED)
  if speed <= 0 then speed = WALK_SPEED end
  local budget = math.min(timeout or (math.ceil(d / speed) + GRACE_TICKS), MAX_TIMEOUT)
  storage.ai_player.walk = {
    target = target, started = game.tick, deadline = game.tick + budget,
    last_pos = {x = character.position.x, y = character.position.y}, stuck = 0,
  }
  log_line(string.format("start from (%.1f,%.1f) to (%.1f,%.1f) dist=%.1f budget=%d",
    character.position.x, character.position.y, x, y, d, budget))
  return true, string.format("walking to (%.0f, %.0f), %.0f tiles, ~%d ticks — check position next turn",
    x, y, d, math.ceil(d / speed))
end

function AIMovement.cancel(character)
  if storage.ai_player and storage.ai_player.walk then finish(character, "cancelled") end
end

-- Compact view for status queries / prompts. nil when idle.
function AIMovement.status()
  local w = storage.ai_player and storage.ai_player.walk
  if not w then return nil end
  return {target = w.target, ticks_left = w.deadline - game.tick}
end

-- Called every tick from on_tick, independent of the autonomy gate.
function AIMovement.step()
  local w = storage.ai_player and storage.ai_player.walk
  if not w then return end

  local character = AICharacter.get_character()
  if not (character and character.valid) then
    finish(nil, "lost")
    return
  end

  local pos = character.position
  if dist(pos, w.target) <= REACH then
    finish(character, "arrived")
    return
  end
  if game.tick >= w.deadline then
    finish(character, "timeout")
    return
  end

  -- Progress check: only samples movement, so standing still against a wall
  -- (or a cliff/water edge) fails fast instead of burning the whole timeout.
  if dist(pos, w.last_pos) < STUCK_EPSILON then
    w.stuck = w.stuck + 1
    if w.stuck >= STUCK_TICKS then
      finish(character, "blocked")
      return
    end
  else
    w.stuck = 0
  end
  w.last_pos = {x = pos.x, y = pos.y}

  character.walking_state = {
    walking = true, direction = direction_to(w.target.x - pos.x, w.target.y - pos.y),
  }
end

return AIMovement
