-- NKM Trace System
-- Pure Lua convex-hull and triangle-surface traces shared by server and client.
-- The Source trace is run separately, with NKM VPhysics proxy entities filtered out.

NKM.TraceEpsilon = 0.01
-- RuntimeVersion is defined centrally in sh_core.lua. Do not override it here.
NKM.TraceMap = nil

local abs = math.abs
local max = math.max
local min = math.min
local huge = math.huge

local function finiteVector(vector)
    return isvector(vector)
        and vector.x == vector.x and vector.y == vector.y and vector.z == vector.z
        and vector.x ~= huge and vector.y ~= huge and vector.z ~= huge
        and vector.x ~= -huge and vector.y ~= -huge and vector.z ~= -huge
end

local function makeVector(point)
    return Vector(point[1], point[2], point[3])
end

local function addPlane(planes, normal, distance)
    for _, plane in ipairs(planes) do
        if plane.normal:Dot(normal) > 0.9999 and abs(plane.distance - distance) < 0.1 then
            return
        end
    end

    planes[#planes + 1] = {
        normal = normal,
        distance = distance
    }
end

local function buildConvexPlanes(points)
    local planes = {}
    local pointCount = #points
    local epsilon = NKM.TraceEpsilon

    -- A supporting plane is defined by any three non-collinear hull vertices
    -- for which every other vertex lies on the same side. Coplanar triangles
    -- are deduplicated, leaving one plane per convex face.
    for a = 1, pointCount - 2 do
        local pointA = points[a]

        for b = a + 1, pointCount - 1 do
            local edgeAB = points[b] - pointA

            for c = b + 1, pointCount do
                local normal = edgeAB:Cross(points[c] - pointA)
                local lengthSqr = normal:LengthSqr()

                if lengthSqr > 0.000001 then
                    normal:Normalize()

                    local minDistance = huge
                    local maxDistance = -huge

                    for pointIndex = 1, pointCount do
                        local signedDistance = (points[pointIndex] - pointA):Dot(normal)
                        minDistance = min(minDistance, signedDistance)
                        maxDistance = max(maxDistance, signedDistance)
                    end

                    local outwardNormal
                    if maxDistance <= epsilon and minDistance < -epsilon then
                        outwardNormal = normal
                    elseif minDistance >= -epsilon and maxDistance > epsilon then
                        outwardNormal = -normal
                    end

                    if outwardNormal then
                        addPlane(planes, outwardNormal, outwardNormal:Dot(pointA))
                    end
                end
            end
        end
    end

    return planes
end

local BVH_LEAF_SIZE = 4

local function boundsForConvexes(items)
    local minX, minY, minZ = huge, huge, huge
    local maxX, maxY, maxZ = -huge, -huge, -huge

    for _, convex in ipairs(items) do
        minX = min(minX, convex.mins.x)
        minY = min(minY, convex.mins.y)
        minZ = min(minZ, convex.mins.z)
        maxX = max(maxX, convex.maxs.x)
        maxY = max(maxY, convex.maxs.y)
        maxZ = max(maxZ, convex.maxs.z)
    end

    return Vector(minX, minY, minZ), Vector(maxX, maxY, maxZ)
end

local function convexCenterOnAxis(convex, axis)
    if axis == 1 then return (convex.mins.x + convex.maxs.x) * 0.5 end
    if axis == 2 then return (convex.mins.y + convex.maxs.y) * 0.5 end
    return (convex.mins.z + convex.maxs.z) * 0.5
end

