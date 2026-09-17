-- Registers the Carrier app with sd-phone's real, documented custom-app API
-- (exports['sd-phone']:addCustomApp) and bridges its own NUI page to the server callbacks above.
-- sd-phone frames ui/index.html in an iframe on its own origin (https://cfx-nui-sd_carrier/...) -
-- a completely separate page from sd-phone's own React app, so nothing here can reach into or
-- rely on sd-phone's internal UI code, only its public exports/events.

CreateThread(function()
    local ok, err = exports['sd-phone']:addCustomApp({
        identifier  = Config.app.identifier,
        name        = Config.app.name,
        description = Config.app.description,
        icon        = Config.app.icon ~= '' and Config.app.icon or nil,
        -- ui/index.html handles its own visibility per sd-phone's documented custom-app contract:
        -- html/body stay visibility:hidden until the page itself receives the 'componentsLoaded'
        -- message sd-phone posts only once it has actually framed this file inside the app view -
        -- that's what keeps it from appearing just because the resource (and its ui_page) started.
        ui = GetCurrentResourceName() .. '/ui/index.html',
    })
    if not ok then
        print(('[sd_carrier] failed to register the Carrier app with sd-phone: %s'):format(tostring(err)))
    end
end)

-- So the NUI page's data-heartbeat interval always matches config.lua without hardcoding the
-- number twice (once here, once in ui/index.html).
RegisterNUICallback('sd_carrier/config', function(_, cb)
    cb({ dataHeartbeatSeconds = Config.billing.dataHeartbeatSeconds or 60 })
end)

RegisterNUICallback('sd_carrier/status', function(_, cb)
    cb(lib.callback.await('sd_carrier:status', false))
end)

RegisterNUICallback('sd_carrier/selectPlan', function(data, cb)
    cb(lib.callback.await('sd_carrier:selectPlan', false, data))
end)

RegisterNUICallback('sd_carrier/setAutoPay', function(data, cb)
    cb(lib.callback.await('sd_carrier:setAutoPay', false, data))
end)

RegisterNUICallback('sd_carrier/payBill', function(_, cb)
    cb(lib.callback.await('sd_carrier:payBill', false))
end)

-- Simulated cellular data usage: only while the phone is actually open on this app, unlocked, and
-- not on Wi-Fi - sd-phone has no export exposing live Wi-Fi/phone-open state to a third-party
-- resource, so this asks the NUI page itself (it already knows whether it's the foreground app)
-- rather than guessing from here. See config.lua's dataHeartbeatSeconds/dataPerHeartbeatMB.
RegisterNUICallback('sd_carrier/dataHeartbeat', function(_, cb)
    cb(lib.callback.await('sd_carrier:dataHeartbeat', false))
end)

RegisterNetEvent('sd_carrier:client:updated', function()
    SendNUIMessage({ action = 'sd_carrier:updated' })
end)
