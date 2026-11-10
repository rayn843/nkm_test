# NKM 0.9.7 — BSP displacement lighting

## Data path

1. Read the parent face's unsigned `styles[4]`, `lightofs`, and `lightmapTextureSizeInLuxels` from the 56-byte `dface_t`.
2. Use `ddispinfo_t.lightmapSamplePositionStart` as a byte offset into lump 34.
3. Read `(sizeS + 1) * (sizeT + 1)` sample-position records. A record contains a triangle index byte (or `255` followed by an extension byte) and three barycentric bytes.
4. Read the first active LDR lightstyle from lump 8 as `RGBExp32` values, one 4-byte sample per face luxel.
5. Convert each RGBExp32 sample to gamma-space RGB, then barycentrically accumulate it into the three regular displacement-grid vertices corresponding to that triangle.
6. Store the optional color array as `patch.vertexLighting`; chunk generation places it into IMesh vertex colors.

## Render modes

- `nkm_bspdisp_material albedo`: white vertex multiplier; texture projection and DispVert alpha blending only.
- `nkm_bspdisp_material lit`: imported per-vertex LDR color multiplies both the base and second texture layers.
- `nkm_bspdisp_material source`: use original VMT source material for comparison (not guaranteed to work for world-only shaders on IMesh).

Changing the material mode rebuilds loaded BSP displacement meshes so the correct vertex colors are baked into the IMesh.

## Scope and known limits

This is a per-vertex approximation to the first active LDR lightstyle, not an exact lightmap atlas implementation. It does not yet support HDR lump 53, multiple/animated lightstyles, bump-lightmap's three directional samples, Source's final lightmap filtering/atlas pages, or dynamic lighting. The lightmap is attached to the displacement grid by barycentric accumulation; that reduces lightmap resolution to the displacement grid and can look softer/coarser than the host BSP.

Vertex lighting is optional in NKM format v1. Legacy maps without it still validate and render as before.

## Offline validation

`tests/bsp_import.lua` builds a synthetic 17x17 LDR lightmap, emits 289 source sample-position records, runs the real importer, and verifies the RGBExp32-to-vertex conversion and propagation to chunk render vertices.


## Deferred per-pixel lighting (GShader)

When the updated `nkm_deferred_lighting_ps30.vcs` is installed and `nkm_gshader_pixel_lighting 1` is set before the map's chunks load, NKM ambient and directional light are evaluated per pixel from GShader's reconstructed world-position and world-normal buffers. In this mode the client does not multiply NKM vertex colors by the server-side `nkmLighting` bake. The existing vertex bake remains the compatibility path by default.

AO, NKM ambient/directional lighting (when pixel mode is enabled), and all NKM point lights are evaluated together in one unmasked full-screen pass over the visible opaque GShader GBuffer. The pass does not use the NKM stencil mask to limit lighting, so Source BSP surfaces and visible NKM surfaces are handled by the same pixel shader. Opaque players and props are included when they are represented in GShader's depth/normal buffers. The NKM stencil mask is retained only as an optional debug visualization.

Directional and point shadows are screen-space approximations using the GShader world-position buffer. Off-screen occluders and transparent materials are not represented by the opaque GBuffer. Imported BSP displacement `lit` mode uses its albedo path when pixel lighting is enabled; its original LDR per-vertex bake remains available in compatibility mode.

**Compilation requirement:** the updated HLSL must be compiled into `shaders/fxc/nkm_deferred_lighting_ps30.vcs` with the Source/GMod shader toolchain. The checked-in VCS is the previous compiled version and does not contain the new ambient/directional c2-c10 shader constants. Do not set `nkm_gshader_pixel_lighting 1` until that VCS has been rebuilt. The convar defaults to `0` to preserve the existing vertex-light fallback.
