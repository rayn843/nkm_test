-- NKM 0.9.7 TriangleSurface / displacement grid and baked-light vertex support.
-- Loaded after sh_core.lua and before sh_trace.lua.

NKM.MaxDisplacementPatches = 256
NKM.MaxDisplacementGridSide = 65
NKM.MaxTriangleSurfaceVertices = 60000

local originalValidateMap = NKM.ValidateMap
local originalBuildChunks = NKM.BuildChunks

local function finiteNumber(value)
    return isnumber(value) and value == value and value ~= math.huge and value ~= -math.huge
end

local function validPoint(point)
    return istable(point)
        and finiteNumber(point[1])
        and finiteNumber(point[2])
        and finiteNumber(point[3])
end

local function validSurfaceName(surface)
    return isstring(surface)
        and #surface > 0
        and #surface <= 32
        and surface:match("^[%w_]+$") ~= nil
end

local function validateDisplacements(displacements)
    if displacements == nil then return true, 0 end
    if not istable(displacements) then return false, "displacements must be an array" end
    if #displacements > NKM.MaxDisplacementPatches then
        return false, "map exceeds displacement patch limit (" .. NKM.MaxDisplacementPatches .. ")"
    end

    local generatedVertices = 0
    for patchIndex, patch in ipairs(displacements) do
        if not istable(patch) then
            return false, "displacement #" .. patchIndex .. " must be a table"
        end
        local width, height = patch.width, patch.height
        if not finiteNumber(width) or not finiteNumber(height)
            or width ~= math.floor(width) or height ~= math.floor(height)
            or width < 2 or height < 2
            or width > NKM.MaxDisplacementGridSide or height > NKM.MaxDisplacementGridSide then
            return false, "displacement #" .. patchIndex .. " grid dimensions must be integers from 2 to " .. NKM.MaxDisplacementGridSide
        end
        if not istable(patch.vertices) or #patch.vertices ~= width * height then
            return false, "displacement #" .. patchIndex .. " must contain width*height positions"
        end
        if patch.surface ~= nil and not validSurfaceName(patch.surface) then
            return false, "invalid surface property at displacement #" .. patchIndex
        end
        if patch.material ~= nil and (not isstring(patch.material) or #patch.material == 0 or #patch.material > 128) then
            return false, "invalid material at displacement #" .. patchIndex
        end
        if patch.uvScale ~= nil and (not finiteNumber(patch.uvScale) or patch.uvScale <= 0 or patch.uvScale > 256) then
            return false, "invalid uvScale at displacement #" .. patchIndex
        end
        if patch.collision ~= nil and not isbool(patch.collision) then
            return false, "displacement collision must be a boolean"
        end
        for _, flagName in ipairs({ "physicsCollision", "hullCollision", "rayCollision" }) do
            if patch[flagName] ~= nil and not isbool(patch[flagName]) then
                return false, "displacement " .. flagName .. " must be a boolean"
            end
        end
        if patch.triangleLayout ~= nil and patch.triangleLayout ~= "source" then
            return false, "unsupported displacement triangleLayout (expected 'source')"
        end
        if patch.flipWinding ~= nil and not isbool(patch.flipWinding) then
            return false, "displacement flipWinding must be a boolean"
        end
        if patch.smoothNormals ~= nil and not isbool(patch.smoothNormals) then
            return false, "displacement smoothNormals must be a boolean"
        end
        if patch.uvs ~= nil then
            if not istable(patch.uvs) or #patch.uvs ~= width * height then
                return false, "displacement UV array must contain width*height entries"
            end
            for uvIndex, uv in ipairs(patch.uvs) do
                if not istable(uv) or not finiteNumber(uv[1]) or not finiteNumber(uv[2]) then
                    return false, "invalid UV at displacement #" .. patchIndex .. ", vertex " .. uvIndex
                end
            end
        end
        if patch.triangleTags ~= nil then
            local expectedTags = (width - 1) * (height - 1) * 2
            if not istable(patch.triangleTags) or #patch.triangleTags ~= expectedTags then
                return false, "displacement triangleTags must contain two tags per grid cell"
            end
            for tagIndex, tag in ipairs(patch.triangleTags) do
                if not finiteNumber(tag) or tag < 0 or tag > 65535 or tag ~= math.floor(tag) then
                    return false, "invalid displacement triangle tag at index " .. tagIndex
                end
            end
        end
        if patch.normals ~= nil then
            if not istable(patch.normals) or #patch.normals ~= width * height then
                return false, "displacement normals must contain width*height entries"
            end
            for normalIndex, normal in ipairs(patch.normals) do
                if not validPoint(normal) then
                    return false, "invalid normal at displacement #" .. patchIndex .. ", vertex " .. normalIndex
                end
            end
        end
        if patch.vertexAlphas ~= nil then
            if not istable(patch.vertexAlphas) or #patch.vertexAlphas ~= width * height then
                return false, "displacement vertexAlphas must contain width*height entries"
            end
            for alphaIndex, alpha in ipairs(patch.vertexAlphas) do
                if not finiteNumber(alpha) or alpha < 0 or alpha > 255 then
                    return false, "invalid blend alpha at displacement #" .. patchIndex .. ", vertex " .. alphaIndex
                end
            end
        end
        if patch.vertexLighting ~= nil then
            if not istable(patch.vertexLighting) or #patch.vertexLighting ~= width * height then
                return false, "displacement vertexLighting must contain width*height entries"
            end
            for lightingIndex, light in ipairs(patch.vertexLighting) do
                if not istable(light) or not finiteNumber(light[1])
                    or not finiteNumber(light[2]) or not finiteNumber(light[3]) then
                    return false, "invalid vertex lighting at displacement #" .. patchIndex .. ", vertex " .. lightingIndex
                end
                for channel = 1, 3 do
                    if light[channel] < 0 or light[channel] > 255 then
                        return false, "vertex lighting channel outside 0..255 at displacement #" .. patchIndex .. ", vertex " .. lightingIndex
                    end
                end
            end
        end

        if patch.nkmLighting ~= nil then
            if not istable(patch.nkmLighting) or #patch.nkmLighting ~= width * height then
                return false, "displacement nkmLighting must contain width*height entries"
            end
            for lightingIndex, light in ipairs(patch.nkmLighting) do
                if not istable(light) or not finiteNumber(light[1])
                    or not finiteNumber(light[2]) or not finiteNumber(light[3]) then
                    return false, "invalid NKM lighting at displacement #" .. patchIndex .. ", vertex " .. lightingIndex
                end
                for channel = 1, 3 do
                    if light[channel] < 0 or light[channel] > 255 then
                        return false, "NKM lighting channel outside 0..255 at displacement #" .. patchIndex .. ", vertex " .. lightingIndex
                    end
                end
            end
        end
        if patch.color ~= nil then
            if not istable(patch.color) or not finiteNumber(patch.color[1])
                or not finiteNumber(patch.color[2]) or not finiteNumber(patch.color[3]) then
                return false, "invalid color at displacement #" .. patchIndex
            end
        end
        for vertexIndex, point in ipairs(patch.vertices) do
            if not validPoint(point) then
                return false, "invalid position at displacement " .. patchIndex .. ", vertex " .. vertexIndex
            end
        end

        local patchVertices = (width - 1) * (height - 1) * 6
        generatedVertices = generatedVertices + patchVertices
        if generatedVertices > NKM.MaxVertices then
            return false, "displacements exceed generated vertex limit (" .. NKM.MaxVertices .. ")"
        end

        -- Reject degenerate grid cells before they reach IMesh or VPhysics.
        for y = 1, height - 1 do
            for x = 1, width - 1 do
                local i00 = (y - 1) * width + x
                local i10 = i00 + 1
                local i01 = i00 + width
                local i11 = i01 + 1
                local p00, p10 = patch.vertices[i00], patch.vertices[i10]
                local p01, p11 = patch.vertices[i01], patch.vertices[i11]
                local function areaSqr(a, b, c)
                    local abx, aby, abz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
                    local acx, acy, acz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
                    local nx = aby * acz - abz * acy
                    local ny = abz * acx - abx * acz
                    local nz = abx * acy - aby * acx
                    return nx * nx + ny * ny + nz * nz
                end
                local areaA, areaB
                if patch.triangleLayout == "source" then
                    local sourceCellIndex = (y - 1) * width + (x - 1)
                    if sourceCellIndex % 2 == 1 then
                        areaA = areaSqr(p00, p01, p10)
                        areaB = areaSqr(p10, p01, p11)
                    else
                        areaA = areaSqr(p00, p01, p11)
                        areaB = areaSqr(p00, p11, p10)
                    end
                else
                    areaA = areaSqr(p00, p10, p11)
                    areaB = areaSqr(p00, p11, p01)
                end
                if areaA < 0.00000001 or areaB < 0.00000001 then
                    return false, "degenerate triangle in displacement #" .. patchIndex .. " cell " .. x .. "," .. y
                end
            end
        end
    end

    return true, generatedVertices
end

local function validateTriangleSurfaces(surfaces)
    if surfaces == nil then return true end
    if not istable(surfaces) then return false, "triangleSurfaces must be an array" end
    if #surfaces > NKM.MaxDisplacementPatches then
        return false, "chunk exceeds triangle surface patch limit"
    end

    local totalVertices = 0
    for surfaceIndex, surfaceData in ipairs(surfaces) do
        if not istable(surfaceData) or not istable(surfaceData.vertices) then
            return false, "triangle surface #" .. surfaceIndex .. " must contain vertices"
        end
        local vertices = surfaceData.vertices
        if #vertices < 3 or #vertices % 3 ~= 0 or #vertices > NKM.MaxTriangleSurfaceVertices then
            return false, "triangle surface #" .. surfaceIndex .. " has an invalid vertex count"
        end
        if surfaceData.surface ~= nil and not validSurfaceName(surfaceData.surface) then
            return false, "invalid surface property at triangle surface #" .. surfaceIndex
        end
        if surfaceData.indices ~= nil and (not istable(surfaceData.indices) or #surfaceData.indices ~= #vertices / 3) then
            return false, "triangle surface #" .. surfaceIndex .. " has an invalid triangle index table"
        end
        for vertexIndex, point in ipairs(vertices) do
            if not validPoint(point) then
                return false, "invalid position at triangle surface " .. surfaceIndex .. ", vertex " .. vertexIndex
            end
        end
        for index, triangleIndex in ipairs(surfaceData.indices or {}) do
            if not finiteNumber(triangleIndex) or triangleIndex < 1 or triangleIndex ~= math.floor(triangleIndex) then
                return false, "invalid triangle index at triangle surface " .. surfaceIndex .. ", triangle " .. index
            end
        end
        totalVertices = totalVertices + #vertices
        if totalVertices > NKM.MaxTriangleSurfaceVertices then
            return false, "chunk exceeds total triangle surface vertex limit"
        end
    end

    return true
end

function NKM.ValidateMap(map)
    if not istable(map) then return false, "root must be a table" end
    local displacements = map.displacements or {}
    local triangleSurfaces = map.triangleSurfaces or {}
    local meshes = map.meshes or {}

    if not istable(meshes) then return false, "meshes must be an array" end
    if #meshes == 0 and (#displacements > 0 or #triangleSurfaces > 0) then
        -- The base validator expects at least one mesh. Use a temporary marker
        -- triangle for validation only; it is never included in runtime chunks.
        local validationMap = {}
        for key, value in pairs(map) do validationMap[key] = value end
        validationMap.meshes = {
            {
                material = "nkm_validation",
                vertices = {
                    { p = { 0, 0, 0 } },
                    { p = { 1, 0, 0 } },
                    { p = { 0, 1, 0 } }
                }
            }
        }
        validationMap.displacements = nil
        validationMap.triangleSurfaces = nil
        local valid, detail = originalValidateMap(validationMap)
        if not valid then return false, detail end
    else
        local valid, detail = originalValidateMap(map)
        if not valid then return false, detail end
    end

    local displacementValid, displacementDetail = validateDisplacements(displacements)
    if not displacementValid then return false, displacementDetail end
    local baseMeshVertices = 0
    for _, meshData in ipairs(meshes) do
        baseMeshVertices = baseMeshVertices + #(meshData.vertices or {})
    end
    if baseMeshVertices + displacementDetail > NKM.MaxVertices then
        return false, "map exceeds combined mesh/displacement generated vertex limit (" .. NKM.MaxVertices .. ")"
    end
    local trianglesValid, triangleDetail = validateTriangleSurfaces(triangleSurfaces)
    if not trianglesValid then return false, triangleDetail end

    if #meshes == 0 and #displacements == 0 and #triangleSurfaces == 0 then
        return false, "map contains no meshes or displacement surfaces"
    end

    return true
end

local function pointToVector(point)
    return Vector(point[1], point[2], point[3])
end

local function includePoint(chunk, point)
    local x, y, z = point[1], point[2], point[3]
    if not chunk._nkmHasBounds then
        chunk._nkmMinX, chunk._nkmMinY, chunk._nkmMinZ = x, y, z
        chunk._nkmMaxX, chunk._nkmMaxY, chunk._nkmMaxZ = x, y, z
        chunk._nkmHasBounds = true
        return
    end
    chunk._nkmMinX = math.min(chunk._nkmMinX, x)
    chunk._nkmMinY = math.min(chunk._nkmMinY, y)
    chunk._nkmMinZ = math.min(chunk._nkmMinZ, z)
    chunk._nkmMaxX = math.max(chunk._nkmMaxX, x)
    chunk._nkmMaxY = math.max(chunk._nkmMaxY, y)
    chunk._nkmMaxZ = math.max(chunk._nkmMaxZ, z)
end

local function buildCellTriangles(patch, row, column, p00, p10, p01, p11,
    uv00, uv10, uv01, uv11, i00, i10, i01, i11)
    local flipWinding = patch.flipWinding == true

    if patch.triangleLayout == "source" then
        -- Source displacement vertex/triangle ordering is row-major. Each
        -- cell alternates its diagonal based on (y * gridWidth + x) parity.
        local sourceCellIndex = (row - 1) * patch.width + (column - 1)
        local oddCell = sourceCellIndex % 2 == 1
        if oddCell then
            if flipWinding then
                return {
                    { p00, p01, p10, uv00, uv01, uv10, i00, i01, i10 },
                    { p10, p01, p11, uv10, uv01, uv11, i10, i01, i11 }
                }
            end
            return {
                { p00, p10, p01, uv00, uv10, uv01, i00, i10, i01 },
                { p10, p11, p01, uv10, uv11, uv01, i10, i11, i01 }
            }
        end

        if flipWinding then
            return {
                { p00, p01, p11, uv00, uv01, uv11, i00, i01, i11 },
                { p00, p11, p10, uv00, uv11, uv10, i00, i11, i10 }
            }
        end
        return {
            { p00, p11, p01, uv00, uv11, uv01, i00, i11, i01 },
            { p00, p10, p11, uv00, uv10, uv11, i00, i10, i11 }
        }
    end

    if flipWinding then
        return {
            { p00, p11, p10, uv00, uv11, uv10, i00, i11, i10 },
            { p00, p01, p11, uv00, uv01, uv11, i00, i01, i11 }
        }
    end
    return {
        { p00, p10, p11, uv00, uv10, uv11, i00, i10, i11 },
        { p00, p11, p01, uv00, uv11, uv01, i00, i11, i01 }
    }
end

function NKM.BuildChunks(mapTable, requestedChunkSize)
    local cleanMap = {}
    for key, value in pairs(mapTable or {}) do
        if key ~= "displacements" and key ~= "triangleSurfaces" then
            cleanMap[key] = value
        end
    end
    cleanMap.meshes = cleanMap.meshes or {}
    if #cleanMap.meshes == 0 then
        cleanMap.meshes = {
            { material = "nkm_validation", vertices = {} }
        }
    end

    local chunks, stats = originalBuildChunks(cleanMap, requestedChunkSize)
    if not chunks then return nil, stats end

    local hasNKMLighting = istable(mapTable.lighting) and mapTable.lighting.enabled ~= false
    if hasNKMLighting then
        for _, chunk in ipairs(chunks) do
            for _, meshGroup in ipairs(chunk.meshes or {}) do
                meshGroup.hasNKMLighting = true
            end
        end
    end

    local chunkSize = requestedChunkSize or mapTable.chunkSize or NKM.DefaultChunkSize
    local byID = {}
    for _, chunk in ipairs(chunks) do
        byID[chunk.id] = chunk
        chunk.triangleSurfaces = chunk.triangleSurfaces or {}
        chunk._nkmDispMeshLookup = {}
        chunk._nkmTriangleLookup = {}
        if chunk.mins and chunk.maxs then
            chunk._nkmMinX, chunk._nkmMinY, chunk._nkmMinZ = chunk.mins.x, chunk.mins.y, chunk.mins.z
            chunk._nkmMaxX, chunk._nkmMaxY, chunk._nkmMaxZ = chunk.maxs.x, chunk.maxs.y, chunk.maxs.z
            chunk._nkmHasBounds = true
        end
    end

    local function getChunkAt(x, y, z)
        local ix, iy, iz = math.floor(x / chunkSize), math.floor(y / chunkSize), math.floor(z / chunkSize)
        local id = tostring(ix) .. "_" .. tostring(iy) .. "_" .. tostring(iz)
        local chunk = byID[id]
        if chunk then return chunk end
        if #chunks >= NKM.MaxChunks then return nil, "map exceeds chunk limit (" .. NKM.MaxChunks .. ")" end
        chunk = {
            id = id,
            ix = ix, iy = iy, iz = iz,
            meshes = {},
            collision = {},
            triangleSurfaces = {},
            _nkmDispMeshLookup = {},
            _nkmTriangleLookup = {}
        }
        byID[id] = chunk
        chunks[#chunks + 1] = chunk
        return chunk
    end

    local totalTriangleVertices = 0
    local triangleIndex = 0
    local removedTriangleCount = 0
    for patchIndex, patch in ipairs(mapTable.displacements or {}) do
        local width, height = patch.width, patch.height
        local surface = patch.surface or "dirt"
        local color = patch.color or { 120, 150, 105, 255 }
        local uvScale = patch.uvScale or 8
        local patchID = patch.id or tostring(patchIndex)
        local material = patch.material or "nkm_prototype_unlit_v2"
        local flipWinding = patch.flipWinding == true
        local gridNormals = nil

        -- Imported Source displacements use a regular grid. Smooth vertex normals
        -- are accumulated from the actual, non-removed triangles in that grid.
        if patch.smoothNormals == true and patch.normals == nil then
            gridNormals = {}
            for vertexIndex = 1, width * height do
                gridNormals[vertexIndex] = { 0, 0, 0 }
            end
            local function addNormal(index, normal)
                local target = gridNormals[index]
                target[1] = target[1] + normal[1]
                target[2] = target[2] + normal[2]
                target[3] = target[3] + normal[3]
            end
            for row = 1, height - 1 do
                for column = 1, width - 1 do
                    local i00 = (row - 1) * width + column
                    local i10 = i00 + 1
                    local i01 = i00 + width
                    local i11 = i01 + 1
                    local p00, p10 = patch.vertices[i00], patch.vertices[i10]
                    local p01, p11 = patch.vertices[i01], patch.vertices[i11]
                    local cellIndex = ((row - 1) * (width - 1) + (column - 1)) * 2
                    local cellTriangles = buildCellTriangles(
                        patch, row, column, p00, p10, p01, p11,
                        nil, nil, nil, nil, i00, i10, i01, i11
                    )
                    local tris = {
                        { cellTriangles[1][7], cellTriangles[1][8], cellTriangles[1][9], cellTriangles[1][1], cellTriangles[1][2], cellTriangles[1][3] },
                        { cellTriangles[2][7], cellTriangles[2][8], cellTriangles[2][9], cellTriangles[2][1], cellTriangles[2][2], cellTriangles[2][3] }
                    }
                    for triOffset, tri in ipairs(tris) do
                        local tag = patch.triangleTags and patch.triangleTags[cellIndex + triOffset] or 0
                        if bit.band(tag, 32) == 0 then
                            local a, b, c = tri[4], tri[5], tri[6]
                            local abx, aby, abz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
                            local acx, acy, acz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
                            local normal = {
                                aby * acz - abz * acy,
                                abz * acx - abx * acz,
                                abx * acy - aby * acx
                            }
                            addNormal(tri[1], normal)
                            addNormal(tri[2], normal)
                            addNormal(tri[3], normal)
                        end
                    end
                end
            end
            for _, normal in ipairs(gridNormals) do
                local length = math.sqrt(normal[1] * normal[1] + normal[2] * normal[2] + normal[3] * normal[3])
                if length > 0.000001 then
                    normal[1], normal[2], normal[3] = normal[1] / length, normal[2] / length, normal[3] / length
                else
                    normal[1], normal[2], normal[3] = 0, 0, 1
                end
            end
        end

        for row = 1, height - 1 do
            for column = 1, width - 1 do
                local i00 = (row - 1) * width + column
                local i10 = i00 + 1
                local i01 = i00 + width
                local i11 = i01 + 1
                local p00, p10 = patch.vertices[i00], patch.vertices[i10]
                local p01, p11 = patch.vertices[i01], patch.vertices[i11]

                local defaultUV00 = { (column - 1) / (width - 1) * uvScale, (row - 1) / (height - 1) * uvScale }
                local defaultUV10 = { column / (width - 1) * uvScale, (row - 1) / (height - 1) * uvScale }
                local defaultUV01 = { (column - 1) / (width - 1) * uvScale, row / (height - 1) * uvScale }
                local defaultUV11 = { column / (width - 1) * uvScale, row / (height - 1) * uvScale }
                local uv00 = patch.uvs and patch.uvs[i00] or defaultUV00
                local uv10 = patch.uvs and patch.uvs[i10] or defaultUV10
                local uv01 = patch.uvs and patch.uvs[i01] or defaultUV01
                local uv11 = patch.uvs and patch.uvs[i11] or defaultUV11

                local triangles = buildCellTriangles(
                    patch, row, column, p00, p10, p01, p11,
                    uv00, uv10, uv01, uv11, i00, i10, i01, i11
                )

                local firstTriangle = ((row - 1) * (width - 1) + (column - 1)) * 2
                for triangleOffset, tri in ipairs(triangles) do
                    local tag = patch.triangleTags and patch.triangleTags[firstTriangle + triangleOffset] or 0
                    if bit.band(tag, 32) ~= 0 then
                        removedTriangleCount = removedTriangleCount + 1
                    else
                        triangleIndex = triangleIndex + 1
                        totalTriangleVertices = totalTriangleVertices + 3
                        local a, b, c = tri[1], tri[2], tri[3]
                        local cx = (a[1] + b[1] + c[1]) / 3
                        local cy = (a[2] + b[2] + c[2]) / 3
                        local cz = (a[3] + b[3] + c[3]) / 3
                        local chunk, err = getChunkAt(cx, cy, cz)
                        if not chunk then return nil, err end

                        local meshGroup = chunk._nkmDispMeshLookup[patchIndex]
                        if not meshGroup then
                            meshGroup = {
                                material = material,
                                vertices = {},
                                sourceGroup = "displacement:" .. tostring(patchID),
                                isBSPDisplacement = patch.sourceType == "BSPDisplacement",
                                hasVertexLighting = patch.vertexLighting ~= nil,
                                hasNKMLighting = hasNKMLighting,
                                vertexLightingSource = patch.lightmap and patch.lightmap.source or nil,
                                lightmapSamples = patch.lightmap and patch.lightmap.usedSamples or 0,
                                sourcePatchID = patch.sourceDispInfo or patchID,
                                sourceFace = patch.sourceFace
                            }
                            chunk._nkmDispMeshLookup[patchIndex] = meshGroup
                            chunk.meshes[#chunk.meshes + 1] = meshGroup
                        end

                        local va, vb, vc = pointToVector(a), pointToVector(b), pointToVector(c)
                        local faceNormal = (vb - va):Cross(vc - va)
                        faceNormal:Normalize()
                        local faceNormalArray = { faceNormal.x, faceNormal.y, faceNormal.z }
                        for vertexOffset = 1, 3 do
                            local point = tri[vertexOffset]
                            local uv = tri[vertexOffset + 3]
                            local vertexIndex = tri[vertexOffset + 6]
                            local normalArray = patch.normals and patch.normals[vertexIndex]
                                or (gridNormals and gridNormals[vertexIndex])
                                or faceNormalArray
                            meshGroup.vertices[#meshGroup.vertices + 1] = {
                                p = { point[1], point[2], point[3] },
                                n = normalArray,
                                uv = uv,
                                color = patch.vertexLighting and patch.vertexLighting[vertexIndex] or color,
                                nkmLighting = patch.nkmLighting and patch.nkmLighting[vertexIndex] or nil,
                                blendAlpha = patch.vertexAlphas and patch.vertexAlphas[vertexIndex] or 255
                            }
                            includePoint(chunk, point)
                        end

                        local legacyCollision = patch.collision ~= false
                        local physicsCollision = legacyCollision and patch.physicsCollision ~= false
                        local hullCollision = legacyCollision and patch.hullCollision ~= false
                        local rayCollision = legacyCollision and patch.rayCollision ~= false
                        if physicsCollision or hullCollision or rayCollision then
                            local triangleGroup = chunk._nkmTriangleLookup[patchIndex]
                            if not triangleGroup then
                                triangleGroup = {
                                    id = tostring(patchID) .. "_" .. chunk.id,
                                    sourceDisplacement = tostring(patchID),
                                    surface = surface,
                                    physicsCollision = physicsCollision,
                                    hullCollision = hullCollision,
                                    rayCollision = rayCollision,
                                    vertices = {},
                                    indices = {}
                                }
                                chunk._nkmTriangleLookup[patchIndex] = triangleGroup
                                chunk.triangleSurfaces[#chunk.triangleSurfaces + 1] = triangleGroup
                            end
                            triangleGroup.vertices[#triangleGroup.vertices + 1] = { a[1], a[2], a[3] }
                            triangleGroup.vertices[#triangleGroup.vertices + 1] = { b[1], b[2], b[3] }
                            triangleGroup.vertices[#triangleGroup.vertices + 1] = { c[1], c[2], c[3] }
                            triangleGroup.indices[#triangleGroup.indices + 1] = triangleIndex
                        end
                    end
                end
            end
        end
    end

    table.sort(chunks, function(a, b)
        if a.ix ~= b.ix then return a.ix < b.ix end
        if a.iy ~= b.iy then return a.iy < b.iy end
        return a.iz < b.iz
    end)

    local triangleSurfaceCount, triangleCount, triangleCollisionChunks = 0, 0, 0
    for _, chunk in ipairs(chunks) do
        if chunk._nkmHasBounds then
            chunk.mins = Vector(chunk._nkmMinX, chunk._nkmMinY, chunk._nkmMinZ)
            chunk.maxs = Vector(chunk._nkmMaxX, chunk._nkmMaxY, chunk._nkmMaxZ)
        end
        local hasPhysicalTriangleSurface = false
        for _, surfaceData in ipairs(chunk.triangleSurfaces) do
            if surfaceData.physicsCollision ~= false or surfaceData.hullCollision ~= false then
                hasPhysicalTriangleSurface = true
                break
            end
        end
        if hasPhysicalTriangleSurface then
            triangleCollisionChunks = triangleCollisionChunks + 1
        end
        local chunkTriangleVertices = 0
        for _, surfaceData in ipairs(chunk.triangleSurfaces) do
            triangleSurfaceCount = triangleSurfaceCount + 1
            triangleCount = triangleCount + #surfaceData.vertices / 3
            chunkTriangleVertices = chunkTriangleVertices + #surfaceData.vertices
        end
        if chunkTriangleVertices > NKM.MaxTriangleSurfaceVertices then
            return nil, "chunk " .. tostring(chunk.id) .. " exceeds triangle-surface vertex limit (" .. NKM.MaxTriangleSurfaceVertices .. ")"
        end
        chunk._nkmDispMeshLookup = nil
        chunk._nkmTriangleLookup = nil
        chunk._nkmMinX, chunk._nkmMinY, chunk._nkmMinZ = nil, nil, nil
        chunk._nkmMaxX, chunk._nkmMaxY, chunk._nkmMaxZ = nil, nil, nil
        chunk._nkmHasBounds = nil
        chunk.triangleSurfaces = chunk.triangleSurfaces or {}
    end

    stats.chunkCount = #chunks
    stats.meshGroups = 0
    for _, chunk in ipairs(chunks) do stats.meshGroups = stats.meshGroups + #(chunk.meshes or {}) end
    stats.triangleSurfacePatches = triangleSurfaceCount
    stats.triangleCount = triangleCount
    stats.triangleSurfaceVertices = totalTriangleVertices
    stats.removedDisplacementTriangles = removedTriangleCount
    stats.triangleCollisionChunks = triangleCollisionChunks
    stats.collisionChunks = 0
    for _, chunk in ipairs(chunks) do
        local hasPhysicalTriangleSurface = false
        for _, surfaceData in ipairs(chunk.triangleSurfaces or {}) do
            if surfaceData.physicsCollision ~= false or surfaceData.hullCollision ~= false then
                hasPhysicalTriangleSurface = true
                break
            end
        end
        if #(chunk.collision or {}) > 0 or hasPhysicalTriangleSurface then
            stats.collisionChunks = stats.collisionChunks + 1
        end
    end

    return chunks, stats
end

function NKM.BuildDisplacementTestMap(origin)
    origin = isvector(origin) and origin or Vector(0, 0, 0)
    local width, height = 25, 25
    local span = 1024
    local step = span / (width - 1)
    local x0, y0 = origin.x - span * 0.5, origin.y - span * 0.5
    local baseZ = origin.z - 96
    local vertices = {}

    for row = 0, height - 1 do
        for column = 0, width - 1 do
            local u = column / (width - 1)
            local v = row / (height - 1)
            local waveA = math.sin(u * math.pi * 2) * math.cos(v * math.pi * 2) * 42
            local waveB = math.sin((u + v) * math.pi * 4) * 14
            local hill = math.exp(-(((u - 0.67) ^ 2) + ((v - 0.38) ^ 2)) * 24) * 38
            vertices[#vertices + 1] = {
                x0 + column * step,
                y0 + row * step,
                baseZ + waveA + waveB + hill
            }
        end
    end

    return {
        format = NKM.FormatMagic,
        version = NKM.Version,
        name = "disptest",
        description = "NKM 0.9.5 triangle-surface displacement test",
        chunkSize = NKM.DefaultChunkSize,
        meshes = {},
        collision = {},
        displacements = {
            {
                id = "terrain_hills_01",
                width = width,
                height = height,
                vertices = vertices,
                material = "nkm_prototype_unlit_v2",
                surface = "dirt",
                color = { 116, 150, 92, 255 },
                uvScale = 8,
                collision = true
            }
        }
    }
end

