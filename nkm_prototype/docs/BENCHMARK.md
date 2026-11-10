# NKM Synthetic Large-World Benchmark

## Purpose

This benchmark separates two workloads: large render/streaming maps with sparse physics, and a smaller map where every tile has a VPhysics collision hull. It is a synthetic runtime benchmark, not a production map; it does not measure baked lighting, material complexity, or imported displacement quality.

## Modes

### Render stress: 500 / 1000 chunks

```text
nkm_server_perf_reset
nkm_benchmark render 500
nkm_benchmark_status
nkm_status
nkm_server_perf
```

For the larger render stress test: `nkm_benchmark render 1000`. The old syntax `nkm_benchmark 500` and `nkm_benchmark 1000` remains supported.

| Test | Grid | Render chunks | Render vertices | Collision hulls |
|---|---:|---:|---:|---:|
| Render 500 | 25 x 20 | 500 | 3,000 | 50 (10%) |
| Render 1000 | 40 x 25 | 1,000 | 6,000 | 100 (10%) |

### Full physics: 100 chunks

```text
nkm_server_perf_reset
nkm_benchmark fullphysics 100
nkm_benchmark_status
nkm_status
nkm_server_perf
```

This generates a 10 x 10 field with 100 visual chunks and 100 convex collision hulls (one per tile). This is a 100% collision-coverage test and stays under the current NKM safety cap of 128 convex hulls. That cap is a prototype validation guardrail, not a documented hard global VPhysics limit. Server VPhysics proxies are still streamed by player distance, so `nkm_status` reports only currently resident collision proxies.

## Geometry layout

Each tile is 512 x 512 Source units and is assigned to exactly one chunk by triangle centroid. The grid is centered around the invoking player's current X/Y chunk. The floor is placed 64 units below the invoking player's current Z position. Tile colors vary deterministically to make the grid easy to inspect. Each collision tile receives a 16-unit-thick concrete convex slab.

## Client run

On the client:

```text
nkm_client_perf_reset
nkm_client_status
nkm_client_perf
```

Wait for nearby chunks to load, then fly over the field with noclip to trigger streaming and unloading. Capture the same commands again. Nearby chunk load requests are paced, so wait for `Pending requests: 0` before comparing settled measurements.

Do not dump all per-chunk state with `nkm_client_chunks` for the 1000-chunk map unless necessary; it prints one line per manifest entry.

## What to send back

For each mode, provide:

- Server: `nkm_benchmark_status`, `nkm_status`, `nkm_server_perf`.
- Client after nearby chunks settle: `nkm_client_status`, `nkm_client_perf`.
- Client after flying across the map and returning: the same two client commands.

Important timings include `benchmark_map_generate`, `map_write_validate`, `map_json_encode`, `map_file_write`, `map_file_read`, `map_json_decode`, `map_validate`, `map_chunk_partition`, `map_trace_build`, `stream_payload_build`, `map_collision_residency_init`, `manifest_network_send`, `chunk_apply`, `mesh_build`, `trace_chunk_build` and `trace_root_bvh_build`.

## Memory caveat

The `Lua heap` value uses `collectgarbage("count")` and reports only Lua-managed memory. It does not count native IMesh objects, VPhysics allocations, material/renderer resources or total process RAM. Use operating-system process memory alongside NKM residency counters.
