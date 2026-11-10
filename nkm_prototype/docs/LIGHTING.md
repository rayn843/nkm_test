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

When the updated `nkm_deferred_lighting_ps30.vcs` is installed and `nkm_gshader_pixel_lighting 1` is set before the map's chunks load, NKM ambient and directional light are evaluated in the deferred pixel shader from the dedicated NKM world-position and world-normal buffers. In this mode the client does not multiply NKM vertex colors by the server-side `nkmLighting` bake. The existing vertex bake remains the compatibility path by default.

The deferred renderer runs two full-screen **pixel-shader** receiver passes using the same four `screenspace_general` texture slots:

- **NKM pass:** NKM world position at s0, NKM normal/visibility mask at s1, dynamic-light LUT at s2, and scene color at s3.
- **Source pass:** GShader's `_rt_WPDepth` at s0 and a packed Source normal/visibility texture at s1, followed by the same light LUT and scene color at s2/s3. This applies NKM point, ambient, and directional lighting to visible opaque Source geometry, including player models and props. Enable/disable it with `nkm_gshader_entity_lighting 1|0` (default `1`).

The Source normal/visibility texture is generated per pixel from three inputs: GShader's Source world-position buffer, NKM's world-position buffer, and GShader's reconstructed normal buffer. Its RG channels retain GShader's octahedral world normal; B is a receiver mask. A Source pixel is eligible only when an NKM surface is present behind it at that screen pixel and the Source surface is nearer. Pixels with no NKM surface behind them are deliberately left untouched, so this pass does not relight ordinary Source room walls, floors or ceilings outside the NKM surface coverage. Equal/coplanar Source/NKM depths belong to the NKM pass. This replaces the previous stencil-based Source exclusion with a direct per-pixel depth comparison.

Both deferred lighting passes execute in the custom PS3.0 pixel shader at screen-pixel frequency. Source normals are **reconstructed from the GShader depth buffer per pixel**, not sampled from each model's original vertex normals or normal maps. The lighting remains a screen-space approximation and cannot recover the original mesh normals or tangent-space normal maps.

The Source receiver-normal mask now applies a depth- and normal-aware filter before lighting. It uses 24 taps on 2-, 7- and 16-pixel rings. The current tuning uses a 0.35 minimum normal-dot threshold and linear normal agreement falloff so adjacent polygon facets on the same curved surface contribute more strongly. The relative-depth tolerance is slightly wider and still scales with sample radius; depth rejection and the normal threshold continue to suppress cross-surface blending at silhouettes and near-perpendicular hard edges. The 7- and 16-pixel rings remain lighter than the inner ring to limit broad detail loss. Tune overall strength with `nkm_gshader_source_normal_smoothing 0..1` (default `1`; `0` disables smoothing). The filter changes only the Source normal input; it does not alter BSP/NKM normals, scene color, alpha, depth, model materials, or visibility.

Translucent surfaces and viewmodels absent from GShader's opaque depth reconstruction are not guaranteed to receive this lighting.

AO and contact-shadow ray samples use the depth buffer belonging to their current pass: NKM depth for NKM receivers and GShader Source depth for Source receivers. Contact shadows remain experimental screen-space approximations and are disabled by default with `nkm_gshader_contact_shadows 0`; enable them explicitly for testing.

Ordinary NKM world materials ignore vertex alpha and remain opaque; only the dedicated BSP displacement blend layer uses vertex alpha. Imported BSP displacement `lit` mode uses its albedo path when pixel lighting is enabled; its original LDR per-vertex bake remains available in compatibility mode.

**Compilation requirement:** compile `nkm_deferred_lighting_ps30.hlsl` into `shaders/fxc/nkm_deferred_lighting_ps30.vcs` and the new `nkm_source_normal_mask_ps30.hlsl` into `shaders/fxc/nkm_source_normal_mask_ps30.vcs` with the Source/GMod shader toolchain. The current NKM normal reconstruction VCS must also be installed. The deferred shader uses only the four `screenspace_general` texture samplers. The Lua bridge also uses GShader's existing `wp_reconstruction_ps30`, `pp_vs30`, `wpn_reconstruction_improved_ps30` and `reconstruction_vs30` compiled shaders. Do not enable `nkm_gshader_pixel_lighting 1` until the updated NKM deferred VCS is installed; its convar defaults to `0` for the existing vertex-light fallback.
