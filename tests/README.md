# Tests

`harness.lua` runs the real `server/core.lua`, `server/main.lua` and `server/admin.lua` against an in-memory store
and a fake framework, with a controllable clock. `core_test.lua` covers billing, promotions, prepaid, bundles,
contracts, pause, add-ons, alerts, escalation, auto-pay (online and offline), the sweep and the staff commands.

```
lua tests/core_test.lua        # from the resource folder, needs Lua 5.4 or newer
```

It exits with a non-zero status if anything fails. These files are not listed in `fxmanifest.lua`, so the game
never loads them.
