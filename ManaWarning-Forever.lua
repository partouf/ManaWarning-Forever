-- ManaWarning-Forever v0.2
--
-- WoW: Forever-only port of ManaWarning. On Forever, current mana / health /
-- power values are "secret" and cannot be read for threshold comparison from
-- addon code, so proactive "below N%" warnings are impossible. This addon
-- instead reacts when the client itself reports an out-of-mana condition via
-- UI_ERROR_MESSAGE (e.g. a cast blocked for "Not enough mana"), and posts a
-- configurable warning to self and/or group channels.
--
-- Everything this addon reads (UnitClass, UnitPowerType, UnitAffectingCombat,
-- UnitInRaid, IsInGroup) returns plain (non-secret) values, so no taint error
-- is produced in the hot path.

ManaWarning_Forever_Settings = nil

local DEFAULTS = {
    enabled         = true,
    warningText     = 'Need Mana!',
    rewarnCooldown  = 10,   -- seconds between repeat warnings
    maxPerCombat    = 3,    -- flood protection
    combatOnly      = false,
    raidOnly        = false,
    announceParty   = false,
    announceRaid    = false,
    announceInstance= false,
}

-- Localized / Forever-specific OOM keywords. Case-insensitive, substring match.
local MANA_KEYWORDS = {
    'not enough mana',
    'out of mana',
    'insufficient mana',
    'need more mana',
    'no mana',
}

local combatWarnCount = 0
local lastWarnTime = 0
local S  -- settings shortcut

--------------------------------------------------------------------------
-- utility
--------------------------------------------------------------------------

local function msg(line, r, g, b)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(tostring(line), r or 1, g or 1, b or 1)
    end
end

local function tryCall(fn, ...)
    local ok, r = pcall(fn, ...)
    return ok, r
end

local function looksLikeManaIssue(s)
    if type(s) ~= 'string' then return false end
    local lower = s:lower()
    for _, k in ipairs(MANA_KEYWORDS) do
        if lower:find(k, 1, true) then return true end
    end
    return false
end

local function copyDefaults(into)
    for k, v in pairs(DEFAULTS) do
        if into[k] == nil then into[k] = v end
    end
end

local function loadSettings()
    ManaWarning_Forever_Settings = ManaWarning_Forever_Settings or {}
    copyDefaults(ManaWarning_Forever_Settings)
    S = ManaWarning_Forever_Settings
end

--------------------------------------------------------------------------
-- warning dispatch
--------------------------------------------------------------------------

local function sendChat(channel, text)
    if type(SendChatMessage) == 'function' then
        pcall(SendChatMessage, text, channel)
    end
end

local function dispatchWarning()
    local now = GetTime()
    if now - lastWarnTime < S.rewarnCooldown then return end

    -- Gating: in-combat / in-raid filters
    local inCombat = UnitAffectingCombat('player')
    if S.combatOnly and not inCombat then return end
    local inRaid = IsInRaid and IsInRaid() or (UnitInRaid and UnitInRaid('player'))
    if S.raidOnly and not inRaid then return end

    -- Flood protection — reset count when we leave combat
    if inCombat then
        if combatWarnCount >= (S.maxPerCombat or 0) and (S.maxPerCombat or 0) > 0 then
            return
        end
        combatWarnCount = combatWarnCount + 1
    end

    lastWarnTime = now

    -- Always show to self
    msg(S.warningText, 1.0, 0.2, 0.2)

    -- Group announces (prefer raid > instance > party, mirroring MW-Classic)
    local inInstance = IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    local inParty = IsInGroup and IsInGroup()

    if S.announceRaid and inRaid then
        sendChat('RAID', S.warningText)
    elseif S.announceInstance and inInstance then
        sendChat('INSTANCE_CHAT', S.warningText)
    elseif S.announceParty and inParty then
        sendChat('PARTY', S.warningText)
    end
end

local function onLeaveCombat()
    combatWarnCount = 0
end

--------------------------------------------------------------------------
-- UI: load settings into controls / read controls into settings
--------------------------------------------------------------------------

local function setLabel(checkbox, text)
    local label = _G[checkbox:GetName() .. 'Text']
    if label and label.SetText then label:SetText(text) end
end

