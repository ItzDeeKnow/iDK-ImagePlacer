-- Permission checks live server-side so they can't be bypassed via client Lua.
--
-- Placements are stored in MySQL via oxmysql and re-broadcast to everyone
-- on join, so they persist across restarts and are visible to all players.
--
-- Requires oxmysql started before this resource, and install.sql imported.

local placements = {}  -- [idString] = { corners = {{x,y,z},{x,y,z},{x,y,z},{x,y,z}}, imageUrl, alpha, placedBy, createdAt }
local nextId = 0
local ready = false -- true once the initial load from MySQL has finished
local resourceStartedAt = os.time()

local function hasPermission(source, perm)
    if not perm or perm == false or perm == '' then
        return true -- no permission configured = open to everyone
    end
    return IsPlayerAceAllowed(source, perm) == true
end

---------------------------------------------------------------------
-- Admin panel: session moderation overrides, activity log
--
-- sessionOverrides lets an admin grant/revoke tool access or admin rights
-- for a connected player for the rest of the session, without touching
-- server.cfg ACE groups. Cleared on disconnect/restart, never persisted.
---------------------------------------------------------------------

local sessionOverrides = {} -- [playerId] = { use = true/false/nil, admin = true/false/nil }

-- Resolves effective access for `kind` ('use'/'admin'): a session override
-- always wins over the configured ACE permission when one is set for this
-- player, otherwise falls back to the normal ACE check.
local function checkAccess(source, kind)
    local override = sessionOverrides[source]
    if override and override[kind] ~= nil then
        return override[kind]
    end
    return hasPermission(source, kind == 'admin' and Config.AdminPermission or Config.UsePermission)
end

AddEventHandler('playerDropped', function()
    sessionOverrides[source] = nil
end)

local activityLog = {}       -- ring buffer, most-recent-first
local ACTIVITY_LOG_MAX = 100

local function logActivity(kind, playerName, placementId, detail)
    table.insert(activityLog, 1, {
        kind = kind,
        player = playerName,
        placementId = placementId,
        detail = detail,
        ts = os.time()
    })
    while #activityLog > ACTIVITY_LOG_MAX do
        table.remove(activityLog)
    end
end

