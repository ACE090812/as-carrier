Config = {
    -- 'auto' detects qbx_core / qb-core / es_extended / falls back to 'standalone'.
    -- 'standalone' has no real bank accounts - Pay Now / auto-pay always succeeds.
    framework = 'auto',

    -- How the app shows up in the App Store / home screen.
    app = {
        identifier  = 'carrier',
        name        = 'Carrier',
        description = 'Your plan, usage and phone bill.',
        -- No icon shipped - sd-phone falls back to an automatic letter tile when this is empty.
        -- Point this at your own image (as a 'nui://sd_carrier/ui/whatever.png' or a plain
        -- 'sd_carrier/ui/whatever.png' path) if you want a real icon instead.
        icon = '',
    },

    -- A real phone bill: pay-monthly plans, each with its own price and included minutes/texts/
    -- data. Usage is tallied through the cycle (calls from their logged duration, texts per send,
    -- data from an approximate cellular-use heartbeat - see server/main.lua's header for why data
    -- can't be metered byte-for-byte without editing sd-phone's own app-install code, which this
    -- resource deliberately never does), and at the end of the cycle a bill is raised for the plan
    -- price plus any overage. Auto-pay (opt-in, per player) tries to charge the bank on the due
    -- date; otherwise the player pays by hand in the app.
    billing = {
        -- Days per billing cycle.
        cycleDays = 28,
        -- Days a bill can sit unpaid after its due date before the account is marked suspended.
        -- NOTE: this resource cannot actually block calls/texts on suspension without editing
        -- sd-phone's own server/service.lua (the single gate calls/texts run through) - see the
        -- README's "Known limitation" section. Suspension here is a real, tracked status the app
        -- displays (and you can act on it yourself, e.g. from a script listening for
        -- 'sd_carrier:accountSuspended'), just not an automatic service cutoff.
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
