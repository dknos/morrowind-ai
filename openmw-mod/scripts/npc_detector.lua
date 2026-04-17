-- npc_detector.lua
-- GLOBAL script.
-- Scans all active actors every second (throttled).
-- When two named NPCs are within PROXIMITY_THRESHOLD units and cooldown has
-- elapsed, fires a [MWAI_REQ] print line that openmw_log_bridge.py tails.
--
-- Windows-compatible: uses print() IPC, no io.open.
-- OpenMW 0.49, Lua 5.1

local core  = require('openmw.core')
local world = require('openmw.world')
local types = require('openmw.types')
local json  = require('scripts.json')

-- ============================================================
-- Configuration
-- ============================================================

local SCAN_INTERVAL       = 1.0    -- seconds between scans
local PROXIMITY_THRESHOLD = 300    -- engine units
local PAIR_COOLDOWN       = 60.0   -- seconds before same pair fires again
local REQ_COUNTER         = 0      -- incrementing req_id

-- ============================================================
-- State
-- ============================================================

local scanTimer  = 0
local pairTimers = {}  -- "id_a|id_b" -> last trigger time

-- ============================================================
-- Helpers
-- ============================================================

local function distance(posA, posB)
    local dx = posA.x - posB.x
    local dy = posA.y - posB.y
    local dz = posA.z - posB.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function pairKey(idA, idB)
    return idA < idB and (idA .. '|' .. idB) or (idB .. '|' .. idA)
end

local function isNamedNpc(actor)
    local ok, result = pcall(function()
        if not types.NPC.objectIsInstance(actor) then return false end
        local rec = types.NPC.record(actor)
        return (rec.name or '') ~= ''
    end)
    return ok and result
end

local function npcInfo(actor)
    local info = { id = '', name = '', race = '', faction = '', position = nil }
    pcall(function()
        info.id = tostring(actor.id or actor.recordId or '')
        local rec = types.NPC.record(actor)
        info.name    = tostring(rec.name  or '')
        info.race    = tostring(rec.race  or 'Unknown')
        info.faction = tostring(rec.faction or '')
        info.position = actor.position
    end)
    return info
end

-- ============================================================
-- Core scan logic
-- ============================================================

local function scanActors()
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
        print('[npc_detector] scan error: ' .. tostring(err))
        return
    end

    local now = core.getSimulationTime()

    local location = ''
    pcall(function()
        local player = world.getPlayerObject and world.getPlayerObject()
        if player and player.cell then location = tostring(player.cell.name or '') end
    end)

    for i = 1, #npcs do
        for j = i + 1, #npcs do
            local a, b = npcs[i], npcs[j]
            if a.position and b.position then
                local dist = distance(a.position, b.position)
                if dist <= PROXIMITY_THRESHOLD then
                    local key = pairKey(a.id, b.id)
                    local lastTime = pairTimers[key] or -math.huge
                    if (now - lastTime) >= PAIR_COOLDOWN then
                        pairTimers[key] = now
                        REQ_COUNTER = REQ_COUNTER + 1
                        local payload = {
                            type         = 'npc_npc',
                            req_id       = 'npc_npc-' .. tostring(math.floor(now)) .. '-' .. REQ_COUNTER,
                            npc_a_id     = a.id,
                            npc_a_name   = a.name,
                            npc_a_race   = a.race,
                            npc_a_faction = a.faction,
                            npc_b_id     = b.id,
                            npc_b_name   = b.name,
                            npc_b_race   = b.race,
                            npc_b_faction = b.faction,
                            location     = location,
                            timestamp    = now,
                        }
                        local encOk, encoded = pcall(json.encode, payload)
                        if encOk then
                            print('[MWAI_REQ] ' .. encoded)
                            print(string.format('[npc_detector] D2D fired: %s + %s (%.1f units)',
                                a.name, b.name, dist))
                        else
                            print('[npc_detector] JSON encode error: ' .. tostring(encoded))
                        end
                        -- one event per scan to avoid log spam
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

print('[morrowind-ai][npc_detector] Loaded (print-IPC, Windows-compatible).')

return {
    engineHandlers = { onUpdate = onUpdate },
}
