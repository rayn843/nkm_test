NKM.ClientMap = nil
NKM.ClientManifest = nil
NKM.ClientMapName = nil
NKM.ClientGeneration = nil
NKM.ClientChunks = {}
NKM.ClientChunkStats = nil
NKM.RenderMeshes = {}
NKM.ManifestTransfer = nil
NKM.ChunkTransfers = {}
NKM.ChunkLoadDistance = 4096
NKM.ChunkUnloadDistance = 6144
NKM.NextChunkUpdate = 0
NKM.NextChunkRequestAt = 0
NKM.LoadedClientChunkCount = 0
NKM.ChunkCacheEnabled = true
NKM.ChunkCacheRoot = "nkm/cache"
NKM.CullModeSetting = NKM.CullModeSetting or 0
NKM.ChunkCacheStats = NKM.ChunkCacheStats or {
    Hits = 0,
    Misses = 0,
    Writes = 0,
    Corruptions = 0,
    Evictions = 0,
    BytesRead = 0,
    BytesWritten = 0
}

file.CreateDir("nkm")
file.CreateDir(NKM.ChunkCacheRoot)

local DEFAULT_MATERIAL = CreateMaterial("nkm_prototype_unlit_v6", "UnlitGeneric", {
    ["$basetexture"] = "color/white",
    ["$vertexcolor"] = "1"
})

-- Diagnostic material deliberately ignores the source BSP material/lightmap.
-- A per-displacement color is applied with render.SetColorModulation in the draw hook.
local BSP_DISPLACEMENT_DEBUG_MATERIAL = CreateMaterial("nkm_bspdisp_debug_unlit", "UnlitGeneric", {
    ["$basetexture"] = "color/white",
    ["$vertexcolor"] = "1",
    ["$nocull"] = "1"
})

NKM.ClientBSPDisplacementRenderEnabled = NKM.ClientBSPDisplacementRenderEnabled ~= false
NKM.ClientBSPDisplacementDebug = NKM.ClientBSPDisplacementDebug == true
NKM.ClientBSPDisplacementMaterialMode = NKM.ClientBSPDisplacementMaterialMode or "albedo"
NKM.ClientBSPDisplacementRenderOffset = tonumber(NKM.ClientBSPDisplacementRenderOffset) or 0

-- Optional GShader deferred bridge. The main NKM renderer remains fully
-- functional when GShader or the compiled custom shader is absent.
NKM.GShaderBridgeEnabled = NKM.GShaderBridgeEnabled ~= false
NKM.GShaderMaskDebug = NKM.GShaderMaskDebug == true
NKM.GShaderReadyFrame = false
NKM.GShaderMaskPassCount = NKM.GShaderMaskPassCount or 0
NKM.GShaderDeferredPassCount = NKM.GShaderDeferredPassCount or 0
NKM.ClientLighting = nil
NKM.ClientDynamicLights = {}
NKM.GShaderDynamicLightLUT = nil
NKM.GShaderLUTGeneration = nil
NKM.GShaderLUTLastError = nil
NKM.GShaderLastError = nil
NKM.GShaderLastHookAt = nil
NKM.GShaderLastMaskDraws = 0
NKM.GShaderNKMStaticPassCount = NKM.GShaderNKMStaticPassCount or 0
NKM.GShaderGlobalPointPassCount = NKM.GShaderGlobalPointPassCount or 0
NKM.GShaderScenePassCount = NKM.GShaderScenePassCount or 0
NKM.GShaderDepthPassCount = NKM.GShaderDepthPassCount or 0
NKM.GShaderDepthMeshDrawCount = NKM.GShaderDepthMeshDrawCount or 0
NKM.GShaderLastDepthPassAt = nil
NKM.GShaderLastDepthPassMeshes = 0
NKM.GShaderNKMBufferBuildCount = NKM.GShaderNKMBufferBuildCount or 0
NKM.GShaderNKMBufferLastMeshes = 0
NKM.GShaderNKMBufferLastAt = nil
NKM.GShaderNKMBufferReady = false
NKM.GShaderNKMBufferLastError = nil
NKM.GShaderNKMBufferDebug = false
NKM.GShaderPixelLighting = false
local NKM_GShaderPixelLightingConVar = CreateClientConVar(
    "nkm_gshader_pixel_lighting", "0", true, false,
    "Use the rebuilt NKM GShader shader for per-pixel ambient/directional/static-point lighting."
)
local NKM_GShaderContactShadowsConVar = CreateClientConVar(
    "nkm_gshader_contact_shadows", "1", true, false,
    "Enable NKM screen-space point/directional contact shadows."
)
local NKM_GShaderAOConVar = CreateClientConVar(
    "nkm_gshader_ao", "1", true, false,
    "Enable NKM screen-space ambient occlusion."
)

local GSHADER_NKM_STENCIL_BIT = 128
local GSHADER_MAX_DYNAMIC_LIGHTS = 32

local GSHADER_DEPTH_MATERIAL = CreateMaterial("nkm_gshader_depthwrite_r5", "DepthWrite", {
    ["$basetexture"] = "color/white",
    ["$color_depth"] = "1",
    ["$nocull"] = "0"
})

local GSHADER_MASK_MATERIAL = CreateMaterial("nkm_gshader_mask_r5", "UnlitGeneric", {
    ["$basetexture"] = "color/white",
    ["$vertexcolor"] = "0",
    ["$vertexalpha"] = "0",
    ["$nocull"] = "0"
})

local GSHADER_NKM_VERTEX_NORMAL_MATERIAL = CreateMaterial("nkm_gshader_vertex_normal_debug", "UnlitGeneric", {
    ["$basetexture"] = "color/white",
    ["$vertexcolor"] = "1",
    ["$vertexalpha"] = "1",
    ["$linearwrite"] = "1",
    ["$nocull"] = "0"
})

local function isFiniteNumber(value)
    return isnumber(value) and value == value and value ~= math.huge and value ~= -math.huge
end

local function destroyMeshList(meshList)
    for _, entry in ipairs(meshList or {}) do
        if entry.mesh and entry.mesh:IsValid() then
            entry.mesh:Destroy()
        end
        if entry.blendMesh and entry.blendMesh:IsValid() then
            entry.blendMesh:Destroy()
        end
        if entry.normalDebugMesh and entry.normalDebugMesh:IsValid() then
            entry.normalDebugMesh:Destroy()
        end
    end
end

local function getVertexColor(value)
    if not value then return Color(255, 255, 255, 255) end
    return Color(
        math.Clamp(math.floor(value[1] or 255), 0, 255),
        math.Clamp(math.floor(value[2] or 255), 0, 255),
        math.Clamp(math.floor(value[3] or 255), 0, 255),
        math.Clamp(math.floor(value[4] or 255), 0, 255)
    )
end

local function encodeGShaderOctahedralNormal(normal)
    local x, y, z = normal.x, normal.y, normal.z
    local length = math.sqrt(x * x + y * y + z * z)
    if length < 0.000001 then
        return Color(128, 128, 255, 255)
    end

    x, y, z = x / length, y / length, z / length
    local denominator = math.abs(x) + math.abs(y) + math.abs(z)
    if denominator < 0.000001 then
        return Color(128, 128, 255, 255)
    end

    x, y, z = x / denominator, y / denominator, z / denominator
    if z < 0 then
        local oldX, oldY = x, y
        x = (1 - math.abs(oldY)) * (oldX >= 0 and 1 or -1)
        y = (1 - math.abs(oldX)) * (oldY >= 0 and 1 or -1)
    end

    return Color(
        math.Clamp(math.floor((x * 0.5 + 0.5) * 255 + 0.5), 0, 255),
        math.Clamp(math.floor((y * 0.5 + 0.5) * 255 + 0.5), 0, 255),
        128,
        255
    )
end

local function makeMeshVertex(value, renderOffset, forceWhite, applyNKMLighting)
    local p = value.p
    local n = value.n or { 0, 0, 1 }
    local uv = value.uv or { 0, 0 }
    local position = Vector(p[1], p[2], p[3])
    local normal = Vector(n[1], n[2], n[3])

    -- This offset affects the client render mesh only. Collision and trace data
    -- remain at exact Source BSP coordinates, allowing a clean Z-fighting test.
    if renderOffset and math.abs(renderOffset) > 0.0001 then
        if normal:LengthSqr() > 0.000001 then
            normal:Normalize()
            position = position + normal * renderOffset
        end
    end

    local color = forceWhite and Color(255, 255, 255, 255) or getVertexColor(value.color)
    local light = applyNKMLighting and value.nkmLighting or nil
    if light then
        color.r = math.Clamp(math.floor(color.r * math.Clamp((light[1] or 255) / 255, 0, 1) + 0.5), 0, 255)
        color.g = math.Clamp(math.floor(color.g * math.Clamp((light[2] or 255) / 255, 0, 1) + 0.5), 0, 255)
        color.b = math.Clamp(math.floor(color.b * math.Clamp((light[3] or 255) / 255, 0, 1) + 0.5), 0, 255)
    end

    return {
        pos = position,
        normal = normal,
        u = uv[1],
        v = uv[2],
        color = color
    }
end

local BSPAlbedoMaterialCache = {}

local function getSafeMaterialString(material, key)
    if not material then return nil end
    local ok, value = pcall(material.GetString, material, key)
    if ok and isstring(value) and value ~= "" then return value end
    return nil
end

local function getSafeMaterialShader(material)
    if not material then return "<unavailable>" end
    local ok, value = pcall(material.GetShader, material)
    if ok and isstring(value) then return value end
    return "<unavailable>"
end

local function createBSPAlbedoMaterial(sourceName, textureName, blendLayer)
    if not isstring(textureName) or textureName == "" then return DEFAULT_MATERIAL end
    local cacheKey = tostring(sourceName) .. "|" .. textureName .. "|" .. tostring(blendLayer == true)
    if BSPAlbedoMaterialCache[cacheKey] then return BSPAlbedoMaterialCache[cacheKey] end

    local hash = util.CRC(cacheKey)
    local parameters = {
        ["$basetexture"] = textureName,
        ["$vertexcolor"] = "1",
        ["$vertexalpha"] = blendLayer and "1" or "0",
        ["$nocull"] = "1"
    }
    if blendLayer then parameters["$translucent"] = "1" end

    local ok, generated = pcall(CreateMaterial, "nkm_bsp_albedo_" .. tostring(hash), "UnlitGeneric", parameters)
    if not ok or not generated then generated = DEFAULT_MATERIAL end
    BSPAlbedoMaterialCache[cacheKey] = generated
    return generated
end

local function getBSPMaterialBundle(materialName)
    local sourceMaterial = DEFAULT_MATERIAL
    if isstring(materialName) and materialName ~= "" then
        local ok, candidate = pcall(Material, materialName)
        if ok and candidate then
            local errorOK, isError = pcall(candidate.IsError, candidate)
            if errorOK and not isError then sourceMaterial = candidate end
        end
    end

    local shader = getSafeMaterialShader(sourceMaterial)
    local baseTexture = getSafeMaterialString(sourceMaterial, "$basetexture")
    local baseTexture2 = getSafeMaterialString(sourceMaterial, "$basetexture2")
    local albedoMaterial = createBSPAlbedoMaterial(materialName, baseTexture, false)
    local blendMaterial = baseTexture2 and createBSPAlbedoMaterial(materialName, baseTexture2, true) or nil

    return {
        source = sourceMaterial,
        shader = shader,
        baseTexture = baseTexture,
        baseTexture2 = baseTexture2,
        albedo = albedoMaterial,
        blend = blendMaterial
    }
end

local NKMLightingMaterialCache = {}

local function createNKMLightingMaterial(materialName)
    local sourceMaterial = DEFAULT_MATERIAL
    if isstring(materialName) and materialName ~= "" then
        local ok, candidate = pcall(Material, materialName)
        if ok and candidate then
            local errorOK, isError = pcall(candidate.IsError, candidate)
            if errorOK and not isError then sourceMaterial = candidate end
        end
    end

    local baseTexture = getSafeMaterialString(sourceMaterial, "$basetexture") or "color/white"
    local cacheKey = tostring(materialName or "<default>") .. "|" .. baseTexture
    if NKMLightingMaterialCache[cacheKey] then return NKMLightingMaterialCache[cacheKey] end

    -- The NKM lighting path deliberately uses a predictable vertex-color shader.
    -- Complex Source world shaders remain available in the non-lit material path.
    local hash = util.CRC(cacheKey)
    local ok, generated = pcall(CreateMaterial, "nkm_vertex_lit_v5_" .. tostring(hash), "UnlitGeneric", {
        ["$basetexture"] = baseTexture,
        ["$vertexcolor"] = "1",
        ["$vertexalpha"] = "1"
    })
    if not ok or not generated then generated = DEFAULT_MATERIAL end
    NKMLightingMaterialCache[cacheKey] = generated
    return generated
end

