-- Staff commands: /carrier <action> <target> [value]
-- <target> is a server id (a player who is online), a SIM phone number, or an account key (citizenid / sim:<number>).
-- Every change is written to sd_carrier_audit.

local store = require 'server.store'
local core = require 'server.core'

local cfg = Config.admin or {}
if cfg.enabled == false then return end

local NULL = core.NULL
local money, priceText = core.money, core.priceText

local function say(src, text)
    if not src or src == 0 then
        print('[as-carrier] ' .. text:gsub('\n', '\n[as-carrier] '))
        return
    end
    TriggerClientEvent('ox_lib:notify', src, { title = 'Carrier', description = text, type = 'inform', duration = 9000 })
end

local function actorName(src)
    if not src or src == 0 then return 'console' end
    return ('%s (%s)'):format(GetPlayerName(src) or '?', src)
end

--- Resolves <target> to an account key.
local function resolveTarget(arg)
    if type(arg) ~= 'string' or arg == '' then return nil end
    local n = tonumber(arg)
    if n and n > 0 and n < 100000 and GetPlayerName(n) then
        local key = core.resolveKey(n)
        if key then return key end
    end
    if core.getRow(arg) then return arg end
    local id = core.simIdentity(arg)
    if id then return id end
    return nil
end

local function dayText(ts)
    if not ts then return '-' end
    return os.date('%Y-%m-%d %H:%M', ts)
end

local function used(row, plan, what, field)
    local inc = core._.includedOf(plan, row, what)
    local u = row[field] or 0
    if inc < 0 then return ('%s / unlimited'):format(u) end
    return ('%s / %s'):format(u, inc)
end

