local store = require 'server.store'
local Bridge = CarrierBridge or require 'server.bridge'

local billingCfg = Config.billing or {}
local PLANS = {}
for _, p in ipairs(billingCfg.plans or {}) do
    if p.id then PLANS[p.id] = p end
end
local FALLBACK_PLAN = billingCfg.defaultPlan or next(PLANS)

local CYCLE_SECONDS = math.max(1, math.floor(tonumber(billingCfg.cycleDays) or 28)) * 86400
local GRACE_SECONDS = math.max(0, math.floor(tonumber(billingCfg.graceDays) or 3)) * 86400

CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        print(('[as_carrier] failed to create its tables: %s'):format(tostring(err)))
    end
end)

local suspended = {}

local function planFor(id)
    return PLANS[id] or PLANS[FALLBACK_PLAN]
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

local function ensureAccount(cid)
    local row = store.getAccount(cid)
    if row then
        suspended[cid] = row.status == 'suspended'
        return row
    end
    local now = os.time()
    store.insertAccount(cid, FALLBACK_PLAN, now, now + CYCLE_SECONDS)
    row = store.getAccount(cid) or {
        citizenid = cid, plan_id = FALLBACK_PLAN, cycle_start = now, due_at = now + CYCLE_SECONDS,
        auto_pay = 0, status = 'current', minutes_used = 0, texts_used = 0, data_mb_used = 0, balance_due = 0, balance_since = nil,
    }
    suspended[cid] = false
    return row
end

local pushUpdate

local function maybeAdvanceCycle(source, cid, row)
    local now = os.time()

    local function escalate()
        local since = tonumber(row.balance_since)
        if (tonumber(row.balance_due) or 0) <= 0 or not since then return end
        local nextStatus = (now - since >= GRACE_SECONDS) and 'suspended' or 'due'
        if row.status ~= nextStatus then
            store.setStatus(cid, nextStatus)
            local wasSuspended = row.status == 'suspended'
            row.status = nextStatus
            if nextStatus == 'suspended' and not wasSuspended then
                TriggerEvent('as_carrier:accountSuspended', cid)
            elseif wasSuspended and nextStatus ~= 'suspended' then
                TriggerEvent('as_carrier:accountRestored', cid)
            end
        end
        suspended[cid] = row.status == 'suspended'
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

    store.insertHistory(cid, row.plan_id, charge, tonumber(row.cycle_start) or now)
    store.rollCycle(cid, newCycleStart, newDueAt, newBalance, newBalance > 0 and balanceSince or nil)

    row.cycle_start, row.due_at = newCycleStart, newDueAt
    row.minutes_used, row.texts_used, row.data_mb_used = 0, 0, 0
    row.balance_due, row.balance_since = newBalance, balanceSince

    local autoPay = row.auto_pay == true or row.auto_pay == 1
    local paid = false
    if autoPay and source and newBalance > 0 then
        paid = Bridge.removeMoney(source, Config.payment.account, newBalance)
        if paid then
            store.markLatestPaid(cid, now)
            store.clearBalance(cid)
            row.balance_due, row.balance_since = 0, nil
            row.status = 'current'
        end
    end

    if not paid then
        row.status = (newBalance > 0) and 'due' or 'current'
        store.setStatus(cid, row.status)
    end

    local wasSuspended = suspended[cid] == true
    suspended[cid] = row.status == 'suspended'
    if suspended[cid] and not wasSuspended then TriggerEvent('as_carrier:accountSuspended', cid) end
    pushUpdate(source)

    if source and newBalance > 0 then
        TriggerClientEvent('sd-phone:client:notify', source, {
            app = 'carrier', appId = Config.app.identifier,
            title = paid and 'Bill Paid' or 'Phone Bill',
            body = paid
                and ('Auto-paid your %s bill.'):format(plan.label or 'phone')
                or ('Your %s bill of $%.2f is due.'):format(plan.label or 'phone', newBalance),
            time = 'now',
        })
    end
end

local function serializePlan(plan)
    return {
        id = plan.id, label = plan.label, price = plan.price,
        minutes = plan.minutes, texts = plan.texts, dataMB = plan.dataMB,
        overagePerMinute = plan.overagePerMinute, overagePerText = plan.overagePerText, overagePerMB = plan.overagePerMB,
    }
end

