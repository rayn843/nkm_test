NKM = NKM or {}

NKM.Name = "NikNaks Map Runtime"
NKM.Version = 1 -- File format version
NKM.RuntimeVersion = "0.9.9-r6-pixel-lighting"
NKM.FormatMagic = "NKM"
NKM.MaxMapBytes = 2 * 1024 * 1024
NKM.MaxVertices = 250000
NKM.MaxCollisionConvexes = 128
NKM.MaxCollisionPointsPerConvex = 32
NKM.MeshVertexLimit = 60000 -- IMesh limit is documented as 65535; leave headroom.
NKM.NetworkChunkBytes = 30000 -- Conservative payload size including net headers.
NKM.MaxManifestBytes = 4 * 1024 * 1024
NKM.DefaultChunkSize = 512
NKM.MaxChunks = 2048

local function isFiniteNumber(value)
    return isnumber(value) and value == value and value ~= math.huge and value ~= -math.huge
end

local function validVectorArray(value)
    return istable(value)
        and isFiniteNumber(value[1])
        and isFiniteNumber(value[2])
        and isFiniteNumber(value[3])
end

-- NKM's own static lighting is stored as map metadata and baked to per-vertex
-- RGB multipliers when the map is loaded. It does not read the Source BSP lightmap.
NKM.Lighting = NKM.Lighting or {}
NKM.Lighting.Version = 2
NKM.Lighting.ShadowBias = 1.0
NKM.MaxLightingDirectionalLights = 4
NKM.MaxLightingPointLights = 32

local function validLightingColor(value)
    if not istable(value) then return false end
    for channel = 1, 3 do
        if not isFiniteNumber(value[channel]) or value[channel] < 0 or value[channel] > 255 then
            return false
        end
    end
    return true
end

local function validateLighting(lighting)
    if lighting == nil then return true end
    if not istable(lighting) then return false, "lighting must be a table" end
    if lighting.enabled ~= nil and not isbool(lighting.enabled) then
        return false, "lighting.enabled must be a boolean"
    end
    if lighting.shadows ~= nil and not isbool(lighting.shadows) then
        return false, "lighting.shadows must be a boolean"
    end
    if lighting.ambient ~= nil and not validLightingColor(lighting.ambient) then
        return false, "lighting.ambient must be RGB values in 0..255"
    end

    local directional = lighting.directional
    if directional == nil then directional = {} end
    if not istable(directional) or #directional > NKM.MaxLightingDirectionalLights then
        return false, "lighting.directional must contain at most " .. NKM.MaxLightingDirectionalLights .. " lights"
    end
    for index, light in ipairs(directional) do
        if not istable(light) or not validVectorArray(light.direction) then
            return false, "invalid direction at NKM directional light #" .. index
        end
        local x, y, z = light.direction[1], light.direction[2], light.direction[3]
        if x * x + y * y + z * z < 0.000001 then
            return false, "zero direction at NKM directional light #" .. index
        end
        if light.color ~= nil and not validLightingColor(light.color) then
            return false, "invalid color at NKM directional light #" .. index
        end
        if light.shadows ~= nil and not isbool(light.shadows) then
            return false, "shadows at NKM directional light #" .. index .. " must be a boolean"
        end
        local intensity = light.intensity == nil and 1 or light.intensity
        if not isFiniteNumber(intensity) or intensity < 0 or intensity > 8 then
            return false, "intensity at NKM directional light #" .. index .. " must be in 0..8"
        end
    end

    local point = lighting.point
    if point == nil then point = {} end
    if not istable(point) or #point > NKM.MaxLightingPointLights then
        return false, "lighting.point must contain at most " .. NKM.MaxLightingPointLights .. " lights"
    end
    for index, light in ipairs(point) do
        if not istable(light) or not validVectorArray(light.position) then
            return false, "invalid position at NKM point light #" .. index
        end
        if light.color ~= nil and not validLightingColor(light.color) then
            return false, "invalid color at NKM point light #" .. index
        end
        if light.shadows ~= nil and not isbool(light.shadows) then
            return false, "shadows at NKM point light #" .. index .. " must be a boolean"
        end
        if light.dynamic ~= nil and not isbool(light.dynamic) then
            return false, "dynamic at NKM point light #" .. index .. " must be a boolean"
        end
        local intensity = light.intensity == nil and 1 or light.intensity
        if not isFiniteNumber(intensity) or intensity < 0 or intensity > 8 then
            return false, "intensity at NKM point light #" .. index .. " must be in 0..8"
        end
        if not isFiniteNumber(light.radius) or light.radius <= 0 or light.radius > 16384 then
            return false, "radius at NKM point light #" .. index .. " must be in 0..16384"
        end
    end

    local deferred = lighting.deferred
    if deferred ~= nil then
        if not istable(deferred) then return false, "lighting.deferred must be a table" end
        for _, key in ipairs({ "ao", "contactShadows" }) do
            if deferred[key] ~= nil and not isbool(deferred[key]) then
                return false, "lighting.deferred." .. key .. " must be a boolean"
            end
        end
        local aoRadius = deferred.aoRadius == nil and 72 or deferred.aoRadius
        if not isFiniteNumber(aoRadius) or aoRadius < 1 or aoRadius > 512 then
            return false, "lighting.deferred.aoRadius must be in 1..512"
        end
        local aoStrength = deferred.aoStrength == nil and 0.35 or deferred.aoStrength
        if not isFiniteNumber(aoStrength) or aoStrength < 0 or aoStrength > 1 then
            return false, "lighting.deferred.aoStrength must be in 0..1"
        end
    end

    return true
