--[[
    Regression coverage for shared/geometry.lua.

    The core property under test: computeAnchorCorners and
    deriveAnchorFromCorners must be exact inverses of each other. Every
    orientation bug this resource has had (corners silently mirrored,
    swapped width/height, a placement only looking right after an
    edit-and-resave round trip) was really the same failure - those two
    functions disagreeing about which direction is "up" or "right" for a
    given surface normal. If they ever disagree again, the round-trip
    test below is what should catch it before it ships.
]]

_G.vector3 = require('tests.support.vector3')
_G.Config = { DefaultWidth = 2.0, DefaultHeight = 2.0 }

require('shared.geometry')

local EPS = 1e-4

local function almostEqual(a, b, eps)
    return math.abs(a - b) < (eps or EPS)
end

local function vecAlmostEqual(v1, v2, eps)
    return almostEqual(v1.x, v2.x, eps) and almostEqual(v1.y, v2.y, eps) and almostEqual(v1.z, v2.z, eps)
end

-- Compares two angles (degrees) up to wraparound, e.g. -180 and 180.
local function angleAlmostEqual(a, b, eps)
    local diff = (a - b) % 360.0
    if diff > 180.0 then diff = diff - 360.0 end
    return math.abs(diff) < (eps or EPS)
end

local function normalize(v)
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    return vector3(v.x / len, v.y / len, v.z / len)
end

describe('Geometry.crossVec', function()
    it('follows the right-hand rule for the standard basis vectors', function()
        local x = vector3(1, 0, 0)
        local y = vector3(0, 1, 0)
        local z = vector3(0, 0, 1)
        assert.is_true(vecAlmostEqual(Geometry.crossVec(x, y), z))
        assert.is_true(vecAlmostEqual(Geometry.crossVec(y, z), x))
        assert.is_true(vecAlmostEqual(Geometry.crossVec(z, x), y))
    end)

    it('is anti-commutative', function()
        local a = vector3(1, 2, 3)
        local b = vector3(4, 5, 6)
        local ab = Geometry.crossVec(a, b)
        local ba = Geometry.crossVec(b, a)
        assert.is_true(vecAlmostEqual(ab, vector3(-ba.x, -ba.y, -ba.z)))
    end)
end)

describe('Geometry.normalizeVec', function()
    it('produces a unit vector', function()
        local v = Geometry.normalizeVec(vector3(3, 4, 0))
        assert.is_true(almostEqual(#v, 1.0))
    end)

    it('falls back to a stable vector instead of dividing by zero', function()
        local v = Geometry.normalizeVec(vector3(0, 0, 0))
        assert.is_true(almostEqual(#v, 1.0))
    end)
end)

describe('Geometry.computeAnchorCorners / deriveAnchorFromCorners round trip', function()
    local anchor = vector3(100.0, 200.0, 30.0)

    local testNormals = {
        vector3(0, 1, 0),
        vector3(0, -1, 0),
        vector3(1, 0, 0),
        vector3(-1, 0, 0),
        normalize(vector3(1, 1, 0)),
        normalize(vector3(0.3, 0.7, 0.4)),
        normalize(vector3(-0.6, 0.2, 0.1)),
    }

    local testRotations = { 0.0, 30.0, 90.0, -45.0, 123.0, 179.9, -179.9 }

    for _, normal in ipairs(testNormals) do
        for _, rotation in ipairs(testRotations) do
            local label = ('normal=(%.2f,%.2f,%.2f) rotation=%.1f'):format(normal.x, normal.y, normal.z, rotation)

            it('recovers the exact width/height/rotation for ' .. label, function()
                local corners = Geometry.computeAnchorCorners(anchor, normal, 2.0, 1.1, rotation)
                local center, derivedNormal, width, height, derivedRotation = Geometry.deriveAnchorFromCorners(corners)

                assert.is_true(vecAlmostEqual(center, anchor, 1e-3))
                assert.is_true(vecAlmostEqual(derivedNormal, normal, 1e-3))
                assert.is_true(almostEqual(width, 2.0, 1e-3))
                assert.is_true(almostEqual(height, 1.1, 1e-3))
                assert.is_true(angleAlmostEqual(derivedRotation, rotation, 1e-2))
            end)

            it('reconstructs an identical quad from the derived values for ' .. label, function()
                local corners = Geometry.computeAnchorCorners(anchor, normal, 2.0, 1.1, rotation)
                local center, derivedNormal, width, height, derivedRotation = Geometry.deriveAnchorFromCorners(corners)
                local rebuilt = Geometry.computeAnchorCorners(center, derivedNormal, width, height, derivedRotation)

                for i = 1, 4 do
                    assert.is_true(vecAlmostEqual(corners[i], rebuilt[i], 1e-3),
                        ('corner %d differs after a no-op edit round trip'):format(i))
                end
            end)
        end
    end

    it('displays upright (identity mapping) at rotation=0 on a vertical wall', function()
        -- Regression anchor for the specific bug reported against this
        -- resource: a fresh placement at the default rotation must not
        -- require an edit-and-resave to look right.
        local corners = Geometry.computeAnchorCorners(anchor, vector3(0, 1, 0), 2.0, 1.1, 0.0)
        local width = #(corners[2] - corners[1])
        local height = #(corners[1] - corners[4])
        assert.is_true(almostEqual(width, 2.0))
        assert.is_true(almostEqual(height, 1.1))
    end)
end)

describe('Geometry.computeQuadNormal', function()
    it('matches the normal a quad was built with', function()
        local anchor = vector3(0, 0, 5)
        local normal = normalize(vector3(0.2, 0.9, 0.1))
        local corners = Geometry.computeAnchorCorners(anchor, normal, 3.0, 2.0, 15.0)
        local derived = Geometry.computeQuadNormal(corners)
        assert.is_true(vecAlmostEqual(derived, normal, 1e-3))
    end)
end)