local function statusFor(source)
    local cid = Bridge.getIdentifier(source)
    if not cid then return nil, 'Player not found' end

    local row = ensureAccount(cid)
    maybeAdvanceCycle(source, cid, row)

    local plan = planFor(row.plan_id)
    local history = {}
    for i, h in ipairs(store.listHistory(cid, 12)) do
        history[i] = {
            id = h.id, planId = h.plan_id, amount = tonumber(h.amount) or 0,
            paid = h.paid == true or h.paid == 1, paidAt = h.paid_at,
            cycleStart = h.cycle_start,
        }
    end

    return {
        plan   = serializePlan(plan),
        plans  = (function() local out = {} for _, p in ipairs(billingCfg.plans or {}) do out[#out + 1] = serializePlan(p) end return out end)(),
        status = row.status,
        autoPay = row.auto_pay == true or row.auto_pay == 1,
        cycleStart = tonumber(row.cycle_start),
        dueAt      = tonumber(row.due_at),
        minutesUsed = tonumber(row.minutes_used) or 0,
        textsUsed   = tonumber(row.texts_used) or 0,
        dataMBUsed  = tonumber(row.data_mb_used) or 0,
        estimatedThisCycle = cycleCharge(plan, row),
        balanceDue = tonumber(row.balance_due) or 0,
        history    = history,
    }
end

function pushUpdate(src)
    if src then TriggerClientEvent('as_carrier:client:updated', src, {}) end
end

lib.callback.register('as_carrier:status', function(source)
    local data, err = statusFor(source)
    if not data then return { ok = false, error = err } end
    return { ok = true, data = data }
end)

lib.callback.register('as_carrier:selectPlan', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = Bridge.getIdentifier(source)
    if not cid then return { ok = false, error = 'Player not found' } end
    if type(payload.planId) ~= 'string' or not PLANS[payload.planId] then return { ok = false, error = 'Unknown plan' } end

    ensureAccount(cid)
    store.setPlan(cid, payload.planId)
    local data = statusFor(source)
    return { ok = true, data = data }
end)

lib.callback.register('as_carrier:setAutoPay', function(source, payload)
    payload = type(payload) == 'table' and payload or {}
    local cid = Bridge.getIdentifier(source)
    if not cid then return { ok = false, error = 'Player not found' } end

    ensureAccount(cid)
    store.setAutoPay(cid, payload.on == true)
    return { ok = true, data = { autoPay = payload.on == true } }
end)

lib.callback.register('as_carrier:payBill', function(source)
    local cid = Bridge.getIdentifier(source)
    if not cid then return { ok = false, error = 'Player not found' } end

    local row = ensureAccount(cid)
    maybeAdvanceCycle(source, cid, row)

    local due = tonumber(row.balance_due) or 0
    if due <= 0 then return { ok = false, error = 'Nothing due' } end

    if not Bridge.removeMoney(source, Config.payment.account, due) then
        return { ok = false, error = 'Not enough money in your account' }
    end

    store.markLatestPaid(cid, os.time())
    store.clearBalance(cid)
    suspended[cid] = false
    TriggerEvent('as_carrier:accountRestored', cid)

    local data = statusFor(source)
    return { ok = true, data = data }
end)

lib.callback.register('as_carrier:dataHeartbeat', function(source)
    local cid = Bridge.getIdentifier(source)
    if not cid then return { ok = false, error = 'Player not found' } end
    ensureAccount(cid)
    store.addDataMB(cid, tonumber(billingCfg.dataPerHeartbeatMB) or 6)
    pushUpdate(source)
    return { ok = true }
end)

local function recordCallSeconds(cid, seconds)
    if type(cid) ~= 'string' or cid == '' then return end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    if not store.getAccount(cid) then return end
    store.addMinutes(cid, math.ceil(seconds / 60))
end

local function recordText(cid)
    if type(cid) ~= 'string' or cid == '' then return end
    if not store.getAccount(cid) then return end
    store.addTexts(cid, 1)
end

AddEventHandler('sd-phone:server:call:ended', function(call)
    if type(call) ~= 'table' then return end
    local callerCid = call.caller and call.caller.citizenid
    local calleeCid = call.callee and call.callee.citizenid
    recordCallSeconds(callerCid, call.duration)
    if calleeCid and calleeCid ~= callerCid then
        recordCallSeconds(calleeCid, call.duration)
    end
end)

AddEventHandler('sd-phone:server:messages:sent', function(payload)
    if type(payload) ~= 'table' then return end

    if payload.system or payload.group then return end
    recordText(payload.citizenid)
end)

local function tryConsumeDownloadData(source, mb)
    local cid = Bridge.getIdentifier(source)
    if not cid then return { success = false, message = 'Player not found' } end

    local row = ensureAccount(cid)
    maybeAdvanceCycle(source, cid, row)

    local plan = planFor(row.plan_id)
    local cap = tonumber(plan.dataMB) or -1
    if cap >= 0 and (tonumber(row.data_mb_used) or 0) >= cap then
        return { success = false, message = "You're out of mobile data for this cycle. Connect to Wi-Fi, switch plans, or wait for your next bill." }
    end

    store.addDataMB(cid, tonumber(mb) or 0)
    pushUpdate(source)
    return { success = true }
end

exports('tryConsumeDownloadData', tryConsumeDownloadData)

exports('isSuspendedCached', function(cid)
    return suspended[cid] == true
end)