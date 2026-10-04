CreateThread(function()
    local ok, err = exports['sd-phone']:addCustomApp({
        identifier  = Config.app.identifier,
        name        = Config.app.name,
        description = Config.app.description,
        icon        = Config.app.icon ~= '' and Config.app.icon or nil,

        ui = GetCurrentResourceName() .. '/ui/index.html',
    })
    if not ok then
        print(('[as-carrier] failed to register the Carrier app with sd-phone: %s'):format(tostring(err)))
    end
end)

RegisterNUICallback('sd_carrier/locale', function(_, cb)
    cb(LocaleDict())
end)

RegisterNUICallback('sd_carrier/config', function(_, cb)
    cb({
        dataHeartbeatSeconds = Config.billing.dataHeartbeatSeconds or 60,
        currency = Config.currency or '£',
    })
end)

-- The app's actions: each one is a server callback of the same name, called with whatever the page sends.
local ACTIONS = {
    status        = 'sd_carrier:status',
    selectPlan    = 'sd_carrier:selectPlan',
    cancelPending = 'sd_carrier:cancelPending',
    cancelService = 'sd_carrier:cancelService',
    setAutoPay    = 'sd_carrier:setAutoPay',
    payBill       = 'sd_carrier:payBill',
    topUp         = 'sd_carrier:topUp',
    buyAddon      = 'sd_carrier:buyAddon',
    pause         = 'sd_carrier:pause',
    resume        = 'sd_carrier:resume',
    dataHeartbeat = 'sd_carrier:dataHeartbeat',
}

for action, callback in pairs(ACTIONS) do
    RegisterNUICallback('sd_carrier/' .. action, function(data, cb)
        cb(lib.callback.await(callback, false, data))
    end)
end

RegisterNetEvent('sd_carrier:client:updated', function()
    SendNUIMessage({ action = 'sd_carrier:updated' })
end)
