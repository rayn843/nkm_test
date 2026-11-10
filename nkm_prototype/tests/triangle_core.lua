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
NKM = {}
dofile("lua/nkm/sh_core.lua")
dofile("lua/nkm/sh_displacement.lua")
assert(NKM.RuntimeVersion == "0.9.7", "runtime version mismatch")

local map = NKM.BuildDisplacementTestMap(Vector(0,0,0))
map.collision = {{
    surface = "concrete",
    vertices = {
        {1900,1900,-20},{1900,1900,20},{1900,1940,-20},{1900,1940,20},
        {1940,1900,-20},{1940,1900,20},{1940,1940,-20},{1940,1940,20}
    }
}}
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
assert(#traceMap.convexes == 1, "legacy convex path was not preserved")
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
local surfaceData = NKM.GetSurfaceData(trace)
assert(surfaceData and surfaceData.TriangleIndex == trace.NKM.TriangleIndex, "triangle surface metadata lookup failed")
assert(surfaceData.SurfaceProp == "dirt", "triangle surface property lookup failed")
local hullTrace = NKM.TraceHull({start=startPos,endpos=endPos,mins=Vector(-8,-8,-8),maxs=Vector(8,8,8),nkmOnly=true})
assert(hullTrace.Hit and hullTrace.HitNKM, "swept hull trace did not hit displacement")

local convexTrace = NKM.TraceLine({
    start = Vector(1800, 1920, 0),
    endpos = Vector(2050, 1920, 0),
    nkmOnly = true
})
assert(convexTrace.Hit and convexTrace.HitNKM and convexTrace.NKM.ConvexIndex == 1, "legacy convex trace path was not preserved")
local convexSurface = NKM.GetSurfaceData(convexTrace)
assert(convexSurface and convexSurface.SurfaceProp == "concrete", "convex surface metadata lookup failed")

local renderOnly = NKM.BuildDisplacementTestMap(Vector(0,0,0))
renderOnly.displacements[1].collision = false
local renderOnlyValid, renderOnlyError = NKM.ValidateMap(renderOnly)
assert(renderOnlyValid, tostring(renderOnlyError))
local renderOnlyChunks = assert(NKM.BuildChunks(renderOnly))
local renderOnlyTrace = assert(NKM.BuildTraceData(renderOnly, renderOnly.name, renderOnlyChunks))
assert(#renderOnlyTrace.triangles == 0, "collision=false displacement unexpectedly entered Trace BVH")
local renderOnlyVertices = 0
for _, chunk in ipairs(renderOnlyChunks) do
    for _, group in ipairs(chunk.meshes or {}) do renderOnlyVertices = renderOnlyVertices + #group.vertices end
end
assert(renderOnlyVertices == 3456, "collision=false displacement did not retain render geometry")

-- Verify Source BSP row-major displacement topology, alternating diagonals,
-- and independent ray/hull collision channels.
local sourceGrid = {
    format = "NKM",
    version = 1,
    name = "source_grid_test",
    chunkSize = 512,
    meshes = {},
    collision = {},
    displacements = {{
        id = "source_grid",
        width = 3,
        height = 3,
        vertices = {
            {0,0,0}, {1,0,0}, {2,0,0},
            {0,1,0}, {1,1,0}, {2,1,0},
            {0,2,0}, {1,2,0}, {2,2,0}
        },
        triangleLayout = "source",
        flipWinding = true,
        physicsCollision = false,
        hullCollision = true,
        rayCollision = false,
        smoothNormals = false
    }}
}
local sourceChunks = assert(NKM.BuildChunks(sourceGrid))
assert(#sourceChunks == 1, "source grid should fit in one chunk")
local sourceGroup = assert(sourceChunks[1].triangleSurfaces[1])
local sourceMeshGroup = assert(sourceChunks[1].meshes[1])
assert(sourceMeshGroup.isBSPDisplacement == false, "synthetic GLua displacement must not be marked as imported BSP")
assert(sourceGroup.physicsCollision == false and sourceGroup.hullCollision == true and sourceGroup.rayCollision == false)
local gv = sourceGroup.vertices
local function samePoint(actual, expected)
    return math.abs(actual[1] - expected[1]) < 0.0001
        and math.abs(actual[2] - expected[2]) < 0.0001
        and math.abs(actual[3] - expected[3]) < 0.0001
end
-- Cell (0,0), even: (TL, BL, BR), (TL, BR, TR).
assert(samePoint(gv[1], {0,0,0}) and samePoint(gv[2], {0,1,0}) and samePoint(gv[3], {1,1,0}), "Source even-cell diagonal/winding mismatch")
assert(samePoint(gv[4], {0,0,0}) and samePoint(gv[5], {1,1,0}) and samePoint(gv[6], {1,0,0}), "Source even-cell second triangle mismatch")
-- Cell (1,0), odd: (TL, BL, TR), (TR, BL, BR).
assert(samePoint(gv[7], {1,0,0}) and samePoint(gv[8], {1,1,0}) and samePoint(gv[9], {2,0,0}), "Source odd-cell diagonal/winding mismatch")
assert(samePoint(gv[10], {2,0,0}) and samePoint(gv[11], {1,1,0}) and samePoint(gv[12], {2,1,0}), "Source odd-cell second triangle mismatch")
local sourceTraceMap = assert(NKM.BuildTraceData(sourceGrid, sourceGrid.name, sourceChunks))
assert(#sourceTraceMap.triangles == 8, "Source grid must produce 8 trace triangles")
NKM.TraceMap = sourceTraceMap
local sourceStart, sourceEnd = Vector(0.5,0.5,10), Vector(0.5,0.5,-10)
local rayDisabled = NKM.TraceLine({start=sourceStart,endpos=sourceEnd,nkmOnly=true})
assert(not rayDisabled.HitNKM, "NO_RAY_COLLISION surface should not block TraceLine")
local hullEnabled = NKM.TraceHull({start=sourceStart,endpos=sourceEnd,mins=Vector(-0.1,-0.1,-0.1),maxs=Vector(0.1,0.1,0.1),nkmOnly=true})
assert(hullEnabled.HitNKM, "NO_HULL_COLLISION is false, so TraceHull should hit")
NKM.TraceMap = traceMap

local degenerate = NKM.BuildDisplacementTestMap(Vector(0,0,0))
degenerate.displacements[1].vertices[2] = {
    degenerate.displacements[1].vertices[1][1],
    degenerate.displacements[1].vertices[1][2],
    degenerate.displacements[1].vertices[1][3]
}
local degenerateValid = NKM.ValidateMap(degenerate)
assert(not degenerateValid, "degenerate displacement triangle was not rejected")

print(string.format("PASS: chunks=%d trianglePatches=%d triangles=%d renderVertices=%d traceLineFraction=%.4f traceHullFraction=%.4f triangleSurface=%s convexSurface=%s renderOnlyTriangles=%d", #chunks, totalPatches, totalTriangles, totalRenderVertices, trace.Fraction, hullTrace.Fraction, surfaceData.SurfaceProp, convexSurface.SurfaceProp, #renderOnlyTrace.triangles))
