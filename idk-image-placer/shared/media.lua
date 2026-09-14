-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 DeeKnow of iDK Scripts

Media = {}

-- Lowercase file extension from a URL's path, ignoring any query string
-- or fragment. Returns nil if there isn't a recognizable one.
function Media.getExtension(url)
    if type(url) ~= 'string' then return nil end
    local pathOnly = url:match('^[^?#]+') or url
    return pathOnly:match('%.([%w]+)$')
end

local function extensionIn(url, list)
    local ext = Media.getExtension(url)
    if not ext then return false end
    ext = ext:lower()
    for _, candidate in ipairs(list or {}) do
        if ext == candidate:lower() then return true end
    end
    return false
end

function Media.isVideo(url)
    return extensionIn(url, Config.VideoExtensions)
end

function Media.isAnimatedImage(url)
    return extensionIn(url, Config.AnimatedImageExtensions)
end
