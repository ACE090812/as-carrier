# as-carrier (Aero Mobile)

A Carrier / phone-plan app for sd-phone, registered through sd-phone's documented `addCustomApp` API.
It ships as its own resource with its own server logic, database tables and NUI page. Two small edits to
sd-phone (below) let it block calls, texts and data for phones with no plan or an unpaid bill; without them
the app still tracks and bills everything but nothing is cut off.

## Setup

1. Drop this folder into your resources as `as-carrier`.
2. Start order: `ensure oxmysql`, `ensure ox_lib`, `ensure sd-phone`, then `ensure as-carrier`.
3. `Config.framework` is `'auto'` (qbx_core / qb-core / es_extended, else standalone).
4. `Config.payment.account` is `'bank'`: the account Pay now and auto-pay charge.
5. Restart. The app appears in the App Store / home screen. On the first start after upgrading from the
   old version, every existing account is reset (see "Existing players" below).
6. Apply the two sd-phone edits below if you want plans to actually block service.

## How plans work

- **Players choose their own plan.** Nobody is put on a default plan. Until a player picks one, the app
  shows a "Choose your plan" screen, and (with `Config.billing.requirePlan = true`) calls, texts and data
  are blocked. Emergency and company lines always work, and nothing is metered or billed until a plan is
  chosen. The first time a phone is opened without a plan the player gets a notification pointing at the app.
- **The plan is locked for the cycle** (`Config.billing.planLock = true`). Choosing another plan doesn't
  change anything now: the switch is queued for the next bill, shown on the Overview and Plans tabs, and can
  be cancelled until then. The bill for the cycle that just ended is always for the plan the cycle was on.
  With `planLock = false` plans change immediately.
- **Plans belong to the SIM, not the character** (`Config.accountBy`). With sd-phone's SIM mode
  (`DataOwner = 'sim'`) each SIM has its own plan, usage and bill. Whoever has the SIM in their phone owes
  its bill and can pay it. Putting a different SIM in starts with no plan; the old SIM keeps its plan and any
  unpaid bill, and picks up again when it goes back in. `'character'` keeps one account per character,
  whatever SIM they use, and is only right for stock sd-phone. Do not use it while sd-phone is in SIM mode
  (the resource prints a warning if you do). `'auto'` (default) picks SIM accounts whenever sd-phone's SIM
  mode is on.
- **Usage and billing.** Included minutes / texts / data per plan, overage rates per unit after that
  (`Config.billing.plans`), a `Config.billing.cycleDays` cycle (28). Calls come from sd-phone's
  `sd-phone:server:call:ended` (rounded up to whole minutes), texts from `sd-phone:server:messages:sent`,
  data is an estimate from the app's own heartbeat while it is open on mobile data (not a byte counter).
- **Bills and suspension.** At the end of a cycle a bill is raised for the plan plus overage. Auto-pay
  (opt-in) charges the account on the due date; otherwise the player pays in the app. A bill unpaid for
  `Config.billing.graceDays` suspends the account, and paying restores it straight away. A server thread
  (`Config.billing.sweepSeconds`, 60) rolls cycles over, raises bills, auto-pays and suspends for online
  players, so it doesn't wait for the app to be opened.
- **Currency** is `Config.currency` (default `£`), used in the app and in notifications.

### Existing players

The first start after upgrading adds the plan columns and resets every existing account: everyone has to
choose a plan again, usage from the old cycle is dropped, unpaid balances are kept. Old accounts were keyed
by character; in SIM mode the new accounts are keyed by SIM, so an old unpaid balance only follows a SIM that
was character-bound (its identity is the citizenid). Everyone else starts fresh.

With `requirePlan = true`, every player is blocked from calls and texts until they pick a plan. Tell your
players before you restart.

## sd-phone edits

### `server/service.lua`: block service for a phone with no plan or a suspended bill

`as-carrier` exports `getBlockReason(key)` (`'suspended'`, `'no_plan'` or nil), a table lookup, not a query.
`service.blockedByPlan(source)` calls `exports['as-carrier']:getBlockReason(player.getIdentifier(source))`, and
`service.allows(source, capability, ignorePlan)` returns false when it is blocked unless `ignorePlan` is true.
This replaces the earlier `as_carrier` block in `service.allows`; that used the resource name `as_carrier`,
which never matched `as-carrier`, so it never blocked anything.

### `server/calls/actions.lua`: emergency and company lines still connect

`actions.dial` checks `service.allows(source, 'call', true)` (coverage only) first and the plan block
(`service.blockedByPlan`) after the emergency/company lookup, so 999 and company lines work with no plan.
`actions.callGroup` and the in-call coverage sweep (`legHasSignal`, for sessions that have `s.company`) ignore
the plan block the same way. Player-to-player calls and texts stay blocked.

### Optional: make downloads cost data too

`as-carrier` exports `tryConsumeDownloadData(source, sizeMB)` returning `{ success, message }`. In sd-phone's
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

## Events and exports

Server events: `sd_carrier:accountSuspended`, `sd_carrier:accountRestored`.
Exports: `getBlockReason(key)`, `isSuspendedCached(key)`, `tryConsumeDownloadData(source, sizeMB)`.

## Languages

Every text the script shows (phone notifications, errors and all of the app's screens) lives in
`locales/en.lua`. Set `Config.locale` to switch. To add one, copy `locales/en.lua` to `locales/<code>.lua`
(e.g. `de.lua`), translate the values only (keep the keys and the `%s` placeholders, in the same order),
change `Locales['en']` to `Locales['<code>']` and set `Config.locale = '<code>'`. Any missing key falls back to
English. Not in the locale files, because it is owner-editable text in `config.lua`: the app name and
description (`Config.app`) and the plan names (`Config.billing.plans[].label`). The month names used in dates
are one comma-separated key, `ui.months`.

## Files

- `config.lua`: language, framework, account mode, currency, payment account, app identity, plans, cycle and lock.
- `locales/en.lua`, `shared/locale.lua`: language strings and the `T()` helper.
- `server/bridge.lua`: framework detection (qb / qbx / esx / standalone) for identifiers and money.
- `server/store.lua`: MySQL persistence (`sd_carrier_accounts`, `sd_carrier_history`; its own tables). The
  `citizenid` column holds the account key (SIM identity, or a character's citizenid).
- `server/main.lua`: account lookup by SIM, the service gate, cycle rollover, invoicing, pay / auto-pay,
  usage hooks, the sweep thread.
- `client/main.lua`: registers the app with sd-phone and bridges its NUI page to the server callbacks.
- `ui/index.html`: the whole app screen (Overview, Plans, Bills, plan choice). One self-contained file,
  no build step, follows the phone's light / dark theme.