end

function NKM.IsValidMapName(name)
    return isstring(name) and #name > 0 and #name <= 48 and name:match("^[%w_%-]+$") ~= nil
end

function NKM.ValidateMap(map)
    if not istable(map) then
        return false, "root must be a table"
    end

    if map.format ~= NKM.FormatMagic then
        return false, "wrong format magic (expected NKM)"
    end

    if map.version ~= NKM.Version then
        return false, "unsupported format version: " .. tostring(map.version)
    end

    if not NKM.IsValidMapName(map.name) then
        return false, "invalid map name"
    end

    if not istable(map.meshes) then
        return false, "meshes must be an array"
    end

    local totalVertices = 0

    for meshIndex, meshData in ipairs(map.meshes) do
        if not istable(meshData) then
            return false, "mesh #" .. meshIndex .. " must be a table"
        end

        if not isstring(meshData.material) or meshData.material == "" then
            return false, "mesh #" .. meshIndex .. " has no material"
        end

        if not istable(meshData.vertices) then
            return false, "mesh #" .. meshIndex .. " has no vertices array"
        end

        local vertexCount = #meshData.vertices
        if vertexCount < 3 or vertexCount % 3 ~= 0 then
            return false, "mesh #" .. meshIndex .. " vertex count must be a multiple of 3"
        end

        totalVertices = totalVertices + vertexCount
        if totalVertices > NKM.MaxVertices then
            return false, "map exceeds prototype vertex limit (" .. NKM.MaxVertices .. ")"
        end

        for vertexIndex, vertex in ipairs(meshData.vertices) do
            if not istable(vertex) or not validVectorArray(vertex.p) then
                return false, "invalid position at mesh " .. meshIndex .. ", vertex " .. vertexIndex
            end

            if vertex.n ~= nil and not validVectorArray(vertex.n) then
                return false, "invalid normal at mesh " .. meshIndex .. ", vertex " .. vertexIndex
            end

            if vertex.uv ~= nil and (not istable(vertex.uv) or not isFiniteNumber(vertex.uv[1]) or not isFiniteNumber(vertex.uv[2])) then
                return false, "invalid UV at mesh " .. meshIndex .. ", vertex " .. vertexIndex
            end

            if vertex.color ~= nil then
                local color = vertex.color
                if not istable(color)
                    or not isFiniteNumber(color[1])
                    or not isFiniteNumber(color[2])
                    or not isFiniteNumber(color[3]) then
                    return false, "invalid color at mesh " .. meshIndex .. ", vertex " .. vertexIndex
                end
            end

            if vertex.nkmLighting ~= nil and not validLightingColor(vertex.nkmLighting) then
                return false, "invalid NKM lighting color at mesh " .. meshIndex .. ", vertex " .. vertexIndex
            end
        end
    end

    if #map.meshes == 0 then
        return false, "map contains no meshes"
    end

    if map.chunkSize ~= nil then
        if not isFiniteNumber(map.chunkSize) or map.chunkSize < 128 or map.chunkSize > 8192 then
            return false, "chunkSize must be between 128 and 8192"
        end
    end

    local lightingValid, lightingError = validateLighting(map.lighting)
    if not lightingValid then return false, lightingError end

    -- Collision geometry is optional so old v1 maps remain readable.
    local collision = map.collision
    if collision ~= nil then
        if not istable(collision) then
            return false, "collision must be an array"
        end

        if #collision > NKM.MaxCollisionConvexes then
            return false, "map exceeds prototype collision convex limit (" .. NKM.MaxCollisionConvexes .. ")"
        end

        for convexIndex, convexData in ipairs(collision) do
            if not istable(convexData) or not istable(convexData.vertices) then
                return false, "collision convex #" .. convexIndex .. " must contain a vertices array"
            end

            local pointCount = #convexData.vertices
            if pointCount < 4 or pointCount > NKM.MaxCollisionPointsPerConvex then
                return false, "collision convex #" .. convexIndex .. " must contain 4-" .. NKM.MaxCollisionPointsPerConvex .. " points"
            end

            if convexData.surface ~= nil then
                if not isstring(convexData.surface)
                    or #convexData.surface == 0
                    or #convexData.surface > 32
                    or not convexData.surface:match("^[%w_]+$") then
                    return false, "invalid surface property at collision convex #" .. convexIndex
                end
            end

            local minX, minY, minZ = math.huge, math.huge, math.huge
            local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

            for pointIndex, point in ipairs(convexData.vertices) do
                if not validVectorArray(point) then
                    return false, "invalid point at collision convex " .. convexIndex .. ", point " .. pointIndex
                end

                minX = math.min(minX, point[1])
                minY = math.min(minY, point[2])
                minZ = math.min(minZ, point[3])
                maxX = math.max(maxX, point[1])
                maxY = math.max(maxY, point[2])
                maxZ = math.max(maxZ, point[3])
            end

            -- VPhysics needs a volume, not a zero-thickness polygon.
            if maxX - minX < 0.01 or maxY - minY < 0.01 or maxZ - minZ < 0.01 then
                return false, "collision convex #" .. convexIndex .. " has zero thickness on an axis"
            end
        end
    end

    return true, totalVertices
