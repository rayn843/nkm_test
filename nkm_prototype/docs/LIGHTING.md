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
