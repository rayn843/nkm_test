# NKM Prototype 0.9.9-r6

## GShader per-pixel lighting

- Adds per-pixel NKM ambient/directional lighting from the dedicated NKM world-position and normal buffers.
- Evaluates AO, NKM ambient/directional lighting (pixel mode), and point lights in one unmasked full-screen pass over NKM receiver pixels; AO and screen-space blockers currently use NKM-only depth.
- Only NKM receiver pixels are shaded in this pass. Source BSP geometry, players and props are not included as occluders yet; screen-space contact shadows are opt-in and the fullscreen pass preserves destination alpha.
- Preserves vertex lighting as the default compatibility mode. After rebuilding `shaders/fxc/nkm_deferred_lighting_ps30.vcs`, enable the new path with `nkm_gshader_pixel_lighting 1` before the map's chunks load.

- The optional seventh NKM GShader debug panel decodes `_rt_NKM_WPDepth` into repeatable RGB world-coordinate bands. Build `shaders/nkm_wp_position_debug_ps30.hlsl` as `shaders/fxc/nkm_wp_position_debug_ps30.vcs` with the same Source shader compiler used for the deferred shader.
- The optional eighth debug panel reads `_rt_NKM_WPDepth` through sampler `s2` (the binding used by both normal reconstruction shaders). Build `shaders/nkm_wp_sampler2_debug_ps30.hlsl` as `shaders/fxc/nkm_wp_sampler2_debug_ps30.vcs` with the same compiler; compare it with panel seven to verify that the `$texture2`/`s2` binding exposes the same world-position data.
- The optional ninth debug panel computes the four-tap cross-product normal directly from `_rt_NKM_WPDepth` through sampler `s2`, before octahedral packing. Build `shaders/nkm_wp_4tap_normal_debug_ps30.hlsl` as `shaders/fxc/nkm_wp_4tap_normal_debug_ps30.vcs`; it derives one-pixel sample offsets from `ddx/ddy` of interpolated screen UVs (rather than the screen shader's `c4` constant). +Z is displayed as `(0.5, 0.5, 1.0)`. Compare it with panels four and five to determine whether the flat normal is produced by position derivatives or later normal-buffer handling.
- NKM's production normal buffer now uses `nkm_wpn_reconstruction_ps30.hlsl`, which derives pixel offsets from `ddx/ddy` of interpolated screen UVs and stores the GShader-compatible octahedral normal in RG. Compile it as `shaders/fxc/nkm_wpn_reconstruction_ps30.vcs` with the Source shader compiler before testing NKM per-pixel lighting; this replaces the stock GShader normal reconstruction only for the NKM-specific buffer.
- The tenth debug panel visualizes the direct NKM point-light contribution from the current NKM world-position/normal buffers and dynamic-light LUT, before scene-color blending and without contact-shadow filtering. Build `shaders/nkm_point_light_debug_ps30.hlsl` as `shaders/fxc/nkm_point_light_debug_ps30.vcs`. Use `nkm_gshader_lights` to print the active point-light positions, radii, colors, intensities and LUT dimensions.

NKM (NikNaks Map Runtime) is an experimental custom world format and runtime for Garry's Mod. It renders world geometry from NKM map data, streams chunks to clients, caches chunk payloads on disk, creates server-side VPhysics collision proxies, and provides custom NKM trace APIs. Version 0.9.7 adds an LDR BSP displacement lightmap importer that transfers RGBExp32 samples onto displacement grid vertices, keeps WorldVertexTransition alpha blending, and adds an optional baked per-vertex lighting render mode.

## New in 0.9.6.1 — Source-accurate BSP displacement import

- Reads the current BSP through `NikNaks.CurrentMap` / `BSPObject:GetLumpString()` and `NikNaks.BitBuffer`.
- Parses `DISPINFO` (lump 26), `DISP_VERTS` (33), `DISP_TRIS` (48), parent faces, surfedges, edges and vertices.
- Reconstructs regular displacement grids in Source row-major order from the parent quad, `startPosition`, displacement direction and distance.
- Reproduces Source alternating cell diagonals and keeps `DISP_TRIS` tags aligned with their source triangles.
- Preserves independent Source contents flags for physics-object collisions, player/NPC hull collisions and ray traces.
- Imports BSP texture axes / texture dimensions for UVs and resolves the material path from the texture string table.
- Preserves `DISPTRI_TAG_REMOVE` by omitting removed triangles; imported surfaces become NKM TriangleSurface patches.
- Exports to the existing NKM v1 JSON format, then loads the generated NKM map into the runtime.
- Adds `nkm_bspdisp_info` and `nkm_import_bsp_displacements` server commands.

This is a first-pass displacement-only conversion. It does not import BSP brushes, world faces, props, overlays, the full baked lightmap atlas, or Source's displacement-neighbor stitching/LOD data. Displacement per-vertex alpha is preserved for two-texture albedo blending; 0.9.7 adds a lower-resolution LDR per-vertex lighting approximation, but full BSP blend/lightmap shader behavior is not reproduced. It also does not remove the host BSP world; NKM geometry is loaded as a separate runtime world. The importer requires NikNaks on the server and currently handles quad-backed Source displacements with powers 2–4. See `docs/BSP_IMPORT.md`.

## New in 0.9.7 — BSP LDR lightmap and vertex-light mode

- Reads `FACES` style bytes, LDR `LIGHTING` (lump 8), and variable-length `DISP_LIGHTMAP_SAMPLE_POSITIONS` (lump 34).
- Decodes Source displacement sample records (triangle index plus barycentric weights) and maps LDR `RGBExp32` samples back to the regular displacement grid.
- Converts the first active LDR lightstyle to gamma-space vertex RGB and stores it as optional `vertexLighting` in NKM v1 displacement data.
- Transfers vertex lighting through chunk partitioning into IMesh vertex colors. Existing per-vertex `DispVert.alpha` still drives the second WorldVertexTransition texture layer.
- Adds `nkm_bspdisp_material lit`; `albedo` deliberately ignores baked light, while `lit` uses the imported per-vertex lighting approximation. Switching modes rebuilds currently resident BSP displacement meshes.
- Extends `nkm_bspdisp_client_info` with vertex-light coverage and range diagnostics.
- NKM file format remains v1; `vertexLighting` is optional, so older maps still load.

Lighting scope: this is a first-pass **LDR, first-lightstyle, per-vertex approximation**. It is not exact `LightmappedGeneric` rendering and does not yet support HDR lighting, animated/multiple lightstyles, the three directional bump-lightmap samples, or Source's final lightmap atlas. Displacement lightmap samples are barycentrically accumulated onto the grid vertices; vertices without direct samples inherit their nearest sampled grid vertex.

## New in 0.9.6.3 — BSP material compatibility

- Imported BSP displacement meshes now use the generic `Mesh()` vertex format instead of using a BSP world material as the IMesh format hint.
- Added an `albedo` render mode that wraps `$basetexture` and optional `$basetexture2` in `UnlitGeneric` materials.
- Source displacement per-vertex alpha is now preserved in NKM data and used to blend the second texture layer where `$basetexture2` exists.
- Added `nkm_bspdisp_material albedo|source` and extended `nkm_bspdisp_client_info` with shader/base-texture diagnostics.
- The `albedo` mode intentionally ignores baked BSP light. Runtime 0.9.7 adds a separate `lit` mode using imported LDR per-vertex lighting; this remains an approximation, not exact lightmap-atlas rendering.

## New in 0.9.6.2 — BSP displacement render diagnostics

- Tags imported displacement render groups separately from ordinary NKM meshes.
- Adds client command `nkm_bspdisp_render 0|1` to hide/show only imported BSP displacement overlays.
- Adds `nkm_bspdisp_debug 0|1` to replace source materials with a per-patch unlit diagnostic color.
- Adds `nkm_bspdisp_offset <units>` to rebuild loaded imported render meshes with a signed offset along their vertex normals (`-16..16`). The default is `0`.
- The offset changes only client IMesh positions. Physics and Trace geometry remain at the exact imported BSP coordinates.
- Adds `nkm_bspdisp_client_info` to report loaded imported groups, UV validity/ranges, source material names and current diagnostic settings.
- Retains imported source vertex groups only while their chunks are resident, so offset changes can rebuild IMesh without retaining all unloaded map geometry.

The diagnostics distinguish coincident-surface depth artifacts from source VMT/lightmap behavior. Version 0.9.6.3 added a first-pass UnlitGeneric two-texture albedo blend using DispVert alpha. Version 0.9.7 adds first-style LDR per-vertex light approximation; full BSP lightmap-atlas rendering and automatic removal/hiding of the host BSP geometry are still not implemented.

## Maintenance update 0.9.6.1

- Corrected Source displacement grid reconstruction to row-major vertex order and Source alternating cell diagonals.
- Preserved independent `contents` collision channels: physics props, player/NPC hulls and ray traces.
- Added server-side pair filtering for `NO_PHYS_COLLISION` and `NO_HULL_COLLISION` on TriangleSurface VPhysics proxies.
- `NKM.TraceLine` and `NKM.TraceHull` now respect the corresponding imported ray/hull flags.
- Added synthetic Source-layout and collision-channel regression tests.

## Maintenance update 0.9.5.1

- Fixed `nkm_client_status`: initialize the resident triangle counter before accumulating streamed triangle surfaces.
- Runtime version is now reported as `0.9.5.1`; map format remains v1.

## New in 0.9.5 — TriangleSurface / displacement prototype

- Adds optional regular-grid `displacements` to format v1.
- Triangulates a grid into IMesh render groups and per-chunk triangle payloads.
- Creates static VPhysics triangle-soup proxies with `Entity:PhysicsFromMesh`, one per chunk/surface-property group.
- Includes triangle surfaces in NKM TraceLine/TraceHull BVH queries.
- Adds triangle hit metadata (`TriangleIndex`, `TriangleSurfaceIndex`, `ChunkID`, `SurfaceProp`) and triangle-aware `NKM.GetSurfaceData(trace)`.
- Adds server command `nkm_displacement_test`, generating 25x25 terrain (1,152 triangles) near the invoking player.
- Adds resident triangle counts to `nkm_status` and per-chunk triangle counts to `nkm_server_chunks`.

The VPhysics mesh is hosted by an invisible server-side proxy Entity. VPhysics performs the actual collision; Lua is not a rigid-body solver. TriangleSurface is for static terrain only: PhysicsFromMesh produces a hollow, zero-volume triangle soup and is not suitable for moving closed solids. Keep `PhysicsInitMultiConvex` for ConvexSolid. See `docs/DISPLACEMENTS.md`.

## Install

1. Remove the previous `nkm_prototype` addon folder.
2. Extract this archive into `garrysmod/addons/` so the final path is `garrysmod/addons/nkm_prototype/`.
3. Confirm `garrysmod/addons/nkm_prototype/lua/autorun/nkm_init.lua` exists. Do not leave an extra versioned folder between `addons/` and `nkm_prototype/`.
4. Restart the server and reconnect clients so both realms load the same runtime.

## First displacement test

Run from server console or as an admin:

```text
nkm_displacement_test
nkm_status
nkm_server_chunks
nkm_trace_test
```

The command saves and loads a synthetic wavy terrain grid centered around the invoking player's position (or origin when run from server console). Expected generator message: `grid=25x25 triangles=1152`.

On the client:

```text
nkm_client_status
nkm_client_chunks
nkm_client_trace_test
```

Walk over the terrain, jump, run across chunk boundaries, drop static/physics props, and test the custom trace. Then fly away with noclip to verify server collision proxy unload and reactivation on return.

## What to expect

- Default chunk edge: 512 units.
- A 25x25 grid contains 576 cells and 1,152 triangles.
- The generated surface is split by triangle centroid; each triangle is stored in one chunk and the chunk bounds include its full vertex extent.
- Each loaded chunk groups triangle collision vertices by surface property and creates one PhysicsFromMesh proxy per group.
- VPhysics residency uses the same player/entity distance system as convex collision.
- Triangle surfaces are present in TraceLine and TraceHull. They are zero-volume surfaces, so PointContents and solid-volume FindInBox/FindInSphere continue to query convex solids only.

## Import displacements from the current BSP

NikNaks must be installed and loaded on the server. First inspect the currently loaded BSP:

```text
nkm_bspdisp_info
```

Then import up to 64 displacement patches by default:

```text
nkm_import_bsp_displacements
```

Or specify an NKM output name and an explicit patch limit:

```text
nkm_import_bsp_displacements my_imported_terrain 96
```

The importer writes `data/nkm/maps/<name>.json` and immediately loads that NKM map. The default 64-patch limit is conservative for the prototype's 2 MiB map JSON limit and 250,000 generated-vertex limit. Increasing the patch limit may cause validation or file-size rejection. For a real map, check the console summary for imported/skipped patches and warnings. The importer currently takes the first valid displacement records in BSP order; it is not yet a full-map batch/region importer.

## BSP displacement material and lighting modes (0.9.7)

After re-importing BSP displacements with the new version, use:

```text
nkm_bspdisp_debug 0
nkm_bspdisp_offset 0
nkm_bspdisp_material albedo
nkm_bspdisp_client_info
```

`albedo` uses stable UnlitGeneric wrappers for `$basetexture` and `$basetexture2`, with `DispVert.alpha` driving the second texture layer. It ignores baked BSP light and is useful for material/UV comparison.

To apply the imported LDR baked-light approximation:

```text
nkm_bspdisp_material lit
nkm_bspdisp_client_info
```

`lit` uses the same two UnlitGeneric texture layers but multiplies them by the imported per-vertex RGB light values. The conversion uses the first active LDR lightstyle and the displacement lightmap sample-position lump. It is an approximation because lightmap luxels are barycentrically accumulated to displacement grid vertices; it is not the exact Source lightmap atlas, HDR pipeline, animated lightstyles or bump lighting. Switching between `albedo`, `lit` and `source` rebuilds loaded BSP displacement render meshes.

Use `nkm_bspdisp_material source` only for comparison with the original VMT shader path; world-only shaders may still be unsupported on IMesh.

## Diagnose imported displacement rendering (0.9.6.2)

The importer tags BSP-origin render groups. Re-run `nkm_import_bsp_displacements <same_name> <patch_limit>` after upgrading so the map receives the latest vertex-alpha payload and material metadata; old NKM v1 files remain readable, but old imported maps default blend alpha to fully opaque.

On the client, with imported BSP chunks loaded:

```text
nkm_bspdisp_client_info
nkm_bspdisp_debug 1
nkm_bspdisp_offset 1
```

If the surface moves in the wrong direction, try `nkm_bspdisp_offset -1`. Use `nkm_bspdisp_offset 0` to restore exact BSP coordinates. Use `nkm_bspdisp_render 0` to hide only the NKM imported displacement overlay and compare it with the original host BSP surface; use `nkm_bspdisp_render 1` to show it again. `nkm_bspdisp_debug 0` restores source materials.

The normal offset is a render-only diagnostic. It does not move VPhysics collision or NKM Trace triangles. `nkm_bspdisp_client_info` reports UV ranges and missing/invalid UV counts only for currently resident chunks.

## Existing features retained

- JSON map format v1, existing convex collision, and user-selected unlit material: `UnlitGeneric` with `$vertexcolor=1` and `$nocull=1`.
- Client/server chunk streaming and server physics residency.
- Persistent client cache under `data/nkm/cache/`.
- Per-chunk Trace BVH cache and profiling.
- Render stress and full-physics benchmark commands from 0.9.4.

## Important commands

| Command | Realm | Purpose |
|---|---|---|
| `nkm_displacement_test` | Server | Generate and load the terrain grid test |
| `nkm_test` | Server | Generate and load the demo room |
| `nkm_status` | Server | Runtime, collision, triangle and trace stats |
| `nkm_server_chunks` | Server | Per-chunk collision residency and triangle counts |
| `nkm_trace_test` | Server | Test server-side NKM trace |
| `nkm_client_status` | Client | Render, collision, triangle, trace and cache stats |
| `nkm_client_chunks` | Client | Per-chunk client residency |
| `nkm_client_trace_test` | Client | Test client-side streamed NKM trace |
| `nkm_server_perf` | Server | Server profiler |
| `nkm_server_perf_reset` | Server | Reset server profiler |
| `nkm_client_perf` | Client | Client profiler |
| `nkm_client_perf_reset` | Client | Reset client profiler |
| `nkm_cache_status` | Client | Disk cache diagnostics |

## Known limitations

- The BSP importer currently converts displacement surfaces only; it does not import ordinary world brushes/faces, static props, overlays, water, the full lightmap atlas, or full neighbor stitching/LOD. Two-texture albedo blending and LDR per-vertex lighting are compatibility approximations, not full Source lighting. The original BSP remains loaded as the Source host world.
- PhysicsFromMesh collision is hollow and may have holes; patch boundaries, winding and contact behavior require in-game validation.
- `PointContents`, `FindInBox` and `FindInSphere` currently skip zero-volume triangle surfaces. Use TraceLine/TraceHull for triangle-surface queries.
- The runtime still uses JSON v1; a packed binary container is future work.
- No editor, full NKM lightmap-atlas/HDR pipeline, visibility system, or navigation system yet. The current LDR per-vertex BSP lighting approximation is documented in `docs/LIGHTING.md`.
- Lua heap does not include native IMesh/VPhysics allocations.
- The addon has not been executed in Garry's Mod from this build environment. Lua syntax and core geometry/trace tests are performed here; in-game VPhysics behavior must be checked by the user.


## Maintenance update 0.9.5.2 — Sandbox prop placement

- Added a server-side `PlayerSpawnedProp` bridge for the Sandbox prop spawner.
- The bridge recomputes the player's standard 2048-unit aim ray using `NKM.TraceLine`; if NKM terrain is the nearest hit, it places the prop flush against that terrain.
- A next-tick correction runs after Sandbox's own `TryFixPropPosition()` adjustment.
- Added `nkm_spawn_trace_test` to compare raw Source `util.TraceLine` against the combined NKM trace.
- This is a Sandbox prop-spawn integration only; it does not globally replace `util.TraceLine` for other addons. Those systems should call `NKM.TraceLine` or the appropriate NKM trace API.
- NKM map format remains v1.
