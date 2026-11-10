-- NKM 0.9.7 - Source BSP displacement importer (NikNaks)
-- Server-side converter: current BSP displacement lumps -> NKM TriangleSurface patches.

if not SERVER then return end

NKM.BSPDisplacementImport = NKM.BSPDisplacementImport or {}

local LUMP = {
    VERTEXES = 3,
    FACES = 7,
    EDGES = 12,
    SURFEDGES = 13,
    TEXINFO = 6,
    TEXDATA = 2,
    LIGHTING = 8,
    DISPINFO = 26,
    DISP_VERTS = 33,
    DISP_LIGHTMAP_SAMPLE_POSITIONS = 34,
    TEXDATA_STRING_DATA = 43,
    TEXDATA_STRING_TABLE = 44,
    DISP_TRIS = 48
}

local SIZE = {
    DISPINFO = 176,
    FACE = 56,
    EDGE = 4,
    SURFEDGE = 4,
    VERTEX = 12,
    TEXINFO = 72,
    TEXDATA = 32,
    DISPVERT = 20,
    DISPTRI = 2
}

local TAG_REMOVE = 32
local DEFAULT_MATERIAL = "nkm_prototype_unlit_v2"
local DEFAULT_IMPORT_PATCH_LIMIT = 64 -- Keeps JSON export comfortably below the prototype map-size ceiling.

local function finite(value)
    return isnumber(value) and value == value and value ~= math.huge and value ~= -math.huge
end

local function getCurrentBSP()
    if not istable(NikNaks) then
        return nil, "NikNaks is not installed or has not been loaded"
    end

    local bsp = NikNaks.CurrentMap
    if bsp then return bsp end

    if isfunction(NikNaks.Map) then
        local ok, result, errorCode = pcall(NikNaks.Map)
        if ok and result then return result end
        return nil, "NikNaks.Map() failed: " .. tostring(errorCode or result)
    end

    return nil, "NikNaks.CurrentMap is unavailable"
end

local function getLump(bsp, lumpID, label)
    local ok, raw = pcall(bsp.GetLumpString, bsp, lumpID)
    if not ok or not isstring(raw) then
        return nil, nil, "could not read BSP lump " .. tostring(lumpID) .. " (" .. label .. ")"
    end
    if #raw == 0 then return nil, raw, nil end

    if not NikNaks.BitBuffer then
        return nil, nil, "NikNaks.BitBuffer is unavailable"
    end

    local bufferOK, buffer = pcall(NikNaks.BitBuffer, raw, true)
    if not bufferOK or not buffer then
        return nil, nil, "could not create BitBuffer for lump " .. tostring(lumpID)
    end

    if buffer.SetLittleEndian then buffer:SetLittleEndian() end
    return buffer, raw, nil
end

local function readAt(lump, byteOffset, reader)
    if not lump or not lump.buffer or byteOffset < 0 or byteOffset + 1 > lump.bytes then
        return nil, "read outside lump bounds"
    end

    local ok, a, b, c, d = pcall(function()
        lump.buffer:Seek(byteOffset * 8)
        return reader(lump.buffer)
    end)
    if not ok then return nil, tostring(a) end
    return a, b, c, d
end

