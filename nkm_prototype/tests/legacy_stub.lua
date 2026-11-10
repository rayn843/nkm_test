local mt = {}
mt.__index = function(v, key)
    if key == "Dot" then return function(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end end
    if key == "Cross" then return function(a,b) return Vector(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) end end
    if key == "LengthSqr" then return function(a) return a.x*a.x+a.y*a.y+a.z*a.z end end
    if key == "Normalize" then return function(a) local l=math.sqrt(a:LengthSqr()); if l>0 then a.x=a.x/l; a.y=a.y/l; a.z=a.z/l end; return l end end
    if key == "DistToSqr" then return function(a,b) local x=a.x-b.x; local y=a.y-b.y; local z=a.z-b.z; return x*x+y*y+z*z end end
    return rawget(v,key)
end
mt.__add = function(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
mt.__sub = function(a,b) return Vector(a.x-b.x,a.y-b.y,a.z-b.z) end
mt.__unm = function(a) return Vector(-a.x,-a.y,-a.z) end
mt.__mul = function(a,b) if type(a)=="number" then return Vector(a*b.x,a*b.y,a*b.z) end; if type(b)=="number" then return Vector(a.x*b,a.y*b,a.z*b) end end
mt.__div = function(a,b) return Vector(a.x/b,a.y/b,a.z/b) end
function Vector(x,y,z) return setmetatable({x=x,y=y,z=z},mt) end
function isvector(v) return type(v)=="table" and getmetatable(v)==mt end
function istable(v) return type(v)=="table" end
function isnumber(v) return type(v)=="number" end
function isstring(v) return type(v)=="string" end
function isbool(v) return type(v)=="boolean" end
function isfunction(v) return type(v)=="function" end
function isentity(v) return false end
bit = { band = function(a,b) return a & b end }
math.Clamp = function(x,lo,hi) if x<lo then return lo elseif x>hi then return hi end return x end
MAT_DEFAULT = 0
NULL = {}
NKM = {
    Name="NKM Test", Version=1, RuntimeVersion="0.9.7", FormatMagic="NKM",
    DefaultChunkSize=512, MaxChunks=2048, MaxVertices=250000,
    MaxCollisionConvexes=128, MaxCollisionPointsPerConvex=32,
    MeshVertexLimit=60000
}
function NKM.ValidateMap(map)
    if map.format ~= "NKM" or map.version ~= 1 or type(map.name) ~= "string" then return false,"base" end
    if type(map.meshes) ~= "table" or #map.meshes == 0 then return false,"empty mesh" end
    for _, m in ipairs(map.meshes) do
        if type(m.vertices) ~= "table" then return false,"vertices" end
    end
    return true, 3
end
function NKM.BuildChunks(map, requested)
    return {}, {chunkSize=requested or map.chunkSize or 512, chunkCount=0, meshGroups=0, collisionConvexes=0, collisionChunks=0}
end

dofile("lua/nkm/sh_displacement.lua")
local map = NKM.BuildDisplacementTestMap(Vector(0,0,0))
local valid, detail = NKM.ValidateMap(map)
assert(valid, tostring(detail))
assert(#map.meshes == 0)
assert(map.displacements[1].width == 25 and map.displacements[1].height == 25)
local chunks, stats = NKM.BuildChunks(map)
assert(chunks and #chunks > 0)
local totalTriangles, totalRenderVertices, totalPatches = 0, 0, 0
for _, chunk in ipairs(chunks) do
    for _, group in ipairs(chunk.meshes) do totalRenderVertices = totalRenderVertices + #group.vertices end
    for _, surface in ipairs(chunk.triangleSurfaces) do
        totalTriangles = totalTriangles + #surface.vertices / 3
        totalPatches = totalPatches + 1
    end
end
assert(totalTriangles == 1152, "expected 1152 triangles, got "..totalTriangles)
assert(totalRenderVertices == 3456, "expected 3456 render vertices, got "..totalRenderVertices)
assert(totalPatches > 0)

dofile("lua/nkm/sh_trace.lua")
local traceMap, traceError = NKM.BuildTraceData(map, map.name, chunks)
assert(traceMap, tostring(traceError))
assert(#traceMap.triangles == 1152, "trace triangles mismatch")
NKM.TraceMap = traceMap
local patch = map.displacements[1]
local step = 1024 / 24
local x = -512 + 10.5 * step
local y = -512 + 12.25 * step
local startPos = Vector(x,y,500)
local endPos = Vector(x,y,-500)
local trace = NKM.TraceLine({start=startPos,endpos=endPos,nkmOnly=true})
assert(trace.Hit and trace.HitNKM, "vertical trace did not hit displacement")
assert(trace.NKM and trace.NKM.TriangleIndex, "triangle metadata missing")
local hullTrace = NKM.TraceHull({start=startPos,endpos=endPos,mins=Vector(-8,-8,-8),maxs=Vector(8,8,8),nkmOnly=true})
assert(hullTrace.Hit and hullTrace.HitNKM, "swept hull trace did not hit displacement")
print(string.format("PASS: chunks=%d trianglePatches=%d triangles=%d renderVertices=%d traceLineFraction=%.4f traceHullFraction=%.4f", #chunks, totalPatches, totalTriangles, totalRenderVertices, trace.Fraction, hullTrace.Fraction))
