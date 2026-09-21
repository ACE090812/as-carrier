local store = require 'server.store'
local Bridge = CarrierBridge or require 'server.bridge'

local billingCfg = Config.billing or {}
local PLANS = {}
for _, p in ipairs(billingCfg.plans or {}) do
    if p.id then PLANS[p.id] = p end
end
-- Only fills the NOT NULL plan column of an account that has not chosen a plan yet. It is never billed.
local PLACEHOLDER_PLAN = (billingCfg.plans and billingCfg.plans[1] and billingCfg.plans[1].id) or next(PLANS)

local CYCLE_SECONDS = math.max(1, math.floor(tonumber(billingCfg.cycleDays) or 28)) * 86400
local GRACE_SECONDS = math.max(0, math.floor(tonumber(billingCfg.graceDays) or 3)) * 86400
local CUR = Config.currency or '£'

local function truthy(v) return v == true or v == 1 end
local function requirePlan() return billingCfg.requirePlan ~= false end
local function planLock() return billingCfg.planLock ~= false end
local function priceText(n) return ('%s%.2f'):format(CUR, tonumber(n) or 0) end

-- ---------------------------------------------------------------------------------------------
-- Which accounts exist and what they may do. Kept in memory so sd-phone can ask "does this SIM have
-- service?" on every call and text without a database query.
-- ---------------------------------------------------------------------------------------------

local known = {}          -- [key] = { chosen = bool, suspended = bool }
local suspended = {}      -- [key] = true while the bill is overdue
local gateLoaded = false  -- false until the accounts have been read after a start, so a restart never blocks anyone

local function setKnown(key, row)
    local k = { chosen = truthy(row.plan_chosen), suspended = row.status == 'suspended' }
    known[key] = k
    suspended[key] = k.suspended
    return k
end

--- 'suspended', 'no_plan' or nil (service allowed).
local function blockReason(key)
    if type(key) ~= 'string' or key == '' then return nil end
    local k = known[key]
    if k and k.suspended then return 'suspended' end
    if requirePlan() and gateLoaded and not (k and k.chosen) then return 'no_plan' end
    return nil
end