local function loadLump(bsp, lumpID, label, required)
    local buffer, raw, err = getLump(bsp, lumpID, label)
    if err then return nil, err end
    if not raw or #raw == 0 then
        if required then return nil, "BSP lump " .. label .. " is empty" end
        return { buffer = nil, raw = "", bytes = 0 }
    end
    return { buffer = buffer, raw = raw, bytes = #raw }
end

local function readDispInfo(lump, index)
    return readAt(lump, index * SIZE.DISPINFO, function(buffer)
        local startPosition = buffer:ReadVector()
        local dispVertStart = buffer:ReadLong()
        local dispTriStart = buffer:ReadLong()
        local power = buffer:ReadLong()
        local minTess = buffer:ReadLong()
        local smoothingAngle = buffer:ReadFloat()
        local contents = buffer:ReadULong()
        local mapFace = buffer:ReadUShort()
        buffer:ReadUShort() -- 2-byte alignment before the following 32-bit fields.
        local lightmapAlphaStart = buffer:ReadLong()
        local lightmapSamplePositionStart = buffer:ReadLong()
        return {
            startPosition = startPosition,
            dispVertStart = dispVertStart,
            dispTriStart = dispTriStart,
            power = power,
            minTess = minTess,
            smoothingAngle = smoothingAngle,
            contents = contents,
            mapFace = mapFace,
            lightmapAlphaStart = lightmapAlphaStart,
            lightmapSamplePositionStart = lightmapSamplePositionStart
        }
    end)
end

local function readFace(lump, index)
    return readAt(lump, index * SIZE.FACE, function(buffer)
        local face = {}
        face.planeNum = buffer:ReadUShort()
        face.side = buffer:ReadByte()
        face.onNode = buffer:ReadByte()
        face.firstEdge = buffer:ReadLong()
        face.numEdges = buffer:ReadShort()
        face.texInfo = buffer:ReadShort()
        face.dispInfo = buffer:ReadShort()
        face.surfaceFogVolumeID = buffer:ReadShort()
        -- Keep style bytes unsigned: 255 means no style and can be returned
        -- as -1 by signed byte readers. dface_t style bytes start at byte 16.
        local faceByteOffset = index * SIZE.FACE
        face.styles = {
            string.byte(lump.raw, faceByteOffset + 17),
            string.byte(lump.raw, faceByteOffset + 18),
            string.byte(lump.raw, faceByteOffset + 19),
            string.byte(lump.raw, faceByteOffset + 20)
        }
        for _ = 1, 4 do buffer:ReadByte() end -- light styles
        face.lightOfs = buffer:ReadLong()
        face.area = buffer:ReadFloat()
        face.lightmapMins = { buffer:ReadLong(), buffer:ReadLong() }
        face.lightmapSize = { buffer:ReadLong(), buffer:ReadLong() }
        face.origFace = buffer:ReadLong()
        buffer:ReadUShort() -- numPrims
        buffer:ReadUShort() -- firstPrimID
        buffer:ReadULong() -- smoothingGroups
        return face
    end)
end

local function readEdge(lump, index)
    return readAt(lump, index * SIZE.EDGE, function(buffer)
        return buffer:ReadUShort(), buffer:ReadUShort()
    end)
end

local function readSurfEdge(lump, index)
    return readAt(lump, index * SIZE.SURFEDGE, function(buffer)
        return buffer:ReadLong()
    end)
end

local function readVertex(lump, index)
    return readAt(lump, index * SIZE.VERTEX, function(buffer)
        local v = buffer:ReadVector()
        return { v.x, v.y, v.z }
    end)
end

local function readDispVert(lump, index)
    return readAt(lump, index * SIZE.DISPVERT, function(buffer)
        local direction = buffer:ReadVector()
        local distance = buffer:ReadFloat()
        local alpha = buffer:ReadFloat()
        return {
            direction = { direction.x, direction.y, direction.z },
            distance = distance,
            alpha = alpha
        }
    end)
end

local function readDispTriTag(lump, index)
    return readAt(lump, index * SIZE.DISPTRI, function(buffer)
        return buffer:ReadUShort()
    end)
end

local function readTexInfo(lump, index)
    return readAt(lump, index * SIZE.TEXINFO, function(buffer)
        local axes = { {}, {} }
        for axis = 1, 2 do
            for component = 1, 4 do
                axes[axis][component] = buffer:ReadFloat()
            end
        end
        for _ = 1, 8 do buffer:ReadFloat() end -- lightmap axes
        local flags = buffer:ReadLong()
        local texData = buffer:ReadLong()
        return { axes = axes, flags = flags, texData = texData }
    end)
end

local function readTexData(lump, index)
    return readAt(lump, index * SIZE.TEXDATA, function(buffer)
        buffer:ReadVector() -- reflectivity
        return {
            nameStringTableID = buffer:ReadLong(),
            width = buffer:ReadLong(),
            height = buffer:ReadLong(),
            viewWidth = buffer:ReadLong(),
            viewHeight = buffer:ReadLong()
        }
    end)
end

local function getStringFromLumps(stringData, stringTable, stringID)
    if not stringTable or stringTable.bytes < (stringID + 1) * 4 then return nil end
    local offset = readAt(stringTable, stringID * 4, function(buffer)
        return buffer:ReadLong()
    end)
    if not finite(offset) or offset < 0 or offset >= #stringData then return nil end
    local terminator = string.find(stringData, "\0", offset + 1, true)
    if not terminator then return nil end
    return string.sub(stringData, offset + 1, terminator - 1)
end

local function normalizeMaterialName(name)
    if not isstring(name) or name == "" then return DEFAULT_MATERIAL end
    name = string.Trim(name):gsub("\\", "/")
    name = name:gsub("^materials/", ""):gsub("%.vmt$", "")
    if #name > 128 or name:find("..", 1, true) or not name:match("^[%w_/%-%.]+$") then
        return DEFAULT_MATERIAL
    end
    return name
end

local function getSurfaceProp(materialName)
    if materialName == DEFAULT_MATERIAL then return "dirt" end
    local vmt = file.Read("materials/" .. materialName .. ".vmt", "GAME")
    if not isstring(vmt) then return "dirt" end
    local surface = vmt:match('"%$surfaceprop"%s*"([%w_%-]+)"')
        or vmt:match('"%$surfaceprop"%s*([^%s%}]+)')
    if not surface then return "dirt" end
    surface = string.lower(surface):gsub("[^%w_]", "_")
    if #surface == 0 or #surface > 32 then return "dirt" end
    return surface
end

local function getFaceCorners(face, edgesLump, surfEdgesLump, verticesLump)
    if face.numEdges ~= 4 then
        return nil, "displacement parent face does not have four edges"
    end
    if face.firstEdge < 0 then return nil, "negative face firstEdge" end

    local corners = {}
    for edgeOffset = 0, 3 do
        local surfEdge, surfError = readSurfEdge(surfEdgesLump, face.firstEdge + edgeOffset)
        if surfEdge == nil then return nil, "could not read surfedge: " .. tostring(surfError) end
        local edgeIndex = math.abs(surfEdge)
        local v0, v1 = readEdge(edgesLump, edgeIndex)
        if v0 == nil or v1 == nil then return nil, "could not read edge " .. tostring(edgeIndex) end
        local vertexIndex = surfEdge < 0 and v1 or v0
        local point, vertexError = readVertex(verticesLump, vertexIndex)
        if not point then return nil, "could not read face vertex: " .. tostring(vertexError) end
        corners[#corners + 1] = point
    end
    return corners
end

local function rotateCornersToStart(corners, startPosition)
    local bestIndex, bestDistance = 1, math.huge
    for index, point in ipairs(corners) do
        local dx = point[1] - startPosition.x
        local dy = point[2] - startPosition.y
        local dz = point[3] - startPosition.z
        local distance = dx * dx + dy * dy + dz * dz
        if distance < bestDistance then
            bestDistance = distance
            bestIndex = index
        end
    end
    if bestDistance > 1.0 then
        return nil, "displacement startPosition does not match a parent face corner"
    end

    local rotated = {}
    for offset = 0, 3 do
        rotated[#rotated + 1] = corners[((bestIndex + offset - 1) % 4) + 1]
    end
    return rotated
end

local function lerpPoint(a, b, fraction)
    return {
        a[1] + (b[1] - a[1]) * fraction,
        a[2] + (b[2] - a[2]) * fraction,
        a[3] + (b[3] - a[3]) * fraction
    }
end

local function getMaterialInfo(face, texInfoLump, texDataLump, stringData, stringTable)
    if not face or face.texInfo < 0 then
        return DEFAULT_MATERIAL, "dirt", nil
    end
    local texInfo = readTexInfo(texInfoLump, face.texInfo)
    if not texInfo or texInfo.texData < 0 then
        return DEFAULT_MATERIAL, "dirt", nil
    end
    local texData = readTexData(texDataLump, texInfo.texData)
    if not texData then return DEFAULT_MATERIAL, "dirt", nil end

    local rawName = getStringFromLumps(stringData, stringTable, texData.nameStringTableID)
    local materialName = normalizeMaterialName(rawName)
    local surfaceProp = getSurfaceProp(materialName)
    local width = math.max(1, texData.width or 1)
    local height = math.max(1, texData.height or 1)
    return materialName, surfaceProp, {
        axes = texInfo.axes,
        width = width,
        height = height
    }
end

local function readSourceTriangleGridIndices(width, triangleIndex)
    -- Reproduce Source's displacement triangle order used by sh_displacement.lua.
    local resolution = width - 1
    local cellIndex = math.floor(triangleIndex / 2)
    local row = math.floor(cellIndex / resolution) -- zero-based
    local column = cellIndex % resolution          -- zero-based
    if row < 0 or row >= resolution then return nil end

    local i00 = row * width + column + 1
    local i10 = i00 + 1
    local i01 = i00 + width
    local i11 = i01 + 1
    local oddCell = (row * width + column) % 2 == 1

    if oddCell then
        if triangleIndex % 2 == 0 then return { i00, i01, i10 } end
        return { i10, i01, i11 }
    end

    if triangleIndex % 2 == 0 then return { i00, i01, i11 } end
    return { i00, i11, i10 }
end

local function decodeRGBExp32(raw, byteOffset)
    -- byteOffset is zero-based into LUMP_LIGHTING. ColorRGBExp32 is RGBe.
    local position = byteOffset + 1
    if byteOffset < 0 or position + 3 > #raw then return nil end
    local r, g, b, exponent = string.byte(raw, position, position + 3)
    if exponent >= 128 then exponent = exponent - 256 end

    local scale = 2 ^ exponent / 255
    local function toVertexByte(channel)
        local linear = math.max(0, channel * scale)
        -- Source's LinearToVertexLight is a gamma-space conversion. This first
        -- NKM implementation uses the classic 2.2 vertex-light approximation.
        local gamma = linear ^ (1 / 2.2)
        return math.Clamp(math.floor(math.min(1, gamma) * 255 + 0.5), 0, 255)
    end
    return { toVertexByte(r), toVertexByte(g), toVertexByte(b) }
end

local function buildVertexLighting(info, face, width, height, lumps)
    if not face or face.lightOfs == nil or face.lightOfs < 0 then
        return nil, { reason = "face has no LDR lightmap" }
    end
    if not face.styles or face.styles[1] == nil or face.styles[1] == 255 then
        return nil, { reason = "face has no active lightstyle" }
    end
    if not face.lightmapSize or not finite(face.lightmapSize[1]) or not finite(face.lightmapSize[2]) then
        return nil, { reason = "face has invalid lightmap dimensions" }
    end

    local sampleWidth = face.lightmapSize[1] + 1
    local sampleHeight = face.lightmapSize[2] + 1
    if sampleWidth < 1 or sampleHeight < 1 or sampleWidth > 1024 or sampleHeight > 1024 then
        return nil, { reason = "face lightmap dimensions exceed importer safety limits" }
    end
    local sampleCount = sampleWidth * sampleHeight
    if face.lightOfs + sampleCount * 4 > lumps.lighting.bytes then
        return nil, { reason = "LDR lighting samples are outside lump 8" }
    end
    if info.lightmapSamplePositionStart < 0 then
        return nil, { reason = "displacement has no lightmap sample-position offset" }
    end

    local positionLump = lumps.dispLightmapSamplePositions.raw or ""
    local cursor = info.lightmapSamplePositionStart + 1 -- BSP offset is byte-based.
    local accum = {}
    for vertexIndex = 1, width * height do
        accum[vertexIndex] = { 0, 0, 0, 0 }
    end

    local usedSamples, invalidSamples = 0, 0
    local triangleCount = (width - 1) * (height - 1) * 2
    for sampleIndex = 0, sampleCount - 1 do
        if cursor > #positionLump then
            return nil, { reason = "DISP_LIGHTMAP_SAMPLE_POSITIONS ended before face sample count" }
        end

        local triangleIndex = string.byte(positionLump, cursor)
        cursor = cursor + 1
        if triangleIndex == 255 then
            if cursor > #positionLump then
                return nil, { reason = "truncated extended displacement lightmap triangle index" }
            end
            triangleIndex = 255 + string.byte(positionLump, cursor)
            cursor = cursor + 1
        end
        if cursor + 2 > #positionLump then
            return nil, { reason = "truncated displacement lightmap barycentric sample" }
        end
        local b0, b1, b2 = string.byte(positionLump, cursor, cursor + 2)
        cursor = cursor + 3

        local baryTotal = b0 + b1 + b2
        if baryTotal > 0 and triangleIndex < triangleCount then
            local color = decodeRGBExp32(lumps.lighting.raw, face.lightOfs + sampleIndex * 4)
            local indices = readSourceTriangleGridIndices(width, triangleIndex)
            if color and indices then
                local weights = { b0 / baryTotal, b1 / baryTotal, b2 / baryTotal }
                for corner = 1, 3 do
                    local target = accum[indices[corner]]
                    local weight = weights[corner]
                    target[1] = target[1] + color[1] * weight
                    target[2] = target[2] + color[2] * weight
                    target[3] = target[3] + color[3] * weight
                    target[4] = target[4] + weight
                end
                usedSamples = usedSamples + 1
            else
                invalidSamples = invalidSamples + 1
            end
        end
    end

    if usedSamples == 0 then
        return nil, { reason = "no usable displacement lightmap samples", samples = sampleCount, invalidSamples = invalidSamples }
    end

    local vertexLighting = {}
    local litVertices = 0
    for index, value in ipairs(accum) do
        if value[4] > 0.000001 then
            vertexLighting[index] = {
                math.Clamp(math.floor(value[1] / value[4] + 0.5), 0, 255),
                math.Clamp(math.floor(value[2] / value[4] + 0.5), 0, 255),
                math.Clamp(math.floor(value[3] / value[4] + 0.5), 0, 255)
            }
            litVertices = litVertices + 1
        end
    end

    -- Lightmap sampling can leave a few boundary grid vertices without a direct
    -- barycentric contribution. Fill those from the nearest sampled grid vertex
    -- to avoid black pinholes in the per-vertex approximation.
    if litVertices > 0 and litVertices < width * height then
        for index = 1, width * height do
            if not vertexLighting[index] then
                local x = (index - 1) % width
                local y = math.floor((index - 1) / width)
                local bestIndex, bestDistance = nil, math.huge
                for candidate, candidateColor in pairs(vertexLighting) do
                    local cx = (candidate - 1) % width
                    local cy = math.floor((candidate - 1) / width)
                    local distance = math.abs(cx - x) + math.abs(cy - y)
                    if distance < bestDistance then
                        bestDistance, bestIndex = distance, candidate
                    end
                end
                local color = vertexLighting[bestIndex]
                vertexLighting[index] = { color[1], color[2], color[3] }
            end
        end
        litVertices = width * height
    end

    return vertexLighting, {
        samples = sampleCount,
        usedSamples = usedSamples,
        invalidSamples = invalidSamples,
        litVertices = litVertices,
        sampleWidth = sampleWidth,
        sampleHeight = sampleHeight,
        style = face.styles[1]
    }
end

local function buildDisplacementPatch(index, info, lumps)
    if info.power < 2 or info.power > 4 then
        return nil, "unsupported displacement power " .. tostring(info.power)
    end

    local side = 2 ^ info.power + 1
    local resolution = side - 1
    local vertexCount = side * side
    local triangleCount = resolution * resolution * 2
    if info.dispVertStart < 0 or (info.dispVertStart + vertexCount) * SIZE.DISPVERT > lumps.dispVerts.bytes then
        return nil, "displacement vertex range is outside lump 33"
    end
    if info.dispTriStart < 0 or (info.dispTriStart + triangleCount) * SIZE.DISPTRI > lumps.dispTris.bytes then
        return nil, "displacement triangle range is outside lump 48"
    end
    if info.mapFace >= math.floor(lumps.faces.bytes / SIZE.FACE) then
        return nil, "displacement mapFace is outside lump 7"
    end

    local face, faceError = readFace(lumps.faces, info.mapFace)
    if not face then return nil, "could not read parent face: " .. tostring(faceError) end
    local corners, cornerError = getFaceCorners(face, lumps.edges, lumps.surfEdges, lumps.vertices)
    if not corners then return nil, cornerError end
    corners, cornerError = rotateCornersToStart(corners, info.startPosition)
    if not corners then return nil, cornerError end

    local p0, p1, p2, p3 = corners[1], corners[2], corners[3], corners[4]
    local materialName, surfaceProp, texture = getMaterialInfo(
        face, lumps.texInfo, lumps.texData, lumps.texDataString, lumps.texDataStringTable
    )

    local patch = {
        id = "bspdisp_" .. tostring(index - 1),
        sourceType = "BSPDisplacement",
        sourceDispInfo = index - 1,
        sourceFace = info.mapFace,
        power = info.power,
        width = side,
        height = side,
        vertices = {},
        uvs = {},
        vertexAlphas = {},
        triangleTags = {},
        material = materialName,
        surface = surfaceProp,
        color = { 255, 255, 255, 255 },
        collision = true,
        physicsCollision = bit.band(info.contents, 2) == 0,
        hullCollision = bit.band(info.contents, 4) == 0,
        rayCollision = bit.band(info.contents, 8) == 0,
        triangleLayout = "source",
        flipWinding = true,
        smoothNormals = true
    }

    -- Source stores displacement vertices row-major (y * side + x).
    -- The start corner is Source corner 0; x runs toward corner 3 and y
    -- runs toward corner 1. Keep the grid's x/y order intact for triangle tags.
    for y = 0, resolution do
        local v = y / resolution
        for x = 0, resolution do
            local u = x / resolution
            local edgeA = lerpPoint(p0, p3, u)
            local edgeB = lerpPoint(p1, p2, u)
            local base = lerpPoint(edgeA, edgeB, v)
            local sourceIndex = y * side + x
            local dispVert, dispError = readDispVert(lumps.dispVerts, info.dispVertStart + sourceIndex)
            if not dispVert then return nil, "could not read displacement vertex: " .. tostring(dispError) end
            if not finite(dispVert.distance) then return nil, "non-finite displacement distance" end

            local point = {
                base[1] + dispVert.direction[1] * dispVert.distance,
                base[2] + dispVert.direction[2] * dispVert.distance,
                base[3] + dispVert.direction[3] * dispVert.distance
            }
            patch.vertices[#patch.vertices + 1] = point
            -- Source DispVert alpha is the per-vertex blend weight used by
            -- WorldVertexTransition displacement materials (0..255).
            patch.vertexAlphas[#patch.vertexAlphas + 1] = math.Clamp(dispVert.alpha or 255, 0, 255)

            if texture then
                local sAxis, tAxis = texture.axes[1], texture.axes[2]
                local uCoord = (sAxis[1] * point[1] + sAxis[2] * point[2] + sAxis[3] * point[3] + sAxis[4]) / texture.width
                local vCoord = (tAxis[1] * point[1] + tAxis[2] * point[2] + tAxis[3] * point[3] + tAxis[4]) / texture.height
                patch.uvs[#patch.uvs + 1] = { uCoord, vCoord }
            else
                patch.uvs[#patch.uvs + 1] = { x / resolution * 8, y / resolution * 8 }
            end
        end
    end

    local vertexLighting, lightingStats = buildVertexLighting(info, face, side, side, lumps)
    if vertexLighting then
        patch.vertexLighting = vertexLighting
        patch.lightmap = {
            source = "BSP_LDR_RGBExp32",
            style = lightingStats.style,
            sampleWidth = lightingStats.sampleWidth,
            sampleHeight = lightingStats.sampleHeight,
            samples = lightingStats.samples,
            usedSamples = lightingStats.usedSamples,
            approximation = "barycentric-to-vertex"
        }
    end

    for triangleIndex = 0, triangleCount - 1 do
        local tag, tagError = readDispTriTag(lumps.dispTris, info.dispTriStart + triangleIndex)
        if tag == nil then return nil, "could not read displacement triangle tag: " .. tostring(tagError) end
        patch.triangleTags[#patch.triangleTags + 1] = tag
    end

    return patch, {
        vertices = vertexCount,
        triangles = triangleCount,
        removedTriangles = (function()
            local count = 0
            for _, tag in ipairs(patch.triangleTags) do
                if bit.band(tag, TAG_REMOVE) ~= 0 then count = count + 1 end
            end
            return count
        end)(),
        physicsCollision = patch.physicsCollision,
        hullCollision = patch.hullCollision,
        rayCollision = patch.rayCollision,
        power = info.power,
        material = materialName,
        surface = surfaceProp,
        lighting = lightingStats or { reason = "not available" }
    }
end

local function loadImporterLumps(bsp)
    local required = {
        { "dispInfo", LUMP.DISPINFO, "dispinfo", true },
        { "dispVerts", LUMP.DISP_VERTS, "dispverts", true },
        { "dispTris", LUMP.DISP_TRIS, "disptris", true },
        { "faces", LUMP.FACES, "faces", true },
        { "edges", LUMP.EDGES, "edges", true },
        { "surfEdges", LUMP.SURFEDGES, "surfedges", true },
        { "vertices", LUMP.VERTEXES, "vertices", true },
        { "texInfo", LUMP.TEXINFO, "texinfo", false },
        { "texData", LUMP.TEXDATA, "texdata", false },
        { "texDataStringTable", LUMP.TEXDATA_STRING_TABLE, "texdata string table", false },
        { "lighting", LUMP.LIGHTING, "LDR lighting", false },
        { "dispLightmapSamplePositions", LUMP.DISP_LIGHTMAP_SAMPLE_POSITIONS, "displacement lightmap sample positions", false }
    }

    local lumps = {}
    for _, spec in ipairs(required) do
        local lump, err = loadLump(bsp, spec[2], spec[3], spec[4])
        if not lump then return nil, err end
        lumps[spec[1]] = lump
    end
    local stringData, err = loadLump(bsp, LUMP.TEXDATA_STRING_DATA, "texdata string data", false)
    if not stringData then return nil, err end
    lumps.texDataString = stringData.raw or ""

    if lumps.dispInfo.bytes % SIZE.DISPINFO ~= 0 then
        return nil, "unexpected DISPINFO lump length; expected 176-byte records"
    end
    if lumps.faces.bytes % SIZE.FACE ~= 0 then return nil, "unexpected FACES lump length" end
    if lumps.edges.bytes % SIZE.EDGE ~= 0 then return nil, "unexpected EDGES lump length" end
    if lumps.surfEdges.bytes % SIZE.SURFEDGE ~= 0 then return nil, "unexpected SURFEDGES lump length" end
    if lumps.vertices.bytes % SIZE.VERTEX ~= 0 then return nil, "unexpected VERTEXES lump length" end
    if lumps.dispVerts.bytes % SIZE.DISPVERT ~= 0 then return nil, "unexpected DISP_VERTS lump length" end
    if lumps.dispTris.bytes % SIZE.DISPTRI ~= 0 then return nil, "unexpected DISP_TRIS lump length" end
    if lumps.texInfo.bytes > 0 and lumps.texInfo.bytes % SIZE.TEXINFO ~= 0 then return nil, "unexpected TEXINFO lump length" end
    if lumps.texData.bytes > 0 and lumps.texData.bytes % SIZE.TEXDATA ~= 0 then return nil, "unexpected TEXDATA lump length" end
    if lumps.texDataStringTable.bytes > 0 and lumps.texDataStringTable.bytes % 4 ~= 0 then return nil, "unexpected TEXDATA_STRING_TABLE lump length" end
    return lumps
end

function NKM.GetCurrentBSPDisplacementInfo()
    local bsp, bspError = getCurrentBSP()
    if not bsp then return nil, bspError end
    local dispInfo, err = loadLump(bsp, LUMP.DISPINFO, "dispinfo", true)
    if not dispInfo then return nil, err end
    if dispInfo.bytes % SIZE.DISPINFO ~= 0 then
        return nil, "unexpected DISPINFO lump length; expected 176-byte records"
    end

    local count = dispInfo.bytes / SIZE.DISPINFO
    local powerCounts = {}
    local invalid = 0
    local noPhysicsCollision, noHullCollision, noRayCollision = 0, 0, 0
    for index = 0, count - 1 do
        local info = readDispInfo(dispInfo, index)
        if info and info.power >= 2 and info.power <= 4 then
            powerCounts[info.power] = (powerCounts[info.power] or 0) + 1
            if bit.band(info.contents, 2) ~= 0 then noPhysicsCollision = noPhysicsCollision + 1 end
            if bit.band(info.contents, 4) ~= 0 then noHullCollision = noHullCollision + 1 end
            if bit.band(info.contents, 8) ~= 0 then noRayCollision = noRayCollision + 1 end
        else
            invalid = invalid + 1
        end
    end
    local mapName = bsp.GetMapName and bsp:GetMapName() or game.GetMap()
    return {
        mapName = mapName,
        bspVersion = bsp.GetVersion and bsp:GetVersion() or nil,
        displacementCount = count,
        powerCounts = powerCounts,
        invalidCount = invalid,
        noPhysicsCollision = noPhysicsCollision,
        noHullCollision = noHullCollision,
        noRayCollision = noRayCollision
    }
end

function NKM.ImportCurrentBSPDisplacements(outputName, maxPatches)
    local bsp, bspError = getCurrentBSP()
    if not bsp then return false, bspError end

    maxPatches = math.floor(tonumber(maxPatches) or DEFAULT_IMPORT_PATCH_LIMIT)
    maxPatches = math.Clamp(maxPatches, 1, NKM.MaxDisplacementPatches or 256)

    local lumps, lumpError = loadImporterLumps(bsp)
    if not lumps then return false, lumpError end

    local infoCount = lumps.dispInfo.bytes / SIZE.DISPINFO
    if infoCount == 0 then return false, "current BSP contains no displacement records" end

    local sourceMapName = bsp.GetMapName and bsp:GetMapName() or game.GetMap()
    outputName = outputName or ("bspdisp_" .. string.lower(sourceMapName or "map"))
    outputName = string.lower(outputName):gsub("[^%w_%-]", "_"):sub(1, 48)
    if not NKM.IsValidMapName(outputName) then return false, "invalid output NKM map name" end

    local patches = {}
    local stats = {
        sourceMap = sourceMapName,
        sourceDisplacements = infoCount,
        importedDisplacements = 0,
        skippedDisplacements = 0,
        vertices = 0,
        triangles = 0,
        removedTriangles = 0,
        noPhysicsCollision = 0,
        noHullCollision = 0,
        noRayCollision = 0,
        lightmappedPatches = 0,
        lightmapSamples = 0,
        litVertices = 0,
        lightingSkipped = 0,
        lightingSkipReasons = {},
        powers = {},
        materials = {},
        errors = {}
    }

    for index = 0, infoCount - 1 do
        if #patches >= maxPatches then
            stats.skippedDisplacements = stats.skippedDisplacements + (infoCount - index)
            break
        end

        local info, infoError = readDispInfo(lumps.dispInfo, index)
        if not info then
            stats.skippedDisplacements = stats.skippedDisplacements + 1
            if #stats.errors < 16 then
                stats.errors[#stats.errors + 1] = "disp " .. tostring(index) .. ": " .. tostring(infoError)
            end
        else
            local patch, patchStats = buildDisplacementPatch(index + 1, info, lumps)
            if patch then
                patches[#patches + 1] = patch
                stats.importedDisplacements = stats.importedDisplacements + 1
                stats.vertices = stats.vertices + patchStats.vertices
                stats.triangles = stats.triangles + patchStats.triangles
                stats.removedTriangles = stats.removedTriangles + patchStats.removedTriangles
                if not patchStats.physicsCollision then stats.noPhysicsCollision = stats.noPhysicsCollision + 1 end
                if not patchStats.hullCollision then stats.noHullCollision = stats.noHullCollision + 1 end
                if not patchStats.rayCollision then stats.noRayCollision = stats.noRayCollision + 1 end
                stats.powers[patchStats.power] = (stats.powers[patchStats.power] or 0) + 1
                stats.materials[patchStats.material] = (stats.materials[patchStats.material] or 0) + 1
                if patchStats.lighting and patchStats.lighting.usedSamples then
                    stats.lightmappedPatches = stats.lightmappedPatches + 1
                    stats.lightmapSamples = stats.lightmapSamples + patchStats.lighting.usedSamples
                    stats.litVertices = stats.litVertices + (patchStats.lighting.litVertices or 0)
                else
                    stats.lightingSkipped = stats.lightingSkipped + 1
                    local reason = patchStats.lighting and patchStats.lighting.reason or "unknown"
                    stats.lightingSkipReasons[reason] = (stats.lightingSkipReasons[reason] or 0) + 1
                end
            else
                stats.skippedDisplacements = stats.skippedDisplacements + 1
                if #stats.errors < 16 then
                    stats.errors[#stats.errors + 1] = "disp " .. tostring(index) .. ": " .. tostring(patchStats)
                end
            end
        end
    end

    if #patches == 0 then return false, "no displacement could be imported; check BSP version/lumps and see nkm_bspdisp_info" end

    local mapTable = {
        format = NKM.FormatMagic,
        version = NKM.Version,
        name = outputName,
        description = "Imported Source BSP displacements from " .. tostring(sourceMapName),
        source = {
            type = "SourceBSP",
            map = sourceMapName,
            importer = NKM.RuntimeVersion
        },
        chunkSize = NKM.DefaultChunkSize,
        meshes = {},
        collision = {},
        displacements = patches
    }

    local writeOK, writeResult = NKM.WriteMap(outputName, mapTable)
    if not writeOK then
        return false, "NKM export failed: " .. tostring(writeResult) .. " (try a lower patch limit)"
    end

    local loadOK, loadResult = NKM.LoadMap(outputName)
    if not loadOK then
        return false, "NKM file was written but runtime load failed: " .. tostring(loadResult)
    end

    stats.outputName = outputName
    stats.fileBytes = writeResult
    NKM.BSPDisplacementImport.LastStats = stats
    return true, stats
end

local function canUseImporterCommand(ply)
    return not IsValid(ply) or ply:IsAdmin()
end

concommand.Add("nkm_bspdisp_info", function(ply)
    if not canUseImporterCommand(ply) then return end
    local info, err = NKM.GetCurrentBSPDisplacementInfo()
    if not info then
        print("[NKM] BSP displacement inspection failed: " .. tostring(err))
        return
    end
    print(string.format(
        "[NKM] BSP '%s': version=%s displacements=%d invalid=%d power2=%d power3=%d power4=%d noPhysics=%d noHull=%d noRay=%d",
        tostring(info.mapName), tostring(info.bspVersion or "unknown"), info.displacementCount,
        info.invalidCount, info.powerCounts[2] or 0, info.powerCounts[3] or 0, info.powerCounts[4] or 0,
        info.noPhysicsCollision, info.noHullCollision, info.noRayCollision
    ))
end)

concommand.Add("nkm_import_bsp_displacements", function(ply, _, args)
    if not canUseImporterCommand(ply) then return end
    local outputName = args[1]
    local maxPatches = tonumber(args[2])
    print("[NKM] Reading current BSP displacement lumps through NikNaks...")
    print("[NKM] Default import limit is 64 patches; pass a larger limit explicitly if the map validates within NKM limits.")
    local startedAt = SysTime()
    local ok, result = NKM.ImportCurrentBSPDisplacements(outputName, maxPatches)
    if not ok then
        print("[NKM] BSP displacement import failed: " .. tostring(result))
        return
    end

    print(string.format(
        "[NKM] Imported BSP displacements: map=%s -> NKM=%s patches=%d/%d skipped=%d vertices=%d triangles=%d removed=%d noPhysics=%d noHull=%d noRay=%d file=%d bytes time=%.2fms",
        tostring(result.sourceMap), tostring(result.outputName), result.importedDisplacements,
        result.sourceDisplacements, result.skippedDisplacements, result.vertices, result.triangles,
        result.removedTriangles, result.noPhysicsCollision, result.noHullCollision, result.noRayCollision,
        result.fileBytes, (SysTime() - startedAt) * 1000
    ))
    print(string.format("[NKM] BSP LDR lighting: patches=%d/%d samples=%d vertexColors=%d skipped=%d",
        result.lightmappedPatches or 0, result.importedDisplacements, result.lightmapSamples or 0,
        result.litVertices or 0, result.lightingSkipped or 0))
    for reason, count in pairs(result.lightingSkipReasons or {}) do
        print(string.format("[NKM] BSP lighting skipped: %s (%d patches)", tostring(reason), count))
    end
    print("[NKM] Runtime loaded. Inspect with nkm_status, nkm_server_chunks and nkm_trace_test.")
    for index, message in ipairs(result.errors or {}) do
        print("[NKM] Import warning " .. index .. ": " .. message)
    end
end)