end

local function normalizeArray3(value, fallback)
    local x, y, z = value[1], value[2], value[3]
    local lengthSqr = x * x + y * y + z * z
    if lengthSqr <= 0.000001 then
        return fallback[1], fallback[2], fallback[3]
    end
    local inverseLength = 1 / math.sqrt(lengthSqr)
    return x * inverseLength, y * inverseLength, z * inverseLength
end

local function lightRayIsOccluded(position, normal, direction, distance, light, lightIndex, context)
    if not context or not context.shadowsEnabled or light.shadows == false then return false end
    local traceMap = context.traceMap
    if not traceMap or not traceMap.bvh or not isfunction(NKM.TraceLine) then return false end

    local cache = context.visibilityCache[lightIndex]
    if not cache then
        cache = {}
        context.visibilityCache[lightIndex] = cache
    end

    local px, py, pz = position[1], position[2], position[3]
    local nx, ny, nz = normal[1], normal[2], normal[3]
    -- Quantized key reuses the same visibility result for duplicated triangle
    -- vertices (common in box meshes and editor-generated geometry).
    local key = string.format("%.2f,%.2f,%.2f|%.3f,%.3f,%.3f", px, py, pz, nx, ny, nz)
    local cached = cache[key]
    if cached ~= nil then return cached end

    local bias = NKM.Lighting.ShadowBias or 1.0
    local startPos = Vector(px + nx * bias, py + ny * bias, pz + nz * bias)
    local rayEnd = startPos + Vector(direction[1], direction[2], direction[3]) * math.max(0.01, distance - bias)
    local ok, trace = pcall(NKM.TraceLine, {
        start = startPos,
        endpos = rayEnd,
        nkmOnly = true
    })

    -- A failed trace must not black out the whole map. Keep it unoccluded and
    -- expose the failure in the bake statistics for diagnosis.
    if not ok or not istable(trace) then
        context.traceFailures = context.traceFailures + 1
        cache[key] = false
        return false
    end

    context.shadowRays = context.shadowRays + 1
    local occluded = trace.Hit == true or trace.StartSolid == true or trace.AllSolid == true
    if occluded then context.shadowHits = context.shadowHits + 1 end
    cache[key] = occluded
    return occluded
