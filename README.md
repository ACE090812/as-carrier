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

## Known limitations (optional edits below turn both of these on)

- **Suspension doesn't block calls/texts/data - unless you add the edit below.** sd-phone's own
  `server/service.lua` is the single gate calls, texts, and data downloads run through, and out
  of the box it doesn't know this resource exists. This resource always tracks and displays
  suspension for real (the app shows "Service Suspended" and stops looking current) and fires
  `sd_carrier:accountSuspended` / `sd_carrier:accountRestored` server events either way.
- **App Store downloads aren't metered against data - unless you add the other edit below.**
  There's no public event fired around a download that a separate resource can hook, so out of
  the box `sd_carrier` only meters data from calls, texts, and the in-app heartbeat.

These are the only two pieces of sd-phone's own files this app ever needs touched; everything
else in this README ships with zero core edits.

### Optional: make suspension actually cut off service

`sd_carrier` exports `isSuspendedCached(cid)` (see `server/main.lua`) - a cheap table lookup, not
a query. To wire it up, open sd-phone's `server/service.lua` and find
`function service.allows(source, capability)`:

```lua
function service.allows(source, capability)
    if #TOWERS == 0 then return true end
    if celltowers.allows(service.levelFor(source), capability, THRESHOLDS) then return true end
    return wifiServer.provides(source, capability)
end
```

Replace it with:

```lua
function service.allows(source, capability)
    if source then
        local cid = player.getIdentifier(source)
        if cid and GetResourceState('sd_carrier') == 'started' then
            local resOk, isSuspended = pcall(function()
                return exports['sd_carrier']:isSuspendedCached(cid)
            end)
            if resOk and isSuspended then return false end
        end
    end

    if #TOWERS == 0 then return true end
    if celltowers.allows(service.levelFor(source), capability, THRESHOLDS) then return true end
    return wifiServer.provides(source, capability)
end
```

No new `require` is needed - `player` (for `player.getIdentifier`) is already required near the
top of `service.lua`.

### Optional: make downloads cost data too

`sd_carrier` exports `tryConsumeDownloadData(source, sizeMB)` (see `server/main.lua`), returning
`{ success, message }`. To wire it up, open sd-phone's `server/apps/actions.lua` and find this
line inside `actions.install` (under the off-Wi-Fi branch):

```lua
local sizeMB = tonumber(def and def.sizeMB) or 35
```

Add this right after it:

```lua
local dataResult = { success = true }
if GetResourceState('sd_carrier') == 'started' then
    local resOk, result = pcall(function()
        return exports['sd_carrier']:tryConsumeDownloadData(source, sizeMB)
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

Downloads simply aren't charged against data if `sd_carrier` isn't installed/started - same as
always being on Wi-Fi.

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