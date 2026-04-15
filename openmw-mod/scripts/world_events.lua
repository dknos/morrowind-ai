-- world_events.lua
-- GLOBAL script.
-- Minimal stub for MVP: event-driven world actions (spawn_enemy, drop_item,
-- message) triggered via global Lua events, NOT filesystem polling.
-- Python bridge can fire these via a separate IPC path later; for now this
-- keeps the mod loadable without sandbox-violating io.popen/ls calls.
--
-- OpenMW 0.49, Lua 5.1

local core  = require('openmw.core')
local world = require('openmw.world')
local types = require('openmw.types')
local util  = require('openmw.util')

local function getPlayer()
    if world.players and world.players[1] then return world.players[1] end
    return nil
end

-- Event handlers (triggered via core.sendGlobalEvent from other scripts) ----

local function onSpawnEnemy(ev)
    if not ev or not ev.creature_id then return end
    local ok, err = pcall(function()
        local pos = util.vector3(tonumber(ev.x) or 0, tonumber(ev.y) or 0, tonumber(ev.z) or 0)
        local player = getPlayer()
        local cellName = tostring(ev.cell or (player and player.cell and player.cell.name) or '')
        if cellName == '' then return end
        local obj = world.createObject(ev.creature_id, 1)
        obj:teleport(cellName, pos, util.vector3(0, 0, 0))
    end)
    if not ok then print('[world_events] spawn_enemy error: ' .. tostring(err)) end
end

local function onDropItem(ev)
    if not ev or not ev.item_id then return end
    local count = math.max(1, math.floor(tonumber(ev.count) or 1))
    local ok, err = pcall(function()
        local player = getPlayer()
        if not player then return end
        types.Actor.inventory(player):add(ev.item_id, count)
    end)
    if not ok then print('[world_events] drop_item error: ' .. tostring(err)) end
end

local function onMessage(ev)
    if not ev or not ev.text then return end
    local player = getPlayer()
    if player then
        player:sendEvent('MorrowindAiMessage', { text = tostring(ev.text) })
    end
end

print('[morrowind-ai][world_events] Loaded (event-driven; filesystem polling disabled).')

return {
    eventHandlers = {
        MorrowindAiSpawnEnemy = onSpawnEnemy,
        MorrowindAiDropItem   = onDropItem,
        MorrowindAiMessage    = onMessage,
    },
}
