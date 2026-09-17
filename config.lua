Config = {
    -- 'auto' detects qbx_core / qb-core / es_extended / falls back to 'standalone'.
    -- 'standalone' has no real bank accounts - Pay Now / auto-pay always succeeds.
    framework = 'auto',

    -- How the app shows up in the App Store / home screen.
    app = {
        identifier  = 'carrier',
        name        = 'Carrier',
        description = 'Your plan, usage and phone bill.',
        icon = '',
    },

    billing = {
        -- Days per billing cycle.
        cycleDays = 28,
        -- Days a bill can sit unpaid after its due date before the account is marked suspended.
        -- Suspension is always tracked and displayed by the app. To make it actually cut off
        -- calls/texts/data, add the small server/service.lua edit documented in the README -
        -- without it, suspension is real and visible but not enforced by sd-phone itself.
        graceDays = 3,

        -- The plan a citizenid is put on the first time they're ever billed.
        defaultPlan = 'basic',

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
              overagePerMinute = 0.08, overagePerText = 0,    overagePerMB = 0.008 },
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