end

local function calculateNKMVertexLighting(position, normal, settings, context)
    local nx, ny, nz = normalizeArray3(normal, { 0, 0, 1 })
    local normalizedNormal = { nx, ny, nz }
    local ambient = settings.ambient or { 32, 32, 32 }
    local red, green, blue = ambient[1], ambient[2], ambient[3]

    for lightIndex, light in ipairs(settings.directional or {}) do
        local lx, ly, lz = normalizeArray3(light.direction, { 0, 0, 1 })
        local diffuse = math.max(0, nx * lx + ny * ly + nz * lz)
        if diffuse > 0 and not lightRayIsOccluded(position, normalizedNormal, { lx, ly, lz }, 65536, light, "d" .. lightIndex, context) then
            local intensity = light.intensity == nil and 1 or light.intensity
            local color = light.color or { 255, 255, 255 }
            red = red + color[1] * intensity * diffuse
            green = green + color[2] * intensity * diffuse
            blue = blue + color[3] * intensity * diffuse
        end
    end

    local px, py, pz = position[1], position[2], position[3]
    for lightIndex, light in ipairs(settings.point or {}) do
        -- Dynamic point lights are evaluated by the optional GShader deferred
        -- pass. Do not bake them into vertex RGB, otherwise they would be lit twice.
        if light.dynamic ~= true then
            local dx = light.position[1] - px
            local dy = light.position[2] - py
            local dz = light.position[3] - pz
            local distanceSqr = dx * dx + dy * dy + dz * dz
            local radius = light.radius
            local radiusSqr = radius * radius
            if distanceSqr < radiusSqr then
                local distance = math.sqrt(distanceSqr)
                local inverseDistance = distance > 0.0001 and (1 / distance) or 0
                local lx, ly, lz = dx * inverseDistance, dy * inverseDistance, dz * inverseDistance
                local diffuse = math.max(0, nx * lx + ny * ly + nz * lz)
                if diffuse > 0 and not lightRayIsOccluded(position, normalizedNormal, { lx, ly, lz }, distance, light, "p" .. lightIndex, context) then
                    local remaining = 1 - distance / radius
                    local attenuation = remaining * remaining
                    local intensity = (light.intensity == nil and 1 or light.intensity) * attenuation * diffuse
                    local color = light.color or { 255, 255, 255 }
                    red = red + color[1] * intensity
                    green = green + color[2] * intensity
                    blue = blue + color[3] * intensity
                end
            end
        end
    end

    return {
        math.Clamp(math.floor(red + 0.5), 0, 255),
        math.Clamp(math.floor(green + 0.5), 0, 255),
        math.Clamp(math.floor(blue + 0.5), 0, 255)
    }
end

local function faceNormalFromVertices(a, b, c)
    local abx, aby, abz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local acx, acy, acz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
    local nx = aby * acz - abz * acy
    local ny = abz * acx - abx * acz
    local nz = abx * acy - aby * acx
    local lengthSqr = nx * nx + ny * ny + nz * nz
    if lengthSqr <= 0.000001 then return { 0, 0, 1 } end
    local inverseLength = 1 / math.sqrt(lengthSqr)
    return { nx * inverseLength, ny * inverseLength, nz * inverseLength }
end

local function bakeMeshLighting(meshes, settings, context)
    local vertexCount = 0
    for _, meshData in ipairs(meshes or {}) do
        local vertices = meshData.vertices or {}
        for index = 1, #vertices, 3 do
            local a, b, c = vertices[index], vertices[index + 1], vertices[index + 2]
            if not c then break end
            local faceNormal = faceNormalFromVertices(a.p, b.p, c.p)
            for offset = 0, 2 do
                local vertex = vertices[index + offset]
                local normal = vertex.n or faceNormal
                vertex.nkmLighting = calculateNKMVertexLighting(vertex.p, normal, settings, context)
                vertexCount = vertexCount + 1
            end
        end
    end
    return vertexCount
end

