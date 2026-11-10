# NKM 0.9.7 — Source BSP displacement importer, LDR lighting and render diagnostics

## Dependency and scope

The importer runs on the server and requires NikNaks to be installed and loaded. It reads the currently loaded BSP through `NikNaks.CurrentMap` (falling back to `NikNaks.Map()`), then uses `BSPObject:GetLumpString(lumpID)` and `NikNaks.BitBuffer` to parse binary records.

The importer converts **displacement surfaces only**. It does not convert world brushes, ordinary BSP faces, static props, overlays, water, or Source's complete displacement neighbor stitching / tessellation rules. Version 0.9.7 additionally reads LDR displacement lightmap samples and converts them to per-vertex color data; this is an approximation rather than full Source lightmap-atlas rendering. The original BSP remains the Source host level; this command does not replace or unload it.

## Commands

Inspect the current BSP:

```text
nkm_bspdisp_info
```

Import using the default output name `bspdisp_<currentmap>` and a conservative limit of 64 valid patches:

```text
nkm_import_bsp_displacements
```

Specify an output name and a patch limit:

```text
nkm_import_bsp_displacements my_terrain 96
```

The importer writes the NKM map to `data/nkm/maps/<outputName>.json` and immediately calls `NKM.LoadMap(outputName)`. The command is server-console/admin only.

The default limit is 64 because the prototype currently limits the serialized source map to 2 MiB and total generated mesh vertices to 250,000. Larger values can fail NKM validation or JSON-size checks; increase the limit only after inspecting the actual BSP's displacement powers and the export result. If the limit is reached, the importer currently takes the first valid displacement records in BSP order and reports the remainder as skipped. It is not yet a spatial selection or multi-part batch exporter.

## Parsed BSP data

| Lump | ID | Use |
|---|---:|---|
| TEXDATA | 2 | Texture dimensions and material string-table index |
| VERTEXES | 3 | Parent-face corner positions |
| TEXINFO | 6 | Texture projection axes |
| FACES | 7 | Parent face, edge range, texture data and displacement reference |
| EDGES | 12 | Vertex pairs |
| SURFEDGES | 13 | Signed edge references and winding |
| DISPINFO | 26 | `startPosition`, offsets, power and parent-face index |
| LIGHTING | 8 | LDR RGBExp32 lightmap sample data |
| DISP_VERTS | 33 | Per-grid-vertex displacement direction, distance and alpha |
| DISP_LIGHTMAP_SAMPLE_POSITIONS | 34 | Variable-length triangle-index and barycentric records for displacement luxels |
| TEXDATA_STRING_DATA | 43 | Material-name strings |
| TEXDATA_STRING_TABLE | 44 | String offsets |
| DISP_TRIS | 48 | Per-triangle tags, including `DISPTRI_TAG_REMOVE` |

The importer supports standard quad-backed Source displacements with power 2, 3 or 4. For each displacement it finds the parent face's four corners, rotates them so the corner nearest `startPosition` is first, then reconstructs the grid in Source's row-major order (`y * side + x`). The grid's horizontal axis runs from Source corner 0 toward corner 3; its vertical axis runs from corner 0 toward corner 1. Each cell uses Source's alternating diagonal rule, based on `(y * side + x) % 2`, so the `DISP_TRIS` row-major tags remain aligned with their triangles. The importer bilinearly interpolates the base quad, then adds `direction * distance` from the corresponding displacement vertex. Texture UVs are calculated from the face's texture axes and texture dimensions. The `REMOVE` triangle tag (bit 5) is preserved by excluding that triangle from rendering, collision and NKM tracing.

The `ddispinfo_t.contents` bits are preserved as three independent channels. File bit `0x2` disables collisions with physics objects, `0x4` disables player/NPC hull collisions, and `0x8` disables ray collisions; these bits are inverted, so a cleared bit means that channel is enabled. NKM applies these as follows: a TriangleSurface proxy filters the corresponding VPhysics pair types with `ShouldCollide`, `NKM.TraceHull` checks the hull channel, and `NKM.TraceLine` checks the ray channel. Ordinary convex solids retain their existing all-channel behavior. External addons calling raw `util.TraceLine` directly are not globally patched; they should use `NKM.TraceLine` to honor imported NKM ray flags.