---------------------------------------------------------------------
-- Image downloading
--
-- No client-side PerformHttpRequest, and a browser fetch() would hit CORS
-- on most image hosts. So the server fetches the image and relays the
-- bytes to the requesting client via TriggerLatentClientEvent (regular
-- events are meant to stay a few KB; latent streams larger payloads
-- without blocking the rest of that client's connection).
---------------------------------------------------------------------

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64Encode(data)
    local out = {}
    local outIdx = 0
    local len = #data

    for i = 1, len, 3 do
        local b1, b2, b3 = data:byte(i, i + 2)
        b2 = b2 or 0
        local n = (b1 << 16) | (b2 << 8) | (b3 or 0)

        outIdx = outIdx + 1
        out[outIdx] = b64chars:sub((n >> 18 & 63) + 1, (n >> 18 & 63) + 1)
        outIdx = outIdx + 1
        out[outIdx] = b64chars:sub((n >> 12 & 63) + 1, (n >> 12 & 63) + 1)
        outIdx = outIdx + 1
        out[outIdx] = (i + 1 <= len) and b64chars:sub((n >> 6 & 63) + 1, (n >> 6 & 63) + 1) or '='
        outIdx = outIdx + 1
        out[outIdx] = (i + 2 <= len) and b64chars:sub((n & 63) + 1, (n & 63) + 1) or '='
    end

    return table.concat(out)
end

RegisterNetEvent('image_placer:requestImageDownload', function(requestId, url)
    local src = source
    if Config.Debug then
        print(('[image_placer] download request #%d from %s: %s'):format(requestId, GetPlayerName(src), url))
    end

    if not checkAccess(src, 'use') then
        TriggerClientEvent('image_placer:imageDownloadResult', src, requestId, false, nil, 'permission denied')
        return
    end

    if type(url) ~= 'string' or url == '' or not url:match('^https?://') then
        TriggerClientEvent('image_placer:imageDownloadResult', src, requestId, false, nil, 'invalid image URL')
        return
    end

    PerformHttpRequest(url, function(statusCode, body, _, headers)
        if Config.Debug then
            print(('[image_placer] download request #%d HTTP %s, %d bytes'):format(requestId, tostring(statusCode), body and #body or 0))
        end

        if statusCode ~= 200 or not body or #body == 0 then
            TriggerClientEvent('image_placer:imageDownloadResult', src, requestId, false, nil, ('HTTP %s'):format(tostring(statusCode)))
            return
        end

        if Config.MaxImageBytes and #body > Config.MaxImageBytes then
            TriggerClientEvent('image_placer:imageDownloadResult', src, requestId, false, nil,
                ('image too large (%.1fMB, max %.1fMB)'):format(#body / 1048576, Config.MaxImageBytes / 1048576))
            return
        end

        local contentType = headers and (headers['content-type'] or headers['Content-Type']) or ''
        local base64Body = base64Encode(body)

        if Config.Debug then
            print(('[image_placer] download request #%d sending %d bytes (base64) to client'):format(requestId, #base64Body))
        end

        -- latent so this doesn't block/starve the rest of this client's
        -- network channel while it streams down
        TriggerLatentClientEvent('image_placer:imageDownloadResult', src, Config.ImageTransferBps or 500000,
            requestId, true, base64Body, contentType)
    end, 'GET', '', {})
end)

local function loadPlacements()
    MySQL.query('SELECT id, corners, imageUrl, alpha, drawDistance, placedBy, createdAt FROM idk_image_placer_placements', {}, function(rows)
        if not rows then
            print('^1[image_placer] ERROR: failed to load placements from MySQL - is the idk_image_placer_placements table imported? See install.sql.^0')
            ready = true
            return
        end

        for _, row in ipairs(rows) do
            local ok, corners = pcall(json.decode, row.corners)
            if ok and type(corners) == 'table' then
                placements[tostring(row.id)] = {
                    corners = corners,
                    imageUrl = row.imageUrl,
                    alpha = row.alpha,
                    drawDistance = row.drawDistance, -- nil/NULL = use the client's default
                    placedBy = row.placedBy,
                    createdAt = row.createdAt
                }
                if row.id > nextId then nextId = row.id end
            end
        end

        ready = true
        if Config.Debug then
            print(('[image_placer] loaded %d placement(s) from MySQL'):format(#rows))
        end
    end)
end

loadPlacements()

local function placementCountFor(playerName)
    local count = 0
    for _, p in pairs(placements) do
        if p.placedBy == playerName then count = count + 1 end
    end
    return count
end

local function clampDrawDistance(v)
    v = tonumber(v)
    if not v then return nil end -- nil = use the client's default, not an error
    local lo = Config.MinPlacementDrawDistance or 10.0
    local hi = Config.MaxPlacementDrawDistance or 3000.0
    if v < lo then v = lo end
    if v > hi then v = hi end
    return v
end

local function clampAlpha(v, fallback)
    v = tonumber(v)
    if not v then return fallback end
    if v < 0 then v = 0 end
    if v > 255 then v = 255 end -- matches the TINYINT UNSIGNED column - out-of-range values fail the insert/update otherwise
    return math.floor(v)
end

-- Only the player who placed something (matched by name) or an admin may
-- edit/delete it - otherwise anyone with use-permission could edit/delete
-- everyone's placements.
--
-- NOTE: ownership is matched by player name, the only identifier stored
-- with a placement. Names aren't unique/spoof-proof - swap placedBy to
-- store an identifier (e.g. license) if you need hard per-player identity.
local function canModify(src, p)
    if checkAccess(src, 'admin') then return true end
    return p.placedBy ~= nil and p.placedBy == GetPlayerName(src)
end

RegisterNetEvent('image_placer:requestAccess', function()
    local src = source

    local allowed = checkAccess(src, 'use')
    local isAdmin = checkAccess(src, 'admin')

    if Config.Debug then
        print(('[image_placer] access request from %s -> allowed=%s admin=%s')
            :format(GetPlayerName(src), tostring(allowed), tostring(isAdmin)))
    end

    TriggerClientEvent('image_placer:accessResult', src, allowed, isAdmin, {
        maxPlacementsPerPlayer = Config.MaxPlacementsPerPlayer,
        maxRaycastDistance = Config.MaxRaycastDistance,
        defaultDrawDistance = Config.DefaultDrawDistance,
        minPlacementDrawDistance = Config.MinPlacementDrawDistance,
        maxPlacementDrawDistance = Config.MaxPlacementDrawDistance,
        defaultWidth = Config.DefaultWidth,
        defaultHeight = Config.DefaultHeight,
        canvasResolution = Config.CanvasResolution
    })
end)

-- Deliberately not permission-gated: existing world placements should be
-- visible to everyone who loads in, not just people who can place new ones.
RegisterNetEvent('image_placer:syncPlacements', function()
    local src = source

    if ready then
        TriggerClientEvent('image_placer:initialPlacements', src, placements)
        return
    end

    -- Player synced before the initial MySQL load finished (e.g. joining
    -- right as the resource starts) - wait for it instead of sending them
    -- an empty table.
    CreateThread(function()
        while not ready do Wait(50) end
        TriggerClientEvent('image_placer:initialPlacements', src, placements)
    end)
end)

RegisterNetEvent('image_placer:createPlacement', function(corners, imageUrl, alpha, nonce, drawDistance)
    local src = source
    if not checkAccess(src, 'use') then
        if nonce then TriggerClientEvent('image_placer:createPlacementAck', src, nonce, nil) end
        return
    end

    if type(corners) ~= 'table' or #corners ~= 4 then return end
    if type(imageUrl) ~= 'string' or imageUrl == '' then return end

    local playerName = GetPlayerName(src)

    if Config.MaxPlacementsPerPlayer and Config.MaxPlacementsPerPlayer > 0 then
        if placementCountFor(playerName) >= Config.MaxPlacementsPerPlayer then
            TriggerClientEvent('image_placer:createPlacementFailed', src, ('Limit reached (%d max placements)'):format(Config.MaxPlacementsPerPlayer))
            if nonce then TriggerClientEvent('image_placer:createPlacementAck', src, nonce, nil) end
            return
        end
    end

    local alphaValue = clampAlpha(alpha, 255)
    local drawDistanceValue = clampDrawDistance(drawDistance)
    local createdAt = os.time()

    local insertId = MySQL.insert.await(
        'INSERT INTO idk_image_placer_placements (corners, imageUrl, alpha, drawDistance, placedBy, createdAt) VALUES (?, ?, ?, ?, ?, ?)',
        { json.encode(corners), imageUrl, alphaValue, drawDistanceValue, playerName, createdAt }
    )

    if not insertId then
        if Config.Debug then
            print(('[image_placer] ERROR: MySQL insert failed for %s'):format(playerName))
        end
        TriggerClientEvent('image_placer:createPlacementFailed', src, 'Database error - placement was not saved')
        if nonce then TriggerClientEvent('image_placer:createPlacementAck', src, nonce, nil) end
        return
    end

    local id = insertId
    local key = tostring(id)
    if id > nextId then nextId = id end

    placements[key] = {
        corners = corners, -- plain {x=,y=,z=} tables, JSON-safe
        imageUrl = imageUrl,
        alpha = alphaValue,
        drawDistance = drawDistanceValue,
        placedBy = playerName,
        createdAt = createdAt
    }

    if Config.Debug then
        print(('[image_placer] %s placed #%d'):format(playerName, id))
    end
    logActivity('create', playerName, id)

    TriggerClientEvent('image_placer:placementAdded', -1, id, placements[key])
    if nonce then TriggerClientEvent('image_placer:createPlacementAck', src, nonce, id) end
end)

RegisterNetEvent('image_placer:updatePlacement', function(id, corners, alpha, drawDistance)
    local src = source
    if not checkAccess(src, 'use') then return end

    local numericId = tonumber(id)
    local key = tostring(numericId)
    local p = placements[key]
    if not p then return end
    if not canModify(src, p) then
        TriggerClientEvent('image_placer:createPlacementFailed', src, 'You can only edit your own placements')
        return
    end

    if type(corners) == 'table' and #corners == 4 then p.corners = corners end
    if alpha ~= nil then p.alpha = clampAlpha(alpha, p.alpha) end
    if drawDistance ~= nil then p.drawDistance = clampDrawDistance(drawDistance) end

    MySQL.update.await(
        'UPDATE idk_image_placer_placements SET corners = ?, alpha = ?, drawDistance = ? WHERE id = ?',
        { json.encode(p.corners), p.alpha, p.drawDistance, numericId }
    )
    logActivity('update', GetPlayerName(src), numericId)

    TriggerClientEvent('image_placer:placementUpdated', -1, numericId, p)
end)

RegisterNetEvent('image_placer:removePlacement', function(id)
    local src = source
    if not checkAccess(src, 'use') then return end

    local numericId = tonumber(id)
    local key = tostring(numericId)
    local p = placements[key]
    if not p then return end
    if not canModify(src, p) then
        TriggerClientEvent('image_placer:createPlacementFailed', src, 'You can only remove your own placements')
        return
    end

    placements[key] = nil
    MySQL.update.await('DELETE FROM idk_image_placer_placements WHERE id = ?', { numericId })
    logActivity('remove', GetPlayerName(src), numericId)
    TriggerClientEvent('image_placer:placementRemoved', -1, numericId)
end)

RegisterNetEvent('image_placer:removeAllPlacements', function()
    local src = source
    if not checkAccess(src, 'admin') then return end

    placements = {}
    MySQL.update.await('DELETE FROM idk_image_placer_placements', {})
    logActivity('remove_all', GetPlayerName(src))
    TriggerClientEvent('image_placer:allPlacementsRemoved', -1)
end)

---------------------------------------------------------------------
-- Admin panel: live stats, activity log, moderation, bulk tools
---------------------------------------------------------------------

RegisterNetEvent('image_placer:requestAdminData', function()
    local src = source
    if not checkAccess(src, 'admin') then return end

    local totalPlacements = 0
    local byPlayer = {}
    for _, p in pairs(placements) do
        totalPlacements = totalPlacements + 1
        local name = p.placedBy or 'unknown'
        byPlayer[name] = (byPlayer[name] or 0) + 1
    end

    local topPlacers = {}
    for name, count in pairs(byPlayer) do
        topPlacers[#topPlacers + 1] = { name = name, count = count }
    end
    table.sort(topPlacers, function(a, b) return a.count > b.count end)

    local playersList = {}
    for _, playerIdStr in ipairs(GetPlayers()) do
        local pid = tonumber(playerIdStr)
        local override = sessionOverrides[pid]
        playersList[#playersList + 1] = {
            id = pid,
            name = GetPlayerName(pid),
            canUse = checkAccess(pid, 'use'),
            isAdmin = checkAccess(pid, 'admin'),
            overrideUse = override and override.use,
            overrideAdmin = override and override.admin
        }
    end
    table.sort(playersList, function(a, b) return a.name < b.name end)

    TriggerClientEvent('image_placer:adminData', src, {
        totalPlacements = totalPlacements,
        uniquePlacers = #topPlacers,
        topPlacers = topPlacers,
        activity = activityLog,
        players = playersList,
        startedAt = resourceStartedAt
    })
end)

-- Grants/revokes/resets tool access or admin rights for one connected
-- player for the rest of this session only - see sessionOverrides above.
-- `value` is true (grant), false (revoke), or omitted (reset to whatever
-- the configured ACE permission would normally give them).
RegisterNetEvent('image_placer:setSessionOverride', function(targetId, kind, value)
    local src = source
    if not checkAccess(src, 'admin') then return end

    targetId = tonumber(targetId)
    if not targetId or GetPlayerName(targetId) == nil then
        TriggerClientEvent('image_placer:adminActionResult', src, false, 'That player is no longer connected')
        return
    end
    if kind ~= 'use' and kind ~= 'admin' then return end

    -- an admin can't strip their own access/admin rights (accidental
    -- self-lockout) - resetting themselves back to their ACE-configured
    -- default is still fine, only an explicit revoke is blocked
    if targetId == src and value == false then
        TriggerClientEvent('image_placer:adminActionResult', src, false, "You can't revoke your own " .. kind .. ' access')
        return
    end

    sessionOverrides[targetId] = sessionOverrides[targetId] or {}
    sessionOverrides[targetId][kind] = value

    local verb = value == nil and 'reset' or (value and 'granted' or 'revoked')
    logActivity('override', GetPlayerName(src), nil, ('%s %s for %s'):format(verb, kind, GetPlayerName(targetId)))

    TriggerClientEvent('image_placer:adminActionResult', src, true, ('%s %s access for %s'):format(verb, kind, GetPlayerName(targetId)))
    -- if we just revoked their live access, boot them out of the NUI
    if kind == 'use' and value == false then
        TriggerClientEvent('image_placer:accessRevoked', targetId)
    end
end)

local function deleteByIds(ids)
    if #ids == 0 then return end
    local clauses = {}
    for _, id in ipairs(ids) do clauses[#clauses + 1] = tostring(id) end -- ids are already tonumber()-validated ints
    MySQL.update.await(('DELETE FROM idk_image_placer_placements WHERE id IN (%s)'):format(table.concat(clauses, ',')), {})
    for _, id in ipairs(ids) do
        TriggerClientEvent('image_placer:placementRemoved', -1, id)
    end
end

-- Bulk-remove a set of ids (Manage tab multi-select). Each id is still
-- checked via canModify, so a non-admin can only remove their own.
RegisterNetEvent('image_placer:removeMultiple', function(ids)
    local src = source
    if not checkAccess(src, 'use') then return end
    if type(ids) ~= 'table' then return end

    local removed = {}
    for _, rawId in ipairs(ids) do
        local numericId = tonumber(rawId)
        local key = numericId and tostring(numericId)
        local p = key and placements[key]
        if p and canModify(src, p) then
            placements[key] = nil
            removed[#removed + 1] = numericId
        end
    end

    if #removed > 0 then
        deleteByIds(removed)
        logActivity('bulk_remove', GetPlayerName(src), nil, ('%d placement(s)'):format(#removed))
    end
    TriggerClientEvent('image_placer:bulkActionResult', src, #removed, #ids)
end)

-- Admin-only: wipe every placement made by one player (e.g. someone who
-- got banned, or spammed a bunch of bad placements).
RegisterNetEvent('image_placer:removeByPlayer', function(playerName)
    local src = source
    if not checkAccess(src, 'admin') then return end
    if type(playerName) ~= 'string' or playerName == '' then return end

    local removed = {}
    for key, p in pairs(placements) do
        if p.placedBy == playerName then
            removed[#removed + 1] = tonumber(key)
            placements[key] = nil
        end
    end

    if #removed > 0 then
        deleteByIds(removed)
        logActivity('bulk_remove_player', GetPlayerName(src), nil, ('%d placement(s) by %s'):format(#removed, playerName))
    end
    TriggerClientEvent('image_placer:bulkActionResult', src, #removed, #removed)
end)

-- Admin-only: sweep out anything older than N days - handy for events/
-- promo billboards that shouldn't stick around forever.
RegisterNetEvent('image_placer:removeOlderThan', function(days)
    local src = source
    if not checkAccess(src, 'admin') then return end

    days = tonumber(days)
    if not days or days <= 0 then return end
    local cutoff = os.time() - (days * 86400)

    local removed = {}
    for key, p in pairs(placements) do
        if (p.createdAt or 0) < cutoff then
            removed[#removed + 1] = tonumber(key)
            placements[key] = nil
        end
    end

    if #removed > 0 then
        deleteByIds(removed)
        logActivity('bulk_remove_old', GetPlayerName(src), nil, ('%d placement(s) older than %d day(s)'):format(#removed, days))
    end
    TriggerClientEvent('image_placer:bulkActionResult', src, #removed, #removed)
end)

---------------------------------------------------------------------
-- Persisted server defaults
--
-- The regular Settings sliders only change the calling client's local
-- sessionConfig. "Save as server default" is the opposite: updates Config
-- for future access requests, broadcasts live to everyone in the NUI, and
-- persists to the database so it survives a restart.
---------------------------------------------------------------------

local function loadServerDefaults()
    MySQL.query('SELECT maxPlacementsPerPlayer, maxRaycastDistance, defaultDrawDistance FROM idk_image_placer_settings WHERE id = 1', {}, function(rows)
        local row = rows and rows[1]
        if not row then return end
        if row.maxPlacementsPerPlayer ~= nil then Config.MaxPlacementsPerPlayer = row.maxPlacementsPerPlayer end
        if row.maxRaycastDistance ~= nil then Config.MaxRaycastDistance = row.maxRaycastDistance end
        if row.defaultDrawDistance ~= nil then Config.DefaultDrawDistance = row.defaultDrawDistance end
        if Config.Debug then
            print('[image_placer] loaded persisted server defaults from MySQL')
        end
    end)
end

loadServerDefaults()

RegisterNetEvent('image_placer:saveServerDefaults', function(data)
    local src = source
    if not checkAccess(src, 'admin') then return end
    if type(data) ~= 'table' then return end

    local maxPlacements = tonumber(data.maxPlacementsPerPlayer)
    local maxRaycast = tonumber(data.maxRaycastDistance)
    local drawDistance = tonumber(data.defaultDrawDistance)

    if maxPlacements then Config.MaxPlacementsPerPlayer = math.max(0, math.floor(maxPlacements)) end
    if maxRaycast then Config.MaxRaycastDistance = math.max(1, maxRaycast) end
    if drawDistance then Config.DefaultDrawDistance = math.max(1, drawDistance) end

    MySQL.update.await([[
        INSERT INTO idk_image_placer_settings (id, maxPlacementsPerPlayer, maxRaycastDistance, defaultDrawDistance)
        VALUES (1, ?, ?, ?)
        ON DUPLICATE KEY UPDATE maxPlacementsPerPlayer = VALUES(maxPlacementsPerPlayer),
                                 maxRaycastDistance = VALUES(maxRaycastDistance),
                                 defaultDrawDistance = VALUES(defaultDrawDistance)
    ]], { Config.MaxPlacementsPerPlayer, Config.MaxRaycastDistance, Config.DefaultDrawDistance })

    logActivity('save_defaults', GetPlayerName(src))

    TriggerClientEvent('image_placer:serverDefaultsUpdated', -1, {
        maxPlacementsPerPlayer = Config.MaxPlacementsPerPlayer,
        maxRaycastDistance = Config.MaxRaycastDistance,
        defaultDrawDistance = Config.DefaultDrawDistance
    })
    TriggerClientEvent('image_placer:adminActionResult', src, true, 'Saved as the new server default')
end)
