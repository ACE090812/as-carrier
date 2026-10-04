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
    setAutoTopUp  = 'sd_carrier:setAutoTopUp',
    sendReceipt   = 'sd_carrier:sendReceipt',
}

for action, callback in pairs(ACTIONS) do
    RegisterNUICallback('sd_carrier/' .. action, function(data, cb)
        cb(lib.callback.await(callback, false, data))
    end)
end

RegisterNetEvent('sd_carrier:client:updated', function()
    SendNUIMessage({ action = 'sd_carrier:updated' })
end)

-- Mobile data use. Same rule as sd-phone's own meter: a ping every interval while the phone is open, NOT on Wi-Fi
-- (Wi-Fi is free) and with cell data available. It runs whether or not the Carrier app is open. The server counts
-- the ping (and refuses it while it knows the phone is closed or when pings come too fast).
CreateThread(function()
    local every = math.max(15, tonumber(Config.billing.dataHeartbeatSeconds) or 60) * 1000
    while true do
        Wait(every)
        local ok, open, wifi, data = pcall(function()
            local sd = exports['sd-phone']
            return sd:isOpen() == true, sd:isOnWifi() == true, sd:hasService('data') == true
        end)
        if ok and open and not wifi and data then
            lib.callback.await('sd_carrier:dataHeartbeat', false)
        end
    end
end)

-- /carrier dash: the staff dashboard as a menu.
RegisterNetEvent('sd_carrier:client:dash', function(payload)
    if type(payload) ~= 'table' or type(payload.lines) ~= 'table' then return end
    local options = {}
    for i, line in ipairs(payload.lines) do
        local label, value = tostring(line):match('^([^:]+):%s*(.+)$')
        options[i] = { title = label or tostring(line), description = value, readOnly = true }
    end
    lib.registerContext({ id = 'sd_carrier_dash', title = payload.title or 'Aero Mobile', options = options })
    lib.showContext('sd_carrier_dash')
end)
