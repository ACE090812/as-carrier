local store = {}

-- The `citizenid` column holds the account key: the SIM's identity ('sim:<number>', or a citizenid for a
-- character-bound SIM) when Config.accountBy is 'sim', a character's citizenid otherwise. The column
-- name is kept so an existing database keeps working.

--- Pass this to store.save to set a column to NULL.
store.NULL = {}

local function newId(len)
    len = len or 10
    local chars = '0123456789abcdefghijklmnopqrstuvwxyz'
    local out = {}
    for i = 1, len do
        local n = math.random(1, #chars)
        out[i] = chars:sub(n, n)
    end
    return table.concat(out)
end
store.newId = newId

local function columnExists(tbl, col)
    return (MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?
    ]], { tbl, col }) or 0) > 0
end

local function indexExists(tbl, name)
    return (MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.statistics
        WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?
    ]], { tbl, name }) or 0) > 0
end

-- Columns added after the first release. Added one by one so any older database is brought up to date.
local ACCOUNT_COLUMNS = {
    { 'plan_chosen',       'TINYINT(1) NOT NULL DEFAULT 0' },
    { 'pending_plan',      'VARCHAR(32) NULL' },
    { 'credit',            'DECIMAL(10,2) NOT NULL DEFAULT 0' },
    { 'extra_data_mb',     'DECIMAL(10,2) NOT NULL DEFAULT 0' },
    { 'contract_ends',     'BIGINT NULL' },
    { 'paused_at',         'BIGINT NULL' },
    { 'paused_until',      'BIGINT NULL' },
    { 'promo_id',          'VARCHAR(32) NULL' },
    { 'promo_cycles_left', 'INT NOT NULL DEFAULT 0' },
    { 'promos_used',       "VARCHAR(1024) NOT NULL DEFAULT ''" },
    { 'late_fee_applied',  'TINYINT(1) NOT NULL DEFAULT 0' },
    { 'alert_bits',        'INT NOT NULL DEFAULT 0' },
    { 'payer_id',          'VARCHAR(64) NULL' },
}

local HISTORY_COLUMNS = {
    { 'kind',  "VARCHAR(16) NOT NULL DEFAULT 'bill'" },
    { 'label', "VARCHAR(64) NOT NULL DEFAULT ''" },
    { 'items', 'TEXT NULL' },
    { 'at',    'BIGINT NOT NULL DEFAULT 0' },
}

-- Columns store.save may write (anything else is ignored, so a field name can never reach the SQL).
local SAVEABLE = {
    plan_id = true, plan_chosen = true, pending_plan = true, cycle_start = true, due_at = true,
    auto_pay = true, status = true, minutes_used = true, texts_used = true, data_mb_used = true,
    balance_due = true, balance_since = true, credit = true, extra_data_mb = true, contract_ends = true,
    paused_at = true, paused_until = true, promo_id = true, promo_cycles_left = true, promos_used = true,
    late_fee_applied = true, alert_bits = true, payer_id = true,
}

