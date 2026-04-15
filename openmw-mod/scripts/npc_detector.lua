-- npc_detector.lua
-- GLOBAL script.
-- Scans all active actors every frame (throttled).
-- Detects when two named NPCs are within 300 units of each other.
-- Writes an npc_npc event to ~/morrowind-ai/ipc/request.json.
--
-- NOTE: Global scripts do NOT have openmw.nearby.
-- We use openmw.world.activeActors to enumerate all loaded actors.
--
-- OpenMW 0.49, Lua 5.1

local core  = require('openmw.core')
local world = require('openmw.world')
local types = require('openmw.types')

local json  = require('scripts.json')

-- ============================================================
-- Configuration
-- ============================================================

local REQUEST_FILE        = '/home/nemoclaw/morrowind-ai/ipc/request.json'
local SCAN_INTERVAL       = 1.0    -- seconds between actor scans
local PROXIMITY_THRESHOLD = 300    -- units (OpenMW engine units)
local PAIR_COOLDOWN       = 60.0   -- seconds before the same pair fires again

-- ============================================================
-- State
-- ============================================================

local scanTimer  = 0
local pairTimers = {}  -- key: "id_a|id_b" -> timestamp of last trigger

-- ============================================================
-- Helpers
-- ============================================================

local function write_file(path, content)
    local ok, err = pcall(function()
        local f, ferr = io.open(path, 'w')
        if not f then error('io.open: ' .. tostring(ferr)) end
        f:write(content)
        f:close()
    end)
    if not ok then
        print('[npc_detector] write_file error: ' .. tostring(err))
        return false
    end
    return true
end

-- Euclidean distance between two openmw.util.Vector3 positions.
local function distance(posA, posB)
    local dx = posA.x - posB.x
    local dy = posA.y - posB.y
    local dz = posA.z - posB.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Canonical pair key — always lower id first to avoid (A,B) vs (B,A) duplicates.
local function pairKey(idA, idB)
    if idA < idB then
        return idA .. '|' .. idB
    else
        return idB .. '|' .. idA
    end
end

-- Determine whether an actor is a named NPC (not a generic creature or unnamed service NPC).
-- In OpenMW 0.49, types.NPC identifies human/mer NPCs.
-- We also require a non-empty name.
local function isNamedNpc(actor)
    local ok, result = pcall(function()
        if not types.NPC.objectIsInstance(actor) then return false end
        local rec = types.NPC.record(actor)
        local name = rec.name or ''
        return name ~= ''
    end)
    if not ok then return false end
    return result
end

-- Collect lightweight info table from an NPC actor.
local function npcInfo(actor)
    local info = {
        id       = '',
        name     = '',
        position = nil,
    }
    local ok, err = pcall(function()
        info.id       = tostring(actor.id or actor.recordId or '')
        local rec     = types.NPC.record(actor)
        info.name     = tostring(rec.name or '')
        info.position = actor.position
    end)
    if not ok then
        print('[npc_detector] npcInfo error: ' .. tostring(err))
    end
    return info
end

-- ============================================================
-- Core scan logic
-- ============================================================

local function scanActors()
    -- Collect all active NPC actors
    local npcs = {}
    local ok, err = pcall(function()
        for _, actor in ipairs(world.activeActors) do
            if isNamedNpc(actor) then
                local info = npcInfo(actor)
                if info.id ~= '' and info.position then
                    npcs[#npcs + 1] = info
                end
            end
        end
    end)
    if not ok then
        print('[npc_detector] scan error collecting actors: ' .. tostring(err))
        return
    end

    -- Current simulation time for cooldown checks
    local now = core.getSimulationTime()

    -- Current cell name for the event payload
    local location = ''
    local lok, lerr = pcall(function()
        -- In global scripts we don't have a player reference directly.
        -- Use the first actor's cell as a proxy, or leave blank.
        if #npcs > 0 then
            -- actor.cell is available in OpenMW 0.49 global scope
            -- We'll iterate actors looking for the player-owned cell later.
            -- For now use the world's player object if available.
            local player = world.getPlayerObject and world.getPlayerObject()
            if player then
                local cell = player.cell
                if cell then location = tostring(cell.name or '') end
            end
        end
    end)
    if not lok then
        print('[npc_detector] cell lookup error: ' .. tostring(lerr))
    end

    -- Check all NPC pairs for proximity
    for i = 1, #npcs do
        for j = i + 1, #npcs do
            local a = npcs[i]
            local b = npcs[j]

            -- Skip if either position is nil
            if a.position and b.position then
                local dist = distance(a.position, b.position)
                if dist <= PROXIMITY_THRESHOLD then
                    local key = pairKey(a.id, b.id)
                    local lastTime = pairTimers[key] or -math.huge

                    -- Only fire if cooldown has elapsed
                    if (now - lastTime) >= PAIR_COOLDOWN then
                        pairTimers[key] = now

                        local payload = {
                            type      = 'npc_npc',
                            npc_a_id  = a.id,
                            npc_b_id  = b.id,
                            npc_a_name = a.name,
                            npc_b_name = b.name,
                            location  = location,
                            timestamp = now,
                        }

                        local encoded = ''
                        local encOk, encErr = pcall(function()
                            encoded = json.encode(payload)
                        end)
                        if encOk then
                            local wrote = write_file(REQUEST_FILE, encoded)
                            if wrote then
                                print(string.format(
                                    '[npc_detector] NPC pair detected: %s + %s (%.1f units)',
                                    a.name, b.name, dist))
                            end
                        else
                            print('[npc_detector] JSON encode error: ' .. tostring(encErr))
                        end

                        -- Only write one event per scan to avoid overwriting
                        -- request.json with a second pair immediately.
                        return
                    end
                end
            end
        end
    end
end

-- ============================================================
-- Script engine interface
-- ============================================================

local function onUpdate(dt)
    scanTimer = scanTimer + dt
    if scanTimer < SCAN_INTERVAL then return end
    scanTimer = 0
    scanActors()
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
