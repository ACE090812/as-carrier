# as-carrier (Aero Mobile)

A Carrier / phone-plan app for sd-phone, registered through sd-phone's documented `addCustomApp` API.
It ships as its own resource with its own server logic, database tables and NUI page. Two small edits to
sd-phone (below) let it block calls, texts and data for phones with no plan, an unpaid bill, a paused plan or
no credit; without them the app still tracks and bills everything but nothing is cut off.

## Setup

1. Drop this folder into your resources as `as-carrier`.
2. Start order: `ensure oxmysql`, `ensure ox_lib`, `ensure sd-phone`, then `ensure as-carrier`.
3. `Config.framework` is `'auto'` (qbx_core / qb-core / es_extended, else standalone).
4. `Config.payment.account` is `'bank'`: the account Pay now, top-ups, add-ons and auto-pay charge.
5. Restart. The app appears in the App Store / home screen. Tables are created and upgraded on start (see
   "Upgrading" below).
6. Apply the two sd-phone edits below if you want plans to actually block service.
7. Give your staff the ACE permission for `/carrier` (default `group.admin`, see "Staff commands").

## Plan types

Everything is set in `Config.billing.plans`.

| Type | How it works |
| --- | --- |
| **Monthly** (default) | Billed at the end of every cycle: plan price plus any extra minutes / texts / data. Add `contractCycles = 6` to make it a contract. |
| **Pay as you go** (`type = 'payg'`) | Prepaid, no bill, no price. Calls, texts and data are taken from the player's credit at the `overagePer*` rates. No credit means no service. |
| **Bundle** (`type = 'bundle'`, `durationDays`, `price`) | Prepaid. Bought from credit, runs for a fixed time. Anything used past the bundle comes out of credit at the `overagePer*` rates. When it ends service stops (to the second) unless the player has **auto-renew** on and enough credit. |

`minutes` / `texts` / `dataMB` = `-1` means unlimited. Three example plans (contract, pay as you go, bundle) ship
in the config; delete or edit them freely.

## How plans work

- **Players choose their own plan.** Nobody is put on a default plan. Until a player picks one, the app
  shows a "Choose your plan" screen, and (with `Config.billing.requirePlan = true`) calls, texts and data
  are blocked. Emergency and company lines always work, and nothing is metered or billed until a plan is
  chosen. The first time a phone is opened without a plan the player gets a notification pointing at the app.
- **The plan is locked for the cycle** (`Config.billing.planLock = true`). Choosing another plan doesn't
  change anything now: the switch is queued for the next bill, shown on the Overview and Plans tabs, and can be
  cancelled until then. The bill for the cycle that just ended is always for the plan the cycle was on. With
  `planLock = false` plans change immediately. Prepaid plans are never locked. A queued switch to a bundle is
  bought from credit when the switch happens (if there is not enough, the account is "ended" until it is bought).
- **Plans belong to the SIM, not the character** (`Config.accountBy`). With sd-phone's SIM mode
  (`DataOwner = 'sim'`) each SIM has its own plan, usage, credit and bill. Whoever has the SIM in their phone
  owes its bill and can pay it. Putting a different SIM in starts with no plan; the old SIM keeps its plan and any
  unpaid bill, and picks up again when it goes back in. `'character'` keeps one account per character,
  whatever SIM they use, and is only right for stock sd-phone. Do not use it while sd-phone is in SIM mode
  (the resource prints a warning if you do). `'auto'` (default) picks SIM accounts whenever sd-phone's SIM
  mode is on.
- **Usage and billing.** Included minutes / texts / data per plan, overage rates per unit after that, a
  `Config.billing.cycleDays` cycle (28). Calls come from sd-phone's `sd-phone:server:call:ended` (rounded up to
  whole minutes, both people on the call are metered), texts from `sd-phone:server:messages:sent`, data is an
  estimate from the app's own heartbeat while it is open on mobile data (not a byte counter).
- **Currency** is `Config.currency` (default `£`), used in the app and in notifications.

### When the data runs out (`Config.billing.outOfData`)

Per server, or per plan with `outOfData = '...'` on the plan:

