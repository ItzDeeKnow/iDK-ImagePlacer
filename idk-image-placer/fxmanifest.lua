fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'idk_image_placer'
author 'DeeKnow of iDK Scripts'
description 'Place images, GIFs, and video on any surface as real corner-pinned textures - MySQL persistence, admin tools, built-in security hardening'
version '2.1.0'

dependency 'oxmysql'

shared_scripts {
    'config.lua',
    'shared/media.lua',
    'shared/geometry.lua'
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
    'html/normalize.html',
    'html/video.html'
}

-- exports for other resources to trigger placement programmatically
exports {
    'PlaceImageAtCorners',
    'PlaceImageAtCoords',
    'RemoveImagePlacement',
    'RemoveAllImagePlacements',
    'GetActivePlacements'
}
