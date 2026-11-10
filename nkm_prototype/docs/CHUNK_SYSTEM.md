# NKM Chunk System

## Purpose

A chunk is the independently streamed spatial unit of an NKM map. Runtime chunk ownership is derived from the map's `chunkSize` (default 512 units).

Each runtime chunk contains:

- A stable string ID (`ix_iy_iz`) and integer grid coordinates.
- World-space bounds (`mins`, `maxs`).
- Render mesh groups, each holding triangle-aligned vertices.
- Collision convexes assigned to that chunk.
- A manifest index used by the current network transport.

## Partitioning rules

`NKM.BuildChunks(mapTable, requestedChunkSize)` partitions the input:

- Each render triangle is assigned to the chunk containing its centroid.
- Each collision convex is assigned to the chunk containing the center of its AABB.
- Full triangles and convexes are assigned; the current system does not clip geometry at chunk borders.
- A chunk's bounds include all vertices assigned to it, so bounds may extend across nominal grid-cell boundaries.
- Collision convexes retain their original global `_nkmIndex`, preserving stable `ConvexIndex` values in streamed client subsets.

## Client residency

Version 0.5 created and destroyed only `IMesh` objects based on distance, while retaining the entire map and collision data in client memory.

Version 0.6 changes that lifecycle:

1. The client receives a manifest containing chunk metadata only.
2. The client requests a chunk when its bounds are within `NKM.ChunkLoadDistance`.
3. The server sends that chunk's render vertices and collision hull descriptions.
4. The client validates the payload, builds its `IMesh` objects, and creates trace data for resident collision hulls.
5. When the chunk leaves `NKM.ChunkUnloadDistance`, the client destroys its `IMesh` objects and releases parsed render/collision arrays.
6. If the player returns, the chunk is requested again from the server.

`nkm_client_chunks` distinguishes manifest mesh groups from currently resident render meshes. For an unloaded chunk, `renderMeshes` and `collisionResident` should both be zero.

## Trace behavior

The server builds a complete trace map from all active chunks. The client rebuilds a partial trace map from collision chunks currently resident on that client. Global `ConvexIndex` values remain the same as the source map's collision-array indices, even when only some chunks are resident.

For authoritative gameplay traces, use the server-side NKM trace API. Client traces are useful for local effects and predictions but cannot hit collision data that has not been streamed to that client.

## Current configuration

```lua
NKM.DefaultChunkSize = 512
NKM.ChunkLoadDistance = 4096
NKM.ChunkUnloadDistance = 6144
```

The unload distance should be larger than the load distance to prevent boundary flicker.

## Current limitations

- Server map data, trace data, and all VPhysics proxies remain resident for the full map.
- Client chunks are fetched again after unload; no persistent disk cache exists yet.
- Visibility is distance-to-AABB based. Frustum, portal and occlusion culling are not implemented.
- Large triangles and convex hulls are not clipped or split at chunk boundaries.
- A chunk payload is JSON and is bounded by the prototype's 2 MiB per-map/per-chunk limits.
