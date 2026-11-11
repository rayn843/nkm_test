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

The Source model bump-normal capture target uses 8-bit RGBA to store octahedrally encoded world-space normal data. Any shader sampling this target must disable sRGB reads (`$linearread_basetexture` or `$linearread_texture1`/`$linearread_texture3` as appropriate); sRGB decoding changes the encoded vector and therefore changes the diffuse `N dot L` result.

The Source normal/visibility texture is generated per pixel from three inputs: GShader's Source world-position buffer, NKM's world-position buffer, and GShader's reconstructed normal buffer. Its RG channels retain GShader's octahedral world normal; B is a receiver mask. A Source pixel is eligible only when an NKM surface is present behind it at that screen pixel and the Source surface is nearer. Pixels with no NKM surface behind them are deliberately left untouched, so this pass does not relight ordinary Source room walls, floors or ceilings outside the NKM surface coverage. Equal/coplanar Source/NKM depths belong to the NKM pass. This replaces the previous stencil-based Source exclusion with a direct per-pixel depth comparison.

Both deferred lighting passes execute in the custom PS3.0 pixel shader at screen-pixel frequency. By default, Source normals are reconstructed from the GShader depth buffer and processed by the edge-aware screen-space filter described below.

An optional experimental model normal-map capture path is available with `nkm_gshader_source_model_normals 1` (default `0`). It enumerates each model's material slots, reads the material's `$bumpmap` and `$bumptransform`, hides the other slots with per-index render overrides, and draws only the selected slot into the Source model-normal RT. The custom VS applies Source's three-influence bone skinning. The PS transforms material UVs, builds a per-pixel tangent frame from world-position/UV derivatives, decodes RGB, DXT5nm, or ATI2N normal data, and writes the result as an octahedral world-space normal. A strict comparison against GShader's `_rt_WPDepth` rejects hidden fragments. Materials without a supported `$bumpmap` retain the depth-reconstructed normal fallback; `$ssbump` and material-specific translucent/cutout blending are not explicitly decoded.

Players and engine NPCs are captured through cached clientside model copies: current model, skin, bodygroups, submaterials, model scale, flex weights, and final bone matrices are copied from the live entity, then only the clone is drawn in the auxiliary pass. This avoids calling `Player:DrawModel()` and re-entering `PrePlayerDraw` hooks. Player/NPC models with custom `RenderOverride`, scripted entities, weapons, BSP static props/world geometry, translucent models, and viewmodels stay on the established depth-reconstructed fallback. This clone-based path is experimental and must be validated against the active gamemode's player models and animation system.

Compile `nkm_source_model_bump_vs30.hlsl` and `nkm_source_model_bump_ps30.hlsl` into matching `.vcs` files and install `materials/pp/nkm_source_model_bumps.vmt`. The previous `nkm_source_model_normals_vs30/ps30` shaders remain used by the depth-diagnostic views.

This capture includes opaque engine-managed model entities with a valid model and normal render mode, including built-in prop and vehicle variants; it is no longer restricted to five stock prop classes. Players, NPCs, weapon entities, custom scripted entities, entities with addon-provided render overrides, BSP static props/world geometry, translucent models, and viewmodels stay on GShader's depth-reconstructed normal fallback. Players and NPCs are still eligible for the Source deferred lighting pass; only their optional skinned-vertex-normal capture is skipped. Calling `Player:DrawModel()` in an auxiliary pass can re-enter player draw hooks, while `Entity:DrawModel()` outside a scripted entity's normal draw hook can invoke its `Draw`/`DrawTranslucent` code, so those cases are deliberately kept out of this generic capture. The pass redraws compatible engine entities and is therefore experimental and potentially expensive; leave it disabled unless testing it. If the custom model shaders are unavailable or the pass fails, the renderer continues using the established depth-reconstructed path.

This diagnostic shader is a visual-only angular check. It displays the maximum `saturate(dot(N, L))` across active NKM point lights for captured Source model entities, intentionally ignoring radius, falloff, light color, AO, and shadows. White means the captured normal faces at least one active light; black means all active lights are behind the surface direction. Compile `nkm_source_model_light_facing_debug_ps30.hlsl` to its matching `.vcs` to use the sixth **N DOT L** preview.

