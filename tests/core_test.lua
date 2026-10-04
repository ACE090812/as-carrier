-- Run from the resource folder:  lua tests/core_test.lua
package.path = './?.lua;' .. package.path
local H = require 'tests.harness'

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failed = failed + 1 print('  FAIL: ' .. msg) end
end
local function eq(a, b, msg) check(a == b, ('%s (got %s, want %s)'):format(msg, tostring(a), tostring(b))) end
local function near(a, b, msg) check(math.abs((a or 0) - b) < 0.0051, ('%s (got %s, want %s)'):format(msg, tostring(a), tostring(b))) end
local function section(name) print('- ' .. name) end

local DAY = 86400
local function row(key) return H.store.accounts[key] end
local function lastBill(key)
    local out
    for _, h in ipairs(H.store.history) do if h.citizenid == key and h.kind == 'bill' then out = h end end
    return out
end
local function itemOf(h, k) for _, i in ipairs(h.items or {}) do if i.k == k then return i end end end

-- ---------------------------------------------------------------------------------------------
section('first plan, welcome promotion, rollover, promotion ends')
do
    local core = H.load()
    local key = H.player(1, 1000)
    local r = H.call('status', 1)
    check(r.ok and not r.data.chosen, 'new account has no plan')
    eq(core.blockReason(key), 'no_plan', 'no plan blocks service')
    check(r.data.offers.basic and r.data.offers.basic.firstPrice == 5, 'welcome offer shown (half price)')

    r = H.call('selectPlan', 1, { planId = 'basic' })
    check(r.ok and r.data.chosen, 'basic chosen')
    eq(r.data.promo and r.data.promo.cyclesLeft, 1, 'promo attached')
    eq(core.blockReason(key), nil, 'service on')
    check(not H.call('status', 1).data.offers.basic, 'new customer offer gone once used')

    H.advance(28 * DAY + 5)
    r = H.call('status', 1)
    local bill = lastBill(key)
    near(bill.amount, 5, 'first bill is half price')
    check(itemOf(bill, 'promo') and itemOf(bill, 'promo').amount == -5, 'promo line on the bill')
    eq(r.data.balanceDue, 5, 'balance due')
    eq(r.data.status, 'due', 'status due')
    check(r.data.promo == nil, 'promo used up')

    H.call('payBill', 1)
    eq(H.bank[1], 995, 'paid from bank')
    eq(row(key).balance_due, 0, 'balance cleared')
    H.advance(28 * DAY + 5)
    H.call('status', 1)
    near(lastBill(key).amount, 10, 'second bill is full price')
end