local function bakeDisplacementLighting(displacements, settings, context)
    local vertexCount = 0
    for _, patch in ipairs(displacements or {}) do
        local width, height = patch.width, patch.height
        local positions = patch.vertices
        local baked = {}
        for y = 0, height - 1 do
            for x = 0, width - 1 do
                local index = y * width + x + 1
                local normal = patch.normals and patch.normals[index]
                if not normal then
                    local leftX, rightX = math.max(0, x - 1), math.min(width - 1, x + 1)
                    local upY, downY = math.max(0, y - 1), math.min(height - 1, y + 1)
                    local left = positions[y * width + leftX + 1]
                    local right = positions[y * width + rightX + 1]
                    local up = positions[upY * width + x + 1]
                    local down = positions[downY * width + x + 1]
                    local tx = { right[1] - left[1], right[2] - left[2], right[3] - left[3] }
                    local ty = { down[1] - up[1], down[2] - up[2], down[3] - up[3] }
                    local nx = tx[2] * ty[3] - tx[3] * ty[2]
                    local ny = tx[3] * ty[1] - tx[1] * ty[3]
                    local nz = tx[1] * ty[2] - tx[2] * ty[1]
                    if patch.flipWinding == true then nx, ny, nz = -nx, -ny, -nz end
                    normal = { nx, ny, nz }
                end
                baked[index] = calculateNKMVertexLighting(positions[index], normal, settings, context)
                vertexCount = vertexCount + 1
            end
        end
        patch.nkmLighting = baked
    end
    return vertexCount
end

function NKM.BakeMapLighting(mapTable)
    if not istable(mapTable) then return false, "invalid map table" end
    local settings = mapTable.lighting
    if not istable(settings) or settings.enabled == false then
        for _, meshData in ipairs(mapTable.meshes or {}) do
            for _, vertex in ipairs(meshData.vertices or {}) do vertex.nkmLighting = nil end
        end
        for _, patch in ipairs(mapTable.displacements or {}) do patch.nkmLighting = nil end
        return true, { enabled = false, vertices = 0 }
    end

    local startedAt = NKM.PerfBegin and NKM.PerfBegin() or nil
    local context = {
        traceMap = NKM.TraceMap,
        shadowsEnabled = settings.shadows ~= false,
        visibilityCache = {},
        shadowRays = 0,
        shadowHits = 0,
        traceFailures = 0
    }
    local meshVertices = bakeMeshLighting(mapTable.meshes, settings, context)
    local displacementVertices = bakeDisplacementLighting(mapTable.displacements, settings, context)
    local dynamicPointLights = 0
    local staticPointLights = 0
    for _, light in ipairs(settings.point or {}) do
        if light.dynamic == true then
            dynamicPointLights = dynamicPointLights + 1
        else
            staticPointLights = staticPointLights + 1
        end
    end

    local stats = {
        enabled = true,
        meshVertices = meshVertices,
        displacementVertices = displacementVertices,
        totalVertices = meshVertices + displacementVertices,
        pointLights = staticPointLights,
        dynamicPointLights = dynamicPointLights,
        directionalLights = #(settings.directional or {}),
        shadowsEnabled = context.shadowsEnabled,
        shadowRays = context.shadowRays,
        shadowHits = context.shadowHits,
        shadowTraceFailures = context.traceFailures
    }
    if startedAt and NKM.PerfRecord then
        NKM.PerfRecord("nkm_lighting_bake", startedAt)
    end
    if NKM.PerfAdd then
        NKM.PerfAdd("nkm_lighting_vertices", stats.totalVertices)
        NKM.PerfAdd("nkm_lighting_point_lights", stats.pointLights)
        NKM.PerfAdd("nkm_lighting_directional_lights", stats.directionalLights)
    end
    return true, stats
end

NKM.Lighting.BakeMap = NKM.BakeMapLighting

local function packVertex(position, normal, u, v, color)
    return {
        p = { position[1], position[2], position[3] },
        n = { normal[1], normal[2], normal[3] },
        uv = { u, v },
        color = { color[1], color[2], color[3], color[4] or 255 }
    }
end