For diagnosis, enable `nkm_gshader_source_model_normals_debug 1`. The HUD shows five views: **STRICT RAW** with the `_rt_WPDepth` match, **UNGATED RAW** without that pixel comparison, **DECODED STRICT**, **DEPTH DELTA**, and **REJECT MASK**. **DECODED STRICT** visualizes signed world-space normal components remapped from `[-1, +1]` to `[0, 1]`: neutral 0.5 means a zero component, values above 0.5 are positive, and values below 0.5 are negative. Red is world X, green is world Y, blue is world Z; this is a normal-direction view, not material albedo or light intensity. DEPTH DELTA visualizes the magnitude of relative difference between the model fragment's reciprocal clip depth and GShader's sampled `_rt_WPDepth`: blue is a small difference, cyan approaches the acceptance limit, red is a large difference (up to 4x the limit), and magenta means no GShader scene depth was present. REJECT MASK now classifies the sign of the depth difference: green means a match accepted by STRICT; orange means the scene-buffer surface is nearer than the candidate prop (typically a foreground occluder such as a player); blue means the scene buffer reports a surface farther away than the candidate prop (possible projection/registration or depth-reconstruction mismatch); red means no GShader depth; black is outside candidate model coverage. The scene/expected depths are reciprocal linear view depths, so larger values mean nearer surfaces. Both depth diagnostic passes use the ordinary hardware Z-test, depth writes, and back-face culling so the nearest eligible prop occludes eligible props behind it. These diagnostic views are not used by lighting.

Change the raster state of the diagnostic UNGATED pass with `nkm_gshader_source_model_normals_debug_raster 0..3`: all modes retain the hardware Z-test. Mode `0` enables depth writes and back-face culling; mode `1` disables depth writes only; mode `2` disables culling only; mode `3` disables both depth writes and culling. `render.OverrideDepthEnable` changes depth writes, not the Z-test. Consequently, modes `1` and `3` can be draw-order-dependent: with no depth writes, later models may overwrite nearer pixels. Use modes `0` or `2` to check nearest-visible-surface behavior. Mode `3` is only diagnostic and may show overlapping front/back surfaces. UNGATED is never bound to the lighting pass. Keep capture and entity lighting enabled while testing; the debug panel itself does not enable capture. Turn off the HUD with `nkm_gshader_source_model_normals_debug 0`.

The Source receiver-normal mask now applies a depth- and normal-aware filter before lighting. It uses 24 taps on 2-, 7- and 16-pixel rings. The current tuning uses a 0.35 minimum normal-dot threshold and linear normal agreement falloff so adjacent polygon facets on the same curved surface contribute more strongly. The relative-depth tolerance is slightly wider and still scales with sample radius; depth rejection and the normal threshold continue to suppress cross-surface blending at silhouettes and near-perpendicular hard edges. The 7- and 16-pixel rings remain lighter than the inner ring to limit broad detail loss. Tune overall strength with `nkm_gshader_source_normal_smoothing 0..1` (default `1`; `0` disables smoothing). The filter changes only the Source normal input; it does not alter BSP/NKM normals, scene color, alpha, depth, model materials, or visibility.

Translucent surfaces and viewmodels absent from GShader's opaque depth reconstruction are not guaranteed to receive this lighting.

AO and contact-shadow ray samples use the depth buffer belonging to their current pass: NKM depth for NKM receivers and GShader Source depth for Source receivers. Contact shadows remain experimental screen-space approximations and are disabled by default with `nkm_gshader_contact_shadows 0`; enable them explicitly for testing.

Ordinary NKM world materials ignore vertex alpha and remain opaque; only the dedicated BSP displacement blend layer uses vertex alpha. Imported BSP displacement `lit` mode uses its albedo path when pixel lighting is enabled; its original LDR per-vertex bake remains available in compatibility mode.

**Compilation requirement:** compile `nkm_deferred_lighting_ps30.hlsl` into `shaders/fxc/nkm_deferred_lighting_ps30.vcs`, `nkm_source_normal_mask_ps30.hlsl` into `shaders/fxc/nkm_source_normal_mask_ps30.vcs`, `nkm_source_model_bump_vs30.hlsl` into `shaders/fxc/nkm_source_model_bump_vs30.vcs`, and `nkm_source_model_bump_ps30.hlsl` into `shaders/fxc/nkm_source_model_bump_ps30.vcs` with the Source/GMod shader toolchain. Install `materials/pp/nkm_source_model_bumps.vmt`, then enable `nkm_gshader_source_model_normals 1`. The legacy `nkm_source_model_normals_vs30/ps30` and `materials/pp/nkm_source_model_normals.vmt` are used only by the geometric/depth diagnostic views. The current NKM normal reconstruction VCS must also be installed.
