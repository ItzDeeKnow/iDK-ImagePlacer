--[[
    idk_image_placer - realtime world-space image overlay, corner-pinned

    SPDX-License-Identifier: GPL-3.0-or-later
    Copyright (C) 2026 DeeKnow of iDK Scripts

    Click up to 4 points in the world (corners of a window, sign, etc.) via
    screen-to-world raycast, preview a ghost quad while picking, then render
    the image as a real textured quad pinned to those 4 points - depth-tested
    against the world like any other geometry, fitting angled/uneven surfaces.

    Placements made through /placeimage are server-authoritative (id assigned
    by MySQL, stored, broadcast to every player, persists across restarts -
    see server/main.lua). PlaceImageAtCorners/PlaceImageAtCoords exports stay
    local/client-side for other resources to call programmatically.

    Pure overlay - doesn't modify any map/prop.
]]

local placements = {}          -- [id] = placement table (see addPlacement)

-- Server-synced placements use positive ids from MySQL. Local export
-- placements (PlaceImageAtCorners/PlaceImageAtCoords) never touch the
-- server, so they count down from -1 to keep the id spaces disjoint.
local placementIdCounter = 0

local nuiOpen = false
local isAdmin = false
local closeNui -- forward-declared, used by net event handlers above its assignment
local getActiveCamPosRot -- forward-declared, used by orderQuadCorners above its assignment

-- session-tunable defaults (admins can adjust these from the NUI Settings tab;
-- everyone else just inherits whatever an admin has set, or the config defaults)
local sessionConfig = {
    maxPlacementsPerPlayer = Config.MaxPlacementsPerPlayer,
    maxRaycastDistance = Config.MaxRaycastDistance,
    defaultDrawDistance = Config.DefaultDrawDistance,
    minPlacementDrawDistance = Config.MinPlacementDrawDistance,
    maxPlacementDrawDistance = Config.MaxPlacementDrawDistance,
    canvasResolution = Config.CanvasResolution
}

---------------------------------------------------------------------
-- Utility
---------------------------------------------------------------------

local function notify(msg)
    SetNotificationTextEntry('STRING')
    AddTextComponentString(msg)
    DrawNotification(false, false)
end

local normalizeVec = Geometry.normalizeVec
local crossVec = Geometry.crossVec
local averageVec3 = Geometry.averageVec3
local computeQuadNormal = Geometry.computeQuadNormal

-- Sets corners/center/normal/maxDrawDistanceSq once, so the draw loop
-- doesn't recompute the normal or a distance-culling sqrt every frame.
local function setPlacementGeometry(p, corners, maxDrawDistance)
    p.corners = corners
    p.center = averageVec3(corners)
    p.normal = computeQuadNormal(corners)
    if maxDrawDistance then
        p.maxDrawDistance = maxDrawDistance
        p.maxDrawDistanceSq = maxDrawDistance * maxDrawDistance
    end
end

-- Sorts a set of (roughly coplanar) points into perimeter order around
-- their centroid, regardless of click order. Otherwise 4 corners clicked
-- out of walking order (crossing the diagonal instead of an edge) build
-- self-intersecting triangles - a thin sliver stretched across the
-- texture instead of a clean quad. Only meaningful for freeform mode;
-- anchor mode's corners are already built in valid order.
local function orderQuadCorners(pts)
    local centroid = averageVec3(pts)

    -- Newell's method: stable normal/winding no matter which corner was
    -- clicked first or which direction the click order went around.
    local n = #pts
    local normal = vector3(0.0, 0.0, 0.0)
    for i = 1, n do
        local a = pts[i] - centroid
        local b = pts[(i % n) + 1] - centroid
        normal = normal + crossVec(a, b)
    end
    if #normal < 0.0001 then
        normal = vector3(0.0, 0.0, 1.0) -- degenerate (e.g. collinear points), still yields a stable order
    end
    normal = normalizeVec(normal)

    -- Geometry alone can't tell which side of the quad is "front" - pin
    -- the normal toward whichever side the camera is currently on.
    local camPos = getActiveCamPosRot()
    local towardCam = camPos - centroid
    if (normal.x * towardCam.x + normal.y * towardCam.y + normal.z * towardCam.z) < 0.0 then
        normal = normal * -1.0
    end

    local worldUp = vector3(0.0, 0.0, 1.0)
    local right = crossVec(normal, worldUp)
    if #right < 0.0001 then right = crossVec(normal, vector3(1.0, 0.0, 0.0)) end
    right = normalizeVec(right)
    local up = normalizeVec(crossVec(normal, right))

    local withAngles = {}
    for i, p in ipairs(pts) do
        local d = p - centroid
        local u = d.x * right.x + d.y * right.y + d.z * right.z
        local v = d.x * up.x + d.y * up.y + d.z * up.z
        withAngles[i] = { point = p, angle = math.atan(v, u), originalIndex = i }
    end
    table.sort(withAngles, function(a, b) return a.angle < b.angle end)

    -- rotate the sorted loop so the first point actually clicked stays the
    -- visual anchor (keeps "first corner = top-left of the image" intuitive
    -- instead of the mapping jumping around depending on click order)
    local startPos = 1
    for i, e in ipairs(withAngles) do
        if e.originalIndex == 1 then
            startPos = i
            break
        end
    end

    local n = #pts
    local ordered = {}
    for i = 0, n - 1 do
        ordered[i + 1] = withAngles[((startPos - 1 + i) % n) + 1].point
    end
    return ordered
end

-- Builds a straight rectangle (parallel edges, square corners) from an
-- anchor point + surface normal + width/height, so it's always level on a
-- normal wall. `right`/`up` come from the normal and world-up. `rotationDeg`
-- optionally rolls right/up around the normal, e.g. for floor decals.
--
-- Pure math - lives in shared/geometry.lua so it's unit-testable outside
-- the game (see tests/geometry_spec.lua).
local computeAnchorCorners = Geometry.computeAnchorCorners

-- Inverse of the above: given an existing (possibly crooked/freeform)
-- quad, derives the anchor/normal/width/height/rotation of the closest
-- straight rectangle, so re-opening it in anchor mode starts straightened.
local deriveAnchorFromCorners = Geometry.deriveAnchorFromCorners

---------------------------------------------------------------------
-- Camera math: turn an arbitrary screen point into a world ray. No native
-- hands you "the ray under the cursor" directly, so this nudges the
-- camera yaw/pitch to get screen-aligned right/up vectors, then calibrates
-- against GetScreenCoordFromWorldCoord samples to solve for an arbitrary
-- screen coordinate.
---------------------------------------------------------------------

-- GetGameplayCamCoord/Rot track the normal follow/aim camera attached to
-- the ped. NoClip/freecam tools use their own script camera instead
-- (RenderScriptCams(true)) without moving the gameplay cam, so reading it
-- directly would throw corner picks off by however far you've flown away.
-- This resolves whichever camera is actually on screen and uses that.
getActiveCamPosRot = function()
    local renderCam = GetRenderingCam()
    if renderCam ~= -1 and renderCam ~= 0 and DoesCamExist(renderCam) and IsCamActive(renderCam) then
        return GetCamCoord(renderCam), GetCamRot(renderCam, 2)
    end
    return GetGameplayCamCoord(), GetGameplayCamRot(2)
end

local function eulerToForward(rot)
    local rx = math.rad(rot.x)
    local rz = math.rad(rot.z)
    return vector3(
        -math.sin(rz) * math.abs(math.cos(rx)),
         math.cos(rz) * math.abs(math.cos(rx)),
         math.sin(rx)
    )
end

local function cameraScreenBasis(camRot)
    local yawStep = eulerToForward(vector3(camRot.x, camRot.y, camRot.z + 10.0))
                  - eulerToForward(vector3(camRot.x, camRot.y, camRot.z - 10.0))
    local pitchStep = eulerToForward(vector3(camRot.x + 10.0, camRot.y, camRot.z))
                     - eulerToForward(vector3(camRot.x - 10.0, camRot.y, camRot.z))

    return normalizeVec(yawStep), normalizeVec(pitchStep)
end