local function describe(key, row)
    local plan = core.planFor(row.plan_id)
    local lines = {
        ('Account: %s'):format(key),
        ('Payer: %s'):format(row.payer_id or '-'),
        ('Plan: %s (%s)%s'):format(core.truthy(row.plan_chosen) and (plan.label or plan.id) or 'none chosen', core.kindOf(plan),
            row.pending_plan and (' -> queued: ' .. row.pending_plan) or ''),
        ('Status: %s%s'):format(row.status, row.paused_at and (' (paused until ' .. dayText(row.paused_until) .. ')') or ''),
        ('Cycle: %s to %s'):format(dayText(row.cycle_start), dayText(row.due_at)),
        ('Minutes: %s'):format(used(row, plan, 'minutes', 'minutes_used')),
        ('Texts: %s'):format(used(row, plan, 'texts', 'texts_used')),
        ('Data MB: %s (add-ons %s)'):format(used(row, plan, 'data', 'data_mb_used'), row.extra_data_mb),
        ('Balance due: %s%s'):format(priceText(row.balance_due), row.balance_since and (' since ' .. dayText(row.balance_since)) or ''),
        ('Credit: %s'):format(priceText(row.credit)),
        ('Auto-pay: %s'):format(core.truthy(row.auto_pay) and 'on' or 'off'),
        ('Add-ons: %s MB, %s min, %s texts'):format(row.extra_data_mb, row.extra_minutes, row.extra_texts),
    }
    if row.auto_topup_amount > 0 then
        lines[#lines + 1] = ('Auto top-up: %s when credit is %s or less'):format(priceText(row.auto_topup_amount), priceText(row.auto_topup_below))
    end
    if row.contract_ends then lines[#lines + 1] = ('Contract ends: %s (exit fee %s)'):format(dayText(row.contract_ends), priceText(core.exitFee(row))) end
    if row.promo_id then lines[#lines + 1] = ('Promo: %s (%s bills left)'):format(row.promo_id, row.promo_cycles_left) end
    return table.concat(lines, '\n')
end

local HELP = table.concat({
    '/carrier info <target>',
    '/carrier setplan <target> <planId>   (puts them on the plan now, free)',
    '/carrier unplan <target>              (back to "no plan")',
    '/carrier credit <target> <amount>     (+/- prepaid credit)',
    '/carrier addextra <target> <data|minutes|texts> <amount>   (+/- add-on amount this cycle; adddata <target> <mb> still works)',
    '/carrier history <target> [count]     (recent bills, fees, top-ups, add-ons with their ids)',
    '/carrier refund <target> <entryId> [credit]   (pays a bill/fee/add-on/top-up back; an unpaid bill is waived)',
    '/carrier bulkpromo <promoId> [all|postpaid|prepaid]   (gives every matching account a promotion)',
    '/carrier stats | dash | validate      (numbers, an in-game page, a check of config.lua)',
    '/carrier clearbill <target>           (waive the balance)',
    '/carrier suspend <target> | restore <target>',
    '/carrier resetusage <target>          (zero this cycle\'s usage)',
    '/carrier promo <target> <promoId>     (give a promotion from the config)',
    'target = server id, phone number or account key',
}, '\n')

local ACTIONS = {}

ACTIONS.info = function(key, row, args, actor)
    return describe(key, row)
end

ACTIONS.setplan = function(key, row, args, actor)
    local planId = args[1]
    if not planId or not core.PLANS[planId] then return nil, 'Unknown plan. Plans: ' .. (function()
        local ids = {}
        for _, p in ipairs(core.PLAN_LIST) do ids[#ids + 1] = p.id end
        return table.concat(ids, ', ')
    end)() end
    core.startPlan(key, row, planId, os.time(), { free = true })
    return ('%s is now on %s'):format(key, planId), ('plan=%s'):format(planId)
end

ACTIONS.unplan = function(key, row)
    core.save(key, { plan_chosen = 0, pending_plan = NULL, contract_ends = NULL, promo_id = NULL, promo_cycles_left = 0 })
    core._.setKnown(key, row)
    core.pushUpdate(key)
    return key .. ' has no plan now', 'unplan'
end

ACTIONS.credit = function(key, row, args)
    local amount = tonumber(args[1])
    if not amount or amount == 0 then return nil, 'Give an amount, e.g. 10 or -5' end
    local new = math.max(0, money(row.credit + amount))
    core.save(key, { credit = new })
    core._.record(key, { kind = 'adjust', planId = row.plan_id, amount = math.abs(money(amount)), label = amount > 0 and 'Credit added' or 'Credit removed',
        items = { { k = 'adjust', label = amount > 0 and 'Credit added' or 'Credit removed', amount = money(amount) } }, paid = true })
    core._.setKnown(key, row)
    core.pushUpdate(key)
    return ('Credit is now %s'):format(priceText(new)), ('credit %+.2f'):format(amount)
end

local EXTRA_COL = { data = 'extra_data_mb', minutes = 'extra_minutes', texts = 'extra_texts' }

ACTIONS.addextra = function(key, row, args)
    local what = args[1] and args[1]:lower()
    local col = EXTRA_COL[what]
    local amount = tonumber(args[2])
    if not col then return nil, 'Say what: data, minutes or texts' end
    if not amount or amount == 0 then return nil, 'Give an amount, e.g. 100 or -50' end
    local new = math.max(0, (row[col] or 0) + amount)
    core.save(key, { [col] = new })
    core._.setKnown(key, row)
    core.pushUpdate(key)
    return ('Add-on %s is now %s'):format(what, new), ('addextra %s %+d'):format(what, amount)
end
ACTIONS.adddata = function(key, row, args) return ACTIONS.addextra(key, row, { 'data', args[1] }) end

ACTIONS.history = function(key, row, args)
    local n = math.min(30, math.max(1, math.floor(tonumber(args[1]) or 10)))
    local lines = {}
    for _, h in ipairs(store.listHistory(key, n)) do
        lines[#lines + 1] = ('%s  %s  %s  %s%s  %s'):format(h.id, h.kind or 'bill', priceText(h.amount),
            core.truthy(h.paid) and 'paid' or 'UNPAID', core.truthy(h.refunded) and ' (refunded)' or '',
            os.date('%Y-%m-%d', h.at or 0))
    end
    if #lines == 0 then return 'No entries yet' end
    return table.concat(lines, '\n')
end

ACTIONS.refund = function(key, row, args)
    if not args[1] then return nil, 'Give the entry id (see /carrier history)' end
    local mode = args[2] and args[2]:lower() == 'credit' and 'credit' or 'bank'
    local ok, msg = core.refund(key, row, args[1], mode)
    if not ok then return nil, msg end
    return 'Done: ' .. msg, ('refund %s: %s'):format(args[1], msg)
end

ACTIONS.clearbill = function(key, row)
    if row.balance_due <= 0 then return nil, 'Nothing is owed' end
    local was = row.balance_due
    core.settle(key, row, os.time())
    core.pushUpdate(key)
    return ('Cleared %s'):format(priceText(was)), ('waived %.2f'):format(was)
end

ACTIONS.suspend = function(key, row)
    core._.setStatus(key, row, 'suspended')
    core.pushUpdate(key)
    return key .. ' is suspended (use restore to lift it)', 'suspend'
end

ACTIONS.restore = function(key, row)
    if row.balance_due > 0 then
        -- they get the grace period again instead of being suspended on the next sweep
        core.save(key, { balance_since = os.time(), late_fee_applied = 0 })
        core._.setStatus(key, row, 'due')
    else
        core._.setStatus(key, row, 'current')
    end
    core.pushUpdate(key)
    return key .. ' is restored', 'restore'
end

ACTIONS.resetusage = function(key, row)
    core.save(key, { minutes_used = 0, texts_used = 0, data_mb_used = 0, alert_bits = core._.clearMask(row.alert_bits, core._.USAGE_MASK) })
    core._.setKnown(key, row)
    core.pushUpdate(key)
    return 'Usage reset', 'resetusage'
end

ACTIONS.promo = function(key, row, args, actor)
    local id = args[1]
    local promos = Config.promotions or {}
    local found
    for _, p in ipairs(promos) do if p.id == id then found = p end end
    if not found then return nil, 'Unknown promotion id' end
    core.save(key, {
        promo_id = found.id, promo_cycles_left = math.max(1, math.floor(tonumber(found.cycles) or 1)),
        promos_used = core._.addUsed(row, found.id),
    })
    core.pushUpdate(key)
    return ('%s now has promotion %s'):format(key, found.id), ('promo=%s'):format(found.id)
end

-- The dashboard ---------------------------------------------------------------------------------

local function sendSummary()
    local wh = cfg.webhook or {}
    if type(wh.url) ~= 'string' or wh.url == '' then return false end
    local d = core.dashboard()
    local body = {
        username = wh.username or 'Aero Mobile',
        embeds = { {
            title = (Config.app.name or 'Aero Mobile') .. ' summary',
            description = table.concat(core.dashboardLines(d), '\n'),
            color = 3447003,
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', d.at),
        } },
    }
    PerformHttpRequest(wh.url, function(code)
        if code and code >= 300 then print(('[as-carrier] the Discord summary was refused (HTTP %s)'):format(tostring(code))) end
    end, 'POST', json.encode(body), { ['Content-Type'] = 'application/json' })
    return true
end

CreateThread(function()
    local wh = cfg.webhook or {}
    if type(wh.url) ~= 'string' or wh.url == '' then return end
    local every = math.max(1, tonumber(wh.everyHours) or 24) * 3600
    local last = os.time()
    while not core.gateLoaded() do Wait(1000) end
    while true do
        Wait(60000)
        if os.time() - last >= every then
            last = os.time()
            local ok, err = pcall(sendSummary)
            if not ok then print(('[as-carrier] could not send the Discord summary: %s'):format(tostring(err))) end
        end
    end
end)

-- Actions that are about the whole server, not one account.
local GLOBAL = {}

GLOBAL.stats = function(src, args)
    if args.target and args.target:lower() == 'send' then
        return sendSummary() and 'Summary sent to Discord' or 'No webhook url is set in Config.admin.webhook'
    end
    return table.concat(core.dashboardLines(core.dashboard()), '\n')
end

GLOBAL.dash = function(src, args)
    local d = core.dashboard()
    if not src or src == 0 then return table.concat(core.dashboardLines(d), '\n') end
    TriggerClientEvent('sd_carrier:client:dash', src, { lines = core.dashboardLines(d), title = (Config.app.name or 'Aero Mobile') })
    return nil
end

GLOBAL.validate = function()
    local issues = core.checkConfig()
    if #issues == 0 then return 'config.lua looks fine' end
    local lines = {}
    for _, i in ipairs(issues) do lines[#lines + 1] = ('%s: %s'):format(i.level, i.text) end
    return table.concat(lines, '\n')
end

GLOBAL.bulkpromo = function(src, args, actor)
    if not args.target then return 'Give a promotion id from Config.promotions' end
    local n, err = core.bulkPromo(args.target, args.value)
    if not n then return err end
    store.audit(actor, 'ALL', 'bulkpromo', ('%s to %s account(s) (%s)'):format(args.target, n, args.value or 'all'))
    print(('[as-carrier] %s: bulkpromo %s to %s account(s)'):format(actor, args.target, n))
    return ('%s given to %s account(s)'):format(args.target, n)
end

local function handle(src, args)
    local action = args.action and args.action:lower() or 'help'
    if action == 'help' then return say(src, HELP) end
    if GLOBAL[action] then
        local ok, text = pcall(GLOBAL[action], src, args, actorName(src))
        if not ok then
            print(('[as-carrier] admin command failed: %s'):format(tostring(text)))
            return say(src, 'That failed, see the server console.')
        end
        if text then say(src, text) end
        return
    end
    local run = ACTIONS[action]
    if not run then return say(src, 'Unknown action.\n' .. HELP) end

    local key = resolveTarget(args.target)
    if not key then return say(src, 'No account found for "' .. tostring(args.target) .. '"') end

    local rest = { args.value, args.extra }
    local msg, detail
    local ok, err = pcall(function()
        core.withLock(key, function()
            local row = core.ensureAccount(key)
            local text, d = run(key, row, rest, actorName(src))
            msg, detail = text, d
            if action ~= 'info' and text and d then
                store.audit(actorName(src), key, action, d)
                print(('[as-carrier] %s: %s on %s (%s)'):format(actorName(src), action, key, d))
            end
        end)
    end)
    if not ok then
        print(('[as-carrier] admin command failed: %s'):format(tostring(err)))
        return say(src, 'That failed, see the server console.')
    end
    say(src, msg or detail or 'Done')
end

local params = {
    { name = 'action', type = 'string', help = 'help | info | history | refund | setplan | unplan | credit | addextra | clearbill | suspend | restore | resetusage | promo | bulkpromo | stats | dash | validate', optional = true },
    { name = 'target', type = 'string', help = 'server id, phone number or account key', optional = true },
    { name = 'value', type = 'string', help = 'plan id / amount / MB / promotion id', optional = true },
    { name = 'extra', type = 'string', optional = true },
}

if lib and lib.addCommand then
    lib.addCommand(cfg.command or 'carrier', {
        help = 'Aero Mobile staff tools (/carrier help)',
        params = params,
        restricted = cfg.ace or 'group.admin',
    }, function(source, args)
        handle(source, args)
    end)
else
    RegisterCommand(cfg.command or 'carrier', function(source, a)
        handle(source, { action = a[1], target = a[2], value = a[3], extra = a[4] })
    end, true)
end
