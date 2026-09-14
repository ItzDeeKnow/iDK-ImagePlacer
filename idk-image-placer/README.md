# idk_image_placer

![tests](https://github.com/DeeKnow/idk_image_placer/actions/workflows/tests.yml/badge.svg)
![license](https://img.shields.io/badge/license-GPL--3.0-blue)

Place custom images, GIFs, and video anywhere in the world as real, corner-mapped textures — signs, posters, billboards, wall art. Server-synced, persists across restarts, visible to everyone.

## Requirements

- [oxmysql](https://github.com/overextended/oxmysql) — started before this resource

## Install

1. Import the database tables:
   ```
   mysql -u your_user -p your_database < install.sql
   ```
2. Add to `server.cfg`, in this order:
   ```cfg
   ensure oxmysql
   ensure idk_image_placer
   ```

If placements aren't saving, check the server console for a MySQL error on startup — it usually means `install.sql` wasn't imported.

## Permissions

Set in `config.lua`:

```lua
Config.UsePermission = false      -- who can open the tool. false = everyone
Config.AdminPermission = false    -- who gets the admin Settings tab. false = everyone
```

To restrict access, use an ACE permission name instead of `false`:

```lua
Config.UsePermission = 'image_placer.use'
Config.AdminPermission = 'image_placer.admin'
```

```cfg
# server.cfg
add_ace group.mod image_placer.use allow
add_ace group.admin image_placer.admin allow
add_principal identifier.license:xxxxxxxx group.admin
```

## Using it

Default command/keybind: `/placeimage` (bind it under Settings > Key Bindings in-game — no default key is set).

1. Paste an image, GIF, or video URL into **Create**. Video (`.mp4`/`.webm`/`.mov`/`.m4v`) and GIFs play/loop live on the placement instead of showing a static frame.
2. Pick a mode:
   - **Straight** (recommended) — click one point to anchor, then size it with the Width/Height/Rotation sliders. Always comes out level.
   - **Freeform** — click all 4 corners yourself, for angled or irregular shapes.
3. **Start placing** — your cursor is free, WASD still works. Click to place points, right-click/Backspace to undo, Esc to cancel.
4. Set opacity and (optionally) a custom draw distance, then **Place image**.
5. **Manage** lists every placement with a thumbnail, who placed it, opacity control, locate/waypoint, edit, and remove. Editing reopens in Straight mode, prefilled from the current shape.

Players can only edit or remove their own placements unless they're an admin.

## Admin tab

Anyone who passes `Config.AdminPermission` gets a **Settings** tab with:

- **Limits** — max placements per player, max click distance, default draw distance. Applies live to everyone; **Save as server default** persists it.
- **Moderation** — grant or revoke a connected player's use/admin access for the session, without touching `server.cfg`.
- **Bulk removal** — remove everything by a specific player, or everything older than N days.

## Security

Static images are downloaded server-side (the game client can't do arbitrary HTTP fetches), which means the server is fetching whatever URL a player submits. That's hardened by default:

- **Scheme + host checks** on every submitted URL, before the server ever requests it.
- **Private network blocking** (`Config.BlockPrivateNetworks`, on by default) — best-effort blocking of `localhost`, loopback, and private/link-local address ranges, so a placement URL can't be used to probe your own server's internal network. This is a hostname/IP-literal pattern check, not a DNS-level guarantee — it doesn't defend against DNS rebinding. For anything stronger, pair it with a domain allowlist.
- **Domain allowlist** (`Config.AllowedImageDomains`) — optional; leave empty to allow any public host, or lock it down to specific CDNs (imgur, Discord, your own asset host, etc.).
- **Per-player rate limiting** (`Config.MaxDownloadsPerMinute`) — stops the server being used as an open image-download proxy.

Video and GIF URLs are loaded directly by the player's own game client (a real browser instance), not proxied through the server, so they aren't subject to the download pipeline above — but they still go through the same scheme/host/allowlist checks before a placement is allowed to be created at all.

## Testing

The placement math (`shared/geometry.lua`) has a `busted` regression suite covering the anchor-mode construction/derivation round trip across a range of surface angles and rotations — the exact class of bug that used to cause placements to come out mirrored or rotated. Runs automatically on every push via GitHub Actions.

To run it locally:

```bash
luarocks install busted
busted
```

## Exports

For other resources to place images programmatically (these don't go through the server sync used by `/placeimage`):

```lua
-- pin an image to 4 world-space corners, in order around the quad
local id = exports.idk_image_placer:PlaceImageAtCorners({
    { x = 100.0, y = 200.0, z = 30.0 },
    { x = 103.0, y = 200.0, z = 30.0 },
    { x = 103.0, y = 200.0, z = 28.0 },
    { x = 100.0, y = 200.0, z = 28.0 }
}, imageUrl, { alpha = 255, maxDrawDistance = 100.0 })

-- or a simple centered quad
local id2 = exports.idk_image_placer:PlaceImageAtCoords(x, y, z, imageUrl, {
    width = 2.0,
    height = 2.0,
    normal = { x = 0.0, y = 1.0, z = 0.0 },
    alpha = 255
})

exports.idk_image_placer:RemoveImagePlacement(id)
exports.idk_image_placer:RemoveAllImagePlacements()
exports.idk_image_placer:GetActivePlacements() -- { id, corners, imageUrl }[]
```

## Config reference

```lua
Config.Command = 'placeimage'
Config.Keybind = 'nil'                 -- set a default key, or leave players to bind their own
Config.MaxPlacementsPerPlayer = 10      -- 0 = unlimited
Config.MaxRaycastDistance = 300.0       -- max distance a corner click can reach
Config.DefaultDrawDistance = 1000.0     -- default view distance for placements
Config.CanvasResolution = 512           -- fallback render resolution; higher = sharper, more VRAM
Config.SurfaceOffset = 0.015            -- meters off a surface, prevents z-fighting
Config.DefaultWidth = 2.0               -- fallback size for PlaceImageAtCoords only
Config.DefaultHeight = 2.0
Config.MaxImageBytes = 6 * 1024 * 1024  -- reject downloads larger than this
Config.ImageTransferBps = 500000        -- streaming rate down to the client

Config.AllowedImageDomains = {}         -- {} = allow any public host
Config.BlockPrivateNetworks = true
Config.MaxDownloadsPerMinute = 20       -- 0 = unlimited

Config.EnableVideo = true
Config.VideoExtensions = { 'mp4', 'webm', 'mov', 'm4v' }
Config.AnimatedImageExtensions = { 'gif' }

Config.Debug = false
```

## License

GPL-3.0 — see `LICENSE`. Free to use, modify, and redistribute; modified versions distributed to others must stay open source under the same license.
