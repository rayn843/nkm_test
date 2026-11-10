-- Synthetic Source BSP displacement-lump test for NKM 0.9.7.
-- Run with: texlua tests/bsp_import.lua

SERVER = true

function istable(v) return type(v) == "table" end
function isstring(v) return type(v) == "string" end
function isnumber(v) return type(v) == "number" end
function isbool(v) return type(v) == "boolean" end
function isfunction(v) return type(v) == "function" end
local vectorMT = {}
vectorMT.__index = function(v, key)
    if key == "Cross" then
        return function(a, b)
            return Vector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        end
    end
    if key == "LengthSqr" then
        return function(a) return a.x * a.x + a.y * a.y + a.z * a.z end
    end
    if key == "Normalize" then
        return function(a)
            local length = math.sqrt(a:LengthSqr())
            if length > 0 then a.x, a.y, a.z = a.x / length, a.y / length, a.z / length end
            return length
        end
    end
    return rawget(v, key)
end
vectorMT.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
vectorMT.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vector(x, y, z) return setmetatable({ x = x, y = y, z = z }, vectorMT) end

math.Clamp = function(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

string.Trim = function(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

bit = { band = function(a, b) return a & b end }
file = {
    Read = function(path, realm)
        if path:find("grass_ground01", 1, true) then
            return '"LightmappedGeneric" { "$surfaceprop" "dirt" }'
        end
        return nil
    end
}
concommand = { Add = function() end }

local function pack(fmt, ...)
    return string.pack("<" .. fmt, ...)
end

local function makeLumpBuffer(raw)
    local buffer = { raw = raw, offset = 1 }
    function buffer:Seek(bitOffset)
        self.offset = math.floor(bitOffset / 8) + 1
    end
    local function read(self, fmt)
        local value
        value, self.offset = string.unpack("<" .. fmt, self.raw, self.offset)
        return value
    end
    function buffer:ReadLong() return read(self, "i4") end
    function buffer:ReadULong() return read(self, "I4") end
    function buffer:ReadShort() return read(self, "i2") end
    function buffer:ReadUShort() return read(self, "I2") end
    function buffer:ReadByte() return read(self, "I1") end
    function buffer:ReadFloat() return read(self, "f") end
    function buffer:ReadVector()
        return { x = self:ReadFloat(), y = self:ReadFloat(), z = self:ReadFloat() }
    end
    function buffer:SetLittleEndian() end
    return buffer
end

local function makeDispInfo(contents)
    contents = contents or 0
    local head = pack("fffiiiifii2i2ii", 0, 0, 0, 0, 0, 2, 0, 45, contents, 0, 0, -1, 0)
    -- 48 bytes of primary fields + 128 bytes of neighbors/allowed-vertex data.
    assert(#head == 48, "bad synthetic ddispinfo header size: " .. #head)
    return head .. string.rep("\0", 128)
end

local function makeFace()
    return pack(
        "I2I1I1i4i2i2i2i2I1I1I1I1i4fi4i4i4i4i4I2I2I4",
        0, 0, 0, 0, 4, 0, 0, 0,
        0, 255, 255, 255, 0, 10000,
        0, 0, 16, 16, -1, 0, 0, 0
    )
end

local lumps = {}
lumps[26] = makeDispInfo(0)
lumps[7] = makeFace()
lumps[12] = table.concat({
    pack("I2I2", 0, 1), pack("I2I2", 1, 2),
    pack("I2I2", 2, 3), pack("I2I2", 3, 0)
})
lumps[13] = pack("i4i4i4i4", 0, 1, 2, 3)
-- Source face corner order for an upward-facing plane: 0=bottom-left,
-- 1=top-left, 2=top-right, 3=bottom-right (clockwise from above).
lumps[3] = table.concat({
    pack("fff", 0, 0, 0), pack("fff", 0, 100, 0),
    pack("fff", 100, 100, 0), pack("fff", 100, 0, 0)
})

local dispVerts = {}
for y = 0, 4 do
    for x = 0, 4 do
        local distance = math.sin(x * math.pi / 4) * math.cos(y * math.pi / 4) * 8
        local alpha = ((x + y) % 2) * 255
        dispVerts[#dispVerts + 1] = pack("fffff", 0, 0, 1, distance, alpha)
    end
end
lumps[33] = table.concat(dispVerts)
local dispTris = {}
for _ = 1, 32 do dispTris[#dispTris + 1] = pack("I2", 0) end
lumps[48] = table.concat(dispTris)
-- 17x17 face lightmap samples. Every sample lands on triangle 0 with
-- barycentric weights (85,85,85), giving a deterministic non-white vertex color.
local lightSamples = {}
local samplePositions = {}
for _ = 1, 17 * 17 do
    lightSamples[#lightSamples + 1] = string.char(96, 96, 96, 0) -- RGBExp32
    samplePositions[#samplePositions + 1] = string.char(0, 85, 85, 85)
end
lumps[8] = table.concat(lightSamples)
lumps[34] = table.concat(samplePositions)
lumps[6] = pack("ffffffffffffffffi4i4",
    1, 0, 0, 0, 0, 1, 0, 0,
    1, 0, 0, 0, 0, 1, 0, 0,
    0, 0
)
lumps[2] = pack("fffi4i4i4i4i4", 1, 1, 1, 0, 128, 128, 128, 128)
lumps[43] = "nature/grass_ground01\0"
lumps[44] = pack("i4", 0)

local bsp = {}
function bsp:GetLumpString(id) return lumps[id] or "" end
function bsp:GetMapName() return "synthetic_fixture" end
function bsp:GetVersion() return 20 end
NikNaks = {
    CurrentMap = bsp,
    BitBuffer = function(raw, littleEndian)
        assert(littleEndian == true)
        return makeLumpBuffer(raw)
    end
}

NKM = {}
dofile("lua/nkm/sh_core.lua")
dofile("lua/nkm/sh_displacement.lua")

local writtenMap
NKM.WriteMap = function(name, mapTable)
    writtenMap = mapTable
    return true, 12345
end
NKM.LoadMap = function(name)
    assert(name == "bsp_import_test" or name == "bsp_import_no_collision" or name == "bsp_import_no_lightmap")
    return true, "loaded"
end

dofile("lua/nkm/sv_bsp_import.lua")

local info, infoError = NKM.GetCurrentBSPDisplacementInfo()
assert(info, tostring(infoError))
assert(info.displacementCount == 1)
assert(info.powerCounts[2] == 1)
assert(info.noPhysicsCollision == 0 and info.noHullCollision == 0 and info.noRayCollision == 0)

local ok, result = NKM.ImportCurrentBSPDisplacements("bsp_import_test", 1)
assert(ok, tostring(result))
assert(writtenMap and writtenMap.name == "bsp_import_test")
assert(#writtenMap.displacements == 1)
local patch = writtenMap.displacements[1]
assert(patch.width == 5 and patch.height == 5)
assert(#patch.vertices == 25)
assert(#patch.uvs == 25)
assert(#patch.vertexAlphas == 25, "BSP vertex blend alpha was not preserved")
assert(patch.vertexAlphas[1] == 0 and patch.vertexAlphas[2] == 255, "BSP vertex blend alpha values changed")
assert(type(patch.vertexLighting) == "table" and #patch.vertexLighting == 25, "BSP LDR lightmap was not transferred to grid vertices")
assert(patch.lightmap and patch.lightmap.source == "BSP_LDR_RGBExp32", "BSP lightmap metadata missing")
assert(patch.lightmap.samples == 289 and patch.lightmap.usedSamples == 289, "BSP lightmap sample mapping count changed")
assert(patch.vertexLighting[1][1] > 0 and patch.vertexLighting[1][1] < 255, "RGBExp32 light sample conversion should produce a midtone vertex color")
assert(#patch.triangleTags == 32)
assert(patch.material == "nature/grass_ground01")
assert(patch.sourceType == "BSPDisplacement", "imported patch missing BSP source marker")
assert(patch.surface == "dirt")
assert(patch.collision == true and patch.flipWinding == true)
assert(patch.triangleLayout == "source")
assert(patch.physicsCollision == true and patch.hullCollision == true and patch.rayCollision == true)
-- Row-major Source grid: vertex #2 advances toward Source corner 3 (+X),
-- while vertex #6 starts the next row toward Source corner 1 (+Y).
assert(math.abs(patch.vertices[2][1] - 25) < 0.001 and math.abs(patch.vertices[2][2]) < 0.001)
assert(math.abs(patch.vertices[6][1]) < 0.001 and math.abs(patch.vertices[6][2] - 25) < 0.001)
local valid, validationError = NKM.ValidateMap(writtenMap)
assert(valid, tostring(validationError))
local importedChunks = assert(NKM.BuildChunks(writtenMap))
local foundImportedRenderGroup = false
for _, chunk in ipairs(importedChunks) do
    for _, group in ipairs(chunk.meshes or {}) do
        if group.isBSPDisplacement == true and group.sourcePatchID == patch.sourceDispInfo then
            foundImportedRenderGroup = true
        end
    end
end
assert(foundImportedRenderGroup, "BSP source marker was not propagated to render chunk metadata")
local importedVertexAlphaFound = false
for _, chunk in ipairs(importedChunks) do
    for _, group in ipairs(chunk.meshes or {}) do
        for _, vertex in ipairs(group.vertices or {}) do
            assert(vertex.blendAlpha == 0 or vertex.blendAlpha == 255, "BSP blend alpha did not reach render vertex")
            assert(type(vertex.color) == "table" and vertex.color[1] > 0 and vertex.color[1] < 255,
                "BSP baked vertex lighting did not reach render geometry")
            importedVertexAlphaFound = true
        end
    end
end
assert(importedVertexAlphaFound, "no imported render vertices were generated")
assert(result.importedDisplacements == 1)
assert(result.vertices == 25 and result.triangles == 32)
assert(result.removedTriangles == 0)
assert(result.lightmappedPatches == 1 and result.lightmapSamples == 289,
    "BSP lightmap import summary was not populated")

-- Source contents bits 2/4/8 disable physics props, player/NPC hulls and rays.
lumps[26] = makeDispInfo(2 + 4 + 8)
local disabledInfo = assert(NKM.GetCurrentBSPDisplacementInfo())
assert(disabledInfo.noPhysicsCollision == 1 and disabledInfo.noHullCollision == 1 and disabledInfo.noRayCollision == 1)
local noCollisionOK, noCollisionResult = NKM.ImportCurrentBSPDisplacements("bsp_import_no_collision", 1)
assert(noCollisionOK, tostring(noCollisionResult))
local noCollisionPatch = writtenMap.displacements[1]
assert(noCollisionPatch.physicsCollision == false)
assert(noCollisionPatch.hullCollision == false)
assert(noCollisionPatch.rayCollision == false)

print(string.format(
    "PASS: BSP=%s displacements=%d imported=%d grid=%dx%d vertices=%d triangles=%d material=%s surface=%s",
    info.mapName, info.displacementCount, result.importedDisplacements,
    patch.width, patch.height, result.vertices, result.triangles, patch.material, patch.surface
))


-- Missing optional LDR lighting must not prevent geometry-only BSP conversion.
lumps[8] = ""
local noLightmapOK, noLightmapResult = NKM.ImportCurrentBSPDisplacements("bsp_import_no_lightmap", 1)
assert(noLightmapOK, tostring(noLightmapResult))
local noLightmapPatch = writtenMap.displacements[1]
assert(noLightmapPatch.vertexLighting == nil, "missing LDR lightmap must not create fabricated vertex lighting")
assert(noLightmapResult.lightmappedPatches == 0 and noLightmapResult.lightingSkipped == 1,
    "missing LDR lightmap must be reported as a skipped lighting patch")
assert(noLightmapResult.lightingSkipReasons["LDR lighting samples are outside lump 8"] == 1,
    "missing LDR lighting skip reason was not reported")
