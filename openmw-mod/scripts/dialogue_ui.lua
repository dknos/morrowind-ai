-- dialogue_ui.lua (PLAYER)
-- H near NPC -> open in-panel chat window, lock onto nearest NPC.
-- Type message; Enter or F1 sends it via MorrowindAiDialogueRequest global event.
-- On MorrowindAiDialogueReply -> display NPC reply inside the same panel.

local ui      = require('openmw.ui')
local input   = require('openmw.input')
local self_   = require('openmw.self')
local nearby  = require('openmw.nearby')
local types   = require('openmw.types')
local util    = require('openmw.util')
local async   = require('openmw.async')
local core    = require('openmw.core')
local v2      = util.vector2

local MAX_DIST  = 500
local HAIL_KEY  = input.KEY.H
local SEND_KEY  = input.KEY.F1   -- alternative to Enter
local CLOSE_KEY = input.KEY.Escape

local lockedCtx     = nil        -- current NPC context
local lastReplyText = ''
local inputBuffer   = ''
local window        = nil        -- ui.create handle
local isOpen        = false

local function showMsg(text)
    pcall(function() ui.showMessage(tostring(text or '')) end)
end

local function buildNpcContext(npcObj)
    local ctx = {
        npc_id = '', npc_name = '', npc_race = '',
        npc_class = '', npc_faction = '', location = '',
    }
    pcall(function() ctx.npc_id = tostring(npcObj.recordId or npcObj.id or '') end)
    pcall(function()
        local rec = types.NPC.record(npcObj)
        if rec then
            ctx.npc_name  = tostring(rec.name  or '')
            ctx.npc_race  = tostring(rec.race  or '')
            ctx.npc_class = tostring(rec.class or '')
        end
    end)
    pcall(function()
        if self_.object and self_.object.cell then
            ctx.location = tostring(self_.object.cell.name or '')
        end
    end)
    return ctx
end

local function findNearestNpc()
    local bestObj, bestDist = nil, MAX_DIST + 1
    local playerPos = self_.object.position
    for _, act in ipairs(nearby.actors or {}) do
        if act ~= self_.object and act.type == types.NPC then
            local d = (act.position - playerPos):length()
            if d < bestDist then
                bestDist = d
                bestObj  = act
            end
        end
    end
    return bestObj
end

-- --------------------------------------------------------------------------
-- UI construction
-- --------------------------------------------------------------------------

local function buildLayout()
    local headerText = '[AI] ' ..
        (lockedCtx and (lockedCtx.npc_name ~= '' and lockedCtx.npc_name or lockedCtx.npc_id) or 'No NPC')
    local replyText = lastReplyText ~= '' and ('NPC: ' .. lastReplyText) or '(awaiting reply...)'
    local inputText = '> ' .. inputBuffer .. '_'

    return {
        type = ui.TYPE.Flex,
        props = {
            size = v2(500, 180),
            position = v2(20, 20),
            relativePosition = v2(0, 0),
            horizontal = false,
        },
        content = ui.content {
            { type = ui.TYPE.Text,
              props = { text = headerText, textSize = 20, textColor = util.color.rgb(1, 0.85, 0.4) } },
            { type = ui.TYPE.Text,
              props = { text = replyText, textSize = 16, textColor = util.color.rgb(0.9, 0.9, 0.9),
                        multiline = true, wordWrap = true, size = v2(480, 80) } },
            { type = ui.TYPE.Text,
              props = { text = inputText, textSize = 18, textColor = util.color.rgb(0.6, 0.9, 1.0) } },
            { type = ui.TYPE.Text,
              props = { text = '[Enter/F1 send] [Esc close] [H re-lock]',
                        textSize = 12, textColor = util.color.rgb(0.6, 0.6, 0.6) } },
        },
    }
end

local function refreshUI()
    if not isOpen then return end
    if window then
        window.layout = buildLayout()
        window:update()
    else
        window = ui.create(buildLayout())
    end
end

local function openWindow()
    isOpen = true
    refreshUI()
end

