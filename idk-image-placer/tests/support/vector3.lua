--[[
    Standalone replacement for FiveM's built-in `vector3` type, covering
    only the operators shared/geometry.lua actually uses: field access,
    +, -, unary -, * (scalar), / (scalar), # (length), ==.

    The real vector3 comes from the FiveM Lua runtime in production -
    this only exists so the geometry math can be unit tested with plain
    Lua/busted, outside the game.
]]

local Vector3 = {}
Vector3.__index = Vector3

function Vector3.__add(a, b)
    return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, Vector3)
end

function Vector3.__sub(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, Vector3)
end

function Vector3.__mul(a, b)
    if type(a) == 'number' then
        return setmetatable({ x = a * b.x, y = a * b.y, z = a * b.z }, Vector3)
    end
    if type(b) == 'number' then
        return setmetatable({ x = a.x * b, y = a.y * b, z = a.z * b }, Vector3)
    end
    error('vector3 * vector3 is not supported by this shim')
end

function Vector3.__div(a, b)
    return setmetatable({ x = a.x / b, y = a.y / b, z = a.z / b }, Vector3)
end

function Vector3.__unm(a)
    return setmetatable({ x = -a.x, y = -a.y, z = -a.z }, Vector3)
end

function Vector3.__len(a)
    return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

function Vector3.__eq(a, b)
    return a.x == b.x and a.y == b.y and a.z == b.z
end

function Vector3.__tostring(a)
    return ('vector3(%.6f, %.6f, %.6f)'):format(a.x, a.y, a.z)
end

return function(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vector3)
end
