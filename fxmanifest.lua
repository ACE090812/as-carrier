fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'as-carrier'
author 'you'
description 'Standalone Carrier/phone-bill app, registered into sd-phone through its real addCustomApp API - no sd-phone core files touched.'
version '1.0.0'

-- ox_lib gives us lib.callback for the client<->server bridge (status/selectPlan/setAutoPay/
-- payBill/dataHeartbeat) - sd-phone already depends on it, so it's assumed present.
shared_script '@ox_lib/init.lua'

shared_scripts {
    'config.lua',
    'shared/locale.lua',
    'locales/*.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/bridge.lua',
    'server/store.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

-- The Carrier app's own screen: sd-phone frames this inside an iframe pointed at
-- https://cfx-nui-as-carrier/ui/index.html (see exports['sd-phone']:addCustomApp in client/main.lua)
-- - a completely separate page served by THIS resource, not sd-phone's own React app.
ui_page 'ui/index.html'
files { 'ui/**/*' }

dependencies {
    'ox_lib',
    'sd-phone',
    'oxmysql',
}