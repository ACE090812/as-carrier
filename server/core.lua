-- The carrier engine: accounts held in memory, the service gate, usage, billing, plan changes.
-- server/main.lua wires it to sd-phone, the app and the sweep thread; server/admin.lua adds staff commands.

local store = require 'server.store'
local Bridge = CarrierBridge or require 'server.bridge'

local core = {}
local NULL = store.NULL
core.NULL = NULL

local billingCfg = Config.billing or {}
local paymentCfg = Config.payment or {}
local DAY = 86400

-- ---------------------------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------------------------

local PLANS, PLAN_LIST = {}, {}
for _, p in ipairs(billingCfg.plans or {}) do
    if p.id then
        p.type = (p.type == 'payg' or p.type == 'bundle') and p.type or 'postpaid'
        if p.type == 'payg' then
            p.price = p.price or 0
            p.minutes = p.minutes or 0
            p.texts = p.texts or 0
            p.dataMB = p.dataMB or 0
        end
        PLANS[p.id] = p
        PLAN_LIST[#PLAN_LIST + 1] = p
    end
end
-- Only fills the NOT NULL plan column of an account that has not chosen a plan yet. It is never billed.
local PLACEHOLDER_PLAN = (PLAN_LIST[1] and PLAN_LIST[1].id) or next(PLANS)
core.PLANS, core.PLAN_LIST = PLANS, PLAN_LIST

local CYCLE_SECONDS = math.max(1, math.floor(tonumber(billingCfg.cycleDays) or 28)) * DAY
local GRACE_SECONDS = math.max(0, math.floor(tonumber(billingCfg.graceDays) or 3)) * DAY
local LIMITED_SECONDS = math.max(0, tonumber(billingCfg.limitedAfterDays) or 0) * DAY
local REMIND_SECONDS = math.max(0, tonumber(billingCfg.suspendReminderHours) or 0) * 3600
local CUR = Config.currency or '£'
local AUTOPAY_RETRY = math.max(60, tonumber(paymentCfg.autoPayRetrySeconds) or 3600)
local PAY_ACCOUNT = paymentCfg.account or 'bank'
core.CYCLE_SECONDS, core.GRACE_SECONDS, core.DAY = CYCLE_SECONDS, GRACE_SECONDS, DAY

local function truthy(v) return v == true or v == 1 end
local function requirePlan() return billingCfg.requirePlan ~= false end
local function planLock() return billingCfg.planLock ~= false end
local function money(n) return math.floor((tonumber(n) or 0) * 100 + 0.5) / 100 end
local function priceText(n) return ('%s%.2f'):format(CUR, tonumber(n) or 0) end
core.truthy, core.money, core.priceText = truthy, money, priceText

local function kindOf(plan) return plan and plan.type or 'postpaid' end
local function isPrepaidKind(kind) return kind == 'payg' or kind == 'bundle' end
local function planFor(id) return PLANS[id] or PLANS[PLACEHOLDER_PLAN] end
core.kindOf, core.isPrepaidKind, core.planFor = kindOf, isPrepaidKind, planFor

--- Prints anything in config.lua that is likely a mistake.
function core.validateConfig()
    local seen = {}
    for _, p in ipairs(billingCfg.plans or {}) do
        if not p.id then print('[as-carrier] config: a plan has no id and is ignored')
        else
            if seen[p.id] then print(('[as-carrier] config: plan id "%s" is used twice'):format(p.id)) end
            seen[p.id] = true
            if (tonumber(p.price) or 0) < 0 then print(('[as-carrier] config: plan "%s" has a negative price'):format(p.id)) end
            if p.type == 'bundle' and (tonumber(p.durationDays) or 0) <= 0 then
                print(('[as-carrier] config: bundle "%s" needs durationDays'):format(p.id))
            end
            if p.type ~= 'payg' and p.type ~= 'bundle' and (tonumber(p.price) or 0) <= 0 and p.price ~= nil then
                print(('[as-carrier] config: postpaid plan "%s" is free'):format(p.id))
            end
        end
    end
    if not PLACEHOLDER_PLAN then print('[as-carrier] config: there are no plans') end
    if (tonumber(billingCfg.cycleDays) or 28) < 1 then print('[as-carrier] config: cycleDays must be at least 1') end
    if LIMITED_SECONDS > 0 and LIMITED_SECONDS >= GRACE_SECONDS then
        print('[as-carrier] config: limitedAfterDays should be smaller than graceDays, the limited step will be skipped')
    end
    for _, a in ipairs((billingCfg.addons or {}).list or {}) do
        if not a.id or (tonumber(a.dataMB) or 0) <= 0 or (tonumber(a.price) or -1) < 0 then
            print('[as-carrier] config: an add-on needs an id, a positive dataMB and a price')
        end
    end
    for _, p in ipairs(Config.promotions or {}) do
        if not p.id then print('[as-carrier] config: a promotion has no id')
        elseif p.plans then
            for _, pid in ipairs(p.plans) do
                if not PLANS[pid] then print(('[as-carrier] config: promotion "%s" names an unknown plan "%s"'):format(p.id, pid)) end
            end
        end
    end
end

-- Promotions ----------------------------------------------------------------------------------

local function parseTime(v)
    if type(v) == 'number' then return v end
    if type(v) == 'string' then
        local y, m, d, H, M = v:match('^(%d+)-(%d+)-(%d+)[ T]?(%d*):?(%d*)$')
        if y then
            return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d),
                hour = tonumber(H) or 0, min = tonumber(M) or 0, sec = 0 })
        end
    end
    return nil
end

