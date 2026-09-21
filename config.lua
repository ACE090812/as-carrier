Config = {
    -- Language: any file in locales/ (locales/en.lua = English). Copy en.lua to add a language.
    locale = 'en',

    -- 'auto' detects qbx_core / qb-core / es_extended / falls back to 'standalone'.
    -- 'standalone' has no real bank accounts - Pay Now / auto-pay always succeeds.
    framework = 'auto',

    -- What an account (plan, usage, bill) belongs to.
    --   'sim'       one account per SIM card: a new SIM has no plan, an old SIM keeps its plan and its bill,
    --               and whoever has the SIM in their phone owes the bill. Use this with sd-phone's
    --               DataOwner = 'sim' (the SIM is the phone).
    --   'character' one account per character, whatever SIM they use (stock sd-phone).
    --   'auto'      'sim' while sd-phone's SIM mode is on, otherwise 'character'.
    accountBy = 'auto',

    -- Symbol shown in front of every price in the app and in notifications.
    currency = '£',

    -- How the app shows up in the App Store / home screen.
    app = {
        identifier  = 'aeromobile',
        name        = 'Aero Mobile',
        description = 'Your plan, usage and phone bill.',
        icon = 'nui://as-carrier/ui/icon.png',
    },

    billing = {
        -- Days per billing cycle.
        cycleDays = 28,
        -- Days a bill can sit unpaid after its due date before the account is marked suspended.
        -- Suspension is enforced by the small sd-phone edit in the README (server/service.lua).
        graceDays = 3,

        -- true  = a player has to choose their own first plan. Until they do, calls, texts and data are
        --         blocked (emergency and company lines still work) and nothing is metered or billed.
        -- false = no plan means no bill and no block: service just works.
        requirePlan = true,

        -- true = once a plan is chosen it is locked until the end of the cycle. Choosing another plan
        --        queues the switch for the next bill (it can be cancelled before then).
        -- false = plans can be changed at any time and the change is immediate.
        planLock = true,

        -- Every this many seconds the server rolls over any online player's cycle, raises the bill,
        -- auto-pays and suspends when it is due, so billing does not wait for the app to be opened.
        -- 0 = off (billing then only happens when a player opens the app).
        sweepSeconds = 60,

        -- Approximate cellular data usage: this resource has no byte-level metering of what each
        -- app actually sends, so "data used" is estimated the way a rough usage tracker would - a
        -- flat MB rate for every interval the phone is open, unlocked and NOT on Wi-Fi. Tune to
        -- taste; it's a simulation, not a packet counter, and the app says so.
        dataHeartbeatSeconds = 60,
        dataPerHeartbeatMB   = 6,

        -- `minutes` / `texts` / `dataMB` = -1 means unlimited (never billed as overage). Overage
        -- rates are currency-per-unit, only charged once the plan's included allowance is used up.
        plans = {
            { id = 'lite',      label = 'SIM Only Lite', price = 6,
              minutes = 100,  texts = 100,  dataMB = 500,
              overagePerMinute = 0.10, overagePerText = 0.05, overagePerMB = 0.02 },
            { id = 'basic',     label = 'Basic', price = 10,
              minutes = 250,  texts = 250,  dataMB = 2000,
              overagePerMinute = 0.10, overagePerText = 0.05, overagePerMB = 0.01 },
            { id = 'standard',  label = 'Standard', price = 20,
              minutes = 1000, texts = -1,   dataMB = 10000,
              overagePerMinute = 0.08, overagePerText = 0,    overagePerMB = 0.008,
              popular = true },
            { id = 'unlimited', label = 'Unlimited', price = 35,
              minutes = -1,   texts = -1,   dataMB = -1,
              overagePerMinute = 0,    overagePerText = 0,    overagePerMB = 0 },
        },
    },

    -- 'account' removes from a money account/balance (framework's cash/bank account below).
    -- Real carriers bill to a bank account, not physical cash, so this has no 'item' mode.
    payment = {
        account = 'bank',
    },
}
