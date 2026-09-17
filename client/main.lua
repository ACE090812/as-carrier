CreateThread(function()
    local ok, err = exports['sd-phone']:addCustomApp({
        identifier  = Config.app.identifier,
        name        = Config.app.name,
        description = Config.app.description,
        icon        = Config.app.icon ~= '' and Config.app.icon or nil,

        ui = GetCurrentResourceName() .. '/ui/index.html',
    })
    if not ok then
        print(('[as_carrier] failed to register the Carrier app with sd-phone: %s'):format(tostring(err)))
    end
end)

RegisterNUICallback('as_carrier/config', function(_, cb)
    cb({ dataHeartbeatSeconds = Config.billing.dataHeartbeatSeconds or 60 })
end)

RegisterNUICallback('as_carrier/status', function(_, cb)
    cb(lib.callback.await('as_carrier:status', false))
end)

RegisterNUICallback('as_carrier/selectPlan', function(data, cb)
    cb(lib.callback.await('as_carrier:selectPlan', false, data))
end)

RegisterNUICallback('as_carrier/setAutoPay', function(data, cb)
    cb(lib.callback.await('as_carrier:setAutoPay', false, data))
end)

RegisterNUICallback('as_carrier/payBill', function(_, cb)
    cb(lib.callback.await('as_carrier:payBill', false))
end)

RegisterNUICallback('as_carrier/dataHeartbeat', function(_, cb)
    cb(lib.callback.await('as_carrier:dataHeartbeat', false))
end)

RegisterNetEvent('as_carrier:client:updated', function()
    SendNUIMessage({ action = 'as_carrier:updated' })
end)