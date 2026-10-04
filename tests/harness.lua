-- Test harness: runs the real server scripts against an in-memory store and a fake framework.
-- Needs plain Lua 5.4+ (run: lua tests/core_test.lua from the resource folder).
local H = {}

local real_time = os.time
H.NOW = 1700000000
os.time = function(t) if t then return real_time(t) end return H.NOW end
function H.advance(seconds) H.NOW = H.NOW + seconds end

-- ---- a tiny scheduler so Wait/CreateThread behave -------------------------------------------
local threads = {}
function H.spawn(fn, ...)
    local co = coroutine.create(fn)
    threads[#threads + 1] = co
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err, 0) end
    return co
end
function H.runThreads(limit)
    for _ = 1, limit or 200 do
        local alive = false
        for _, co in ipairs(threads) do
            if coroutine.status(co) == 'suspended' then
                alive = true
                local ok, err = coroutine.resume(co)
                if not ok then error(err, 0) end
            end
        end
        if not alive then return end
    end
end
function Wait() if coroutine.isyieldable() then coroutine.yield() end end
function CreateThread(fn) H.spawn(fn) end

-- ---- json (tiny, enough for items) -------------------------------------------------------------
local function enc(v)
    local t = type(v)
    if t == 'table' then
        if #v > 0 or next(v) == nil then
            local out = {}
            for i, x in ipairs(v) do out[i] = enc(x) end
            return '[' .. table.concat(out, ',') .. ']'
        end
        local out = {}
        for k, x in pairs(v) do out[#out + 1] = ('%q:%s'):format(k, enc(x)) end
        return '{' .. table.concat(out, ',') .. '}'
    elseif t == 'string' then return ('%q'):format(v)
    else return tostring(v) end
end
json = { encode = enc, decode = function(s) return load('return ' .. s:gsub('%[', '{'):gsub('%]', '}'):gsub('"(%w+)":', '%1='))() end }

-- ---- FiveM globals ----------------------------------------------------------------------------
H.events = {}      -- TriggerClientEvent log
H.localEvents = {} -- TriggerEvent log
H.online = {}      -- [source] = true
function GetPlayerName(s) return H.online[s] and ('Player' .. s) or nil end
function GetResourceState() return 'missing' end
function GetCurrentResourceName() return 'as-carrier' end
function TriggerClientEvent(name, src, payload) H.events[#H.events + 1] = { name = name, src = src, payload = payload } end
function TriggerEvent(name, ...) H.localEvents[#H.localEvents + 1] = { name = name, args = { ... } } end
H.handlers, H.callbacks, H.exports, H.commands = {}, {}, {}, {}
function AddEventHandler(name, fn) H.handlers[name] = fn end
function RegisterNetEvent() end
--- fires a server event as if the given player's client had sent it (FiveM sets the global `source`)
function H.fire(name, src, ...)
    local old = source
    source = src
    local ok, err = pcall(H.handlers[name], ...)
    source = old
    if not ok then error(err, 0) end
end
H.http = {}
function PerformHttpRequest(url, cb, method, body, headers) H.http[#H.http + 1] = { url = url, method = method, body = body, headers = headers } if cb then cb(204) end end
function RegisterCommand() end
function exports(name, fn) H.exports[name] = fn end
lib = { callback = { register = function(name, fn) H.callbacks[name] = fn end },
        addCommand = function(name, props, fn) H.commands[name] = fn end }

-- ---- fake framework ------------------------------------------------------------------------------
H.bank = {}        -- [source] = balance (online players)
H.offlineBank = {} -- [identifier] = balance
H.charged = {}
CarrierBridge = {}
function CarrierBridge.getIdentifier(src) return H.online[src] and ('CID' .. src) or nil end
function CarrierBridge.getSourceByIdentifier(id)
    local n = tonumber((id or ''):match('^CID(%d+)$'))
    return n and H.online[n] and n or nil
end
function CarrierBridge.removeMoney(src, acct, amount)
    if (H.bank[src] or 0) < amount then return false end
    H.bank[src] = H.bank[src] - amount
    H.charged[#H.charged + 1] = { src = src, amount = amount }
    return true
end
function CarrierBridge.addMoney(src, acct, amount)
    if not H.online[src] then return false end
    H.bank[src] = (H.bank[src] or 0) + amount
    return true
end
function CarrierBridge.addMoneyOffline(id, acct, amount)
    H.offlineBank[id] = (H.offlineBank[id] or 0) + amount
    return true
end
function CarrierBridge.removeMoneyOffline(id, acct, amount)
    if (H.offlineBank[id] or 0) < amount then return false end
    H.offlineBank[id] = H.offlineBank[id] - amount
    H.charged[#H.charged + 1] = { id = id, amount = amount }
    return true
end

-- ---- fake store -----------------------------------------------------------------------------------
local NULL = {}
local S = { NULL = NULL, accounts = {}, history = {}, daily = {}, audits = {} }
H.store = S
local seq = 0
local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
function S.ensureSchema() return false end
function S.getAccount(key) return S.accounts[key] and copy(S.accounts[key]) or nil end
function S.listGate() local o = {} for _, r in pairs(S.accounts) do o[#o + 1] = copy(r) end return o end
function S.insertAccount(key, plan, cs, due)
    if S.accounts[key] then return end
    S.accounts[key] = { citizenid = key, plan_id = plan, cycle_start = cs, due_at = due, auto_pay = 0, status = 'current',
        minutes_used = 0, texts_used = 0, data_mb_used = 0, balance_due = 0, plan_chosen = 0, credit = 0, extra_data_mb = 0,
        promo_cycles_left = 0, promos_used = '', late_fee_applied = 0, alert_bits = 0,
        extra_minutes = 0, extra_texts = 0, auto_topup_amount = 0, auto_topup_below = 0 }
end
function S.save(key, fields)
    local r = S.accounts[key]
    assert(r, 'save on missing account ' .. tostring(key))
    for k, v in pairs(fields) do
        if v == NULL then r[k] = nil elseif v == true then r[k] = 1 elseif v == false then r[k] = 0 else r[k] = v end
    end
end
function S.listDue(now)
    local o = {}
    for k, r in pairs(S.accounts) do
        if (r.plan_chosen == 1 and not r.paused_at and r.status ~= 'expired' and r.due_at <= now)
            or (r.paused_at and r.paused_until and r.paused_until <= now)
            or ((r.balance_due or 0) > 0 and (r.status ~= 'suspended' or r.auto_pay == 1)) then o[#o + 1] = k end
    end
    return o
end
function S.insertHistory(key, e)
    seq = seq + 1
    local row = { id = e.id or ('h' .. seq), citizenid = key, plan_id = e.planId or '', amount = e.amount or 0,
        cycle_start = e.cycleStart, paid = e.paid and 1 or 0, paid_at = e.paid and (e.paidAt or e.at) or nil,
        kind = e.kind or 'bill', label = e.label or '', items = e.items, at = e.at or os.time(), seq = seq,
        pay = e.pay == 'credit' and 'credit' or 'bank', refunded = 0 }
    S.history[#S.history + 1] = row
    return row.id
end
function S.markPaid(key, at)
    for _, h in ipairs(S.history) do if h.citizenid == key and h.paid == 0 then h.paid, h.paid_at = 1, at end end
end
function S.listHistory(key, limit)
    local o = {}
    for _, h in ipairs(S.history) do if h.citizenid == key then o[#o + 1] = h end end
    table.sort(o, function(a, b) return a.seq > b.seq end)
    while #o > (limit or 12) do o[#o] = nil end
    return o
end
function S.getHistoryEntry(key, id)
    for _, h in ipairs(S.history) do if h.citizenid == key and h.id == id then return copy(h) end end
end
function S.markRefunded(key, id, at)
    for _, h in ipairs(S.history) do
        if h.citizenid == key and h.id == id and h.refunded ~= 1 then
            h.refunded = 1
            if h.paid == 0 then h.paid, h.paid_at = 1, at end
            return true
        end
    end
    return false
end
function S.bulkPromo(promoId, cycles, scope, postpaid, prepaid)
    local ids = {}
    if scope == 'postpaid' or scope == 'all' then for _, id in ipairs(postpaid) do ids[id] = true end end
    if scope == 'prepaid' or scope == 'all' then for _, id in ipairs(prepaid) do ids[id] = true end end
    local n = 0
    for _, r in pairs(S.accounts) do
        local used = false
        for tok in (r.promos_used or ''):gmatch('[^,]+') do if tok == promoId then used = true end end
        if r.plan_chosen == 1 and ids[r.plan_id] and not used and (not r.promo_id or r.promo_cycles_left == 0) then
            r.promo_id, r.promo_cycles_left = promoId, cycles
            r.promos_used = (r.promos_used == '' and '' or r.promos_used .. ',') .. promoId
            n = n + 1
        end
    end
    return n
end
function S.stats(now, plans)
    local out = { accounts = { postpaid = 0, payg = 0, bundle = 0, none = 0 }, byPlan = {}, overdue = 0, owed = 0, suspended = 0, paused = 0, credit = 0,
        revenue = { day = 0, week = 0, month = 0, byKind = {} }, activeWeek = 0, topData = {} }
    for _, r in pairs(S.accounts) do
        if r.plan_chosen == 1 then
            local kind = plans[r.plan_id] or 'postpaid'
            out.accounts[kind] = out.accounts[kind] + 1
            out.byPlan[r.plan_id] = (out.byPlan[r.plan_id] or 0) + 1
        else out.accounts.none = out.accounts.none + 1 end
        if r.balance_due > 0 then out.overdue = out.overdue + 1 out.owed = out.owed + r.balance_due end
        if r.status == 'suspended' then out.suspended = out.suspended + 1 end
        if r.paused_at then out.paused = out.paused + 1 end
        out.credit = out.credit + r.credit
    end
    for _, h in ipairs(S.history) do
        if h.paid == 1 and h.pay == 'bank' and h.kind ~= 'adjust' and h.paid_at and h.paid_at >= now - 30 * 86400 then
            local sign = h.kind == 'refund' and -1 or 1
            out.revenue.month = out.revenue.month + sign * h.amount
            if h.paid_at >= now - 7 * 86400 then out.revenue.week = out.revenue.week + sign * h.amount end
            if h.paid_at >= now - 86400 then out.revenue.day = out.revenue.day + sign * h.amount end
        end
    end
    local seen, per = {}, {}
    for key, days in pairs(S.daily) do
        for day, e in pairs(days) do
            if day >= math.floor(now / 86400) - 6 then seen[key] = true per[key] = (per[key] or 0) + e.data_mb end
        end
    end
    for k in pairs(seen) do out.activeWeek = out.activeWeek + 1 out.topData[#out.topData + 1] = { key = k, mb = per[k] } end
    table.sort(out.topData, function(a, b) return a.mb > b.mb end)
    while #out.topData > 5 do out.topData[#out.topData] = nil end
    return out
end
function S.addDaily(key, day, m, t, d)
    S.daily[key] = S.daily[key] or {}
    local e = S.daily[key][day] or { minutes = 0, texts = 0, data_mb = 0 }
    e.minutes, e.texts, e.data_mb = e.minutes + m, e.texts + t, e.data_mb + d
    S.daily[key][day] = e
end
function S.listDaily(key, from)
    local o = {}
    for day, e in pairs(S.daily[key] or {}) do if day >= from then o[#o + 1] = { day = day, minutes = e.minutes, texts = e.texts, data_mb = e.data_mb } end end
    table.sort(o, function(a, b) return a.day < b.day end)
    return o
end
function S.pruneDaily() end
function S.audit(actor, target, action, detail) S.audits[#S.audits + 1] = { actor = actor, target = target, action = action, detail = detail } end
function S.simIdentity() return nil end
package.preload['server.store'] = function() return S end

-- ---- load the resource with a given config tweak ---------------------------------------------------
function H.load(tweak)
    for _, name in ipairs({ 'server.core', 'server.main', 'server.admin' }) do package.loaded[name] = nil end
    Config = nil
    Locales = nil
    dofile('config.lua')
    if tweak then tweak(Config) end
    dofile('shared/locale.lua')
    dofile('locales/en.lua')
    H.callbacks, H.handlers, H.exports, H.commands = {}, {}, {}, {}
    threads = {}
    S.accounts, S.history, S.daily, S.audits = {}, {}, {}, {}
    H.events, H.localEvents, H.bank, H.offlineBank, H.charged, H.online, H.http = {}, {}, {}, {}, {}, {}, {}
    H.NOW = 1700000000
    H.core = dofile('server/core.lua')
    package.loaded['server.core'] = H.core
    dofile('server/main.lua')
    dofile('server/admin.lua')
    H.runThreads(1)
    H.core.loadGate()
    return H.core
end

function H.player(src, bank)
    H.online[src] = true
    H.bank[src] = bank or 0
    return 'CID' .. src
end

function H.call(name, src, payload) return H.callbacks['sd_carrier:' .. name](src, payload) end

function H.notices(titleMatch)
    local o = {}
    for _, e in ipairs(H.events) do
        if e.name == 'sd-phone:client:notify' and (not titleMatch or tostring(e.payload.title):find(titleMatch, 1, true)) then o[#o + 1] = e.payload end
    end
    return o
end

return H