The current implementation expects the standard 176-byte `ddispinfo_t` and 56-byte `dface_t` records used by the Source BSP structures. A different BSP branch or layout is rejected with a clear lump-size error rather than being parsed with guessed offsets. NikNaks exposes current-map access and raw lump reads through its BSP API; Source SDK defines the relevant lump IDs, record structures and displacement triangle flags.

## Material and surface behavior

- The imported material name comes from the BSP texture string table. The renderer attempts to use the mounted Source material; if it is not available, it falls back to the NKM unlit material.
- `$surfaceprop` is read from the mounted VMT when possible. If unavailable, the importer falls back to `dirt`.
- The importer calculates diffuse texture UVs and preserves per-vertex displacement alpha. In 0.9.7 it also reads the first active LDR lightstyle from lump 8 and maps the sample colors to grid vertices using lump 34 barycentric sample positions. It does not import the full lightmap atlas, HDR lightmaps, additional animated lightstyles, three directional bump-lightmap samples, detail textures, cubemap behavior or the full original Source shader.
- Neighbor records are not yet used to stitch different displacement powers or reproduce Source's tessellation/LOD transitions. Adjacent displacement seams must be checked in-game.

## LDR displacement lighting (0.9.7)

The importer reads the parent `dface_t` lighting metadata (`styles`, `lightofs`, `lightmapTextureMinsInLuxels` and `lightmapTextureSizeInLuxels`). For each face luxel, Source's `DISP_LIGHTMAP_SAMPLE_POSITIONS` record identifies a displacement triangle and three barycentric weights. NKM decodes the first active LDR `RGBExp32` style from lump 8, converts it to gamma-space RGB, and accumulates the color into the three referenced displacement grid vertices. A grid vertex without a direct sample receives the nearest sampled vertex color to prevent unlit pinholes.

This data is optional in NKM v1 as `vertexLighting`. Old NKM maps without it remain valid. It affects render vertex colors only; VPhysics and NKM Trace geometry are unchanged.

Client modes:

| Command | Effect |
|---|---|
| `nkm_bspdisp_material albedo` | Stable texture-only mode; ignores imported baked-light vertex colors. |
| `nkm_bspdisp_material lit` | Applies the imported LDR per-vertex light approximation to both texture layers. |
| `nkm_bspdisp_material source` | Attempts the original BSP world material on IMesh for comparison. |
| `nkm_bspdisp_material lit` | Applies the imported LDR per-vertex light approximation to both texture layers. |
| `nkm_bspdisp_material source` | Attempts to use the original BSP material/shader on IMesh for comparison. |

Changing the mode rebuilds currently resident BSP displacement meshes. `nkm_bspdisp_client_info` reports the number and range of resident BSP vertex-light colors.

Limitations: only the first active LDR style is imported. HDR lump 53, animated/additional lightstyles, bump-lightmap directions, exact lightmap atlas sampling, lightmap filtering and dynamic lighting are not supported yet. Per-vertex lighting can appear smoother/coarser than the original BSP lightmap because many luxels are reduced to the displacement's regular grid vertices.

## Client render diagnostics (0.9.6.2)

Imported BSP render groups carry an explicit `isBSPDisplacement` marker, allowing the client to inspect or hide them without affecting ordinary NKM meshes. Re-run the BSP importer after upgrading from 0.9.6.1 so previously exported NKM maps receive this marker; existing map files remain readable but are not recognized by the BSP-only render controls until regenerated.

| Client command | Effect |
|---|---|
| `nkm_bspdisp_render 0|1` | Hide/show only imported BSP displacement render meshes. |
| `nkm_bspdisp_debug 0|1` | Use/stop using per-displacement unlit debug colors, bypassing the source VMT for visual diagnosis. |
| `nkm_bspdisp_offset <units>` | Rebuild loaded imported IMesh with a signed offset along vertex normals, clamped to -16..16 units. |
| `nkm_bspdisp_client_info` | Report resident BSP groups, vertex count, UV validity/ranges, material names and current render settings. |

