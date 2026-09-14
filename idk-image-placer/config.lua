-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 DeeKnow of iDK Scripts

Config = {}

-- Command / keybind
Config.Command = 'placeimage'
Config.Keybind = 'nil'   -- no default bind - opt-in via FiveM's keybind settings menu

-- Permissions (FiveM ACE permissions - see server/main.lua)
-- nil/false = open to everyone. Otherwise must be a STRING ace name
-- (e.g. 'image_placer.use') - never `true`: IsPlayerAceAllowed() needs an
-- actual ace name, and boolean `true` matches no one, locking everyone out.
Config.UsePermission = false      -- who can open the tool at all
Config.AdminPermission = false    -- who sees the in-NUI Settings tab (false = everyone is "admin")

-- Example server.cfg lines:
--   add_ace group.mod image_placer.use allow
--   add_ace group.admin image_placer.admin allow
--   add_principal identifier.license:xxxx group.admin

-- Limits
Config.MaxPlacementsPerPlayer = 10     -- 0 = unlimited
Config.MaxRaycastDistance = 300.0      -- how far a corner click is allowed to reach (bumped up so distant billboards/rooftop views are clickable)

-- Defaults (admins can change these for the session from the NUI Settings tab)
Config.DefaultDrawDistance = 1000.0    -- how far away a placement stays visible
Config.MinPlacementDrawDistance = 10.0   -- clamp bounds for the per-placement custom draw
Config.MaxPlacementDrawDistance = 3000.0 -- distance option exposed in the Create/Edit panel
Config.CanvasResolution = 512          -- DUI render target size (px), higher = sharper/heavier
Config.SurfaceOffset = 0.015           -- meters, starting clearance off a clicked surface (avoids
                                        -- z-fighting/clipping). Scroll-adjustable per-corner while
                                        -- picking, from -150 to +150.

-- Only used as a fallback size by the PlaceImageAtCoords() export (the
-- interactive /placeimage tool always uses the 4 corners you click, so it
-- doesn't need a width/height).
Config.DefaultWidth = 2.0
Config.DefaultHeight = 2.0

-- Image downloading (server-side fetch, relayed to the client - see
-- README for why this can't just be a client-side HTTP/fetch call)
Config.MaxImageBytes = 6 * 1024 * 1024   -- reject downloads bigger than this (raw bytes, before base64)
Config.ImageTransferBps = 500000         -- bytes/sec used to stream the image down to the client (TriggerLatentClientEvent)

-- Security: the server fetches whatever URL a player submits, so treat it
-- like any other user-supplied-URL fetcher (see README > Security).
Config.AllowedImageDomains = {}         -- {} = allow any public host. e.g. { 'imgur.com', 'i.imgur.com', 'cdn.discordapp.com' }
Config.BlockPrivateNetworks = true      -- best-effort block of localhost/private/link-local hostnames
Config.MaxDownloadsPerMinute = 20       -- per-player download rate limit (0 = unlimited)

-- Video/GIF placements (rendered live via DUI - a real Chromium tab -
-- rather than a decoded static texture, so they can autoplay/loop)
Config.EnableVideo = true
Config.VideoExtensions = { 'mp4', 'webm', 'mov', 'm4v' }
Config.AnimatedImageExtensions = { 'gif' }

-- Misc
Config.Debug = false
