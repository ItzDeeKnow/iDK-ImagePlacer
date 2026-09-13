# idk_image_placer

Place custom images anywhere in the world as real, corner-mapped textures — signs, posters, billboards, wall art. Server-synced, persists across restarts, visible to everyone.

## Video Preview
- https://streamable.com/z37pr7
- https://streamable.com/go1b16

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

1. Paste an image URL into **Create**.
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
Config.Debug = false
```