The default normal offset is 0. Positive values move along the imported vertex normals; negative values move against them. The offset is applied while building client IMesh only. It does not change source NKM vertex data, server VPhysics proxies, collision residency, or Trace BVH coordinates. Source render vertices are retained only while an imported chunk is resident so the user can change the offset and rebuild its IMesh; they are released when the chunk unloads.

Suggested diagnosis for dark or triangular overlays:

1. Run `nkm_bspdisp_client_info` and check whether UVs are present/finite and whether source materials resolve.
2. Run `nkm_bspdisp_debug 1`. If per-patch colors are clean, geometry is being drawn and the original material/lightmap path is a stronger suspect.
3. Run `nkm_bspdisp_offset 1`; if the depth artifacts change or disappear, coincident BSP/NKM surfaces are likely z-fighting. If it moves in the wrong direction, try `-1`.
4. Run `nkm_bspdisp_render 0` to hide the NKM overlay and compare the untouched BSP world; restore with `nkm_bspdisp_render 1`.
5. Restore defaults with `nkm_bspdisp_offset 0` and `nkm_bspdisp_debug 0`.

These controls are diagnostic, not a full material/lightmap solution. The 0.9.6.3 albedo mode approximates the two base-texture blend with UnlitGeneric passes and retained vertex alpha. Runtime 0.9.7 adds first-style LDR per-vertex lighting, but does not reproduce the original lightmap atlas, HDR, bump lighting or animated styles. Detail materials, overlays and neighbor stitching are still not imported. The original BSP remains visible as the host world.

## Validation workflow

1. Ensure NikNaks is loaded on the server.
2. Run `nkm_bspdisp_info` and confirm non-zero displacement count, sensible power counts, and the `noPhysics` / `noHull` / `noRay` channel counts. Those three counts report surfaces with the corresponding source collision channel disabled.
3. Run `nkm_import_bsp_displacements test_import 32` for a conservative first pass.
4. Check the importer summary for `patches`, `skipped`, vertices, triangles, removed triangles and file size.
5. Run `nkm_status`, `nkm_server_chunks`, `nkm_trace_test` on the server.
6. On the client run `nkm_client_status`, `nkm_client_chunks` and `nkm_client_trace_test`.
7. Inspect terrain shape, material orientation, seams, walking and props. In particular verify winding, UV orientation and shared boundaries on the actual map.

The repository test `tests/bsp_import.lua` feeds synthetic binary BSP lumps into the same importer code and validates row-major vertex placement, UV generation, Source collision flags and the generated NKM displacement table. `tests/triangle_core.lua` verifies the alternating-diagonal topology and separate ray/hull trace behavior. These tests do not replace testing against a real mounted BSP and actual VPhysics in Garry's Mod.

## References

- NikNaks BSP API: `CurrentMap`, `Map()`, `GetLumpString()`: https://github-wiki-see.page/m/Nak2/NikNaks/wiki/BSP-Parser
- NikNaks BitBuffer API: `Seek`, typed reads, little-endian support: https://github-wiki-see.page/m/Nak2/NikNaks/wiki/BitBuffer
- Valve Source SDK `bspfile.h`: lump IDs, `ddispinfo_t`, `CDispVert`, `DISPTRI_TAG_REMOVE`, `dface_t`: https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/public/bspfile.h
- Displacement reconstruction example using the parent quad, `startPosition` and `direction * distance`: https://github.com/thomasfn/HL2UE4AssetImporter/blob/master/Source/HL2Editor/Private/BSPImporter.cpp


## Rendering compatibility (0.9.6.3)

BSP world materials are not guaranteed to be usable by dynamic IMesh. In particular, WorldVertexTransition is a world/displacement shader rather than a generic dynamic-mesh material, and LightmappedGeneric expects lightmap coordinates plus a lightmap texture. NKM therefore offers an `albedo` preview path: it extracts `$basetexture` and optional `$basetexture2`, wraps them in UnlitGeneric, and uses the original displacement vertex alpha for the second layer. This path is stable and camera-independent, but it does not yet reproduce the BSP baked lightmap, bump lighting, or every shader proxy. Use `nkm_bspdisp_material source` only for comparison; use `nkm_bspdisp_material albedo` for the compatibility path.

The client diagnostic command `nkm_bspdisp_client_info` reports the material shader/base texture channels and, in `lit` mode, how many resident vertices received imported LDR light data.
