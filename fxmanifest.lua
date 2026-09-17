fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'as-carrier'
author 'ACE Studios'
description 'Standalone Carrier/phone-bill app, registered into sd-phone through its real addCustomApp API - no sd-phone core files touched.'
version '1.0.0'

shared_script '@ox_lib/init.lua'

shared_scripts {
    'config.lua',
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

ui_page 'ui/index.html'
files { 'ui/**/*' }

dependencies {
    'ox_lib',
    'sd-phone',
    'oxmysql',
}