local function buildChunkRenderMeshes(meshGroups, chunkID)
    local built = {}
    local buildNormalDebugMeshes = NKM.GShaderNKMBufferDebug == true

    for groupIndex, group in ipairs(meshGroups or {}) do
        local source = group.vertices or {}
        local sourceIndex = 1
        local isBSPDisplacement = group.isBSPDisplacement == true
        local hasNKMLighting = group.hasNKMLighting == true
        local renderOffset = isBSPDisplacement and (NKM.ClientBSPDisplacementRenderOffset or 0) or 0
        local material = DEFAULT_MATERIAL
        local bspBundle = nil
        local nkmLightingMaterial = nil
        local flipBrushWinding = not isBSPDisplacement and NKM.ClientFlipBrushWinding ~= false
        if isBSPDisplacement then
            bspBundle = getBSPMaterialBundle(group.material)
            material = bspBundle.source
        elseif isstring(group.material) and group.material ~= "" then
            local materialOK, candidate = pcall(Material, group.material)
            if materialOK and candidate then
                local errorOK, isError = pcall(candidate.IsError, candidate)
                if errorOK and not isError then material = candidate end
            end
            if hasNKMLighting then
                nkmLightingMaterial = createNKMLightingMaterial(group.material)
            end
        end

        while sourceIndex <= #source do
            local batch = {}
            local blendBatch = bspBundle and bspBundle.blend and {} or nil
            local batchEnd = math.min(sourceIndex + NKM.MeshVertexLimit - 1, #source)
            batchEnd = batchEnd - ((batchEnd - sourceIndex + 1) % 3)
            if batchEnd < sourceIndex then
                destroyMeshList(built)
                return nil, "could not create triangle-aligned mesh batch"
            end

            local useBSPVertexLighting = isBSPDisplacement
                and NKM.ClientBSPDisplacementMaterialMode == "lit"
                and NKM.GShaderPixelLighting ~= true
            local forceWhite = isBSPDisplacement and not useBSPVertexLighting
            local useBakedNKMLighting = hasNKMLighting and NKM.GShaderPixelLighting ~= true
            for index = sourceIndex, batchEnd do
                local value = source[index]
                batch[#batch + 1] = makeMeshVertex(value, renderOffset, forceWhite, useBakedNKMLighting)
                if blendBatch then
                    local blendVertex = makeMeshVertex(value, renderOffset, forceWhite, useBakedNKMLighting)
                    local color = blendVertex.color
                    color.a = math.Clamp(math.floor((value.blendAlpha or 255) + 0.5), 0, 255)
                    blendVertex.color = color
                    blendBatch[#blendBatch + 1] = blendVertex
                end
            end

            local normalDebugBatch = nil
            if buildNormalDebugMeshes then
                normalDebugBatch = {}
                for triangleStart = 1, #batch, 3 do
                    local a, b, c = batch[triangleStart], batch[triangleStart + 1], batch[triangleStart + 2]
                    local faceNormal = (b.pos - a.pos):Cross(c.pos - a.pos)
                    if faceNormal:LengthSqr() < 0.000001 then
                        faceNormal = Vector(0, 0, 1)
                    else
                        faceNormal:Normalize()
                    end

                    for vertexOffset = 0, 2 do
                        local vertexIndex = triangleStart + vertexOffset
                        local sourceVertex = source[sourceIndex + vertexIndex - 1]
                        local sourceNormal = sourceVertex and sourceVertex.n
                        local normal = faceNormal
                        if istable(sourceNormal)
                            and isFiniteNumber(sourceNormal[1])
                            and isFiniteNumber(sourceNormal[2])
                            and isFiniteNumber(sourceNormal[3]) then
                            local candidate = Vector(sourceNormal[1], sourceNormal[2], sourceNormal[3])
                            if candidate:LengthSqr() > 0.000001 then
                                candidate:Normalize()
                                normal = candidate
                            end
                        end

                        normalDebugBatch[#normalDebugBatch + 1] = {
                            pos = batch[vertexIndex].pos,
                            normal = normal,
                            u = 0,
                            v = 0,
                            color = encodeGShaderOctahedralNormal(normal)
                        }
                    end
                end
            end

            -- Source IMesh culling expects the opposite triangle order to the
            -- editor's outward-facing face order. Keep this flip for ordinary NKM
            -- brush meshes; do not apply it to imported BSP displacements.
            if flipBrushWinding then
                for i = 1, #batch - 2, 3 do
                    batch[i + 1], batch[i + 2] = batch[i + 2], batch[i + 1]
                    if normalDebugBatch then
                        normalDebugBatch[i + 1], normalDebugBatch[i + 2] =
                            normalDebugBatch[i + 2], normalDebugBatch[i + 1]
                    end
                end
            end

            -- BSP world shaders (especially WorldVertexTransition) are not a
            -- supported IMesh vertex-format contract. Use the generic format
            -- for imported displacements and bind compatible materials at Draw.
            local imesh = (isBSPDisplacement or hasNKMLighting) and Mesh() or Mesh(material)
            if not imesh then
                destroyMeshList(built)
                return nil, "Mesh() returned nil for chunk " .. tostring(chunkID)
            end

            local ok, err = pcall(function()
                imesh:BuildFromTriangles(batch)
            end)
            if not ok then
                if imesh:IsValid() then imesh:Destroy() end
                destroyMeshList(built)
                return nil, "BuildFromTriangles failed in chunk " .. tostring(chunkID) .. ": " .. tostring(err)
            end

            local normalDebugMesh = nil
            if normalDebugBatch then
                normalDebugMesh = Mesh()
                if not normalDebugMesh then
                    if imesh:IsValid() then imesh:Destroy() end
                    destroyMeshList(built)
                    return nil, "normal debug Mesh() returned nil for chunk " .. tostring(chunkID)
                end
                local normalOK, normalError = pcall(function()
                    normalDebugMesh:BuildFromTriangles(normalDebugBatch)
                end)
                if not normalOK then
                    if imesh:IsValid() then imesh:Destroy() end
                    if normalDebugMesh:IsValid() then normalDebugMesh:Destroy() end
                    destroyMeshList(built)
                    return nil, "normal debug BuildFromTriangles failed in chunk "
                        .. tostring(chunkID) .. ": " .. tostring(normalError)
                end
            end

            local blendMesh = nil
            if blendBatch then
                blendMesh = Mesh()
                if not blendMesh then
                    if imesh:IsValid() then imesh:Destroy() end
                    if normalDebugMesh and normalDebugMesh:IsValid() then normalDebugMesh:Destroy() end
                    destroyMeshList(built)
                    return nil, "blend Mesh() returned nil for chunk " .. tostring(chunkID)
                end
                local blendOK, blendError = pcall(function()
                    blendMesh:BuildFromTriangles(blendBatch)
                end)
                if not blendOK then
                    if imesh:IsValid() then imesh:Destroy() end
                    if blendMesh:IsValid() then blendMesh:Destroy() end
                    if normalDebugMesh and normalDebugMesh:IsValid() then normalDebugMesh:Destroy() end
                    destroyMeshList(built)
                    return nil, "blend BuildFromTriangles failed in chunk " .. tostring(chunkID) .. ": " .. tostring(blendError)
                end
            end

            built[#built + 1] = {
                mesh = imesh,
                blendMesh = blendMesh,
                normalDebugMesh = normalDebugMesh,
                material = material,
                albedoMaterial = bspBundle and bspBundle.albedo or nil,
                blendMaterial = bspBundle and bspBundle.blend or nil,
                nkmLightingMaterial = nkmLightingMaterial,
                hasNKMLighting = hasNKMLighting,
                sourceShader = bspBundle and bspBundle.shader or nil,
                sourceBaseTexture = bspBundle and bspBundle.baseTexture or nil,
                sourceBaseTexture2 = bspBundle and bspBundle.baseTexture2 or nil,
                sourceGroup = group.sourceGroup or groupIndex,
                chunkID = chunkID,
                isBSPDisplacement = isBSPDisplacement,
                sourcePatchID = group.sourcePatchID or group.sourceGroup or groupIndex,
                sourceFace = group.sourceFace,
                sourceMaterial = group.material
            }
            sourceIndex = batchEnd + 1
        end
    end

    return built
end

local function rebuildLoadedMeshList()
    local combined = {}
    local loadedCount = 0
    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        if chunk.loaded then loadedCount = loadedCount + 1 end
        for _, entry in ipairs(chunk.renderMeshes or {}) do
            combined[#combined + 1] = entry
        end
    end
    NKM.RenderMeshes = combined
    NKM.LoadedClientChunkCount = loadedCount
end

local function distanceSqrToBounds(position, mins, maxs)
    local dx = position.x < mins.x and mins.x - position.x or (position.x > maxs.x and position.x - maxs.x or 0)
    local dy = position.y < mins.y and mins.y - position.y or (position.y > maxs.y and position.y - maxs.y or 0)
    local dz = position.z < mins.z and mins.z - position.z or (position.z > maxs.z and position.z - maxs.z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function getChunkCacheDirectory(mapName)
    if not NKM.IsValidMapName(mapName) then return nil end
    return NKM.ChunkCacheRoot .. "/" .. string.lower(mapName) .. "/format_" .. tostring(NKM.Version)
end

local function getChunkCacheFileName(chunk)
    if not chunk or not isnumber(chunk.index) or chunk.index < 1 or not isstring(chunk.checksum) then
        return nil
    end
    if not chunk.checksum:match("^[%w]+$") then return nil end
    return "chunk_" .. tostring(math.floor(chunk.index)) .. "_" .. chunk.checksum .. ".dat"
end

local function getChunkCachePath(chunk, mapName)
    local directory = getChunkCacheDirectory(mapName or NKM.ClientMapName)
    local fileName = getChunkCacheFileName(chunk)
    if not directory or not fileName then return nil end
    return directory .. "/" .. fileName
end

local function addCacheStat(name, amount)
    NKM.ChunkCacheStats[name] = (NKM.ChunkCacheStats[name] or 0) + (amount or 1)
end

local function readChunkCacheInternal(chunk)
    if not NKM.ChunkCacheEnabled then return nil, "disabled" end
    local path = getChunkCachePath(chunk)
    if not path then return nil, "invalid cache path" end

    local raw = file.Read(path, "DATA")
    if not raw then
        addCacheStat("Misses")
        return nil, "miss"
    end

    addCacheStat("BytesRead", #raw)
    if #raw ~= chunk.expectedBytes or util.CRC(raw) ~= chunk.checksum then
        file.Delete(path)
        addCacheStat("Corruptions")
        addCacheStat("Evictions")
        addCacheStat("Misses")
        return nil, "corrupt"
    end

    local decoded = util.JSONToTable(raw)
    if not istable(decoded) then
        file.Delete(path)
        addCacheStat("Corruptions")
        addCacheStat("Evictions")
        addCacheStat("Misses")
        return nil, "invalid JSON"
    end

    return decoded, "hit"
end

function NKM.ReadChunkCache(chunk)
    local startedAt = NKM.PerfBegin()
    local payload, state = readChunkCacheInternal(chunk)
    NKM.PerfRecord("cache_read_validate_decode", startedAt)
    if payload then NKM.PerfAdd("cache_disk_hits", 1) end
    return payload, state
end

local function writeChunkCacheInternal(chunk, raw)
    if not NKM.ChunkCacheEnabled or not isstring(raw) then return false, "disabled or invalid payload" end
    local path = getChunkCachePath(chunk)
    local directory = getChunkCacheDirectory(NKM.ClientMapName)
    if not path or not directory then return false, "invalid cache path" end
    if #raw ~= chunk.expectedBytes or util.CRC(raw) ~= chunk.checksum then
        return false, "payload does not match manifest checksum"
    end

    file.CreateDir(NKM.ChunkCacheRoot)
    file.CreateDir(NKM.ChunkCacheRoot .. "/" .. string.lower(NKM.ClientMapName))
    file.CreateDir(directory)
    local ok = file.Write(path, raw)
    if not ok and file.Read(path, "DATA") ~= raw then
        return false, "file.Write failed"
    end

    addCacheStat("Writes")
    addCacheStat("BytesWritten", #raw)
    return true
end

function NKM.WriteChunkCache(chunk, raw)
    local startedAt = NKM.PerfBegin()
    local ok, err = writeChunkCacheInternal(chunk, raw)
    NKM.PerfRecord("cache_write", startedAt)
    return ok, err
end

function NKM.CleanChunkCache(manifest, chunks)
    if not NKM.ChunkCacheEnabled or not istable(manifest) then return end
    local directory = getChunkCacheDirectory(manifest.mapName)
    if not directory then return end

    file.CreateDir(NKM.ChunkCacheRoot)
    file.CreateDir(NKM.ChunkCacheRoot .. "/" .. string.lower(manifest.mapName))
    file.CreateDir(directory)

    -- The checksum is part of every filename. Keep only entries referenced by
    -- the current manifest; stale map revisions are removed automatically.
    local expected = {}
    for _, chunk in ipairs(chunks or {}) do
        local name = getChunkCacheFileName(chunk)
        if name then expected[name] = true end
    end

    local files = file.Find(directory .. "/*.dat", "DATA") or {}
    for _, name in ipairs(files) do
        if name:match("^chunk_%d+_[%w]+%.dat$") and not expected[name] then
            file.Delete(directory .. "/" .. name)
            addCacheStat("Evictions")
        end
    end

    -- Remove cache files from old format-version directories for this map.
    local mapRoot = NKM.ChunkCacheRoot .. "/" .. string.lower(manifest.mapName)
    local _, oldDirectories = file.Find(mapRoot .. "/*", "DATA")
    oldDirectories = oldDirectories or {}
    local currentDirectoryName = "format_" .. tostring(NKM.Version)
    for _, oldName in ipairs(oldDirectories) do
        if oldName:match("^format_%d+$") and oldName ~= currentDirectoryName then
            local oldPath = mapRoot .. "/" .. oldName
            local oldFiles = file.Find(oldPath .. "/*", "DATA") or {}
            for _, oldFile in ipairs(oldFiles) do
                if oldFile:match("^chunk_%d+_[%w]+%.dat$") then
                    file.Delete(oldPath .. "/" .. oldFile)
                    addCacheStat("Evictions")
                end
            end
        end
    end
end

function NKM.GetChunkCacheDiskStats(mapName)
    local directory = getChunkCacheDirectory(mapName or NKM.ClientMapName)
    if not directory then return 0, 0 end
    local files = file.Find(directory .. "/*.dat", "DATA") or {}
    local count, bytes = 0, 0
    for _, name in ipairs(files) do
        if name:match("^chunk_%d+_[%w]+%.dat$") then
            local size = file.Size(directory .. "/" .. name, "DATA")
            if size and size > 0 then
                count = count + 1
                bytes = bytes + size
            end
        end
    end
    return count, bytes
end

local function clearMapChunkCache(mapName)
    if not NKM.IsValidMapName(mapName) then return 0 end
    local mapRoot = NKM.ChunkCacheRoot .. "/" .. string.lower(mapName)
    local _, directories = file.Find(mapRoot .. "/*", "DATA")
    directories = directories or {}
    local deleted = 0
    for _, directoryName in ipairs(directories) do
        if directoryName:match("^format_%d+$") then
            local directory = mapRoot .. "/" .. directoryName
            local files = file.Find(directory .. "/*", "DATA") or {}
            for _, fileName in ipairs(files) do
                if fileName:match("^chunk_%d+_[%w]+%.dat$") then
                    file.Delete(directory .. "/" .. fileName)
                    deleted = deleted + 1
                end
            end
        end
    end
    return deleted
end

function NKM.ClearChunkCache(mapName)
    if mapName then return clearMapChunkCache(mapName) end
    local _, maps = file.Find(NKM.ChunkCacheRoot .. "/*", "DATA")
    maps = maps or {}
    local deleted = 0
    for _, cachedMap in ipairs(maps) do
        if NKM.IsValidMapName(cachedMap) then
            deleted = deleted + clearMapChunkCache(cachedMap)
        end
    end
    return deleted
end

local function rebuildClientTraceMap()
    local perfStartedAt = NKM.PerfBegin()
    if not NKM.ClientMapName then
        NKM.TraceMap = nil
        NKM.PerfRecord("trace_rebuild", perfStartedAt)
        return
    end

    local traceChunks = {}
    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        if chunk.loaded and ((istable(chunk.collision) and #chunk.collision > 0)
            or (istable(chunk.triangleSurfaces) and #chunk.triangleSurfaces > 0)) then
            traceChunks[#traceChunks + 1] = chunk
        end
    end

    local traceMap, err = NKM.BuildTraceData({
        name = NKM.ClientMapName,
        collision = {}
    }, NKM.ClientMapName, traceChunks)

    if not traceMap then
        ErrorNoHalt("[NKM] Could not rebuild client trace map: " .. tostring(err) .. "\n")
        NKM.TraceMap = nil
        NKM.PerfRecord("trace_rebuild", perfStartedAt)
        return
    end

    NKM.TraceMap = traceMap
    NKM.PerfRecord("trace_rebuild", perfStartedAt)
end

local function hasGShaderAPI()
    return istable(shaderlib)
        and isfunction(shaderlib.DrawScreenQuad)
        and isfunction(shaderlib.GetViewProjMatrix)
        and isfunction(shaderlib.CanDrawEffects)
end

local getNKMDeferredMaterial

local function setClientLightingSettings(lighting)
    local hasDeferredSettings = istable(lighting) and istable(lighting.deferred)
    local clean = {
        enabled = istable(lighting) and lighting.enabled ~= false,
        shadows = not istable(lighting) or lighting.shadows ~= false,
        ambient = { 32, 32, 32 },
        directional = {},
        deferred = {
            ao = hasDeferredSettings and lighting.deferred.ao ~= false,
            contactShadows = hasDeferredSettings and lighting.deferred.contactShadows ~= false,
            aoRadius = 72,
            aoStrength = 0.35
        },
        point = {}
    }

    if istable(lighting) and istable(lighting.ambient) then
        for channel = 1, 3 do
            if isFiniteNumber(lighting.ambient[channel]) then
                clean.ambient[channel] = math.Clamp(lighting.ambient[channel], 0, 255)
            end
        end
    end

    if hasDeferredSettings then
        local deferred = lighting.deferred
        if isFiniteNumber(deferred.aoRadius) then clean.deferred.aoRadius = math.Clamp(deferred.aoRadius, 1, 512) end
        if isFiniteNumber(deferred.aoStrength) then clean.deferred.aoStrength = math.Clamp(deferred.aoStrength, 0, 1) end
    end

    local pixelRequested = NKM_GShaderPixelLightingConVar:GetBool()
    local pixelModeAvailable = clean.enabled and pixelRequested
        and NKM.GShaderBridgeEnabled == true and hasGShaderAPI()
        and getNKMDeferredMaterial() ~= nil
    NKM.GShaderPixelLighting = pixelModeAvailable == true

    if clean.enabled and istable(lighting.directional) then
        for _, light in ipairs(lighting.directional) do
            if #clean.directional >= (NKM.MaxLightingDirectionalLights or 4) then break end
            if istable(light) and istable(light.direction) and istable(light.color)
                and isFiniteNumber(light.direction[1]) and isFiniteNumber(light.direction[2]) and isFiniteNumber(light.direction[3])
                and isFiniteNumber(light.color[1]) and isFiniteNumber(light.color[2]) and isFiniteNumber(light.color[3])
                and isFiniteNumber(light.intensity or 1) then
                local directionLengthSqr = light.direction[1] * light.direction[1]
                    + light.direction[2] * light.direction[2] + light.direction[3] * light.direction[3]
                if directionLengthSqr > 0.000001 then
                    clean.directional[#clean.directional + 1] = {
                        direction = { light.direction[1], light.direction[2], light.direction[3] },
                        color = {
                            math.Clamp(light.color[1], 0, 255),
                            math.Clamp(light.color[2], 0, 255),
                            math.Clamp(light.color[3], 0, 255)
                        },
                        intensity = math.Clamp(light.intensity or 1, 0, 8),
                        shadows = light.shadows ~= false
                    }
                end
            end
        end
    end

    if clean.enabled and istable(lighting.point) then
        for _, light in ipairs(lighting.point) do
            if #clean.point >= GSHADER_MAX_DYNAMIC_LIGHTS then break end
            -- Static point lights stay in the vertex bake until the matching VCS
            -- is rebuilt and the user opts in; dynamic lights can use GShader now.
            if pixelModeAvailable or light.dynamic == true then
                if istable(light) and istable(light.position) and istable(light.color)
                    and isFiniteNumber(light.position[1]) and isFiniteNumber(light.position[2]) and isFiniteNumber(light.position[3])
                    and isFiniteNumber(light.color[1]) and isFiniteNumber(light.color[2]) and isFiniteNumber(light.color[3])
                    and isFiniteNumber(light.radius) and light.radius > 0
                    and isFiniteNumber(light.intensity or 1) then
                    clean.point[#clean.point + 1] = {
                        position = { light.position[1], light.position[2], light.position[3] },
                        color = {
                            math.Clamp(light.color[1], 0, 255),
                            math.Clamp(light.color[2], 0, 255),
                            math.Clamp(light.color[3], 0, 255)
                        },
                        radius = math.Clamp(light.radius, 1, 16384),
                        intensity = math.Clamp(light.intensity or 1, 0, 8),
                        shadows = clean.shadows and light.shadows ~= false
                    }
                end
            end
        end
    end

    NKM.ClientLighting = clean
    NKM.ClientDynamicLights = clean.point
    NKM.GShaderLUTGeneration = nil
    NKM.GShaderLUTLastError = nil
end

local function updateGShaderDynamicLightLUT()
    if not hasGShaderAPI() or not isfunction(shaderlib.CreateLUT) or not isfunction(shaderlib.WritePixel) then
        NKM.GShaderLUTLastError = "GShader LUT API unavailable"
        return false
    end
    if NKM.GShaderLUTGeneration == NKM.ClientGeneration and NKM.GShaderDynamicLightLUT then
        return true
    end

    local lut = NKM.GShaderDynamicLightLUT
    if not lut then
        local ok, result = pcall(shaderlib.CreateLUT, "_rt_NKM_DynamicLights", 2, GSHADER_MAX_DYNAMIC_LIGHTS)
        if not ok or not result then
            NKM.GShaderLUTLastError = tostring(result or "CreateLUT returned nil")
            return false
        end
        lut = result
        NKM.GShaderDynamicLightLUT = lut
    end

    for index = 0, GSHADER_MAX_DYNAMIC_LIGHTS - 1 do
        local light = NKM.ClientDynamicLights[index + 1]
        local position = light and light.position or { 0, 0, 0 }
        local color = light and light.color or { 0, 0, 0 }
        local intensity = light and light.intensity or 0
        local radius = light and light.radius or 1
        local castsShadows = light and light.shadows and 1 or 0

        local okPosition, positionError = pcall(shaderlib.WritePixel,
            lut, 0, index, position[1], position[2], position[3], radius)
        local okColor, colorError = pcall(shaderlib.WritePixel,
            lut, 1, index,
            color[1] / 255 * intensity,
            color[2] / 255 * intensity,
            color[3] / 255 * intensity,
            castsShadows)
        if not okPosition or not okColor then
            NKM.GShaderLUTLastError = tostring(positionError or colorError or "WritePixel failed")
            return false
        end
    end

    NKM.GShaderLUTGeneration = NKM.ClientGeneration
    NKM.GShaderLUTLastError = nil
    return true
end

getNKMDeferredMaterial = function()
    if NKM.GShaderDeferredMaterial then
        local ok, isError = pcall(NKM.GShaderDeferredMaterial.IsError, NKM.GShaderDeferredMaterial)
        if ok and not isError then return NKM.GShaderDeferredMaterial end
    end

    local ok, material = pcall(Material, "pp/nkm_deferred_lighting")
    if not ok or not material then
        NKM.GShaderLastError = "Material pp/nkm_deferred_lighting is unavailable"
        return nil
    end
    local isErrorOK, isError = pcall(material.IsError, material)
    if not isErrorOK or isError then
        NKM.GShaderLastError = "Custom shader is not compiled/available (pp/nkm_deferred_lighting)"
        return nil
    end
    NKM.GShaderDeferredMaterial = material
    NKM.GShaderLastError = nil
    return material
end

local function hasNKMStaticDeferredLighting()
    local lighting = NKM.ClientLighting
    if not lighting or lighting.enabled ~= true then return false end
    local deferred = lighting.deferred or {}
    local hasAO = deferred.ao == true and (deferred.aoStrength or 0) > 0.0001
    if hasAO then return true end
    if NKM.GShaderPixelLighting ~= true then return false end
    local ambient = lighting.ambient or {}
    local hasAmbient = (ambient[1] or 0) > 0 or (ambient[2] or 0) > 0 or (ambient[3] or 0) > 0
    return hasAmbient or #(lighting.directional or {}) > 0
end

local function shouldRunGShaderLighting()
    if not NKM.GShaderBridgeEnabled or not hasGShaderAPI() then return false end
    if NKM.GShaderMaskDebug then return true end

    local lighting = NKM.ClientLighting
    if not lighting or lighting.enabled ~= true then return false end

    return hasNKMStaticDeferredLighting()
        or #(NKM.ClientDynamicLights or {}) > 0
end

local function resetNKMStencilState()
    render.SetStencilEnable(false)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    render.SetStencilReferenceValue(0)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilPassOperation(STENCIL_KEEP)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.SetStencilZFailOperation(STENCIL_KEEP)
end

local function clearNKMStencilBit()
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(GSHADER_NKM_STENCIL_BIT)
    render.SetStencilTestMask(0)
    render.SetStencilReferenceValue(0)
    render.SetStencilCompareFunction(STENCIL_ALWAYS)
    render.SetStencilPassOperation(STENCIL_ZERO)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.SetStencilZFailOperation(STENCIL_KEEP)
    render.PerformFullScreenStencilOperation()
    resetNKMStencilState()
end

local function markVisibleNKMGeometry()
    local drawCount = 0
    if not NKM.RenderMeshes or #NKM.RenderMeshes == 0 then return 0 end

    local ok, err = pcall(function()
        render.SetStencilEnable(true)
        render.SetStencilWriteMask(GSHADER_NKM_STENCIL_BIT)
        render.SetStencilTestMask(0)
        render.SetStencilReferenceValue(GSHADER_NKM_STENCIL_BIT)
        render.SetStencilCompareFunction(STENCIL_ALWAYS)
        render.SetStencilPassOperation(STENCIL_REPLACE)
        render.SetStencilFailOperation(STENCIL_KEEP)
        render.SetStencilZFailOperation(STENCIL_KEEP)
        -- Keep the scene's depth test, but do not modify hardware depth while
        -- stamping the NKM-only stencil bit. Failed depth pixels stay unmarked.
        render.OverrideDepthEnable(true, false)
        render.OverrideColorWriteEnable(true, false)

        for _, entry in ipairs(NKM.RenderMeshes) do
            local isBSPDisplacement = entry.isBSPDisplacement == true
            local shouldDraw = not (isBSPDisplacement and NKM.ClientBSPDisplacementRenderEnabled == false)
            if shouldDraw and entry.mesh and entry.mesh:IsValid() then
                render.SetMaterial(GSHADER_MASK_MATERIAL)
                entry.mesh:Draw()
                drawCount = drawCount + 1
            end
        end
    end)

    -- Always release global render overrides, including after a failed IMesh draw.
    render.OverrideColorWriteEnable(false, false)
    render.OverrideDepthEnable(false, false)
    render.SetBlend(1)
    resetNKMStencilState()
    NKM.GShaderLastMaskDraws = drawCount
    if not ok then
        NKM.GShaderLastError = "NKM stencil mask draw failed: " .. tostring(err)
        return 0
    end

    NKM.GShaderMaskPassCount = (NKM.GShaderMaskPassCount or 0) + 1
    return drawCount
end

local function configureNKMStencilTest()
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(0)
    render.SetStencilTestMask(GSHADER_NKM_STENCIL_BIT)
    render.SetStencilReferenceValue(GSHADER_NKM_STENCIL_BIT)
    render.SetStencilCompareFunction(STENCIL_EQUAL)
    render.SetStencilPassOperation(STENCIL_KEEP)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.SetStencilZFailOperation(STENCIL_KEEP)
end

local function drawGShaderMaskDebug()
    configureNKMStencilTest()
    cam.Start2D()
        surface.SetDrawColor(0, 210, 255, 80)
        surface.DrawRect(0, 0, ScrW(), ScrH())
    cam.End2D()
    resetNKMStencilState()
end

local NKM_GShaderRawDepthRT
local NKM_GShaderWorldPosRT
local NKM_GShaderNormalRT
local NKM_GShaderDecodedWorldPosRT
local NKM_GShaderWorldPosDebugMaterial
local NKM_GShaderWorldPosSampler2RT
local NKM_GShaderWorldPosSampler2Material
local NKM_GShaderWorldPosNormal4TapRT
local NKM_GShaderWorldPosNormal4TapMaterial
local NKM_GShaderPointLightDebugRT
local NKM_GShaderPointLightDebugMaterial
local NKM_GShaderDecodedNormalRT
local NKM_GShaderVertexNormalRT
local NKM_GShaderDecodedVertexNormalRT
local NKM_GShaderVertexNormalDecodeMaterial
local NKM_GShaderNormal4TapRT
local NKM_GShaderDecodedNormal4TapRT
local NKM_GShaderWorldPosMaterial
local NKM_GShaderNormalMaterial
local NKM_GShaderNormalDecodeMaterial
local NKM_GShaderNormal4TapMaterial
local NKM_GShaderNormal4TapDecodeMaterial

local function ensureNKMNormalDecodeDebugResources(width, height, flags)
    if not NKM.GShaderNKMBufferDebug then
        NKM.GShaderNKMBufferDebugLastError = nil
        NKM.GShaderNKMBufferDebug4TapError = nil
        return true
    end

    -- This function is outside ensureNKMGShaderBufferResources, so it must
    -- resolve the format locally rather than using that function's local.
    local normalFormat = IMAGE_FORMAT_RGB888
    if isfunction(shaderlib.GetWorldNormalsImageFormat) then
        local formatOK, format = pcall(shaderlib.GetWorldNormalsImageFormat)
        if formatOK and format then normalFormat = format end
    end

    local decodedWorldPosReady = NKM_GShaderDecodedWorldPosRT
        and NKM_GShaderDecodedWorldPosRT:Width() == width
        and NKM_GShaderDecodedWorldPosRT:Height() == height
    if not decodedWorldPosReady then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_DecodedWorldPosition", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888)
        NKM_GShaderDecodedWorldPosRT = targetOK and target or nil
        if not NKM_GShaderDecodedWorldPosRT then
            NKM.GShaderNKMBufferDebugWorldPosError =
                tostring(target or "decoded world-position RT creation failed")
        end
    end

    local sampler2Ready = NKM_GShaderWorldPosSampler2RT
        and NKM_GShaderWorldPosSampler2RT:Width() == width
        and NKM_GShaderWorldPosSampler2RT:Height() == height
    if not sampler2Ready then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_WP_Sampler2_Debug", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888)
        NKM_GShaderWorldPosSampler2RT = targetOK and target or nil
        if not NKM_GShaderWorldPosSampler2RT then
            NKM.GShaderNKMBufferDebugSampler2Error =
                tostring(target or "sampler2 debug RT creation failed")
        end
    end

    local normal4TapTargetReady = NKM_GShaderWorldPosNormal4TapRT
        and NKM_GShaderWorldPosNormal4TapRT:Width() == width
        and NKM_GShaderWorldPosNormal4TapRT:Height() == height
    if not normal4TapTargetReady then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_WP_Normal4Tap_Debug", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888)
        NKM_GShaderWorldPosNormal4TapRT = targetOK and target or nil
        if not NKM_GShaderWorldPosNormal4TapRT then
            NKM.GShaderNKMBufferDebugNormal4TapError =
                tostring(target or "4-tap world-normal debug RT creation failed")
        end
    end

    local pointLightDebugReady = NKM_GShaderPointLightDebugRT
        and NKM_GShaderPointLightDebugRT:Width() == width
        and NKM_GShaderPointLightDebugRT:Height() == height
    if not pointLightDebugReady then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_PointLightContribution_Debug", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888)
        NKM_GShaderPointLightDebugRT = targetOK and target or nil
        if not NKM_GShaderPointLightDebugRT then
            NKM.GShaderNKMBufferDebugPointLightError =
                tostring(target or "point-light debug RT creation failed")
        end
    end

    if not NKM_GShaderPointLightDebugMaterial then
        local materialOK, material = pcall(Material, "pp/nkm_point_light_debug")
        if not materialOK or not material then
            NKM_GShaderPointLightDebugMaterial = nil
            NKM.GShaderNKMBufferDebugPointLightError =
                tostring(material or "point-light debug material is unavailable")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderPointLightDebugMaterial = nil
                NKM.GShaderNKMBufferDebugPointLightError =
                    "nkm_point_light_debug_ps30 is not compiled/available"
            else
                NKM_GShaderPointLightDebugMaterial = material
                NKM.GShaderNKMBufferDebugPointLightError = nil
            end
        end
    end

    if not NKM_GShaderWorldPosNormal4TapMaterial then
        local materialOK, material = pcall(Material, "pp/nkm_wp_4tap_normal_debug")
        if not materialOK or not material then
            NKM_GShaderWorldPosNormal4TapMaterial = nil
            NKM.GShaderNKMBufferDebugNormal4TapError =
                tostring(material or "4-tap world-normal debug material is unavailable")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderWorldPosNormal4TapMaterial = nil
                NKM.GShaderNKMBufferDebugNormal4TapError =
                    "nkm_wp_4tap_normal_debug_ps30 is not compiled/available"
            else
                NKM_GShaderWorldPosNormal4TapMaterial = material
                NKM.GShaderNKMBufferDebugNormal4TapError = nil
            end
        end
    end

    if not NKM_GShaderWorldPosSampler2Material then
        local materialOK, material = pcall(Material, "pp/nkm_wp_sampler2_debug")
        if not materialOK or not material then
            NKM_GShaderWorldPosSampler2Material = nil
            NKM.GShaderNKMBufferDebugSampler2Error =
                tostring(material or "world-position sampler2 debug material is unavailable")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderWorldPosSampler2Material = nil
                NKM.GShaderNKMBufferDebugSampler2Error =
                    "nkm_wp_sampler2_debug_ps30 is not compiled/available"
            else
                NKM_GShaderWorldPosSampler2Material = material
                NKM.GShaderNKMBufferDebugSampler2Error = nil
            end
        end
    end

    if not NKM_GShaderWorldPosDebugMaterial then
        local materialOK, material = pcall(Material, "pp/nkm_wp_position_debug")
        if not materialOK or not material then
            NKM_GShaderWorldPosDebugMaterial = nil
            NKM.GShaderNKMBufferDebugWorldPosError =
                tostring(material or "world-position debug material is unavailable")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderWorldPosDebugMaterial = nil
                NKM.GShaderNKMBufferDebugWorldPosError =
                    "nkm_wp_position_debug_ps30 is not compiled/available"
            else
                NKM_GShaderWorldPosDebugMaterial = material
                NKM.GShaderNKMBufferDebugWorldPosError = nil
            end
        end
    end

    local vertexNormalReady = NKM_GShaderVertexNormalRT
        and NKM_GShaderVertexNormalRT:Width() == width
        and NKM_GShaderVertexNormalRT:Height() == height
    if not vertexNormalReady then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_VertexNormals", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_SEPARATE, flags, 0, normalFormat)
        NKM_GShaderVertexNormalRT = targetOK and target or nil
        if not NKM_GShaderVertexNormalRT then
            NKM.GShaderNKMBufferDebugVertexError = tostring(target or "vertex normal RT creation failed")
        end
    end

    local decodedVertexReady = NKM_GShaderDecodedVertexNormalRT
        and NKM_GShaderDecodedVertexNormalRT:Width() == width
        and NKM_GShaderDecodedVertexNormalRT:Height() == height
    if not decodedVertexReady then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_DecodedVertexNormals", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA16161616F)
        NKM_GShaderDecodedVertexNormalRT = targetOK and target or nil
        if not NKM_GShaderDecodedVertexNormalRT then
            NKM.GShaderNKMBufferDebugVertexError = tostring(target or "decoded vertex normal RT creation failed")
        end
    end

    if not NKM_GShaderVertexNormalDecodeMaterial then
        local materialOK, material = pcall(CreateMaterial, "nkm_gshader_vertex_normal_decode_debug",
            "screenspace_general", {
                ["$pixshader"] = "wn_tangetns_decode_ps30",
                ["$vertexshader"] = "pp_vs30",
                ["$basetexture"] = "_rt_NKM_VertexNormals",
                ["$no_fullbright"] = "1",
                ["$ignorez"] = "1",
                ["$VERTEXTRANSFORM"] = "1",
                ["$WRITEALPHA"] = "1",
                ["$copyalpha"] = "1",
                ["$vertexalpha"] = "1"
            })
        if not materialOK or not material then
            NKM_GShaderVertexNormalDecodeMaterial = nil
            NKM.GShaderNKMBufferDebugVertexError = tostring(material or "vertex normal decode material failed")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderVertexNormalDecodeMaterial = nil
                NKM.GShaderNKMBufferDebugVertexError = "GShader vertex normal decode shader is unavailable"
            else
                NKM_GShaderVertexNormalDecodeMaterial = material
            end
        end
    end

    local decodedReady = NKM_GShaderDecodedNormalRT
        and NKM_GShaderDecodedNormalRT:Width() == width
        and NKM_GShaderDecodedNormalRT:Height() == height
    if not decodedReady then
        local decodedOK, decodedNormals = pcall(GetRenderTargetEx,
            "_rt_NKM_DecodedNormals", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA16161616F)
        if decodedOK and decodedNormals then
            NKM_GShaderDecodedNormalRT = decodedNormals
        else
            NKM_GShaderDecodedNormalRT = nil
            NKM.GShaderNKMBufferDebugLastError = tostring(decodedNormals or "decoded normal RT creation failed")
        end
    end

    if not NKM_GShaderNormalDecodeMaterial then
        local materialOK, material = pcall(CreateMaterial, "nkm_gshader_normal_decode_debug",
            "screenspace_general", {
                ["$pixshader"] = "wn_tangetns_decode_ps30",
                ["$vertexshader"] = "pp_vs30",
                ["$basetexture"] = "_rt_NKM_Normals",
                ["$no_fullbright"] = "1",
                ["$ignorez"] = "1",
                ["$VERTEXTRANSFORM"] = "1",
                ["$WRITEALPHA"] = "1",
                ["$copyalpha"] = "1",
                ["$vertexalpha"] = "1"
            })
        if not materialOK or not material then
            NKM_GShaderNormalDecodeMaterial = nil
            NKM.GShaderNKMBufferDebugLastError = tostring(material or "normal decode debug material failed")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderNormalDecodeMaterial = nil
                NKM.GShaderNKMBufferDebugLastError = "GShader normal decode shader is unavailable"
            else
                NKM_GShaderNormalDecodeMaterial = material
            end
        end
    end

    local fourTapTargetReady = NKM_GShaderNormal4TapRT
        and NKM_GShaderNormal4TapRT:Width() == width
        and NKM_GShaderNormal4TapRT:Height() == height
    if not fourTapTargetReady then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_Normals4Tap", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, normalFormat)
        NKM_GShaderNormal4TapRT = targetOK and target or nil
        if not NKM_GShaderNormal4TapRT then
            NKM.GShaderNKMBufferDebug4TapError = tostring(target or "4-tap normal RT creation failed")
        end
    end

    local decoded4TapReady = NKM_GShaderDecodedNormal4TapRT
        and NKM_GShaderDecodedNormal4TapRT:Width() == width
        and NKM_GShaderDecodedNormal4TapRT:Height() == height
    if not decoded4TapReady then
        local targetOK, target = pcall(GetRenderTargetEx,
            "_rt_NKM_DecodedNormals4Tap", width, height, RT_SIZE_FULL_FRAME_BUFFER,
            MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA16161616F)
        NKM_GShaderDecodedNormal4TapRT = targetOK and target or nil
        if not NKM_GShaderDecodedNormal4TapRT then
            NKM.GShaderNKMBufferDebug4TapError = tostring(target or "4-tap decoded normal RT creation failed")
        end
    end

    if not NKM_GShaderNormal4TapMaterial then
        local materialOK, material = pcall(CreateMaterial, "nkm_gshader_normal_reconstruction_4tap_debug",
            "screenspace_general", {
                ["$pixshader"] = "wpn_reconstruction_4tap_ps30",
                ["$vertexshader"] = "reconstruction_vs30",
                ["$basetexture"] = "_rt_NKM_RawDepth",
                ["$texture1"] = "_rt_FullFrameFB",
                ["$texture2"] = "_rt_NKM_WPDepth",
                ["$no_fullbright"] = "1",
                ["$vertexcolor"] = "1",
                ["$ignorez"] = "1",
                ["$VERTEXTRANSFORM"] = "1",
                ["$LINEARREAD_BASETEXTURE"] = "1",
                ["$LINEARREAD_TEXTURE1"] = "1",
                ["$WRITEALPHA"] = "1",
                ["$copyalpha"] = "1",
                ["$vertexalpha"] = "1",
                ["$c0_w"] = "1",
                ["$c1_w"] = "0"
            })
        if not materialOK or not material then
            NKM_GShaderNormal4TapMaterial = nil
            NKM.GShaderNKMBufferDebug4TapError = tostring(material or "4-tap normal material failed")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderNormal4TapMaterial = nil
                NKM.GShaderNKMBufferDebug4TapError = "GShader 4-tap normal shader is unavailable"
            else
                NKM_GShaderNormal4TapMaterial = material
            end
        end
    end

    if not NKM_GShaderNormal4TapDecodeMaterial then
        local materialOK, material = pcall(CreateMaterial, "nkm_gshader_normal_decode_4tap_debug",
            "screenspace_general", {
                ["$pixshader"] = "wn_tangetns_decode_ps30",
                ["$vertexshader"] = "pp_vs30",
                ["$basetexture"] = "_rt_NKM_Normals4Tap",
                ["$no_fullbright"] = "1",
                ["$ignorez"] = "1",
                ["$VERTEXTRANSFORM"] = "1",
                ["$WRITEALPHA"] = "1",
                ["$copyalpha"] = "1",
                ["$vertexalpha"] = "1"
            })
        if not materialOK or not material then
            NKM_GShaderNormal4TapDecodeMaterial = nil
            NKM.GShaderNKMBufferDebug4TapError = tostring(material or "4-tap normal decode material failed")
        else
            local errorOK, isError = pcall(material.IsError, material)
            if not errorOK or isError then
                NKM_GShaderNormal4TapDecodeMaterial = nil
                NKM.GShaderNKMBufferDebug4TapError = "GShader 4-tap normal decode shader is unavailable"
            else
                NKM_GShaderNormal4TapDecodeMaterial = material
            end
        end
    end

    if NKM_GShaderDecodedWorldPosRT and NKM_GShaderWorldPosDebugMaterial then
        NKM.GShaderNKMBufferDebugWorldPosError = nil
    elseif not NKM.GShaderNKMBufferDebugWorldPosError then
        NKM.GShaderNKMBufferDebugWorldPosError =
            "world-position debug resources are incomplete"
    end

    if NKM_GShaderWorldPosSampler2RT and NKM_GShaderWorldPosSampler2Material then
        NKM.GShaderNKMBufferDebugSampler2Error = nil
    elseif not NKM.GShaderNKMBufferDebugSampler2Error then
        NKM.GShaderNKMBufferDebugSampler2Error =
            "world-position sampler2 debug resources are incomplete"
    end

    if NKM_GShaderWorldPosNormal4TapRT and NKM_GShaderWorldPosNormal4TapMaterial then
        NKM.GShaderNKMBufferDebugNormal4TapError = nil
    elseif not NKM.GShaderNKMBufferDebugNormal4TapError then
        NKM.GShaderNKMBufferDebugNormal4TapError =
            "4-tap world-normal debug resources are incomplete"
    end

    if NKM_GShaderPointLightDebugRT and NKM_GShaderPointLightDebugMaterial then
        NKM.GShaderNKMBufferDebugPointLightError = nil
    elseif not NKM.GShaderNKMBufferDebugPointLightError then
        NKM.GShaderNKMBufferDebugPointLightError =
            "point-light debug resources are incomplete"
    end

    local vertexNormalDebugReady = NKM_GShaderVertexNormalRT ~= nil
        and NKM_GShaderDecodedVertexNormalRT ~= nil
        and NKM_GShaderVertexNormalDecodeMaterial ~= nil
    if vertexNormalDebugReady then
        NKM.GShaderNKMBufferDebugVertexError = nil
    elseif not NKM.GShaderNKMBufferDebugVertexError then
        NKM.GShaderNKMBufferDebugVertexError = "vertex normal debug resources are incomplete"
    end

    local fourTapReady = NKM_GShaderNormal4TapRT ~= nil
        and NKM_GShaderDecodedNormal4TapRT ~= nil
        and NKM_GShaderNormal4TapMaterial ~= nil
        and NKM_GShaderNormal4TapDecodeMaterial ~= nil
    if fourTapReady then
        NKM.GShaderNKMBufferDebug4TapError = nil
    elseif not NKM.GShaderNKMBufferDebug4TapError then
        NKM.GShaderNKMBufferDebug4TapError = "4-tap debug resources are incomplete"
    end

    return NKM_GShaderDecodedNormalRT ~= nil and NKM_GShaderNormalDecodeMaterial ~= nil
end

local function ensureNKMGShaderBufferResources()
    local width, height = ScrW(), ScrH()
    local ready = NKM_GShaderRawDepthRT and NKM_GShaderWorldPosRT and NKM_GShaderNormalRT
        and NKM_GShaderRawDepthRT:Width() == width and NKM_GShaderRawDepthRT:Height() == height
        and NKM_GShaderWorldPosRT:Width() == width and NKM_GShaderWorldPosRT:Height() == height
        and NKM_GShaderNormalRT:Width() == width and NKM_GShaderNormalRT:Height() == height
    local coreMaterialsReady = NKM_GShaderWorldPosMaterial and NKM_GShaderNormalMaterial
    local flags = bit.bor(1, 4, 8, 256, 512, 32768, 8388608)
    if ready and coreMaterialsReady then
        ensureNKMNormalDecodeDebugResources(width, height, flags)
        return true
    end

    local okRaw, rawDepth = pcall(GetRenderTargetEx,
        "_rt_NKM_RawDepth", width, height, RT_SIZE_FULL_FRAME_BUFFER,
        MATERIAL_RT_DEPTH_SEPARATE, flags, 0, IMAGE_FORMAT_RGBA32323232F)
    local okWorld, worldPos = pcall(GetRenderTargetEx,
        "_rt_NKM_WPDepth", width, height, RT_SIZE_FULL_FRAME_BUFFER,
        MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA32323232F)
    local normalFormat = IMAGE_FORMAT_RGB888
    if isfunction(shaderlib.GetWorldNormalsImageFormat) then
        local formatOK, format = pcall(shaderlib.GetWorldNormalsImageFormat)
        if formatOK and format then normalFormat = format end
    end
    local okNormal, normals = pcall(GetRenderTargetEx,
        "_rt_NKM_Normals", width, height, RT_SIZE_FULL_FRAME_BUFFER,
        MATERIAL_RT_DEPTH_NONE, flags, 0, normalFormat)
    if not okRaw or not rawDepth or not okWorld or not worldPos or not okNormal or not normals then
        NKM.GShaderNKMBufferLastError = tostring(rawDepth or worldPos or normals or "GetRenderTargetEx failed")
        return false
    end

    NKM_GShaderRawDepthRT = rawDepth
    NKM_GShaderWorldPosRT = worldPos
    NKM_GShaderNormalRT = normals

    if not NKM_GShaderWorldPosMaterial then
        local materialOK, material = pcall(CreateMaterial, "nkm_gshader_worldpos_reconstruction",
            "screenspace_general", {
                ["$pixshader"] = "wp_reconstruction_ps30",
                ["$vertexshader"] = "pp_vs30",
                ["$basetexture"] = "_rt_NKM_RawDepth",
                ["$texture1"] = "_rt_ResolvedFullFrameDepthSky",
                ["$no_fullbright"] = "1",
                ["$ignorez"] = "1",
                ["$VERTEXTRANSFORM"] = "1",
                ["$LINEARREAD_BASETEXTURE"] = "1",
                ["$WRITEALPHA"] = "1",
                ["$copyalpha"] = "1",
                ["$vertexalpha"] = "1",
                ["$linearwrite"] = "1"
            })
        if not materialOK or not material then
            NKM.GShaderNKMBufferLastError = tostring(material or "world position reconstruction material failed")
            return false
        end
        local errorOK, isError = pcall(material.IsError, material)
        if not errorOK or isError then
            NKM.GShaderNKMBufferLastError = "GShader world-position reconstruction shader is unavailable"
            return false
        end
        NKM_GShaderWorldPosMaterial = material
    end

    if not NKM_GShaderNormalMaterial then
        local materialOK, material = pcall(CreateMaterial, "nkm_gshader_normal_reconstruction",
            "screenspace_general", {
                ["$pixshader"] = "nkm_wpn_reconstruction_ps30",
                ["$vertexshader"] = "reconstruction_vs30",
                ["$basetexture"] = "_rt_NKM_RawDepth",
                ["$texture1"] = "_rt_FullFrameFB",
                ["$texture2"] = "_rt_NKM_WPDepth",
                ["$no_fullbright"] = "1",
                ["$vertexcolor"] = "1",
                ["$ignorez"] = "1",
                ["$VERTEXTRANSFORM"] = "1",
                ["$LINEARREAD_BASETEXTURE"] = "1",
                ["$LINEARREAD_TEXTURE1"] = "1",
                ["$WRITEALPHA"] = "1",
                ["$copyalpha"] = "1",
                ["$vertexalpha"] = "1",
                ["$c0_w"] = "1",
                ["$c1_w"] = "0"
            })
        if not materialOK or not material then
            NKM.GShaderNKMBufferLastError = tostring(material or "normal reconstruction material failed")
            return false
        end
        local errorOK, isError = pcall(material.IsError, material)
        if not errorOK or isError then
            NKM.GShaderNKMBufferLastError = "GShader normal reconstruction shader is unavailable"
            return false
        end
        NKM_GShaderNormalMaterial = material
    end

    ensureNKMNormalDecodeDebugResources(width, height, flags)
    return true
end

-- Match GShader's world-position reconstruction matrix exactly: position is
-- supplied separately through EyePos(), so the view matrix contains rotation only.
local function getNKMReconstructionViewProjection(viewSetup)
    local forward = -viewSetup.angles:Forward()
    local right = viewSetup.angles:Right()
    local up = -viewSetup.angles:Up()
    local viewRotation = Matrix({
        { right.x, right.y, right.z, 0 },
        { up.x, up.y, up.z, 0 },
        { forward.x, forward.y, forward.z, 0 },
        { 0, 0, 0, 1 }
    })
    local projection = shaderlib.GetProjMatrix(viewSetup)
    projection:Mul(viewRotation)
    return projection
end

local function drawNKMRawDepth(viewSetup)
    local pushedTarget = false
    local cameraStarted = false
    local drawnMeshes = 0
    local width, height = ScrW(), ScrH()
    local ok, err = pcall(function()
        render.PushRenderTarget(NKM_GShaderRawDepthRT)
        pushedTarget = true
        -- White is Source's far/sky depth value. The target has its own Z buffer.
        render.Clear(255, 255, 255, 255, true, true)

        cam.Start3D(viewSetup.origin, viewSetup.angles, viewSetup.fov,
            0, 0, width, height, viewSetup.znear or 1, viewSetup.zfar or 32768)
        cameraStarted = true
        render.CullMode(NKM.CullModeSetting == 1 and MATERIAL_CULLMODE_CW or MATERIAL_CULLMODE_CCW)
        render.OverrideDepthEnable(true, true)
        render.SetBlend(1)

        for _, entry in ipairs(NKM.RenderMeshes or {}) do
            local isBSPDisplacement = entry.isBSPDisplacement == true
            local shouldDraw = not (isBSPDisplacement and NKM.ClientBSPDisplacementRenderEnabled == false)
            if shouldDraw and entry.mesh and entry.mesh:IsValid() then
                render.SetMaterial(GSHADER_DEPTH_MATERIAL)
                entry.mesh:Draw()
                drawnMeshes = drawnMeshes + 1
            end
        end

        render.OverrideDepthEnable(false, false)
        render.CullMode(MATERIAL_CULLMODE_CCW)
        cam.End3D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End3D) end
    render.OverrideDepthEnable(false, false)
    render.CullMode(MATERIAL_CULLMODE_CCW)
    render.SetColorModulation(1, 1, 1)
    render.SetBlend(1)
    if pushedTarget then pcall(render.PopRenderTarget) end

    if not ok then return false, tostring(err), drawnMeshes end
    return true, nil, drawnMeshes
end

local function setNKMShaderTexelSize(material, sourceTexture)
    if not material or not sourceTexture then return end

    local width = math.max(sourceTexture:Width(), 1)
    local height = math.max(sourceTexture:Height(), 1)
    material:SetFloat("$c4_x", 1 / width)
    material:SetFloat("$c4_y", 1 / height)
end

local function drawNKMReconstruction(material, target, worldProjection, eyePosition, rawDepth, worldPos, frameBuffer)
    local pushedTarget = false
    local cameraStarted = false
    local ok, err = pcall(function()
        -- VPOS-based GShader pixel shaders use c4 as the inverse source-texture
        -- dimensions. Set it explicitly for NKM's dynamically created materials.
        setNKMShaderTexelSize(material, rawDepth or target)
        material:SetMatrix("$INVVIEWPROJMAT", worldProjection:GetInverse())
        if eyePosition then
            material:SetFloat("$c0_x", eyePosition.x)
            material:SetFloat("$c0_y", eyePosition.y)
            material:SetFloat("$c0_z", eyePosition.z)
        end

        if rawDepth then material:SetTexture("$basetexture", rawDepth) end
        if worldPos then material:SetTexture("$texture2", worldPos) end
        if frameBuffer then material:SetTexture("$texture1", frameBuffer) end

        render.PushRenderTarget(target)
        pushedTarget = true
        render.Clear(0, 0, 0, 0, false, false)
        cam.Start2D()
        cameraStarted = true
        render.SetMaterial(material)
        render.DrawScreenQuad()
        cam.End2D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End2D) end
    if pushedTarget then pcall(render.PopRenderTarget) end
    if not ok then return false, tostring(err) end
    return true
end

local function drawNKMVertexNormalBuffer(viewSetup)
    if not NKM_GShaderVertexNormalRT then
        return false, "vertex normal RT is unavailable", 0
    end

    local pushedTarget = false
    local cameraStarted = false
    local drawnMeshes = 0
    local width, height = ScrW(), ScrH()
    local ok, err = pcall(function()
        render.PushRenderTarget(NKM_GShaderVertexNormalRT)
        pushedTarget = true
        render.Clear(128, 128, 255, 0, true, true)

        cam.Start3D(viewSetup.origin, viewSetup.angles, viewSetup.fov,
            0, 0, width, height, viewSetup.znear or 1, viewSetup.zfar or 32768)
        cameraStarted = true
        render.CullMode(NKM.CullModeSetting == 1 and MATERIAL_CULLMODE_CW or MATERIAL_CULLMODE_CCW)
        render.OverrideDepthEnable(true, true)
        render.SetBlend(1)
        render.SetColorModulation(1, 1, 1)
        render.SetMaterial(GSHADER_NKM_VERTEX_NORMAL_MATERIAL)

        for _, entry in ipairs(NKM.RenderMeshes or {}) do
            if entry.normalDebugMesh and entry.normalDebugMesh:IsValid() then
                entry.normalDebugMesh:Draw()
                drawnMeshes = drawnMeshes + 1
            end
        end

        render.OverrideDepthEnable(false, false)
        render.CullMode(MATERIAL_CULLMODE_CCW)
        cam.End3D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End3D) end
    render.OverrideDepthEnable(false, false)
    render.CullMode(MATERIAL_CULLMODE_CCW)
    render.SetColorModulation(1, 1, 1)
    render.SetBlend(1)
    if pushedTarget then pcall(render.PopRenderTarget) end

    if not ok then return false, tostring(err), drawnMeshes end
    return true, nil, drawnMeshes
end

local function drawNKMDecodedVertexNormals()
    if not NKM_GShaderVertexNormalDecodeMaterial or not NKM_GShaderDecodedVertexNormalRT
        or not NKM_GShaderVertexNormalRT then
        return false, "vertex normal decode resources are unavailable"
    end

    local pushedTarget = false
    local cameraStarted = false
    local ok, err = pcall(function()
        setNKMShaderTexelSize(NKM_GShaderVertexNormalDecodeMaterial, NKM_GShaderVertexNormalRT)
        NKM_GShaderVertexNormalDecodeMaterial:SetTexture("$basetexture", NKM_GShaderVertexNormalRT)
        render.PushRenderTarget(NKM_GShaderDecodedVertexNormalRT)
        pushedTarget = true
        render.Clear(0, 0, 0, 0, false, false)
        cam.Start2D()
        cameraStarted = true
        render.SetMaterial(NKM_GShaderVertexNormalDecodeMaterial)
        render.DrawScreenQuad()
        cam.End2D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End2D) end
    if pushedTarget then pcall(render.PopRenderTarget) end
    if not ok then return false, tostring(err) end
    return true
end

local function drawNKMDecodedWorldPositionDebug()
    if not NKM_GShaderWorldPosDebugMaterial or not NKM_GShaderDecodedWorldPosRT
        or not NKM_GShaderWorldPosRT then
        return false, "decoded world-position debug resources are unavailable"
    end

    local pushedTarget = false
    local cameraStarted = false
    local ok, err = pcall(function()
        -- The debug pixel shader samples by VPOS, so c4 must contain the
        -- inverse dimensions of the source world-position texture.
        local sourceWidth = math.max(NKM_GShaderWorldPosRT:Width(), 1)
        local sourceHeight = math.max(NKM_GShaderWorldPosRT:Height(), 1)
        NKM_GShaderWorldPosDebugMaterial:SetFloat("$c4_x", 1 / sourceWidth)
        NKM_GShaderWorldPosDebugMaterial:SetFloat("$c4_y", 1 / sourceHeight)
        NKM_GShaderWorldPosDebugMaterial:SetTexture("$basetexture", NKM_GShaderWorldPosRT)
        render.PushRenderTarget(NKM_GShaderDecodedWorldPosRT)
        pushedTarget = true
        render.Clear(0, 0, 0, 0, false, false)
        cam.Start2D()
        cameraStarted = true
        render.SetMaterial(NKM_GShaderWorldPosDebugMaterial)
        render.DrawScreenQuad()
        cam.End2D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End2D) end
    if pushedTarget then pcall(render.PopRenderTarget) end
    if not ok then return false, tostring(err) end
    return true
end

local function drawNKMWorldPosSampler2Debug()
    if not NKM_GShaderWorldPosSampler2Material or not NKM_GShaderWorldPosSampler2RT
        or not NKM_GShaderWorldPosRT then
        return false, "world-position sampler2 debug resources are unavailable"
    end

    local pushedTarget = false
    local cameraStarted = false
    local ok, err = pcall(function()
        setNKMShaderTexelSize(NKM_GShaderWorldPosSampler2Material, NKM_GShaderWorldPosRT)
        NKM_GShaderWorldPosSampler2Material:SetTexture("$texture2", NKM_GShaderWorldPosRT)
        render.PushRenderTarget(NKM_GShaderWorldPosSampler2RT)
        pushedTarget = true
        render.Clear(0, 0, 0, 0, false, false)
        cam.Start2D()
        cameraStarted = true
        render.SetMaterial(NKM_GShaderWorldPosSampler2Material)
        render.DrawScreenQuad()
        cam.End2D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End2D) end
    if pushedTarget then pcall(render.PopRenderTarget) end
    if not ok then return false, tostring(err) end
    return true
end

local function drawNKMPointLightContributionDebug()
    if not NKM_GShaderPointLightDebugMaterial or not NKM_GShaderPointLightDebugRT
        or not NKM_GShaderWorldPosRT or not NKM_GShaderNormalRT then
        return false, "point-light debug resources are unavailable"
    end
    if not updateGShaderDynamicLightLUT() or not NKM.GShaderDynamicLightLUT then
        return false, NKM.GShaderLUTLastError or "dynamic-light LUT is unavailable"
    end

    local pushedTarget = false
    local cameraStarted = false
    local ok, err = pcall(function()
        NKM_GShaderPointLightDebugMaterial:SetTexture("$basetexture", NKM_GShaderWorldPosRT)
        NKM_GShaderPointLightDebugMaterial:SetTexture("$texture1", NKM_GShaderNormalRT)
        NKM_GShaderPointLightDebugMaterial:SetTexture("$texture2", NKM.GShaderDynamicLightLUT)
        NKM_GShaderPointLightDebugMaterial:SetFloat("$c0_x", #((NKM.ClientDynamicLights) or {}))
        render.PushRenderTarget(NKM_GShaderPointLightDebugRT)
        pushedTarget = true
        render.Clear(0, 0, 0, 0, false, false)
        cam.Start2D()
        cameraStarted = true
        render.SetMaterial(NKM_GShaderPointLightDebugMaterial)
        render.DrawScreenQuad()
        cam.End2D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End2D) end
    if pushedTarget then pcall(render.PopRenderTarget) end
    if not ok then return false, tostring(err) end
    return true
end

local function drawNKMWorldPosNormal4TapDebug()
    if not NKM_GShaderWorldPosNormal4TapMaterial or not NKM_GShaderWorldPosNormal4TapRT
        or not NKM_GShaderWorldPosRT then
        return false, "4-tap world-normal debug resources are unavailable"
    end

    local pushedTarget = false
    local cameraStarted = false
    local ok, err = pcall(function()
        setNKMShaderTexelSize(NKM_GShaderWorldPosNormal4TapMaterial, NKM_GShaderWorldPosRT)
        NKM_GShaderWorldPosNormal4TapMaterial:SetTexture("$texture2", NKM_GShaderWorldPosRT)
        render.PushRenderTarget(NKM_GShaderWorldPosNormal4TapRT)
        pushedTarget = true
        render.Clear(0, 0, 0, 0, false, false)
        cam.Start2D()
        cameraStarted = true
        render.SetMaterial(NKM_GShaderWorldPosNormal4TapMaterial)
        render.DrawScreenQuad()
        cam.End2D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End2D) end
    if pushedTarget then pcall(render.PopRenderTarget) end
    if not ok then return false, tostring(err) end
    return true
end

local function drawNKMDecodedNormalDebug()
    if not NKM_GShaderNormalDecodeMaterial or not NKM_GShaderDecodedNormalRT or not NKM_GShaderNormalRT then
        return false, "normal decode debug resources are unavailable"
    end

    local pushedTarget = false
    local cameraStarted = false
    local ok, err = pcall(function()
        setNKMShaderTexelSize(NKM_GShaderNormalDecodeMaterial, NKM_GShaderNormalRT)
        NKM_GShaderNormalDecodeMaterial:SetTexture("$basetexture", NKM_GShaderNormalRT)
        render.PushRenderTarget(NKM_GShaderDecodedNormalRT)
        pushedTarget = true
        render.Clear(0, 0, 0, 0, false, false)
        cam.Start2D()
        cameraStarted = true
        render.SetMaterial(NKM_GShaderNormalDecodeMaterial)
        render.DrawScreenQuad()
        cam.End2D()
        cameraStarted = false
    end)

    if cameraStarted then pcall(cam.End2D) end
    if pushedTarget then pcall(render.PopRenderTarget) end
    if not ok then return false, tostring(err) end
    return true
end

local function buildNKMReconstructionBuffers(viewSetup)
    NKM.GShaderNKMBufferReady = false
    if not NKM.GShaderBridgeEnabled or not hasGShaderAPI() or not viewSetup then return false end
    if not shouldRunGShaderLighting() then return false end
    if not ensureNKMGShaderBufferResources() then return false end

    local rawOK, rawError, drawnMeshes = drawNKMRawDepth(viewSetup)
    if not rawOK then
        NKM.GShaderNKMBufferLastError = "NKM-only depth render failed: " .. tostring(rawError)
        return false
    end

    if NKM.GShaderNKMBufferDebug then
        local vertexOK, vertexError, vertexMeshes = drawNKMVertexNormalBuffer(viewSetup)
        NKM.GShaderNKMBufferDebugVertexMeshes = vertexMeshes or 0
        if not vertexOK then
            NKM.GShaderNKMBufferDebugVertexError = tostring(vertexError)
        else
            local decodeOK, decodeError = drawNKMDecodedVertexNormals()
            NKM.GShaderNKMBufferDebugVertexError = decodeOK and nil or tostring(decodeError)
        end
    end

    local projectionOK, worldProjection = pcall(getNKMReconstructionViewProjection, viewSetup)
    if not projectionOK or not worldProjection then
        NKM.GShaderNKMBufferLastError = "NKM view-projection build failed: " .. tostring(worldProjection)
        return false
    end

    local eyePosition = EyePos()
    local worldOK, worldError = drawNKMReconstruction(
        NKM_GShaderWorldPosMaterial, NKM_GShaderWorldPosRT,
        worldProjection, eyePosition, NKM_GShaderRawDepthRT, nil)
    if not worldOK then
        NKM.GShaderNKMBufferLastError = "NKM world-position reconstruction failed: " .. tostring(worldError)
        return false
    end

    if NKM.GShaderNKMBufferDebug then
        local positionDebugOK, positionDebugError = drawNKMDecodedWorldPositionDebug()
        if positionDebugOK then
            NKM.GShaderNKMBufferDebugWorldPosError = nil
        else
            NKM.GShaderNKMBufferDebugWorldPosError = tostring(positionDebugError)
        end

        local sampler2OK, sampler2Error = drawNKMWorldPosSampler2Debug()
        if sampler2OK then
            NKM.GShaderNKMBufferDebugSampler2Error = nil
        else
            NKM.GShaderNKMBufferDebugSampler2Error = tostring(sampler2Error)
        end

        local worldNormalOK, worldNormalError = drawNKMWorldPosNormal4TapDebug()
        if worldNormalOK then
            NKM.GShaderNKMBufferDebugNormal4TapError = nil
        else
            NKM.GShaderNKMBufferDebugNormal4TapError = tostring(worldNormalError)
        end
    end

    local frameBuffer = render.GetScreenEffectTexture()
    local normalOK, normalError = drawNKMReconstruction(
        NKM_GShaderNormalMaterial, NKM_GShaderNormalRT,
        worldProjection, nil, NKM_GShaderRawDepthRT, NKM_GShaderWorldPosRT, frameBuffer)
    if not normalOK then
        NKM.GShaderNKMBufferLastError = "NKM normal reconstruction failed: " .. tostring(normalError)
        return false
    end

    if NKM.GShaderNKMBufferDebug then
        local pointDebugOK, pointDebugError = drawNKMPointLightContributionDebug()
        if pointDebugOK then
            NKM.GShaderNKMBufferDebugPointLightError = nil
        else
            NKM.GShaderNKMBufferDebugPointLightError = tostring(pointDebugError)
        end
    end

    -- Decode the improved buffer for inspection and build a second normal map
    -- with GShader's simpler 4-tap algorithm. Comparing both isolates errors in
    -- the improved neighbour-selection logic from errors in NKM world positions.
    if NKM.GShaderNKMBufferDebug then
        local debugOK, debugError = drawNKMDecodedNormalDebug()
        NKM.GShaderNKMBufferDebugLastError = debugOK and nil or tostring(debugError)

        if NKM_GShaderNormal4TapRT and NKM_GShaderNormal4TapMaterial
            and NKM_GShaderDecodedNormal4TapRT and NKM_GShaderNormal4TapDecodeMaterial then
            local fourTapOK, fourTapError = drawNKMReconstruction(
                NKM_GShaderNormal4TapMaterial, NKM_GShaderNormal4TapRT,
                worldProjection, nil, NKM_GShaderRawDepthRT,
                NKM_GShaderWorldPosRT, frameBuffer)
            if fourTapOK then
                local pushedTarget, cameraStarted = false, false
                local decodeOK, decodeError = pcall(function()
                    setNKMShaderTexelSize(NKM_GShaderNormal4TapDecodeMaterial, NKM_GShaderNormal4TapRT)
                    NKM_GShaderNormal4TapDecodeMaterial:SetTexture("$basetexture", NKM_GShaderNormal4TapRT)
                    render.PushRenderTarget(NKM_GShaderDecodedNormal4TapRT)
                    pushedTarget = true
                    render.Clear(0, 0, 0, 0, false, false)
                    cam.Start2D()
                    cameraStarted = true
                    render.SetMaterial(NKM_GShaderNormal4TapDecodeMaterial)
                    render.DrawScreenQuad()
                    cam.End2D()
                    cameraStarted = false
                end)
                if cameraStarted then pcall(cam.End2D) end
                if pushedTarget then pcall(render.PopRenderTarget) end
                if decodeOK then
                    NKM.GShaderNKMBufferDebug4TapError = nil
                else
                    NKM.GShaderNKMBufferDebug4TapError = "4-tap decode failed: " .. tostring(decodeError)
                end
            else
                NKM.GShaderNKMBufferDebug4TapError = "4-tap reconstruction failed: " .. tostring(fourTapError)
            end
        elseif not NKM.GShaderNKMBufferDebug4TapError then
            NKM.GShaderNKMBufferDebug4TapError = "4-tap debug resources are missing"
        end
    else
        NKM.GShaderNKMBufferDebugLastError = nil
    end

    NKM.GShaderNKMBufferBuildCount = (NKM.GShaderNKMBufferBuildCount or 0) + 1
    NKM.GShaderNKMBufferLastMeshes = drawnMeshes
    NKM.GShaderNKMBufferLastAt = RealTime()
    NKM.GShaderNKMBufferReady = true
    NKM.GShaderNKMBufferLastError = nil
    return true
end

hook.Add("PostDrawReconstructionPreEffects", "NKM.GShaderNKMBuffer", buildNKMReconstructionBuffers)

hook.Add("HUDPaint", "NKM.GShaderNKMBufferDebug", function()
    if not NKM.GShaderNKMBufferDebug then return end
    if not NKM_GShaderRawDepthRT or not NKM_GShaderWorldPosRT or not NKM_GShaderNormalRT then return end

    local width = math.floor((ScrW() - 96) / 10)
    local height = math.floor(width * ScrH() / math.max(ScrW(), 1))
    local y = ScrH() - height - 34
    local gap = 8
    local x1 = 8
    local x2 = x1 + width + gap
    local x3 = x2 + width + gap

    render.DrawTextureToScreenRect(NKM_GShaderRawDepthRT, x1, y, width, height)
    render.DrawTextureToScreenRect(NKM_GShaderWorldPosRT, x2, y, width, height)
    render.DrawTextureToScreenRect(NKM_GShaderNormalRT, x3, y, width, height)
    local x4 = x3 + width + gap
    local x5 = x4 + width + gap
    local x6 = x5 + width + gap
    local x7 = x6 + width + gap
    local x8 = x7 + width + gap
    local x9 = x8 + width + gap
    local x10 = x9 + width + gap
    if NKM_GShaderDecodedNormalRT then
        render.DrawTextureToScreenRect(NKM_GShaderDecodedNormalRT, x4, y, width, height)
    end
    if NKM_GShaderDecodedNormal4TapRT then
        render.DrawTextureToScreenRect(NKM_GShaderDecodedNormal4TapRT, x5, y, width, height)
    end
    if NKM_GShaderDecodedVertexNormalRT then
        render.DrawTextureToScreenRect(NKM_GShaderDecodedVertexNormalRT, x6, y, width, height)
    end
    if NKM_GShaderDecodedWorldPosRT then
        render.DrawTextureToScreenRect(NKM_GShaderDecodedWorldPosRT, x7, y, width, height)
    end
    if NKM_GShaderWorldPosSampler2RT then
        render.DrawTextureToScreenRect(NKM_GShaderWorldPosSampler2RT, x8, y, width, height)
    end
    if NKM_GShaderWorldPosNormal4TapRT then
        render.DrawTextureToScreenRect(NKM_GShaderWorldPosNormal4TapRT, x9, y, width, height)
    end
    if NKM_GShaderPointLightDebugRT then
        render.DrawTextureToScreenRect(NKM_GShaderPointLightDebugRT, x10, y, width, height)
    end
    draw.SimpleText("NKM raw depth", "DermaDefault", x1, y + height + 4, color_white)
    draw.SimpleText("NKM world position", "DermaDefault", x2, y + height + 4, color_white)
    draw.SimpleText("NKM normals (packed)", "DermaDefault", x3, y + height + 4, color_white)
    if NKM_GShaderDecodedNormalRT then
        draw.SimpleText("NKM normals (UV derivatives)", "DermaDefault", x4, y + height + 4, color_white)
    end
    if NKM_GShaderDecodedNormal4TapRT then
        draw.SimpleText("Stock GShader 4-tap", "DermaDefault", x5, y + height + 4, color_white)
    end
    if NKM_GShaderDecodedVertexNormalRT then
        draw.SimpleText("Normals from mesh", "DermaDefault", x6, y + height + 4, color_white)
    end
    if NKM_GShaderDecodedWorldPosRT then
        draw.SimpleText("NKM WP decoded XYZ", "DermaDefault", x7, y + height + 4, color_white)
    end
    if NKM_GShaderWorldPosSampler2RT then
        draw.SimpleText("NKM WP sampler s2", "DermaDefault", x8, y + height + 4, color_white)
    end
    if NKM_GShaderWorldPosNormal4TapRT then
        draw.SimpleText("NKM WP 4-tap normal XYZ", "DermaDefault", x9, y + height + 4, color_white)
    end
    if NKM_GShaderPointLightDebugRT then
        draw.SimpleText("NKM point-light contribution", "DermaDefault", x10, y + height + 4, color_white)
    end
    if NKM.GShaderNKMBufferDebugLastError then
        draw.SimpleText("Improved decode debug: " .. tostring(NKM.GShaderNKMBufferDebugLastError),
            "DermaDefault", 8, y - 36, Color(255, 100, 100))
    end
    if NKM.GShaderNKMBufferDebug4TapError then
        draw.SimpleText("4-tap debug: " .. tostring(NKM.GShaderNKMBufferDebug4TapError),
            "DermaDefault", 8, y - 18, Color(255, 100, 100))
    end
    if NKM.GShaderNKMBufferDebugVertexError then
        draw.SimpleText("Mesh normal debug: " .. tostring(NKM.GShaderNKMBufferDebugVertexError),
            "DermaDefault", 8, y - 54, Color(255, 100, 100))
    end
    if NKM.GShaderNKMBufferDebugWorldPosError then
        draw.SimpleText("World-position debug: " .. tostring(NKM.GShaderNKMBufferDebugWorldPosError),
            "DermaDefault", 8, y - 72, Color(255, 100, 100))
    end
    if NKM.GShaderNKMBufferDebugSampler2Error then
        draw.SimpleText("WP sampler2 debug: " .. tostring(NKM.GShaderNKMBufferDebugSampler2Error),
            "DermaDefault", 8, y - 90, Color(255, 100, 100))
    end
    if NKM.GShaderNKMBufferDebugNormal4TapError then
        draw.SimpleText("WP 4-tap normal debug: " .. tostring(NKM.GShaderNKMBufferDebugNormal4TapError),
            "DermaDefault", 8, y - 108, Color(255, 100, 100))
    end
    if NKM.GShaderNKMBufferDebugPointLightError then
        draw.SimpleText("Point-light debug: " .. tostring(NKM.GShaderNKMBufferDebugPointLightError),
            "DermaDefault", 8, y - 126, Color(255, 100, 100))
    end
end)

local function drawNKMSceneLighting(viewSetup)
    if not NKM.GShaderBridgeEnabled or not hasGShaderAPI() then return false end
    if not updateGShaderDynamicLightLUT() then return false end

    local material = getNKMDeferredMaterial()
    if not material then return false end

    local okMatrix, viewProjection = pcall(shaderlib.GetViewProjMatrix, viewSetup)
    if not okMatrix or not viewProjection then
        NKM.GShaderLastError = "GShader.GetViewProjMatrix failed"
        return false
    end

    local lighting = NKM.ClientLighting or {}
    local deferred = lighting.deferred or {}
    local pointLights = NKM.ClientDynamicLights or {}
    local usePixelStatic = NKM.GShaderPixelLighting == true
    local ambient = usePixelStatic and (lighting.ambient or { 32, 32, 32 }) or { 0, 0, 0 }
    local directional = usePixelStatic and (lighting.directional or {}) or {}

    local ok, err = pcall(function()
        if not NKM.GShaderNKMBufferReady or not NKM_GShaderWorldPosRT or not NKM_GShaderNormalRT then
            error("NKM reconstructed buffers are not ready for this frame")
        end

        -- Refresh the scene copy before binding s3. screenspace_general only
        -- exposes BASETEXTURE and TEXTURE1..TEXTURE3 (samplers s0..s3).
        render.UpdateScreenEffectTexture()
        local sceneTexture = render.GetScreenEffectTexture()
        if not sceneTexture then error("GMod screen-effect texture is unavailable") end

        local setters = {
            { material.SetTexture, "$basetexture", NKM_GShaderWorldPosRT },
            { material.SetTexture, "$texture1", NKM_GShaderNormalRT },
            { material.SetTexture, "$texture2", NKM.GShaderDynamicLightLUT },
            { material.SetTexture, "$texture3", sceneTexture },
            { material.SetMatrix, "$viewprojmat", viewProjection },
            { material.SetFloat, "$c0_x", #pointLights },
            { material.SetFloat, "$c0_y", deferred.aoRadius or 72 },
            { material.SetFloat, "$c0_z",
                deferred.ao ~= false and NKM_GShaderAOConVar:GetBool()
                    and (deferred.aoStrength or 0.35) or 0 },
            { material.SetFloat, "$c0_w",
                lighting.shadows ~= false and deferred.contactShadows ~= false
                    and NKM_GShaderContactShadowsConVar:GetBool() and 1 or 0 },
            { material.SetFloat, "$c1_x", ScrW() },
            { material.SetFloat, "$c1_y", ScrH() },
            { material.SetFloat, "$c2_x", (ambient[1] or 0) / 255 },
            { material.SetFloat, "$c2_y", (ambient[2] or 0) / 255 },
            { material.SetFloat, "$c2_z", (ambient[3] or 0) / 255 },
            { material.SetFloat, "$c2_w", usePixelStatic and 1 or 0 }
        }

        -- c3/c4, c5/c6, c7/c8, c9/c10: direction+intensity and color+shadow flag.
        for index = 1, 4 do
            local light = directional[index]
            local register = 3 + (index - 1) * 2
            local direction = light and light.direction or { 0, 0, 0 }
            local color = light and light.color or { 0, 0, 0 }
            local intensity = light and (light.intensity or 1) or 0
            local castsShadows = light and lighting.shadows ~= false
                and NKM_GShaderContactShadowsConVar:GetBool() and light.shadows ~= false and 1 or 0
            setters[#setters + 1] = { material.SetFloat, "$c" .. register .. "_x", direction[1] or 0 }
            setters[#setters + 1] = { material.SetFloat, "$c" .. register .. "_y", direction[2] or 0 }
            setters[#setters + 1] = { material.SetFloat, "$c" .. register .. "_z", direction[3] or 0 }
            setters[#setters + 1] = { material.SetFloat, "$c" .. register .. "_w", intensity }
            setters[#setters + 1] = { material.SetFloat, "$c" .. (register + 1) .. "_x", (color[1] or 0) / 255 }
            setters[#setters + 1] = { material.SetFloat, "$c" .. (register + 1) .. "_y", (color[2] or 0) / 255 }
            setters[#setters + 1] = { material.SetFloat, "$c" .. (register + 1) .. "_z", (color[3] or 0) / 255 }
            setters[#setters + 1] = { material.SetFloat, "$c" .. (register + 1) .. "_w", castsShadows }
        end

        for _, setter in ipairs(setters) do
            local succeeded, setError = pcall(setter[1], material, setter[2], setter[3])
            if not succeeded then error(setError or ("failed to set " .. setter[2])) end
        end

        -- One unmasked full-screen pass shades visible NKM receiver pixels.
        -- Source depth is not part of this four-sampler pass.
        resetNKMStencilState()
        render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
        render.SetMaterial(material)
        -- GShader's 2D screen quad shares the exact screen UV domain used while
        -- reconstructing _rt_WPDepth and _rt_NormalsTangents. Avoid the cached
        -- RenderScene 3D quad, which can drift from a custom view setup.
        shaderlib.DrawScreenQuad()
    end)

    render.OverrideBlend(false)
    render.SetBlend(1)
    resetNKMStencilState()
    if not ok then
        NKM.GShaderLastError = "GShader full-scene deferred pass failed: " .. tostring(err)
        return false
    end

    NKM.GShaderDeferredPassCount = (NKM.GShaderDeferredPassCount or 0) + 1
    NKM.GShaderScenePassCount = (NKM.GShaderScenePassCount or 0) + 1
    NKM.GShaderLastError = nil
    return true
end

function NKM.ClearClientMap()
    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        destroyMeshList(chunk.renderMeshes)
        chunk.renderMeshes = nil
        chunk.collision = nil
        chunk.triangleSurfaces = nil
        chunk._nkmTraceCache = nil
        chunk._nkmRenderSourceMeshes = nil
        chunk.loaded = false
    end

    NKM.ClientChunks = {}
    NKM.ClientChunkStats = nil
    NKM.ClientManifest = nil
    NKM.ClientMap = nil
    NKM.ClientMapName = nil
    NKM.ClientGeneration = nil
    NKM.ClientLighting = nil
    NKM.ClientDynamicLights = {}
    NKM.GShaderLUTGeneration = nil
    NKM.GShaderReadyFrame = false
    NKM.ManifestTransfer = nil
    NKM.ChunkTransfers = {}
    NKM.LoadedClientChunkCount = 0
    NKM.RenderMeshes = {}
    NKM.TraceMap = nil
    NKM.GShaderNKMBufferReady = false
end

function NKM.UnloadClientChunk(chunk)
    if not chunk or not chunk.loaded then return end

    destroyMeshList(chunk.renderMeshes)
    chunk.renderMeshes = nil
    chunk.collision = nil
    chunk.triangleSurfaces = nil
    chunk._nkmTraceCache = nil
    chunk._nkmRenderSourceMeshes = nil
    chunk.loaded = false
    chunk.requestPending = false
    chunk.cacheChecked = false
    rebuildLoadedMeshList()
    rebuildClientTraceMap()
end

local function validateChunkPayload(payload, chunk)
    if not istable(payload) then return false, "chunk payload is not a table" end
    if payload.format ~= "NKM_CHUNK" or payload.version ~= NKM.Version then
        return false, "unsupported chunk format/version"
    end
    if payload.name ~= NKM.ClientMapName or payload.id ~= chunk.id or payload.index ~= chunk.index
        or payload.ix ~= chunk.ix or payload.iy ~= chunk.iy or payload.iz ~= chunk.iz then
        return false, "chunk identity mismatch"
    end
    if not istable(payload.meshes) or not istable(payload.collision)
        or not istable(payload.triangleSurfaces) then
        return false, "chunk mesh/collision/triangle surface arrays are missing"
    end
    if #payload.meshes ~= chunk.meshGroupCount or #payload.collision ~= chunk.collisionCount
        or #payload.triangleSurfaces ~= (chunk.triangleSurfaceCount or 0) then
        return false, "chunk content counts do not match manifest"
    end

    -- Reuse the central map validator. Collision-only chunks get a temporary
    -- validation triangle that is never passed to the renderer.
    local validationMeshes = payload.meshes
    if #validationMeshes == 0 then
        validationMeshes = {
            {
                material = "nkm_validation",
                vertices = {
                    { p = { 0, 0, 0 } },
                    { p = { 1, 0, 0 } },
                    { p = { 0, 1, 1 } }
                }
            }
        }
    end

    local valid, detail = NKM.ValidateMap({
        format = NKM.FormatMagic,
        version = NKM.Version,
        name = NKM.ClientMapName,
        meshes = validationMeshes,
        collision = payload.collision,
        triangleSurfaces = payload.triangleSurfaces
    })
    if not valid then return false, detail end
    return true
end

function NKM.ApplyClientChunk(chunkIndex, payload)
    local applyStartedAt = NKM.PerfBegin()
    local chunk = NKM.ClientChunks[chunkIndex]
    if not chunk then return false, "unknown chunk index" end
    chunk.requestPending = false

    if not chunk.wanted then
        return false, "chunk is no longer within load distance"
    end

    local validateStartedAt = NKM.PerfBegin()
    local valid, detail = validateChunkPayload(payload, chunk)
    NKM.PerfRecord("chunk_validate", validateStartedAt)
    if not valid then
        chunk.retryAt = CurTime() + 2
        NKM.PerfRecord("chunk_apply", applyStartedAt)
        return false, "validation failed: " .. tostring(detail)
    end

    local meshStartedAt = NKM.PerfBegin()
    local meshes, meshError = buildChunkRenderMeshes(payload.meshes, chunk.id)
    NKM.PerfRecord("mesh_build", meshStartedAt)
    if not meshes then
        chunk.retryAt = CurTime() + 2
        NKM.PerfRecord("chunk_apply", applyStartedAt)
        return false, meshError
    end

    chunk.renderMeshes = meshes
    chunk._nkmRenderSourceMeshes = nil
    for _, meshGroup in ipairs(payload.meshes or {}) do
        if meshGroup.isBSPDisplacement == true then
            -- Keep source vertices only for imported BSP chunks so the diagnostic
            -- offset can rebuild their IMesh without changing physics or trace data.
            chunk._nkmRenderSourceMeshes = payload.meshes
            break
        end
    end
    chunk.collision = payload.collision
    chunk.triangleSurfaces = payload.triangleSurfaces
    chunk.loaded = true
    chunk.loadedAt = CurTime()
    chunk.cacheChecked = true
    chunk.meshes = nil -- Parsed render vertices are discarded after IMesh creation.

    rebuildLoadedMeshList()
    rebuildClientTraceMap()
    NKM.PerfRecord("chunk_apply", applyStartedAt)
    NKM.PerfAdd("chunks_applied", 1)
    return true
end


function NKM.RebuildBSPDisplacementRenderMeshes()
    local rebuiltChunks = 0
    local failedChunks = 0

    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        if chunk.loaded and istable(chunk._nkmRenderSourceMeshes) then
            local replacement, err = buildChunkRenderMeshes(chunk._nkmRenderSourceMeshes, chunk.id)
            if replacement then
                destroyMeshList(chunk.renderMeshes)
                chunk.renderMeshes = replacement
                rebuiltChunks = rebuiltChunks + 1
            else
                failedChunks = failedChunks + 1
                ErrorNoHalt("[NKM] BSP displacement mesh rebuild failed for chunk "
                    .. tostring(chunk.id) .. ": " .. tostring(err) .. "\n")
            end
        end
    end

    rebuildLoadedMeshList()
    return rebuiltChunks, failedChunks
end

local function printBSPDisplacementClientInfo()
    local groups, vertices = 0, 0
    local missingUV, invalidUV = 0, 0
    local minU, minV, maxU, maxV = math.huge, math.huge, -math.huge, -math.huge
    local materials = {}
    local patchIDs = {}
    local vertexLit = 0
    local litPatches = {}
    local lightmapSamples = 0
    local minLight, maxLight = math.huge, -math.huge

    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        if chunk.loaded then
            for _, group in ipairs(chunk._nkmRenderSourceMeshes or {}) do
                if group.isBSPDisplacement == true then
                    groups = groups + 1
                    materials[group.material or "<none>"] = true
                    local patchKey = tostring(group.sourcePatchID or group.sourceGroup or "?")
                    patchIDs[patchKey] = true
                    if group.hasVertexLighting then litPatches[patchKey] = true end
                    lightmapSamples = lightmapSamples + (group.lightmapSamples or 0)
                    for _, vertex in ipairs(group.vertices or {}) do
                        vertices = vertices + 1
                        local color = vertex.color
                        if group.hasVertexLighting and istable(color)
                            and isnumber(color[1]) and isnumber(color[2]) and isnumber(color[3]) then
                            vertexLit = vertexLit + 1
                            local light = (color[1] + color[2] + color[3]) / 3
                            minLight = math.min(minLight, light)
                            maxLight = math.max(maxLight, light)
                        end
                        local uv = vertex.uv
                        if not istable(uv) then
                            missingUV = missingUV + 1
                        elseif not isnumber(uv[1]) or not isnumber(uv[2])
                            or uv[1] ~= uv[1] or uv[2] ~= uv[2]
                            or uv[1] == math.huge or uv[1] == -math.huge
                            or uv[2] == math.huge or uv[2] == -math.huge then
                            invalidUV = invalidUV + 1
                        else
                            minU = math.min(minU, uv[1])
                            minV = math.min(minV, uv[2])
                            maxU = math.max(maxU, uv[1])
                            maxV = math.max(maxV, uv[2])
                        end
                    end
                end
            end
        end
    end

    local materialNames = {}
    local errorMaterials = 0
    for name in pairs(materials) do
        materialNames[#materialNames + 1] = name
        local ok, mat = pcall(Material, name)
        if not ok or not mat then
            errorMaterials = errorMaterials + 1
        else
            local checkOK, isError = pcall(mat.IsError, mat)
            if not checkOK or isError then errorMaterials = errorMaterials + 1 end
        end
    end
    table.sort(materialNames)

    print(string.format("[NKM] BSP displacement client: groups=%d patches=%d vertices=%d",
        groups, table.Count(patchIDs), vertices))
    print(string.format("[NKM] UV: missing=%d invalid=%d rangeU=[%.4f, %.4f] rangeV=[%.4f, %.4f]",
        missingUV, invalidUV,
        minU == math.huge and 0 or minU, maxU == -math.huge and 0 or maxU,
        minV == math.huge and 0 or minV, maxV == -math.huge and 0 or maxV))
    print(string.format("[NKM] Materials: %d, missing/error=%d: %s",
        #materialNames, errorMaterials, table.concat(materialNames, ", ")))
    print(string.format("[NKM] BSP vertex lighting: patches=%d/%d renderVertices=%d/%d luxelSamples=%d averageRGB-range=[%.1f, %.1f]",
        table.Count(litPatches), table.Count(patchIDs), vertexLit, vertices, lightmapSamples,
        minLight == math.huge and 0 or minLight, maxLight == -math.huge and 0 or maxLight))
    for _, name in ipairs(materialNames) do
        local ok, mat = pcall(Material, name)
        if ok and mat then
            print(string.format("[NKM] Material '%s': shader=%s basetexture=%s basetexture2=%s",
                name, getSafeMaterialShader(mat) or "<unknown>",
                getSafeMaterialString(mat, "$basetexture") or "<none>",
                getSafeMaterialString(mat, "$basetexture2") or "<none>"))
        end
    end
    print(string.format("[NKM] Render: enabled=%s debug=%s materialMode=%s normalOffset=%.3f units",
        tostring(NKM.ClientBSPDisplacementRenderEnabled), tostring(NKM.ClientBSPDisplacementDebug),
        tostring(NKM.ClientBSPDisplacementMaterialMode), NKM.ClientBSPDisplacementRenderOffset or 0))
end

function NKM.ApplyClientManifest(manifest, generation)
    if not istable(manifest) or manifest.format ~= "NKM_MANIFEST" then
        return false, "invalid manifest format"
    end
    if manifest.version ~= NKM.Version or not NKM.IsValidMapName(manifest.mapName) then
        return false, "unsupported manifest version or map name"
    end
    if manifest.generation ~= generation then
        return false, "manifest generation mismatch"
    end
    if not istable(manifest.chunks) or #manifest.chunks > NKM.MaxChunks then
        return false, "invalid manifest chunk list"
    end

    local newChunks = {}
    local seenIDs = {}
    for index, meta in ipairs(manifest.chunks) do
        if not istable(meta) or not isstring(meta.id) or #meta.id > 64 or seenIDs[meta.id] then
            return false, "invalid or duplicate chunk ID at index " .. index
        end
        if not istable(meta.mins) or not istable(meta.maxs)
            or not isFiniteNumber(meta.mins[1]) or not isFiniteNumber(meta.mins[2]) or not isFiniteNumber(meta.mins[3])
            or not isFiniteNumber(meta.maxs[1]) or not isFiniteNumber(meta.maxs[2]) or not isFiniteNumber(meta.maxs[3])
            or meta.mins[1] > meta.maxs[1] or meta.mins[2] > meta.maxs[2] or meta.mins[3] > meta.maxs[3] then
            return false, "invalid chunk bounds at index " .. index
        end
        if not isFiniteNumber(meta.bytes) or meta.bytes < 1 or meta.bytes > NKM.MaxMapBytes
            or not isstring(meta.checksum) or #meta.checksum < 1 or #meta.checksum > 16
            or not meta.checksum:match("^[%w]+$")
            or not isnumber(meta.meshGroups) or meta.meshGroups < 0
            or not isnumber(meta.collisionCount) or meta.collisionCount < 0
            or (meta.triangleSurfaceCount ~= nil and (not isnumber(meta.triangleSurfaceCount) or meta.triangleSurfaceCount < 0)) then
            return false, "invalid chunk size/checksum/counts at index " .. index
        end

        seenIDs[meta.id] = true
        newChunks[index] = {
            id = meta.id,
            index = index,
            ix = meta.ix or 0,
            iy = meta.iy or 0,
            iz = meta.iz or 0,
            mins = Vector(meta.mins[1], meta.mins[2], meta.mins[3]),
            maxs = Vector(meta.maxs[1], meta.maxs[2], meta.maxs[3]),
            expectedBytes = meta.bytes,
            checksum = meta.checksum,
            meshGroupCount = meta.meshGroups or 0,
            collisionCount = meta.collisionCount or 0,
            triangleSurfaceCount = meta.triangleSurfaceCount or 0,
            renderMeshes = nil,
            collision = nil,
            loaded = false,
            wanted = false,
            requestPending = false,
            retryAt = 0
        }
    end

    NKM.ClearClientMap()
    NKM.ClientManifest = manifest
    NKM.ClientMap = manifest
    NKM.ClientMapName = manifest.mapName
    NKM.ClientGeneration = generation
    setClientLightingSettings(manifest.lighting)
    NKM.ClientChunks = newChunks
    NKM.ClientChunkStats = {
        chunkSize = manifest.chunkSize or NKM.DefaultChunkSize,
        chunkCount = #newChunks
    }
    NKM.CleanChunkCache(manifest, newChunks)
    NKM.NextChunkRequestAt = 0

    print(string.format("[NKM] Manifest received: '%s', %d chunks (payload is streamed on demand)",
        manifest.mapName, #newChunks))
    NKM.UpdateChunkStreaming(true)
    return true
end

function NKM.UpdateChunkStreaming(force)
    if not NKM.ClientChunks or #NKM.ClientChunks == 0 then return end

    local now = CurTime()
    if not force and now < (NKM.NextChunkUpdate or 0) then return end
    NKM.NextChunkUpdate = now + 0.25

    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local position = ply:GetPos()
    local loadDistanceSqr = NKM.ChunkLoadDistance * NKM.ChunkLoadDistance
    local unloadDistanceSqr = NKM.ChunkUnloadDistance * NKM.ChunkUnloadDistance
    local loadedCount = 0
    local requestQueue = {}

    -- First pass updates residency and collects missing chunks. Requests are
    -- sent only after sorting by distance, so nearby geometry always wins.
    for _, chunk in ipairs(NKM.ClientChunks) do
        local distanceSqr = distanceSqrToBounds(position, chunk.mins, chunk.maxs)
        chunk.distanceSqr = distanceSqr
        chunk.wanted = distanceSqr <= loadDistanceSqr

        if chunk.loaded then
            if distanceSqr > unloadDistanceSqr then
                NKM.UnloadClientChunk(chunk)
            else
                loadedCount = loadedCount + 1
            end
        elseif chunk.requestPending then
            if now - (chunk.requestTime or now) > 3 then
                chunk.requestPending = false
                chunk.retryAt = now + 1
            end
        elseif chunk.wanted and now >= (chunk.retryAt or 0) then
            requestQueue[#requestQueue + 1] = chunk
        end
    end

    table.sort(requestQueue, function(a, b)
        if a.distanceSqr ~= b.distanceSqr then
            return a.distanceSqr < b.distanceSqr
        end
        return a.id < b.id
    end)

    if #requestQueue > 0 then
        local chunk = requestQueue[1]
        if not chunk.cacheChecked then
            chunk.cacheChecked = true
            local cachedPayload, cacheState = NKM.ReadChunkCache(chunk)
            if cachedPayload then
                local ok, err = NKM.ApplyClientChunk(chunk.index, cachedPayload)
                if ok then
                    addCacheStat("Hits")
                    NKM.LastChunkCacheSource = "disk"
                    NKM.LastChunkCacheChunk = chunk.id
                    NKM.NextChunkUpdate = 0
                    return
                end

                local path = getChunkCachePath(chunk)
                if path then file.Delete(path) end
                addCacheStat("Corruptions")
                addCacheStat("Evictions")
                chunk.cacheChecked = false
                chunk.retryAt = now + 0.5
                print("[NKM] Cached chunk rejected " .. chunk.id .. ": " .. tostring(err))
                return
            end
            if cacheState == "miss" or cacheState == "corrupt" or cacheState == "invalid JSON" then
                NKM.LastChunkCacheSource = "network"
            end
        end
    end

    if #requestQueue > 0 and now >= (NKM.NextChunkRequestAt or 0) then
        local chunk = requestQueue[1]
        net.Start("nkm_chunk_request")
            net.WriteUInt(NKM.ClientGeneration or 0, 16)
            net.WriteUInt(chunk.index, 16)
        net.SendToServer()

        chunk.requestPending = true
        chunk.requestTime = now
        NKM.NextChunkRequestAt = now + 0.12
    end

    NKM.LoadedClientChunkCount = loadedCount
    NKM.LastChunkRequestQueueSize = #requestQueue
end

net.Receive("nkm_manifest_begin", function()
    local generation = net.ReadUInt(16)
    local mapName = net.ReadString()
    local totalParts = net.ReadUInt(16)
    local totalBytes = net.ReadUInt(32)
    local checksum = net.ReadString()

    if totalBytes < 1 or totalBytes > NKM.MaxManifestBytes or totalParts < 1 then
        NKM.ManifestTransfer = nil
        print("[NKM] Rejected manifest transfer: invalid size/part count")
        return
    end

    NKM.ManifestTransfer = {
        generation = generation,
        mapName = mapName,
        totalParts = totalParts,
        totalBytes = totalBytes,
        checksum = checksum,
        parts = {},
        received = 0
    }
end)

net.Receive("nkm_manifest_data", function()
    local generation = net.ReadUInt(16)
    local partIndex = net.ReadUInt(16)
    local length = net.ReadUInt(16)
    local data = net.ReadData(length)
    local transfer = NKM.ManifestTransfer

    if not transfer or transfer.generation ~= generation or not data then return end
    if partIndex < 1 or partIndex > transfer.totalParts or transfer.parts[partIndex] then return end

    transfer.parts[partIndex] = data
    transfer.received = transfer.received + 1
    if transfer.received ~= transfer.totalParts then return end

    local payload = table.concat(transfer.parts)
    NKM.ManifestTransfer = nil
    if #payload ~= transfer.totalBytes or util.CRC(payload) ~= transfer.checksum then
        print("[NKM] Manifest transfer failed: size/checksum mismatch")
        return
    end

    local manifest = util.JSONToTable(payload)
    if not manifest or manifest.mapName ~= transfer.mapName then
        print("[NKM] Manifest transfer failed: invalid JSON or map name mismatch")
        return
    end

    local ok, err = NKM.ApplyClientManifest(manifest, generation)
    if not ok then
        print("[NKM] Manifest rejected: " .. tostring(err))
    end
end)

net.Receive("nkm_chunk_begin", function()
    local generation = net.ReadUInt(16)
    local chunkIndex = net.ReadUInt(16)
    local totalParts = net.ReadUInt(16)
    local totalBytes = net.ReadUInt(32)
    local checksum = net.ReadString()

    if generation ~= NKM.ClientGeneration then return end
    local chunk = NKM.ClientChunks[chunkIndex]
    if not chunk or totalBytes < 1 or totalBytes > NKM.MaxMapBytes or totalParts < 1 then return end

    local key = tostring(generation) .. ":" .. tostring(chunkIndex)
    NKM.ChunkTransfers[key] = {
        generation = generation,
        chunkIndex = chunkIndex,
        totalParts = totalParts,
        totalBytes = totalBytes,
        checksum = checksum,
        parts = {},
        received = 0
    }
end)

net.Receive("nkm_chunk_data", function()
    local generation = net.ReadUInt(16)
    local chunkIndex = net.ReadUInt(16)
    local partIndex = net.ReadUInt(16)
    local length = net.ReadUInt(16)
    local data = net.ReadData(length)
    local key = tostring(generation) .. ":" .. tostring(chunkIndex)
    local transfer = NKM.ChunkTransfers[key]

    if not transfer or not data then return end
    if partIndex < 1 or partIndex > transfer.totalParts or transfer.parts[partIndex] then return end

    transfer.parts[partIndex] = data
    transfer.received = transfer.received + 1
    if transfer.received ~= transfer.totalParts then return end

    NKM.ChunkTransfers[key] = nil
    local transferStartedAt = NKM.PerfBegin()
    local payload = table.concat(transfer.parts)
    local chunk = NKM.ClientChunks[chunkIndex]
    if not chunk then return end

    if #payload ~= transfer.totalBytes or #payload ~= chunk.expectedBytes
        or util.CRC(payload) ~= transfer.checksum or transfer.checksum ~= chunk.checksum then
        chunk.requestPending = false
        chunk.retryAt = CurTime() + 2
        print("[NKM] Chunk transfer failed: size/checksum mismatch for " .. chunk.id)
        return
    end

    local decodeStartedAt = NKM.PerfBegin()
    local decoded = util.JSONToTable(payload)
    NKM.PerfRecord("network_json_decode", decodeStartedAt)
    NKM.PerfRecord("network_chunk_receive", transferStartedAt)
    NKM.PerfAdd("network_chunk_bytes", #payload)
    if not decoded then
        chunk.requestPending = false
        chunk.retryAt = CurTime() + 2
        print("[NKM] Chunk transfer failed: invalid JSON for " .. chunk.id)
        return
    end

    local ok, err = NKM.ApplyClientChunk(chunkIndex, decoded)
    if ok then
        local cached, cacheError = NKM.WriteChunkCache(chunk, payload)
        if not cached then
            print("[NKM] Could not cache chunk " .. chunk.id .. ": " .. tostring(cacheError))
        else
            NKM.LastChunkCacheSource = "network (cached)"
            NKM.LastChunkCacheChunk = chunk.id
        end
    elseif err ~= "chunk is no longer within load distance" then
        print("[NKM] Could not apply chunk " .. chunk.id .. ": " .. tostring(err))
    end
end)

net.Receive("nkm_map_clear", function()
    NKM.ClearClientMap()
    print("[NKM] Client map unloaded")
end)

hook.Add("Think", "NKM.ChunkStreaming", function()
    NKM.UpdateChunkStreaming(false)
end)

local function getBSPDisplacementDebugColor(sourcePatchID)
    local text = tostring(sourcePatchID or "nkm")
    local hash = 0
    for index = 1, #text do
        hash = (hash * 33 + string.byte(text, index)) % 104729
    end
    return 0.55 + (hash % 45) / 100,
        0.55 + (math.floor(hash / 7) % 45) / 100,
        0.55 + (math.floor(hash / 31) % 45) / 100
end

hook.Add("PreDrawOpaqueRenderables", "NKM.GShaderStencilClear", function(bDrawingDepth, bDrawingSkybox)
    if bDrawingDepth or bDrawingSkybox then return end
    NKM.GShaderReadyFrame = false
    if NKM.GShaderMaskDebug then clearNKMStencilBit() end
end)

hook.Add("PostDrawOpaqueRenderables", "NKM.DrawWorld", function(bDrawingDepth, bDrawingSkybox)
    if bDrawingSkybox then return end

    -- GShader asks the engine for an additional depth pass. Draw NKM meshes in
    -- that pass too, using Source's DepthWrite shader so its reconstructed
    -- WorldPos/Normals include NKM geometry as well as the BSP scene.
    if bDrawingDepth then
        -- Count the engine's actual depth-pass callbacks separately from the
        -- later full-screen lighting callback. A fullscreen pass alone does
        -- not prove NKM geometry made it into GShader's source depth buffer.
        NKM.GShaderDepthPassCount = (NKM.GShaderDepthPassCount or 0) + 1
        NKM.GShaderLastDepthPassAt = RealTime()
        local drawnMeshes = 0

        if NKM.GShaderBridgeEnabled and hasGShaderAPI() and shouldRunGShaderLighting() and #NKM.RenderMeshes > 0 then
            local ok, err = pcall(function()
                render.CullMode(NKM.CullModeSetting == 1 and MATERIAL_CULLMODE_CW or MATERIAL_CULLMODE_CCW)
                render.OverrideDepthEnable(true, true)
                for _, entry in ipairs(NKM.RenderMeshes) do
                    local isBSPDisplacement = entry.isBSPDisplacement == true
                    local shouldDraw = not (isBSPDisplacement and NKM.ClientBSPDisplacementRenderEnabled == false)
                    if shouldDraw and entry.mesh and entry.mesh:IsValid() then
                        render.SetMaterial(GSHADER_DEPTH_MATERIAL)
                        entry.mesh:Draw()
                        drawnMeshes = drawnMeshes + 1
                    end
                end
            end)
            render.OverrideDepthEnable(false, false)
            render.CullMode(MATERIAL_CULLMODE_CCW)
            render.SetBlend(1)
            if not ok then
                NKM.GShaderLastError = "NKM GShader depth pre-pass failed: " .. tostring(err)
            end
        end

        NKM.GShaderLastDepthPassMeshes = drawnMeshes
        NKM.GShaderDepthMeshDrawCount = (NKM.GShaderDepthMeshDrawCount or 0) + drawnMeshes
        return
    end

    if #NKM.RenderMeshes == 0 then return end

    render.CullMode(NKM.CullModeSetting == 1 and MATERIAL_CULLMODE_CW or MATERIAL_CULLMODE_CCW)

    -- Some vertex-alpha/unlit material combinations or other render hooks can
    -- leave depth writes disabled for this pass. Keep normal depth testing, but
    -- explicitly require every opaque NKM surface to update the Z-buffer so
    -- later meshes cannot draw through nearer NKM walls.
    render.OverrideDepthEnable(true, true)

    for _, entry in ipairs(NKM.RenderMeshes) do
        local isBSPDisplacement = entry.isBSPDisplacement == true
        local shouldDraw = not (isBSPDisplacement and NKM.ClientBSPDisplacementRenderEnabled == false)

        if shouldDraw and entry.mesh and entry.mesh:IsValid() then
            if isBSPDisplacement and NKM.ClientBSPDisplacementDebug then
                render.SetMaterial(BSP_DISPLACEMENT_DEBUG_MATERIAL)
                local r, g, b = getBSPDisplacementDebugColor(entry.sourcePatchID)
                render.SetColorModulation(r, g, b)
                render.SetBlend(1)
                entry.mesh:Draw()
                render.SetColorModulation(1, 1, 1)
            elseif isBSPDisplacement and (NKM.ClientBSPDisplacementMaterialMode == "albedo"
                or NKM.ClientBSPDisplacementMaterialMode == "lit") then
                -- WorldVertexTransition is reproduced with two UnlitGeneric passes.
                -- In lit mode, BSP LDR light samples are barycentrically transferred
                -- to displacement grid vertices and applied through vertex color.
                render.SetColorModulation(1, 1, 1)
                render.SetBlend(1)
                render.SetMaterial(entry.albedoMaterial or DEFAULT_MATERIAL)
                entry.mesh:Draw()
                if entry.blendMesh and entry.blendMesh:IsValid() and entry.blendMaterial then
                    render.SetMaterial(entry.blendMaterial)
                    entry.blendMesh:Draw()
                end
            elseif entry.hasNKMLighting and not isBSPDisplacement then
                render.SetMaterial(entry.nkmLightingMaterial or DEFAULT_MATERIAL)
                render.SetColorModulation(1, 1, 1)
                render.SetBlend(1)
                entry.mesh:Draw()
            else
                render.SetMaterial(entry.material)
                render.SetColorModulation(1, 1, 1)
                render.SetBlend(1)
                entry.mesh:Draw()
            end
        end
    end
    -- Release the override after the NKM pass; do not leak it into Source
    -- translucent rendering, viewmodels, or other addons.
    render.OverrideDepthEnable(false, false)
    render.CullMode(MATERIAL_CULLMODE_CCW)
    render.SetColorModulation(1, 1, 1)
    render.SetBlend(1)
end)

-- GShader calls PostDrawReconstructionLighting only after _rt_WPDepth and
-- _rt_NormalsTangents are fully reconstructed and its RTs have been popped.
-- Execute both deferred passes here, synchronously. Deferring to another
-- PreDrawTranslucentRenderables hook is order-dependent because GShader itself
-- runs reconstruction from that same hook event.
local function runNKMDeferredLighting(viewSetup)
    if not NKM.GShaderBridgeEnabled or not hasGShaderAPI() then return end
    local ok, canDraw = pcall(shaderlib.CanDrawEffects, viewSetup)
    if not ok or not canDraw then return end
    if not shouldRunGShaderLighting() or not getNKMDeferredMaterial() then return end

    NKM.GShaderLastViewSetup = viewSetup
    NKM.GShaderLastHookAt = RealTime()

    if NKM.GShaderMaskDebug then
        markVisibleNKMGeometry()
        drawGShaderMaskDebug()
        return
    end

    if not drawNKMSceneLighting(viewSetup) and NKM.GShaderLastError then
        NKM.GShaderLastStatusPrintAt = NKM.GShaderLastStatusPrintAt or 0
        if RealTime() >= NKM.GShaderLastStatusPrintAt then
            NKM.GShaderLastStatusPrintAt = RealTime() + 5
            print("[NKM] GShader scene pass skipped: " .. tostring(NKM.GShaderLastError))
        end
    end
end

hook.Add("PostDrawReconstructionLighting", "NKM.GShaderDeferredPass", runNKMDeferredLighting)


concommand.Add("nkm_lighting_status", function()
    local hasLighting = false
    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        for _, group in ipairs(chunk.renderMeshes or {}) do
            if group.hasNKMLighting then
                hasLighting = true
                break
            end
        end
        if hasLighting then break end
    end

    local gshaderAvailable = hasGShaderAPI()
    print("[NKM] Lighting: " .. (hasLighting and "NKM vertex lighting present" or "no NKM vertex bake in active map"))
    print("[NKM] GShader: " .. (gshaderAvailable and "detected" or "not detected")
        .. "; dynamic point lights=" .. tostring(#(NKM.ClientDynamicLights or {})))
    print("[NKM] Deferred: bridge=" .. tostring(NKM.GShaderBridgeEnabled == true)
        .. " maskDebug=" .. tostring(NKM.GShaderMaskDebug == true)
        .. " maskPasses=" .. tostring(NKM.GShaderMaskPassCount or 0)
        .. " shaderPasses=" .. tostring(NKM.GShaderDeferredPassCount or 0))
    print("[NKM] GShader material: " .. (getNKMDeferredMaterial() and "compiled/available" or tostring(NKM.GShaderLastError or "unavailable")))
    print("[NKM] GShader LUT: " .. (NKM.GShaderLUTGeneration == NKM.ClientGeneration and "uploaded" or "not uploaded")
        .. (NKM.GShaderLUTLastError and (" (" .. tostring(NKM.GShaderLUTLastError) .. ")") or ""))
    print("[NKM] Per-pixel lighting requested: " .. tostring(NKM_GShaderPixelLightingConVar:GetBool())
        .. "; active: " .. tostring(NKM.GShaderPixelLighting == true))
    print("[NKM] NKM AO, ambient/directional and point lights use one unmasked full-screen pass (NKM-only receiver depth).")
end)

concommand.Add("nkm_gshader_lights", function()
    local lighting = NKM.ClientLighting or {}
    local lights = NKM.ClientDynamicLights or {}
    print("[NKM] Lighting enabled: " .. tostring(lighting.enabled == true)
        .. "; pixel lighting active: " .. tostring(NKM.GShaderPixelLighting == true)
        .. "; dynamic point lights: " .. tostring(#lights))
    for index, light in ipairs(lights) do
        local position = light.position or {}
        local color = light.color or {}
        print(string.format(
            "[NKM] Point #%d pos=(%.2f, %.2f, %.2f) radius=%.2f color=(%.1f, %.1f, %.1f) intensity=%.3f shadows=%s",
            index,
            position[1] or 0, position[2] or 0, position[3] or 0,
            light.radius or 0,
            color[1] or 0, color[2] or 0, color[3] or 0,
            light.intensity or 1,
            tostring(light.shadows == true)
        ))
    end
    local lut = NKM.GShaderDynamicLightLUT
    if lut then
        local widthOK, width = pcall(lut.Width, lut)
        local heightOK, height = pcall(lut.Height, lut)
        print("[NKM] Dynamic-light LUT: " .. tostring(widthOK and width or "?")
            .. "x" .. tostring(heightOK and height or "?")
            .. "; uploaded=" .. tostring(NKM.GShaderLUTGeneration == NKM.ClientGeneration)
            .. "; error=" .. tostring(NKM.GShaderLUTLastError))
    else
        print("[NKM] Dynamic-light LUT: not created; error=" .. tostring(NKM.GShaderLUTLastError))
    end
end)

concommand.Add("nkm_gshader_status", function()
    local available = hasGShaderAPI()
    local material = getNKMDeferredMaterial()
    print("[NKM] GShader available: " .. tostring(available))
    print("[NKM] GShader bridge enabled: " .. tostring(NKM.GShaderBridgeEnabled == true))
    print("[NKM] Pixel lighting requested/active: " .. tostring(NKM_GShaderPixelLightingConVar:GetBool())
        .. "/" .. tostring(NKM.GShaderPixelLighting == true))
    print("[NKM] Screen-space effects: contactShadows="
        .. tostring(NKM_GShaderContactShadowsConVar:GetBool())
        .. "; AO=" .. tostring(NKM_GShaderAOConVar:GetBool()))
    print("[NKM] Full-scene deferred passes: " .. tostring(NKM.GShaderScenePassCount or 0))
    print("[NKM] NKM GBuffer builds: " .. tostring(NKM.GShaderNKMBufferBuildCount or 0)
        .. "; ready=" .. tostring(NKM.GShaderNKMBufferReady == true)
        .. "; last meshes=" .. tostring(NKM.GShaderNKMBufferLastMeshes or 0)
        .. (NKM.GShaderNKMBufferLastAt and string.format("; updated %.2fs ago", math.max(0, RealTime() - NKM.GShaderNKMBufferLastAt)) or "; not built yet"))
    if NKM.GShaderNKMBufferLastError then
        print("[NKM] NKM GBuffer error: " .. tostring(NKM.GShaderNKMBufferLastError))
    end
    if NKM.GShaderNKMBufferDebug then
        print("[NKM] NKM normal debug: custom NKM decoded=" .. tostring(NKM_GShaderDecodedNormalRT ~= nil)
            .. "; WP XYZ decoded=" .. tostring(NKM_GShaderDecodedWorldPosRT ~= nil)
            .. "; WP debug shader=" .. tostring(NKM_GShaderWorldPosDebugMaterial ~= nil)
            .. "; WP sampler2 shader=" .. tostring(NKM_GShaderWorldPosSampler2Material ~= nil)
            .. "; WP 4-tap normal shader=" .. tostring(NKM_GShaderWorldPosNormal4TapMaterial ~= nil)
            .. "; point-light debug shader=" .. tostring(NKM_GShaderPointLightDebugMaterial ~= nil)
            .. "; mesh normal meshes=" .. tostring(NKM.GShaderNKMBufferDebugVertexMeshes or 0)
            .. "; mesh normal decoded=" .. tostring(NKM_GShaderDecodedVertexNormalRT ~= nil)
            .. "; 4tap target=" .. tostring(NKM_GShaderNormal4TapRT ~= nil)
            .. "; 4tap decoded=" .. tostring(NKM_GShaderDecodedNormal4TapRT ~= nil)
            .. "; 4tap shader=" .. tostring(NKM_GShaderNormal4TapMaterial ~= nil)
            .. "; 4tap decode=" .. tostring(NKM_GShaderNormal4TapDecodeMaterial ~= nil))
        if NKM.GShaderNKMBufferDebug4TapError then
            print("[NKM] NKM 4-tap debug error: " .. tostring(NKM.GShaderNKMBufferDebug4TapError))
        end
        if NKM.GShaderNKMBufferDebugVertexError then
            print("[NKM] NKM mesh normal debug error: " .. tostring(NKM.GShaderNKMBufferDebugVertexError))
        end
        if NKM.GShaderNKMBufferDebugWorldPosError then
            print("[NKM] NKM world-position debug error: "
                .. tostring(NKM.GShaderNKMBufferDebugWorldPosError))
        end
        if NKM.GShaderNKMBufferDebugSampler2Error then
            print("[NKM] NKM world-position sampler2 debug error: "
                .. tostring(NKM.GShaderNKMBufferDebugSampler2Error))
        end
        if NKM.GShaderNKMBufferDebugNormal4TapError then
            print("[NKM] NKM 4-tap world-normal debug error: "
                .. tostring(NKM.GShaderNKMBufferDebugNormal4TapError))
        end
        if NKM.GShaderNKMBufferDebugPointLightError then
            print("[NKM] NKM point-light debug error: "
                .. tostring(NKM.GShaderNKMBufferDebugPointLightError))
        end
    end
    print("[NKM] Engine SSAO depth callbacks: " .. tostring(NKM.GShaderDepthPassCount or 0)
        .. "; last depth meshes submitted=" .. tostring(NKM.GShaderLastDepthPassMeshes or 0)
        .. "; cumulative mesh draws=" .. tostring(NKM.GShaderDepthMeshDrawCount or 0)
        .. (NKM.GShaderLastDepthPassAt and string.format("; depth callback %.2fs ago", math.max(0, RealTime() - NKM.GShaderLastDepthPassAt)) or "; no depth callback seen"))
    print("[NKM] Render meshes currently loaded: " .. tostring(#(NKM.RenderMeshes or {})))
    print("[NKM] Reconstruction hook seen: " .. tostring(NKM.GShaderLastHookAt ~= nil)
        .. (NKM.GShaderLastHookAt and string.format(" (%.2fs ago)", math.max(0, RealTime() - NKM.GShaderLastHookAt)) or ""))
    print("[NKM] NKM dynamic point lights: " .. tostring(#(NKM.ClientDynamicLights or {})))
    print("[NKM] NKM stencil mask debug (visualization only): " .. tostring(NKM.GShaderMaskDebug == true)
        .. "; mask passes=" .. tostring(NKM.GShaderMaskPassCount or 0)
        .. "; last mask meshes=" .. tostring(NKM.GShaderLastMaskDraws or 0))
    print("[NKM] Deferred shader material: " .. tostring(material ~= nil))
    print("[NKM] LUT uploaded: " .. tostring(NKM.GShaderLUTGeneration == NKM.ClientGeneration))
    if NKM.GShaderLUTLastError then print("[NKM] LUT error: " .. tostring(NKM.GShaderLUTLastError)) end
    if NKM.GShaderLastError then print("[NKM] Last error: " .. tostring(NKM.GShaderLastError)) end
end)

concommand.Add("nkm_gshader_debug_buffers", function(_, _, args)
    local value = args and args[1]
    local previous = NKM.GShaderNKMBufferDebug == true
    if value == "1" then
        NKM.GShaderNKMBufferDebug = true
    elseif value == "0" then
        NKM.GShaderNKMBufferDebug = false
    elseif value ~= nil then
        print("[NKM] Usage: nkm_gshader_debug_buffers [0|1]")
        return
    end

    if previous ~= (NKM.GShaderNKMBufferDebug == true) then
        -- The previous rebuild helper only retained source vertices for BSP
        -- displacements. Ordinary streamed NKM chunks had already discarded
        -- their parsed vertex arrays, so their normalDebugMesh was never built.
        -- Re-stream wanted chunks from the local cache (or server) with the
        -- diagnostic flag active, causing buildChunkRenderMeshes to create it.
        local requeued = 0
        for _, chunk in ipairs(NKM.ClientChunks or {}) do
            if chunk.loaded and chunk.wanted then
                NKM.UnloadClientChunk(chunk)
                chunk.cacheChecked = false
                chunk.requestPending = false
                chunk.retryAt = 0
                requeued = requeued + 1
            end
        end

        if requeued > 0 and isfunction(NKM.UpdateChunkStreaming) then
            NKM.NextChunkUpdate = 0
            NKM.NextChunkRequestAt = 0
            NKM.UpdateChunkStreaming(true)
        end

        print(string.format(
            "[NKM] Re-queued %d wanted chunks for normal diagnostics; they will rebuild from cache/network",
            requeued))
    end

    print("[NKM] NKM GBuffer debug: " .. tostring(NKM.GShaderNKMBufferDebug == true))
end)

concommand.Add("nkm_gshader_debug_mask", function(_, _, args)
    local value = args and args[1]
    if value == "1" then
        NKM.GShaderMaskDebug = true
    elseif value == "0" then
        NKM.GShaderMaskDebug = false
    elseif value ~= nil then
        print("[NKM] Usage: nkm_gshader_debug_mask [0|1]")
        return
    end
    print("[NKM] GShader NKM mask debug: " .. tostring(NKM.GShaderMaskDebug))
end)

concommand.Add("nkm_gshader_enable", function(_, _, args)
    local value = args and args[1]
    if value == "1" then
        NKM.GShaderBridgeEnabled = true
    elseif value == "0" then
        NKM.GShaderBridgeEnabled = false
        NKM.GShaderReadyFrame = false
    elseif value ~= nil then
        print("[NKM] Usage: nkm_gshader_enable [0|1]")
        return
    end
    print("[NKM] GShader bridge: " .. tostring(NKM.GShaderBridgeEnabled))
end)

concommand.Add("nkm_bspdisp_render", function(_, _, args)
    local value = args and args[1]
    if value == "0" then
        NKM.ClientBSPDisplacementRenderEnabled = false
    elseif value == "1" then
        NKM.ClientBSPDisplacementRenderEnabled = true
    elseif value ~= nil then
        print("[NKM] Usage: nkm_bspdisp_render [0|1]")
        return
    end
    print("[NKM] BSP displacement rendering: "
        .. (NKM.ClientBSPDisplacementRenderEnabled and "enabled" or "disabled"))
end)

concommand.Add("nkm_bspdisp_debug", function(_, _, args)
    local value = args and args[1]
    if value == "0" then
        NKM.ClientBSPDisplacementDebug = false
    elseif value == "1" then
        NKM.ClientBSPDisplacementDebug = true
    elseif value ~= nil then
        print("[NKM] Usage: nkm_bspdisp_debug [0|1]")
        return
    end
    print("[NKM] BSP displacement debug material: "
        .. (NKM.ClientBSPDisplacementDebug and "enabled" or "disabled"))
end)

concommand.Add("nkm_bspdisp_material", function(_, _, args)
    local mode = string.lower(tostring(args and args[1] or ""))
    if mode ~= "albedo" and mode ~= "lit" and mode ~= "source" then
        print("[NKM] Usage: nkm_bspdisp_material <albedo|lit|source>")
        return
    end
    NKM.ClientBSPDisplacementMaterialMode = mode
    local rebuilt, failed = NKM.RebuildBSPDisplacementRenderMeshes()
    print("[NKM] BSP displacement material mode: " .. mode .. "; rebuilt chunks=" .. rebuilt .. " failed=" .. failed)
    if mode == "albedo" then
        print("[NKM] Uses stable UnlitGeneric texture wrappers; BSP vertex lighting is ignored.")
    elseif mode == "lit" then
        print("[NKM] Uses UnlitGeneric albedo + BSP LDR per-vertex light approximation; WVT alpha blend is preserved.")
        print("[NKM] This is not exact LightmappedGeneric, HDR, animated lightstyles or bump-lightmap rendering.")
    else
        print("[NKM] Uses original BSP materials; world-only shaders may be unsupported on IMesh.")
    end
end)

concommand.Add("nkm_bspdisp_offset", function(_, _, args)
    local value = tonumber(args and args[1])
    if not value or value ~= value or value == math.huge or value == -math.huge then
        print("[NKM] Usage: nkm_bspdisp_offset <signed units> (range -16..16)")
        print("[NKM] Positive values move along vertex normals; negative values move against them.")
        return
    end
    value = math.Clamp(value, -16, 16)
    NKM.ClientBSPDisplacementRenderOffset = value
    local rebuilt, failed = NKM.RebuildBSPDisplacementRenderMeshes()
    print(string.format("[NKM] BSP displacement render offset: %.3f units; rebuilt chunks=%d failed=%d",
        value, rebuilt, failed))
    print("[NKM] Offset changes render meshes only; VPhysics and Trace coordinates are unchanged.")
end)

concommand.Add("nkm_bspdisp_client_info", function()
    printBSPDisplacementClientInfo()
end)

concommand.Add("nkm_client_status", function()
    local loadedCollisionChunks = 0
    local loadedCollisionConvexes = 0
    local loadedTrianglePatches = 0
    local loadedTriangleCount = 0
    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        if chunk.loaded and ((chunk.collision and #chunk.collision > 0)
            or (chunk.triangleSurfaces and #chunk.triangleSurfaces > 0)) then
            loadedCollisionChunks = loadedCollisionChunks + 1
            loadedCollisionConvexes = loadedCollisionConvexes + #(chunk.collision or {})
            loadedTrianglePatches = loadedTrianglePatches + #(chunk.triangleSurfaces or {})
            for _, surfaceData in ipairs(chunk.triangleSurfaces or {}) do
                loadedTriangleCount = loadedTriangleCount + #(surfaceData.vertices or {}) / 3
            end
        end
    end

    print("[NKM] Client map: " .. tostring(NKM.ClientMapName or "none"))
    print(string.format("[NKM] Lua heap: %.1f MB (excludes native IMesh allocations)", collectgarbage("count") / 1024))
    print("[NKM] Generation: " .. tostring(NKM.ClientGeneration or "none"))
    print("[NKM] Render meshes: " .. #NKM.RenderMeshes)
    print("[NKM] Chunks loaded: " .. tostring(NKM.LoadedClientChunkCount or 0) .. "/" .. tostring(#NKM.ClientChunks))
    print("[NKM] Collision chunks resident: " .. loadedCollisionChunks .. "/" .. tostring(#NKM.ClientChunks))
    print("[NKM] Collision convexes resident: " .. loadedCollisionConvexes)
    print("[NKM] Triangle surface patches resident: " .. loadedTrianglePatches)
    print("[NKM] Triangle collision triangles resident: " .. loadedTriangleCount)
    print("[NKM] Chunk size: " .. tostring(NKM.ClientChunkStats and NKM.ClientChunkStats.chunkSize or NKM.DefaultChunkSize))
    print("[NKM] Pending requests: " .. tostring((function()
        local count = 0
        for _, chunk in ipairs(NKM.ClientChunks or {}) do
            if chunk.requestPending then count = count + 1 end
        end
        return count
    end)()))
    print("[NKM] Waiting chunks: " .. tostring(NKM.LastChunkRequestQueueSize or 0))
    local cacheFiles, cacheBytes = NKM.GetChunkCacheDiskStats()
    local cacheStats = NKM.ChunkCacheStats or {}
    print(string.format("[NKM] Chunk cache: %d files, %d bytes, hits=%d misses=%d writes=%d corruptions=%d evictions=%d",
        cacheFiles, cacheBytes, cacheStats.Hits or 0, cacheStats.Misses or 0,
        cacheStats.Writes or 0, cacheStats.Corruptions or 0, cacheStats.Evictions or 0))

    local traceStats = NKM.GetTraceStats()
    if traceStats then
        print(string.format("[NKM] Client trace: chunks=%d convexes=%d triangles=%d planes=%d",
            traceStats.ChunkCount, traceStats.ConvexCount, traceStats.TriangleCount or 0, traceStats.PlaneCount))
        print(string.format("[NKM] Trace BVH: nodes=%d leaves=%d depth=%d leafSize=%d",
            traceStats.BVHNodeCount, traceStats.BVHLeafCount, traceStats.BVHDepth, traceStats.BVHLeafSize))
        print(string.format("[NKM] Last trace chunks: %d/%d, candidates: %d/%d (plane tests: %d)",
            traceStats.LastChunkCount, traceStats.ChunkCount,
            traceStats.LastCandidateCount, traceStats.ConvexCount + (traceStats.TriangleCount or 0), traceStats.LastTestedCount))
    else
        print("[NKM] Client trace: no streamed collision chunks")
    end
end)

concommand.Add("nkm_client_chunks", function()
    print(string.format("[NKM] Client chunks: %d total, %d loaded, %d active render meshes",
        #NKM.ClientChunks, NKM.LoadedClientChunkCount or 0, #NKM.RenderMeshes))
    for _, chunk in ipairs(NKM.ClientChunks or {}) do
        print(string.format(
            "[NKM] Chunk %s loaded=%s renderMeshes=%d meshGroups=%d convexes=%d/%d trianglePatches=%d/%d pending=%s",
            chunk.id,
            tostring(chunk.loaded == true),
            #(chunk.renderMeshes or {}),
            chunk.meshGroupCount or 0,
            chunk.collision and #chunk.collision or 0,
            chunk.collisionCount or 0,
            chunk.triangleSurfaces and #chunk.triangleSurfaces or 0,
            chunk.triangleSurfaceCount or 0,
            tostring(chunk.requestPending == true)
        ))
    end
end)

concommand.Add("nkm_cache_status", function()
    local cacheFiles, cacheBytes = NKM.GetChunkCacheDiskStats()
    local stats = NKM.ChunkCacheStats or {}
    print("[NKM] Cache root: data/" .. NKM.ChunkCacheRoot)
    print("[NKM] Cache map: " .. tostring(NKM.ClientMapName or "none"))
    print(string.format("[NKM] Cached chunks: %d files, %d bytes", cacheFiles, cacheBytes))
    print(string.format("[NKM] Session: hits=%d misses=%d writes=%d corruptions=%d evictions=%d",
        stats.Hits or 0, stats.Misses or 0, stats.Writes or 0,
        stats.Corruptions or 0, stats.Evictions or 0))
    print("[NKM] Last cache source: " .. tostring(NKM.LastChunkCacheSource or "none")
        .. " (" .. tostring(NKM.LastChunkCacheChunk or "no chunk") .. ")")
end)

concommand.Add("nkm_cache_clear", function(_, _, args)
    local mapName = args and args[1] or nil
    if mapName == "" then mapName = nil end
    if mapName and not NKM.IsValidMapName(mapName) then
        print("[NKM] Invalid map name. Use: nkm_cache_clear [mapName]")
        return
    end

    local deleted = NKM.ClearChunkCache(mapName)
    print(string.format("[NKM] Deleted %d cached chunk files", deleted))
end)

concommand.Add("nkm_client_perf", function()
    NKM.PerfPrint("NKM Client")
    local cacheStats = NKM.ChunkCacheStats or {}
    print(string.format("[NKM Client] Cache: hits=%d misses=%d writes=%d corruptions=%d diskHits=%d",
        cacheStats.Hits or 0, cacheStats.Misses or 0, cacheStats.Writes or 0,
        cacheStats.Corruptions or 0, (NKM.PerfStats.cache_disk_hits and NKM.PerfStats.cache_disk_hits.value) or 0))
    print(string.format("[NKM Client] Residency: chunks=%d meshes=%d pending=%d",
        NKM.LoadedClientChunkCount or 0, #NKM.RenderMeshes, (function()
            local count = 0
            for _, chunk in ipairs(NKM.ClientChunks or {}) do
                if chunk.requestPending then count = count + 1 end
            end
            return count
        end)()))
end)

concommand.Add("nkm_client_perf_reset", function()
    NKM.PerfReset()
    print("[NKM Client] Performance counters reset")
end)

concommand.Add("nkm_client_trace_test", function()
    if not NKM.TraceMap or (#NKM.TraceMap.convexes == 0 and #NKM.TraceMap.triangles == 0) then
        print("[NKM] No streamed NKM collision near the client")
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
        "[NKM] Client trace test: Hit=%s HitNKM=%s Fraction=%.4f Surface=%s Convex=%s Triangle=%s Chunks=%d/%d BVH=%d/%d tested=%d",
        tostring(trace.Hit), tostring(trace.HitNKM), trace.Fraction or 1,
        tostring(trace.SurfaceProp), tostring(trace.NKM and trace.NKM.ConvexIndex or "none"),
        tostring(trace.NKM and trace.NKM.TriangleIndex or "none"),
        stats.LastChunkCount or 0, stats.ChunkCount or 0,
        stats.LastCandidateCount or 0, (stats.ConvexCount or 0) + (stats.TriangleCount or 0), stats.LastTestedCount or 0
    ))
end)
