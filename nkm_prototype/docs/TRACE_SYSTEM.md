# NKM Trace System (runtime 0.6.0)

The trace system is shared between server and client. It builds plane data from each convex collision hull when collision data becomes resident. Runtime 0.6.0 uses a two-level median-split BVH: a top-level tree selects candidate collision chunks, then a local tree selects candidate convexes. It does not read BSP geometry.

The server builds a complete trace map for the active NKM world. The client builds a partial trace map from chunks currently streamed to that client. Therefore, client-side traces can only hit resident chunks; use the server-side API for authoritative gameplay decisions. See [Network Streaming](STREAMING.md).

## API

### `NKM.TraceLine(data)`

Traces a ray against the active NKM collision map and the normal Source world/entities. The closest hit wins.

```lua
local tr = NKM.TraceLine({
    start = startPos,
    endpos = endPos,
    mask = MASK_SOLID,
    filter = self
})

if tr.HitNKM then
    print(tr.NKM.MapName)
    print(tr.NKM.ConvexIndex)
    print(tr.NKM.ChunkID)
    print(tr.NKM.SurfaceProp)
end
```

Set `nkmOnly = true` to trace only NKM collision and ignore the Source world/entities:

```lua
local tr = NKM.TraceLine({
    start = startPos,
    endpos = endPos,
    nkmOnly = true
})
```

### `NKM.TraceHull(data)`

Uses the same result structure and supports `mins`/`maxs`:

```lua
local tr = NKM.TraceHull({
    start = startPos,
    endpos = endPos,
    mins = Vector(-16, -16, 0),
    maxs = Vector(16, 16, 72),
    nkmOnly = true
})
```

The NKM hull path uses conservative plane expansion for a swept axis-aligned box. This is suitable for broad collision checks, but can report a slightly early hit near convex corners. The Source portion still uses `util.TraceHull`.

### `NKM.PointContents(position [, nkmFilter])`

Returns `inside, hits`. Each hit contains `MapName`, `ConvexIndex`, `ChunkID`, and `SurfaceProp`.

### `NKM.FindInBox(mins, maxs [, nkmFilter])`

Returns convexes whose world-space AABBs overlap the query box. This is a broad-phase query, not an exact polygon intersection test.

### `NKM.FindInSphere(origin, radius [, nkmFilter])`

Returns convexes whose world-space AABBs intersect the query sphere. This is also a broad-phase query.

### `NKM.GetSurfaceData(traceOrIndex)`

Accepts an NKM trace result or a 1-based collision convex index and returns `{ MapName, ConvexIndex, ChunkID, SurfaceProp }`.

### `NKM.GetTraceStats()`

Returns acceleration diagnostics for the active map: convex/plane counts, BVH nodes/leaves/depth/leaf size, and the candidate/tested convex counts from the most recent NKM trace.

## BVH acceleration

Collision hull AABBs are arranged in a median-split BVH. `TraceLine` and `TraceHull` traverse only nodes intersected by the ray or swept AABB. `PointContents`, `FindInBox`, and `FindInSphere` use AABB BVH queries. Leaf-level candidate checks are performed against each convex AABB before any convex-plane test.

`nkm_status` and `nkm_client_status` print the BVH build statistics. Trace test commands also report `candidates / total convexes` and the count of convex plane tests.

## NKM filter

`nkmFilter` only filters the custom collision hulls; the regular `filter` and `whitelist` fields are forwarded to the Source trace.

Supported `nkmFilter` forms:

- A surface property string, e.g. `"concrete"`.
- A lookup table with convex indices or surface names set to `true`.
- A callback `(convexData, index) -> boolean`.

## Trace result extensions

Every returned trace has `HitNKM`.

For an NKM hit:

- `HitNKM = true`
- `NKM.MapName`
- `NKM.ConvexIndex`
- `NKM.ChunkID`
- `NKM.SurfaceProp`
- `SurfaceProp`
- `HitTexture = "nkm/<surface>"`

For a Source hit or miss, `HitNKM = false`.

NKM is a custom runtime world, not a Source `worldspawn` or ordinary entity. Therefore an NKM hit has `HitWorld = false` and `Entity = NULL`; use `HitNKM` to identify it.

## Current limits

- NKM ray traces use generated convex face planes, derived from the hull vertices.
- The convex index is prepared once during map activation, not rebuilt on every trace.
- The BVH accelerates broad-phase collision queries, but the prototype still has a 128-convex map limit.
- `FindInBox` and `FindInSphere` are broad-phase AABB queries.
- Swept NKM `TraceHull` is conservative near edges/corners.
- These APIs query NKM collision data only. Render-only geometry without a `collision` entry is not traceable.


## Chunk-aware statistics (0.6.0)

`NKM.GetTraceStats()` now includes:

- `ChunkCount`: number of chunks containing collision hulls.
- `LastChunkCount`: candidate chunks visited by the last broad-phase trace.
- `LastCandidateCount`: convex hull candidates returned by the selected local BVHs.
- `LastTestedCount`: candidates that passed `nkmFilter` and received the convex-plane test.

The existing `TraceLine`/`TraceHull` API and NKM v1 map file format are unchanged. `ConvexIndex` remains the original 1-based index from the map collision array even when the client has loaded only a subset of chunks.
