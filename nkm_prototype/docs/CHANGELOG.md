## 0.9.7

- Imports Source LDR displacement lightmaps from `LIGHTING` lump 8 and displacement sample-position lump 34.
- Preserves unsigned face lightstyle bytes, light offsets and lightmap sample dimensions.
- Decodes Source triangle-index/barycentric sample records and maps RGBExp32 samples onto displacement grid vertices.
- Stores optional `vertexLighting` in NKM v1 and validates/transfers it through chunk rendering.
- Adds client `nkm_bspdisp_material lit` mode using per-vertex baked-light approximation while preserving the two-layer UnlitGeneric WorldVertexTransition blend.
- `albedo` remains a stable no-baked-light diagnostic; `source` remains available for shader comparison.
- Extends client diagnostics and importer summary with lightmap sample/vertex-color coverage.
- Does not yet implement HDR, multiple/animated lightstyles, bump-lightmap directions, or exact Source lightmap atlas rendering.
- NKM map format remains version 1; `vertexLighting` is optional and backward compatible.

## 0.9.6.3

- Added a compatibility render path for BSP displacement materials using generic IMesh vertex format and UnlitGeneric albedo wrappers.
- Preserved Source DispVert alpha in NKM mesh vertices and used it for optional second-texture blending.
- Added shader/base-texture diagnostics and material-mode command.
- Explicitly documents that baked BSP lightmaps are not yet reproduced in albedo mode.

## 0.9.6.2
- Tagged generated render groups originating from BSP displacement patches.
- Added client commands to hide/show imported BSP overlays, enable per-patch unlit debug colors, and rebuild loaded imported IMesh with a signed vertex-normal offset.
- Added client-side UV/material diagnostics for currently resident imported displacement groups.
- Kept render offset strictly client-visual; VPhysics and Trace coordinates remain unchanged.
- Retained source render vertices only for resident imported chunks, releasing them on unload.
- Added regression coverage that the BSP source marker propagates from importer patches into streamed render group metadata.
- NKM format remains version 1.

## 0.9.6.1
- Corrected BSP displacement vertex reconstruction to Source row-major ordering and Source alternating cell diagonals.
- Preserved independent DISPINFO contents collision channels for physics props, player/NPC hulls and ray traces.
- Added TriangleSurface `ShouldCollide` filtering for the physics-object and hull channels.
- Made NKM TraceLine/TraceHull respect imported ray/hull collision flags.
- Added `nkm_bspdisp_info` collision-channel diagnostics.
- Added synthetic regression coverage for Source topology, row-major vertex placement and collision channels.
- NKM file format remains version 1.

## 0.9.6.0
- Added server-side NikNaks BSP displacement importer using raw Source BSP lumps.
- Reconstructs power 2–4 displacement grids from `DISPINFO`, `DISP_VERTS`, parent quad faces and vertex/edge data.
- Imports BSP material names, texture-axis UVs and `DISPTRI_TAG_REMOVE` filtering into NKM TriangleSurface.
- Adds `nkm_bspdisp_info` and `nkm_import_bsp_displacements` commands.
- Preserves the NKM v1 map format; adds a synthetic-lump importer test.
- Limitation: displacement geometry only; brushes, lightmaps, alpha blends, overlays, props and neighbor stitching are not imported yet.

## 0.9.5.2
- Added NKM-aware placement correction for props spawned through the Sandbox `PlayerSpawnedProp` flow.
- Added `nkm_spawn_trace_test` to compare Source and combined NKM spawn rays.
- Kept the integration scoped to Sandbox prop spawning; no global `util.TraceLine` override.

## 0.9.5.1
- Fixed an uninitialized local counter in the client status command that caused `nkm_client_status` to error on maps containing TriangleSurface patches.
- Updated the runtime version string; NKM format remains v1.

## 0.9.5
- Added optional regular-grid `displacements` to NKM format v1.
- Added grid validation, triangulation, generated IMesh vertex groups and chunk partitioning.
- Added static `PhysicsFromMesh` triangle-surface proxies per collision chunk/surface property.
- Added triangle-surface support to TraceLine and TraceHull, sharing the per-chunk and root BVH hierarchy with convex solids.
- Added triangle hit metadata and triangle-aware `NKM.GetSurfaceData(trace)`.
- Added `nkm_displacement_test` to generate a 25x25 terrain grid (1,152 triangles).
- Added resident/total triangle counts to server status and per-chunk diagnostics.
- Fixed client trace candidate denominator to include triangle candidates.
- NKM file format remains version 1; older runtimes must not connect to a map containing streamed triangle-surface payloads.

## 0.9.4
- Split synthetic benchmarking into render-stress and full-physics modes.
- Added `nkm_benchmark render 500|1000` and `nkm_benchmark fullphysics 100`.
- Kept legacy `nkm_benchmark 500|1000` syntax for compatibility.
- Added design documentation for displacement rendering and triangle-soup VPhysics using `PhysicsFromMesh`.
- No NKM map-format change; format version remains 1.

## 0.9.3
- Added synthetic 500/1000-chunk large-world benchmark.
- Added generation, serialization, validation and residency profiling.
