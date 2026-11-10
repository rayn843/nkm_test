# NKM JSON format v1

Format v1 is the current prototype interchange format. It remains JSON while geometry, collision and runtime contracts are tested. Optional displacement grids, BSP metadata and per-vertex lighting are additive; the on-disk format version remains `1`.

```json
{
  "format": "NKM",
  "version": 1,
  "name": "terrain_demo",
  "chunkSize": 512,
  "meshes": [],
  "collision": [],
  "displacements": [
    {
      "id": "hills_01",
      "width": 3,
      "height": 3,
      "vertices": [
        [0, 0, 0], [128, 0, 4], [256, 0, 0],
        [0, 128, 8], [128, 128, 24], [256, 128, 8],
        [0, 256, 0], [128, 256, 4], [256, 256, 0]
      ],
      "material": "nkm_prototype_unlit_v2",
      "surface": "dirt",
      "uvScale": 8,
      "color": [116, 150, 92, 255],
      "vertexAlphas": [255, 255, 255, 255, 255, 255, 255, 255, 255],
      "vertexLighting": [[180, 176, 164], [182, 178, 167], [185, 180, 168], [188, 183, 170], [190, 185, 172], [175, 172, 161], [180, 176, 165], [184, 179, 168], [188, 183, 171]],
      "lightmap": { "source": "BSP_LDR_RGBExp32", "style": 0, "sampleWidth": 17, "sampleHeight": 17 },
      "collision": true
    }
  ]
}
```

## Root fields

- `format`: exact string `NKM`.
- `version`: integer `1`.
- `name`: 1–48 characters matching `[A-Za-z0-9_-]`.
- `meshes`: array of non-indexed render triangle groups. It may be empty if the map contains at least one displacement grid.
- `chunkSize`: optional edge length in world units (128–8192), defaults to 512.
- `collision`: optional array of convex solid hulls.
- `displacements`: optional array of regular grid surfaces, added by runtime 0.9.5.

## Displacement fields (0.9.5–0.9.7)

`vertexAlphas` is an optional `width * height` numeric array (0..255) preserving Source `DispVert.alpha`; render vertices expose this as `blendAlpha` for compatible two-texture albedo materials. `vertexLighting` is an optional `width * height` array of `[r, g, b]` values (0..255) containing the imported first-style LDR BSP light approximation. `lightmap` is optional provenance metadata (source lump, style, sample dimensions/count and mapping method). Older NKM v1 maps without these fields remain valid; absent vertex lighting defaults to white/unlit vertex color.


- `id`: optional patch identifier.
- `width`, `height`: integer grid dimensions from 2 through 65.
- `vertices`: `width * height` world-space `[x, y, z]` positions, row-major.
- `material`: optional material label (the current renderer still uses the built-in UnlitGeneric vertex-color material).
- `surface`: optional VPhysics surface property, defaults to `dirt`.
- `uvScale`: optional positive UV multiplier, defaults to 8.
- `color`: optional `[r, g, b, a]`, defaults to `[120, 150, 105, 255]`.
- `vertexAlphas`: optional per-grid-vertex blend alpha from Source `DispVert.alpha`.
- `vertexLighting`: optional per-grid-vertex RGB byte values from the NKM 0.9.7 LDR lightmap importer. This is a first-lightstyle approximation and affects rendering only.
- `lightmap`: optional import metadata describing the source LDR light samples; it does not store a full lightmap atlas.
- `collision`: optional legacy master boolean; defaults to `true`. If false, all three collision channels are disabled while the surface remains rendered.
- `physicsCollision`: optional boolean; defaults to `true`. Controls contact with VPhysics objects on TriangleSurface proxies.
- `hullCollision`: optional boolean; defaults to `true`. Controls player/NPC hull contact and NKM `TraceHull` queries.
- `rayCollision`: optional boolean; defaults to `true`. Controls NKM `TraceLine` queries.
- `triangleLayout`: optional string `source`. Selects Source BSP's row-major grid and alternating cell diagonals. Omitted means the legacy NKM fixed-diagonal layout.
- `flipWinding`: optional boolean; defaults to `false`. Reverses triangle winding for normals/culling.
- `triangleTags`: optional unsigned 16-bit tags, two per cell. Bit 5 (`DISPTRI_TAG_REMOVE`) removes that triangle from generated render, collision and trace data.
- `smoothNormals`: optional boolean; computes area-weighted grid normals when explicit `normals` are not supplied.

Legacy grids (without `triangleLayout`) are split using the original fixed diagonal. Source grids use the Source alternating diagonal rule. Vertices are expanded into render triangles and chunk-local triangle-surface payloads. Triangles are assigned to a runtime chunk by centroid and are not clipped to chunk boundaries.

## Runtime chunk payload fields

Streamed `NKM_CHUNK` records can contain `triangleSurfaces`: an array of per-chunk groups. Each group carries a surface property, independent `physicsCollision`, `hullCollision` and `rayCollision` flags, flat triangle vertex positions, and stable source triangle indices. This field is a runtime transport representation; it is generated from root `displacements` and is not required in saved map files.

## Collision fields

`collision[]` stores 3D convex point clouds (4–32 points each, non-zero volume on X/Y/Z). Runtime builds VPhysics proxies with `PhysicsInitMultiConvex`. Displacement grids instead use `PhysicsFromMesh` triangle soup in a static proxy. Groups with neither physics nor hull collision enabled do not create a VPhysics proxy; ray-only groups remain available to `NKM.TraceLine`.

## Limits

- Maximum JSON map payload: 2 MiB.
- Maximum generated render vertices: 250,000.
- IMesh batches are triangle-aligned and limited to 60,000 vertices.
- Maximum root convex hulls: 128.
- Maximum displacement patches: 256.
- Maximum displacement grid side: 65 vertices.
- Maximum triangle-surface vertices per runtime chunk: 60,000.
- Physics creation is server-side only.