local PROMOS, PROMO_LIST = {}, {}
for _, p in ipairs(Config.promotions or {}) do
    if p.id then
        local kind = (p.kind == 'amount' or p.kind == 'free') and p.kind or 'percent'
        local promo = {
            id = tostring(p.id), label = p.label or tostring(p.id), kind = kind, value = tonumber(p.value) or 0,
            cycles = math.max(1, math.floor(tonumber(p.cycles) or 1)), plans = p.plans,
            startsAt = parseTime(p.startsAt), endsAt = parseTime(p.endsAt),
            newCustomerOnly = p.newCustomerOnly == true,
            code = p.code and tostring(p.code):upper() or nil,
            enabled = p.enabled ~= false,
        }
        PROMOS[promo.id] = promo
        PROMO_LIST[#PROMO_LIST + 1] = promo
    end
end

local function discountOf(promo, fee)
    fee = tonumber(fee) or 0
    if fee <= 0 then return 0 end
    if promo.kind == 'free' then return fee end
    if promo.kind == 'amount' then return math.min(fee, promo.value) end
    return fee * math.min(100, math.max(0, promo.value)) / 100
end

local function hasUsed(row, id)
    for tok in (row.promos_used or ''):gmatch('[^,]+') do
        if tok == id then return true end
    end
    return false
end

local function eligible(p, planId, row, now)
    if not p.enabled then return false end
    if p.startsAt and now < p.startsAt then return false end
    if p.endsAt and now > p.endsAt then return false end
    if p.plans then
        local ok = false
        for _, id in ipairs(p.plans) do if id == planId then ok = true break end end
        if not ok then return false end
    end
    if hasUsed(row, p.id) then return false end
    if p.newCustomerOnly and hasUsed(row, '*') then return false end
    return true
end

--- The promotion a player gets on `planId`: the most valuable one they are eligible for. A code adds the
--- code's promotion to the choices. Returns nil, 'badcode' when a code was typed that does not apply.
function core.bestPromo(planId, row, code, now)
    local plan = PLANS[planId]
    local fee = plan and tonumber(plan.price) or 0
    local codeUp = (type(code) == 'string' and code:match('%S')) and code:upper():gsub('^%s+', ''):gsub('%s+$', '') or nil
    if fee <= 0 then
        if codeUp then return nil, 'badcode' end
        return nil
    end
    local best, bestTotal, codeOk = nil, 0, false
    for _, p in ipairs(PROMO_LIST) do
        if eligible(p, planId, row, now) then
            local usable = true
            if p.code then
                usable = codeUp ~= nil and p.code == codeUp
                if usable then codeOk = true end
            end
            if usable then
                local total = discountOf(p, fee) * p.cycles
                if total > bestTotal then best, bestTotal = p, total end
            end
        end
    end
    if codeUp and not codeOk then return nil, 'badcode' end
    return best
end

--- { [planId] = { promoId, label, kind, value, cycles, firstPrice } } for the promotions shown in the app.
function core.offersFor(row, now)
    local out = {}
    for _, plan in ipairs(PLAN_LIST) do
        local promo = core.bestPromo(plan.id, row, nil, now)
        if promo then
            local fee = tonumber(plan.price) or 0
            out[plan.id] = {
                promoId = promo.id, label = promo.label, kind = promo.kind, value = promo.value, cycles = promo.cycles,
                firstPrice = money(math.max(0, fee - discountOf(promo, fee))),
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Allowances and rates
-- ---------------------------------------------------------------------------------------------

local USED = { minutes = 'minutes_used', texts = 'texts_used', data = 'data_mb_used' }
local RATE = { minutes = 'overagePerMinute', texts = 'overagePerText', data = 'overagePerMB' }
local WHATS = { 'minutes', 'texts', 'data' }

local function includedOf(plan, row, what)
    local base
    if what == 'minutes' then base = tonumber(plan.minutes)
    elseif what == 'texts' then base = tonumber(plan.texts)
    else base = tonumber(plan.dataMB) end
    if base == nil then base = -1 end
    if base < 0 then return -1 end
    if what == 'data' then base = base + (row.extra_data_mb or 0) end
    return base
end

local function remainingOf(plan, row, what)
    local inc = includedOf(plan, row, what)
    if inc < 0 then return math.huge end
    return math.max(0, inc - (row[USED[what]] or 0))
end

local function rateOf(plan, what) return tonumber(plan[RATE[what]]) or 0 end

local function dataMode(plan)
    if kindOf(plan) == 'payg' then return 'bill' end
    local m = plan.outOfData or billingCfg.outOfData or 'bill'
    if m ~= 'throttle' and m ~= 'block' then m = 'bill' end
    return m
end
core.dataMode = dataMode

-- ---------------------------------------------------------------------------------------------
-- The service gate: what sd-phone asks on every call and text. A table lookup, never a query.
-- ---------------------------------------------------------------------------------------------

local known = {}          -- [key] = gate (see buildGate)
local gateLoaded = false  -- false until the accounts have been read after a start, so a restart never blocks anyone
core.known = known

local function buildGate(row)
    local plan = planFor(row.plan_id)
    local kind = kindOf(plan)
    local g = { chosen = truthy(row.plan_chosen), status = row.status or 'current', kind = kind, paused = row.paused_at ~= nil }
    if kind == 'bundle' then g.endsAt = row.due_at end
    if g.chosen and isPrepaidKind(kind) then
        if kind == 'payg' then
            g.dry = (row.credit or 0) <= 0
        else
            g.dry = (row.credit or 0) <= 0 and remainingOf(plan, row, 'minutes') <= 0
                and remainingOf(plan, row, 'texts') <= 0 and remainingOf(plan, row, 'data') <= 0
        end
    end
    return g
end

local function setKnown(key, row)
    local g = buildGate(row)
    known[key] = g
    return g
end

--- 'suspended' | 'paused' | 'expired' | 'no_credit' | 'no_plan' | 'limited' (data only) | nil (service allowed).
--- `capability` is sd-phone's ('call', 'text', 'data', ...). Only 'data' is cut by the limited step.
local function blockReason(key, capability)
    if type(key) ~= 'string' or key == '' then return nil end
    local g = known[key]
    if g then
        if g.status == 'suspended' then return 'suspended' end
        if g.paused then return 'paused' end
        if g.chosen then
            if g.status == 'expired' or (g.endsAt and os.time() >= g.endsAt) then return 'expired' end
            if g.dry then return 'no_credit' end
            if capability == 'data' and g.status == 'limited' then return 'limited' end
            return nil
        end
    end
    if requirePlan() and gateLoaded and not (g and g.chosen) then return 'no_plan' end
    return nil
end
core.blockReason = blockReason
function core.isSuspended(key) local g = known[key]; return g ~= nil and g.status == 'suspended' end
function core.gateLoaded() return gateLoaded end

--- Reads every account once after a start. Returns the number loaded.
function core.loadGate()
    local n = 0
    for _, r in ipairs(store.listGate()) do
        r.credit = tonumber(r.credit) or 0
        r.minutes_used = tonumber(r.minutes_used) or 0
        r.texts_used = tonumber(r.texts_used) or 0
        r.data_mb_used = tonumber(r.data_mb_used) or 0
        r.extra_data_mb = tonumber(r.extra_data_mb) or 0
        r.due_at = tonumber(r.due_at) or 0
        r.paused_at = tonumber(r.paused_at)
        setKnown(r.citizenid, r)
        n = n + 1
    end
    gateLoaded = true
    return n
end

-- ---------------------------------------------------------------------------------------------
-- Account cache. Rows live in memory while they are in use; usage counters are written to the database
-- in batches (flushKey / flushAll), everything else is written straight away.
-- ---------------------------------------------------------------------------------------------

local cache, touched, dirty, dailyBuf, loading, locks = {}, {}, {}, {}, {}, {}
local EVICT_AFTER = 600

local NUMBERS = { 'cycle_start', 'due_at', 'minutes_used', 'texts_used', 'data_mb_used', 'balance_due', 'credit',
    'extra_data_mb', 'promo_cycles_left', 'alert_bits' }
local NULLABLE_NUMBERS = { 'balance_since', 'contract_ends', 'paused_at', 'paused_until' }

local function normalize(row)
    for _, f in ipairs(NUMBERS) do row[f] = tonumber(row[f]) or 0 end
    for _, f in ipairs(NULLABLE_NUMBERS) do row[f] = tonumber(row[f]) end
    row.alert_bits = math.tointeger(math.floor(row.alert_bits)) or 0
    row.promos_used = row.promos_used or ''
    row.status = row.status or 'current'
    return row
end

--- The account row for a key (loaded once, then kept in memory), or nil when there is none.
function core.getRow(key)
    if type(key) ~= 'string' or key == '' then return nil end
    local hit = cache[key]
    if hit then touched[key] = os.time() return hit end
    while loading[key] do Wait(0) end
    hit = cache[key]
    if hit then touched[key] = os.time() return hit end
    loading[key] = true
    local ok, row = pcall(store.getAccount, key)
    loading[key] = nil
    if not ok then error(row, 0) end
    if not row then return nil end
    cache[key] = normalize(row)
    touched[key] = os.time()
    return cache[key]
end

--- Changes fields on the cached row and writes them to the database. store.NULL clears a field.
function core.save(key, fields)
    local row = core.getRow(key)
    if row then
        for k, v in pairs(fields) do
            if v == NULL then row[k] = nil
            elseif v == true then row[k] = 1
            elseif v == false then row[k] = 0
            else row[k] = v end
        end
    end
    store.save(key, fields)
end

local function markDirty(key, col)
    local d = dirty[key]
    if not d then d = {} dirty[key] = d end
    d[col] = true
end

function core.flushKey(key)
    local d, row = dirty[key], cache[key]
    if d and row then
        dirty[key] = nil
        local f = {}
        for col in pairs(d) do f[col] = row[col] end
        local ok, err = pcall(store.save, key, f)
        if not ok then
            -- keep it for the next flush instead of losing it
            local again = dirty[key] or {}
            for col in pairs(d) do again[col] = true end
            dirty[key] = again
            error(err, 0)
        end
    end
    local buf = dailyBuf[key]
    if buf then
        dailyBuf[key] = nil
        for day, e in pairs(buf) do
            local ok, err = pcall(store.addDaily, key, day, e.m, e.t, e.d)
            if not ok then
                local back = dailyBuf[key] or {}
                local cur = back[day] or { m = 0, t = 0, d = 0 }
                cur.m, cur.t, cur.d = cur.m + e.m, cur.t + e.t, cur.d + e.d
                back[day] = cur
                dailyBuf[key] = back
                error(err, 0)
            end
        end
    end
end

--- Writes everything waiting, then forgets accounts nobody has touched for a while.
function core.flushAll()
    local keys = {}
    for k in pairs(dirty) do keys[#keys + 1] = k end
    for k in pairs(dailyBuf) do if not dirty[k] then keys[#keys + 1] = k end end
    for _, k in ipairs(keys) do
        local ok, err = pcall(core.flushKey, k)
        if not ok then print(('[as-carrier] could not save usage for %s: %s'):format(k, tostring(err))) end
    end
    local now = os.time()
    for k, t in pairs(touched) do
        if now - t > EVICT_AFTER and not dirty[k] and not dailyBuf[k] and not locks[k] and not loading[k] then
            cache[k], touched[k] = nil, nil
        end
    end
end

--- Runs fn(key) with the account locked, so two requests for the same account never overlap (a double click on
--- Pay now can't charge twice). Returns whatever fn returns, or nil, 'busy'.
function core.withLock(key, fn)
    local waited = 0
    while locks[key] do
        Wait(10)
        waited = waited + 1
        if waited > 600 then return nil, T('err.busy') end
    end
    locks[key] = true
    local res = table.pack(pcall(fn, key))
    locks[key] = nil
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

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
core.useSim = useSim

local simCache = {}   -- [number] = { id = identity, at = time }
local SIM_TTL = 30

function core.simIdentity(number)
    local hit = simCache[number]
    local now = os.time()
    if hit and now - hit.at < SIM_TTL then return hit.id end
    local ok, id = pcall(store.simIdentity, number)
    if not ok or not id then return nil end
    simCache[number] = { id = id, at = now }
    return id
end

--- The account key for a player: the identity of the SIM in their active phone, or their citizenid.
function core.resolveKey(source)
    if useSim() then
        local ok, number = pcall(function() return exports['sd-phone']:getSimNumber(source) end)
        if not ok or not number then return nil, T('err.noSim') end
        local id = core.simIdentity(tostring(number))
        if not id then return nil, T('err.simNotFound') end
        return id
    end
    local cid = Bridge.getIdentifier(source)
    if not cid then return nil, T('err.playerNotFound') end
    return cid
end

-- Who to tell: the player we last saw using this account, else whoever pays for it, if they are online.
local sourceByKey = {}

function core.touchSource(key, source)
    if key and source then sourceByKey[key] = source end
end

function core.forgetSource(source)
    local keys = {}
    for k, s in pairs(sourceByKey) do if s == source then keys[#keys + 1] = k end end
    for _, k in ipairs(keys) do sourceByKey[k] = nil end
    return keys
end

local function payerSource(row)
    return row and row.payer_id and Bridge.getSourceByIdentifier(row.payer_id) or nil
end

local function sourceFor(key)
    local s = sourceByKey[key]
    if s and GetPlayerName(s) then return s end
    local row = cache[key]
    return payerSource(row)
end
core.sourceFor = sourceFor

local function notifyKey(key, title, body)
    local src = sourceFor(key)
    if not src then return end
    TriggerClientEvent('sd-phone:client:notify', src, {
        app = 'carrier', appId = Config.app.identifier, title = title, body = body, time = 'now',
    })
end
core.notifyKey = notifyKey

local function pushUpdate(key)
    local src = sourceFor(key)
    if src then TriggerClientEvent('sd_carrier:client:updated', src, {}) end
end
core.pushUpdate = pushUpdate

--- Remembers which character pays for an account (used to charge them while they are offline).
function core.notePayer(key, row, source)
    local cid = source and Bridge.getIdentifier(source)
    if cid and row.payer_id ~= cid then core.save(key, { payer_id = cid }) end
end

-- ---------------------------------------------------------------------------------------------
-- Alerts
-- ---------------------------------------------------------------------------------------------

-- alert_bits: 0/1 minutes 1st/2nd threshold, 2/3 texts, 4/5 data, 6 low credit, 7 suspension reminder, 8 out of credit,
-- 9 told the bundle has ended
local BIT = { minutes = { 0, 1 }, texts = { 2, 3 }, data = { 4, 5 } }
local USAGE_MASK = 0x3F
local BIT_LOW_CREDIT, BIT_REMINDER, BIT_NO_CREDIT, BIT_BUNDLE_ENDED = 6, 7, 8, 9

local function hasBit(bits, n) return (bits >> n) & 1 == 1 end
local function setBit(bits, n) return bits | (1 << n) end
local function clearBit(bits, n) return bits & ~(1 << n) end
local function clearMask(bits, mask) return bits & ~mask end

local WHAT_LABEL = { minutes = 'notify.whatMinutes', texts = 'notify.whatTexts', data = 'notify.whatData' }

local function alertsCfg() return billingCfg.alerts or {} end

local function checkAlerts(key, row, plan, kind)
    local cfg = alertsCfg()
    if cfg.enabled ~= true then return end
    local bits = row.alert_bits
    local nb = bits
    local thresholds = cfg.thresholds or { 80, 100 }

    for _, what in ipairs(WHATS) do
        local inc = includedOf(plan, row, what)
        if inc > 0 then
            local pct = (row[USED[what]] or 0) / inc * 100
            for i = 1, 2 do
                local th = tonumber(thresholds[i])
                if th and pct >= th and not hasBit(nb, BIT[what][i]) then
                    nb = setBit(nb, BIT[what][i])
                    local label = T(WHAT_LABEL[what])
                    local body
                    if pct >= 100 then
                        if what == 'data' and dataMode(plan) == 'throttle' then body = T('notify.usageDataThrottle')
                        elseif what == 'data' and dataMode(plan) == 'block' then body = T('notify.usageDataBlock')
                        elseif isPrepaidKind(kind) then body = T('notify.usageOverCredit', label)
                        else body = T('notify.usageOver', label) end
                    else
                        body = T('notify.usagePct', math.floor(th), label)
                    end
                    notifyKey(key, T('notify.usageTitle'), body)
                end
            end
        end
    end

    if isPrepaidKind(kind) then
        local low = tonumber(cfg.lowCredit) or 0
        if row.credit <= 0 then
            if not hasBit(nb, BIT_NO_CREDIT) then
                nb = setBit(nb, BIT_NO_CREDIT)
                notifyKey(key, T('notify.noCreditTitle'), T('notify.noCreditBody'))
            end
        elseif low > 0 and row.credit <= low and not hasBit(nb, BIT_LOW_CREDIT) then
            nb = setBit(nb, BIT_LOW_CREDIT)
            notifyKey(key, T('notify.lowCreditTitle'), T('notify.lowCreditBody', priceText(row.credit)))
        end
    end

    if nb ~= bits then
        row.alert_bits = nb
        markDirty(key, 'alert_bits')
    end
end

-- ---------------------------------------------------------------------------------------------
-- Usage
-- ---------------------------------------------------------------------------------------------

local function addDaily(key, what, units)
    local day = math.floor(os.time() / DAY)
    local b = dailyBuf[key]
    if not b then b = {} dailyBuf[key] = b end
    local e = b[day]
    if not e then e = { m = 0, t = 0, d = 0 } b[day] = e end
    if what == 'minutes' then e.m = e.m + units
    elseif what == 'texts' then e.t = e.t + units
    else e.d = e.d + units end
end

--- Counts usage on an account: what = 'minutes' | 'texts' | 'data'. Prepaid accounts pay for what goes past
--- their allowance out of credit; data past the cap follows Config.billing.outOfData.
function core.record(key, what, units)
    units = tonumber(units) or 0
    if units <= 0 or type(key) ~= 'string' or key == '' then return end
    local g = known[key]
    if not g or not g.chosen or g.paused or g.status == 'expired' or (g.endsAt and os.time() >= g.endsAt) then return end
    local row = core.getRow(key)
    if not row then return end
    local plan = planFor(row.plan_id)
    local kind = kindOf(plan)

    if what == 'data' and kind ~= 'payg' then
        local inc = includedOf(plan, row, 'data')
        if inc >= 0 and dataMode(plan) ~= 'bill' then
            units = math.min(units, math.max(0, inc - row.data_mb_used))
            if units <= 0 then return end
        end
    end

    if isPrepaidKind(kind) then
        local free = remainingOf(plan, row, what)
        local billable = math.max(0, units - free)
        local cost = billable * rateOf(plan, what)
        if cost > 0 then
            row.credit = math.max(0, money(row.credit - cost))
            markDirty(key, 'credit')
        end
    end

    local col = USED[what]
    row[col] = (row[col] or 0) + units
    markDirty(key, col)
    addDaily(key, what, units)
    if isPrepaidKind(kind) then setKnown(key, row) end
    checkAlerts(key, row, plan, kind)
end

--- 'ok' | 'throttled' | 'blocked', plus the reason when blocked.
function core.dataState(key)
    local reason = blockReason(key, 'data')
    if reason then return 'blocked', reason end
    local g = known[key]
    if not g or not g.chosen then return 'ok' end
    local row = core.getRow(key)
    if not row then return 'ok' end
    local plan = planFor(row.plan_id)
    if kindOf(plan) == 'payg' then return 'ok' end
    local inc = includedOf(plan, row, 'data')
    if inc < 0 or row.data_mb_used < inc then return 'ok' end
    local mode = dataMode(plan)
    if mode == 'block' then return 'blocked', 'outOfData' end
    if mode == 'throttle' then return 'throttled' end
    return 'ok'
end

-- ---------------------------------------------------------------------------------------------
-- Bills
-- ---------------------------------------------------------------------------------------------

local function overage(used, included, rate)
    if included < 0 then return 0, 0 end
    local over = used - included
    if over <= 0 then return 0, 0 end
    return over * rate, over
end

--- The charge for the cycle on the books, and its line items.
function core.cycleCharge(plan, row)
    local items = {}
    local fee = tonumber(plan.price) or 0
    local total = fee
    items[#items + 1] = { k = 'plan', label = plan.label, amount = money(fee) }
    local promo = row.promo_id and PROMOS[row.promo_id]
    if promo and (row.promo_cycles_left or 0) > 0 and fee > 0 then
        local d = discountOf(promo, fee)
        if d > 0 then
            items[#items + 1] = { k = 'promo', label = promo.label, amount = -money(d) }
            total = total - d
        end
    end
    for _, what in ipairs(WHATS) do
        local c, over = overage(row[USED[what]] or 0, includedOf(plan, row, what), rateOf(plan, what))
        if c > 0 then
            items[#items + 1] = { k = what, qty = math.floor(over * 100 + 0.5) / 100, amount = money(c) }
            total = total + c
        end
    end
    return math.max(0, money(total)), items
end

local function record(key, e)
    e.at = e.at or os.time()
    return store.insertHistory(key, e)
end

--- Takes money from whoever pays this account: `source` if given, else the payer if online, else (when
--- allowed) straight from the offline payer's bank.
function core.charge(key, row, source, amount)
    amount = money(amount)
    if amount <= 0 then return true end
    local src = source or payerSource(row)
    if src then return Bridge.removeMoney(src, PAY_ACCOUNT, amount) == true end
    if paymentCfg.offlineAutoPay ~= false and row.payer_id then
        return Bridge.removeMoneyOffline(row.payer_id, PAY_ACCOUNT, amount) == true
    end
    return false
end

--- The bill is paid: clear the balance and mark the bills paid.
function core.settle(key, row, now)
    local wasSuspended = row.status == 'suspended'
    local plan = planFor(row.plan_id)
    local status = 'current'
    if truthy(row.plan_chosen) and kindOf(plan) == 'bundle' and now >= row.due_at then status = 'expired' end
    core.save(key, {
        balance_due = 0, balance_since = NULL, status = status, late_fee_applied = 0,
        alert_bits = clearBit(row.alert_bits, BIT_REMINDER),
    })
    store.markPaid(key, now)
    setKnown(key, row)
    if wasSuspended then TriggerEvent('sd_carrier:accountRestored', key) end
end

local lastAutoTry, autoFailFor = {}, {}

--- Charges an unpaid balance if the account has auto-pay on. Failed tries are repeated every
--- Config.payment.autoPayRetrySeconds (not on every sweep). Returns true if it was paid.
function core.autoPay(key, row, source, force)
    if not truthy(row.auto_pay) or (row.balance_due or 0) <= 0 then return false end
    local now = os.time()
    if not force and lastAutoTry[key] and now - lastAutoTry[key] < AUTOPAY_RETRY then return false end
    lastAutoTry[key] = now
    local amount = row.balance_due
    local plan = planFor(row.plan_id)
    if core.charge(key, row, source, amount) then
        core.settle(key, row, now)
        autoFailFor[key] = nil
        notifyKey(key, T('notify.billPaidTitle'), T('notify.autoPaid', plan.label or T('notify.phoneFallback')))
        pushUpdate(key)
        return true
    end
    local marker = row.balance_since or 0
    if autoFailFor[key] ~= marker then
        autoFailFor[key] = marker
        notifyKey(key, T('notify.autoPayFailedTitle'), T('notify.autoPayFailedBody', priceText(amount)))
    end
    return false
end

--- Skip an account in the sweep until this time (nothing to do but wait for an auto-pay retry).
local skipUntil = {}
function core.sweepSkip(key, now) return skipUntil[key] and now < skipUntil[key] end

-- ---------------------------------------------------------------------------------------------
-- Starting a plan
-- ---------------------------------------------------------------------------------------------

local function addUsed(row, id)
    local used = row.promos_used or ''
    local function add(s, tok)
        if s == '' then return tok end
        return s .. ',' .. tok
    end
    if not hasUsed(row, '*') then used = add(used, '*') end
    if id and not hasUsed(row, id) then used = add(used, id) end
    if #used > 1000 then used = used:sub(-1000) end
    return used
end

--- Puts an account on a plan. opts: { code, keepCycle, free }.
---   keepCycle  swap the plan inside the running cycle (usage and dates stay)
---   free       a bundle is not charged (staff)
--- Returns true plus { purchased, charge, needCredit } (bundles).
function core.startPlan(key, row, planId, now, opts)
    opts = opts or {}
    local plan = PLANS[planId]
    local kind = kindOf(plan)
    local f = {
        plan_id = planId, plan_chosen = 1, pending_plan = NULL, contract_ends = NULL,
        promo_id = NULL, promo_cycles_left = 0, paused_at = NULL, paused_until = NULL,
        late_fee_applied = (row.balance_due > 0) and row.late_fee_applied or 0,
    }
    if not opts.keepCycle then
        f.cycle_start = now
        f.due_at = now + CYCLE_SECONDS
        f.minutes_used, f.texts_used, f.data_mb_used = 0, 0, 0
        f.alert_bits = clearMask(row.alert_bits, USAGE_MASK)
    end

    local promo = core.bestPromo(planId, row, opts.code, now)
    f.promos_used = addUsed(row, promo and promo.id)
    if promo then
        f.promo_id = promo.id
        f.promo_cycles_left = promo.cycles
    end

    if kind == 'postpaid' and (tonumber(plan.contractCycles) or 0) > 0 then
        f.contract_ends = now + math.floor(plan.contractCycles) * CYCLE_SECONDS
    end

    local result = {}
    local keepStatus = row.balance_due > 0
    f.status = keepStatus and row.status or 'current'

    if kind == 'bundle' then
        f.cycle_start = now
        f.due_at = now + math.max(1, math.floor(tonumber(plan.durationDays) or 30)) * DAY
        f.minutes_used, f.texts_used, f.data_mb_used = 0, 0, 0
        f.alert_bits = clearMask(row.alert_bits, USAGE_MASK)
        local price = tonumber(plan.price) or 0
        local charge = price
        local items = { { k = 'plan', label = plan.label, amount = money(price) } }
        if promo then
            local d = discountOf(promo, price)
            if d > 0 then
                charge = math.max(0, price - d)
                items[#items + 1] = { k = 'promo', label = promo.label, amount = -money(d) }
            end
            f.promo_id, f.promo_cycles_left = NULL, 0   -- a bundle promotion is for one purchase
        end
        if opts.free then charge = 0 end
        charge = money(charge)
        result.charge = charge
        if row.credit >= charge then
            f.credit = money(row.credit - charge)
            f.alert_bits = clearBit(clearBit(clearBit(f.alert_bits or row.alert_bits, BIT_LOW_CREDIT), BIT_NO_CREDIT), BIT_BUNDLE_ENDED)
            result.purchased = true
            record(key, { kind = 'bundle', planId = planId, amount = charge, cycleStart = now, label = plan.label,
                items = items, paid = true, paidAt = now, at = now })
        else
            -- not paid for: the bundle is over before it began
            f.due_at = now
            f.status = keepStatus and row.status or 'expired'
            f.alert_bits = setBit(f.alert_bits or row.alert_bits, BIT_BUNDLE_ENDED)
            result.needCredit = money(charge - row.credit)
        end
    end

    core.save(key, f)
    setKnown(key, row)
    return true, result
end

-- ---------------------------------------------------------------------------------------------
-- Escalation of an unpaid bill, and the cycle rollover
-- ---------------------------------------------------------------------------------------------

local function setStatus(key, row, status)
    if row.status == status then return end
    local wasSuspended = row.status == 'suspended'
    core.save(key, { status = status })
    setKnown(key, row)
    if status == 'suspended' and not wasSuspended then
        TriggerEvent('sd_carrier:accountSuspended', key)
    elseif wasSuspended and status ~= 'suspended' then
        TriggerEvent('sd_carrier:accountRestored', key)
    end
end

local function escalate(key, row, now)
    local since = row.balance_since
    if (row.balance_due or 0) <= 0 or not since then return end
    local age = now - since
    local plan = planFor(row.plan_id)

    -- a one-off late fee
    local lf = billingCfg.lateFee or {}
    if lf.enabled == true and not truthy(row.late_fee_applied) and age >= (tonumber(lf.afterDays) or 1) * DAY then
        local fee = money((tonumber(lf.amount) or 0) + row.balance_due * (tonumber(lf.percent) or 0) / 100)
        if fee > 0 then
            record(key, { kind = 'fee', planId = row.plan_id, amount = fee, cycleStart = now, label = T('ui.lateFee'),
                items = { { k = 'fee', label = T('ui.lateFee'), amount = fee } }, paid = false, at = now })
            core.save(key, { balance_due = money(row.balance_due + fee), late_fee_applied = 1 })
            notifyKey(key, T('notify.lateFeeTitle'), T('notify.lateFeeBody', priceText(fee), priceText(row.balance_due)))
        else
            core.save(key, { late_fee_applied = 1 })
        end
    end

    local stage = 'due'
    if LIMITED_SECONDS > 0 and LIMITED_SECONDS < GRACE_SECONDS and age >= LIMITED_SECONDS then stage = 'limited' end
    if age >= GRACE_SECONDS then stage = 'suspended' end

    if stage ~= row.status then
        setStatus(key, row, stage)
        if stage == 'limited' then
            notifyKey(key, T('notify.limitedTitle'), T('notify.limitedBody'))
        elseif stage == 'suspended' then
            notifyKey(key, T('notify.suspendedTitle'), T('notify.suspendedBody'))
        end
    end

    if stage ~= 'suspended' and REMIND_SECONDS > 0 and GRACE_SECONDS - age <= REMIND_SECONDS
        and not hasBit(row.alert_bits, BIT_REMINDER) then
        core.save(key, { alert_bits = setBit(row.alert_bits, BIT_REMINDER) })
        notifyKey(key, T('notify.reminderTitle'), T('notify.reminderBody', priceText(row.balance_due)))
    end
    setKnown(key, row)
end

--- Ends the cycle: raises the bill (postpaid), resets usage and applies a queued plan switch or cancellation.
function core.rollCycle(key, row, source, now)
    local plan = planFor(row.plan_id)
    local kind = kindOf(plan)
    local queued = row.pending_plan
    local isCancel = queued == '__cancel'
    if not isCancel and queued and not PLANS[queued] then queued = nil end

    local f = {
        cycle_start = now, due_at = now + CYCLE_SECONDS, minutes_used = 0, texts_used = 0, data_mb_used = 0,
        pending_plan = NULL, alert_bits = clearMask(row.alert_bits, USAGE_MASK),
    }
    -- add-on MB: gone at the end of the cycle unless carry-over is on
    local keep = 0
    if (billingCfg.addons or {}).carryOver == true and row.extra_data_mb > 0 then
        keep = math.min(row.extra_data_mb, math.max(0, includedOf(plan, row, 'data') - row.data_mb_used))
    end
    f.extra_data_mb = keep

    local charge, newBalance = 0, row.balance_due
    if kind == 'postpaid' then
        local prev = row.balance_due
        local items
        charge, items = core.cycleCharge(plan, row)
        record(key, { kind = 'bill', planId = row.plan_id, amount = charge, cycleStart = row.cycle_start,
            label = plan.label, items = items, paid = charge <= 0, paidAt = now, at = now })
        newBalance = money(prev + charge)
        f.balance_due = newBalance
        if newBalance > 0 then f.balance_since = (prev > 0 and row.balance_since) or now else f.balance_since = NULL end
        f.late_fee_applied = (prev > 0) and row.late_fee_applied or 0
        if newBalance > 0 then
            f.status = (row.status == 'suspended' or row.status == 'limited') and row.status or 'due'
        else
            f.status = 'current'
        end
        if row.promo_id and row.promo_cycles_left > 0 then
            f.promo_cycles_left = row.promo_cycles_left - 1
            if f.promo_cycles_left <= 0 then f.promo_id = NULL end
        end
        if row.contract_ends and now >= row.contract_ends then f.contract_ends = NULL end
    end

    local planLabel = plan.label or T('notify.phoneFallback')
    core.save(key, f)
    setKnown(key, row)

    local switched
    if isCancel then
        core.save(key, { plan_chosen = 0, pending_plan = NULL, contract_ends = NULL, promo_id = NULL, promo_cycles_left = 0 })
        setKnown(key, row)
        notifyKey(key, T('notify.cancelledTitle'), T('notify.cancelledBody'))
    elseif queued then
        local _, started = core.startPlan(key, row, queued, now, {})
        if started and started.needCredit then
            notifyKey(key, T('notify.bundleUnpaidTitle'), T('notify.bundleUnpaidBody', (PLANS[queued].label or queued), priceText(started.needCredit)))
        else
            switched = queued
        end
    end

    if kind == 'postpaid' and charge > 0 and row.balance_due > 0 then
        if not core.autoPay(key, row, source, true) then
            notifyKey(key, T('notify.billTitle'), T('notify.billDue', planLabel, priceText(row.balance_due)))
        end
    end
    if switched then
        local np = PLANS[switched]
        notifyKey(key, T('notify.planChangedTitle'), T('notify.planChangedBody', np.label or switched))
    end
    pushUpdate(key)
end

--- A bundle ran out of time: renew it from credit if auto-renew is on, else service stops.
function core.bundleEnded(key, row, source, now)
    local plan = planFor(row.plan_id)
    local price = tonumber(plan.price) or 0
    if truthy(row.auto_pay) and row.credit >= price then
        local _, started = core.startPlan(key, row, row.plan_id, now, {})
        if started and started.purchased then
            notifyKey(key, T('notify.bundleRenewedTitle'), T('notify.bundleRenewedBody', plan.label or ''))
            pushUpdate(key)
            return
        end
    end
    core.save(key, { status = (row.balance_due > 0) and row.status or 'expired', alert_bits = setBit(row.alert_bits, BIT_BUNDLE_ENDED) })
    setKnown(key, row)
    notifyKey(key, T('notify.bundleEndedTitle'), T('notify.bundleEndedBody', plan.label or ''))
    pushUpdate(key)
end

function core.resume(key, row, now, auto)
    local shift = math.max(0, now - (row.paused_at or now))
    core.save(key, {
        paused_at = NULL, paused_until = NULL, due_at = row.due_at + shift, cycle_start = row.cycle_start + shift,
        contract_ends = row.contract_ends and (row.contract_ends + shift) or NULL,
    })
    setKnown(key, row)
    if auto then notifyKey(key, T('notify.resumedTitle'), T('notify.resumedBody')) end
    pushUpdate(key)
end

--- Everything an account may need doing right now. Call with the account locked.
function core.process(key, row, source)
    local now = os.time()
    if row.paused_at then
        if row.paused_until and now >= row.paused_until then
            core.resume(key, row, now, true)
        else
            return
        end
    end
    local plan = planFor(row.plan_id)
    local kind = kindOf(plan)
    local chosen = truthy(row.plan_chosen)

    if chosen and kind == 'bundle' and now >= row.due_at and not hasBit(row.alert_bits, BIT_BUNDLE_ENDED) then
        core.bundleEnded(key, row, source, now)
    end
    escalate(key, row, now)
    if chosen and kind ~= 'bundle' and now >= row.due_at then
        core.rollCycle(key, row, source, now)
    end
    core.autoPay(key, row, source, false)

    -- an unpaid, suspended account only needs the sweep again when auto-pay could retry
    if row.balance_due > 0 and row.status == 'suspended' then
        skipUntil[key] = now + AUTOPAY_RETRY
    else
        skipUntil[key] = nil
    end
end

--- Creates the account row on first sight (no plan chosen).
function core.ensureAccount(key)
    local row = core.getRow(key)
    if not row then
        local now = os.time()
        store.insertAccount(key, PLACEHOLDER_PLAN, now, now + CYCLE_SECONDS)
        row = core.getRow(key)
        if not row then
            row = normalize({
                citizenid = key, plan_id = PLACEHOLDER_PLAN, cycle_start = now, due_at = now + CYCLE_SECONDS,
                auto_pay = 0, status = 'current', plan_chosen = 0,
            })
            cache[key] = row
            touched[key] = now
        end
    end
    setKnown(key, row)
    return row
end

-- ---------------------------------------------------------------------------------------------
-- Actions (all return true | nil, message, extra)
-- ---------------------------------------------------------------------------------------------

--- What leaving the contract now would cost (0 = no contract running).
function core.exitFee(row, now)
    now = now or os.time()
    local plan = planFor(row.plan_id)
    if kindOf(plan) ~= 'postpaid' or not truthy(row.plan_chosen) or not row.contract_ends or now >= row.contract_ends then
        return 0
    end
    local cfg = Config.contract or {}
    local remaining = math.ceil((row.contract_ends - now) / CYCLE_SECONDS)
    local fee = (tonumber(plan.price) or 0) * remaining * (tonumber(cfg.feeRate) or 0.5)
    fee = math.max(fee, tonumber(cfg.minFee) or 0)
    local cap = tonumber(cfg.maxFee) or 0
    if cap > 0 then fee = math.min(fee, cap) end
    return money(fee)
end

local function recordFee(key, row, amount, label, now)
    record(key, { kind = 'fee', planId = row.plan_id, amount = amount, cycleStart = now, label = label,
        items = { { k = 'fee', label = label, amount = amount } }, paid = true, paidAt = now, at = now })
end

--- Ends the cycle right now, then applies `target` ('__cancel' or a plan id). Used for an early exit.
local function closeCycleNow(key, row, source, now, target)
    core.save(key, { pending_plan = target, due_at = now })
    core.rollCycle(key, row, source, now)
end

--- Choose or change plan. opts: { code, payExit }.
function core.selectPlan(key, row, source, planId, opts)
    opts = opts or {}
    local plan = PLANS[planId]
    if not plan then return nil, T('err.unknownPlan') end
    local now = os.time()
    local kind = kindOf(plan)

    local function bundleCreditCheck()
        if kind ~= 'bundle' then return true end
        local promo = core.bestPromo(planId, row, opts.code, now)
        local price = tonumber(plan.price) or 0
        local charge = promo and math.max(0, price - discountOf(promo, price)) or price
        if row.credit < charge then
            return nil, T('err.needCredit', priceText(money(charge - row.credit))), { needCredit = money(charge - row.credit) }
        end
        return true
    end

    if opts.code and opts.code:match('%S') then
        local promo, bad = core.bestPromo(planId, row, opts.code, now)
        if bad then return nil, T('err.badPromo') end
        if not promo then return nil, T('err.badPromo') end
    end

    -- first plan on this account
    if not truthy(row.plan_chosen) then
        local ok, msg, extra = bundleCreditCheck()
        if not ok then return nil, msg, extra end
        core.startPlan(key, row, planId, now, { code = opts.code })
        pushUpdate(key)
        return true
    end

    local cur = planFor(row.plan_id)
    local curKind = kindOf(cur)

    if planId == row.plan_id then
        if curKind == 'bundle' then
            local ended = row.status == 'expired' or now >= row.due_at
            if not ended and not (known[key] and known[key].dry) then return nil, T('err.bundleActive') end
            local ok, msg, extra = bundleCreditCheck()
            if not ok then return nil, msg, extra end
            core.startPlan(key, row, planId, now, { code = opts.code })
            return true
        end
        -- choosing the plan you are on drops any queued switch
        if row.pending_plan then core.save(key, { pending_plan = NULL }) end
        return true
    end

    -- leaving a prepaid plan: nothing is owed, it just switches (an unused bundle is forfeited)
    if isPrepaidKind(curKind) then
        local ok, msg, extra = bundleCreditCheck()
        if not ok then return nil, msg, extra end
        core.startPlan(key, row, planId, now, { code = opts.code })
        pushUpdate(key)
        return true
    end

    -- leaving a postpaid plan
    local fee = core.exitFee(row, now)
    local upgrade = (Config.contract or {}).upgradesFree ~= false and kind == 'postpaid'
        and (tonumber(plan.price) or 0) > (tonumber(cur.price) or 0)
    local immediate = false
    if fee > 0 and not upgrade then
        if not opts.payExit then
            return nil, T('err.exitFeeRequired', priceText(fee)), { needsExit = true, fee = fee }
        end
        local ok, msg, extra = bundleCreditCheck()
        if not ok then return nil, msg, extra end
        if not core.charge(key, row, source, fee) then return nil, T('err.insufficientFunds') end
        recordFee(key, row, fee, T('ui.exitFee'), now)
        immediate = true
    end

    if immediate then
        closeCycleNow(key, row, source, now, planId)
        return true
    end
    if not planLock() then
        local ok, msg, extra = bundleCreditCheck()
        if not ok then return nil, msg, extra end
        core.startPlan(key, row, planId, now, { code = opts.code, keepCycle = kind ~= 'bundle' })
        return true
    end
    core.save(key, { pending_plan = planId })
    return true
end

function core.cancelPending(key, row)
    core.save(key, { pending_plan = NULL })
    return true
end

--- Stop service on this account (it goes back to "no plan"). Postpaid: at the end of the cycle, or now for an
--- early exit fee.
function core.cancelService(key, row, source, opts)
    opts = opts or {}
    if not truthy(row.plan_chosen) then return nil, T('err.noPlan') end
    local now = os.time()
    local kind = kindOf(planFor(row.plan_id))
    if isPrepaidKind(kind) then
        core.save(key, { plan_chosen = 0, pending_plan = NULL, auto_pay = 0 })
        setKnown(key, row)
        pushUpdate(key)
        return true
    end
    local fee = core.exitFee(row, now)
    if fee > 0 then
        if not opts.payExit then
            return nil, T('err.exitFeeRequired', priceText(fee)), { needsExit = true, fee = fee }
        end
        if not core.charge(key, row, source, fee) then return nil, T('err.insufficientFunds') end
        recordFee(key, row, fee, T('ui.exitFee'), now)
        closeCycleNow(key, row, source, now, '__cancel')
        return true
    end
    if planLock() then
        core.save(key, { pending_plan = '__cancel' })
    else
        closeCycleNow(key, row, source, now, '__cancel')
    end
    return true
end

function core.pause(key, row, source, days)
    local cfg = Config.pause or {}
    if cfg.enabled ~= true then return nil, T('err.pauseOff') end
    local now = os.time()
    if not truthy(row.plan_chosen) or kindOf(planFor(row.plan_id)) ~= 'postpaid' then return nil, T('err.pauseNotPostpaid') end
    if row.paused_at then return nil, T('err.alreadyPaused') end
    if row.balance_due > 0 or row.status ~= 'current' then return nil, T('err.pauseOwing') end
    if row.contract_ends and now < row.contract_ends and cfg.allowedInContract ~= true then
        return nil, T('err.pauseContract')
    end
    local maxDays = math.max(1, math.floor(tonumber(cfg.maxDays) or 28))
    days = math.min(maxDays, math.max(1, math.floor(tonumber(days) or maxDays)))
    local fee = money(cfg.fee)
    if fee > 0 then
        if not core.charge(key, row, source, fee) then return nil, T('err.insufficientFunds') end
        recordFee(key, row, fee, T('ui.pauseFee'), now)
    end
    core.save(key, { paused_at = now, paused_until = now + days * DAY })
    setKnown(key, row)
    pushUpdate(key)
    return true
end

function core.resumeNow(key, row)
    if not row.paused_at then return nil, T('err.notPaused') end
    core.resume(key, row, os.time(), false)
    return true
end

function core.topUp(key, row, source, amount)
    local cfg = (Config.prepaid or {}).topUp or {}
    amount = money(amount)
    local min, max = tonumber(cfg.min) or 1, tonumber(cfg.max) or 1000
    if amount <= 0 or amount < min or amount > max then
        return nil, T('err.topUpRange', priceText(min), priceText(max))
    end
    if truthy(row.plan_chosen) and not isPrepaidKind(kindOf(planFor(row.plan_id))) then
        return nil, T('err.topUpNotPrepaid')
    end
    if not core.charge(key, row, source, amount) then return nil, T('err.insufficientFunds') end
    local now = os.time()
    core.save(key, {
        credit = money(row.credit + amount),
        alert_bits = clearBit(clearBit(row.alert_bits, BIT_LOW_CREDIT), BIT_NO_CREDIT),
    })
    record(key, { kind = 'topup', planId = row.plan_id, amount = amount, cycleStart = now, label = T('ui.topUpLabel'),
        items = { { k = 'topup', label = T('ui.topUpLabel'), amount = amount } }, paid = true, paidAt = now, at = now })
    setKnown(key, row)
    pushUpdate(key)
    return true
end

local function addonById(id)
    for _, a in ipairs((billingCfg.addons or {}).list or {}) do
        if a.id == id then return a end
    end
    return nil
end

function core.buyAddon(key, row, source, id)
    local addon = addonById(id)
    if not addon then return nil, T('err.unknownAddon') end
    if not truthy(row.plan_chosen) then return nil, T('err.noPlan') end
    if row.status == 'suspended' then return nil, T('err.suspended') end
    if row.paused_at then return nil, T('err.paused') end
    local plan = planFor(row.plan_id)
    local kind = kindOf(plan)
    if kind ~= 'payg' and (tonumber(plan.dataMB) or -1) < 0 then return nil, T('err.addonNotNeeded') end
    if kind == 'bundle' and row.status == 'expired' then return nil, T('err.expired') end
    local cap = tonumber((billingCfg.addons or {}).maxExtraMB) or 0
    local mb = tonumber(addon.dataMB) or 0
    if cap > 0 and row.extra_data_mb + mb > cap then return nil, T('err.addonCap') end
    local price = money(addon.price)

    local now = os.time()
    local fields = { extra_data_mb = row.extra_data_mb + mb }
    if isPrepaidKind(kind) then
        if row.credit < price then
            return nil, T('err.needCredit', priceText(money(price - row.credit))), { needCredit = money(price - row.credit) }
        end
        fields.credit = money(row.credit - price)
    else
        if not core.charge(key, row, source, price) then return nil, T('err.insufficientFunds') end
    end
    -- the data alerts start over with the bigger allowance
    fields.alert_bits = clearMask(row.alert_bits, (1 << BIT.data[1]) | (1 << BIT.data[2]))
    core.save(key, fields)
    record(key, { kind = 'addon', planId = row.plan_id, amount = price, cycleStart = now, label = addon.label,
        items = { { k = 'addon', label = addon.label, amount = price } }, paid = true, paidAt = now, at = now })
    setKnown(key, row)
    pushUpdate(key)
    return true
end

function core.payBill(key, row, source)
    local due = row.balance_due
    if due <= 0 then return nil, T('err.nothingDue') end
    if not core.charge(key, row, source, due) then return nil, T('err.insufficientFunds') end
    core.settle(key, row, os.time())
    lastAutoTry[key], autoFailFor[key] = nil, nil
    return true
end

function core.setAutoPay(key, row, on)
    core.save(key, { auto_pay = on and 1 or 0 })
    if on then lastAutoTry[key] = nil end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- What the app sees
-- ---------------------------------------------------------------------------------------------

local function serializePlan(plan)
    return {
        id = plan.id, label = plan.label, price = plan.price, type = kindOf(plan),
        minutes = plan.minutes, texts = plan.texts, dataMB = plan.dataMB,
        overagePerMinute = plan.overagePerMinute, overagePerText = plan.overagePerText, overagePerMB = plan.overagePerMB,
        popular = plan.popular == true, durationDays = plan.durationDays,
        contractCycles = tonumber(plan.contractCycles) or 0, outOfData = dataMode(plan),
    }
end
core.serializePlan = serializePlan

local function dailyFor(key, days)
    core.flushKey(key)
    local today = math.floor(os.time() / DAY)
    local rows = {}
    for i, r in ipairs(store.listDaily(key, today - days + 1)) do
        rows[i] = { day = tonumber(r.day), m = tonumber(r.minutes) or 0, t = tonumber(r.texts) or 0, d = tonumber(r.data_mb) or 0 }
    end
    return rows
end

function core.statusFor(key, row)
    local now = os.time()
    local chosen = truthy(row.plan_chosen)
    local plan = planFor(row.plan_id)
    local kind = kindOf(plan)
    local prepaid = chosen and isPrepaidKind(kind)

    local history = {}
    for i, h in ipairs(store.listHistory(key, 30)) do
        history[i] = {
            id = h.id, kind = h.kind or 'bill', planId = h.plan_id, label = h.label, amount = tonumber(h.amount) or 0,
            paid = truthy(h.paid), paidAt = h.paid_at, cycleStart = tonumber(h.cycle_start), at = h.at, items = h.items,
        }
    end

    local plans = {}
    for _, p in ipairs(PLAN_LIST) do
        if not p.hidden or (chosen and p.id == row.plan_id) then plans[#plans + 1] = serializePlan(p) end
    end

    local pending = chosen and row.pending_plan and row.pending_plan ~= '__cancel' and PLANS[row.pending_plan] or nil

    local addons = {}
    for _, a in ipairs((billingCfg.addons or {}).list or {}) do
        addons[#addons + 1] = { id = a.id, label = a.label, dataMB = a.dataMB, price = a.price }
    end

    local promo = row.promo_id and PROMOS[row.promo_id]
    local estimate, estimateItems = 0, nil
    if chosen and kind == 'postpaid' then estimate, estimateItems = core.cycleCharge(plan, row) end

    local dataState, dataReason = 'ok', nil
    if chosen then dataState, dataReason = core.dataState(key) end

    local contractLeft
    if chosen and row.contract_ends and now < row.contract_ends then
        contractLeft = math.ceil((row.contract_ends - now) / CYCLE_SECONDS)
    end

    local lf = billingCfg.lateFee or {}
    local topUp = (Config.prepaid or {}).topUp or {}
    local pauseCfg = Config.pause or {}
    local days = math.max(1, math.floor(tonumber(Config.usageDays) or 14))

    return {
        chosen = chosen,
        kind = chosen and kind or nil,
        plan = chosen and serializePlan(plan) or nil,
        plans = plans,
        pendingPlan = pending and serializePlan(pending) or nil,
        pendingCancel = chosen and row.pending_plan == '__cancel' or false,
        planLock = planLock() and not prepaid,
        lockedUntil = (chosen and planLock() and kind == 'postpaid') and row.due_at or nil,
        requirePlan = requirePlan(),
        blocked = blockReason(key),
        dataState = dataState, dataReason = dataReason,
        status = row.status,
        autoPay = truthy(row.auto_pay),
        cycleStart = row.cycle_start, dueAt = row.due_at,
        cycleDays = math.floor(CYCLE_SECONDS / DAY),
        minutesUsed = row.minutes_used, textsUsed = row.texts_used, dataMBUsed = row.data_mb_used,
        extraDataMB = row.extra_data_mb,
        estimatedThisCycle = estimate, estimateItems = estimateItems,
        balanceDue = row.balance_due,
        payBy = (row.balance_due > 0 and row.balance_since) and (row.balance_since + GRACE_SECONDS) or nil,
        limitedAt = (row.balance_due > 0 and row.balance_since and LIMITED_SECONDS > 0) and (row.balance_since + LIMITED_SECONDS) or nil,
        lateFee = { enabled = lf.enabled == true, amount = tonumber(lf.amount) or 0, percent = tonumber(lf.percent) or 0,
            afterDays = tonumber(lf.afterDays) or 1, applied = truthy(row.late_fee_applied) },
        credit = row.credit,
        topUp = { min = tonumber(topUp.min) or 1, max = tonumber(topUp.max) or 1000, presets = topUp.presets or {},
            available = not chosen or prepaid },
        addons = addons,
        contract = chosen and kind == 'postpaid' and {
            cycles = tonumber(plan.contractCycles) or 0, endsAt = row.contract_ends, cyclesLeft = contractLeft,
            exitFee = core.exitFee(row, now), upgradesFree = (Config.contract or {}).upgradesFree ~= false,
        } or nil,
        promo = promo and (row.promo_cycles_left or 0) > 0 and { label = promo.label, cyclesLeft = row.promo_cycles_left } or nil,
        offers = core.offersFor(row, now),
        paused = row.paused_at and { since = row.paused_at, untilAt = row.paused_until } or nil,
        pauseCfg = { enabled = pauseCfg.enabled == true, maxDays = tonumber(pauseCfg.maxDays) or 28,
            fee = tonumber(pauseCfg.fee) or 0, allowedInContract = pauseCfg.allowedInContract == true },
        daily = dailyFor(key, days), usageDays = days,
        history = history,
        now = now,
    }
end

-- Exposed for tests and the admin commands
core._ = {
    hasBit = hasBit, setBit = setBit, clearBit = clearBit, clearMask = clearMask, USAGE_MASK = USAGE_MASK,
    includedOf = includedOf, remainingOf = remainingOf, discountOf = discountOf, buildGate = buildGate,
    cache = cache, dirty = dirty, setKnown = setKnown, setStatus = setStatus, escalate = escalate,
    record = record, normalize = normalize, hasUsed = hasUsed, addUsed = addUsed,
}

return core