- `'bill'` (default): data keeps working and the extra MB are billed (monthly) or taken from credit (prepaid).
- `'throttle'`: data keeps working at reduced speed and nothing extra is billed, so there are no surprise bills.
  sd-phone is told through `getDataState` / the download hook (see "Exports"); the app shows a banner.
- `'block'`: data stops until the next cycle (or until an add-on is bought). Nothing extra is billed.

### Data add-ons (`Config.billing.addons`)

Players buy extra MB for the current cycle ("Add data" on the Overview and Plans tabs). Monthly players pay from
the bank straight away, prepaid players from credit. Unused add-on MB expire at the end of the cycle unless
`carryOver = true`. Unlimited-data plans don't offer them.

### Prepaid credit (`Config.prepaid`)

"Top up" adds credit from the bank (`min`, `max` and the quick-pick `presets` are in the config). Credit is used by
pay-as-you-go plans, bundle purchases and renewals, usage past a bundle, and add-ons for prepaid players. Warnings
go out at `Config.billing.alerts.lowCredit` and at zero. Other scripts can add credit with the `addCredit` export
(for a shop that sells top-up cards).

### Contracts (`contractCycles` on a plan, `Config.contract`)

A contract plan locks the player in for `contractCycles` cycles. Leaving early (switching plan or cancelling)
costs `feeRate` of the plan fees still to run, at least `minFee` and at most `maxFee`. The app shows the fee and the
player confirms; the fee is charged to the bank, the open cycle is billed straight away and the change starts
now. Moving to a dearer plan (`upgradesFree`) is free and queues like a normal switch.

### Pause and cancel

- **Pause** (`Config.pause`, monthly plans only): service is switched off (emergency and company lines still work),
  nothing is metered or billed, and the cycle (and any contract) picks up where it stopped. It ends by itself after
  the chosen number of days (up to `maxDays`) or when the player resumes. Not while a bill is outstanding, and not
  in a contract unless `allowedInContract`.
- **Cancel service**: a monthly plan ends at the end of the cycle (or straight away with `planLock = false`, or
  after the early-exit fee in a contract). A prepaid plan ends now and the credit stays on the SIM.

### Promotions (`Config.promotions`)

Automatic discounts on the plan price, shown in the app as a green offer on the plan card and as a line on the
bill. Each one can be limited to plans, a date window (`startsAt` / `endsAt`), new customers only, or a promo
code the player types in. Discounts last `cycles` bills (a bundle: one purchase). Each account can use each
promotion once. Staff can hand one out with `/carrier promo`. Two examples ship in the config.

### Bills, late fees and escalation

At the end of a cycle a bill is raised for the plan plus overage (minus any promotion), with the lines saved
so the Bills tab and receipts can show them. Auto-pay (opt-in) charges the account on the due date; otherwise the
player pays in the app. An unpaid bill then escalates, with the clock starting when it was raised:

1. `lateFee.afterDays`: a one-off late fee (flat `amount` plus `percent` of the balance) is added.
2. `limitedAfterDays`: **limited**, mobile data is switched off, calls and texts still work.
3. `suspendReminderHours` before the end: a reminder notification.
4. `graceDays`: **suspended**, calls, texts and data off. Paying restores service straight away.

Auto-pay that fails (not enough money) tells the player and is retried every
`Config.payment.autoPayRetrySeconds`.

### Usage alerts (`Config.billing.alerts`)

Phone notifications at two thresholds (default 80% and 100%) of the minutes, texts and data allowance, a special
message at 100% that says what happens next (extra billed, slowed, or off), and low / no credit warnings for
prepaid.

### The app

Overview (plan, allowances, credit, banners), Plans (change plan, add data, top up, pause, cancel), **Usage**
(daily chart for data, minutes or texts, with today, daily average and busiest day) and Bills (every bill, fee,
top-up, add-on and bundle). Tap an entry for its lines and **View receipt**: a receipt you can copy, or download as
a text file (downloads depend on the NUI browser; Copy always works).

### Billing offline players

A server thread (`Config.billing.sweepSeconds`, 60) runs one query that finds the accounts that need attention
(a cycle or bundle that ended, an unpaid bill, a pause that is over) and handles them whether the player is online
or not: rolls the cycle, raises the bill, applies late fees, escalates, renews bundles and auto-pays.

