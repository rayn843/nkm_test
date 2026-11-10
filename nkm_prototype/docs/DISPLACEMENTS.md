# NKM TriangleSurface and displacement prototype (0.9.5.1)

## What is implemented

NKM 0.9.5 adds an optional regular-grid `displacements` field to the v1 map JSON. The runtime triangulates each grid into client render geometry, per-chunk triangle-surface payloads, and an independent triangle BVH for `NKM.TraceLine` / `NKM.TraceHull`. The server creates static triangle collision proxies with `Entity:PhysicsFromMesh`, one proxy per chunk and surface-property group. The proxies are still invisible scripted entities; VPhysics performs collision, Lua does not simulate contacts.

The prototype test map is generated with `nkm_displacement_test`. It is a 25 x 25 vertex grid, yielding 1,152 triangles. With the default 512-unit chunk size, it is split spatially into several runtime chunks. The map is saved as `disptest` in `data/nkm/maps/`.

## Why PhysicsFromMesh

`Entity:PhysicsFromMesh(vertices, surfaceprop)` accepts a triangle-soup mesh. Facepunch documents it as hollow, zero-volume geometry that may contain holes, and explicitly identifies static terrain displacements as a suitable use. For correct player collision and trace behavior, call `Entity:EnableCustomCollisions()` after building the mesh. See the official [Entity API](https://wiki.facepunch.com/gmod/ENTITY) and [EnableCustomCollisions](https://wiki.facepunch.com/gmod/Entity:EnableCustomCollisions).

The NKM proxy is positioned at the center of the chunk collision bounds. Triangle vertex positions are translated into that entity's local coordinate space before `PhysicsFromMesh` is called. The resulting PhysObj is put to sleep and its motion is disabled.

## Physical geometry types

- **ConvexSolid** — enclosed walls, boxes, solid props and dynamic/closed objects. Uses `PhysicsInitMultiConvex`.
- **TriangleSurface** — static terrain, imported displacements, ground and non-volumetric surface patches. Uses `PhysicsFromMesh`.
- **TraceOnly** — geometry intended for custom NKM traces but not VPhysics. This type is reserved for a later explicit format field; it is not yet an authorable root-map field in 0.9.5.

This is not a custom rigid-body solver. VPhysics still owns contacts and collision response. The entity is only the GLua-accessible host for a custom collision mesh because the public GLua API does not expose a way to append arbitrary triangles directly to Source `worldspawn`.

## Test procedure

1. Install 0.9.5 on server and clients, then restart the server and reconnect clients.
2. Run `nkm_displacement_test` from server console or as an admin.
3. Inspect `nkm_status` and `nkm_server_chunks`.
4. On the client, inspect `nkm_client_status`, `nkm_client_chunks`, and run `nkm_client_trace_test`.
5. Walk on the hills, jump, run across patch boundaries, drop several physics props, and test server/client trace results.
6. Fly away with noclip to verify collision proxies unload, then return and verify they are recreated.

Expected generation summary: `grid=25x25`, `triangles=1152`. Exact runtime chunk/patch counts can depend on the invoking player's position relative to chunk boundaries.

## Current limitations and risks

- `PhysicsFromMesh` creates a hollow, zero-volume triangle soup, not a closed solid. It is for static surfaces, not dynamic solid bodies.
- VPhysics may expose holes if winding, degenerate faces, borders or T-junctions are invalid. The validator rejects degenerate grid triangles, but in-game seam and contact tests remain necessary.
- Each generated displacement triangle is assigned to a chunk by its centroid, not clipped at chunk boundaries. Chunk bounds include all triangle vertices, so streaming bounds remain conservative.
- The current synthetic displacement is a regular grid, not yet a direct importer for Hammer/BSP displacement data. Importing Source displacement power, alpha/blend layers, multiblend materials, lightmaps and neighbor stitching remains future work.
- `NKM.PointContents`, `FindInBox` and `FindInSphere` currently query solid convex volumes, not zero-volume triangles. Triangle surfaces participate in `TraceLine` and `TraceHull`.
- Client and server must run the same NKM runtime version for triangle-surface payloads. Format version remains 1, but older runtime versions do not understand the optional `triangleSurfaces` chunk payload field.
- PhysicsFromMesh proxies are server-side entities and are still subject to Source/GMod entity and VPhysics limitations.

## API notes

`NKM.TraceLine` and `NKM.TraceHull` return `HitNKM = true` and triangle metadata in `trace.NKM`: `TriangleIndex`, `TriangleSurfaceIndex`, `ChunkID`, and `SurfaceProp`. `NKM.GetSurfaceData(trace)` now resolves triangle hits as well as convex hits.


## Sandbox prop placement integration (0.9.5.2)

Sandbox's stock prop placement computes its aim hit with `util.TraceLine`. NKM exposes a combined `NKM.TraceLine` that tests both Source geometry and NKM geometry. The runtime now hooks `PlayerSpawnedProp`, repeats the same 2048-unit player aim ray through `NKM.TraceLine`, and moves the newly spawned prop to the NKM hit when NKM terrain is the nearest surface. A next-tick correction runs after Sandbox's own post-spawn fixup.

Use `nkm_spawn_trace_test` while looking at the displacement to compare raw Source trace output with the combined NKM trace. The bridge only covers the stock Sandbox prop-spawn path; third-party addons that perform their own placement traces must call `NKM.TraceLine` themselves.