-- ---------------------------------------------------------------------------------------------
section('double click on Pay now cannot charge twice')
do
    local core = H.load()
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    H.advance(28 * DAY + 5)
    H.call('status', 1)
    local results = {}
    -- both requests start at once; the first one holds the lock across a yield
    local orig = H.store.markPaid
    H.store.markPaid = function(...) Wait() return orig(...) end
    H.spawn(function() results[1] = H.call('payBill', 1) end)
    H.spawn(function() results[2] = H.call('payBill', 1) end)
    H.runThreads()
    H.store.markPaid = orig
    local oks = 0
    for _, x in ipairs(results) do if x.ok then oks = oks + 1 end end
    eq(oks, 1, 'exactly one payment went through')
    eq(#H.charged, 1, 'bank was charged once')
end

-- ---------------------------------------------------------------------------------------------
section('usage, overage and usage alerts')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    H.handlers['sd-phone:server:call:ended']({ caller = { citizenid = key }, callee = { citizenid = 'other' }, duration = 61 })
    eq(row(key).minutes_used, 0, 'usage is held in memory until flushed')
    eq(core._.cache[key].minutes_used, 2, 'call rounded up to whole minutes')
    core.flushAll()
    eq(row(key).minutes_used, 2, 'flush writes it')

    for i = 1, 200 do H.handlers['sd-phone:server:messages:sent']({ citizenid = key }) end
    eq(#H.notices('Usage'), 1, 'one alert at 80% of texts')
    for i = 1, 50 do H.handlers['sd-phone:server:messages:sent']({ citizenid = key }) end
    eq(#H.notices('Usage'), 2, 'a second alert at 100%')
    for i = 1, 5 do H.handlers['sd-phone:server:messages:sent']({ citizenid = key }) end
    eq(#H.notices('Usage'), 2, 'no repeat alerts')
    core.flushAll()
    local d = H.call('status', 1).data.daily
    eq(#d, 1, 'one day of usage')
    eq(d[1].t, 255, 'daily texts')
    eq(d[1].m, 2, 'daily minutes')

    -- overage on the bill
    H.handlers['sd-phone:server:call:ended']({ caller = { citizenid = key }, callee = { citizenid = 'x' }, duration = 60 * 300 })
    H.advance(28 * DAY + 5)
    H.call('status', 1)
    local bill = lastBill(key)
    near(itemOf(bill, 'minutes').amount, (302 - 250) * 0.10, 'minute overage')
    near(itemOf(bill, 'texts').amount, 5 * 0.05, 'text overage')
    near(bill.amount, 10 + 5.2 + 0.25, 'total')
    eq(row(key).minutes_used, 0, 'usage reset')
    eq(row(key).alert_bits & 0x3F, 0, 'alerts re-armed')
end

-- ---------------------------------------------------------------------------------------------
section('out of data: bill / throttle / block')
do
    local function run(mode)
        local core = H.load(function(c) c.promotions = {}; c.billing.outOfData = mode end)
        local key = H.player(1, 1000)
        H.call('selectPlan', 1, { planId = 'lite' })   -- 500 MB
        for i = 1, 100 do H.callbacks['sd_carrier:dataHeartbeat'](1) H.advance(100) end
        return core, key
    end
    local core, key = run('bill')
    local st = H.call('status', 1).data
    check(st.dataMBUsed > 500, 'bill mode keeps counting')
    eq(st.dataState, 'ok', 'bill mode: still ok')
    H.advance(28 * DAY)
    H.call('status', 1)
    check(itemOf(lastBill(key), 'data') ~= nil, 'overage billed')
    local res = H.exports.tryConsumeDownloadData(1, 10)
    check(res.success, 'bill mode: downloads allowed')

    core, key = run('throttle')
    st = H.call('status', 1).data
    eq(st.dataMBUsed, 500, 'throttle mode stops at the cap')
    eq(st.dataState, 'throttled', 'throttled state')
    res = H.exports.tryConsumeDownloadData(1, 10)
    check(res.success and res.throttled, 'throttle: download allowed, slowed')
    eq(H.exports.getDataState(1), 'throttled', 'export reports throttled')
    H.advance(28 * DAY)
    H.call('status', 1)
    check(itemOf(lastBill(key), 'data') == nil, 'throttle: no data charge')
    check(#H.notices('Usage') > 0, 'alert sent')

    core, key = run('block')
    st = H.call('status', 1).data
    eq(st.dataState, 'blocked', 'blocked state')
    res = H.exports.tryConsumeDownloadData(1, 10)
    check(not res.success, 'block: download refused')
    eq(core.blockReason(key), nil, 'calls still allowed when only data is out')

    -- an add-on lifts the cap
    local b = H.bank[1]
    local r = H.call('buyAddon', 1, { id = 'data1' })
    check(r.ok, 'add-on bought')
    eq(H.bank[1], b - 5, 'add-on charged to the bank')
    eq(r.data.dataState, 'ok', 'data is back after an add-on')
    eq(r.data.extraDataMB, 1024, 'extra MB')
    check(#H.call('status', 1).data.history > 0 and H.call('status', 1).data.history[1].kind == 'addon', 'add-on on the activity list')
    H.advance(28 * DAY + 5)
    r = H.call('status', 1)
    eq(r.data.extraDataMB, 0, 'add-on MB expire at the end of the cycle')
end

-- ---------------------------------------------------------------------------------------------
section('add-on carry over and unlimited plans')
do
    local core = H.load(function(c) c.promotions = {}; c.billing.addons.carryOver = true end)
    H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'lite' })
    H.call('buyAddon', 1, { id = 'data1' })
    H.advance(28 * DAY + 5)
    local st = H.call('status', 1).data
    eq(st.extraDataMB, 1024, 'carry over keeps unused add-on MB')
    core = H.load(function(c) c.promotions = {} end)
    H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'unlimited' })
    local r = H.call('buyAddon', 1, { id = 'data1' })
    check(not r.ok, 'no add-on on unlimited data')
end

-- ---------------------------------------------------------------------------------------------
section('prepaid pay as you go')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 500)
    local r = H.call('selectPlan', 1, { planId = 'payg' })
    check(r.ok, 'payg chosen with no credit')
    eq(core.blockReason(key), 'no_credit', 'no credit = no service')
    r = H.call('topUp', 1, { amount = 1 })
    check(not r.ok, 'top up below the minimum refused')
    r = H.call('topUp', 1, { amount = 10 })
    check(r.ok, 'top up works')
    eq(r.data.credit, 10, 'credit')
    eq(H.bank[1], 490, 'bank charged')
    eq(core.blockReason(key), nil, 'service on')
    H.handlers['sd-phone:server:call:ended']({ caller = { citizenid = key }, callee = { citizenid = 'x' }, duration = 120 })
    near(core._.cache[key].credit, 10 - 2 * 0.15, 'two minutes taken from credit')
    for i = 1, 5 do H.handlers['sd-phone:server:messages:sent']({ citizenid = key }) end
    near(core._.cache[key].credit, 10 - 0.3 - 0.4, 'texts taken from credit')
    -- run out
    H.handlers['sd-phone:server:call:ended']({ caller = { citizenid = key }, callee = { citizenid = 'x' }, duration = 60 * 100 })
    eq(core._.cache[key].credit, 0, 'credit never goes negative')
    eq(core.blockReason(key), 'no_credit', 'blocked at zero credit')
    check(#H.notices('credit') >= 1, 'out of credit notice')
    -- no bills ever
    H.advance(60 * DAY)
    H.call('status', 1)
    check(lastBill(key) == nil, 'prepaid never gets a bill')
    eq(row(key).balance_due, 0, 'nothing owed')
    -- a postpaid account can't top up
    H.call('selectPlan', 1, { planId = 'basic' })
    r = H.call('topUp', 1, { amount = 10 })
    check(not r.ok, 'a monthly plan cannot be topped up')
    eq(H.bank[1], 490, 'and nothing was charged')
end

-- ---------------------------------------------------------------------------------------------
section('prepaid bundle: buy, use, expire, auto-renew')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 500)
    local r = H.call('selectPlan', 1, { planId = 'bundle30' })
    check(not r.ok and r.needCredit == 8, 'bundle needs credit first')
    H.call('topUp', 1, { amount = 20 })
    r = H.call('selectPlan', 1, { planId = 'bundle30' })
    check(r.ok, 'bundle bought')
    eq(r.data.credit, 12, 'bundle price taken from credit')
    eq(r.data.kind, 'bundle', 'kind')
    eq(row(key).due_at, H.NOW + 30 * DAY, 'ends after durationDays')
    H.handlers['sd-phone:server:call:ended']({ caller = { citizenid = key }, callee = { citizenid = 'x' }, duration = 60 * 100 })
    eq(core._.cache[key].credit, 12, 'inside the bundle nothing is taken')
    H.handlers['sd-phone:server:call:ended']({ caller = { citizenid = key }, callee = { citizenid = 'x' }, duration = 60 * 100 })
    near(core._.cache[key].credit, 12 - 50 * 0.15, 'past the bundle minutes credit pays')
    r = H.call('selectPlan', 1, { planId = 'bundle30' })
    check(not r.ok, 'cannot buy the same live bundle again')

    H.advance(31 * DAY)
    core.sweepOnce()
    eq(core.blockReason(key), 'expired', 'bundle expired, service stops')
    check(#H.notices('Bundle') >= 1, 'told it ended')
    -- renew by hand
    H.call('topUp', 1, { amount = 20 })
    r = H.call('selectPlan', 1, { planId = 'bundle30' })
    check(r.ok, 'renewed')
    eq(core.blockReason(key), nil, 'service back')
    -- auto renew
    H.call('setAutoPay', 1, { on = true })
    H.advance(31 * DAY)
    core.sweepOnce()
    eq(core.blockReason(key), nil, 'auto-renewed, no gap')
    eq(core._.cache[key].due_at > H.NOW, true, 'new end date')
end

-- ---------------------------------------------------------------------------------------------
section('contract: exit fee, upgrade, cancel')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'contract6' })
    local st = H.call('status', 1).data
    eq(st.contract.cycles, 6, 'contract length')
    eq(st.contract.cyclesLeft, 6, 'six cycles to go')
    near(st.contract.exitFee, 14 * 6 * 0.5, 'exit fee is half the remaining fees')

    local r = H.call('selectPlan', 1, { planId = 'basic' })
    check(not r.ok and r.needsExit and r.fee == 42, 'leaving needs the fee confirmed')
    eq(row(key).plan_id, 'contract6', 'nothing changed')
    r = H.call('selectPlan', 1, { planId = 'basic', payExit = true })
    check(r.ok, 'left the contract')
    eq(r.data.plan.id, 'basic', 'now on basic straight away')
    eq(H.bank[1], 1000 - 42, 'fee charged')
    check(lastBill(key) ~= nil, 'the open cycle was billed')
    local fees = 0
    for _, h in ipairs(H.store.history) do if h.kind == 'fee' then fees = fees + h.amount end end
    eq(fees, 42, 'fee on the activity list')
    eq(row(key).contract_ends, nil, 'no contract any more')

    -- upgrade out of a contract is free and queues
    core = H.load(function(c) c.promotions = {} end)
    key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'contract6' })
    r = H.call('selectPlan', 1, { planId = 'unlimited' })
    check(r.ok and r.data.pendingPlan and r.data.pendingPlan.id == 'unlimited', 'upgrade queues for free')
    eq(H.bank[1], 1000, 'no fee')
    H.advance(28 * DAY + 5)
    r = H.call('status', 1)
    eq(r.data.plan.id, 'unlimited', 'switched at the end of the cycle')
    eq(row(key).contract_ends, nil, 'contract replaced')

    -- cancel a contract
    core = H.load(function(c) c.promotions = {} end)
    key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'contract6' })
    r = H.call('cancelService', 1, {})
    check(not r.ok and r.needsExit, 'cancel needs the fee')
    r = H.call('cancelService', 1, { payExit = true })
    check(r.ok and not r.data.chosen, 'cancelled straight away after paying')
    -- cancel without a contract is queued
    core = H.load(function(c) c.promotions = {} end)
    key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    r = H.call('cancelService', 1, {})
    check(r.ok and r.data.pendingCancel and r.data.chosen, 'cancel queued, still on the plan')
    H.advance(28 * DAY + 5)
    r = H.call('status', 1)
    check(not r.data.chosen, 'plan ends at the end of the cycle')
