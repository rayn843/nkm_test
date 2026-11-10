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

When the updated `nkm_deferred_lighting_ps30.vcs` is installed and `nkm_gshader_pixel_lighting 1` is set before the map's chunks load, NKM ambient and directional light are evaluated per pixel from the dedicated NKM world-position and world-normal buffers. In this mode the client does not multiply NKM vertex colors by the server-side `nkmLighting` bake. The existing vertex bake remains the compatibility path by default.

AO, NKM ambient/directional lighting (when pixel mode is enabled), and all NKM point lights are evaluated together in one unmasked full-screen pass. The production material uses exactly the four texture slots exposed by `screenspace_general`: NKM world position, NKM normal, the dynamic-light LUT, and the scene-color copy (`s0`–`s3`). NKM receiver pixels use the dedicated NKM world-position and normal buffers, including where NKM meshes coincide with the host BSP. AO and screen-space blocker samples currently use NKM depth only; Source BSP occluders are not included in this four-sampler pass. This avoids relying on the engine's internal SSAO depth pass to include Lua-drawn IMesh objects. The NKM stencil mask is retained only as an optional debug visualization.

Directional and point shadows are experimental screen-space approximations using the NKM-only world-position buffer. They can produce camera-dependent artifacts and are disabled by default with `nkm_gshader_contact_shadows 0`; enable them explicitly for testing. Source BSP occluders, off-screen occluders and transparent materials are not represented in this pass. The fullscreen color pass replaces RGB while preserving the destination alpha channel, because Source may use that channel for depth-related data. Imported BSP displacement `lit` mode uses its albedo path when pixel lighting is enabled; its original LDR per-vertex bake remains available in compatibility mode.

**Compilation requirement:** compile the current HLSL into `shaders/fxc/nkm_deferred_lighting_ps30.vcs` with the Source/GMod shader toolchain. The compiled shader must include the ambient/directional c2-c10 constants and use only the four `screenspace_general` texture samplers: NKM world position at s0, NKM normal at s1, dynamic-light LUT at s2, and scene color at s3. The Lua bridge also uses GShader's existing `wp_reconstruction_ps30`, `pp_vs30`, `wpn_reconstruction_improved_ps30` and `reconstruction_vs30` compiled shaders. Do not enable `nkm_gshader_pixel_lighting 1` until the updated NKM deferred VCS is installed. The convar defaults to `0` to preserve the existing vertex-light fallback.
