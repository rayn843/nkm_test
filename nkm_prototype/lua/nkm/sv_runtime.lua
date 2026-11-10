util.AddNetworkString("nkm_manifest_begin")
util.AddNetworkString("nkm_manifest_data")
util.AddNetworkString("nkm_chunk_request")
util.AddNetworkString("nkm_chunk_begin")
util.AddNetworkString("nkm_chunk_data")
util.AddNetworkString("nkm_map_clear")

NKM.ActiveMapName = nil
NKM.ActiveMapJSON = nil
NKM.ActiveMap = nil
NKM.ActiveChunks = {}
NKM.ChunkStats = nil
NKM.TransferID = 0
NKM.ActiveGeneration = 0
NKM.ActiveManifestJSON = nil
NKM.ActiveChunkPayloads = {}
NKM.ActiveManifest = nil

local MAP_DIRECTORY = "nkm/maps"

file.CreateDir("nkm")
file.CreateDir(MAP_DIRECTORY)

NKM.CollisionEntities = NKM.CollisionEntities or {}
NKM.CollisionHullCount = 0

-- This entity is a server-authoritative, invisible static physics proxy.
-- Its model supplies a valid base entity; PhysicsInitMultiConvex replaces
-- the model collision with NKM's own convex collision data.
local CollisionProxy = {}
CollisionProxy.Type = "anim"
CollisionProxy.Base = "base_anim"
CollisionProxy.PrintName = "NKM Collision Proxy"
CollisionProxy.Spawnable = false
CollisionProxy.AdminOnly = true