Auto-pay for a player who is **offline** is charged straight to their bank in the database: `players.money`
(qb-core / qbx_core) or `users.accounts` (ESX), only if they can afford it. Each account remembers which character
last used it (the "payer"). **If your banking script keeps balances somewhere else** (a separate bank table), set
`Config.payment.offlineAutoPay = false`: auto-pay then waits until the payer is online.

Usage is held in memory and written to the database in batches (`Config.billing.flushSeconds`, 15); it is also
written when a player leaves and when the resource stops. A crash can lose up to that many seconds of usage.

## Staff commands

`/carrier help` (from the console or in game; needs the ACE `Config.admin.ace`, default `group.admin`).
`<target>` is a server id, a SIM phone number or an account key (a citizenid, or `sim:<number>`).

| Command | Does |
| --- | --- |
| `/carrier info <target>` | Plan, status, usage, balance, credit, contract, promotion |
| `/carrier setplan <target> <planId>` | Put them on a plan now (a bundle is free) |
| `/carrier unplan <target>` | Back to "no plan" |
| `/carrier credit <target> <amount>` | Add or remove (negative) prepaid credit |
| `/carrier adddata <target> <mb>` | Add or remove add-on MB for this cycle |
| `/carrier clearbill <target>` | Waive what they owe |
| `/carrier suspend <target>` / `restore <target>` | Cut service / lift it (restore re-starts the grace period if they still owe) |
| `/carrier resetusage <target>` | Zero this cycle's usage |
| `/carrier promo <target> <promoId>` | Give a promotion from the config |

Every change is logged to the server console and to the `sd_carrier_audit` table.

## Upgrading

Tables keep their names (`sd_carrier_accounts`, `sd_carrier_history`) and are brought up to date column by column
on start, so an existing database keeps working. New: `sd_carrier_usage_daily` (the usage chart) and
`sd_carrier_audit` (staff actions). Existing bills keep their amounts; bills from before line items existed show a
plan line and an "extras" line.

- Coming from the very first release (no `plan_chosen` column): every existing account is reset once, everyone
  has to choose a plan again, usage from the old cycle is dropped, unpaid balances are kept.
- Everyone who already has an account counts as an existing customer, so "new customer" promotions are not for them.
- Old accounts were keyed by character; in SIM mode the new accounts are keyed by SIM, so an old unpaid balance only
  follows a SIM that was character-bound (its identity is the citizenid). Everyone else starts fresh.
- With `requirePlan = true`, every player is blocked from calls and texts until they pick a plan. Tell your
  players before you restart.
- Behaviour change: with the default `outOfData = 'bill'`, downloads past the data cap are now allowed and billed
  as overage (before, they were refused while the same data was being billed). Use `'block'` for the old refusal.
- The new texts are in `locales/en.lua`. The other language files don't have them yet, so those players see English
  for the new screens until the files are translated (missing keys fall back to English).

## sd-phone edits

### `server/service.lua`: block service for a phone with no plan, a late bill, a pause or no credit

`as-carrier` exports `getBlockReason(key, capability)`, a table lookup, not a query. It returns `'suspended'`,
`'no_plan'`, `'paused'`, `'expired'`, `'no_credit'`, `'limited'` or nil. `'limited'` is only returned for the
capability `'data'`: the player's bill is late, so mobile data is off while calls and texts still work.
`service.blockedByPlan(source, capability)` calls
`exports['as-carrier']:getBlockReason(player.getIdentifier(source), capability)`, and
`service.allows(source, capability, ignorePlan)` returns false when it is blocked unless `ignorePlan` is true.
Pass the `capability` through: without it the limited step is ignored (everything else works as before, and any new
reason simply blocks). This replaces the earlier `as_carrier` block in `service.allows`; that used the resource name
`as_carrier`, which never matched `as-carrier`, so it never blocked anything.

### `server/calls/actions.lua`: emergency and company lines still connect

`actions.dial` checks `service.allows(source, 'call', true)` (coverage only) first and the plan block
(`service.blockedByPlan`) after the emergency/company lookup, so 999 and company lines work with no plan.
`actions.callGroup` and the in-call coverage sweep (`legHasSignal`, for sessions that have `s.company`) ignore
the plan block the same way. Player-to-player calls and texts stay blocked.

