fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'idk_image_placer'
author 'DeeKnow of iDK Scripts'
description 'Realtime image overlay tool for in-game signs/props - click 4 corners, image fits between them'
version '2.0.0'

dependency 'oxmysql'

shared_scripts {
    'config.lua'
}

client_scripts {
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'html/canvas.html',
    'html/normalize.html'
}

-- exports for other resources to trigger placement programmatically
exports {
    'PlaceImageAtCorners',
    'PlaceImageAtCoords',
    'RemoveImagePlacement',
    'RemoveAllImagePlacements',
    'GetActivePlacements'
}
