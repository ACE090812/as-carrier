local store = {}

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
end

function store.getAccount(cid)
    if type(cid) ~= 'string' or cid == '' then return nil end
    return MySQL.single.await('SELECT * FROM sd_carrier_accounts WHERE citizenid = ?', { cid })
end

function store.insertAccount(cid, planId, cycleStart, dueAt)
    MySQL.insert.await([[
        INSERT IGNORE INTO sd_carrier_accounts
            (citizenid, plan_id, cycle_start, due_at, auto_pay, status, minutes_used, texts_used, data_mb_used, balance_due)
        VALUES (?, ?, ?, ?, 0, 'current', 0, 0, 0, 0)
    ]], { cid, planId, cycleStart, dueAt })
end

function store.setPlan(cid, planId)
    MySQL.update.await('UPDATE sd_carrier_accounts SET plan_id = ? WHERE citizenid = ?', { planId, cid })
end

function store.setAutoPay(cid, on)
    MySQL.update.await('UPDATE sd_carrier_accounts SET auto_pay = ? WHERE citizenid = ?', { on and 1 or 0, cid })
end

function store.setStatus(cid, status)
    MySQL.update.await('UPDATE sd_carrier_accounts SET status = ? WHERE citizenid = ?', { status, cid })
end

function store.addMinutes(cid, minutes)
    if minutes <= 0 then return end
    MySQL.update.await('UPDATE sd_carrier_accounts SET minutes_used = minutes_used + ? WHERE citizenid = ?', { minutes, cid })
end

function store.addTexts(cid, n)
    if n <= 0 then return end
    MySQL.update.await('UPDATE sd_carrier_accounts SET texts_used = texts_used + ? WHERE citizenid = ?', { n, cid })
end

function store.addDataMB(cid, mb)
    if mb <= 0 then return end
    MySQL.update.await('UPDATE sd_carrier_accounts SET data_mb_used = data_mb_used + ? WHERE citizenid = ?', { mb, cid })
end

function store.rollCycle(cid, newCycleStart, newDueAt, balanceDue, balanceSince)
    MySQL.update.await([[
        UPDATE sd_carrier_accounts
        SET cycle_start = ?, due_at = ?, minutes_used = 0, texts_used = 0, data_mb_used = 0, balance_due = ?, balance_since = ?
        WHERE citizenid = ?
    ]], { newCycleStart, newDueAt, balanceDue, balanceSince, cid })
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

return store