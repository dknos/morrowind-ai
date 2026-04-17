-- dialogue_ui.lua (PLAYER)
-- H near NPC -> lock NPC, send auto-greeting, open chat panel.
-- Type message; Enter or F1 sends it.
-- On MorrowindAiDialogueReply -> display NPC reply in the panel.
-- On MorrowindAiNpcSpeech -> show ambient NPC-to-NPC lines as HUD messages.
-- On MorrowindAiAction -> execute NPC-triggered world actions.
--
-- OpenMW 0.49, Lua 5.1

local ui      = require('openmw.ui')
local input   = require('openmw.input')
local self_   = require('openmw.self')
local nearby  = require('openmw.nearby')
local types   = require('openmw.types')
local util    = require('openmw.util')
local core    = require('openmw.core')
local v2      = util.vector2

local MAX_DIST  = 500
local HAIL_KEY  = input.KEY.H
local SEND_KEY  = input.KEY.F1
local CLOSE_KEY = input.KEY.Escape

local lockedCtx     = nil
local lastReplyText = ''
local lastEmotion   = ''
local inputBuffer   = ''
local window        = nil
local isOpen        = false

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function showMsg(text)
    pcall(function() ui.showMessage(tostring(text or '')) end)
end

-- Emotion colour map for reply display
local EMOTION_COLORS = {
    neutral   = util.color.rgb(0.9, 0.9, 0.9),
    happy     = util.color.rgb(0.6, 1.0, 0.6),
    angry     = util.color.rgb(1.0, 0.4, 0.4),
    fearful   = util.color.rgb(0.8, 0.7, 1.0),
    disgusted = util.color.rgb(0.7, 0.9, 0.4),
    surprised = util.color.rgb(1.0, 0.9, 0.4),
}

local function replyColor()
    return EMOTION_COLORS[lastEmotion] or EMOTION_COLORS.neutral
end

-- ── NPC context builder ───────────────────────────────────────────────────────

