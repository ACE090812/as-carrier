local store = {}

-- The `citizenid` column holds the account key: the SIM's identity ('sim:<number>', or a citizenid for a
-- character-bound SIM) when Config.accountBy is 'sim', a character's citizenid otherwise. The column
-- name is kept so an existing database keeps working.

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

--- Creates the tables and adds the plan columns. Returns true when the plan columns were added on this
--- run, which is the one moment every existing account is reset (they never chose their plan).
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

    local added = false
    if not columnExists('sd_carrier_accounts', 'plan_chosen') then
        MySQL.query.await('ALTER TABLE sd_carrier_accounts ADD COLUMN plan_chosen TINYINT(1) NOT NULL DEFAULT 0')
        added = true
    end
    if not columnExists('sd_carrier_accounts', 'pending_plan') then
        MySQL.query.await('ALTER TABLE sd_carrier_accounts ADD COLUMN pending_plan VARCHAR(32) NULL')
    end

    if added then
        -- Nobody on the old system picked their plan (the script put them on one). They choose again; any
        -- unpaid balance stays, only usage from the old cycle is dropped.
        MySQL.update.await('UPDATE sd_carrier_accounts SET minutes_used = 0, texts_used = 0, data_mb_used = 0, pending_plan = NULL')
    end
    return added
end

function store.getAccount(cid)
    if type(cid) ~= 'string' or cid == '' then return nil end
    return MySQL.single.await('SELECT * FROM sd_carrier_accounts WHERE citizenid = ?', { cid })
end

function store.listAll()
    return MySQL.query.await('SELECT citizenid, plan_chosen, status FROM sd_carrier_accounts') or {}
end

--- A new account with no plan chosen yet. `placeholderPlan` only fills the NOT NULL column.
function store.insertAccount(cid, placeholderPlan, cycleStart, dueAt)
    MySQL.insert.await([[
        INSERT IGNORE INTO sd_carrier_accounts
            (citizenid, plan_id, cycle_start, due_at, auto_pay, status, minutes_used, texts_used, data_mb_used, balance_due, plan_chosen)
        VALUES (?, ?, ?, ?, 0, 'current', 0, 0, 0, 0, 0)
    ]], { cid, placeholderPlan, cycleStart, dueAt })
end

--- The player's own first pick: it starts now, so it starts the cycle and the lock.
function store.choosePlan(cid, planId, cycleStart, dueAt)
    MySQL.update.await([[
        UPDATE sd_carrier_accounts
        SET plan_id = ?, plan_chosen = 1, pending_plan = NULL, cycle_start = ?, due_at = ?,
            minutes_used = 0, texts_used = 0, data_mb_used = 0
        WHERE citizenid = ?
    ]], { planId, cycleStart, dueAt, cid })
end

--- Switches the plan straight away (only used when Config.billing.planLock is off).
function store.setPlan(cid, planId)
    MySQL.update.await('UPDATE sd_carrier_accounts SET plan_id = ?, pending_plan = NULL WHERE citizenid = ?', { planId, cid })
end

--- Queues a plan for the next cycle, or clears the queue with nil.
function store.setPending(cid, planId)
    if planId then
        MySQL.update.await('UPDATE sd_carrier_accounts SET pending_plan = ? WHERE citizenid = ?', { planId, cid })
    else
        MySQL.update.await('UPDATE sd_carrier_accounts SET pending_plan = NULL WHERE citizenid = ?', { cid })
    end
end

function store.setAutoPay(cid, on)
    MySQL.update.await('UPDATE sd_carrier_accounts SET auto_pay = ? WHERE citizenid = ?', { on and 1 or 0, cid })
end

function store.setStatus(cid, status)
    MySQL.update.await('UPDATE sd_carrier_accounts SET status = ? WHERE citizenid = ?', { status, cid })
end

function store.addMinutes(cid, minutes)
    if minutes <= 0 then return end
    MySQL.update.await('UPDATE sd_carrier_accounts SET minutes_used = minutes_used + ? WHERE citizenid = ? AND plan_chosen = 1', { minutes, cid })
end

function store.addTexts(cid, n)
    if n <= 0 then return end
    MySQL.update.await('UPDATE sd_carrier_accounts SET texts_used = texts_used + ? WHERE citizenid = ? AND plan_chosen = 1', { n, cid })
end

function store.addDataMB(cid, mb)
    if mb <= 0 then return end
    MySQL.update.await('UPDATE sd_carrier_accounts SET data_mb_used = data_mb_used + ? WHERE citizenid = ? AND plan_chosen = 1', { mb, cid })
end

--- Starts the next cycle. `balanceSince` and `newPlanId` may be nil (no unpaid balance / no queued plan);
--- the SQL is built per case because oxmysql parameter arrays must not have nil holes.
function store.rollCycle(cid, newCycleStart, newDueAt, balanceDue, balanceSince, newPlanId)
    local sets = { 'cycle_start = ?', 'due_at = ?', 'minutes_used = 0', 'texts_used = 0', 'data_mb_used = 0', 'balance_due = ?' }
    local params = { newCycleStart, newDueAt, balanceDue }
    if balanceSince then
        sets[#sets + 1] = 'balance_since = ?'
        params[#params + 1] = balanceSince
    else
        sets[#sets + 1] = 'balance_since = NULL'
    end
    if newPlanId then
        sets[#sets + 1] = 'plan_id = ?'
        params[#params + 1] = newPlanId
    end
    sets[#sets + 1] = 'pending_plan = NULL'
    params[#params + 1] = cid
    MySQL.update.await('UPDATE sd_carrier_accounts SET ' .. table.concat(sets, ', ') .. ' WHERE citizenid = ?', params)
end

function store.clearBalance(cid)
    MySQL.update.await("UPDATE sd_carrier_accounts SET balance_due = 0, balance_since = NULL, status = 'current' WHERE citizenid = ?", { cid })
end

function store.insertHistory(cid, planId, amount, cycleStart)
    local id = newId(10)
    MySQL.insert.await([[
        INSERT INTO sd_carrier_history (id, citizenid, plan_id, amount, cycle_start, paid, paid_at)
        VALUES (?, ?, ?, ?, ?, 0, NULL)
    ]], { id, cid, planId, amount, cycleStart })
    return id
end

function store.markLatestPaid(cid, paidAt)
    MySQL.update.await([[
        UPDATE sd_carrier_history SET paid = 1, paid_at = ?
        WHERE citizenid = ? AND paid = 0
        ORDER BY created_at DESC LIMIT 1
    ]], { paidAt, cid })
end

function store.listHistory(cid, limit)
    return MySQL.query.await(
        'SELECT id, plan_id, amount, cycle_start, paid, paid_at, created_at FROM sd_carrier_history WHERE citizenid = ? ORDER BY created_at DESC LIMIT ?',
        { cid, limit or 12 }) or {}
end

--- The SIM identity for a phone number, from sd-phone's own SIM table.
function store.simIdentity(number)
    if type(number) ~= 'string' or number == '' then return nil end
    return MySQL.scalar.await('SELECT identity FROM phone_sim_cards WHERE number = ?', { number })
end

return store