-- nx, ny: normalized screen coords, 0-1, origin top-left (matches
-- GetScreenCoordFromWorldCoord).
--
-- A single global calibration sample introduces a consistent skew since
-- our right/up basis doesn't perfectly match the game's camera/roll model.
-- Instead this iterates: probe right/up from the current best-guess point,
-- measure the real screen response via GetScreenCoordFromWorldCoord, solve
-- the local 2x2 system, step toward the target, repeat. Converges in a
-- handful of iterations.
local function screenToWorldDirection(nx, ny)
    local camPos, camRot = getActiveCamPosRot()
    local forward = eulerToForward(camRot)
    local right, up = cameraScreenBasis(camRot)

    local probeDist = 10.0
    local guessPoint = camPos + forward * probeDist
    local step = 0.25 -- small probe offset for the local derivative, in world units

    for _ = 1, 5 do
        local okC, cx, cy = GetScreenCoordFromWorldCoord(guessPoint.x, guessPoint.y, guessPoint.z)
        if not okC then break end

        local rp = guessPoint + right * step
        local up_ = guessPoint + up * step
        local okR, rx, ry = GetScreenCoordFromWorldCoord(rp.x, rp.y, rp.z)
        local okU, ux, uy = GetScreenCoordFromWorldCoord(up_.x, up_.y, up_.z)
        if not okR or not okU then break end

        -- [ dRx dUx ] [fx]   [nx - cx]
        -- [ dRy dUy ] [fy] = [ny - cy]
        local dRx, dRy = (rx - cx) / step, (ry - cy) / step
        local dUx, dUy = (ux - cx) / step, (uy - cy) / step

        local det = (dRx * dUy) - (dUx * dRy)
        if math.abs(det) < 0.0000001 then break end

        local tx, ty = nx - cx, ny - cy
        local fx = (tx * dUy - dUx * ty) / det
        local fy = (dRx * ty - tx * dRy) / det

        guessPoint = guessPoint + (right * fx) + (up * fy)

        -- close enough to stop early (screen-space, so this is a tiny fraction of the viewport)
        if math.abs(tx) < 0.0005 and math.abs(ty) < 0.0005 then break end
    end

    return normalizeVec(guessPoint - camPos)
end

-- Raycasts from the given screen point. If nothing is hit within
-- maxDistance, returns a point along the ray at freeDistance instead, so
-- images can be placed floating with no surface required. `hitSurface`
-- tells the caller whether a real surface was hit.
local function raycastFromScreen(nx, ny, maxDistance, freeDistance, surfaceOffset)
    local camPos = getActiveCamPosRot() -- same active-camera resolution as screenToWorldDirection, so ray origin matches noclip's actual freecam position
    local dir = screenToWorldDirection(nx, ny)

    local rayHandle = StartShapeTestRay(
        camPos.x, camPos.y, camPos.z,
        (camPos + dir * maxDistance).x, (camPos + dir * maxDistance).y, (camPos + dir * maxDistance).z,
        -1, PlayerPedId(), 0
    )

    local _, hit, endCoords, surfaceNormal = GetShapeTestResult(rayHandle)

    if hit == 1 then
        -- GetShapeTestResult's surface normal points outward from whatever
        -- was hit, toward the ray origin side. Nudging the point a small
        -- distance along it keeps the placed quad sitting just in front of
        -- the surface instead of exactly coincident with it - without this,
        -- the quad and the wall/prop polygon occupy the same depth and you
        -- get z-fighting flicker, or on slightly uneven geometry the quad
        -- can visibly sink into/clip through the object. This is most
        -- visible on things like billboards that already have their own
        -- screen texture baked in close to the surface - the default
        -- offset isn't always enough to fully clear that, hence
        -- surfaceOffset being adjustable per-placement (mouse wheel) rather
        -- than fixed.
        local normal = surfaceNormal
        if #normal < 0.01 then
            normal = normalizeVec(camPos - endCoords) -- degenerate normal, fall back to facing the camera
        end
        local offsetPoint = endCoords + normal * (surfaceOffset or Config.SurfaceOffset)
        return true, offsetPoint, normal, true
    end

    -- nothing hit - place a free-floating point out along the ray instead
    -- of rejecting the click, so you can pin corners in open air
    local freePoint = camPos + dir * (freeDistance or maxDistance)
    return true, freePoint, normalizeVec(camPos - freePoint), false
end

---------------------------------------------------------------------
-- Corner-pin point picking (mouse-cursor based, 4 points)
---------------------------------------------------------------------

local DEFAULT_FREE_PLACE_DISTANCE = 15.0
local FREE_PLACE_MIN, FREE_PLACE_MAX = 0.5, 300.0 -- kept in line with the raised Config.MaxRaycastDistance

-- How far in/out of the surface a corner sits, in meters. Adjustable via
-- scroll so it covers both ends: fine (mm) steps near zero for clearing
-- z-fighting, scaling up to large steps so big offsets (floating a
-- placement well off the surface, or push it behind/through) are still
-- reachable in a reasonable number of scroll ticks.
local SURFACE_OFFSET_MIN, SURFACE_OFFSET_MAX = -150.0, 150.0

local function surfaceOffsetScrollStep(currentOffset)
    return math.max(0.001, math.abs(currentOffset) * 0.08)
end

-- Width/height/rotation bounds for anchor mode's size sliders.
local SIZE_MIN, SIZE_MAX = 0.2, 40.0     -- meters
local ROTATION_MIN, ROTATION_MAX = -180.0, 180.0 -- degrees, roll around the surface normal