local function closeWindow()
    isOpen = false
    if window then
        pcall(function() window:destroy() end)
        window = nil
    end
end

-- --------------------------------------------------------------------------
-- Send request to GLOBAL ipc_client
-- --------------------------------------------------------------------------

local function sendMessage()
    if not lockedCtx then
        showMsg('[AI] No NPC locked; press H near an NPC first.')
        return
    end
    if inputBuffer == '' then return end
    local payload = {
        npc_id      = lockedCtx.npc_id,
        npc_name    = lockedCtx.npc_name,
        npc_race    = lockedCtx.npc_race,
        npc_class   = lockedCtx.npc_class,
        npc_faction = lockedCtx.npc_faction,
        location    = lockedCtx.location,
        player_text = inputBuffer,
    }
    core.sendGlobalEvent('MorrowindAiDialogueRequest', payload)
    lastReplyText = '(sent: "' .. inputBuffer .. '"; awaiting reply...)'
    inputBuffer = ''
    refreshUI()
end

-- --------------------------------------------------------------------------
-- Input handling
-- --------------------------------------------------------------------------

local KEY = input.KEY

-- Minimal printable-key map for a-z 0-9 space.
local KEYMAP = {
    [KEY.A]='a',[KEY.B]='b',[KEY.C]='c',[KEY.D]='d',[KEY.E]='e',[KEY.F]='f',
    [KEY.G]='g',[KEY.H]='h',[KEY.I]='i',[KEY.J]='j',[KEY.K]='k',[KEY.L]='l',
    [KEY.M]='m',[KEY.N]='n',[KEY.O]='o',[KEY.P]='p',[KEY.Q]='q',[KEY.R]='r',
    [KEY.S]='s',[KEY.T]='t',[KEY.U]='u',[KEY.V]='v',[KEY.W]='w',[KEY.X]='x',
    [KEY.Y]='y',[KEY.Z]='z',
    [KEY._0]='0',[KEY._1]='1',[KEY._2]='2',[KEY._3]='3',[KEY._4]='4',
    [KEY._5]='5',[KEY._6]='6',[KEY._7]='7',[KEY._8]='8',[KEY._9]='9',
    [KEY.Space]=' ',
}

local function onKeyPress(key)
    if not key then return end
    local code = key.code

    -- H always toggles/locks (even when closed)
    if code == HAIL_KEY and not isOpen then
        local npc = findNearestNpc()
        if not npc then
            showMsg('[AI] No NPC nearby.')
            return
        end
        lockedCtx = buildNpcContext(npc)
        lastReplyText = ''
        inputBuffer = ''
        openWindow()
        return
    end

    if not isOpen then return end

    if code == CLOSE_KEY then
        closeWindow()
        return
    end

    if code == KEY.Enter or code == KEY.NumpadEnter or code == SEND_KEY then
        sendMessage()
        return
    end

    if code == HAIL_KEY then
        -- re-lock to new nearest NPC while panel open
        local npc = findNearestNpc()
        if npc then
            lockedCtx = buildNpcContext(npc)
            lastReplyText = ''
            refreshUI()
        end
        return
    end

    if code == KEY.Backspace then
        if #inputBuffer > 0 then
            inputBuffer = inputBuffer:sub(1, -2)
            refreshUI()
        end
        return
    end

    local ch = KEYMAP[code]
    if ch then
        if key.withShift and ch:match('%a') then ch = ch:upper() end
        inputBuffer = inputBuffer .. ch
        refreshUI()
    end
end

local function onDialogueReply(data)
    if not data then return end
    local text = tostring(data.npc_response or '')
    if text == '' then text = '...' end
    lastReplyText = text
    if isOpen then
        refreshUI()
    else
        showMsg('[NPC] ' .. text)
    end
end

local function onInit()
    showMsg('[AI mod] Press H near an NPC to open chat. Enter/F1 send, Esc close.')
end

return {
    engineHandlers = {
        onInit     = onInit,
        onKeyPress = onKeyPress,
    },
    eventHandlers = {
        MorrowindAiDialogueReply = onDialogueReply,
    },
}