--- Creates the tables and brings the columns up to date. Returns true when the plan columns were added on
--- this run, which is the one moment every existing account is reset (they never chose their plan).
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS sd_carrier_accounts (
            citizenid      VARCHAR(64)   NOT NULL,
            plan_id        VARCHAR(32)   NOT NULL,
            cycle_start    BIGINT        NOT NULL,
            due_at         BIGINT        NOT NULL,
            auto_pay       TINYINT(1)    NOT NULL DEFAULT 0,
            status         VARCHAR(16)   NOT NULL DEFAULT 'current',
            minutes_used   INT           NOT NULL DEFAULT 0,
            texts_used     INT           NOT NULL DEFAULT 0,
            data_mb_used   DECIMAL(10,2) NOT NULL DEFAULT 0,
            balance_due    DECIMAL(10,2) NOT NULL DEFAULT 0,
            balance_since  BIGINT        NULL,
            created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS sd_carrier_history (
            id          VARCHAR(16)   NOT NULL,
            citizenid   VARCHAR(64)   NOT NULL,
            plan_id     VARCHAR(32)   NOT NULL,
            amount      DECIMAL(10,2) NOT NULL,
            cycle_start BIGINT        NOT NULL,
            paid        TINYINT(1)    NOT NULL DEFAULT 0,
            paid_at     BIGINT        NULL,
            created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (id),
            INDEX idx_sd_carrier_history_cid (citizenid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS sd_carrier_usage_daily (
            citizenid VARCHAR(64)   NOT NULL,
            day       INT           NOT NULL,
            minutes   INT           NOT NULL DEFAULT 0,
            texts     INT           NOT NULL DEFAULT 0,
            data_mb   DECIMAL(10,2) NOT NULL DEFAULT 0,
            PRIMARY KEY (citizenid, day)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS sd_carrier_audit (
            id      VARCHAR(16)  NOT NULL,
            actor   VARCHAR(64)  NOT NULL,
            target  VARCHAR(64)  NOT NULL,
            action  VARCHAR(32)  NOT NULL,
            detail  VARCHAR(255) NOT NULL DEFAULT '',
            at      BIGINT       NOT NULL,
            PRIMARY KEY (id),
            INDEX idx_sd_carrier_audit_target (target)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    local planColumnAdded = false
    local promosColumnAdded = false
    for _, c in ipairs(ACCOUNT_COLUMNS) do
        if not columnExists('sd_carrier_accounts', c[1]) then
            MySQL.query.await(('ALTER TABLE sd_carrier_accounts ADD COLUMN %s %s'):format(c[1], c[2]))
            if c[1] == 'plan_chosen' then planColumnAdded = true end
            if c[1] == 'promos_used' then promosColumnAdded = true end
        end
    end
    for _, c in ipairs(HISTORY_COLUMNS) do
        if not columnExists('sd_carrier_history', c[1]) then
            MySQL.query.await(('ALTER TABLE sd_carrier_history ADD COLUMN %s %s'):format(c[1], c[2]))
        end
    end

    if not indexExists('sd_carrier_accounts', 'idx_sd_carrier_due') then
        MySQL.query.await('CREATE INDEX idx_sd_carrier_due ON sd_carrier_accounts (due_at)')
    end
    if not indexExists('sd_carrier_accounts', 'idx_sd_carrier_balance') then
        MySQL.query.await('CREATE INDEX idx_sd_carrier_balance ON sd_carrier_accounts (balance_due)')
    end

    if planColumnAdded then
        -- Nobody on the old system picked their plan (the script put them on one). They choose again; any
        -- unpaid balance stays, only usage from the old cycle is dropped.
        MySQL.update.await('UPDATE sd_carrier_accounts SET minutes_used = 0, texts_used = 0, data_mb_used = 0, pending_plan = NULL')
    end
    if promosColumnAdded then
        -- Everyone who already had an account is an existing customer: "new customer" promotions are not for them.
        MySQL.update.await([[
            UPDATE sd_carrier_accounts SET promos_used = '*'
            WHERE plan_chosen = 1 OR citizenid IN (SELECT DISTINCT citizenid FROM sd_carrier_history)
        ]])
    end
    -- a brand new install has nothing to reset
    return planColumnAdded and (MySQL.scalar.await('SELECT COUNT(*) FROM sd_carrier_accounts') or 0) > 0
end

function store.getAccount(cid)
    if type(cid) ~= 'string' or cid == '' then return nil end
    return MySQL.single.await('SELECT * FROM sd_carrier_accounts WHERE citizenid = ?', { cid })
end

--- Just what the service gate needs for every account.
function store.listGate()
    return MySQL.query.await([[
        SELECT citizenid, plan_id, plan_chosen, status, paused_at, credit,
               minutes_used, texts_used, data_mb_used, extra_data_mb
        FROM sd_carrier_accounts
    ]]) or {}
end

--- Accounts that need the sweep's attention: a cycle (or bundle) that has ended, a pause that is over, an
--- unpaid balance (a suspended account only matters if auto-pay could still clear it).
function store.listDue(now)
    local rows = MySQL.query.await([[
        SELECT citizenid FROM sd_carrier_accounts
        WHERE (plan_chosen = 1 AND paused_at IS NULL AND status <> 'expired' AND due_at <= ?)
           OR (paused_at IS NOT NULL AND paused_until IS NOT NULL AND paused_until <= ?)
           OR (balance_due > 0 AND (status <> 'suspended' OR auto_pay = 1))
    ]], { now, now }) or {}
    local out = {}
    for i, r in ipairs(rows) do out[i] = r.citizenid end
    return out
end

--- A new account with no plan chosen yet. `placeholderPlan` only fills the NOT NULL column.
function store.insertAccount(cid, placeholderPlan, cycleStart, dueAt)
    MySQL.insert.await([[
        INSERT IGNORE INTO sd_carrier_accounts
            (citizenid, plan_id, cycle_start, due_at, auto_pay, status, minutes_used, texts_used, data_mb_used, balance_due, plan_chosen)
        VALUES (?, ?, ?, ?, 0, 'current', 0, 0, 0, 0, 0)
    ]], { cid, placeholderPlan, cycleStart, dueAt })
end

--- Writes the given columns. A value of store.NULL sets the column to NULL (oxmysql parameter arrays must not
--- have nil holes, so NULL is written into the statement instead of passed as a parameter).
function store.save(cid, fields)
    local sets, params = {}, {}
    for col, v in pairs(fields) do
        if SAVEABLE[col] then
            if v == store.NULL then
                sets[#sets + 1] = col .. ' = NULL'
            else
                if v == true then v = 1 elseif v == false then v = 0 end
                sets[#sets + 1] = col .. ' = ?'
                params[#params + 1] = v
            end
        end
    end
    if #sets == 0 then return end
    params[#params + 1] = cid
    MySQL.update.await('UPDATE sd_carrier_accounts SET ' .. table.concat(sets, ', ') .. ' WHERE citizenid = ?', params)
end

--- One line on an account's bills / receipts.
---   e = { kind = 'bill'|'fee'|'topup'|'addon'|'bundle'|'adjust', planId, amount, cycleStart, paid, paidAt, label, items, at }
function store.insertHistory(cid, e)
    local id = e.id or newId(10)
    local at = e.at or os.time()
    MySQL.insert.await([[
        INSERT INTO sd_carrier_history (id, citizenid, plan_id, amount, cycle_start, paid, paid_at, kind, label, items, at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        id, cid, e.planId or '', e.amount or 0, e.cycleStart or at,
        e.paid and 1 or 0, e.paid and (e.paidAt or at) or 0,
        e.kind or 'bill', e.label or '', e.items and json.encode(e.items) or '', at,
    })
    return id
end

--- Marks every unpaid bill and fee as paid.
function store.markPaid(cid, paidAt)
    MySQL.update.await("UPDATE sd_carrier_history SET paid = 1, paid_at = ? WHERE citizenid = ? AND paid = 0", { paidAt, cid })
end

function store.listHistory(cid, limit)
    local rows = MySQL.query.await([[
        SELECT id, plan_id, amount, cycle_start, paid, paid_at, kind, label, items, at, UNIX_TIMESTAMP(created_at) AS created_ts
        FROM sd_carrier_history WHERE citizenid = ? ORDER BY created_at DESC, at DESC LIMIT ?
    ]], { cid, limit or 12 }) or {}
    for _, r in ipairs(rows) do
        r.paid_at = tonumber(r.paid_at)
        if r.paid_at == 0 then r.paid_at = nil end
        r.at = tonumber(r.at)
        if not r.at or r.at == 0 then r.at = tonumber(r.created_ts) end
        if type(r.items) == 'string' and r.items ~= '' then
            local ok, decoded = pcall(json.decode, r.items)
            r.items = ok and decoded or nil
        else
            r.items = nil
        end
    end
    return rows
end

--- Adds to one day's usage (day = whole days since 1970, UTC).
function store.addDaily(cid, day, minutes, texts, dataMB)
    MySQL.update.await([[
        INSERT INTO sd_carrier_usage_daily (citizenid, day, minutes, texts, data_mb) VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE minutes = minutes + VALUES(minutes), texts = texts + VALUES(texts), data_mb = data_mb + VALUES(data_mb)
    ]], { cid, day, minutes, texts, dataMB })
end

function store.listDaily(cid, fromDay)
    return MySQL.query.await(
        'SELECT day, minutes, texts, data_mb FROM sd_carrier_usage_daily WHERE citizenid = ? AND day >= ? ORDER BY day',
        { cid, fromDay }) or {}
end

function store.pruneDaily(beforeDay)
    MySQL.update.await('DELETE FROM sd_carrier_usage_daily WHERE day < ?', { beforeDay })
end

function store.audit(actor, target, action, detail)
    MySQL.insert.await('INSERT INTO sd_carrier_audit (id, actor, target, action, detail, at) VALUES (?, ?, ?, ?, ?, ?)',
        { newId(12), tostring(actor or ''), tostring(target or ''), tostring(action or ''), tostring(detail or ''):sub(1, 255), os.time() })
end

--- The SIM identity for a phone number, from sd-phone's own SIM table.
function store.simIdentity(number)
    if type(number) ~= 'string' or number == '' then return nil end
    return MySQL.scalar.await('SELECT identity FROM phone_sim_cards WHERE number = ?', { number })
end

return store
