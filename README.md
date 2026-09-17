# sd_carrier

A standalone Carrier / phone-bill app, registered into sd-phone through its real, documented
`addCustomApp` API. Nothing in sd-phone's own files is touched - this ships as its own resource
with its own server logic, its own database tables, and its own NUI page.

## Setup

1. Drop this folder into your resources as `sd_carrier`.
2. Make sure `oxmysql` and `sd-phone` are both started before it (`ensure oxmysql`, `ensure sd-phone`,
   then `ensure sd_carrier` - order matters for the `dependencies` in fxmanifest.lua to resolve).
3. `Config.framework` in `config.lua` is `'auto'` by default (detects qbx_core / qb-core /
   es_extended, falls back to standalone). Set it explicitly if you'd rather skip detection.
4. `Config.payment.account` is `'bank'` by default - the account your framework's
   `RemoveMoney`/`removeAccountMoney` charges Pay Now and auto-pay against.
5. Restart the resource. The Carrier app appears in the App Store / home screen with no other
   setup - `client/main.lua` registers it on start.

## What it does

Real pay-monthly plans (SIM Only Lite / Basic / Standard / Unlimited by default, edit
`Config.billing.plans` for your own), each with included minutes/texts/data and overage rates.
Usage is tallied through a billing cycle (`Config.billing.cycleDays`, 28 by default) from:

- **Calls** - hooks sd-phone's own `sd-phone:server:call:ended` event (fired natively for every
  call), rounding each call's duration up to the next whole minute.
- **Texts** - hooks sd-phone's own `sd-phone:server:messages:sent` event (fired natively for
  every message actually sent), one count per text.
- **Data** - a simulated heartbeat from the app's own NUI page, while it's the open, foreground
  app (`Config.billing.dataHeartbeatSeconds` / `dataPerHeartbeatMB`). This is an estimate, not a
  byte counter - same approach a lot of phone scripts use, since nothing meters what each app
  actually sends.

At the end of a cycle a bill is raised for the plan price plus any overage. Auto-pay (opt-in,
per player) tries to charge the configured account on the due date; otherwise the player pays by
hand from the app. An unpaid bill past `Config.billing.graceDays` marks the account `suspended`.

## Known limitations (both are a direct consequence of never touching sd-phone's own files)

- **Suspension doesn't block calls/texts.** sd-phone's own `server/service.lua` is the single
  gate calls and texts run through, and it has no export or event another resource can hook to
  add a condition to it. This resource tracks and displays suspension for real (the app shows
  "Service Suspended" and stops looking current), and fires `sd_carrier:accountSuspended` /
  `sd_carrier:accountRestored` server events you can listen for yourself if you want to act on
  it (e.g. from a resource that *is* willing to patch `service.lua`), but it can't enforce the
  cutoff on its own.
- **App Store downloads aren't metered against data - unless you add the one small edit below.**
  There's no public event fired around a download that a separate resource can hook, so out of
  the box `sd_carrier` only meters data from calls, texts, and the in-app heartbeat.

### Optional: make downloads cost data too

`sd_carrier` exports `tryConsumeDownloadData(source, sizeMB)` (see `server/main.lua`), matching
the exact `{ success, message }` shape sd-phone's own built-in Carrier feature uses. To wire it
up, open sd-phone's `server/apps/actions.lua` and find this line inside `actions.install`
(under the off-Wi-Fi branch):

```lua
local dataResult = billing.tryConsumeDownloadData(source, sizeMB)
```

Replace it with:

```lua
local dataResult
if util.appEnabled('billing') then
    dataResult = billing.tryConsumeDownloadData(source, sizeMB)
elseif GetResourceState('sd_carrier') == 'started' then
    local resOk, result = pcall(function()
        return exports['sd_carrier']:tryConsumeDownloadData(source, sizeMB)
    end)
    dataResult = (resOk and type(result) == 'table') and result or { success = true }
else
    dataResult = { success = true }
end
```

`util` is already imported at the top of that file (`local util = require 'server.util'`), so no
other change is needed. This uses whichever Carrier feature is actually enabled - the built-in
one, or `sd_carrier` if the built-in one is switched off in `configs/apps.lua` (`enabled = false`
on the `billing` entry) - and never double-charges when both would otherwise apply. If neither is
enabled, downloads are simply never charged against data, same as always being on Wi-Fi.

This is the one piece of sd-phone's own files this app needs touched to fully match the original
built-in feature; everything else in this README ships with zero core edits.

## Files

- `config.lua` - framework, payment account, app identity, plans and cycle timing.
- `server/bridge.lua` - framework detection (qb/qbx/esx/standalone) for identifiers and money.
- `server/store.lua` - MySQL persistence (`sd_carrier_accounts` / `sd_carrier_history` - its own
  tables, never shared with sd-phone's own schema).
- `server/main.lua` - the billing logic: cycle rollover, invoicing, pay/auto-pay, usage hooks.
- `client/main.lua` - registers the app with sd-phone and bridges its NUI page to the callbacks.
- `ui/index.html` - the app's whole screen: plan card, usage rings, account/history lists, plan
  picker. Self-contained (no build step, no framework) since it renders in its own iframe,
  separate from sd-phone's own React app.