local function clampNum(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local corner = {
    active = false,
    mode = 'anchor',    -- 'anchor' (straight rectangle, recommended) or 'freeform' (4 independently-clicked corners)
    imageUrl = nil,
    editId = nil,       -- set when re-picking corners for an existing placement instead of a new one
    points = {},        -- world-space vector3 corners actually used for the ghost preview/confirm, in perimeter order.
                         -- Freeform mode builds this up click by click; anchor mode recomputes it every frame from
                         -- anchorPoint/anchorNormal/width/height/rotation instead.
    cursorNX = 0.5,
    cursorNY = 0.5,
    liveHit = false,     -- true if the live cursor point is resting on a real surface
    livePoint = nil,
    liveNormal = nil,
    freeDistance = DEFAULT_FREE_PLACE_DISTANCE, -- distance used for points placed in open air (mouse wheel adjustable)
    surfaceOffset = Config.SurfaceOffset,       -- clearance off a hit surface (mouse wheel adjustable, tiny steps)

    -- anchor-mode-only state
    anchorPoint = nil,   -- vector3, set once you click to "drop" the anchor - nil means still aiming/following the cursor
    anchorNormal = nil,
    width = Config.DefaultWidth,
    height = Config.DefaultHeight,
    rotation = 0.0
}

local function resetCorner()
    corner.active = false
    corner.mode = 'anchor'
    corner.imageUrl = nil
    corner.editId = nil
    corner.points = {}
    corner.liveHit = false
    corner.livePoint = nil
    corner.liveNormal = nil
    corner.freeDistance = DEFAULT_FREE_PLACE_DISTANCE
    corner.surfaceOffset = Config.SurfaceOffset
    corner.anchorPoint = nil
    corner.anchorNormal = nil
    corner.width = Config.DefaultWidth
    corner.height = Config.DefaultHeight
    corner.rotation = 0.0
end

function enterCornerPicking(imageUrl, editId, opts)
    opts = opts or {}
    corner.active = true
    corner.mode = opts.mode == 'freeform' and 'freeform' or 'anchor'
    corner.imageUrl = imageUrl
    corner.editId = editId
    corner.points = {}
    corner.cursorNX, corner.cursorNY = 0.5, 0.5
    corner.freeDistance = DEFAULT_FREE_PLACE_DISTANCE
    corner.surfaceOffset = Config.SurfaceOffset

    corner.anchorPoint = opts.anchor
    corner.anchorNormal = opts.normal
    corner.width = clampNum(opts.width or Config.DefaultWidth, SIZE_MIN, SIZE_MAX)
    corner.height = clampNum(opts.height or Config.DefaultHeight, SIZE_MIN, SIZE_MAX)
    corner.rotation = clampNum(opts.rotation or 0.0, ROTATION_MIN, ROTATION_MAX)

    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(true) -- keep WASD working while the cursor is free

    SendNUIMessage({
        action = 'cornerPicking',
        active = true,
        mode = corner.mode,
        count = 0,
        total = 4,
        anchorSet = corner.anchorPoint ~= nil,
        editing = editId ~= nil,
        editId = editId,
        alpha = opts.alpha,
        drawDistance = opts.drawDistance,
        width = corner.width,
        height = corner.height,
        rotation = corner.rotation,
        sizeMin = SIZE_MIN,
        sizeMax = SIZE_MAX,
        rotationMin = ROTATION_MIN,
        rotationMax = ROTATION_MAX
    })
end

function exitCornerPicking()
    resetCorner()
    SetNuiFocusKeepInput(false)

    if nuiOpen then
        SetNuiFocus(true, true)
    else
        SetNuiFocus(false, false)
    end

    SendNUIMessage({ action = 'cornerPicking', active = false })
end

-- Controls disabled while corner-picking is active. SetNuiFocusKeepInput(true)
-- leaves WASD live so you can walk into position, but also leaves weapon
-- aim/attack live - so those are explicitly disabled every frame.
local DISABLED_CONTROLS_WHILE_PLACING = {
    24,  -- INPUT_ATTACK
    25,  -- INPUT_AIM
    47,  -- INPUT_WEAPON_SPECIAL (e.g. shotgun pump / bow draw)
    91,  -- INPUT_VEH_FLY_ATTACK_CAMERA
    92,  -- INPUT_VEH_PASSENGER_AIM
    114, -- INPUT_VEH_FLY_ATTACK
    140, -- INPUT_MELEE_ATTACK_LIGHT
    141, -- INPUT_MELEE_ATTACK_HEAVY
    142, -- INPUT_MELEE_ATTACK_ALTERNATE
    257, -- INPUT_ATTACK2
    263, -- INPUT_MELEE_ATTACK_LIGHT (alt binding)
    264, -- INPUT_MELEE_ATTACK_HEAVY (alt binding)
    331, -- INPUT_VEH_FLY_ATTACK (alt binding)
    332, -- INPUT_VEH_FLY_ATTACK_CAMERA (alt binding)
    14,  -- INPUT_WEAPON_WHEEL_PREV (mouse wheel down - repurposed below for free-place distance)
    15   -- INPUT_WEAPON_WHEEL_NEXT (mouse wheel up - repurposed below for free-place distance)
}

-- Mouse-wheel step for adjusting a free-floating point's distance. Scales
-- with current distance (~8%/tick, floored at a small fixed step) so it's
-- fine-grained up close but still reaches long draw distances quickly.
local function freeDistanceScrollStep(currentDistance)
    return math.max(0.25, currentDistance * 0.08)
end

CreateThread(function()
    while true do
        local wait = 250
        if corner.active then
            wait = 0

            for _, control in ipairs(DISABLED_CONTROLS_WHILE_PLACING) do
                DisableControlAction(0, control, true)
            end

            if corner.mode == 'anchor' then
                if not corner.anchorPoint then
                    -- still aiming: the live raycast doubles as both the
                    -- ghost preview and what gets "dropped" as the anchor
                    -- on click. Scroll behaves exactly like freeform mode.
                    if corner.liveHit then
                        if IsDisabledControlJustPressed(0, 15) then
                            corner.surfaceOffset = math.min(SURFACE_OFFSET_MAX, corner.surfaceOffset + surfaceOffsetScrollStep(corner.surfaceOffset))
                        elseif IsDisabledControlJustPressed(0, 14) then
                            corner.surfaceOffset = math.max(SURFACE_OFFSET_MIN, corner.surfaceOffset - surfaceOffsetScrollStep(corner.surfaceOffset))
                        end
                    else
                        if IsDisabledControlJustPressed(0, 15) then
                            corner.freeDistance = math.min(FREE_PLACE_MAX, corner.freeDistance + freeDistanceScrollStep(corner.freeDistance))
                        elseif IsDisabledControlJustPressed(0, 14) then
                            corner.freeDistance = math.max(FREE_PLACE_MIN, corner.freeDistance - freeDistanceScrollStep(corner.freeDistance))
                        end
                    end

                    local _, point, normal, hitSurface = raycastFromScreen(
                        corner.cursorNX, corner.cursorNY,
                        sessionConfig.maxRaycastDistance, corner.freeDistance, corner.surfaceOffset
                    )
                    corner.liveHit = hitSurface
                    corner.livePoint = point
                    corner.liveNormal = normal
                end

                -- recomputed every frame (cheap - a handful of vector ops)
                -- so slider changes are reflected instantly without a
                -- separate "dirty" flag to manage
                local anchor = corner.anchorPoint or corner.livePoint
                local normal = corner.anchorNormal or corner.liveNormal
                corner.points = (anchor and normal)
                    and computeAnchorCorners(anchor, normal, corner.width, corner.height, corner.rotation)
                    or {}
            elseif #corner.points < 4 then
                -- Scroll wheel adjusts whichever distance is currently
                -- relevant, based on where the cursor was resting LAST
                -- frame: if it was on a real surface, scroll nudges the
                -- surface offset in tiny (1mm) steps so you can clear
                -- clipping/z-fighting without the point visibly moving
                -- off the surface you clicked. If it was free-floating in
                -- open air, scroll instead adjusts how far out that point
                -- sits, same as before.
                if corner.liveHit then
                    if IsDisabledControlJustPressed(0, 15) then -- wheel up = further off the surface
                        corner.surfaceOffset = math.min(SURFACE_OFFSET_MAX, corner.surfaceOffset + surfaceOffsetScrollStep(corner.surfaceOffset))
                    elseif IsDisabledControlJustPressed(0, 14) then -- wheel down = closer to/into the surface
                        corner.surfaceOffset = math.max(SURFACE_OFFSET_MIN, corner.surfaceOffset - surfaceOffsetScrollStep(corner.surfaceOffset))
                    end
                else
                    if IsDisabledControlJustPressed(0, 15) then -- wheel up
                        corner.freeDistance = math.min(FREE_PLACE_MAX, corner.freeDistance + freeDistanceScrollStep(corner.freeDistance))
                    elseif IsDisabledControlJustPressed(0, 14) then -- wheel down
                        corner.freeDistance = math.max(FREE_PLACE_MIN, corner.freeDistance - freeDistanceScrollStep(corner.freeDistance))
                    end
                end

                local _, point, _, hitSurface = raycastFromScreen(
                    corner.cursorNX, corner.cursorNY,
                    sessionConfig.maxRaycastDistance, corner.freeDistance, corner.surfaceOffset
                )
                corner.liveHit = hitSurface
                corner.livePoint = point
            end
        end
        Wait(wait)
    end
end)

---------------------------------------------------------------------
-- Texture creation
---------------------------------------------------------------------
--
-- CreateRuntimeTextureFromDuiHandle streams a live browser frame, updated
-- continuously - no mip chain is possible for that, so at a distance
-- (quad covering only a few screen pixels) it aliases/shimmers hard.
--
-- CreateRuntimeTextureFromImage loads a static image through the normal
-- texture-import pipeline instead, which does get mip levels, so distant
-- viewing samples a properly downsampled version.
--
-- Image is downloaded once via a server-side proxy (see below - the
-- client has no PerformHttpRequest, and this avoids CORS), then handed to
-- CreateRuntimeTextureFromImage as a base64 "data:" URL - no disk writes.
-- DUI stays as a fallback for anything the static path can't handle
-- (download failure, unsupported format, etc.).

local function guessImageExtension(url, contentType)
    if contentType then
        contentType = contentType:lower()
        if contentType:find('png') then return 'png' end
        if contentType:find('jpe?g') then return 'jpg' end
        if contentType:find('gif') then return 'gif' end
        if contentType:find('webp') then return 'webp' end
        if contentType:find('bmp') then return 'bmp' end
    end
    local ext = url:match('%.([%a%d]+)%?') or url:match('%.([%a%d]+)$')
    if ext then
        ext = ext:lower()
        if ext == 'jpeg' then ext = 'jpg' end
        return ext
    end
    return 'png'
end

-- FiveM client Lua has no PerformHttpRequest, so the fetch happens
-- server-side (server/main.lua) and streams back as base64 via a latent
-- event. It's handed straight to CreateRuntimeTextureFromImage as a
-- "data:" URL - no disk write needed (SaveResourceFile/LoadResourceFile
-- don't fit a freshly-downloaded runtime image anyway).

local mimeByExt = {
    png = 'image/png', jpg = 'image/jpeg', jpeg = 'image/jpeg',
    gif = 'image/gif', webp = 'image/webp', bmp = 'image/bmp'
}

local function guessMimeType(url, contentType)
    if contentType and contentType ~= '' then
        local bare = contentType:match('^%s*([^;%s]+)') -- strip "; charset=..." etc
        if bare and bare:find('/') then return bare end
    end
    return mimeByExt[guessImageExtension(url, contentType)] or 'image/png'
end

local downloadRequestId = 0
local pendingDownloads = {} -- [requestId] = callback(ok, base64Data|nil, contentType|errMsg)

local function downloadImageViaServer(imageUrl, cb)
    downloadRequestId = downloadRequestId + 1
    local requestId = downloadRequestId
    pendingDownloads[requestId] = cb

    if Config.Debug then
        print(('[image_placer] requesting download #%d: %s'):format(requestId, imageUrl))
    end

    TriggerServerEvent('image_placer:requestImageDownload', requestId, imageUrl)

    SetTimeout(20000, function()
        if pendingDownloads[requestId] then
            pendingDownloads[requestId] = nil
            cb(false, nil, 'timed out waiting for server to fetch the image')
        end
    end)
end

RegisterNetEvent('image_placer:imageDownloadResult', function(requestId, success, base64OrNil, contentTypeOrErr)
    if Config.Debug then
        print(('[image_placer] download #%d result: success=%s info=%s bytes(b64)=%d'):format(
            requestId, tostring(success), tostring(contentTypeOrErr), base64OrNil and #base64OrNil or 0))
    end

    local pending = pendingDownloads[requestId]
    if not pending then return end
    pendingDownloads[requestId] = nil

    if not success or not base64OrNil or #base64OrNil == 0 then
        pending(false, nil, (not success and contentTypeOrErr) or 'empty download')
        return
    end

    pending(true, base64OrNil, contentTypeOrErr)
end)

---------------------------------------------------------------------
-- Orientation normalization
---------------------------------------------------------------------
-- CreateRuntimeTextureFromImage ignores EXIF orientation, so a photo
-- shot in portrait or from a front camera can come out sideways/mirrored
-- even though it looks correct in a browser. A hidden DUI page decodes
-- the image the way a browser would (honoring EXIF), draws the result to
-- a canvas, and hands back a plain PNG with the orientation baked in -
-- keeping the sharp static texture path while matching what the source
-- URL actually looks like.

local normalizeRequestId = 0
local pendingNormalizations = {} -- [requestId] = { cb, dui, done }

local function normalizeImageOrientation(dataUrl, cb)
    normalizeRequestId = normalizeRequestId + 1
    local requestId = normalizeRequestId

    local duiUrl = ('https://cfx-nui-%s/html/normalize.html'):format(GetCurrentResourceName())
    local dui = CreateDui(duiUrl, 64, 64) -- size is irrelevant - this DUI is never turned into a texture, only used to run a browser's own image decoder

    local entry = { cb = cb, dui = dui, done = false }
    pendingNormalizations[requestId] = entry

    CreateThread(function()
        local attempts = 0
        while not IsDuiAvailable(dui) and attempts < 200 do
            Wait(10)
            attempts = attempts + 1
        end
        if entry.done then return end
        SendDuiMessage(dui, json.encode({ type = 'normalize', requestId = requestId, url = dataUrl }))
    end)

    SetTimeout(8000, function()
        if entry.done then return end
        entry.done = true
        pendingNormalizations[requestId] = nil
        DestroyDui(dui)
        cb(false, nil)
    end)
end

RegisterNUICallback('normalizeImageResult', function(data, cb)
    local requestId = tonumber(data.requestId)
    local entry = requestId and pendingNormalizations[requestId]
    if entry and not entry.done then
        entry.done = true
        pendingNormalizations[requestId] = nil
        DestroyDui(entry.dui)
        entry.cb(data.success and true or false, data.dataUrl)
    end
    cb({})
end)

local function createStaticTexture(id, imageUrl, cb)
    downloadImageViaServer(imageUrl, function(ok, base64Data, contentTypeOrErr)
        if not ok or not base64Data then
            cb(false, ('download failed (%s)'):format(tostring(contentTypeOrErr)))
            return
        end

        local mime = guessMimeType(imageUrl, contentTypeOrErr)
        local dataUrl = ('data:%s;base64,%s'):format(mime, base64Data)

        normalizeImageOrientation(dataUrl, function(normOk, normalizedDataUrl)
            -- if normalization fails for any reason, fall back to the raw
            -- bytes rather than blocking the placement entirely - worst
            -- case it's back to the old (possibly wrong-orientation)
            -- behaviour instead of not placing at all
            local finalDataUrl = (normOk and normalizedDataUrl) or dataUrl

            local runtimeTxdName = 'imgplacer_' .. id
            local runtimeTxn = 'tex_' .. id
            local runtimeTxd = CreateRuntimeTxd(runtimeTxdName)

            local ok2 = pcall(function()
                CreateRuntimeTextureFromImage(runtimeTxd, runtimeTxn, finalDataUrl)
            end)

            if not ok2 then
                cb(false, 'unsupported image format for a static texture')
                return
            end

            cb(true, { txd = runtimeTxdName, txn = runtimeTxn, static = true })
        end)
    end)
end

local function createDuiTexture(id, imageUrl, cb)
    local texW, texH = sessionConfig.canvasResolution, sessionConfig.canvasResolution
    local duiUrl = ('https://cfx-nui-%s/html/canvas.html'):format(GetCurrentResourceName())
    local dui = CreateDui(duiUrl, texW, texH)

    CreateThread(function()
        local duiHandle = nil
        local attempts = 0
        while not duiHandle and attempts < 200 do
            duiHandle = GetDuiHandle(dui)
            attempts = attempts + 1
            Wait(10)
        end

        if not duiHandle then
            cb(false, 'Failed to acquire DUI handle')
            return
        end

        SendDuiMessage(dui, json.encode({ type = 'setImage', url = imageUrl }))

        local runtimeTxdName = 'imgplacer_' .. id
        local runtimeTxn = 'tex_' .. id
        local runtimeTxd = CreateRuntimeTxd(runtimeTxdName)
        CreateRuntimeTextureFromDuiHandle(runtimeTxd, runtimeTxn, duiHandle)

        cb(true, { dui = dui, txd = runtimeTxdName, txn = runtimeTxn, static = false })
    end)
end

-- Same idea as createDuiTexture, but the DUI page holds a looping <video>
-- instead of an <img> - the browser fetches the URL directly, so this
-- never touches the server-side download/base64 path (which would be a
-- poor fit for anything video-sized anyway).
local function createVideoTexture(id, videoUrl, cb)
    local texW, texH = sessionConfig.canvasResolution, sessionConfig.canvasResolution
    local duiUrl = ('https://cfx-nui-%s/html/video.html'):format(GetCurrentResourceName())
    local dui = CreateDui(duiUrl, texW, texH)

    CreateThread(function()
        local duiHandle = nil
        local attempts = 0
        while not duiHandle and attempts < 200 do
            duiHandle = GetDuiHandle(dui)
            attempts = attempts + 1
            Wait(10)
        end

        if not duiHandle then
            cb(false, 'Failed to acquire DUI handle')
            return
        end

        SendDuiMessage(dui, json.encode({ type = 'setVideo', url = videoUrl }))

        local runtimeTxdName = 'imgplacer_' .. id
        local runtimeTxn = 'tex_' .. id
        local runtimeTxd = CreateRuntimeTxd(runtimeTxdName)
        CreateRuntimeTextureFromDuiHandle(runtimeTxd, runtimeTxn, duiHandle)

        cb(true, { dui = dui, txd = runtimeTxdName, txn = runtimeTxn, static = false })
    end)
end

-- Tries the sharp, mipmapped static path first; only falls back to the
-- live DUI browser path if that genuinely can't handle this URL. Video
-- always needs the DUI (it can play); GIFs go straight to DUI too, since
-- the static path would just freeze on a single frame.
local function createPlacementTexture(id, imageUrl, cb)
    if Config.EnableVideo and Media.isVideo(imageUrl) then
        createVideoTexture(id, imageUrl, cb)
        return
    end

    if Media.isAnimatedImage(imageUrl) then
        createDuiTexture(id, imageUrl, cb)
        return
    end

    createStaticTexture(id, imageUrl, function(ok, result)
        if ok then
            cb(true, result)
            return
        end

        print(('[image_placer] static texture failed for #%d (%s), falling back to DUI'):format(id, tostring(result)))
        createDuiTexture(id, imageUrl, cb)
    end)
end

---------------------------------------------------------------------
-- Placement management (pure overlay - draws on top, replaces nothing)
---------------------------------------------------------------------

-- id -> true while a texture build (download + CreateRuntimeTexture...) is
-- still in flight for that placement. There's a window between "created/
-- synced" and "exists in `placements`" - a delete landing inside that
-- window needs to be remembered here, or the build finishes afterward and
-- resurrects a ghost placement with no corresponding DB row.
local pendingBuilds = {}       -- [id] = true
local removedWhilePending = {} -- [id] = true if a removal came in mid-build
local latestPendingData = {}   -- [id] = freshest corners/alpha to use once the in-flight build resolves

local function destroyBuildResult(result)
    if result and result.dui then
        DestroyDui(result.dui)
    end
end

-- Keeps the Manage tab's list honest: a full resync whenever the panel
-- opens, plus a live push after anything changes while it's open - so it
-- reflects placements from before you opened it or made by other players.
local function nuiPlacementSummary(id, p)
    local width, height
    if p.corners then
        local ok, _, _, w, h = pcall(deriveAnchorFromCorners, p.corners)
        if ok then width, height = w, h end
    end

    return {
        id = id,
        imageUrl = p.imageUrl,
        alpha = p.alpha,
        drawDistance = p.maxDrawDistance,
        width = width,   -- best-effort, derived from the current corners - used to prefill "duplicate"
        height = height,
        placedBy = p.placedBy,
        createdAt = p.createdAt,
        mapX = p.center and p.center.x or nil,
        mapY = p.center and p.center.y or nil
    }
end

local function pushNuiPlacementList()
    if not nuiOpen then return end -- next openNui() call resyncs anyway
    local list = {}
    for id, p in pairs(placements) do
        list[#list + 1] = nuiPlacementSummary(id, p)
    end
    SendNUIMessage({ action = 'syncPlacements', placements = list })
end

local function addPlacement(corners, imageUrl, opts, cb)
    if Config.MaxPlacementsPerPlayer and sessionConfig.maxPlacementsPerPlayer > 0 then
        local count = 0
        for _ in pairs(placements) do count = count + 1 end
        if count >= sessionConfig.maxPlacementsPerPlayer then
            if cb then cb(false, ('Limit reached (%d max placements)'):format(sessionConfig.maxPlacementsPerPlayer)) end
            return
        end
    end

    placementIdCounter = placementIdCounter - 1
    local id = placementIdCounter
    opts = opts or {}
    pendingBuilds[id] = true

    createPlacementTexture(id, imageUrl, function(ok, result)
        pendingBuilds[id] = nil

        if removedWhilePending[id] then
            removedWhilePending[id] = nil
            if ok then destroyBuildResult(result) end
            if cb then cb(false, 'removed before it finished loading') end
            return
        end

        if not ok then
            if cb then cb(false, result) end
            return
        end

        placements[id] = {
            id = id,
            imageUrl = imageUrl,
            dui = result.dui, -- nil when the static (mipmapped) path was used
            txd = result.txd,
            txn = result.txn,
            alpha = opts.alpha or 255,
            placedBy = nil, -- created via export, not tied to a specific player action
            createdAt = os.time(),
            spawnedAt = GetGameTimer()
        }
        setPlacementGeometry(placements[id], corners, opts.maxDrawDistance or sessionConfig.defaultDrawDistance)
        pushNuiPlacementList()

        if cb then cb(true, id) end
    end)
end

local function removePlacement(id, skipNuiPush)
    if pendingBuilds[id] then
        -- nothing's been created yet to tear down - flag it so the
        -- in-flight build discards its result instead of adding it
        removedWhilePending[id] = true
        return true
    end

    local p = placements[id]
    if not p then return false end

    if p.dui then
        DestroyDui(p.dui)
    end

    placements[id] = nil
    if not skipNuiPush then pushNuiPlacementList() end
    return true
end

local function removeAllPlacements()
    for id in pairs(placements) do
        removePlacement(id, true)
    end
    for id in pairs(pendingBuilds) do
        removePlacement(id, true)
    end
    pushNuiPlacementList()
end

---------------------------------------------------------------------
-- Draw loop
--   - draws the purple ghost preview while corner-picking
--   - draws each confirmed placement as a real world-space textured quad
--     (DrawTexturedPoly, corner-mapped), so it's depth-tested against the
--     world like any other piece of geometry
---------------------------------------------------------------------

local GHOST_R, GHOST_G, GHOST_B = 130, 90, 255 -- matches the NUI's purple accent

local function drawGhostLine(a, b)
    DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, GHOST_R, GHOST_G, GHOST_B, 220)
end

local function drawGhostFace(a, b, c, alpha)
    -- DrawPoly only renders one winding order, so draw both to keep the
    -- ghost visible no matter which side you're viewing it from.
    DrawPoly(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, GHOST_R, GHOST_G, GHOST_B, alpha)
    DrawPoly(a.x, a.y, a.z, c.x, c.y, c.z, b.x, b.y, b.z, GHOST_R, GHOST_G, GHOST_B, alpha)
end

local function drawCornerGhost()
    local pts = corner.points
    local n = #pts
    local stillAiming = (corner.mode == 'freeform' and n < 4) or (corner.mode == 'anchor' and not corner.anchorPoint)

    -- in freeform mode this also shows a live "next point" preview appended
    -- to the confirmed ones; anchor mode has nothing equivalent to append -
    -- corner.points already holds the full live-preview rectangle pre-lock
    local preview = (corner.mode == 'freeform' and n < 4) and corner.livePoint or nil

    -- Small on-screen readout of the current scroll-adjustable value, so
    -- there's feedback while nudging it in/out - shown in mm near zero
    -- (where steps are sub-millimeter) or meters once it's large.
    if stillAiming then
        local label
        if corner.liveHit then
            if math.abs(corner.surfaceOffset) < 1.0 then
                label = string.format("Surface offset: %.1fmm  (scroll to adjust)", corner.surfaceOffset * 1000.0)
            else
                label = string.format("Surface offset: %.2fm  (scroll to adjust)", corner.surfaceOffset)
            end
        else
            label = string.format("Free-place distance: %.1fm  (scroll to adjust)", corner.freeDistance)
        end
        SetTextFont(4)
        SetTextScale(0.32, 0.32)
        SetTextColour(255, 255, 255, 220)
        SetTextOutline()
        SetTextCentre(true)
        BeginTextCommandDisplayText("STRING")
        AddTextComponentSubstringPlayerName(label)
        EndTextCommandDisplayText(0.5, 0.90)
    end

    -- tiny marker cube at each corner currently being previewed
    for _, p in ipairs(pts) do
        drawGhostFace(
            p + vector3(0.025, 0.025, 0.025),
            p + vector3(-0.025, 0.025, -0.025),
            p + vector3(0.025, -0.025, -0.025),
            200
        )
    end

    local rawForDisplay = {}
    for i = 1, n do rawForDisplay[i] = pts[i] end
    if preview then rawForDisplay[#rawForDisplay + 1] = preview end

    local total = #rawForDisplay
    if total < 2 then return end

    -- Anchor mode's points are already in valid perimeter order (built
    -- directly from the surface normal/rotation); only freeform's
    -- arbitrary click order needs straightening out.
    local ordered = (corner.mode == 'freeform') and orderQuadCorners(rawForDisplay) or rawForDisplay

    for i = 2, total do drawGhostLine(ordered[i - 1], ordered[i]) end
    if total >= 3 then drawGhostLine(ordered[total], ordered[1]) end

    if total == 3 then
        drawGhostFace(ordered[1], ordered[2], ordered[3], 55)
    elseif total == 4 then
        drawGhostFace(ordered[1], ordered[2], ordered[3], 65)
        drawGhostFace(ordered[1], ordered[3], ordered[4], 65)
    end
end

-- DrawTexturedPoly is backface-culled, but the image needs to be visible
-- from both sides of the surface (e.g. walking behind a billboard). Rather
-- than drawing both windings (which z-fights/occludes at grazing angles),
-- this checks which side of the quad's plane the camera is on and draws
-- only the front-facing winding for that side, picked fresh each frame.
local function drawTexturedTri(a, b, c, ua, va, ub, vb, uc, vc, alpha, txd, txn)
    DrawTexturedPoly(
        a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z,
        255, 255, 255, alpha, txd, txn,
        ua, va, 1.0, ub, vb, 1.0, uc, vc, 1.0
    )
end

-- V is flipped (0.0<->1.0 swapped vs. what you'd expect from top-left-origin
-- UVs) because CreateRuntimeTextureFromImage/CreateRuntimeTextureFromDuiHandle
-- store the source image bottom-up: V=0 addresses the *bottom* row of the
-- source image, not the top. Mapping top corners to V=0 (the "normal"
-- convention) therefore renders every placement upside down. Flipping V here
-- corrects that without touching corner order or winding.
local function drawPlacementQuad(p, alpha, camCoord)
    local c = p.corners
    local toCam = camCoord - p.center
    local facingCam = (p.normal.x * toCam.x + p.normal.y * toCam.y + p.normal.z * toCam.z) >= 0.0

    if facingCam then
        drawTexturedTri(c[1], c[2], c[3], 0.0, 1.0, 1.0, 1.0, 1.0, 0.0, alpha, p.txd, p.txn)
        drawTexturedTri(c[1], c[3], c[4], 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, alpha, p.txd, p.txn)
    else
        drawTexturedTri(c[3], c[2], c[1], 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, alpha, p.txd, p.txn)
        drawTexturedTri(c[4], c[3], c[1], 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, alpha, p.txd, p.txn)
    end
end

CreateThread(function()
    local SPAWN_ANIM_MS = 300.0

    while true do
        local hasPlacements = false
        local camCoord = getActiveCamPosRot() -- draw-distance culling should follow wherever you're actually viewing from, including noclip
        local now = GetGameTimer()

        if corner.active then
            drawCornerGhost()
        end

        for id, p in pairs(placements) do
            hasPlacements = true

            local beingEdited = corner.active and corner.editId == id
            local diff = camCoord - p.center
            local distSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z
            if not beingEdited and distSq <= p.maxDrawDistanceSq then
                local elapsed = now - p.spawnedAt
                local t = math.min(1.0, elapsed / SPAWN_ANIM_MS)
                local alpha = math.floor(t * p.alpha)
                if alpha > 0 then
                    drawPlacementQuad(p, alpha, camCoord)
                end
            end
        end

        Wait((hasPlacements or corner.active) and 0 or 500)
    end
end)

---------------------------------------------------------------------
-- Exports
---------------------------------------------------------------------

-- corners: table of 4 {x=,y=,z=}-style tables, in order around the quad
-- (e.g. top-left, top-right, bottom-right, bottom-left).
exports('PlaceImageAtCorners', function(corners, imageUrl, opts)
    local v = {}
    for i = 1, 4 do
        local c = corners[i]
        v[i] = vector3(c.x, c.y, c.z)
    end

    local resultId, done = nil, false
    addPlacement(v, imageUrl, opts, function(ok, idOrErr)
        resultId = ok and idOrErr or nil
        done = true
    end)
    while not done do Wait(0) end
    return resultId
end)

-- Backward/simple-compatible helper: builds a flat quad centered at a point.
-- opts.normal (table {x,y,z}) orients the quad; defaults to facing +Y.
exports('PlaceImageAtCoords', function(x, y, z, imageUrl, opts)
    opts = opts or {}
    local center = vector3(x, y, z)
    local normal = opts.normal and vector3(opts.normal.x, opts.normal.y, opts.normal.z) or vector3(0.0, 1.0, 0.0)
    normal = normalizeVec(normal)

    local worldUp = vector3(0.0, 0.0, 1.0)
    local right = crossVec(normal, worldUp)
    if #right < 0.0001 then right = vector3(1.0, 0.0, 0.0) end
    right = normalizeVec(right)
    local up = normalizeVec(crossVec(normal, right))

    local halfW = (opts.width or Config.DefaultWidth) / 2.0
    local halfH = (opts.height or Config.DefaultHeight) / 2.0

    local corners = {
        center - (right * halfW) + (up * halfH),
        center + (right * halfW) + (up * halfH),
        center + (right * halfW) - (up * halfH),
        center - (right * halfW) - (up * halfH)
    }

    local resultId, done = nil, false
    addPlacement(corners, imageUrl, opts, function(ok, idOrErr)
        resultId = ok and idOrErr or nil
        done = true
    end)
    while not done do Wait(0) end
    return resultId
end)

exports('RemoveImagePlacement', function(id)
    return removePlacement(id)
end)

exports('RemoveAllImagePlacements', function()
    removeAllPlacements()
end)

exports('GetActivePlacements', function()
    local list = {}
    for id, p in pairs(placements) do
        local corners = {}
        for i = 1, 4 do
            corners[i] = { x = p.corners[i].x, y = p.corners[i].y, z = p.corners[i].z }
        end
        list[#list + 1] = { id = id, corners = corners, imageUrl = p.imageUrl }
    end
    return list
end)

---------------------------------------------------------------------
-- Server sync (persistence + shared visibility across all players)
---------------------------------------------------------------------

-- Corners travel over the network/JSON as plain {x=,y=,z=} tables (vector3
-- isn't JSON-safe); convert back to vector3 for the local rendering math.
local function plainToVec3List(list)
    local out = {}
    for i, pt in ipairs(list) do
        out[i] = vector3(pt.x, pt.y, pt.z)
    end
    return out
end

-- Every client builds its own local texture for a placement (no way to
-- share a GPU texture across players) - "syncing" just means every client
-- runs addPlacement() with the same server-assigned id and stored data.
local function applyServerPlacement(id, data)
    if placements[id] then
        -- already rendering it locally (e.g. we're the one who just
        -- created it) - just make sure it reflects the latest data in
        -- case this broadcast is actually carrying a newer edit
        setPlacementGeometry(placements[id], plainToVec3List(data.corners), data.drawDistance or sessionConfig.defaultDrawDistance)
        placements[id].alpha = tonumber(data.alpha) or placements[id].alpha
        placements[id].placedBy = data.placedBy or placements[id].placedBy
        placements[id].createdAt = data.createdAt or placements[id].createdAt
        pushNuiPlacementList()
        return
    end

    if pendingBuilds[id] then
        -- a build's already in flight for this id (duplicate sync, or an
        -- edit arrived before the initial build resolved) - just remember
        -- the freshest data, the in-flight callback below will pick it up
        latestPendingData[id] = data
        return
    end

    pendingBuilds[id] = true

    createPlacementTexture(id, data.imageUrl, function(ok, result)
        pendingBuilds[id] = nil
        local freshest = latestPendingData[id] or data
        latestPendingData[id] = nil

        if removedWhilePending[id] then
            removedWhilePending[id] = nil
            if ok then destroyBuildResult(result) end
            return
        end

        if not ok then
            print(('^1[image_placer] ERROR: failed to build texture for placement #%d: %s^0'):format(id, tostring(result)))
            if data.placedBy == GetPlayerName(PlayerId()) then
                notify(('~r~Image #%d failed to load: %s'):format(id, tostring(result)))
            end
            return
        end

        placements[id] = {
            id = id,
            imageUrl = data.imageUrl,
            dui = result.dui,
            txd = result.txd,
            txn = result.txn,
            alpha = tonumber(freshest.alpha) or 255,
            placedBy = freshest.placedBy,
            createdAt = freshest.createdAt,
            spawnedAt = GetGameTimer()
        }
        setPlacementGeometry(placements[id], plainToVec3List(freshest.corners), freshest.drawDistance or sessionConfig.defaultDrawDistance)
        pushNuiPlacementList()
    end)
end

RegisterNetEvent('image_placer:initialPlacements', function(serverPlacements)
    for idStr, data in pairs(serverPlacements or {}) do
        applyServerPlacement(tonumber(idStr), data)
    end
end)

RegisterNetEvent('image_placer:placementAdded', function(id, data)
    applyServerPlacement(id, data)
end)

RegisterNetEvent('image_placer:placementUpdated', function(id, data)
    local p = placements[id]
    if not p then
        applyServerPlacement(id, data)
        return
    end
    setPlacementGeometry(p, plainToVec3List(data.corners), data.drawDistance or sessionConfig.defaultDrawDistance)
    p.alpha = tonumber(data.alpha) or p.alpha
    pushNuiPlacementList()
end)

RegisterNetEvent('image_placer:placementRemoved', function(id)
    removePlacement(id)
end)

RegisterNetEvent('image_placer:allPlacementsRemoved', function()
    removeAllPlacements()
end)

RegisterNetEvent('image_placer:createPlacementFailed', function(reason)
    notify(('~r~Could not place image: %s'):format(reason))
end)

-- Fired once on resource start for every player, independent of the
-- use-permission - existing placements are just part of the world.
CreateThread(function()
    TriggerServerEvent('image_placer:syncPlacements')
end)

---------------------------------------------------------------------
-- Permission handling
---------------------------------------------------------------------

RegisterNetEvent('image_placer:accessResult', function(allowed, adminFlag, cfg)
    isAdmin = adminFlag

    if cfg then
        sessionConfig.maxPlacementsPerPlayer = cfg.maxPlacementsPerPlayer
        sessionConfig.maxRaycastDistance = cfg.maxRaycastDistance
        sessionConfig.defaultDrawDistance = cfg.defaultDrawDistance
        sessionConfig.minPlacementDrawDistance = cfg.minPlacementDrawDistance
        sessionConfig.maxPlacementDrawDistance = cfg.maxPlacementDrawDistance
        sessionConfig.canvasResolution = cfg.canvasResolution
    end

    if not allowed then
        notify('~r~You do not have permission to use the image placer.')
        return
    end

    openNui()
end)

-- An admin revoked our access mid-session (moderation panel in Settings) -
-- close the tool immediately rather than leaving it open with no access.
RegisterNetEvent('image_placer:accessRevoked', function()
    notify('~r~Your access to the image placer was revoked by an admin.')
    if nuiOpen then
        closeNui()
    end
end)

-- An admin saved new server defaults (Settings > "Save as server default")
-- - applies live for everyone, not just the admin who saved it.
RegisterNetEvent('image_placer:serverDefaultsUpdated', function(cfg)
    if not cfg then return end
    sessionConfig.maxPlacementsPerPlayer = cfg.maxPlacementsPerPlayer
    sessionConfig.maxRaycastDistance = cfg.maxRaycastDistance
    sessionConfig.defaultDrawDistance = cfg.defaultDrawDistance
    if nuiOpen then
        SendNUIMessage({ action = 'serverDefaultsUpdated', settings = sessionConfig })
    end
end)

RegisterNetEvent('image_placer:adminData', function(data)
    SendNUIMessage({ action = 'adminData', data = data })
end)

RegisterNetEvent('image_placer:adminActionResult', function(success, message)
    SendNUIMessage({ action = 'adminActionResult', success = success, message = message })
end)

RegisterNetEvent('image_placer:bulkActionResult', function(removedCount, requestedCount)
    SendNUIMessage({ action = 'bulkActionResult', removedCount = removedCount, requestedCount = requestedCount })
    notify(('~g~Removed %d/%d placement(s)'):format(removedCount, requestedCount))
end)

---------------------------------------------------------------------
-- NUI open/close + command
---------------------------------------------------------------------

function openNui()
    nuiOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        isAdmin = isAdmin,
        settings = sessionConfig,
        myId = GetPlayerServerId(PlayerId())
    })
    pushNuiPlacementList()
end

closeNui = function()
    nuiOpen = false
    if corner.active then
        resetCorner()
        SendNUIMessage({ action = 'cornerPicking', active = false })
    end
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'close' })
end

RegisterCommand(Config.Command, function()
    if nuiOpen then return end
    TriggerServerEvent('image_placer:requestAccess')
end, false)

RegisterKeyMapping(Config.Command, 'Open Image Placer', 'keyboard', Config.Keybind)

---------------------------------------------------------------------
-- NUI callbacks
---------------------------------------------------------------------

RegisterNUICallback('startCornerPicking', function(data, cb)
    if not data.imageUrl or data.imageUrl == '' then
        cb({ success = false, error = 'No image URL/path provided' })
        return
    end
    enterCornerPicking(data.imageUrl, nil, {
        alpha = tonumber(data.alpha) or 255,
        mode = data.mode,
        width = tonumber(data.width),   -- set when duplicating an existing placement; nil = use the config default
        height = tonumber(data.height),
        rotation = tonumber(data.rotation)
    })
    cb({ success = true })
end)

RegisterNUICallback('startEditPlacement', function(data, cb)
    local id = tonumber(data.id)
    local p = placements[id]
    if not p then
        if pendingBuilds[id] then
            cb({ success = false, error = 'Still loading - try again in a second' })
        else
            cb({ success = false, error = 'That placement no longer exists' })
        end
        return
    end

    -- Always re-enter in anchor mode, prefilled from the existing corners
    -- straightened into a proper rectangle - so re-opening a crooked
    -- freeform placement immediately shows you a corrected version you
    -- can just confirm as-is, or fine-tune with the sliders first. You
    -- can still switch to freeform from the picking overlay if you
    -- genuinely want independent corners back.
    local anchor, normal, width, height, rotation = deriveAnchorFromCorners(p.corners)
    enterCornerPicking(p.imageUrl, id, {
        alpha = p.alpha,
        drawDistance = p.maxDrawDistance,
        mode = 'anchor',
        anchor = anchor,
        normal = normal,
        width = width,
        height = height,
        rotation = rotation
    })
    cb({ success = true })
end)

RegisterNUICallback('cursorMove', function(data, cb)
    if corner.active then
        corner.cursorNX = tonumber(data.x) or corner.cursorNX
        corner.cursorNY = tonumber(data.y) or corner.cursorNY
    end
    cb({})
end)

RegisterNUICallback('cursorClick', function(data, cb)
    if not corner.active then
        cb({ success = false })
        return
    end

    corner.cursorNX = tonumber(data.x) or corner.cursorNX
    corner.cursorNY = tonumber(data.y) or corner.cursorNY

    if corner.mode == 'anchor' then
        -- always succeeds - if nothing's under the cursor it drops a
        -- free-floating anchor at corner.freeDistance instead of
        -- rejecting the click. Clicking again while already anchored just
        -- moves it, so you can freely reposition before confirming.
        local _, point, normal, hitSurface = raycastFromScreen(
            corner.cursorNX, corner.cursorNY,
            sessionConfig.maxRaycastDistance, corner.freeDistance, corner.surfaceOffset
        )
        corner.anchorPoint = point
        corner.anchorNormal = normal

        SendNUIMessage({ action = 'cornerPointAdded', mode = 'anchor', anchorSet = true, floating = not hitSurface })
        cb({ success = true, anchorSet = true, floating = not hitSurface })
        return
    end

    if #corner.points >= 4 then
        cb({ success = false })
        return
    end

    -- always succeeds now - if nothing's under the cursor (e.g. open air
    -- above a billboard) it drops a free-floating point at corner.freeDistance
    -- instead of rejecting the click
    local _, point, _, hitSurface = raycastFromScreen(
        corner.cursorNX, corner.cursorNY,
        sessionConfig.maxRaycastDistance, corner.freeDistance, corner.surfaceOffset
    )

    corner.points[#corner.points + 1] = point
    local count = #corner.points

    SendNUIMessage({
        action = 'cornerPointAdded',
        mode = 'freeform',
        count = count,
        total = 4,
        coords = { x = point.x, y = point.y, z = point.z },
        floating = not hitSurface
    })
    cb({ success = true, count = count, floating = not hitSurface })
end)

RegisterNUICallback('cursorUndo', function(data, cb)
    if not corner.active then
        cb({})
        return
    end

    if corner.mode == 'anchor' then
        corner.anchorPoint = nil
        corner.anchorNormal = nil
        SendNUIMessage({ action = 'cornerPointAdded', mode = 'anchor', anchorSet = false })
        cb({ anchorSet = false })
        return
    end

    if #corner.points > 0 then
        table.remove(corner.points)
    end
    local count = #corner.points
    SendNUIMessage({ action = 'cornerPointAdded', mode = 'freeform', count = count, total = 4 })
    cb({ count = count })
end)

RegisterNUICallback('setPickingMode', function(data, cb)
    if not corner.active then
        cb({ success = false })
        return
    end

    local newMode = data.mode == 'freeform' and 'freeform' or 'anchor'
    if newMode ~= corner.mode then
        corner.mode = newMode
        corner.points = {}
        corner.anchorPoint = nil
        corner.anchorNormal = nil
    end

    SendNUIMessage({
        action = 'cornerPicking',
        active = true,
        mode = corner.mode,
        count = 0,
        total = 4,
        anchorSet = false,
        editing = corner.editId ~= nil,
        editId = corner.editId,
        width = corner.width,
        height = corner.height,
        rotation = corner.rotation,
        sizeMin = SIZE_MIN,
        sizeMax = SIZE_MAX,
        rotationMin = ROTATION_MIN,
        rotationMax = ROTATION_MAX
    })
    cb({ success = true, mode = corner.mode })
end)

RegisterNUICallback('updateAnchorSize', function(data, cb)
    if corner.active and corner.mode == 'anchor' then
        if data.width ~= nil then corner.width = clampNum(tonumber(data.width) or corner.width, SIZE_MIN, SIZE_MAX) end
        if data.height ~= nil then corner.height = clampNum(tonumber(data.height) or corner.height, SIZE_MIN, SIZE_MAX) end
        if data.rotation ~= nil then corner.rotation = clampNum(tonumber(data.rotation) or corner.rotation, ROTATION_MIN, ROTATION_MAX) end
    end
    cb({})
end)

RegisterNUICallback('cursorCancel', function(data, cb)
    exitCornerPicking()
    cb({})
end)

-- Inverse of plainToVec3List: corners go out over the network as plain
-- {x=,y=,z=} tables to match what the server stores/JSON-encodes.
local function vec3ListToPlain(list)
    local out = {}
    for i, v in ipairs(list) do
        out[i] = { x = v.x, y = v.y, z = v.z }
    end
    return out
end

-- Creation goes through the server (assigned id + persistence +
-- broadcast), so it can't resolve synchronously. This nonce lets the
-- server hand the real id back to the specific request that asked for it.
local pendingCreateAcks = {}

RegisterNetEvent('image_placer:createPlacementAck', function(nonce, id)
    local cb = pendingCreateAcks[nonce]
    if cb then
        pendingCreateAcks[nonce] = nil
        cb(id)
    end
end)

RegisterNUICallback('confirmQuadPlacement', function(data, cb)
    local ready = corner.active and (
        (corner.mode == 'anchor' and corner.anchorPoint ~= nil and #corner.points == 4) or
        (corner.mode == 'freeform' and #corner.points == 4)
    )
    if not ready then
        cb({ success = false, error = corner.mode == 'anchor' and 'Click a surface to anchor the image first' or 'Place all 4 corners first' })
        return
    end

    -- Freeform's corners were clicked in an arbitrary order and need
    -- straightening into a perimeter walk; anchor mode's are already
    -- built that way by computeAnchorCorners, so leave those alone.
    local orderedCorners = (corner.mode == 'freeform') and orderQuadCorners(corner.points) or corner.points

    local alpha = tonumber(data.alpha) or 255
    local drawDistance = tonumber(data.drawDistance) -- nil = use the server default, left as-is
    local editId = corner.editId

    if editId and placements[editId] then
        -- optimistic: the server is the source of truth and will broadcast
        -- image_placer:placementUpdated back to us (and everyone else) to
        -- actually apply it, but there's nothing meaningfully async here
        -- from the NUI's point of view since it's just editing an id we
        -- already have
        TriggerServerEvent('image_placer:updatePlacement', editId, vec3ListToPlain(orderedCorners), alpha, drawDistance)

        notify('Placement updated')
        exitCornerPicking()
        cb({ success = true, id = editId })
        return
    end

    local nonce = ('%d_%d'):format(GetGameTimer(), math.random(100000, 999999))
    pendingCreateAcks[nonce] = function(id)
        if id then
            notify('Image placed in the world')
            exitCornerPicking()
            cb({ success = true, id = id })
        else
            cb({ success = false, error = 'Placement request failed or was denied' })
        end
    end

    -- safety timeout in case the server never responds (e.g. permission
    -- denied server-side with no explicit failure event reaching us)
    CreateThread(function()
        Wait(8000)
        local pending = pendingCreateAcks[nonce]
        if pending then
            pendingCreateAcks[nonce] = nil
            pending(nil)
        end
    end)

    TriggerServerEvent('image_placer:createPlacement', vec3ListToPlain(orderedCorners), corner.imageUrl, alpha, nonce, drawDistance)
end)

RegisterNUICallback('updatePlacementAlpha', function(data, cb)
    local id = tonumber(data.id)
    local p = placements[id]
    if not p then
        cb({ success = false })
        return
    end
    local alpha = tonumber(data.alpha) or p.alpha
    p.alpha = alpha -- local, immediate live-preview while dragging the slider
    TriggerServerEvent('image_placer:updatePlacement', id, nil, alpha)
    cb({ success = true })
end)

RegisterNUICallback('removePlacement', function(data, cb)
    local id = tonumber(data.id)
    TriggerServerEvent('image_placer:removePlacement', id)
    cb({ success = true }) -- optimistic; image_placer:placementRemoved will actually remove it locally for everyone
end)

RegisterNUICallback('locatePlacement', function(data, cb)
    local id = tonumber(data.id)
    local p = placements[id]
    if not p or not p.center then
        cb({ success = false, error = 'That placement no longer exists' })
        return
    end
    SetNewWaypoint(p.center.x, p.center.y)
    notify('Waypoint set')
    cb({ success = true })
end)

RegisterNUICallback('removeAll', function(data, cb)
    TriggerServerEvent('image_placer:removeAllPlacements')
    cb({ success = true }) -- optimistic; image_placer:allPlacementsRemoved will actually clear it locally for everyone
end)

RegisterNUICallback('closeNui', function(data, cb)
    closeNui()
    cb({})
end)

RegisterNUICallback('updateSettings', function(data, cb)
    if not isAdmin then
        cb({ success = false, error = 'Not authorized' })
        return
    end

    sessionConfig.maxPlacementsPerPlayer = tonumber(data.maxPlacementsPerPlayer) or sessionConfig.maxPlacementsPerPlayer
    sessionConfig.maxRaycastDistance = tonumber(data.maxRaycastDistance) or sessionConfig.maxRaycastDistance
    sessionConfig.defaultDrawDistance = tonumber(data.defaultDrawDistance) or sessionConfig.defaultDrawDistance

    notify('Image Placer settings updated')
    cb({ success = true, settings = sessionConfig })
end)

---------------------------------------------------------------------
-- Admin panel: stats/activity/moderation/bulk tools - thin proxies to the
-- server, which does the actual permission checks and work. See
-- server/main.lua for what each of these actually does.
---------------------------------------------------------------------

RegisterNUICallback('requestAdminData', function(data, cb)
    if not isAdmin then
        cb({ success = false, error = 'Not authorized' })
        return
    end
    TriggerServerEvent('image_placer:requestAdminData')
    cb({ success = true })
end)

RegisterNUICallback('setSessionOverride', function(data, cb)
    if not isAdmin then
        cb({ success = false, error = 'Not authorized' })
        return
    end
    local targetId = tonumber(data.id)
    if not targetId or (data.kind ~= 'use' and data.kind ~= 'admin') then
        cb({ success = false, error = 'Bad request' })
        return
    end
    -- mirrors the server-side guard: fail fast locally instead of round-tripping
    -- just to be told an admin can't revoke their own access
    if targetId == GetPlayerServerId(PlayerId()) and data.value == false then
        cb({ success = false, error = "You can't revoke your own " .. data.kind .. ' access' })
        return
    end
    -- data.value is JS true/false, or omitted entirely for "reset to default"
    TriggerServerEvent('image_placer:setSessionOverride', targetId, data.kind, data.value)
    cb({ success = true })
end)

RegisterNUICallback('removeMultiple', function(data, cb)
    if type(data.ids) ~= 'table' or #data.ids == 0 then
        cb({ success = false, error = 'Nothing selected' })
        return
    end
    local ids = {}
    for _, v in ipairs(data.ids) do ids[#ids + 1] = tonumber(v) end
    TriggerServerEvent('image_placer:removeMultiple', ids)
    cb({ success = true })
end)

RegisterNUICallback('removeByPlayer', function(data, cb)
    if not isAdmin then
        cb({ success = false, error = 'Not authorized' })
        return
    end
    if type(data.playerName) ~= 'string' or data.playerName == '' then
        cb({ success = false, error = 'No player selected' })
        return
    end
    TriggerServerEvent('image_placer:removeByPlayer', data.playerName)
    cb({ success = true })
end)

RegisterNUICallback('removeOlderThan', function(data, cb)
    if not isAdmin then
        cb({ success = false, error = 'Not authorized' })
        return
    end
    local days = tonumber(data.days)
    if not days or days <= 0 then
        cb({ success = false, error = 'Enter a number of days' })
        return
    end
    TriggerServerEvent('image_placer:removeOlderThan', days)
    cb({ success = true })
end)

RegisterNUICallback('saveServerDefaults', function(data, cb)
    if not isAdmin then
        cb({ success = false, error = 'Not authorized' })
        return
    end
    TriggerServerEvent('image_placer:saveServerDefaults', {
        maxPlacementsPerPlayer = tonumber(data.maxPlacementsPerPlayer),
        maxRaycastDistance = tonumber(data.maxRaycastDistance),
        defaultDrawDistance = tonumber(data.defaultDrawDistance)
    })
    cb({ success = true })
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        removeAllPlacements()
        SetNuiFocus(false, false)
        SetNuiFocusKeepInput(false)
    end
end)
