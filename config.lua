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

        -- What happens to a bill that is not paid. The clock starts when the bill is raised.
        --   lateFee            a one-off fee added to the balance (flat `amount` plus `percent` of the balance)
        --   limitedAfterDays   mobile data is switched off (calls and texts still work). 0 = skip this step
        --   graceDays          the account is suspended (calls, texts and data off)
        --   suspendReminderHours  a reminder this long before suspension
        -- Suspension is enforced by the small sd-phone edit in the README (server/service.lua).
        graceDays = 3,
        limitedAfterDays = 2,
        suspendReminderHours = 24,
        lateFee = {
            enabled = true,
            afterDays = 1,
            amount = 5,
            percent = 0,
        },

        -- true  = a player has to choose their own first plan. Until they do, calls, texts and data are
        --         blocked (emergency and company lines still work) and nothing is metered or billed.
        -- false = no plan means no bill and no block: service just works.
        requirePlan = true,

        -- true = once a plan is chosen it is locked until the end of the cycle. Choosing another plan
        --        queues the switch for the next bill (it can be cancelled before then).
        -- false = plans can be changed at any time and the change is immediate.
        -- (Prepaid plans are never locked, and a contract has its own rules, see Config.contract.)
        planLock = true,

        -- Every this many seconds the server finds accounts that need attention (a cycle that ended, an
        -- unpaid bill, a pause that is over) with one query and handles them, online or offline.
        -- 0 = off (billing then only happens when a player opens the app).
        sweepSeconds = 60,

        -- Usage is held in memory and written to the database in batches this often (seconds).
        flushSeconds = 15,

        -- Approximate cellular data usage: this resource has no byte-level metering of what each
        -- app actually sends, so "data used" is estimated the way a rough usage tracker would - a
        -- flat MB rate for every interval the phone is open, unlocked and NOT on Wi-Fi. Tune to
        -- taste; it's a simulation, not a packet counter, and the app says so.
        dataHeartbeatSeconds = 60,
        dataPerHeartbeatMB   = 6,

        -- What happens when the data allowance (plan + add-ons) runs out. A plan can override it with
        -- its own `outOfData`.
        --   'bill'     keep working, extra MB are billed at the plan's rate (postpaid) or taken from credit
        --   'throttle' keep working at reduced speed (see throttleKBps), nothing extra is billed ("no surprise bills")
        --   'block'    mobile data stops until the next cycle (or an add-on is bought), nothing extra is billed
        -- Prepaid pay-as-you-go ('payg') always takes extra data from credit.
        outOfData = 'bill',
        -- Throttled downloads run at this speed (kilobytes per second). sd-phone's app store waits that long
        -- when you add the one-line edit from the README. The wait is never longer than throttleMaxSeconds.
        throttleKBps = 256,
        throttleMaxSeconds = 90,

        -- Phone notifications when an allowance is nearly or fully used, and when credit runs low.
        alerts = {
            enabled = true,
            thresholds = { 80, 100 },   -- two percentages
            lowCredit = 2,              -- prepaid: warn when credit drops to this amount (0 = off)
        },

        -- Add-ons: extra data, minutes or texts bought on top of a plan, for this cycle only. An add-on can
        -- carry any of `dataMB`, `minutes`, `texts`. Postpaid players pay from their bank straight away,
        -- prepaid players pay from credit. An add-on is not offered where a plan is already unlimited in that
        -- kind (an add-on that adds nothing to the plan is hidden).
        addons = {
            carryOver = false,          -- true = unused add-on amounts roll into the next cycle
            maxExtraMB = 20480,         -- most of each an account can hold at once (0 = no limit)
            maxExtraMinutes = 1000,
            maxExtraTexts = 1000,
            list = {
                { id = 'data1',  label = '1 GB Data Boost',  dataMB = 1024, price = 5 },
                { id = 'data3',  label = '3 GB Data Boost',  dataMB = 3072, price = 12 },
                { id = 'data10', label = '10 GB Data Boost', dataMB = 10240, price = 30 },
                { id = 'min100', label = '100 Extra Minutes', minutes = 100, price = 4 },
                { id = 'txt100', label = '100 Extra Texts',   texts = 100,   price = 3 },
            },
        },

        -- Plan types:
        --   (none) / 'postpaid'  billed at the end of each cycle: plan price + overage. `contractCycles = N`
        --                        makes it a contract (see Config.contract).
        --   'payg'               prepaid pay-as-you-go: no bill, no price. Calls, texts and data are taken from
        --                        credit at the overagePer* rates. No credit = no service.
        --   'bundle'             prepaid bundle bought from credit for `durationDays`. Used up allowances are
        --                        taken from credit at the overagePer* rates. When it ends, service stops unless
        --                        the player has "auto-renew" on and enough credit.
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

            -- Examples of the other plan types. Delete or edit them freely.
            { id = 'contract6', label = 'Value 6-Month', price = 14,
              minutes = 1000, texts = -1,   dataMB = 15000,
              overagePerMinute = 0.08, overagePerText = 0,    overagePerMB = 0.008,
              contractCycles = 6, outOfData = 'throttle' },
            { id = 'payg',      label = 'Pay As You Go', type = 'payg',
              overagePerMinute = 0.15, overagePerText = 0.08, overagePerMB = 0.03 },
            { id = 'bundle30',  label = '30-Day Bundle', type = 'bundle', price = 8, durationDays = 30,
              minutes = 150,  texts = 150,  dataMB = 1500,
              overagePerMinute = 0.15, overagePerText = 0.08, overagePerMB = 0.03 },
        },
    },

    -- Prepaid credit: players top up from the payment account below.
    prepaid = {
        topUp = {
            min = 5,
            max = 200,
            presets = { 5, 10, 20, 50 },
        },
        -- An option each player can switch on: when credit drops to their chosen level the chosen amount is
        -- taken from their bank and added (also at the end of a bundle with auto-renew, if credit is short).
        -- A failed attempt is retried after retrySeconds and the player is told once.
        autoTopUp = {
            enabled = true,
            amounts = { 5, 10, 20, 50 },    -- amounts to choose from (inside the top-up min / max)
            below   = { 1, 2, 5 },          -- "when credit drops to" levels to choose from
            retrySeconds = 600,
        },
    },

    -- Receipts: the "Send to my phone" button on a receipt. 'notification' shows the receipt as a banner on
    -- the phone (always works). 'custom' calls `send` below, so a receipt can go to any phone app.
    receipts = {
        delivery = 'notification',
        -- send = function(source, subject, body, entry) ... return true end
        --   source  the player, subject a short title, body the plain-text receipt, entry the bill / fee / top-up
        --   (id, kind, label, amount, paid, items). Return true when it was delivered, false/nil to fall back
        --   to the banner. Example for a mail app whose server export takes (source, mail):
        --     send = function(source, subject, body)
        --         return pcall(function() exports['sd-phone']:sendMail(source, { subject = subject, body = body }) end)
        --     end,
        --   Check the export's real arguments in your phone's docs first.
    },

    -- Contract plans (a plan with `contractCycles`). Leaving early costs `feeRate` of the plan fees still to
    -- run, never less than `minFee` and never more than `maxFee` (0 = no limit). Moving to a dearer plan
    -- (`upgradesFree`) is free and just queues like any other switch.
    contract = {
        feeRate = 0.5,
        minFee = 5,
        maxFee = 0,
        upgradesFree = true,
    },

    -- Pause a postpaid plan for a while: nothing is billed or metered and service is off (emergency and
    -- company lines still work). The cycle picks up where it left off.
    pause = {
        enabled = true,
        maxDays = 28,
        fee = 0,                  -- charged when the pause starts
        allowedInContract = false,
    },

    -- Promotions. Each one is applied automatically when a player starts or switches to a matching plan, and
    -- takes money off the plan price for `cycles` bills (a bundle: one purchase). Fields:
    --   id, label                 shown in the app and on the bill
    --   kind = 'percent' | 'amount' | 'free'    value = percent off / amount off (ignored for 'free')
    --   cycles = 1                how many bills it lasts
    --   plans = { 'basic' }       only these plans (omit = every plan with a price)
    --   startsAt / endsAt         'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM' (server time), either can be omitted
    --   newCustomerOnly = true    only for a SIM/account that has never had a plan
    --   code = 'LAUNCH'           only when the player types this code; not listed in the app
    --   enabled = false           switch it off without deleting it
    -- Each account can use each promotion once.
    promotions = {
        { id = 'welcome', label = 'Welcome: 50% off your first bill', kind = 'percent', value = 50,
          cycles = 1, newCustomerOnly = true },
        { id = 'launch', label = 'Launch code: first bill free', kind = 'free', cycles = 1, code = 'LAUNCH',
          enabled = false },
    },

    -- 'account' removes from a money account/balance (framework's cash/bank account below).
    -- Real carriers bill to a bank account, not physical cash, so this has no 'item' mode.
    payment = {
        account = 'bank',
        -- Auto-pay for players who are offline: the bill is charged straight to the character's bank in
        -- the database (qb-core / qbx_core `players.money`, ESX `users.accounts`), and only if they can
        -- afford it. Turn this off if your banking script keeps balances somewhere else; auto-pay then
        -- waits until the player is online.
        offlineAutoPay = true,
        -- A failed auto-pay is tried again after this many seconds.
        autoPayRetrySeconds = 3600,
    },

    -- Staff commands: /carrier help
    admin = {
        enabled = true,
        command = 'carrier',
        ace = 'group.admin',
        -- A summary posted to a Discord channel every few hours (accounts, money in, overdue, top data users).
        -- Leave url empty to switch it off. /carrier stats and /carrier dash show the same numbers in game.
        webhook = {
            url = '',
            everyHours = 24,
            username = 'Aero Mobile',
        },
    },

    -- How many days the Usage tab shows.
    usageDays = 14,
}