end

-- ---------------------------------------------------------------------------------------------
section('plan lock, queue and cancel switch')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    local r = H.call('selectPlan', 1, { planId = 'standard' })
    eq(r.data.pendingPlan.id, 'standard', 'switch queued')
    eq(r.data.plan.id, 'basic', 'still on basic')
    r = H.call('selectPlan', 1, { planId = 'basic' })
    eq(r.data.pendingPlan, nil, 'choosing the current plan drops the queue')
    H.call('selectPlan', 1, { planId = 'standard' })
    r = H.call('cancelPending', 1)
    eq(r.data.pendingPlan, nil, 'cancelled')
end

-- ---------------------------------------------------------------------------------------------
section('pause and resume')
do
    local core = H.load(function(c) c.promotions = {}; c.pause.fee = 3 end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    local dueBefore = row(key).due_at
    H.advance(5 * DAY)
    local r = H.call('pause', 1, { days = 10 })
    check(r.ok and r.data.paused, 'paused')
    eq(H.bank[1], 997, 'pause fee charged')
    eq(core.blockReason(key), 'paused', 'service off while paused')
    H.handlers['sd-phone:server:messages:sent']({ citizenid = key })
    eq(core._.cache[key].texts_used, 0, 'nothing metered while paused')
    H.advance(4 * DAY)
    r = H.call('resume', 1)
    check(r.ok and not r.data.paused, 'resumed early')
    eq(row(key).due_at, dueBefore + 4 * DAY, 'the cycle picks up where it left off')
    eq(core.blockReason(key), nil, 'service back')

    r = H.call('pause', 1, { days = 3 })
    H.advance(4 * DAY)
    core.sweepOnce()
    check(row(key).paused_at == nil, 'sweep ends the pause on time')
    check(#H.notices('Plan resumed') == 1, 'told the pause is over')

    -- cannot pause with a bill outstanding or in a contract
    core = H.load(function(c) c.promotions = {} end)
    key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'contract6' })
    r = H.call('pause', 1, { days = 3 })
    check(not r.ok, 'no pause in a contract')
