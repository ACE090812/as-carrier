local store = require 'server.store'
local core = require 'server.core'

local billingCfg = Config.billing or {}

local function requirePlan() return billingCfg.requirePlan ~= false end

-- ---------------------------------------------------------------------------------------------
-- Start up
-- ---------------------------------------------------------------------------------------------

CreateThread(function()
    core.validateConfig()
    local ok, resetOrErr = pcall(store.ensureSchema)
    if not ok then
        print(('[as-carrier] failed to create its tables: %s'):format(tostring(resetOrErr)))
        return
    end
    if resetOrErr == true then
        print('[as-carrier] plan choice is new: every existing account was reset and must choose a plan (unpaid balances were kept).')
    end
    local loaded = core.loadGate()
    print(('[as-carrier] ready: %d account(s) loaded'):format(loaded))

    if Config.accountBy == 'character' and GetResourceState('sd-phone') == 'started' then
        local ok2, active = pcall(function() return exports['sd-phone']:isSimModeActive() end)
        if ok2 and active == true then
            print('[as-carrier] WARNING: Config.accountBy is "character" but sd-phone runs in SIM mode. sd-phone reports SIM identities, so the call/text block and usage metering will not match your accounts. Use "sim" or "auto".')
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- The app's callbacks. Every one resolves the account, locks it, brings it up to date, does its thing and
-- answers with the fresh status.
-- ---------------------------------------------------------------------------------------------

--- fn(key, row) returns true, or nil + message + extra. Without fn it just returns the status.
local function withAccount(source, fn)
    local key, err = core.resolveKey(source)
    if not key then return { ok = false, error = err } end
    core.touchSource(key, source)

    local ran, ok, msg, extra = pcall(core.withLock, key, function()
        local row = core.ensureAccount(key)
        core.notePayer(key, row, source)
        core.process(key, row, source)
        if fn then return fn(key, row) end
        return true
    end)
    if not ran then
        print(('[as-carrier] request failed for %s: %s'):format(key, tostring(ok)))
        return { ok = false, error = T('err.generic') }
    end
    if not ok then
        local out = { ok = false, error = msg }
        if type(extra) == 'table' then for k, v in pairs(extra) do out[k] = v end end
        return out
    end
    local row = core.getRow(key)
    return { ok = true, data = core.statusFor(key, row) }
end

lib.callback.register('sd_carrier:status', function(source)
    return withAccount(source)
end)

lib.callback.register('sd_carrier:selectPlan', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    if type(payload.planId) ~= 'string' then return { ok = false, error = T('err.unknownPlan') } end
    local code = type(payload.code) == 'string' and payload.code:sub(1, 32) or nil
    return withAccount(source, function(key, row)
        return core.selectPlan(key, row, source, payload.planId, { code = code, payExit = payload.payExit == true })
    end)
end)

lib.callback.register('sd_carrier:cancelPending', function(source)
    return withAccount(source, function(key, row) return core.cancelPending(key, row) end)
end)

lib.callback.register('sd_carrier:cancelService', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    return withAccount(source, function(key, row)
        return core.cancelService(key, row, source, { payExit = payload.payExit == true })
    end)
end)

lib.callback.register('sd_carrier:setAutoPay', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    return withAccount(source, function(key, row) return core.setAutoPay(key, row, payload.on == true) end)
end)

lib.callback.register('sd_carrier:payBill', function(source)
    return withAccount(source, function(key, row) return core.payBill(key, row, source) end)
end)

lib.callback.register('sd_carrier:topUp', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    return withAccount(source, function(key, row) return core.topUp(key, row, source, payload.amount) end)
end)

lib.callback.register('sd_carrier:buyAddon', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    if type(payload.id) ~= 'string' then return { ok = false, error = T('err.unknownAddon') } end
    return withAccount(source, function(key, row) return core.buyAddon(key, row, source, payload.id) end)
end)

lib.callback.register('sd_carrier:pause', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    return withAccount(source, function(key, row) return core.pause(key, row, source, payload.days) end)
end)

lib.callback.register('sd_carrier:resume', function(source)
    return withAccount(source, function(key, row) return core.resumeNow(key, row) end)
end)

-- Data heartbeat: the app calls this while it is open on mobile data. Called too fast, it is ignored.
local lastBeat = {}
lib.callback.register('sd_carrier:dataHeartbeat', function(source)
    local key = core.resolveKey(source)
    if not key then return { ok = false } end
    core.touchSource(key, source)

    local now = os.time()
    local every = math.max(10, (tonumber(billingCfg.dataHeartbeatSeconds) or 60) * 0.8)
    if lastBeat[source] and now - lastBeat[source] < every then return { ok = true } end
    lastBeat[source] = now

    local state = core.dataState(key)
    if state == 'blocked' then return { ok = true } end
    core.record(key, 'data', tonumber(billingCfg.dataPerHeartbeatMB) or 6)
    core.pushUpdate(key)
    return { ok = true }
end)

-- ---------------------------------------------------------------------------------------------
-- Usage from sd-phone's own events. These carry sd-phone's identity for the phone, which is the SIM's
-- identity in SIM mode (the same key used above).
-- ---------------------------------------------------------------------------------------------

AddEventHandler('sd-phone:server:call:ended', function(call)
    if type(call) ~= 'table' then return end
    local seconds = tonumber(call.duration) or 0
    if seconds <= 0 then return end
    local minutes = math.ceil(seconds / 60)
    local callerKey = call.caller and call.caller.citizenid
    local calleeKey = call.callee and call.callee.citizenid
    core.record(callerKey, 'minutes', minutes)
    if calleeKey and calleeKey ~= callerKey then
        core.record(calleeKey, 'minutes', minutes)
    end
end)

AddEventHandler('sd-phone:server:messages:sent', function(payload)
    if type(payload) ~= 'table' then return end
    if payload.system or payload.group then return end
    core.record(payload.citizenid, 'texts', 1)
end)

-- ---------------------------------------------------------------------------------------------
-- Nudge: tell a player why they have no service (or what needs doing), when they open their phone
-- ---------------------------------------------------------------------------------------------

local nudged = {}
local NUDGE_EVERY = 600

local NUDGES = {
    no_plan   = { 'notify.choosePlanTitle', 'notify.choosePlanBody' },
    suspended = { 'notify.suspendedTitle', 'notify.suspendedBody' },
    paused    = { 'notify.pausedTitle', 'notify.pausedBody' },
    expired   = { 'notify.bundleEndedTitle', 'notify.bundleEndedNudge' },
    no_credit = { 'notify.noCreditTitle', 'notify.noCreditBody' },
}

RegisterNetEvent('sd-phone:server:phone:setOpen')
AddEventHandler('sd-phone:server:phone:setOpen', function(open)
    local src = source
    if not src or not open then return end
    local now = os.time()
    if nudged[src] and now - nudged[src] < NUDGE_EVERY then return end
    local key = core.resolveKey(src)
    if not key then return end
    core.touchSource(key, src)
    local reason = core.blockReason(key)
    local g = core.known[key]
    if not reason and g and g.status == 'limited' then reason = 'limited' end
    if not reason then return end
    nudged[src] = now
    local text = NUDGES[reason]
    if reason == 'limited' then text = { 'notify.limitedTitle', 'notify.limitedBody' } end
    if text then
        TriggerClientEvent('sd-phone:client:notify', src, {
            app = 'carrier', appId = Config.app.identifier, title = T(text[1]), body = T(text[2]), time = 'now',
        })
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    nudged[src] = nil
    lastBeat[src] = nil
    for _, key in ipairs(core.forgetSource(src)) do
        local ok, err = pcall(core.flushKey, key)
        if not ok then print(('[as-carrier] could not save usage for %s: %s'):format(key, tostring(err))) end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Background work: batched saving, and the sweep that bills, escalates and auto-pays
-- ---------------------------------------------------------------------------------------------

CreateThread(function()
    local every = math.max(5, tonumber(billingCfg.flushSeconds) or 15)
    while true do
        Wait(every * 1000)
        core.flushAll()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    pcall(core.flushAll)
end)

local function sweepOnce()
    local now = os.time()
    local keys = store.listDue(now)
    for _, key in ipairs(keys) do
        if not core.sweepSkip(key, now) then
            local ok, err = pcall(function()
                core.withLock(key, function()
                    local row = core.getRow(key)
                    if row then core.process(key, row, nil) end
                end)
            end)
            if not ok then print(('[as-carrier] sweep failed for %s: %s'):format(key, tostring(err))) end
        end
    end
    return #keys
end
core.sweepOnce = sweepOnce

CreateThread(function()
    local every = tonumber(billingCfg.sweepSeconds) or 0
    if every <= 0 then return end
    while not core.gateLoaded() do Wait(500) end
    local ticks = 0
    while true do
        Wait(math.max(10, every) * 1000)
        local ok, err = pcall(sweepOnce)
        if not ok then print(('[as-carrier] sweep failed: %s'):format(tostring(err))) end
        ticks = ticks + 1
        -- usage history older than a quarter is not shown anywhere
        if ticks % 600 == 1 then
            pcall(store.pruneDaily, math.floor(os.time() / core.DAY) - 90)
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------------------------

--- sd-phone's download hook. Returns { success, message, throttled }.
local function tryConsumeDownloadData(source, mb)
    local key, err = core.resolveKey(source)
    if not key then return { success = false, message = err or T('err.playerNotFound') } end
    core.touchSource(key, source)

    local reply
    core.withLock(key, function()
        local row = core.ensureAccount(key)
        core.process(key, row, source)

        local reason = core.blockReason(key, 'data')
        if reason == 'no_plan' then reply = { success = false, message = T('err.noPlan') } return end
        if reason == 'suspended' then reply = { success = false, message = T('err.suspended') } return end
        if reason == 'limited' then reply = { success = false, message = T('err.limited') } return end
        if reason == 'paused' then reply = { success = false, message = T('err.paused') } return end
        if reason == 'expired' then reply = { success = false, message = T('err.expired') } return end
        if reason == 'no_credit' then reply = { success = false, message = T('err.noCredit') } return end

        local g = core.known[key]
        if not g or not g.chosen then reply = { success = true } return end

        local state = core.dataState(key)
        if state == 'blocked' then reply = { success = false, message = T('err.outOfData') } return end
        if state == 'throttled' then reply = { success = true, throttled = true, message = T('err.throttled') } return end
        core.record(key, 'data', tonumber(mb) or 0)
        core.pushUpdate(key)
        reply = { success = true }
    end)
    return reply or { success = false, message = T('err.busy') }
end
exports('tryConsumeDownloadData', tryConsumeDownloadData)

--- Why a phone has no service, or nil. `key` is the identity sd-phone uses for the phone (player.getIdentifier);
--- `capability` is optional (sd-phone's 'call' / 'text' / 'data' ...): with 'data' the limited step also counts.
---   'no_plan'   no plan chosen yet (only while Config.billing.requirePlan is on)
---   'suspended' the bill is overdue
---   'limited'   (data only) the bill is late, mobile data is off
---   'paused'    the plan is paused
---   'expired'   a prepaid bundle ran out of time
---   'no_credit' a prepaid account is out of credit
exports('getBlockReason', function(key, capability)
    return core.blockReason(key, capability)
end)

exports('isSuspendedCached', function(key)
    return core.isSuspended(key)
end)

--- 'ok' | 'throttled' | 'blocked' for a player's mobile data (throttled = past the cap, running slow).
exports('getDataState', function(source)
    local key = core.resolveKey(source)
    if not key then return 'blocked' end
    return (core.dataState(key))
end)

--- Adds credit to an account (for a shop that sells top-up cards, or staff tools). `key` as in getBlockReason.
exports('addCredit', function(key, amount)
    amount = core.money(amount)
    if type(key) ~= 'string' or key == '' or amount == 0 then return false end
    local done = false
    core.withLock(key, function()
        local row = core.ensureAccount(key)
        core.save(key, { credit = math.max(0, core.money(row.credit + amount)) })
        core.known[key] = core._.buildGate(row)
        done = true
    end)
    return done
end)

--- Money system hook for other scripts: the account's credit.
exports('getCredit', function(key)
    local row = core.getRow(key)
    return row and row.credit or 0
end)
