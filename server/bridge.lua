-- Framework bridge, same pattern as sd_blackmarket's BMBridge: the rest of this resource calls
-- these generic functions and never touches qb-core/es_extended directly.

CarrierBridge = {}

local function detectFramework()
    if Config.framework ~= 'auto' then return Config.framework end
    if GetResourceState('qbx_core') == 'started' then return 'qbx' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'standalone'
end

local framework = detectFramework()

local QBCore, qbxExport, ESX

---Lazily resolves and caches the framework's core object on first real use, rather than in a
---fire-and-forget CreateThread at resource start (which can race a call made in the first tick).
local function ensureCore()
    if framework == 'qb' and not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif framework == 'qbx' and not qbxExport then
        qbxExport = exports.qbx_core
    elseif framework == 'esx' and not ESX then
        ESX = exports['es_extended']:getSharedObject()
    end
end

---A stable per-character id, used as the primary key for billing accounts/history.
---@param source number
---@return string|nil
function CarrierBridge.getIdentifier(source)
    ensureCore()
    if framework == 'qb' and QBCore then
        local Player = QBCore.Functions.GetPlayer(source)
        return Player and Player.PlayerData.citizenid or nil
    elseif framework == 'qbx' and qbxExport then
        local Player = qbxExport:GetPlayer(source)
        return Player and Player.PlayerData.citizenid or nil
    elseif framework == 'esx' and ESX then
        local xPlayer = ESX.GetPlayerFromId(source)
        return xPlayer and xPlayer.identifier or nil
    end
    -- Standalone: no character system to key off - the server id is what we've got. Not
    -- persistent across a reconnect, worth knowing if you're running standalone.
    return source and ('standalone:' .. tostring(source)) or nil
end

---@param source number
---@param account string
---@return number|nil balance, nil when unknowable (standalone)
function CarrierBridge.getBalance(source, account)
    ensureCore()
    if framework == 'qb' and QBCore then
        local Player = QBCore.Functions.GetPlayer(source)
        return Player and Player.PlayerData.money[account] or 0
    elseif framework == 'qbx' and qbxExport then
        local Player = qbxExport:GetPlayer(source)
        return Player and Player.PlayerData.money[account] or 0
    elseif framework == 'esx' and ESX then
        local xPlayer = ESX.GetPlayerFromId(source)
        local acc = xPlayer and xPlayer.getAccount(account)
        return acc and acc.money or 0
    end
    return nil
end

---@return boolean success
function CarrierBridge.removeMoney(source, account, amount)
    ensureCore()
    if amount <= 0 then return true end
    if framework == 'qb' and QBCore then
        local Player = QBCore.Functions.GetPlayer(source)
        return Player ~= nil and Player.Functions.RemoveMoney(account, amount, 'phone-bill') == true
    elseif framework == 'qbx' and qbxExport then
        local Player = qbxExport:GetPlayer(source)
        return Player ~= nil and Player.Functions.RemoveMoney(account, amount, 'phone-bill') == true
    elseif framework == 'esx' and ESX then
        local xPlayer = ESX.GetPlayerFromId(source)
        if not xPlayer then return false end
        local acc = xPlayer.getAccount(account)
        if not acc or acc.money < amount then return false end
        xPlayer.removeAccountMoney(account, amount)
        return true
    end
    -- Standalone: nothing to actually check or remove - treated as always affordable.
    return true
end

return CarrierBridge
