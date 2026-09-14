--[[
    SPDX-License-Identifier: GPL-3.0-or-later
    Copyright (C) 2026 DeeKnow of iDK Scripts

    Pure vector/rectangle math used to build and re-derive placement
    quads. No FiveM natives - kept dependency-free so it can be unit
    tested outside the game (see tests/geometry_spec.lua).
]]

Geometry = {}

function Geometry.normalizeVec(v)
    local len = #v
    if len < 0.0001 then return vector3(0.0, 1.0, 0.0) end
    return v / len
end

function Geometry.crossVec(a, b)
    return vector3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
end

function Geometry.averageVec3(list)
    local sx, sy, sz = 0.0, 0.0, 0.0
    for _, v in ipairs(list) do
        sx = sx + v.x
        sy = sy + v.y
        sz = sz + v.z
    end
    local n = #list
    return vector3(sx / n, sy / n, sz / n)
end

function Geometry.computeQuadNormal(corners)
    return Geometry.normalizeVec(Geometry.crossVec(corners[2] - corners[1], corners[3] - corners[1]))
end

-- Builds a straight rectangle (parallel edges, square corners) from an
-- anchor point + surface normal + width/height, so it's always level on a
-- normal wall. `right`/`up` come from the normal and world-up. `rotationDeg`
-- optionally rolls right/up around the normal, e.g. for floor decals.
function Geometry.computeAnchorCorners(anchor, normal, width, height, rotationDeg)
    local worldUp = vector3(0.0, 0.0, 1.0)
    local right = Geometry.crossVec(normal, worldUp)
    if #right < 0.0001 then right = vector3(1.0, 0.0, 0.0) end -- normal ~parallel to world-up (floor/ceiling), fall back to a fixed axis
    right = Geometry.normalizeVec(right)
    local up = Geometry.normalizeVec(Geometry.crossVec(right, normal))

    -- CreateRuntimeTextureFromImage samples the quad a half-turn off from
    -- the right/up axes above, so the offset is baked in here - keeps
    -- rotationDeg=0 (the untouched default) displaying upright.
    local rad = math.rad((rotationDeg or 0.0) + 180.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)
    local rotRight = (right * cosA) + (up * sinA)
    local rotUp = (up * cosA) - (right * sinA)
    right, up = rotRight, rotUp

    local halfW = (width or Config.DefaultWidth) / 2.0
    local halfH = (height or Config.DefaultHeight) / 2.0

    return {
        anchor - (right * halfW) + (up * halfH),
        anchor + (right * halfW) + (up * halfH),
        anchor + (right * halfW) - (up * halfH),
        anchor - (right * halfW) - (up * halfH)
    }
end

-- Inverse of the above: given an existing (possibly crooked/freeform)
-- quad, derives the anchor/normal/width/height/rotation of the closest
-- straight rectangle, so re-opening it in anchor mode starts straightened.
function Geometry.deriveAnchorFromCorners(corners)
    local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
    local center = Geometry.averageVec3(corners)
    local normal = Geometry.computeQuadNormal(corners)

    local width = (#(c2 - c1) + #(c3 - c4)) / 2.0
    local height = (#(c1 - c4) + #(c2 - c3)) / 2.0

    local worldUp = vector3(0.0, 0.0, 1.0)
    local baseRight = Geometry.crossVec(normal, worldUp)
    if #baseRight < 0.0001 then baseRight = vector3(1.0, 0.0, 0.0) end
    baseRight = Geometry.normalizeVec(baseRight)

    -- Signed angle from the "default" (rotation = 0) right vector to the
    -- quad's actual edge direction, measured around the normal - lets the
    -- edit prefill match the placement's original orientation.
    local actualRight = Geometry.normalizeVec(c2 - c1)
    local cosA = math.max(-1.0, math.min(1.0,
        baseRight.x * actualRight.x + baseRight.y * actualRight.y + baseRight.z * actualRight.z))
    local baseUp = Geometry.normalizeVec(Geometry.crossVec(baseRight, normal))
    local sinA = baseUp.x * actualRight.x + baseUp.y * actualRight.y + baseUp.z * actualRight.z

    -- Undo the same 180 degree bake-in computeAnchorCorners applies, so
    -- editing an untouched placement shows rotation=0, not 180.
    local rotation = math.deg(math.atan(sinA, cosA)) - 180.0
    if rotation <= -180.0 then rotation = rotation + 360.0 end

    return center, normal, width, height, rotation
end