local function refreshUI()
    setLabel(MWFEnable,      'Enable OOM warning')
    setLabel(MWFCombatOnly,  'Only when in combat')
    setLabel(MWFRaidOnly,    'Only when in raid')
    setLabel(MWFAnnParty,    'Announce to party')
    setLabel(MWFAnnRaid,     'Announce to raid')
    setLabel(MWFAnnInstance, 'Announce to instance')

    MWFEnable:SetChecked(S.enabled)
    MWFWarnText:SetText(S.warningText or '')
    MWFCooldown:SetNumber(S.rewarnCooldown or 10)
    MWFFlood:SetNumber(S.maxPerCombat or 3)
    MWFCombatOnly:SetChecked(S.combatOnly)
    MWFRaidOnly:SetChecked(S.raidOnly)
    MWFAnnParty:SetChecked(S.announceParty)
    MWFAnnRaid:SetChecked(S.announceRaid)
    MWFAnnInstance:SetChecked(S.announceInstance)
end

function MWF_UI_OnSave()
    S.enabled          = MWFEnable:GetChecked() and true or false
    S.warningText      = MWFWarnText:GetText() or DEFAULTS.warningText
    S.rewarnCooldown   = tonumber(MWFCooldown:GetText()) or DEFAULTS.rewarnCooldown
    S.maxPerCombat     = tonumber(MWFFlood:GetText()) or DEFAULTS.maxPerCombat
    S.combatOnly       = MWFCombatOnly:GetChecked() and true or false
    S.raidOnly         = MWFRaidOnly:GetChecked() and true or false
    S.announceParty    = MWFAnnParty:GetChecked() and true or false
    S.announceRaid     = MWFAnnRaid:GetChecked() and true or false
    S.announceInstance = MWFAnnInstance:GetChecked() and true or false
    ManaWarningForeverSettings:Hide()
end

function MWF_UI_OnCancel()
    ManaWarningForeverSettings:Hide()
end

function MWF_UI_OnDefaults()
    for k, v in pairs(DEFAULTS) do S[k] = v end
    refreshUI()
end

--------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------

function ManaWarningForever_OnLoad(obj)
    obj:RegisterEvent('PLAYER_LOGIN')
    obj:RegisterEvent('PLAYER_REGEN_ENABLED')  -- left combat
    local function safeReg(ev) pcall(function() obj:RegisterEvent(ev) end) end
    safeReg('UI_ERROR_MESSAGE')
    safeReg('UI_INFO_MESSAGE')
    safeReg('UNIT_SPELLCAST_FAILED')
    safeReg('UNIT_SPELLCAST_FAILED_QUIET')

    SlashCmdList['MWFOREVER'] = function(arg)
        arg = (arg or ''):lower()
        if arg == 'test' then
            lastWarnTime = 0; combatWarnCount = 0
            dispatchWarning()
            return
        end
        if ManaWarningForeverSettings then
            if ManaWarningForeverSettings:IsShown() then
                ManaWarningForeverSettings:Hide()
            else
                refreshUI()
                ManaWarningForeverSettings:Show()
            end
        end
    end
    SLASH_MWFOREVER1 = '/mwf'
    SLASH_MWFOREVER2 = '/manawarning'
end

function ManaWarningForever_OnEvent(obj, event, ...)
    if event == 'PLAYER_LOGIN' then
        loadSettings()
        local _, enClass = tryCall(UnitClass, 'player')
        local _, powerType = tryCall(UnitPowerType, 'player')
        -- Silently disable if not a mana user
        if type(powerType) == 'number' and powerType ~= 0 then
            S.enabled = false
        end
        msg('ManaWarning-Forever loaded (class=' .. tostring(enClass) .. '). Type /mwf for settings.', 0.4, 1.0, 1.0)
        return
    end

    if event == 'PLAYER_REGEN_ENABLED' then
        onLeaveCombat()
        return
    end

    if not S or not S.enabled then return end

    if event == 'UI_ERROR_MESSAGE' or event == 'UI_INFO_MESSAGE' then
        -- (errType:number, msg:string) on modern clients, sometimes just a string.
        local a, b = ...
        local message = (type(a) == 'string') and a or ((type(b) == 'string') and b or nil)
        if looksLikeManaIssue(message) then
            dispatchWarning()
        end
    elseif event == 'UNIT_SPELLCAST_FAILED' or event == 'UNIT_SPELLCAST_FAILED_QUIET' then
        local unit = ...
        if unit ~= 'player' then return end
        -- Some clients include a reason string in later args
        for i = 2, select('#', ...) do
            local v = select(i, ...)
            if type(v) == 'string' and looksLikeManaIssue(v) then
                dispatchWarning()
                return
            end
        end
    end
end