CreateThread(function()
    local ok, resetOrErr = pcall(store.ensureSchema)
    if not ok then
        print(('[as-carrier] failed to create its tables: %s'):format(tostring(resetOrErr)))
        return
    end
    if resetOrErr == true then
        print('[as-carrier] plan choice is new: every existing account was reset and must choose a plan (unpaid balances were kept).')
    end
    for _, row in ipairs(store.listAll()) do setKnown(row.citizenid, row) end
    gateLoaded = true

    if Config.accountBy == 'character' and GetResourceState('sd-phone') == 'started' then
        local ok, active = pcall(function() return exports['sd-phone']:isSimModeActive() end)
        if ok and active == true then
            print('[as-carrier] WARNING: Config.accountBy is "character" but sd-phone runs in SIM mode. sd-phone reports SIM identities, so the call/text block and usage metering will not match your accounts. Use "sim" or "auto".')
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Who is this? One account per SIM (or per character, see Config.accountBy)
-- ---------------------------------------------------------------------------------------------

local function useSim()
    local mode = Config.accountBy or 'auto'
    if mode == 'sim' then return true end
    if mode == 'character' then return false end
    if GetResourceState('sd-phone') ~= 'started' then return false end
    local ok, active = pcall(function() return exports['sd-phone']:isSimModeActive() end)
    return ok and active == true
end

local simCache = {}   -- [number] = { id = identity, at = time }
local SIM_TTL = 30

local function simIdentity(number)
    local hit = simCache[number]
    local now = os.time()
    if hit and now - hit.at < SIM_TTL then return hit.id end
    local ok, id = pcall(store.simIdentity, number)
    if not ok or not id then return nil end
    simCache[number] = { id = id, at = now }
    return id
end

--- The account key for a player: the identity of the SIM in their active phone, or their citizenid.
local function resolveKey(source)
    if useSim() then
        local ok, number = pcall(function() return exports['sd-phone']:getSimNumber(source) end)
        if not ok or not number then return nil, T('err.noSim') end
        local id = simIdentity(tostring(number))
        if not id then return nil, T('err.simNotFound') end
        return id
    end
    local cid = Bridge.getIdentifier(source)
    if not cid then return nil, T('err.playerNotFound') end
    return cid
end

-- ---------------------------------------------------------------------------------------------
-- Billing
-- ---------------------------------------------------------------------------------------------

local function planFor(id)
    return PLANS[id] or PLANS[PLACEHOLDER_PLAN]
end

local function money(n)
    return math.floor((tonumber(n) or 0) * 100 + 0.5) / 100
end

local function overage(used, included, rate)
    if included < 0 then return 0 end
    local over = used - included
    if over <= 0 then return 0 end
    return over * rate
end

local function cycleCharge(plan, row)
    local total = tonumber(plan.price) or 0
    total = total + overage(tonumber(row.minutes_used) or 0, tonumber(plan.minutes) or -1, tonumber(plan.overagePerMinute) or 0)
    total = total + overage(tonumber(row.texts_used) or 0, tonumber(plan.texts) or -1, tonumber(plan.overagePerText) or 0)
    total = total + overage(tonumber(row.data_mb_used) or 0, tonumber(plan.dataMB) or -1, tonumber(plan.overagePerMB) or 0)
    return money(total)
end

local function ensureAccount(key)
    local row = store.getAccount(key)
    if not row then
        local now = os.time()
        store.insertAccount(key, PLACEHOLDER_PLAN, now, now + CYCLE_SECONDS)
        row = store.getAccount(key) or {
            citizenid = key, plan_id = PLACEHOLDER_PLAN, cycle_start = now, due_at = now + CYCLE_SECONDS,
            auto_pay = 0, status = 'current', plan_chosen = 0, minutes_used = 0, texts_used = 0, data_mb_used = 0,
            balance_due = 0, balance_since = nil,
        }
    end
    setKnown(key, row)
    return row
end

local pushUpdate

local function notify(source, title, body)
    if not source then return end
    TriggerClientEvent('sd-phone:client:notify', source, {
        app = 'carrier', appId = Config.app.identifier, title = title, body = body, time = 'now',
    })
end

local function maybeAdvanceCycle(source, key, row)
    local now = os.time()

    -- Overdue bills escalate to a suspension once the grace period has passed.
    local function escalate()
        local since = tonumber(row.balance_since)
        if (tonumber(row.balance_due) or 0) <= 0 or not since then return end
        local nextStatus = (now - since >= GRACE_SECONDS) and 'suspended' or 'due'
        if row.status ~= nextStatus then
            store.setStatus(key, nextStatus)
            local wasSuspended = row.status == 'suspended'
            row.status = nextStatus
            if nextStatus == 'suspended' and not wasSuspended then
                TriggerEvent('sd_carrier:accountSuspended', key)
            elseif wasSuspended and nextStatus ~= 'suspended' then
                TriggerEvent('sd_carrier:accountRestored', key)
            end
        end
        setKnown(key, row)
    end

    -- No plan chosen yet: nothing to cycle, nothing is billed.
    if not truthy(row.plan_chosen) then
        escalate()
        return
    end

    if now < (tonumber(row.due_at) or 0) then
        escalate()
        return
    end

    escalate()

    local plan = planFor(row.plan_id)
    local charge = cycleCharge(plan, row)
    local newBalance = money((tonumber(row.balance_due) or 0) + charge)
    local balanceSince = (tonumber(row.balance_due) or 0) > 0 and tonumber(row.balance_since) or now
    local newCycleStart, newDueAt = now, now + CYCLE_SECONDS

    -- The bill is for the plan the cycle was on. A switch queued during the cycle takes effect now.
    local queued = row.pending_plan and PLANS[row.pending_plan] and row.pending_plan or nil

    store.insertHistory(key, row.plan_id, charge, tonumber(row.cycle_start) or now)
    store.rollCycle(key, newCycleStart, newDueAt, newBalance, newBalance > 0 and balanceSince or nil, queued)

    row.cycle_start, row.due_at = newCycleStart, newDueAt
    row.minutes_used, row.texts_used, row.data_mb_used = 0, 0, 0
    row.balance_due, row.balance_since = newBalance, (newBalance > 0) and balanceSince or nil
    row.pending_plan = nil
    if queued then row.plan_id = queued end

    local autoPay = truthy(row.auto_pay)
    local paid = false
    if autoPay and source and newBalance > 0 then
        paid = Bridge.removeMoney(source, Config.payment.account, newBalance)
        if paid then
            store.markLatestPaid(key, now)
            store.clearBalance(key)
            row.balance_due, row.balance_since = 0, nil
            row.status = 'current'
        end
    end

    if not paid then
        -- An already suspended account stays suspended until the balance is paid.
        if not (row.status == 'suspended' and newBalance > 0) then
            row.status = (newBalance > 0) and 'due' or 'current'
        end
        store.setStatus(key, row.status)
    end

    local wasSuspended = suspended[key] == true
    setKnown(key, row)
    if suspended[key] and not wasSuspended then TriggerEvent('sd_carrier:accountSuspended', key) end
    pushUpdate(source)

    if source and newBalance > 0 then
        notify(source, paid and T('notify.billPaidTitle') or T('notify.billTitle'),
            paid and T('notify.autoPaid', plan.label or T('notify.phoneFallback'))
                or T('notify.billDue', plan.label or T('notify.phoneFallback'), priceText(newBalance)))
    end
    if source and queued then
        notify(source, T('notify.planChangedTitle'), T('notify.planChangedBody', planFor(queued).label or queued))
    end
end

local function serializePlan(plan)
    return {
        id = plan.id, label = plan.label, price = plan.price,
        minutes = plan.minutes, texts = plan.texts, dataMB = plan.dataMB,
        overagePerMinute = plan.overagePerMinute, overagePerText = plan.overagePerText, overagePerMB = plan.overagePerMB,
        popular = plan.popular == true,
    }
end

local function allPlans()
    local out = {}
    for _, p in ipairs(billingCfg.plans or {}) do out[#out + 1] = serializePlan(p) end
    return out
end

local function statusFor(source)
    local key, err = resolveKey(source)
    if not key then return nil, err end

    local row = ensureAccount(key)
    maybeAdvanceCycle(source, key, row)

    local chosen = truthy(row.plan_chosen)
    local plan = planFor(row.plan_id)
    local history = {}
    for i, h in ipairs(store.listHistory(key, 12)) do
        history[i] = {
            id = h.id, planId = h.plan_id, amount = tonumber(h.amount) or 0,
            paid = truthy(h.paid), paidAt = h.paid_at,
            cycleStart = h.cycle_start,
        }
    end

    local pending = chosen and row.pending_plan and PLANS[row.pending_plan] or nil
    return {
        chosen = chosen,
        plan   = chosen and serializePlan(plan) or nil,
        plans  = allPlans(),
        pendingPlan = pending and serializePlan(pending) or nil,
        planLock = planLock(),
        lockedUntil = (chosen and planLock()) and tonumber(row.due_at) or nil,
        requirePlan = requirePlan(),
        blocked = blockReason(key),
        status = row.status,
        autoPay = truthy(row.auto_pay),
        cycleStart = tonumber(row.cycle_start),
        dueAt      = tonumber(row.due_at),
        cycleDays  = math.floor(CYCLE_SECONDS / 86400),
        minutesUsed = tonumber(row.minutes_used) or 0,
        textsUsed   = tonumber(row.texts_used) or 0,
        dataMBUsed  = tonumber(row.data_mb_used) or 0,
        estimatedThisCycle = chosen and cycleCharge(plan, row) or 0,
        balanceDue = tonumber(row.balance_due) or 0,
        payBy      = ((tonumber(row.balance_due) or 0) > 0 and row.balance_since) and (tonumber(row.balance_since) + GRACE_SECONDS) or nil,
        history    = history,
        now        = os.time(),
    }
end

function pushUpdate(src)
    if src then TriggerClientEvent('sd_carrier:client:updated', src, {}) end
end

local function reply(source)
    local data, err = statusFor(source)
    if not data then return { ok = false, error = err } end
    return { ok = true, data = data }
end

lib.callback.register('sd_carrier:status', function(source)
    return reply(source)
end)

lib.callback.register('sd_carrier:selectPlan', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local key, err = resolveKey(source)
    if not key then return { ok = false, error = err } end
    if type(payload.planId) ~= 'string' or not PLANS[payload.planId] then return { ok = false, error = T('err.unknownPlan') } end

    local row = ensureAccount(key)
    maybeAdvanceCycle(source, key, row)
    row = store.getAccount(key) or row

    if not truthy(row.plan_chosen) then
        -- The player's own first pick. It starts now: it starts the cycle and the lock.
        local now = os.time()
        store.choosePlan(key, payload.planId, now, now + CYCLE_SECONDS)
        setKnown(key, store.getAccount(key) or row)
        pushUpdate(source)
        return reply(source)
    end

    if not planLock() then
        store.setPlan(key, payload.planId)
        setKnown(key, store.getAccount(key) or row)
        return reply(source)
    end

    if payload.planId == row.plan_id then
        -- Picking the plan you are already on drops any queued switch.
        store.setPending(key, nil)
    else
        store.setPending(key, payload.planId)
    end
    return reply(source)
end)

lib.callback.register('sd_carrier:cancelPending', function(source)
    local key, err = resolveKey(source)
    if not key then return { ok = false, error = err } end
    ensureAccount(key)
    store.setPending(key, nil)
    return reply(source)
end)

lib.callback.register('sd_carrier:setAutoPay', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local key, err = resolveKey(source)
    if not key then return { ok = false, error = err } end

    ensureAccount(key)
    store.setAutoPay(key, payload.on == true)
    return { ok = true, data = { autoPay = payload.on == true } }
end)

lib.callback.register('sd_carrier:payBill', function(source)
    local key, err = resolveKey(source)
    if not key then return { ok = false, error = err } end

    local row = ensureAccount(key)
    maybeAdvanceCycle(source, key, row)

    local due = tonumber(row.balance_due) or 0
    if due <= 0 then return { ok = false, error = T('err.nothingDue') } end

    if not Bridge.removeMoney(source, Config.payment.account, due) then
        return { ok = false, error = T('err.insufficientFunds') }
    end

    local wasSuspended = suspended[key] == true
    store.markLatestPaid(key, os.time())
    store.clearBalance(key)
    setKnown(key, store.getAccount(key) or row)
    if wasSuspended then TriggerEvent('sd_carrier:accountRestored', key) end

    return reply(source)
end)

lib.callback.register('sd_carrier:dataHeartbeat', function(source)
    local key = resolveKey(source)
    if not key then return { ok = false } end
    local row = ensureAccount(key)
    if not truthy(row.plan_chosen) or blockReason(key) then return { ok = true } end
    store.addDataMB(key, tonumber(billingCfg.dataPerHeartbeatMB) or 6)
    pushUpdate(source)
    return { ok = true }
end)

-- ---------------------------------------------------------------------------------------------
-- Usage from sd-phone's own events. These carry sd-phone's identity for the phone, which is the SIM's
-- identity in SIM mode (the same key used above).
-- ---------------------------------------------------------------------------------------------

local function isChosen(key)
    local k = known[key]
    return k ~= nil and k.chosen == true
end

local function recordCallSeconds(key, seconds)
    if type(key) ~= 'string' or key == '' or not isChosen(key) then return end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    store.addMinutes(key, math.ceil(seconds / 60))
end

local function recordText(key)
    if type(key) ~= 'string' or key == '' or not isChosen(key) then return end
    store.addTexts(key, 1)
end

AddEventHandler('sd-phone:server:call:ended', function(call)
    if type(call) ~= 'table' then return end
    local callerKey = call.caller and call.caller.citizenid
    local calleeKey = call.callee and call.callee.citizenid
    recordCallSeconds(callerKey, call.duration)
    if calleeKey and calleeKey ~= callerKey then
        recordCallSeconds(calleeKey, call.duration)
    end
end)

AddEventHandler('sd-phone:server:messages:sent', function(payload)
    if type(payload) ~= 'table' then return end

    if payload.system or payload.group then return end
    recordText(payload.citizenid)
end)

-- ---------------------------------------------------------------------------------------------
-- Nudge: tell a blocked player why, the first time they open their phone in a while
-- ---------------------------------------------------------------------------------------------

local nudged = {}
local NUDGE_EVERY = 600

AddEventHandler('sd-phone:server:phone:setOpen', function(open)
    local src = source
    if not src or not open then return end
    local now = os.time()
    if nudged[src] and now - nudged[src] < NUDGE_EVERY then return end
    local key = resolveKey(src)
    local reason = key and blockReason(key)
    if not reason then return end
    nudged[src] = now
    if reason == 'no_plan' then
        notify(src, T('notify.choosePlanTitle'), T('notify.choosePlanBody'))
    else
        notify(src, T('notify.suspendedTitle'), T('notify.suspendedBody'))
    end
end)

AddEventHandler('playerDropped', function()
    nudged[source] = nil
end)

-- ---------------------------------------------------------------------------------------------
-- Sweep: roll over, bill, auto-pay and suspend without waiting for the app to be opened
-- ---------------------------------------------------------------------------------------------

CreateThread(function()
    local every = tonumber(billingCfg.sweepSeconds) or 0
    if every <= 0 then return end
    while not gateLoaded do Wait(500) end
    while true do
        Wait(math.max(10, every) * 1000)
        for _, id in ipairs(GetPlayers()) do
            local src = tonumber(id)
            if src then
                pcall(function()
                    local key = resolveKey(src)
                    if not key then return end
                    local row = store.getAccount(key)
                    if row and (truthy(row.plan_chosen) or (tonumber(row.balance_due) or 0) > 0) then
                        maybeAdvanceCycle(src, key, row)
                    end
                end)
            end
        end
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------------------------

local function tryConsumeDownloadData(source, mb)
    local key, err = resolveKey(source)
    if not key then return { success = false, message = err or T('err.playerNotFound') } end

    local row = ensureAccount(key)
    maybeAdvanceCycle(source, key, row)

    local reason = blockReason(key)
    if reason == 'no_plan' then
        return { success = false, message = T('err.noPlan') }
    elseif reason == 'suspended' then
        return { success = false, message = T('err.suspended') }
    end
    if not truthy(row.plan_chosen) then return { success = true } end

    local plan = planFor(row.plan_id)
    local cap = tonumber(plan.dataMB) or -1
    if cap >= 0 and (tonumber(row.data_mb_used) or 0) >= cap then
        return { success = false, message = T('err.outOfData') }
    end

    store.addDataMB(key, tonumber(mb) or 0)
    pushUpdate(source)
    return { success = true }
end

exports('tryConsumeDownloadData', tryConsumeDownloadData)

--- Why a phone has no service, or nil. `key` is the identity sd-phone uses for the phone (player.getIdentifier).
---   'no_plan'   no plan chosen yet (only while Config.billing.requirePlan is on)
---   'suspended' the bill is overdue
exports('getBlockReason', function(key)
    return blockReason(key)
end)

exports('isSuspendedCached', function(key)
    return suspended[key] == true
end)