function CollisionProxy:Initialize()
    self:AddEFlags(EFL_FORCE_CHECK_TRANSMIT)
    self:SetModel("models/props_junk/wood_crate001a.mdl")
    self:SetNoDraw(true)
    self:DrawShadow(false)
    self:SetUnFreezable(true)
    self:SetSolid(SOLID_VPHYSICS)

    local convexes = self.NKM_Convexes
    local triangles = self.NKM_Triangles
    if (not istable(convexes) or #convexes == 0)
        and (not istable(triangles) or #triangles < 3) then
        self.NKM_PhysicsError = "no convex or triangle collision data"
        return
    end

    local ok, result = pcall(function()
        if istable(triangles) and #triangles >= 3 then
            -- TriangleSurface is intended for static terrain/displacement.
            -- PhysicsFromMesh consumes MeshVertex records and creates a
            -- zero-volume triangle soup in Source VPhysics.
            return self:PhysicsFromMesh(triangles, self.NKM_SurfaceProp or "default")
        end
        return self:PhysicsInitMultiConvex(convexes, self.NKM_SurfaceProp or "default")
    end)

    if not ok or not result then
        self.NKM_PhysicsError = (istable(self.NKM_Triangles) and "PhysicsFromMesh failed: " or "PhysicsInitMultiConvex failed: ") .. tostring(result)
        return
    end

    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:EnableCustomCollisions()

    local phys = self:GetPhysicsObject()
    if not IsValid(phys) then
        self.NKM_PhysicsError = "physics object is invalid after initialization"
        return
    end

    phys:EnableMotion(false)
    phys:Sleep()
    self.NKM_PhysicsReady = true
end

function CollisionProxy:UpdateTransmitState()
    -- Collision is authoritative on the server; don't send the proxy's
    -- placeholder model to clients as a fake prop.
    return TRANSMIT_NEVER
end

function CollisionProxy:PhysgunPickup()
    return false
end

function CollisionProxy:GravGunPickupAllowed()
    return false
end

scripted_ents.Register(CollisionProxy, "nkm_collision_proxy")

-- Per-displacement contents can disable prop physics or player/NPC hulls.
-- VPhysics is hosted by this proxy Entity, so filter only the affected pairs.
hook.Add("ShouldCollide", "NKM.TriangleSurfaceCollisionChannels", function(first, second)
    if not IsValid(first) or not IsValid(second) then return end

    local proxy, other
    if first:GetClass() == "nkm_collision_proxy" and first.NKM_ProxyType == "TriangleSurface" then
        proxy, other = first, second
    elseif second:GetClass() == "nkm_collision_proxy" and second.NKM_ProxyType == "TriangleSurface" then
        proxy, other = second, first
    else
        return
    end

    if proxy.NKM_NoPhysicsCollision and other:GetMoveType() == MOVETYPE_VPHYSICS then
        return false
    end

    local isHullEntity = other:IsPlayer() or other:IsNPC()
    if not isHullEntity and other.IsNextBot then isHullEntity = other:IsNextBot() end
    if proxy.NKM_NoHullCollision and isHullEntity then return false end
end)

local function surfaceHasPhysicsCollision(surfaceData)
    return surfaceData.physicsCollision ~= false or surfaceData.hullCollision ~= false
end

local function chunkHasTrianglePhysics(chunk)
    for _, surfaceData in ipairs(chunk.triangleSurfaces or {}) do
        if surfaceHasPhysicsCollision(surfaceData) then return true end
    end
    return false
end

local function removeCollisionEntities(entities)
    for _, ent in ipairs(entities or {}) do
        if IsValid(ent) then
            ent:Remove()
        end
    end
end

local function distanceSqrToBounds(position, mins, maxs)
    local dx = position.x < mins.x and mins.x - position.x or (position.x > maxs.x and position.x - maxs.x or 0)
    local dy = position.y < mins.y and mins.y - position.y or (position.y > maxs.y and position.y - maxs.y or 0)
    local dz = position.z < mins.z and mins.z - position.z or (position.z > maxs.z and position.z - maxs.z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function distanceSqrBetweenBounds(aMins, aMaxs, bMins, bMaxs)
    local dx = aMaxs.x < bMins.x and bMins.x - aMaxs.x or (aMins.x > bMaxs.x and aMins.x - bMaxs.x or 0)
    local dy = aMaxs.y < bMins.y and bMins.y - aMaxs.y or (aMins.y > bMaxs.y and aMins.y - bMaxs.y or 0)
    local dz = aMaxs.z < bMins.z and bMins.z - aMaxs.z or (aMins.z > bMaxs.z and aMins.z - bMaxs.z or 0)
    return dx * dx + dy * dy + dz * dz
end

NKM.ServerPhysicsLoadDistance = 4096
NKM.ServerPhysicsUnloadDistance = 6144
NKM.ServerPhysicsEntityKeepDistance = 512
NKM.ServerPhysicsUpdateInterval = 0.5
NKM.NextServerPhysicsUpdate = 0
NKM.CollisionTotalHullCount = 0
NKM.CollisionResidentChunkCount = 0

local function addGlobalCollisionEntities(entities)
    NKM.CollisionEntities = NKM.CollisionEntities or {}
    for _, ent in ipairs(entities or {}) do
        if IsValid(ent) then
            NKM.CollisionEntities[#NKM.CollisionEntities + 1] = ent
        end
    end
end

local function removeGlobalCollisionEntities(entities)
    for _, ent in ipairs(entities or {}) do
        for index = #NKM.CollisionEntities, 1, -1 do
            if NKM.CollisionEntities[index] == ent then
                table.remove(NKM.CollisionEntities, index)
            end
        end
    end
end

local function chunkHasPhysicsGeometry(chunk)
    if not chunk then return false end
    if #(chunk.collision or {}) > 0 then return true end
    return chunkHasTrianglePhysics(chunk)
end

function NKM.CreateCollisionChunk(chunk, registerGlobal)
    if not istable(chunk) then return false, "invalid collision chunk" end
    chunk.collision = chunk.collision or {}
    chunk.triangleSurfaces = chunk.triangleSurfaces or {}
    if chunk.collisionResident then
        return true, chunk.collisionEntities or {}
    end
    if not chunkHasPhysicsGeometry(chunk) then
        chunk.collisionResident = true
        chunk.collisionEntities = {}
        chunk.collisionProxyCount = 0
        return true, {}
    end

    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    local function include(x, y, z)
        minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
        maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
    end

    for _, convexData in ipairs(chunk.collision) do
        for _, point in ipairs(convexData.vertices or {}) do
            include(point[1], point[2], point[3])
        end
    end
    for _, surfaceData in ipairs(chunk.triangleSurfaces) do
        if surfaceHasPhysicsCollision(surfaceData) then
            for _, point in ipairs(surfaceData.vertices or {}) do
                include(point[1], point[2], point[3])
            end
        end
    end

    if minX == math.huge then
        chunk.collisionResident = true
        chunk.collisionEntities = {}
        chunk.collisionProxyCount = 0
        return true, {}
    end

    local origin = Vector(
        (minX + maxX) * 0.5,
        (minY + maxY) * 0.5,
        (minZ + maxZ) * 0.5
    )
    local convexGroups, convexOrder = {}, {}
    local triangleGroups, triangleOrder = {}, {}

    for _, convexData in ipairs(chunk.collision) do
        local surface = convexData.surface or "default"
        if not convexGroups[surface] then
            convexGroups[surface] = {}
            convexOrder[#convexOrder + 1] = surface
        end
        local localPoints = {}
        for _, point in ipairs(convexData.vertices) do
            localPoints[#localPoints + 1] = Vector(
                point[1] - origin.x,
                point[2] - origin.y,
                point[3] - origin.z
            )
        end
        convexGroups[surface][#convexGroups[surface] + 1] = localPoints
    end

    for _, surfaceData in ipairs(chunk.triangleSurfaces) do
        local physicsCollision = surfaceData.physicsCollision ~= false
        local hullCollision = surfaceData.hullCollision ~= false
        if physicsCollision or hullCollision then
            local surface = surfaceData.surface or "default"
            local groupKey = surface .. "|p" .. (physicsCollision and "1" or "0")
                .. "h" .. (hullCollision and "1" or "0")
            if not triangleGroups[groupKey] then
                triangleGroups[groupKey] = {
                    surface = surface,
                    physicsCollision = physicsCollision,
                    hullCollision = hullCollision,
                    triangles = {}
                }
                triangleOrder[#triangleOrder + 1] = groupKey
            end
            local group = triangleGroups[groupKey]
            for _, point in ipairs(surfaceData.vertices or {}) do
                group.triangles[#group.triangles + 1] = {
                    pos = Vector(
                        point[1] - origin.x,
                        point[2] - origin.y,
                        point[3] - origin.z
                    )
                }
            end
        end
    end

    local created = {}
    local function spawnProxy(surface, convexes, triangles, proxyType, collisionFlags)
        local proxy = ents.Create("nkm_collision_proxy")
        if not IsValid(proxy) then
            return false, "could not create " .. proxyType .. " proxy for chunk " .. tostring(chunk.id)
        end

        proxy:SetPos(origin)
        proxy.NKM_Convexes = convexes
        proxy.NKM_Triangles = triangles
        proxy.NKM_SurfaceProp = surface
        proxy.NKM_ChunkID = chunk.id
        proxy.NKM_ProxyType = proxyType
        if collisionFlags then
            proxy.NKM_NoPhysicsCollision = not collisionFlags.physicsCollision
            proxy.NKM_NoHullCollision = not collisionFlags.hullCollision
        end

        local spawnOK, spawnError = pcall(function()
            proxy:Spawn()
            proxy:Activate()
        end)

        if not spawnOK or not IsValid(proxy) or not proxy.NKM_PhysicsReady then
            local reason = IsValid(proxy)
                and (proxy.NKM_PhysicsError or spawnError or "collision proxy did not initialize")
                or (spawnError or "entity removed during spawn")
            if IsValid(proxy) then proxy:Remove() end
            return false, "collision creation failed for chunk " .. tostring(chunk.id)
                .. " surface '" .. surface .. "' (" .. proxyType .. "): " .. tostring(reason)
        end

        created[#created + 1] = proxy
        return true
    end

    for _, surface in ipairs(convexOrder) do
        local ok, err = spawnProxy(surface, convexGroups[surface], nil, "ConvexSolid")
        if not ok then
            removeCollisionEntities(created)
            return false, err
        end
    end

    for _, groupKey in ipairs(triangleOrder) do
        local group = triangleGroups[groupKey]
        if #group.triangles >= 3 then
            local ok, err = spawnProxy(group.surface, nil, group.triangles, "TriangleSurface", group)
            if not ok then
                removeCollisionEntities(created)
                return false, err
            end
        end
    end

    chunk.collisionEntities = created
    chunk.collisionResident = true
    chunk.collisionProxyCount = #created
    chunk.collisionRetryAt = nil
    if registerGlobal ~= false then
        addGlobalCollisionEntities(created)
    end
    return true, created
end

function NKM.RemoveCollisionChunk(chunk)
    if not chunk or not chunk.collisionResident then return false end

    local entities = chunk.collisionEntities or {}
    removeGlobalCollisionEntities(entities)
    removeCollisionEntities(entities)

    chunk.collisionEntities = nil
    chunk.collisionProxyCount = 0
    chunk.collisionResident = false
    return true
end

local function collectResidencyAnchors()
    local playerPositions = {}
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:Alive() then
            playerPositions[#playerPositions + 1] = ply:GetPos()
        end
    end

    local physicsBounds = {}
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:GetClass() ~= "nkm_collision_proxy"
            and ent:GetMoveType() == MOVETYPE_VPHYSICS then
            local phys = ent:GetPhysicsObject()
            if IsValid(phys) then
                local entMins, entMaxs = ent:WorldSpaceAABB()
                physicsBounds[#physicsBounds + 1] = {
                    mins = entMins,
                    maxs = entMaxs
                }
            end
        end
    end

    return playerPositions, physicsBounds
end

local function shouldKeepCollisionChunk(chunk, playerPositions, physicsBounds)
    local wasResident = chunk.collisionResident == true
    local playerDistance = wasResident and NKM.ServerPhysicsUnloadDistance or NKM.ServerPhysicsLoadDistance
    local playerDistanceSqr = playerDistance * playerDistance

    for _, position in ipairs(playerPositions or {}) do
        if distanceSqrToBounds(position, chunk.mins, chunk.maxs) <= playerDistanceSqr then
            return true
        end
    end

    -- Nearby VPhysics objects keep collision resident even when no player is
    -- close. Bounds are collected once per update, not once per chunk.
    local entityKeepDistance = NKM.ServerPhysicsEntityKeepDistance
    local entityKeepDistanceSqr = entityKeepDistance * entityKeepDistance
    for _, bounds in ipairs(physicsBounds or {}) do
        if distanceSqrBetweenBounds(chunk.mins, chunk.maxs, bounds.mins, bounds.maxs) <= entityKeepDistanceSqr then
            return true
        end
    end

    return false
end

local function refreshCollisionStats(runtimeChunks)
    local proxies, hulls, residentChunks, totalHulls = 0, 0, 0, 0
    local totalTrianglePatches, residentTrianglePatches, totalTriangles, residentTriangles = 0, 0, 0, 0
    for _, chunk in ipairs(runtimeChunks or NKM.ActiveChunks or {}) do
        local chunkHullCount = #(chunk.collision or {})
        local chunkTriangleSurfaceCount, chunkTriangleCount = 0, 0
        totalHulls = totalHulls + chunkHullCount
        for _, triangleSurface in ipairs(chunk.triangleSurfaces or {}) do
            if surfaceHasPhysicsCollision(triangleSurface) then
                chunkTriangleSurfaceCount = chunkTriangleSurfaceCount + 1
                chunkTriangleCount = chunkTriangleCount + #(triangleSurface.vertices or {}) / 3
            end
        end
        totalTrianglePatches = totalTrianglePatches + chunkTriangleSurfaceCount
        totalTriangles = totalTriangles + chunkTriangleCount
        if chunk.collisionResident and (chunkHullCount > 0 or chunkTriangleSurfaceCount > 0) then
            residentTriangles = residentTriangles + chunkTriangleCount
            residentChunks = residentChunks + 1
            hulls = hulls + chunkHullCount
            residentTrianglePatches = residentTrianglePatches + chunkTriangleSurfaceCount
            proxies = proxies + (chunk.collisionProxyCount or 0)
        end
    end

    NKM.CollisionProxyCount = proxies
    NKM.CollisionHullCount = hulls
    NKM.CollisionResidentChunkCount = residentChunks
    NKM.CollisionTotalHullCount = totalHulls
    NKM.TriangleSurfaceTotalCount = totalTrianglePatches
    NKM.TriangleSurfaceResidentCount = residentTrianglePatches
    NKM.TriangleCount = totalTriangles
    NKM.TriangleResidentCount = residentTriangles
end

function NKM.CreateCollisionWorld(runtimeChunks)
    if not istable(runtimeChunks) then
        return nil, "runtime chunk list is invalid"
    end

    local created = {}
    local playerPositions, physicsBounds = collectResidencyAnchors()
    for _, chunk in ipairs(runtimeChunks) do
        if chunkHasPhysicsGeometry(chunk) and shouldKeepCollisionChunk(chunk, playerPositions, physicsBounds) then
            local ok, result = NKM.CreateCollisionChunk(chunk, false)
            if not ok then
                for _, builtChunk in ipairs(runtimeChunks) do
                    NKM.RemoveCollisionChunk(builtChunk)
                end
                removeCollisionEntities(created)
                return nil, result
            end
            for _, ent in ipairs(result or {}) do
                created[#created + 1] = ent
            end
        end
    end

    local totalHulls, totalTriangleSurfaces = 0, 0
    for _, chunk in ipairs(runtimeChunks) do
        totalHulls = totalHulls + #(chunk.collision or {})
        totalTriangleSurfaces = totalTriangleSurfaces + #(chunk.triangleSurfaces or {})
    end
    return created, totalHulls, totalTriangleSurfaces
end

function NKM.UpdateServerPhysicsStreaming(force)
    if not NKM.ActiveMapName or not NKM.ActiveChunks then return end

    local now = CurTime()
    if not force and now < (NKM.NextServerPhysicsUpdate or 0) then return end
    NKM.NextServerPhysicsUpdate = now + NKM.ServerPhysicsUpdateInterval

    local changed = false
    local playerPositions, physicsBounds = collectResidencyAnchors()
    for _, chunk in ipairs(NKM.ActiveChunks) do
        if chunkHasPhysicsGeometry(chunk) then
            local wanted = shouldKeepCollisionChunk(chunk, playerPositions, physicsBounds)
            if wanted and not chunk.collisionResident then
                local retryAt = chunk.collisionRetryAt or 0
                if now >= retryAt then
                    local ok, result = NKM.CreateCollisionChunk(chunk)
                    if ok then
                        changed = true
                    else
                        chunk.collisionRetryAt = now + 5
                        ErrorNoHalt("[NKM] Could not activate collision chunk " .. tostring(chunk.id)
                            .. ": " .. tostring(result) .. "\n")
                    end
                end
            elseif not wanted and chunk.collisionResident then
                NKM.RemoveCollisionChunk(chunk)
                changed = true
            end
        end
    end

    if changed or force then
        refreshCollisionStats(NKM.ActiveChunks)
    end
end



local function mapPath(name)
    return MAP_DIRECTORY .. "/" .. name .. ".json"
end

local function canUseCommand(ply)
    if not IsValid(ply) then return true end
    return ply:IsAdmin()
end

function NKM.WriteMap(name, mapTable)
    if not NKM.IsValidMapName(name) then
        return false, "invalid map name"
    end

    local validateStartedAt = NKM.PerfBegin()
    local valid, detail = NKM.ValidateMap(mapTable)
    NKM.PerfRecord("map_write_validate", validateStartedAt)
    if not valid then
        return false, detail
    end

    local encodeStartedAt = NKM.PerfBegin()
    local json = util.TableToJSON(mapTable, false)
    NKM.PerfRecord("map_json_encode", encodeStartedAt)
    if not isstring(json) or json == "" then
        return false, "JSON encoding failed"
    end

    if #json > NKM.MaxMapBytes then
        return false, "map exceeds prototype size limit"
    end

    local writeStartedAt = NKM.PerfBegin()
    local success = file.Write(mapPath(name), json)
    NKM.PerfRecord("map_file_write", writeStartedAt)
    NKM.PerfAdd("map_file_bytes_written", #json)
    if not success then
        return false, "file.Write failed"
    end

    return true, #json
end

local function vectorToArray(vector)
    return { vector.x, vector.y, vector.z }
end

function NKM.BuildStreamPayloads(mapName, runtimeChunks, chunkStats, generation, lightingSettings)
    local buildStartedAt = NKM.PerfBegin()
    if not istable(runtimeChunks) then return nil, nil, "runtime chunk list is invalid" end

    local clientLighting = nil
    if istable(lightingSettings) and lightingSettings.enabled ~= false then
        local hasDeferredSettings = istable(lightingSettings.deferred)
        local deferredSettings = hasDeferredSettings and lightingSettings.deferred or {}
        local ambient = lightingSettings.ambient or { 32, 32, 32 }
        clientLighting = {
            enabled = true,
            shadows = lightingSettings.shadows ~= false,
            ambient = { ambient[1] or 32, ambient[2] or 32, ambient[3] or 32 },
            deferred = {
                -- Do not silently enable screen-space AO on old baked-only maps.
                -- A map opts into deferred effects by supplying lighting.deferred.
                ao = hasDeferredSettings and deferredSettings.ao ~= false,
                contactShadows = hasDeferredSettings and deferredSettings.contactShadows ~= false,
                aoRadius = deferredSettings.aoRadius == nil and 72 or deferredSettings.aoRadius,
                aoStrength = deferredSettings.aoStrength == nil and 0.35 or deferredSettings.aoStrength
            },
            directional = {},
            point = {}
        }
        for _, light in ipairs(lightingSettings.directional or {}) do
            clientLighting.directional[#clientLighting.directional + 1] = {
                direction = { light.direction[1], light.direction[2], light.direction[3] },
                color = { (light.color or { 255, 255, 255 })[1], (light.color or { 255, 255, 255 })[2], (light.color or { 255, 255, 255 })[3] },
                intensity = light.intensity == nil and 1 or light.intensity,
                shadows = light.shadows ~= false
            }
        end
        -- Ship static and dynamic point lights. The client keeps static point
        -- lights vertex-baked until its matching deferred VCS shader is enabled.
        for _, light in ipairs(lightingSettings.point or {}) do
            clientLighting.point[#clientLighting.point + 1] = {
                position = { light.position[1], light.position[2], light.position[3] },
                color = { (light.color or { 255, 255, 255 })[1], (light.color or { 255, 255, 255 })[2], (light.color or { 255, 255, 255 })[3] },
                intensity = light.intensity == nil and 1 or light.intensity,
                radius = light.radius,
                shadows = light.shadows ~= false,
                dynamic = light.dynamic == true
            }
        end
    end

    local manifest = {
        format = "NKM_MANIFEST",
        version = NKM.Version,
        mapName = mapName,
        generation = generation,
        chunkSize = chunkStats and chunkStats.chunkSize or NKM.DefaultChunkSize,
        lighting = clientLighting,
        chunks = {}
    }
    local payloads = {}

    for index, chunk in ipairs(runtimeChunks) do
        local chunkTable = {
            format = "NKM_CHUNK",
            version = NKM.Version,
            name = mapName,
            index = index,
            id = chunk.id,
            ix = chunk.ix,
            iy = chunk.iy,
            iz = chunk.iz,
            meshes = chunk.meshes or {},
            collision = chunk.collision or {},
            triangleSurfaces = chunk.triangleSurfaces or {}
        }

        local chunkEncodeStartedAt = NKM.PerfBegin()
        local chunkJSON = util.TableToJSON(chunkTable, false)
        NKM.PerfRecord("chunk_json_encode", chunkEncodeStartedAt)
        if not isstring(chunkJSON) or chunkJSON == "" then
            return nil, nil, "could not encode chunk " .. tostring(chunk.id)
        end
        if #chunkJSON > NKM.MaxMapBytes then
            return nil, nil, "chunk " .. tostring(chunk.id) .. " exceeds chunk payload limit"
        end

        payloads[index] = chunkJSON
        manifest.chunks[index] = {
            id = chunk.id,
            ix = chunk.ix,
            iy = chunk.iy,
            iz = chunk.iz,
            mins = vectorToArray(chunk.mins),
            maxs = vectorToArray(chunk.maxs),
            bytes = #chunkJSON,
            checksum = util.CRC(chunkJSON),
            meshGroups = #(chunk.meshes or {}),
            collisionCount = #(chunk.collision or {}),
            triangleSurfaceCount = #(chunk.triangleSurfaces or {})
        }
    end

    local manifestJSON = util.TableToJSON(manifest, false)
    if not isstring(manifestJSON) or manifestJSON == "" then
        return nil, nil, "could not encode chunk manifest"
    end
    if #manifestJSON > NKM.MaxManifestBytes then
        return nil, nil, "manifest exceeds configured size limit"
    end

    NKM.PerfRecord("stream_payload_build", buildStartedAt)
    NKM.PerfAdd("stream_raw_bytes_built", (function()
        local total = #manifestJSON
        for _, payload in ipairs(payloads) do total = total + #payload end
        return total
    end)())
    return manifestJSON, payloads, manifest
end

local function sendManifestPayload(ply)
    local sendStartedAt = NKM.PerfBegin()
    if not IsValid(ply) or not NKM.ActiveManifestJSON then return false end

    local payload = NKM.ActiveManifestJSON
    local totalParts = math.ceil(#payload / NKM.NetworkChunkBytes)
    if totalParts < 1 or totalParts > 65535 then return false end

    net.Start("nkm_manifest_begin")
        net.WriteUInt(NKM.ActiveGeneration, 16)
        net.WriteString(NKM.ActiveMapName or "unknown")
        net.WriteUInt(totalParts, 16)
        net.WriteUInt(#payload, 32)
        net.WriteString(util.CRC(payload))
    net.Send(ply)

    for partIndex = 1, totalParts do
        local startByte = (partIndex - 1) * NKM.NetworkChunkBytes + 1
        local part = string.sub(payload, startByte, startByte + NKM.NetworkChunkBytes - 1)
        net.Start("nkm_manifest_data")
            net.WriteUInt(NKM.ActiveGeneration, 16)
            net.WriteUInt(partIndex, 16)
            net.WriteUInt(#part, 16)
            net.WriteData(part, #part)
        net.Send(ply)
    end

    NKM.PerfRecord("manifest_network_send", sendStartedAt)
    NKM.PerfAdd("manifest_network_bytes", #payload)
    NKM.PerfAdd("manifest_network_packets", totalParts + 1)
    return true
end

function NKM.SendManifestTo(ply)
    return sendManifestPayload(ply)
end

function NKM.SendChunkTo(ply, chunkIndex)
    local sendStartedAt = NKM.PerfBegin()
    if not IsValid(ply) or not NKM.ActiveChunkPayloads then return false end
    local payload = NKM.ActiveChunkPayloads[chunkIndex]
    if not payload then return false end

    local totalParts = math.ceil(#payload / NKM.NetworkChunkBytes)
    if totalParts < 1 or totalParts > 65535 then return false end
    local checksum = util.CRC(payload)

    net.Start("nkm_chunk_begin")
        net.WriteUInt(NKM.ActiveGeneration, 16)
        net.WriteUInt(chunkIndex, 16)
        net.WriteUInt(totalParts, 16)
        net.WriteUInt(#payload, 32)
        net.WriteString(checksum)
    net.Send(ply)

    for partIndex = 1, totalParts do
        local startByte = (partIndex - 1) * NKM.NetworkChunkBytes + 1
        local part = string.sub(payload, startByte, startByte + NKM.NetworkChunkBytes - 1)
        net.Start("nkm_chunk_data")
            net.WriteUInt(NKM.ActiveGeneration, 16)
            net.WriteUInt(chunkIndex, 16)
            net.WriteUInt(partIndex, 16)
            net.WriteUInt(#part, 16)
            net.WriteData(part, #part)
        net.Send(ply)
    end

    NKM.PerfRecord("chunk_network_send", sendStartedAt)
    NKM.PerfAdd("chunk_network_bytes", #payload)
    NKM.PerfAdd("chunk_network_packets", totalParts + 1)
    NKM.PerfAdd("chunk_network_transfers", 1)
    return true
end

local function distanceSqrToBounds(position, mins, maxs)
    local dx = position.x < mins.x and mins.x - position.x or (position.x > maxs.x and position.x - maxs.x or 0)
    local dy = position.y < mins.y and mins.y - position.y or (position.y > maxs.y and position.y - maxs.y or 0)
    local dz = position.z < mins.z and mins.z - position.z or (position.z > maxs.z and position.z - maxs.z or 0)
    return dx * dx + dy * dy + dz * dz
end

net.Receive("nkm_chunk_request", function(_, ply)
    if not IsValid(ply) or not NKM.ActiveMapName then return end

    local generation = net.ReadUInt(16)
    local chunkIndex = net.ReadUInt(16)
    if generation ~= NKM.ActiveGeneration then return end

    local chunk = NKM.ActiveChunks[chunkIndex]
    if not chunk then return end

    local now = CurTime()
    if now < (ply.NKM_NextChunkRequestAt or 0) then return end
    ply.NKM_NextChunkRequestAt = now + 0.10

    -- Clients may only request chunks near their authoritative server position.
    local requestDistance = NKM.ServerChunkRequestDistance or 8192
    if distanceSqrToBounds(ply:GetPos(), chunk.mins, chunk.maxs) > requestDistance * requestDistance then
        return
    end

    ply.NKM_ChunkRequestTimes = ply.NKM_ChunkRequestTimes or {}
    local requestKey = tostring(generation) .. ":" .. tostring(chunkIndex)
    if now < (ply.NKM_ChunkRequestTimes[requestKey] or 0) then return end
    ply.NKM_ChunkRequestTimes[requestKey] = now + 0.25

    NKM.SendChunkTo(ply, chunkIndex)
end)

function NKM.LoadMap(name)
    if not NKM.IsValidMapName(name) then
        return false, "invalid map name"
    end

    local readStartedAt = NKM.PerfBegin()
    local payload = file.Read(mapPath(name), "DATA")
    NKM.PerfRecord("map_file_read", readStartedAt)
    if not payload then
        return false, "map file not found: data/" .. mapPath(name)
    end

    if #payload > NKM.MaxMapBytes then
        return false, "map exceeds prototype size limit"
    end

    local decodeStartedAt = NKM.PerfBegin()
    local mapTable = util.JSONToTable(payload)
    NKM.PerfRecord("map_json_decode", decodeStartedAt)
    NKM.PerfAdd("map_source_bytes_read", #payload)
    if not mapTable then
        return false, "JSON parsing failed"
    end

    local validateStartedAt = NKM.PerfBegin()
    local valid, detail = NKM.ValidateMap(mapTable)
    NKM.PerfRecord("map_validate", validateStartedAt)
    if not valid then
        return false, "map validation failed: " .. tostring(detail)
    end

    if mapTable.name ~= name then
        return false, "map name in file does not match requested name"
    end

    -- Build the NKM collision BVH first so the lighting baker can test whether
    -- a NKM surface has a clear ray to each light. This is NKM-only: the BSP
    -- world is not modified and does not become part of the NKM light bake.
    local traceBuildStartedAt = NKM.PerfBegin()
    local newTraceMap, traceBuildError = NKM.BuildTraceData(mapTable, name)
    NKM.PerfRecord("map_trace_build", traceBuildStartedAt)
    if not newTraceMap then
        return false, "trace data build failed: " .. tostring(traceBuildError)
    end

    -- Bake NKM-authored lighting independently from the Source BSP lightmap.
    -- The trace map is temporarily exposed to the baker for NKM shadow rays.
    local previousTraceMap = NKM.TraceMap
    NKM.TraceMap = newTraceMap
    if NKM.BakeMapLighting then
        local bakeCallOK, lightingOK, lightingStats = pcall(NKM.BakeMapLighting, mapTable)
        NKM.TraceMap = previousTraceMap
        if not bakeCallOK then
            return false, "NKM lighting bake crashed: " .. tostring(lightingOK)
        end
        if not lightingOK then
            return false, "NKM lighting bake failed: " .. tostring(lightingStats)
        end
        NKM.ActiveLightingStats = lightingStats
    else
        NKM.TraceMap = previousTraceMap
    end

    -- Build final render chunks after baking so copied displacement vertices
    -- receive the same baked NKM lighting as ordinary mesh vertices.
    local chunkBuildStartedAt = NKM.PerfBegin()
    local newChunks, chunkStats = NKM.BuildChunks(mapTable)
    NKM.PerfRecord("map_chunk_partition", chunkBuildStartedAt)
    if not newChunks then
        return false, "chunk build failed: " .. tostring(chunkStats)
    end
    NKM.PerfAdd("map_runtime_chunks", #newChunks)
    NKM.PerfAdd("map_collision_hulls", chunkStats.collisionConvexes or 0)
    local sourceVertexCount = 0
    for _, meshData in ipairs(mapTable.meshes or {}) do
        sourceVertexCount = sourceVertexCount + #(meshData.vertices or {})
    end
    NKM.PerfAdd("map_render_vertices", sourceVertexCount)

    local nextGeneration = ((NKM.ActiveGeneration or 0) % 65535) + 1
    local newManifestJSON, newChunkPayloads, newManifest = NKM.BuildStreamPayloads(
        name, newChunks, chunkStats, nextGeneration, mapTable.lighting
    )
    if newManifestJSON then
        NKM.PerfAdd("map_manifest_bytes", #newManifestJSON)
        NKM.PerfAdd("map_chunk_payloads", #newChunkPayloads)
    end
    if not newManifestJSON then
        return false, "stream preparation failed: " .. tostring(newManifest)
    end

    local collisionBuildStartedAt = NKM.PerfBegin()
    local newCollisionEntities, collisionResult, triangleSurfaceResult = NKM.CreateCollisionWorld(newChunks)
    NKM.PerfRecord("map_collision_residency_init", collisionBuildStartedAt)
    if not newCollisionEntities then
        return false, "collision build failed: " .. tostring(collisionResult)
    end

    local oldCollisionEntities = NKM.CollisionEntities or {}
    hook.Run("NKMMapUnloading", NKM.ActiveMapName, NKM.ActiveMap)

    NKM.ActiveMapName = name
    NKM.ActiveMapJSON = payload
    NKM.ActiveMap = mapTable
    NKM.ActiveChunks = newChunks
    NKM.ChunkStats = chunkStats
    NKM.TraceMap = newTraceMap
    NKM.ActiveGeneration = nextGeneration
    NKM.ActiveManifestJSON = newManifestJSON
    NKM.ActiveManifest = newManifest
    NKM.ActiveChunkPayloads = newChunkPayloads
    NKM.CollisionEntities = newCollisionEntities
    NKM.CollisionHullCount = 0
    NKM.CollisionProxyCount = #newCollisionEntities
    NKM.CollisionResidentChunkCount = 0
    NKM.CollisionTotalHullCount = collisionResult or 0
    NKM.TriangleSurfaceTotalCount = triangleSurfaceResult or 0
    refreshCollisionStats(newChunks)
    NKM.NextServerPhysicsUpdate = 0

    removeCollisionEntities(oldCollisionEntities)

    for _, player in ipairs(player.GetAll()) do
        player.NKM_ChunkRequestTimes = {}
        player.NKM_NextChunkRequestAt = 0
        NKM.SendManifestTo(player)
    end

    hook.Run("NKMMapLoaded", name, mapTable)
    print(string.format(
        "[NKM] Loaded '%s' (%d bytes, %d chunks, %d stream bytes, %d collision hulls)",
        name, #payload, chunkStats.chunkCount, (function()
            local total = #newManifestJSON
            for _, chunkPayload in ipairs(newChunkPayloads) do total = total + #chunkPayload end
            return total
        end)(), NKM.CollisionHullCount
    ))
    if NKM.ActiveLightingStats and NKM.ActiveLightingStats.enabled then
        print(string.format("[NKM] Lighting: %d vertices baked (%d mesh, %d displacement), directional=%d staticPoint=%d deferredPoint=%d",
            NKM.ActiveLightingStats.totalVertices or 0,
            NKM.ActiveLightingStats.meshVertices or 0,
            NKM.ActiveLightingStats.displacementVertices or 0,
            NKM.ActiveLightingStats.directionalLights or 0,
            NKM.ActiveLightingStats.pointLights or 0,
            NKM.ActiveLightingStats.dynamicPointLights or 0))
        print(string.format("[NKM] Lighting shadows: enabled=%s rays=%d occluded=%d traceFailures=%d",
            tostring(NKM.ActiveLightingStats.shadowsEnabled == true),
            NKM.ActiveLightingStats.shadowRays or 0,
            NKM.ActiveLightingStats.shadowHits or 0,
            NKM.ActiveLightingStats.shadowTraceFailures or 0))
    end
    if (NKM.TriangleSurfaceTotalCount or 0) > 0 then
        print(string.format("[NKM] TriangleSurface: %d patches, %d triangles; PhysicsFromMesh proxies are active near players.",
            NKM.TriangleSurfaceTotalCount, NKM.TriangleCount or 0))
    end

    return true, mapTable
end

function NKM.UnloadMap()
    hook.Run("NKMMapUnloading", NKM.ActiveMapName, NKM.ActiveMap)

    removeCollisionEntities(NKM.CollisionEntities)
    NKM.CollisionEntities = {}
    NKM.CollisionHullCount = 0
    NKM.CollisionProxyCount = 0
    NKM.CollisionResidentChunkCount = 0
    NKM.CollisionTotalHullCount = 0
    NKM.TriangleSurfaceTotalCount = 0
    NKM.TriangleSurfaceResidentCount = 0
    NKM.TriangleCount = 0
    NKM.TriangleResidentCount = 0
    NKM.ActiveMapName = nil
    NKM.ActiveMapJSON = nil
    NKM.ActiveMap = nil
    NKM.ActiveLightingStats = nil
    NKM.ActiveChunks = {}
    NKM.ChunkStats = nil
    NKM.TraceMap = nil
    NKM.ActiveManifestJSON = nil
    NKM.ActiveManifest = nil
    NKM.ActiveChunkPayloads = {}
    NKM.ActiveGeneration = ((NKM.ActiveGeneration or 0) % 65535) + 1

    net.Start("nkm_map_clear")
    net.Broadcast()

    hook.Run("NKMMapUnloaded")
    print("[NKM] Runtime map unloaded")
    return true
end

hook.Add("PlayerInitialSpawn", "NKM.SyncOnJoin", function(ply)
    timer.Simple(2, function()
        if IsValid(ply) and NKM.ActiveMapJSON then
            NKM.SendManifestTo(ply)
            NKM.UpdateServerPhysicsStreaming(true)
        end
    end)
end)

hook.Add("PlayerSpawn", "NKM.RefreshPhysicsStreaming", function()
    timer.Simple(0.25, function()
        NKM.UpdateServerPhysicsStreaming(true)
    end)
end)

hook.Add("Think", "NKM.ServerPhysicsStreaming", function()
    NKM.UpdateServerPhysicsStreaming(false)
end)

concommand.Add("nkm_test", function(ply)
    if not canUseCommand(ply) then return end

    local origin = Vector(0, 0, 0)
    if IsValid(ply) then
        origin = ply:GetPos() - Vector(0, 0, 8)
    end

    local demo = NKM.BuildDemoMap(origin)
    local written, writeResult = NKM.WriteMap("demo", demo)
    if not written then
        print("[NKM] Could not write demo map: " .. tostring(writeResult))
        return
    end

    local loaded, loadResult = NKM.LoadMap("demo")
    if not loaded then
        print("[NKM] Could not load demo map: " .. tostring(loadResult))
        return
    end

    print("[NKM] Demo created with client IMesh rendering and server VPhysics collision hulls.")
end)

concommand.Add("nkm_benchmark", function(ply, _, args)
    if not canUseCommand(ply) then return end

    args = args or {}
    local mode, targetChunks
    if tonumber(args[1]) then
        -- Backwards-compatible form: nkm_benchmark 500 / 1000.
        mode = "render"
        targetChunks = tonumber(args[1])
    else
        mode = string.lower(tostring(args[1] or "render"))
        targetChunks = tonumber(args[2])
    end

    if mode == "render" then
        targetChunks = targetChunks or 500
        if targetChunks ~= 500 and targetChunks ~= 1000 then
            print("[NKM] Usage: nkm_benchmark render <500|1000>")
            print("[NKM] Legacy syntax remains supported: nkm_benchmark <500|1000>")
            return
        end
    elseif mode == "fullphysics" then
        targetChunks = targetChunks or 100
        if targetChunks ~= 100 then
            print("[NKM] Usage: nkm_benchmark fullphysics 100")
            return
        end
    else
        print("[NKM] Usage: nkm_benchmark <render 500|render 1000|fullphysics 100>")
        return
    end

    local origin = Vector(0, 0, 0)
    if IsValid(ply) then
        origin = ply:GetPos()
    end

    local generateStartedAt = NKM.PerfBegin()
    local benchmarkMap, benchmarkStats = NKM.BuildBenchmarkMap(targetChunks, origin, mode)
    NKM.PerfRecord("benchmark_map_generate", generateStartedAt)
    if not benchmarkMap then
        print("[NKM] Benchmark generation failed: " .. tostring(benchmarkStats))
        return
    end

    local writeOK, writeResult = NKM.WriteMap(benchmarkStats.name, benchmarkMap)
    if not writeOK then
        print("[NKM] Benchmark write failed: " .. tostring(writeResult))
        return
    end

    local loadOK, loadResult = NKM.LoadMap(benchmarkStats.name)
    if not loadOK then
        print("[NKM] Benchmark load failed: " .. tostring(loadResult))
        return
    end

    benchmarkStats.fileBytes = writeResult
    benchmarkStats.actualChunks = NKM.ChunkStats and NKM.ChunkStats.chunkCount or 0
    benchmarkStats.actualCollisionChunks = NKM.ChunkStats and NKM.ChunkStats.collisionChunks or 0
    benchmarkStats.streamBytes = NKM.ActiveManifestJSON and #NKM.ActiveManifestJSON or 0
    for _, chunkPayload in ipairs(NKM.ActiveChunkPayloads or {}) do
        benchmarkStats.streamBytes = benchmarkStats.streamBytes + #chunkPayload
    end
    NKM.BenchmarkInfo = benchmarkStats

    print(string.format(
        "[NKM] Benchmark '%s' mode=%s loaded: chunks=%d/%d grid=%dx%d vertices=%d collisionHulls=%d collisionChunks=%d file=%d bytes stream=%d bytes",
        benchmarkStats.name, benchmarkStats.mode, benchmarkStats.actualChunks,
        benchmarkStats.renderChunksExpected, benchmarkStats.columns, benchmarkStats.rows,
        benchmarkStats.renderVertices, benchmarkStats.collisionHulls,
        benchmarkStats.actualCollisionChunks, benchmarkStats.fileBytes, benchmarkStats.streamBytes
    ))
    if benchmarkStats.mode == "fullphysics" then
        print("[NKM] Every tile has a VPhysics collision hull (100/100). Physics remains streamed by player distance.")
    else
        print("[NKM] Render stress mode: 500/1000 visual chunks; one in every 10 tiles has a VPhysics collision hull.")
    end
end)

concommand.Add("nkm_benchmark_status", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local info = NKM.BenchmarkInfo
    if not info or NKM.ActiveMapName ~= info.name then
        print("[NKM] No synthetic benchmark map is currently active")
        return
    end

    print(string.format("[NKM] Benchmark map: %s mode=%s (%dx%d grid)", info.name, info.mode or "render", info.columns, info.rows))
    print(string.format("[NKM] Chunks: %d/%d; render vertices: %d", info.actualChunks, info.renderChunksExpected, info.renderVertices))
    print(string.format("[NKM] Collision hulls: %d; collision chunks: %d; collision stride: 1/%d",
        info.collisionHulls, info.actualCollisionChunks, info.collisionStride))
    print(string.format("[NKM] Map file: %d bytes; stream payload + manifest: %d bytes", info.fileBytes, info.streamBytes))
    print("[NKM] Chunk size: " .. tostring(info.chunkSize) .. "; floor Z: " .. tostring(info.floorZ))
end)

concommand.Add("nkm_trace_test", function(ply)
    if not canUseCommand(ply) then return end
    if not NKM.TraceMap or (#NKM.TraceMap.convexes == 0 and #NKM.TraceMap.triangles == 0) then
        print("[NKM] No active NKM collision map")
        return
    end

    local bounds = NKM.TraceMap
    local centerX = (bounds.mins.x + bounds.maxs.x) * 0.5
    local centerY = (bounds.mins.y + bounds.maxs.y) * 0.5
    local centerZ = (bounds.mins.z + bounds.maxs.z) * 0.5
    local startPos, endPos
    if #NKM.TraceMap.triangles > 0 then
        startPos = Vector(centerX, centerY, bounds.maxs.z + 256)
        endPos = Vector(centerX, centerY, bounds.mins.z - 256)
    else
        startPos = Vector(centerX, centerY, centerZ)
        endPos = startPos + Vector((bounds.maxs.x - bounds.mins.x) + 128, 0, 0)
    end
    local trace = NKM.TraceLine({ start = startPos, endpos = endPos, nkmOnly = true })

    local stats = NKM.GetTraceStats() or {}
    print(string.format(
        "[NKM] Trace test: Hit=%s HitNKM=%s Fraction=%.4f Surface=%s Convex=%s Triangle=%s Chunks=%d/%d BVH=%d/%d tested=%d",
        tostring(trace.Hit), tostring(trace.HitNKM), trace.Fraction or 1,
        tostring(trace.SurfaceProp), tostring(trace.NKM and trace.NKM.ConvexIndex or "none"),
        tostring(trace.NKM and trace.NKM.TriangleIndex or "none"),
        stats.LastChunkCount or 0, stats.ChunkCount or 0,
        stats.LastCandidateCount or 0, (stats.ConvexCount or 0) + (stats.TriangleCount or 0), stats.LastTestedCount or 0
    ))
end)

concommand.Add("nkm_displacement_test", function(ply)
    if not canUseCommand(ply) then return end
    local origin = IsValid(ply) and ply:GetPos() or Vector(0, 0, 0)
    local mapTable = NKM.BuildDisplacementTestMap(origin)
    local saved, saveResult = NKM.WriteMap(mapTable.name, mapTable)
    if not saved then
        print("[NKM] Displacement test save failed: " .. tostring(saveResult))
        return
    end
    local loaded, loadResult = NKM.LoadMap(mapTable.name)
    if not loaded then
        print("[NKM] Displacement test load failed: " .. tostring(loadResult))
        return
    end
    print("[NKM] Displacement terrain created: grid=25x25 triangles=1152; inspect the hills with noclip and walk on the surface.")
end)


-- Sandbox prop placement bridge ------------------------------------------------
-- The stock Sandbox GetSpawnTrace() uses util.TraceLine directly. NKM terrain
-- is represented by its own triangle BVH as well as server-side VPhysics
-- proxies, so use the combined NKM trace to correct prop placement when an
-- NKM surface is nearer than the underlying Source BSP hit.
local function getSandboxAimTrace(ply, ent)
    local startPos = ply:GetShootPos()
    local endPos = startPos + ply:EyeAngles():Forward() * 2048
    local filter = { ply, ent }
    local vehicle = ply:GetVehicle()
    if IsValid(vehicle) then
        filter[#filter + 1] = vehicle
    end

    return {
        start = startPos,
        endpos = endPos,
        filter = filter
    }
end

local function isSpawnedEntityNearAimRay(ent, startPos, endPos)
    local delta = endPos - startPos
    local lengthSqr = delta:LengthSqr()
    if lengthSqr <= 0 then return false end

    local along = math.Clamp((ent:GetPos() - startPos):Dot(delta) / lengthSqr, 0, 1)
    local nearest = startPos + delta * along
    local radius = 128
    local ok, boundsRadius = pcall(function() return ent:BoundingRadius() end)
    if ok and isnumber(boundsRadius) and boundsRadius > radius then
        radius = boundsRadius + 64
    end

    return ent:GetPos():DistToSqr(nearest) <= radius * radius
end

local function placeSpawnedEntityOnNKM(ent, trace)
    if not IsValid(ent) or not istable(trace) or not trace.HitNKM
        or not isvector(trace.HitPos) or not isvector(trace.HitNormal) then
        return false
    end

    -- Match Sandbox's DoPlayerEntitySpawn() flush calculation so the nearest
    -- point of the prop rests on the NKM surface, including sloped terrain.
    local currentPos = ent:GetPos()
    local flushProbe = trace.HitPos - trace.HitNormal * 512
    local nearestPoint = ent:NearestPoint(flushProbe)
    if not isvector(nearestPoint) then return false end

    local targetPos = trace.HitPos + (currentPos - nearestPoint)
    ent:SetPos(targetPos)
    ent.NKM_SpawnedOnNKM = true
    ent.NKM_SpawnMap = NKM.ActiveMapName
    ent.NKM_SpawnChunkID = trace.NKM and trace.NKM.ChunkID or nil
    ent.NKM_SpawnTriangleIndex = trace.NKM and trace.NKM.TriangleIndex or nil
    ent.NKM_SpawnSurface = trace.SurfaceProp or (trace.NKM and trace.NKM.SurfaceProp) or "default"

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
    return true
end

hook.Add("PlayerSpawnedProp", "NKM.SandboxPropPlacement", function(ply, model, ent)
    if not IsValid(ply) or not IsValid(ent) or not NKM.TraceMap then return end

    local traceData = getSandboxAimTrace(ply, ent)
    if not isSpawnedEntityNearAimRay(ent, traceData.start, traceData.endpos) then return end

    local trace = NKM.TraceLine(traceData)
    if not trace or not trace.HitNKM or trace.StartSolid then return end

    local generation = NKM.ActiveGeneration
    -- Correct immediately, then once more next tick because Sandbox's own
    -- TryFixPropPosition() runs after PlayerSpawnedProp and may adjust it.
    placeSpawnedEntityOnNKM(ent, trace)
    timer.Simple(0, function()
        if not IsValid(ent) or generation ~= NKM.ActiveGeneration
            or not NKM.TraceMap or ent.NKM_SpawnMap ~= NKM.ActiveMapName then
            return
        end
        placeSpawnedEntityOnNKM(ent, trace)
    end)
end)

concommand.Add("nkm_spawn_trace_test", function(ply)
    if not canUseCommand(ply) then return end
    if not IsValid(ply) then
        print("[NKM] nkm_spawn_trace_test must be run by a player")
        return
    end
    if not NKM.TraceMap then
        print("[NKM] No active NKM map")
        return
    end

    local traceData = getSandboxAimTrace(ply, NULL)
    local sourceTrace = util.TraceLine({
        start = traceData.start,
        endpos = traceData.endpos,
        filter = { ply, IsValid(ply:GetVehicle()) and ply:GetVehicle() or NULL }
    })
    local combinedTrace = NKM.TraceLine(traceData)

    local sourceClass = IsValid(sourceTrace.Entity) and sourceTrace.Entity:GetClass() or (sourceTrace.HitWorld and "world" or "none")
    print(string.format(
        "[NKM] Spawn ray Source: Hit=%s Fraction=%.4f Class=%s Pos=%s",
        tostring(sourceTrace.Hit), sourceTrace.Fraction or 1, sourceClass, tostring(sourceTrace.HitPos)
    ))
    print(string.format(
        "[NKM] Spawn ray Combined: Hit=%s HitNKM=%s Fraction=%.4f Surface=%s Triangle=%s Chunk=%s Pos=%s",
        tostring(combinedTrace.Hit), tostring(combinedTrace.HitNKM), combinedTrace.Fraction or 1,
        tostring(combinedTrace.SurfaceProp),
        tostring(combinedTrace.NKM and combinedTrace.NKM.TriangleIndex or "none"),
        tostring(combinedTrace.NKM and combinedTrace.NKM.ChunkID or "none"),
        tostring(combinedTrace.HitPos)
    ))
end)

concommand.Add("nkm_load", function(ply, _, args)
    if not canUseCommand(ply) then return end

    local name = args[1]
    if not name then
        print("Usage: nkm_load <map_name>")
        return
    end

    local loaded, result = NKM.LoadMap(name)
    if not loaded then
        print("[NKM] Load failed: " .. tostring(result))
    end
end)

concommand.Add("nkm_unload", function(ply)
    if not canUseCommand(ply) then return end
    NKM.UnloadMap()
end)

concommand.Add("nkm_server_chunks", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end

    local chunks = NKM.ActiveChunks or {}
    local resident, totalConvexes, totalTriangleSurfaces = 0, 0, 0
    for _, chunk in ipairs(chunks) do
        local convexCount = #(chunk.collision or {})
        local triangleCount = 0
        for _, surfaceData in ipairs(chunk.triangleSurfaces or {}) do
            if surfaceHasPhysicsCollision(surfaceData) then
                triangleCount = triangleCount + 1
            end
        end
        if chunk.collisionResident and (convexCount > 0 or triangleCount > 0) then
            resident = resident + 1
        end
        totalConvexes = totalConvexes + convexCount
        totalTriangleSurfaces = totalTriangleSurfaces + triangleCount
    end

    print(string.format("[NKM] Server collision chunks: %d/%d resident, convexes=%d trianglePatches=%d",
        resident, (NKM.ChunkStats and NKM.ChunkStats.collisionChunks) or 0,
        totalConvexes, totalTriangleSurfaces))
    for _, chunk in ipairs(chunks) do
        local convexCount = #(chunk.collision or {})
        local trianglePatchCount, triangleCount = 0, 0
        for _, surfaceData in ipairs(chunk.triangleSurfaces or {}) do
            if surfaceHasPhysicsCollision(surfaceData) then
                trianglePatchCount = trianglePatchCount + 1
                triangleCount = triangleCount + #(surfaceData.vertices or {}) / 3
            end
        end
        if convexCount > 0 or trianglePatchCount > 0 then
            print(string.format("[NKM] Chunk %s resident=%s proxies=%d convexes=%d trianglePatches=%d triangles=%d retryAt=%.2f",
                chunk.id, tostring(chunk.collisionResident == true), chunk.collisionProxyCount or 0,
                convexCount, trianglePatchCount, triangleCount, chunk.collisionRetryAt or 0))
        end
    end
end)

concommand.Add("nkm_server_perf", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    NKM.PerfPrint("NKM Server")
end)

concommand.Add("nkm_server_perf_reset", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    NKM.PerfReset()
    print("[NKM Server] Performance counters reset")
end)

concommand.Add("nkm_status", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end

    print("[NKM] Runtime version: " .. tostring(NKM.RuntimeVersion))
    print("[NKM] Format version: " .. tostring(NKM.Version))
    print("[NKM] Active map: " .. tostring(NKM.ActiveMapName or "none"))
    print("[NKM] Active payload bytes: " .. tostring(NKM.ActiveMapJSON and #NKM.ActiveMapJSON or 0))
    print(string.format("[NKM] Lua heap: %.1f MB (excludes native VPhysics/renderer allocations)", collectgarbage("count") / 1024))
    print("[NKM] Manifest bytes: " .. tostring(NKM.ActiveManifestJSON and #NKM.ActiveManifestJSON or 0))
    print("[NKM] Streamed chunks: " .. tostring(#(NKM.ActiveChunkPayloads or {})))
    print("[NKM] Generation: " .. tostring(NKM.ActiveGeneration or 0))
    print("[NKM] Collision proxies: " .. tostring(NKM.CollisionProxyCount or #(NKM.CollisionEntities or {})))
    print("[NKM] Collision chunks resident: " .. tostring(NKM.CollisionResidentChunkCount or 0)
        .. "/" .. tostring(NKM.ChunkStats and NKM.ChunkStats.collisionChunks or 0))
    print("[NKM] Collision convexes resident: " .. tostring(NKM.CollisionHullCount or 0)
        .. "/" .. tostring(NKM.CollisionTotalHullCount or 0))
    print("[NKM] Triangle surface patches resident: " .. tostring(NKM.TriangleSurfaceResidentCount or 0)
        .. "/" .. tostring(NKM.TriangleSurfaceTotalCount or 0))
    print("[NKM] Triangle collision triangles resident: " .. tostring(NKM.TriangleResidentCount or 0)
        .. "/" .. tostring(NKM.TriangleCount or 0))
    print("[NKM] Server physics distances: load=" .. tostring(NKM.ServerPhysicsLoadDistance)
        .. " unload=" .. tostring(NKM.ServerPhysicsUnloadDistance))
    print("[NKM] Chunks: " .. tostring(NKM.ChunkStats and NKM.ChunkStats.chunkCount or 0))
    print("[NKM] Chunk size: " .. tostring(NKM.ChunkStats and NKM.ChunkStats.chunkSize or NKM.DefaultChunkSize))
    if NKM.BenchmarkInfo and NKM.ActiveMapName == NKM.BenchmarkInfo.name then
        print(string.format("[NKM] Synthetic benchmark: %dx%d (%d expected chunks)",
            NKM.BenchmarkInfo.columns, NKM.BenchmarkInfo.rows, NKM.BenchmarkInfo.renderChunksExpected))
    end
    print("[NKM] Trace chunks: " .. tostring(NKM.TraceMap and #NKM.TraceMap.chunks or 0))
    print("[NKM] Trace convexes: " .. tostring(NKM.TraceMap and #NKM.TraceMap.convexes or 0))
    print("[NKM] Trace triangles: " .. tostring(NKM.TraceMap and #NKM.TraceMap.triangles or 0))
    print("[NKM] Trace planes: " .. tostring(NKM.TraceMap and NKM.TraceMap.planeCount or 0))
    local traceStats = NKM.GetTraceStats()
    if traceStats then
        print(string.format(
            "[NKM] Trace BVH: nodes=%d leaves=%d depth=%d leafSize=%d",
            traceStats.BVHNodeCount, traceStats.BVHLeafCount,
            traceStats.BVHDepth, traceStats.BVHLeafSize
        ))
        print(string.format(
            "[NKM] Last trace chunks: %d/%d, candidates: %d/%d (convexes=%d triangles=%d)",
            traceStats.LastChunkCount, traceStats.ChunkCount,
            traceStats.LastCandidateCount, traceStats.ConvexCount + (traceStats.TriangleCount or 0),
            traceStats.ConvexCount, traceStats.TriangleCount or 0
        ))
    end
end)