local function addQuad(vertices, p1, p2, p3, p4, normal, color)
    -- Two triangles. Positions are in world coordinates for prototype v1.
    vertices[#vertices + 1] = packVertex(p1, normal, 0, 0, color)
    vertices[#vertices + 1] = packVertex(p2, normal, 1, 0, color)
    vertices[#vertices + 1] = packVertex(p3, normal, 1, 1, color)

    vertices[#vertices + 1] = packVertex(p1, normal, 0, 0, color)
    vertices[#vertices + 1] = packVertex(p3, normal, 1, 1, color)
    vertices[#vertices + 1] = packVertex(p4, normal, 0, 1, color)
end

local function addBoxCollision(out, mins, maxs, surface)
    out[#out + 1] = {
        surface = surface or "concrete",
        vertices = {
            { mins[1], mins[2], mins[3] },
            { mins[1], mins[2], maxs[3] },
            { mins[1], maxs[2], mins[3] },
            { mins[1], maxs[2], maxs[3] },
            { maxs[1], mins[2], mins[3] },
            { maxs[1], mins[2], maxs[3] },
            { maxs[1], maxs[2], mins[3] },
            { maxs[1], maxs[2], maxs[3] }
        }
    }
end


local function chunkKey(x, y, z)
    return tostring(x) .. "_" .. tostring(y) .. "_" .. tostring(z)
end

local function includeChunkPoint(chunk, x, y, z)
    if not chunk.hasBounds then
        chunk.minX, chunk.minY, chunk.minZ = x, y, z
        chunk.maxX, chunk.maxY, chunk.maxZ = x, y, z
        chunk.hasBounds = true
        return
    end

    chunk.minX = math.min(chunk.minX, x)
    chunk.minY = math.min(chunk.minY, y)
    chunk.minZ = math.min(chunk.minZ, z)
    chunk.maxX = math.max(chunk.maxX, x)
    chunk.maxY = math.max(chunk.maxY, y)
    chunk.maxZ = math.max(chunk.maxZ, z)
end

-- Splits triangle lists and convex collision hulls into runtime chunks.
-- Triangles are assigned by centroid (not clipped), so no geometry is lost.
function NKM.BuildChunks(mapTable, requestedChunkSize)
    if not istable(mapTable) then
        return nil, "map table is invalid"
    end

    local chunkSize = requestedChunkSize or mapTable.chunkSize or NKM.DefaultChunkSize
    if not isFiniteNumber(chunkSize) or chunkSize < 128 or chunkSize > 8192 then
        return nil, "chunk size must be between 128 and 8192"
    end

    local chunkByKey = {}
    local chunks = {}

    local function getChunk(x, y, z)
        local ix = math.floor(x / chunkSize)
        local iy = math.floor(y / chunkSize)
        local iz = math.floor(z / chunkSize)
        local key = chunkKey(ix, iy, iz)
        local chunk = chunkByKey[key]

        if not chunk then
            if #chunks >= NKM.MaxChunks then
                return nil, "map exceeds chunk limit (" .. NKM.MaxChunks .. ")"
            end

            chunk = {
                id = key,
                ix = ix, iy = iy, iz = iz,
                meshes = {},
                collision = {},
                _meshLookup = {},
                hasBounds = false
            }
            chunkByKey[key] = chunk
            chunks[#chunks + 1] = chunk
        end

        return chunk
    end

    for meshIndex, meshData in ipairs(mapTable.meshes or {}) do
        local source = meshData.vertices
        for vertexIndex = 1, #source, 3 do
            local v1, v2, v3 = source[vertexIndex], source[vertexIndex + 1], source[vertexIndex + 2]
            if not v3 then
                return nil, "mesh " .. meshIndex .. " contains an incomplete triangle"
            end

            local p1, p2, p3 = v1.p, v2.p, v3.p
            local cx = (p1[1] + p2[1] + p3[1]) / 3
            local cy = (p1[2] + p2[2] + p3[2]) / 3
            local cz = (p1[3] + p2[3] + p3[3]) / 3
            local chunk, err = getChunk(cx, cy, cz)
            if not chunk then return nil, err end

            local groupedMesh = chunk._meshLookup[meshIndex]
            if not groupedMesh then
                groupedMesh = {
                    material = meshData.material,
                    vertices = {},
                    sourceGroup = meshIndex
                }
                chunk._meshLookup[meshIndex] = groupedMesh
                chunk.meshes[#chunk.meshes + 1] = groupedMesh
            end

            for offset = 0, 2 do
                local vertex = source[vertexIndex + offset]
                groupedMesh.vertices[#groupedMesh.vertices + 1] = vertex
                local pos = vertex.p
                includeChunkPoint(chunk, pos[1], pos[2], pos[3])
            end
        end
    end

    for convexIndex, convexData in ipairs(mapTable.collision or {}) do
        local minX, minY, minZ = math.huge, math.huge, math.huge
        local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
        for _, point in ipairs(convexData.vertices) do
            minX = math.min(minX, point[1])
            minY = math.min(minY, point[2])
            minZ = math.min(minZ, point[3])
            maxX = math.max(maxX, point[1])
            maxY = math.max(maxY, point[2])
            maxZ = math.max(maxZ, point[3])
        end

        local centerX = (minX + maxX) * 0.5
        local centerY = (minY + maxY) * 0.5
        local centerZ = (minZ + maxZ) * 0.5
        local chunk, err = getChunk(centerX, centerY, centerZ)
        if not chunk then return nil, err end

        -- Preserve the source collision index across streamed chunks. This keeps
        -- ConvexIndex stable even when the client only has a subset of chunks.
        local runtimeConvex = {
            surface = convexData.surface,
            vertices = convexData.vertices,
            _nkmIndex = convexIndex
        }
        chunk.collision[#chunk.collision + 1] = runtimeConvex
        for _, point in ipairs(convexData.vertices) do
            includeChunkPoint(chunk, point[1], point[2], point[3])
        end
    end

    table.sort(chunks, function(a, b)
        if a.ix ~= b.ix then return a.ix < b.ix end
        if a.iy ~= b.iy then return a.iy < b.iy end
        return a.iz < b.iz
    end)

    for _, chunk in ipairs(chunks) do
        chunk._meshLookup = nil
        chunk.mins = Vector(chunk.minX, chunk.minY, chunk.minZ)
        chunk.maxs = Vector(chunk.maxX, chunk.maxY, chunk.maxZ)
        chunk.minX, chunk.minY, chunk.minZ = nil, nil, nil
        chunk.maxX, chunk.maxY, chunk.maxZ = nil, nil, nil
        chunk.hasBounds = nil
    end

    return chunks, {
        chunkSize = chunkSize,
        chunkCount = #chunks,
        meshGroups = (function()
            local count = 0
            for _, chunk in ipairs(chunks) do count = count + #chunk.meshes end
            return count
        end)(),
        collisionConvexes = (function()
            local count = 0
            for _, chunk in ipairs(chunks) do count = count + #chunk.collision end
            return count
        end)(),
        collisionChunks = (function()
            local count = 0
            for _, chunk in ipairs(chunks) do
                if #chunk.collision > 0 then count = count + 1 end
            end
            return count
        end)()
    }
end

function NKM.BuildDemoMap(origin)
    origin = origin or Vector(0, 0, 0)

    local ox, oy, oz = origin.x, origin.y, origin.z
    local function p(x, y, z)
        return { x + ox, y + oy, z + oz }
    end

    local vertices = {}

    -- An open-top room, with all coordinates stored in world space.
    addQuad(vertices,
        p(-256, -256, 0), p(256, -256, 0), p(256, 256, 0), p(-256, 256, 0),
        { 0, 0, 1 }, { 170, 180, 190, 255 })

    -- Front wall, facing the inside of the room.
    addQuad(vertices,
        p(256, -256, 0), p(-256, -256, 0), p(-256, -256, 256), p(256, -256, 256),
        { 0, 1, 0 }, { 120, 160, 210, 255 })

    -- Back wall.
    addQuad(vertices,
        p(-256, 256, 0), p(256, 256, 0), p(256, 256, 256), p(-256, 256, 256),
        { 0, -1, 0 }, { 150, 190, 150, 255 })

    -- Left wall.
    addQuad(vertices,
        p(-256, -256, 0), p(-256, 256, 0), p(-256, 256, 256), p(-256, -256, 256),
        { 1, 0, 0 }, { 190, 150, 130, 255 })

    -- Right wall.
    addQuad(vertices,
        p(256, 256, 0), p(256, -256, 0), p(256, -256, 256), p(256, 256, 256),
        { -1, 0, 0 }, { 170, 150, 200, 255 })

    local collision = {}

    -- Closed, convex collision solids. Their top faces line up with the
    -- render-only floor/walls, while the thickness extends outward/downward.
    addBoxCollision(collision, p(-256, -256, -16), p(256, 256, 0), "concrete") -- floor
    addBoxCollision(collision, p(-256, -272, -16), p(256, -256, 256), "concrete") -- front
    addBoxCollision(collision, p(-256, 256, -16), p(256, 272, 256), "concrete") -- back
    addBoxCollision(collision, p(-272, -256, -16), p(-256, 256, 256), "concrete") -- left
    addBoxCollision(collision, p(256, -256, -16), p(272, 256, 256), "concrete") -- right

    return {
        format = NKM.FormatMagic,
        version = NKM.Version,
        name = "demo",
        description = "NKM prototype open-top test room",
        chunkSize = NKM.DefaultChunkSize,
        meshes = {
            {
                material = "nkm_prototype_unlit_v2",
                vertices = vertices
            }
        },
        collision = collision
    }
end


-- Synthetic large-world generator used by nkm_benchmark.
-- Modes:
--   render: 500/1000 render chunks, one convex hull per 10 tiles.
--   fullphysics: 100 render chunks, one convex hull per tile.
-- The 128-hull limit is an NKM prototype safety cap, not a claim about a
-- hard global VPhysics limit.
function NKM.BuildBenchmarkMap(targetChunks, origin, mode)
    mode = mode or "render"
    targetChunks = tonumber(targetChunks)

    local columns, rows, collisionStride
    if mode == "render" then
        targetChunks = targetChunks or 500
        if targetChunks == 500 then
            columns, rows = 25, 20
        elseif targetChunks == 1000 then
            columns, rows = 40, 25
        else
            return nil, "render benchmark size must be 500 or 1000"
        end
        collisionStride = 10
    elseif mode == "fullphysics" then
        targetChunks = targetChunks or 100
        if targetChunks ~= 100 then
            return nil, "fullphysics benchmark size must be 100"
        end
        columns, rows = 10, 10
        collisionStride = 1
    else
        return nil, "unknown benchmark mode: " .. tostring(mode)
    end

    if not isvector(origin) then
        origin = Vector(0, 0, 0)
    end

    local chunkSize = 512
    local centerCellX = math.floor(origin.x / chunkSize)
    local centerCellY = math.floor(origin.y / chunkSize)
    local startCellX = centerCellX - math.floor(columns * 0.5)
    local startCellY = centerCellY - math.floor(rows * 0.5)
    local floorZ = origin.z - 64

    local vertices = {}
    local collision = {}
    local tileIndex = 0

    for row = 0, rows - 1 do
        for column = 0, columns - 1 do
            tileIndex = tileIndex + 1
            local cellX = startCellX + column
            local cellY = startCellY + row
            local x0 = cellX * chunkSize
            local y0 = cellY * chunkSize
            local x1 = x0 + chunkSize
            local y1 = y0 + chunkSize

            local color = {
                100 + ((column * 13 + row * 3) % 80),
                100 + ((column * 5 + row * 11) % 80),
                100 + ((column * 7 + row * 17) % 80),
                255
            }

            addQuad(vertices,
                { x0, y0, floorZ },
                { x1, y0, floorZ },
                { x1, y1, floorZ },
                { x0, y1, floorZ },
                { 0, 0, 1 }, color
            )

            if tileIndex % collisionStride == 0 then
                addBoxCollision(collision,
                    { x0, y0, floorZ - 16 },
                    { x1, y1, floorZ },
                    "concrete"
                )
            end
        end
    end

    local mapName
    if mode == "fullphysics" then
        mapName = "benchphy100"
    else
        mapName = targetChunks == 500 and "bench500" or "bench1000"
    end

    local mapTable = {
        format = NKM.FormatMagic,
        version = NKM.Version,
        name = mapName,
        description = "NKM synthetic " .. mode .. " benchmark (" .. targetChunks .. " chunks)",
        chunkSize = chunkSize,
        meshes = {
            {
                material = "nkm_prototype_unlit_v2",
                vertices = vertices
            }
        },
        collision = collision
    }

    return mapTable, {
        name = mapName,
        mode = mode,
        columns = columns,
        rows = rows,
        renderChunksExpected = targetChunks,
        renderVertices = #vertices,
        collisionHulls = #collision,
        collisionStride = collisionStride,
        chunkSize = chunkSize,
        floorZ = floorZ
    }
end
