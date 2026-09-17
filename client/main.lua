CreateThread(function()
    local ok, err = exports['sd-phone']:addCustomApp({
        identifier  = Config.app.identifier,
        name        = Config.app.name,
        description = Config.app.description,
        icon        = Config.app.icon ~= '' and Config.app.icon or nil,

        ui = GetCurrentResourceName() .. '/ui/index.html',
    })
    if not ok then
        print(('[sd_carrier] failed to register the Carrier app with sd-phone: %s'):format(tostring(err)))
    end
end)

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

RegisterNUICallback('sd_carrier/dataHeartbeat', function(_, cb)
    cb(lib.callback.await('sd_carrier:dataHeartbeat', false))
end)

RegisterNetEvent('sd_carrier:client:updated', function()
    SendNUIMessage({ action = 'sd_carrier:updated' })
end)