local function buildBVH(items, stats, depth)
    if #items == 0 then return nil end

    stats.nodeCount = stats.nodeCount + 1
    stats.maxDepth = max(stats.maxDepth, depth)

    local nodeMins, nodeMaxs = boundsForConvexes(items)
    local node = {
        mins = nodeMins,
        maxs = nodeMaxs
    }

    if #items <= BVH_LEAF_SIZE then
        node.items = items
        stats.leafCount = stats.leafCount + 1
        return node
    end

    local sizeX = nodeMaxs.x - nodeMins.x
    local sizeY = nodeMaxs.y - nodeMins.y
    local sizeZ = nodeMaxs.z - nodeMins.z
    local splitAxis = 1

    if sizeY > sizeX and sizeY >= sizeZ then
        splitAxis = 2
    elseif sizeZ > sizeX and sizeZ > sizeY then
        splitAxis = 3
    end

    table.sort(items, function(a, b)
        return convexCenterOnAxis(a, splitAxis) < convexCenterOnAxis(b, splitAxis)
    end)

    local middle = math.floor(#items * 0.5)
    local leftItems, rightItems = {}, {}

    for index = 1, middle do
        leftItems[#leftItems + 1] = items[index]
    end
    for index = middle + 1, #items do
        rightItems[#rightItems + 1] = items[index]
    end

    node.left = buildBVH(leftItems, stats, depth + 1)
    node.right = buildBVH(rightItems, stats, depth + 1)
    return node
end

local function buildTraceChunkData(runtimeChunk, mapName, sourceIndices)
    local collisionData = runtimeChunk.collision or {}
    local triangleData = runtimeChunk.triangleSurfaces or {}
    local cached = runtimeChunk._nkmTraceCache

    -- Collision payload tables are immutable while a chunk is resident. Reuse
    -- both convex and triangle acceleration data until the payload changes.
    if cached
        and cached.sourceCollision == collisionData
        and cached.sourceTriangleSurfaces == triangleData
        and cached.id == runtimeChunk.id
        and cached.mapName == mapName then
        if NKM.PerfAdd then NKM.PerfAdd("trace_chunk_cache_hits", 1) end
        return cached
    end

    local perfStartedAt = NKM.PerfBegin and NKM.PerfBegin() or nil
    local chunkTrace = {
        id = runtimeChunk.id,
        ix = runtimeChunk.ix,
        iy = runtimeChunk.iy,
        iz = runtimeChunk.iz,
        mapName = mapName,
        sourceCollision = collisionData,
        sourceTriangleSurfaces = triangleData,
        convexes = {},
        triangles = {},
        items = {},
        bvh = nil,
        bvhNodeCount = 0,
        bvhLeafCount = 0,
        bvhDepth = 0
    }

    for _, convexData in ipairs(collisionData) do
        local convexIndex = convexData._nkmIndex or sourceIndices[convexData] or (#chunkTrace.convexes + 1)
        local points = {}
        local minX, minY, minZ = huge, huge, huge
        local maxX, maxY, maxZ = -huge, -huge, -huge

        for _, rawPoint in ipairs(convexData.vertices) do
            local point = makeVector(rawPoint)
            points[#points + 1] = point
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            minZ = min(minZ, point.z)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
            maxZ = max(maxZ, point.z)
        end

        local planes = buildConvexPlanes(points)
        if #planes < 4 then
            if perfStartedAt and NKM.PerfRecord then
                NKM.PerfRecord("trace_chunk_build", perfStartedAt)
            end
            if NKM.PerfAdd then NKM.PerfAdd("trace_chunk_build_failures", 1) end
            return nil, "collision convex #" .. convexIndex .. " does not form a valid 3D convex hull"
        end

        local convex = {
            kind = "convex",
            index = convexIndex,
            surface = convexData.surface or "default",
            points = points,
            planes = planes,
            mins = Vector(minX, minY, minZ),
            maxs = Vector(maxX, maxY, maxZ),
            chunkID = runtimeChunk.id
        }
        chunkTrace.convexes[#chunkTrace.convexes + 1] = convex
        chunkTrace.items[#chunkTrace.items + 1] = convex
    end

    local fallbackTriangleIndex = 0
    for surfaceIndex, surfaceData in ipairs(triangleData) do
        local vertices = surfaceData.vertices or {}
        local indices = surfaceData.indices or {}
        for vertexIndex = 1, #vertices, 3 do
            fallbackTriangleIndex = fallbackTriangleIndex + 1
            local a = makeVector(vertices[vertexIndex])
            local b = makeVector(vertices[vertexIndex + 1])
            local c = makeVector(vertices[vertexIndex + 2])
            local edgeAB = b - a
            local edgeAC = c - a
            local normal = edgeAB:Cross(edgeAC)
            local normalLengthSqr = normal:LengthSqr()
            if normalLengthSqr > 0.00000001 then
                normal:Normalize()
                local minX = min(a.x, b.x, c.x)
                local minY = min(a.y, b.y, c.y)
                local minZ = min(a.z, b.z, c.z)
                local maxX = max(a.x, b.x, c.x)
                local maxY = max(a.y, b.y, c.y)
                local maxZ = max(a.z, b.z, c.z)
                local triangleIndex = indices[math.floor((vertexIndex + 2) / 3)] or fallbackTriangleIndex
                local triangle = {
                    kind = "triangle",
                    index = triangleIndex,
                    surfaceIndex = surfaceIndex,
                    surface = surfaceData.surface or "default",
                    rayCollision = surfaceData.rayCollision ~= false,
                    hullCollision = surfaceData.hullCollision ~= false,
                    a = a,
                    b = b,
                    c = c,
                    normal = normal,
                    mins = Vector(minX, minY, minZ),
                    maxs = Vector(maxX, maxY, maxZ),
                    chunkID = runtimeChunk.id
                }
                chunkTrace.triangles[#chunkTrace.triangles + 1] = triangle
                chunkTrace.items[#chunkTrace.items + 1] = triangle
            end
        end
    end

    if #chunkTrace.items > 0 then
        local localStats = { nodeCount = 0, leafCount = 0, maxDepth = 0 }
        chunkTrace.bvh = buildBVH(chunkTrace.items, localStats, 1)
        chunkTrace.bvhNodeCount = localStats.nodeCount
        chunkTrace.bvhLeafCount = localStats.leafCount
        chunkTrace.bvhDepth = localStats.maxDepth
        chunkTrace.mins, chunkTrace.maxs = boundsForConvexes(chunkTrace.items)
    end

    runtimeChunk._nkmTraceCache = chunkTrace
    if perfStartedAt and NKM.PerfRecord then
        NKM.PerfRecord("trace_chunk_build", perfStartedAt)
    end
    if NKM.PerfAdd then
        NKM.PerfAdd("trace_chunk_builds", 1)
        NKM.PerfAdd("trace_triangles_built", #chunkTrace.triangles)
    end
    return chunkTrace
end

function NKM.BuildTraceData(mapTable, mapName, runtimeChunks)
    if not istable(mapTable) then
        return nil, "map table is invalid"
    end

    runtimeChunks = runtimeChunks or NKM.BuildChunks(mapTable)
    if not istable(runtimeChunks) then
        return nil, "chunk partition is invalid"
    end

    local resolvedMapName = mapName or mapTable.name or "unknown"
    local traceMap = {
        name = resolvedMapName,
        convexes = {},
        convexByIndex = {},
        triangles = {},
        triangleByChunkIndex = {},
        chunks = {},
        planeCount = 0,
        bvh = nil,
        bvhNodeCount = 0,
        bvhLeafCount = 0,
        bvhDepth = 0,
        bvhLeafSize = BVH_LEAF_SIZE,
        lastCandidateCount = 0,
        lastTriangleCandidateCount = 0,
        lastTestedCount = 0,
        lastChunkCount = 0
    }

    local sourceIndices = {}
    for index, convexData in ipairs(mapTable.collision or {}) do
        sourceIndices[convexData] = index
    end

    local rootItems = {}

    for _, runtimeChunk in ipairs(runtimeChunks) do
        local collisionData = runtimeChunk.collision or {}
        local triangleData = runtimeChunk.triangleSurfaces or {}
        if #collisionData > 0 or #triangleData > 0 then
            local chunkTrace, err = buildTraceChunkData(runtimeChunk, resolvedMapName, sourceIndices)
            if not chunkTrace then return nil, err end
            if #chunkTrace.items > 0 then
                traceMap.chunks[#traceMap.chunks + 1] = chunkTrace
                rootItems[#rootItems + 1] = chunkTrace
            end

            for _, convex in ipairs(chunkTrace.convexes) do
                traceMap.convexes[#traceMap.convexes + 1] = convex
                traceMap.convexByIndex[convex.index] = convex
                traceMap.planeCount = traceMap.planeCount + #convex.planes
            end
            if #chunkTrace.triangles > 0 then
                local byIndex = {}
                traceMap.triangleByChunkIndex[runtimeChunk.id] = byIndex
                for _, triangle in ipairs(chunkTrace.triangles) do
                    traceMap.triangles[#traceMap.triangles + 1] = triangle
                    byIndex[triangle.index] = triangle
                end
            end

            traceMap.bvhNodeCount = traceMap.bvhNodeCount + chunkTrace.bvhNodeCount
            traceMap.bvhLeafCount = traceMap.bvhLeafCount + chunkTrace.bvhLeafCount
            traceMap.bvhDepth = max(traceMap.bvhDepth, chunkTrace.bvhDepth)
        end
    end

    if #rootItems > 0 then
        local rootPerfStartedAt = NKM.PerfBegin and NKM.PerfBegin() or nil
        local rootStats = { nodeCount = 0, leafCount = 0, maxDepth = 0 }
        traceMap.bvh = buildBVH(rootItems, rootStats, 1)
        traceMap.bvhNodeCount = traceMap.bvhNodeCount + rootStats.nodeCount
        traceMap.bvhLeafCount = traceMap.bvhLeafCount + rootStats.leafCount
        traceMap.bvhDepth = max(traceMap.bvhDepth, rootStats.maxDepth)
        traceMap.mins, traceMap.maxs = boundsForConvexes(rootItems)
        if rootPerfStartedAt and NKM.PerfRecord then
            NKM.PerfRecord("trace_root_bvh_build", rootPerfStartedAt)
        end
        if NKM.PerfAdd then NKM.PerfAdd("trace_root_bvh_builds", 1) end
    end

    table.sort(traceMap.convexes, function(a, b) return a.index < b.index end)
    return traceMap
end

local function segmentIntersectsAABB(startPos, endPos, mins, maxs)
    local direction = endPos - startPos
    local tEnter, tExit = 0, 1
    local axes = {
        { startPos.x, direction.x, mins.x, maxs.x },
        { startPos.y, direction.y, mins.y, maxs.y },
        { startPos.z, direction.z, mins.z, maxs.z }
    }

    for _, axis in ipairs(axes) do
        local origin, delta, low, high = axis[1], axis[2], axis[3], axis[4]

        if abs(delta) < 0.0000001 then
            if origin < low or origin > high then
                return false
            end
        else
            local t1 = (low - origin) / delta
            local t2 = (high - origin) / delta
            if t1 > t2 then t1, t2 = t2, t1 end

            tEnter = max(tEnter, t1)
            tExit = min(tExit, t2)
            if tEnter > tExit then
                return false
            end
        end
    end

    return tExit >= 0 and tEnter <= 1
end

local function aabbOverlaps(minsA, maxsA, minsB, maxsB)
    return minsA.x <= maxsB.x and maxsA.x >= minsB.x
        and minsA.y <= maxsB.y and maxsA.y >= minsB.y
        and minsA.z <= maxsB.z and maxsA.z >= minsB.z
end

local function queryBVHAABB(node, queryMins, queryMaxs, results)
    if not node or not aabbOverlaps(node.mins, node.maxs, queryMins, queryMaxs) then
        return
    end

    if node.items then
        for _, convex in ipairs(node.items) do
            if aabbOverlaps(convex.mins, convex.maxs, queryMins, queryMaxs) then
                results[#results + 1] = convex
            end
        end
        return
    end

    queryBVHAABB(node.left, queryMins, queryMaxs, results)
    queryBVHAABB(node.right, queryMins, queryMaxs, results)
end

local function queryBVHSegment(node, startPos, endPos, expansion, results)
    if not node then return end

    local expandedMins = node.mins - expansion
    local expandedMaxs = node.maxs + expansion
    if not segmentIntersectsAABB(startPos, endPos, expandedMins, expandedMaxs) then
        return
    end

    if node.items then
        for _, convex in ipairs(node.items) do
            local convexMins = convex.mins - expansion
            local convexMaxs = convex.maxs + expansion
            if segmentIntersectsAABB(startPos, endPos, convexMins, convexMaxs) then
                results[#results + 1] = convex
            end
        end
        return
    end

    queryBVHSegment(node.left, startPos, endPos, expansion, results)
    queryBVHSegment(node.right, startPos, endPos, expansion, results)
end

local function getBVHCandidatesForSegment(traceMap, startPos, endPos, halfSize)
    local candidates = {}
    local chunkCandidates = {}
    if traceMap.bvh then
        queryBVHSegment(traceMap.bvh, startPos, endPos, halfSize, chunkCandidates)
    end

    traceMap.lastChunkCount = #chunkCandidates
    for _, chunk in ipairs(chunkCandidates) do
        if chunk.bvh then
            queryBVHSegment(chunk.bvh, startPos, endPos, halfSize, candidates)
        end
    end
    return candidates
end

local function getBVHCandidatesForAABB(traceMap, mins, maxs)
    local candidates = {}
    local chunkCandidates = {}
    if traceMap.bvh then
        queryBVHAABB(traceMap.bvh, mins, maxs, chunkCandidates)
    end

    traceMap.lastChunkCount = #chunkCandidates
    for _, chunk in ipairs(chunkCandidates) do
        if chunk.bvh then
            queryBVHAABB(chunk.bvh, mins, maxs, candidates)
        end
    end
    return candidates
end

local function shouldTraceConvex(convex, index, nkmFilter)
    if nkmFilter == nil then return true end

    if isfunction(nkmFilter) then
        return nkmFilter(convex, index) ~= false
    end

    if isstring(nkmFilter) then
        return convex.surface == nkmFilter
    end

    if istable(nkmFilter) then
        return nkmFilter[index] == true or nkmFilter[convex.surface] == true
    end

    return true
end

local function traceConvex(startPos, endPos, mins, maxs, convex)
    local centerOffset = (mins + maxs) * 0.5
    local halfSize = (maxs - mins) * 0.5
    local traceStart = startPos + centerOffset
    local traceEnd = endPos + centerOffset

    local direction = traceEnd - traceStart
    local enterFraction = -huge
    local exitFraction = huge
    local enterNormal
    local startsInside = true
    local epsilon = NKM.TraceEpsilon

    for _, plane in ipairs(convex.planes) do
        local normal = plane.normal
        local supportRadius = abs(normal.x) * halfSize.x
            + abs(normal.y) * halfSize.y
            + abs(normal.z) * halfSize.z
        local distance = plane.distance + supportRadius - normal:Dot(traceStart)
        local denominator = normal:Dot(direction)

        if distance < -epsilon then
            startsInside = false
        end

        if abs(denominator) < 0.0000001 then
            if distance < -epsilon then
                return nil
            end
        else
            local fraction = distance / denominator

            if denominator < 0 then
                if fraction > enterFraction then
                    enterFraction = fraction
                    enterNormal = normal
                end
            elseif fraction < exitFraction then
                exitFraction = fraction
            end

            if enterFraction > exitFraction then
                return nil
            end
        end
    end

    if exitFraction < 0 or enterFraction > 1 then
        return nil
    end

    local fraction = startsInside and 0 or max(enterFraction, 0)
    if fraction > 1 then return nil end

    return {
        fraction = fraction,
        exitFraction = exitFraction,
        normal = startsInside and Vector(0, 0, 0) or (enterNormal or Vector(0, 0, 0)),
        startSolid = startsInside,
        allSolid = startsInside and exitFraction >= 1,
        convex = convex
    }
end

local function traceTriangle(startPos, endPos, mins, maxs, triangle)
    -- Continuous SAT for a translating axis-aligned box against a static
    -- triangle. For a zero-sized box this reduces to segment/triangle tracing.
    local centerOffset = (mins + maxs) * 0.5
    local halfSize = (maxs - mins) * 0.5
    local centerStart = startPos + centerOffset
    local direction = endPos - startPos
    local a, b, c = triangle.a, triangle.b, triangle.c
    local edgeAB, edgeBC, edgeCA = b - a, c - b, a - c
    local axes = {
        Vector(1, 0, 0), Vector(0, 1, 0), Vector(0, 0, 1),
        triangle.normal,
        edgeAB:Cross(Vector(1, 0, 0)), edgeAB:Cross(Vector(0, 1, 0)), edgeAB:Cross(Vector(0, 0, 1)),
        edgeBC:Cross(Vector(1, 0, 0)), edgeBC:Cross(Vector(0, 1, 0)), edgeBC:Cross(Vector(0, 0, 1)),
        edgeCA:Cross(Vector(1, 0, 0)), edgeCA:Cross(Vector(0, 1, 0)), edgeCA:Cross(Vector(0, 0, 1))
    }

    local enterFraction, exitFraction = -huge, huge
    local enterNormal
    local startsOverlapping = true
    local epsilon = NKM.TraceEpsilon

    for _, axis in ipairs(axes) do
        local axisLengthSqr = axis:LengthSqr()
        if axisLengthSqr > 0.00000001 then
            axis = axis / math.sqrt(axisLengthSqr)
            local projectionA = axis:Dot(a)
            local projectionB = axis:Dot(b)
            local projectionC = axis:Dot(c)
            local triangleMin = min(projectionA, projectionB, projectionC)
            local triangleMax = max(projectionA, projectionB, projectionC)
            local radius = abs(axis.x) * halfSize.x
                + abs(axis.y) * halfSize.y
                + abs(axis.z) * halfSize.z
            local low = triangleMin - radius
            local high = triangleMax + radius
            local startProjection = axis:Dot(centerStart)
            local velocity = axis:Dot(direction)

            if startProjection < low - epsilon or startProjection > high + epsilon then
                startsOverlapping = false
            end

            if abs(velocity) < 0.0000001 then
                if startProjection < low - epsilon or startProjection > high + epsilon then
                    return nil
                end
            else
                local first = (low - startProjection) / velocity
                local second = (high - startProjection) / velocity
                local axisEnter, axisExit, axisNormal
                if first <= second then
                    axisEnter, axisExit = first, second
                    axisNormal = -axis
                else
                    axisEnter, axisExit = second, first
                    axisNormal = axis
                end

                if axisEnter > enterFraction then
                    enterFraction = axisEnter
                    enterNormal = axisNormal
                end
                exitFraction = min(exitFraction, axisExit)
                if enterFraction > exitFraction + epsilon then
                    return nil
                end
            end
        end
    end

    if exitFraction < 0 or enterFraction > 1 then return nil end
    local fraction = startsOverlapping and 0 or max(enterFraction, 0)
    if fraction > 1 then return nil end
    return {
        fraction = fraction,
        exitFraction = exitFraction,
        normal = startsOverlapping and Vector(0, 0, 0) or (enterNormal or triangle.normal),
        startSolid = startsOverlapping,
        allSolid = startsOverlapping and exitFraction >= 1,
        triangle = triangle
    }
end

local function traceNKM(data, mins, maxs, isHullTrace)
    local traceMap = NKM.TraceMap
    if not traceMap or (#traceMap.convexes == 0 and #traceMap.triangles == 0) then return nil end

    local best
    local nkmFilter = data.nkmFilter
    local centerOffset = (mins + maxs) * 0.5
    local halfSize = (maxs - mins) * 0.5
    local traceStart = data.start + centerOffset
    local traceEnd = data.endpos + centerOffset
    local candidates = getBVHCandidatesForSegment(traceMap, traceStart, traceEnd, halfSize)
    local testedCount, triangleCandidates = 0, 0

    traceMap.lastCandidateCount = #candidates

    for _, item in ipairs(candidates) do
        if item.kind == "triangle" then
            triangleCandidates = triangleCandidates + 1
            local channelEnabled = isHullTrace and item.hullCollision or (not isHullTrace and item.rayCollision)
            if channelEnabled and shouldTraceConvex(item, item.index, nkmFilter) then
                testedCount = testedCount + 1
                local hit = traceTriangle(data.start, data.endpos, mins, maxs, item)
                if hit and (not best or hit.fraction < best.fraction) then
                    best = hit
                end
            end
        elseif shouldTraceConvex(item, item.index, nkmFilter) then
            testedCount = testedCount + 1
            local hit = traceConvex(data.start, data.endpos, mins, maxs, item)
            if hit and (not best or hit.fraction < best.fraction) then
                best = hit
            end
        end
    end

    traceMap.lastTestedCount = testedCount
    traceMap.lastTriangleCandidateCount = triangleCandidates
    if not best then return nil end

    local direction = data.endpos - data.start
    local hitPosition = data.start + direction * best.fraction
    local target = best.convex or best.triangle
    local surface = target.surface
    local isTriangle = best.triangle ~= nil
    local metadata = {
        MapName = traceMap.name,
        ChunkID = target.chunkID,
        SurfaceProp = surface
    }
    if isTriangle then
        metadata.TriangleIndex = target.index
        metadata.TriangleSurfaceIndex = target.surfaceIndex
    else
        metadata.ConvexIndex = target.index
    end

    return {
        StartPos = data.start,
        EndPos = data.endpos,
        StartSolid = best.startSolid,
        AllSolid = best.allSolid,
        Fraction = best.fraction,
        FractionLeftSolid = best.startSolid and math.Clamp(best.exitFraction, 0, 1) or 0,
        Hit = true,
        HitWorld = false,
        HitNonWorld = false,
        HitNoDraw = false,
        HitSky = false,
        HitBox = 0,
        HitGroup = 0,
        HitTexture = "nkm/" .. surface,
        MatType = MAT_DEFAULT or 0,
        HitPos = hitPosition,
        HitNormal = best.normal,
        Entity = NULL,
        HitNKM = true,
        SurfaceProp = surface,
        NKM = metadata
    }
end

local function isProxyEntity(ent, proxySet)
    return proxySet[ent] == true
end

local function makeSourceFilter(data)
    local proxySet = {}
    local proxyList = {}

    for _, ent in ipairs(NKM.CollisionEntities or {}) do
        if IsValid(ent) then
            proxySet[ent] = true
            proxyList[#proxyList + 1] = ent
        end
    end

    local original = data.filter
    local whitelist = data.whitelist == true

    if #proxyList == 0 then
        return original, data.whitelist
    end

    if isfunction(original) then
        return function(ent)
            if isProxyEntity(ent, proxySet) then return false end
            return original(ent)
        end, false
    end

    if isentity(original) then
        local merged = { original }
        if not whitelist then
            for _, ent in ipairs(proxyList) do merged[#merged + 1] = ent end
        end
        return merged, whitelist
    end

    if istable(original) then
        local containsClassNames = false
        for _, value in ipairs(original) do
            if isstring(value) then
                containsClassNames = true
                break
            end
        end

        if containsClassNames then
            -- Avoid mixing entity references and class-name strings in one
            -- engine filter array. Preserve both blacklist and whitelist intent.
            return function(ent)
                local listed = false
                local className = ent:GetClass()
                for _, value in ipairs(original) do
                    if value == ent or (isstring(value) and value == className) then
                        listed = true
                        break
                    end
                end
                if isProxyEntity(ent, proxySet) then return false end
                return whitelist and listed or not whitelist and not listed
            end, false
        end

        local merged = {}
        for _, value in ipairs(original) do
            if not isentity(value) or not isProxyEntity(value, proxySet) then
                merged[#merged + 1] = value
            end
        end
        if not whitelist then
            for _, ent in ipairs(proxyList) do merged[#merged + 1] = ent end
        end
        return merged, whitelist
    end

    if original == nil and not whitelist then
        return proxyList, false
    end

    return original, data.whitelist
end

local function runSourceTrace(method, data)
    if data.nkmOnly then return nil end

    local traceData = {}
    for key, value in pairs(data) do
        if key ~= "nkmOnly" and key ~= "nkmFilter" and key ~= "output" then
            traceData[key] = value
        end
    end

    local filter, whitelist = makeSourceFilter(data)
    traceData.filter = filter
    traceData.whitelist = whitelist

    local ok, result = pcall(util[method], traceData)
    if ok and istable(result) then
        result.HitNKM = false
        result.NKM = nil
        return result
    end

    return nil
end

local function finalizeTraceResult(result, data)
    if istable(data.output) then
        for key in pairs(data.output) do
            data.output[key] = nil
        end
        for key, value in pairs(result) do
            data.output[key] = value
        end
        return data.output
    end
    return result
end

local function runNKMTrace(method, data, mins, maxs)
    if not istable(data) then
        error("NKM." .. method .. " expects a trace data table", 3)
    end
    if not finiteVector(data.start) or not finiteVector(data.endpos) then
        error("NKM." .. method .. " requires finite Vector start and endpos", 3)
    end

    local defaultMins = Vector(0, 0, 0)
    local defaultMaxs = Vector(0, 0, 0)
    mins = mins or data.mins or defaultMins
    maxs = maxs or data.maxs or defaultMaxs

    if not finiteVector(mins) or not finiteVector(maxs)
        or mins.x > maxs.x or mins.y > maxs.y or mins.z > maxs.z then
        error("NKM." .. method .. " received invalid mins/maxs", 3)
    end

    local nkmResult = traceNKM(data, mins, maxs, method == "TraceHull")
    local sourceResult = runSourceTrace(method, data)

    if nkmResult and (not sourceResult or not sourceResult.Hit or nkmResult.Fraction < sourceResult.Fraction) then
        return finalizeTraceResult(nkmResult, data)
    end

    if sourceResult then return finalizeTraceResult(sourceResult, data) end

    return finalizeTraceResult({
        StartPos = data.start,
        EndPos = data.endpos,
        StartSolid = false,
        AllSolid = false,
        Fraction = 1,
        FractionLeftSolid = 0,
        Hit = false,
        HitWorld = false,
        HitNonWorld = false,
        HitNoDraw = false,
        HitSky = false,
        HitBox = 0,
        HitGroup = 0,
        HitTexture = "**empty**",
        MatType = MAT_DEFAULT or 0,
        HitPos = data.endpos,
        HitNormal = Vector(0, 0, 0),
        Entity = NULL,
        HitNKM = false
    }, data)
end

--- Performs a line trace against NKM collision and normal Source geometry.
--- Set nkmOnly = true to ignore all Source BSP/entities.
--- nkmFilter may be a surface name, an index/surface lookup table, or a callback.
function NKM.TraceLine(data)
    return runNKMTrace("TraceLine", data, Vector(0, 0, 0), Vector(0, 0, 0))
end

--- Performs a swept AABB trace against NKM convexes and normal Source geometry.
--- The NKM part uses conservative plane expansion for the swept box.
function NKM.TraceHull(data)
    if not istable(data) then
        error("NKM.TraceHull expects a trace data table", 2)
    end
    return runNKMTrace("TraceHull", data, data.mins, data.maxs)
end

--- Returns true when a point is inside one or more NKM collision convexes.
--- The second return value is an array of hit metadata records.
function NKM.PointContents(position, nkmFilter)
    if not finiteVector(position) or not NKM.TraceMap then
        return false, {}
    end

    local contents = {}
    local epsilon = NKM.TraceEpsilon
    local candidates = getBVHCandidatesForAABB(NKM.TraceMap, position, position)

    for _, convex in ipairs(candidates) do
        local index = convex.index
        if convex.kind ~= "triangle" and shouldTraceConvex(convex, index, nkmFilter) then
            local inside = true
            for _, plane in ipairs(convex.planes) do
                if plane.normal:Dot(position) > plane.distance + epsilon then
                    inside = false
                    break
                end
            end

            if inside then
                contents[#contents + 1] = {
                    ConvexIndex = convex.index,
                    ChunkID = convex.chunkID,
                    SurfaceProp = convex.surface,
                    MapName = NKM.TraceMap.name
                }
            end
        end
    end

    return #contents > 0, contents
end

--- Broad-phase query against NKM collision convex bounds.
function NKM.FindInBox(mins, maxs, nkmFilter)
    if not finiteVector(mins) or not finiteVector(maxs) or not NKM.TraceMap then
        return {}
    end

    local results = {}
    local candidates = getBVHCandidatesForAABB(NKM.TraceMap, mins, maxs)
    for _, convex in ipairs(candidates) do
        local index = convex.index
        if convex.kind ~= "triangle" and shouldTraceConvex(convex, index, nkmFilter) then
            results[#results + 1] = {
                ConvexIndex = convex.index,
                ChunkID = convex.chunkID,
                SurfaceProp = convex.surface,
                Mins = convex.mins,
                Maxs = convex.maxs,
                MapName = NKM.TraceMap.name
            }
        end
    end

    return results
end

--- Broad-phase sphere query against NKM collision convex bounds.
function NKM.FindInSphere(origin, radius, nkmFilter)
    if not finiteVector(origin) or not isnumber(radius) or radius ~= radius
        or radius == huge or radius == -huge or radius < 0 or not NKM.TraceMap then
        return {}
    end

    local results = {}
    local radiusSqr = radius * radius
    local radiusVector = Vector(radius, radius, radius)
    local candidates = getBVHCandidatesForAABB(NKM.TraceMap, origin - radiusVector, origin + radiusVector)

    for _, convex in ipairs(candidates) do
        local index = convex.index
        if convex.kind ~= "triangle" and shouldTraceConvex(convex, index, nkmFilter) then
            local closest = Vector(
                math.Clamp(origin.x, convex.mins.x, convex.maxs.x),
                math.Clamp(origin.y, convex.mins.y, convex.maxs.y),
                math.Clamp(origin.z, convex.mins.z, convex.maxs.z)
            )

            if origin:DistToSqr(closest) <= radiusSqr then
                results[#results + 1] = {
                    ConvexIndex = convex.index,
                    ChunkID = convex.chunkID,
                    SurfaceProp = convex.surface,
                    Mins = convex.mins,
                    Maxs = convex.maxs,
                    MapName = NKM.TraceMap.name
                }
            end
        end
    end

    return results
end

--- Resolves NKM surface metadata from a trace result or convex index.
-- Triangle surfaces are addressed by the TriangleIndex + ChunkID pair returned
-- by TraceLine/TraceHull; a bare numeric index continues to mean ConvexIndex.
function NKM.GetSurfaceData(traceOrIndex)
    if not NKM.TraceMap then return nil end

    local index
    local triangleIndex, chunkID
    if isnumber(traceOrIndex) then
        index = traceOrIndex
    elseif istable(traceOrIndex) and traceOrIndex.HitNKM and istable(traceOrIndex.NKM) then
        index = traceOrIndex.NKM.ConvexIndex
        triangleIndex = traceOrIndex.NKM.TriangleIndex
        chunkID = traceOrIndex.NKM.ChunkID
    else
        return nil
    end

    if triangleIndex ~= nil then
        local triangle = chunkID ~= nil
            and NKM.TraceMap.triangleByChunkIndex
            and NKM.TraceMap.triangleByChunkIndex[chunkID]
            and NKM.TraceMap.triangleByChunkIndex[chunkID][triangleIndex]
            or nil
        if not triangle then
            for _, candidate in ipairs(NKM.TraceMap.triangles or {}) do
                if candidate.index == triangleIndex and (chunkID == nil or candidate.chunkID == chunkID) then
                    triangle = candidate
                    break
                end
            end
        end
        if not triangle then return nil end
        return {
            MapName = NKM.TraceMap.name,
            TriangleIndex = triangle.index,
            TriangleSurfaceIndex = triangle.surfaceIndex,
            ChunkID = triangle.chunkID,
            SurfaceProp = triangle.surface,
            Normal = triangle.normal,
            Mins = triangle.mins,
            Maxs = triangle.maxs
        }
    end

    local convex = NKM.TraceMap.convexByIndex and NKM.TraceMap.convexByIndex[index]
        or NKM.TraceMap.convexes[index]
    if not convex then return nil end

    return {
        MapName = NKM.TraceMap.name,
        ConvexIndex = convex.index,
        ChunkID = convex.chunkID,
        SurfaceProp = convex.surface
    }
end


--- Returns acceleration and last-query diagnostics for the active NKM map.
function NKM.GetTraceStats()
    local traceMap = NKM.TraceMap
    if not traceMap then return nil end

    return {
        MapName = traceMap.name,
        ConvexCount = #traceMap.convexes,
        TriangleCount = #traceMap.triangles,
        PlaneCount = traceMap.planeCount,
        BVHNodeCount = traceMap.bvhNodeCount,
        BVHLeafCount = traceMap.bvhLeafCount,
        BVHDepth = traceMap.bvhDepth,
        BVHLeafSize = traceMap.bvhLeafSize,
        ChunkCount = #traceMap.chunks,
        LastChunkCount = traceMap.lastChunkCount,
        LastCandidateCount = traceMap.lastCandidateCount,
        LastTestedCount = traceMap.lastTestedCount
    }
end