local function buildNpcContext(npcObj)
    local ctx = {
        npc_id = '', npc_name = '', npc_race = '',
        npc_class = '', npc_faction = '', location = '',
    }
    pcall(function() ctx.npc_id = tostring(npcObj.recordId or npcObj.id or '') end)
    pcall(function()
        local rec = types.NPC.record(npcObj)
        if rec then
            ctx.npc_name    = tostring(rec.name    or '')
            ctx.npc_race    = tostring(rec.race    or '')
            ctx.npc_class   = tostring(rec.class   or '')
            ctx.npc_faction = tostring(rec.faction or '')
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
            if d < bestDist then bestDist = d; bestObj = act end
        end
    end
    return bestObj
end

-- ── UI ────────────────────────────────────────────────────────────────────────

local function buildLayout()
    local headerText = '[AI] ' ..
        (lockedCtx and (lockedCtx.npc_name ~= '' and lockedCtx.npc_name or lockedCtx.npc_id) or 'No NPC')
    local replyText
    if lastReplyText ~= '' then
        replyText = (lockedCtx and lockedCtx.npc_name or 'NPC') .. ': ' .. lastReplyText
        if lastEmotion ~= '' and lastEmotion ~= 'neutral' then
            replyText = replyText .. '  [' .. lastEmotion .. ']'
        end
    else
        replyText = '(awaiting reply...)'
    end
    local inputText = '> ' .. inputBuffer .. '_'

    return {
        type = ui.TYPE.Flex,
        props = {
            size = v2(520, 200),
            position = v2(20, 20),
            relativePosition = v2(0, 0),
            horizontal = false,
        },
        content = ui.content {
            { type = ui.TYPE.Text,
              props = { text = headerText, textSize = 20,
                        textColor = util.color.rgb(1, 0.85, 0.4) } },
            { type = ui.TYPE.Text,
              props = { text = replyText, textSize = 16, textColor = replyColor(),
                        multiline = true, wordWrap = true, size = v2(500, 90) } },
            { type = ui.TYPE.Text,
              props = { text = inputText, textSize = 18,
                        textColor = util.color.rgb(0.6, 0.9, 1.0) } },
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

local function openWindow()  isOpen = true; refreshUI() end
local function closeWindow()
    isOpen = false
    if window then pcall(function() window:destroy() end); window = nil end
end

-- ── Send dialogue to IPC ──────────────────────────────────────────────────────

local function sendMessage(text)
    if not lockedCtx then
        showMsg('[AI] No NPC locked; press H near an NPC first.')
        return
    end
    local payload = {
        npc_id      = lockedCtx.npc_id,
        npc_name    = lockedCtx.npc_name,
        npc_race    = lockedCtx.npc_race,
        npc_class   = lockedCtx.npc_class,
        npc_faction = lockedCtx.npc_faction,
        location    = lockedCtx.location,
        player_text = text,
    }
    core.sendGlobalEvent('MorrowindAiDialogueRequest', payload)
end

-- ── H press: lock NPC + fire auto-greeting ────────────────────────────────────

local function lockAndGreet(npc)
    lockedCtx     = buildNpcContext(npc)
    lastReplyText = '(greeting NPC...)'
    lastEmotion   = ''
    inputBuffer   = ''

    -- Notify global script so it records the locked NPC context.
    core.sendGlobalEvent('MorrowindAiLockNpc', {
        npc_id      = lockedCtx.npc_id,
        npc_name    = lockedCtx.npc_name,
        npc_race    = lockedCtx.npc_race,
        npc_class   = lockedCtx.npc_class,
        npc_faction = lockedCtx.npc_faction,
        location    = lockedCtx.location,
    })

    -- Auto-greeting: like kenshi's startPlayerConversation hook
    sendMessage('__greet__')
    openWindow()
end

-- ── Input ─────────────────────────────────────────────────────────────────────

local KEY = input.KEY

local KEYMAP = {
    [KEY.A]='a',[KEY.B]='b',[KEY.C]='c',[KEY.D]='d',[KEY.E]='e',[KEY.F]='f',
    [KEY.G]='g',[KEY.H]='h',[KEY.I]='i',[KEY.J]='j',[KEY.K]='k',[KEY.L]='l',
    [KEY.M]='m',[KEY.N]='n',[KEY.O]='o',[KEY.P]='p',[KEY.Q]='q',[KEY.R]='r',
    [KEY.S]='s',[KEY.T]='t',[KEY.U]='u',[KEY.V]='v',[KEY.W]='w',[KEY.X]='x',
    [KEY.Y]='y',[KEY.Z]='z',
    [KEY._0]='0',[KEY._1]='1',[KEY._2]='2',[KEY._3]='3',[KEY._4]='4',
    [KEY._5]='5',[KEY._6]='6',[KEY._7]='7',[KEY._8]='8',[KEY._9]='9',
    [KEY.Space]=' ',[KEY.Period]='.',[KEY.Comma]=',',[KEY.Apostrophe]="'",
    [KEY.Slash]='/',[KEY.Minus]='-',
}

local function onKeyPress(key)
    if not key then return end
    local code = key.code

    if code == HAIL_KEY and not isOpen then
        local npc = findNearestNpc()
        if not npc then showMsg('[AI] No NPC nearby.'); return end
        lockAndGreet(npc)
        return
    end

    if not isOpen then return end

    if code == CLOSE_KEY then closeWindow(); return end

    if code == KEY.Enter or code == KEY.NumpadEnter or code == SEND_KEY then
        if inputBuffer ~= '' then
            sendMessage(inputBuffer)
            lastReplyText = '(sent: "' .. inputBuffer .. '"; awaiting reply...)'
            inputBuffer = ''
            refreshUI()
        end
        return
    end

    if code == HAIL_KEY then
        local npc = findNearestNpc()
        if npc then lockAndGreet(npc) end
        return
    end

    if code == KEY.Backspace then
        if #inputBuffer > 0 then inputBuffer = inputBuffer:sub(1, -2); refreshUI() end
        return
    end

    local ch = KEYMAP[code]
    if ch then
        if key.withShift and ch:match('%a') then ch = ch:upper() end
        inputBuffer = inputBuffer .. ch
        refreshUI()
    end
end

-- ── Event handlers ────────────────────────────────────────────────────────────

local function onDialogueReply(data)
    if not data then return end
    local text = tostring(data.npc_response or '')
    if text == '' then text = '...' end
    lastReplyText = text
    lastEmotion   = tostring(data.emotion or 'neutral')
    if isOpen then refreshUI() else showMsg('[NPC] ' .. text) end
end

local function onNpcSpeech(data)
    -- Ambient NPC-to-NPC line from the D2D radiant system.
    if not data then return end
    local text = tostring(data.text or '')
    if text ~= '' then showMsg(text) end
end

local function onAction(data)
    -- NPC requested an action (follow/flee/attack/trade).
    if not data or not data.action then return end
    local action = tostring(data.action)
    if action == 'follow' then
        showMsg('[AI] ' .. (data.npc_name or 'NPC') .. ' decides to follow you.')
    elseif action == 'flee' then
        showMsg('[AI] ' .. (data.npc_name or 'NPC') .. ' backs away nervously.')
    elseif action == 'attack' then
        showMsg('[AI] ' .. (data.npc_name or 'NPC') .. ' is hostile!')
    elseif action == 'trade' then
        showMsg('[AI] ' .. (data.npc_name or 'NPC') .. ' gestures toward their wares.')
    end
end

local function onInit()
    showMsg('[AI mod] Press H near an NPC to chat. Enter/F1 send, Esc close.')
end

return {
    engineHandlers = {
        onInit     = onInit,
        onKeyPress = onKeyPress,
    },
    eventHandlers = {
        MorrowindAiDialogueReply = onDialogueReply,
        MorrowindAiNpcSpeech     = onNpcSpeech,
        MorrowindAiAction        = onAction,
    },
}
