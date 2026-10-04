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

local function ensureCore()
    if framework == 'qb' and not QBCore then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif framework == 'qbx' and not qbxExport then
        qbxExport = exports.qbx_core
    elseif framework == 'esx' and not ESX then
        ESX = exports['es_extended']:getSharedObject()
    end
end

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

    return source and ('standalone:' .. tostring(source)) or nil
end

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

    return true
end

--- The server id of the online player behind a framework identifier (citizenid / ESX identifier), or nil.
function CarrierBridge.getSourceByIdentifier(id)
    ensureCore()
    if type(id) ~= 'string' or id == '' then return nil end
    if framework == 'qb' and QBCore then
        local Player = QBCore.Functions.GetPlayerByCitizenId(id)
        return Player and Player.PlayerData.source or nil
    elseif framework == 'qbx' and qbxExport then
        local Player = qbxExport:GetPlayerByCitizenId(id)
        return Player and Player.PlayerData.source or nil
    elseif framework == 'esx' and ESX then
        local xPlayer = ESX.GetPlayerFromIdentifier(id)
        return xPlayer and xPlayer.source or nil
    end
    local n = id:match('^standalone:(%d+)$')
    n = n and tonumber(n)
    if n and GetPlayerName(n) then return n end
    return nil
end

local function safeAccount(account)
    return type(account) == 'string' and account:match('^[%w_]+$') ~= nil
end

-- ESX keeps accounts as either {"bank":100,...} (Legacy) or [{"name":"bank","money":100},...] (older).
local function esxTakeOffline(identifier, account, amount)
    local raw = MySQL.scalar.await('SELECT accounts FROM users WHERE identifier = ?', { identifier })
    if type(raw) ~= 'string' or raw == '' then return false end
    local ok, accounts = pcall(json.decode, raw)
    if not ok or type(accounts) ~= 'table' then return false end

    local done = false
    if accounts[account] ~= nil and type(accounts[account]) == 'number' then
        if accounts[account] < amount then return false end
        accounts[account] = math.floor((accounts[account] - amount) * 100 + 0.5) / 100
        done = true
    else
        for _, a in ipairs(accounts) do
            if type(a) == 'table' and a.name == account then
                if (tonumber(a.money) or 0) < amount then return false end
                a.money = math.floor(((tonumber(a.money) or 0) - amount) * 100 + 0.5) / 100
                done = true
                break
            end
        end
    end
    if not done then return false end

    -- Only writes if nothing changed the row since it was read.
    local changed = MySQL.update.await('UPDATE users SET accounts = ? WHERE identifier = ? AND accounts = ?',
        { json.encode(accounts), identifier, raw })
    return (changed or 0) > 0
end

--- Takes money from the bank of a character who is NOT online, straight in the database, only if they can
--- afford it. Returns true when the money was taken. (Standalone has no money, so it always succeeds.)
function CarrierBridge.removeMoneyOffline(identifier, account, amount)
    if amount <= 0 then return true end
    if type(identifier) ~= 'string' or identifier == '' or not safeAccount(account) then return false end

    if framework == 'qb' or framework == 'qbx' then
        local balance = ('CAST(JSON_UNQUOTE(JSON_EXTRACT(money, \'$.%s\')) AS DECIMAL(15,2))'):format(account)
        local changed = MySQL.update.await(([[
            UPDATE players SET money = JSON_SET(money, '$.%s', ROUND(%s - ?, 2))
            WHERE citizenid = ? AND JSON_EXTRACT(money, '$.%s') IS NOT NULL AND %s >= ?
        ]]):format(account, balance, account, balance), { amount, identifier, amount })
        return (changed or 0) > 0
    elseif framework == 'esx' then
        return esxTakeOffline(identifier, account, amount)
    end
    return true
end

return CarrierBridge