-- ipc_client.lua (GLOBAL)
-- Receives dialogue requests from PLAYER script, writes request.json, polls
-- response.json, and relays NPC replies back to the player.

local core  = require('openmw.core')
local world = require('openmw.world')
local json  = require('scripts.json')

local io_lib = io or (pcall(require, 'io') and require('io')) or nil
local os_lib = os or (pcall(require, 'os') and require('os')) or nil

local IPC_DIR        = '/home/nemoclaw/morrowind-ai/ipc/'
local REQUEST_FILE   = IPC_DIR .. 'request.json'
local RESPONSE_FILE  = IPC_DIR .. 'response.json'
local POLL_INTERVAL  = 0.25

local pollTimer = 0

local function write_file(path, content)
    if not io_lib then
        print('[morrowind-ai] io unavailable; cannot write ' .. tostring(path))
        return false
    end
    local ok, err = pcall(function()
        local f, ferr = io_lib.open(path, 'w')
        if not f then error('io.open: ' .. tostring(ferr)) end
        f:write(content); f:close()
    end)
    if not ok then
        print('[morrowind-ai] write_file error for ' .. tostring(path) .. ': ' .. tostring(err))
    end
    return ok
end

local function read_file(path)
    if not io_lib then return nil end
    local out
    pcall(function()
        local f = io_lib.open(path, 'r')
        if not f then return end
        out = f:read('*a'); f:close()
    end)
    return out
end

local function delete_file(path)
    if not os_lib then return end
    pcall(function() os_lib.remove(path) end)
end

local function onDialogueRequest(data)
    if not data then return end
    local payload = {
        type        = 'dialogue',
        npc_id      = tostring(data.npc_id or ''),
        npc_name    = tostring(data.npc_name or ''),
        npc_race    = tostring(data.npc_race or ''),
        npc_class   = tostring(data.npc_class or ''),
        npc_faction = tostring(data.npc_faction or ''),
        location    = tostring(data.location or ''),
        player_text = tostring(data.player_text or ''),
    }
    local ok, enc = pcall(json.encode, payload)
    if ok then
        local wrote = write_file(REQUEST_FILE, enc)
        print('[morrowind-ai] Sent dialogue request: ' .. payload.npc_id
              .. ' <- "' .. payload.player_text .. '" (wrote=' .. tostring(wrote) .. ')')
    else
        print('[morrowind-ai] JSON encode error: ' .. tostring(enc))
    end
end

local function onUpdate(dt)
    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0

    local content = read_file(RESPONSE_FILE)
    if not content or content == '' then return end

    local ok, decoded = pcall(json.decode, content)
    if not ok or type(decoded) ~= 'table' then return end

    delete_file(RESPONSE_FILE)

    local text = tostring(decoded.npc_response or decoded.response or '')
    local player
    pcall(function()
        if world.players and world.players[1] then player = world.players[1] end
    end)
    if player then
        player:sendEvent('MorrowindAiDialogueReply', {
            npc_id = tostring(decoded.npc_id or ''),
            npc_response = text,
        })
    end
end

delete_file(RESPONSE_FILE)
print('[morrowind-ai][ipc_client] Global IPC client loaded (Linux, ' .. IPC_DIR
      .. '). io=' .. tostring(io_lib ~= nil) .. ' os=' .. tostring(os_lib ~= nil))

return {
    engineHandlers = { onUpdate = onUpdate },
    eventHandlers  = { MorrowindAiDialogueRequest = onDialogueRequest },
}