end

-- ---------------------------------------------------------------------------------------------
section('late fee and escalation')
do
    local core = H.load(function(c) c.promotions = {}; c.payment.offlineAutoPay = false end)
    local key = H.player(1, 0)
    H.call('selectPlan', 1, { planId = 'basic' })
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    eq(row(key).status, 'due', 'bill raised')
    eq(row(key).balance_due, 10, 'balance')
    check(#H.notices('Phone Bill') == 1, 'bill notification')

    H.advance(DAY + 60)
    core.sweepOnce()
    eq(row(key).balance_due, 15, 'late fee added')
    check(#H.notices('Late fee') == 1, 'late fee notice')
    core.sweepOnce()
    eq(row(key).balance_due, 15, 'late fee only once')

    H.advance(DAY + 60)
    core.sweepOnce()
    eq(row(key).status, 'limited', 'limited step')
    eq(core.blockReason(key), nil, 'calls and texts still on')
    eq(core.blockReason(key, 'data'), 'limited', 'data is off')
    check(not H.exports.tryConsumeDownloadData(1, 5).success, 'downloads refused while limited')
    check(#H.notices('Mobile data off') == 1, 'limited notice')

    H.advance(DAY + 60)
    core.sweepOnce()
    eq(row(key).status, 'suspended', 'suspended after the grace period')
    eq(core.blockReason(key), 'suspended', 'service off')
    check(#H.notices('suspended') >= 1, 'suspension notice')
    check(#H.localEvents > 0 and H.localEvents[#H.localEvents].name == 'sd_carrier:accountSuspended', 'event for other scripts')

    -- can't pay: broke
    local r = H.call('payBill', 1)
    check(not r.ok, 'insufficient funds')
    H.bank[1] = 100
    r = H.call('payBill', 1)
    check(r.ok, 'paid')
    eq(r.data.status, 'current', 'restored')
    eq(core.blockReason(key), nil, 'service back')
    eq(H.bank[1], 85, 'paid bill and fee')
    local unpaid = 0
    for _, h in ipairs(H.store.history) do if h.paid == 0 then unpaid = unpaid + 1 end end
    eq(unpaid, 0, 'every bill and fee marked paid')
end

-- ---------------------------------------------------------------------------------------------
section('suspension reminder')
do
    local core = H.load(function(c) c.promotions = {}; c.billing.lateFee.enabled = false; c.billing.limitedAfterDays = 0 end)
    local key = H.player(1, 0)
    H.call('selectPlan', 1, { planId = 'basic' })
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    H.advance(2 * DAY + 3600)   -- 23h before suspension
    core.sweepOnce()
    eq(#H.notices('Pay your bill'), 1, 'one reminder before suspension')
    core.sweepOnce()
    eq(#H.notices('Pay your bill'), 1, 'and only one')
    H.advance(DAY)
    core.sweepOnce()
    eq(row(key).status, 'suspended', 'then suspended')
    eq(#H.notices('Pay your bill'), 1, 'no reminder after suspension')
end

-- ---------------------------------------------------------------------------------------------
section('auto-pay: online, offline, failure and retry')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    H.call('setAutoPay', 1, { on = true })
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    eq(row(key).balance_due, 0, 'auto-paid at rollover')
    eq(H.bank[1], 990, 'online auto-pay')

    -- the player goes offline; the sweep still bills and pays from the bank
    H.online[1] = nil
    H.offlineBank['CID1'] = 50
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    eq(row(key).balance_due, 0, 'offline auto-pay')
    eq(H.offlineBank['CID1'], 40, 'charged to the offline bank')

    -- offline and broke: bill stays, one notice, retried later, paid when funds appear
    H.offlineBank['CID1'] = 1
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    eq(row(key).balance_due, 10, 'could not pay')
    H.advance(10)
    core.sweepOnce()
    eq(row(key).balance_due, 10, 'still not paid')
    H.offlineBank['CID1'] = 100
    core.sweepOnce()
    eq(row(key).balance_due, 10, 'retry waits for the interval')
    H.advance(3601)
    core.sweepOnce()
    eq(row(key).balance_due, 0, 'retried and paid')
end

-- ---------------------------------------------------------------------------------------------
section('offline auto-pay can be switched off')
do
    local core = H.load(function(c) c.promotions = {}; c.payment.offlineAutoPay = false end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    H.call('setAutoPay', 1, { on = true })
    H.online[1] = nil
    H.offlineBank['CID1'] = 500
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    eq(row(key).balance_due, 10, 'not charged while offline')
    eq(H.offlineBank['CID1'], 500, 'offline bank untouched')
    H.online[1] = true
    H.advance(3601)
    core.sweepOnce()
    eq(row(key).balance_due, 0, 'paid once online')
end

-- ---------------------------------------------------------------------------------------------
section('promotions: window, code, once per account')
do
    local core = H.load(function(c)
        c.promotions = {
            { id = 'sale', label = 'Sale', kind = 'percent', value = 25, cycles = 3, plans = { 'standard' },
              startsAt = '2023-11-01', endsAt = '2023-12-31' },
            { id = 'old', label = 'Old', kind = 'amount', value = 5, endsAt = '2020-01-01' },
            { id = 'code', label = 'Code', kind = 'free', code = 'FREEBIE' },
        }
    end)
    local key = H.player(1, 1000)   -- NOW is 2023-11-14
    local st = H.call('status', 1).data
    check(st.offers.standard and st.offers.standard.firstPrice == 15, 'sale shows for the plan it covers')
    check(not st.offers.basic, 'not for other plans')
    check(not (st.offers.standard and st.offers.standard.promoId == 'old'), 'expired promotion ignored')
    local r = H.call('selectPlan', 1, { planId = 'basic', code = 'nope' })
    check(not r.ok, 'wrong code refused')
    r = H.call('selectPlan', 1, { planId = 'basic', code = ' freebie ' })
    check(r.ok and r.data.promo.label == 'Code', 'code accepted (any case)')
    H.advance(28 * DAY + 5)
    H.call('status', 1)
    eq(lastBill(key).amount, 0, 'free first bill')
    check(lastBill(key).paid == 1, 'a free bill is paid')
    eq(row(key).balance_due, 0, 'nothing to pay')

    -- 3-cycle percent promotion
    H.load(function(c)
        c.promotions = { { id = 'sale', label = 'Sale', kind = 'percent', value = 20, cycles = 2 } }
    end)
    key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'standard' })
    H.call('setAutoPay', 1, { on = true })
    for i = 1, 3 do H.advance(28 * DAY + 5) H.call('status', 1) end
    local amounts = {}
    for _, h in ipairs(H.store.history) do if h.kind == 'bill' then amounts[#amounts + 1] = h.amount end end
    eq(amounts[1], 16, 'bill 1 discounted'); eq(amounts[2], 16, 'bill 2 discounted'); eq(amounts[3], 20, 'bill 3 full')
end

-- ---------------------------------------------------------------------------------------------
section('admin commands')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    local cmd = H.commands['carrier']
    check(cmd ~= nil, 'command registered')
    local say = {}
    local oldNotify = TriggerClientEvent
    cmd(0, { action = 'info', target = '1' })
    cmd(0, { action = 'credit', target = '1', value = '25' })
    near(row(key).credit, 25, 'credit added')
    cmd(0, { action = 'setplan', target = '1', value = 'unlimited' })
    eq(row(key).plan_id, 'unlimited', 'plan set')
    cmd(0, { action = 'suspend', target = '1' })
    eq(core.blockReason(key), 'suspended', 'suspended')
    cmd(0, { action = 'restore', target = '1' })
    eq(core.blockReason(key), nil, 'restored')
    cmd(0, { action = 'adddata', target = key, value = '500' })
    eq(row(key).extra_data_mb, 500, 'add-on data')
    cmd(0, { action = 'unplan', target = '1' })
    eq(row(key).plan_chosen, 0, 'plan removed')
    check(#H.store.audits >= 5, 'every change is audited')
    cmd(0, { action = 'setplan', target = 'nobody', value = 'basic' })
end

-- ---------------------------------------------------------------------------------------------
section('sweep only touches accounts that need it, and a suspended unpaid account is skipped')
do
    local core = H.load(function(c) c.promotions = {} end)
    for i = 1, 5 do H.player(i, 100) H.call('selectPlan', i, { planId = 'basic' }) end
    eq(#H.store.listDue(H.NOW), 0, 'nothing due')
    H.advance(28 * DAY + 5)
    eq(#H.store.listDue(H.NOW), 5, 'all five due')
    eq(core.sweepOnce(), 5, 'sweep handles them')
    eq(#H.store.listDue(H.NOW + 1), 5, 'unpaid balances stay on the list')
    H.advance(5 * DAY)
    core.sweepOnce()
    eq(row('CID1').status, 'suspended', 'suspended')
    eq(#H.store.listDue(H.NOW), 0, 'a suspended account without auto-pay leaves the list')
end

-- ---------------------------------------------------------------------------------------------
section('existing accounts keep working: gate loads from the database, restart never blocks')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 100)
    H.call('selectPlan', 1, { planId = 'basic' })
    -- fresh start: nothing known yet
    local c2 = H.load(function(c) c.promotions = {} end)
    eq(c2.blockReason('someone'), 'no_plan', 'unknown account is blocked once the gate is loaded')
end


-- ---------------------------------------------------------------------------------------------
section('first plan with no credit for a bundle, unpaid debt from before, and an account with an old balance')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('status', 1)
    H.store.accounts[key].balance_due = 12
    H.store.accounts[key].balance_since = H.NOW - 5 * DAY
    core._.cache[key] = nil
    core.sweepOnce()
    eq(row(key).status, 'suspended', 'an old debt still suspends an account with no plan')
    local r = H.call('payBill', 1)
    check(r.ok, 'old debt can be paid')
    eq(row(key).status, 'current', 'restored')
end

-- ---------------------------------------------------------------------------------------------
section('prepaid switch rules')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('topUp', 1, { amount = 30 })
    H.call('selectPlan', 1, { planId = 'payg' })
    local r = H.call('selectPlan', 1, { planId = 'basic' })
    check(r.ok and r.data.plan.id == 'basic' and not r.data.pendingPlan, 'leaving prepaid switches straight away')
    near(row(key).credit, 30, 'credit stays')
    -- postpaid -> bundle is queued; at the end of the cycle the bundle is bought from credit
    r = H.call('selectPlan', 1, { planId = 'bundle30' })
    check(r.ok and r.data.pendingPlan and r.data.pendingPlan.id == 'bundle30', 'postpaid to bundle is queued')
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    eq(row(key).plan_id, 'bundle30', 'switched')
    near(row(key).credit, 22, 'bundle paid from credit at the switch')
    eq(core.blockReason(key), nil, 'service on')
end

-- ---------------------------------------------------------------------------------------------
section('queued bundle with no credit leaves the account ended until it is bought')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('selectPlan', 1, { planId = 'basic' })
    H.call('selectPlan', 1, { planId = 'bundle30' })
    H.advance(28 * DAY + 5)
    core.sweepOnce()
    eq(row(key).plan_id, 'bundle30', 'on the bundle')
    eq(core.blockReason(key), 'expired', 'but it could not be paid for, so service is off')
    local r = H.call('status', 1)
    eq(r.data.plan.id, 'bundle30', 'plan shown')
end

-- ---------------------------------------------------------------------------------------------
section('config sanity: bad config does not crash')
do
    local core = H.load(function(c)
        c.promotions = { { id = 'x', plans = { 'nope' } }, { kind = 'percent' } }
        c.billing.plans[#c.billing.plans + 1] = { id = 'basic', label = 'dup', price = -1 }
        c.billing.addons.list[#c.billing.addons.list + 1] = { id = 'bad' }
    end)
    check(core ~= nil, 'loads with problems in the config (they are printed)')
end

-- ---------------------------------------------------------------------------------------------
section('status payload shape the app relies on')
do
    local core = H.load()
    H.player(1, 1000)
    local d = H.call('status', 1).data
    for _, k in ipairs({ 'chosen', 'plans', 'offers', 'topUp', 'addons', 'pauseCfg', 'lateFee', 'daily', 'usageDays', 'history', 'now', 'cycleDays', 'planLock', 'requirePlan', 'balanceDue', 'credit' }) do
        check(d[k] ~= nil, 'status has ' .. k)
    end
    H.call('selectPlan', 1, { planId = 'basic' })
    d = H.call('status', 1).data
    for _, k in ipairs({ 'plan', 'kind', 'status', 'dataState', 'cycleStart', 'dueAt', 'minutesUsed', 'textsUsed', 'dataMBUsed', 'extraDataMB', 'estimatedThisCycle', 'autoPay', 'contract' }) do
        check(d[k] ~= nil, 'chosen status has ' .. k)
    end
end


-- ---------------------------------------------------------------------------------------------
section('a bundle stops the moment it ends, not when the sweep notices')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 1000)
    H.call('topUp', 1, { amount = 20 })
    H.call('selectPlan', 1, { planId = 'bundle30' })
    eq(core.blockReason(key), nil, 'on while it runs')
    H.advance(30 * DAY - 1)
    eq(core.blockReason(key), nil, 'still on one second before the end')
    H.advance(1)
    eq(core.blockReason(key), 'expired', 'off at the end, no sweep needed')
    H.handlers['sd-phone:server:messages:sent']({ citizenid = key })
    eq(core._.cache[key].texts_used, 0, 'an ended bundle meters nothing')
    local r = H.call('status', 1)
    eq(r.data.blocked, 'expired', 'the app is told')
    r = H.call('selectPlan', 1, { planId = 'bundle30' })
    check(r.ok, 'it can be bought again')
    eq(core.blockReason(key), nil, 'service back')
end


-- ---------------------------------------------------------------------------------------------
section('usage is not lost when the database is down for a moment')
do
    local core = H.load(function(c) c.promotions = {} end)
    local key = H.player(1, 100)
    H.call('selectPlan', 1, { planId = 'basic' })
    for i = 1, 3 do H.handlers['sd-phone:server:messages:sent']({ citizenid = key }) end
    local save, daily = H.store.save, H.store.addDaily
    H.store.save = function() error('db down') end
    H.store.addDaily = function() error('db down') end
    core.flushAll()
    H.store.save, H.store.addDaily = save, daily
    core.flushAll()
    eq(row(key).texts_used, 3, 'counters saved on the next flush')
    eq(H.store.daily[key][math.floor(H.NOW / DAY)].texts, 3, 'daily usage saved too')
end

print(('\n%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