### Optional: make downloads cost data too

`as-carrier` exports `tryConsumeDownloadData(source, sizeMB)` returning `{ success, message, throttled }`. In sd-phone's
`server/apps/actions.lua`, inside `actions.install` (the off-Wi-Fi branch), right after
`local sizeMB = tonumber(def and def.sizeMB) or 35`, add:

```lua
local dataResult = { success = true }
if GetResourceState('as-carrier') == 'started' then
    local resOk, result = pcall(function()
        return exports['as-carrier']:tryConsumeDownloadData(source, sizeMB)
    end)
    dataResult = (resOk and type(result) == 'table') and result or { success = true }
end

if not dataResult.success then
    TriggerClientEvent('sd-phone:client:notify', source, {
        app = 'carrier', appId = 'carrier',
        title = 'Out of Data',
        body  = dataResult.message,
        time  = 'now',
    })
    return dataResult
end
```

When `throttled` is true the player is past their data allowance on a `'throttle'` plan and `message` says so; the
download still succeeds. If you want to slow it down, do that where the download progress is simulated (the speed is
up to you, the carrier only reports the state).

## Events and exports

Server events: `sd_carrier:accountSuspended`, `sd_carrier:accountRestored` (with the account key).
Exports:

- `getBlockReason(key, capability)`, `isSuspendedCached(key)`: the service gate (above).
- `tryConsumeDownloadData(source, sizeMB)`: the download hook (above).
- `getDataState(source)`: `'ok'`, `'throttled'` or `'blocked'` for a player's mobile data.
- `addCredit(key, amount)`: add (or remove, negative) prepaid credit; `getCredit(key)`.

## Languages

Every text the script shows (phone notifications, errors and all of the app's screens) lives in
`locales/en.lua`. Set `Config.locale` to switch. To add one, copy `locales/en.lua` to `locales/<code>.lua`
(e.g. `de.lua`), translate the values only (keep the keys and the `%s` placeholders, in the same order),
change `Locales['en']` to `Locales['<code>']` and set `Config.locale = '<code>'`. Any missing key falls back to
English. Not in the locale files, because it is owner-editable text in `config.lua`: the app name and
description (`Config.app`), the plan names (`Config.billing.plans[].label`), add-on and promotion labels. The month
names used in dates are one comma-separated key, `ui.months`.

## Files

- `config.lua`: language, framework, account mode, currency, payment, app identity, plans, add-ons, prepaid,
  contracts, pause, promotions, billing rules, staff commands.
- `locales/en.lua`, `shared/locale.lua`: language strings and the `T()` helper.
- `server/bridge.lua`: framework detection (qb / qbx / esx / standalone) for identifiers and money, including
  charging an offline character's bank.
- `server/store.lua`: MySQL persistence (`sd_carrier_accounts`, `sd_carrier_history`, `sd_carrier_usage_daily`,
  `sd_carrier_audit`) and schema upgrades. The `citizenid` column holds the account key (SIM identity, or a
  character's citizenid).
- `server/core.lua`: the engine: in-memory accounts with batched saving, the service gate, usage and alerts, billing,
  escalation, plan changes, contracts, pause, top-ups, add-ons, promotions.
- `server/main.lua`: the app's callbacks, sd-phone events, the sweep and flush threads, exports.
- `server/admin.lua`: the `/carrier` staff commands.
- `client/main.lua`: registers the app with sd-phone and bridges its NUI page to the server callbacks.
- `ui/index.html`: the whole app screen. One self-contained file, no build step, follows the phone's light / dark
  theme.
- `tests/`: a test harness that runs the real server scripts against an in-memory store (plain Lua 5.4:
  `lua tests/core_test.lua` from this folder). Not loaded by the game.

## Known limits

- Data use is an estimate from a heartbeat the app sends while it is open on mobile data. The server rate-limits it,
  but a modified client can still stay silent.
- The receipt "Download" button depends on the game's NUI browser allowing file downloads; Copy always works.
- Offline auto-pay edits the framework's own money columns directly, see "Billing offline players".
