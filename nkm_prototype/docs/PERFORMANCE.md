# NKM Performance Diagnostics (0.9.5)

The profiler uses cumulative millisecond timings from `SysTime`. Timings are inclusive where noted; do not add nested timings together.

## Client commands

```text
nkm_client_perf
nkm_client_perf_reset
```

Client timings include cache read/validation/JSON decode, cache write, chunk validation, IMesh construction, chunk application, network JSON decode/receive, per-chunk Trace BVH build, root BVH build and trace-map rebuild. `trace_chunk_cache_hits` reports already-resident chunks whose prebuilt trace data was reused. Counters also report disk-cache hits, streamed bytes, applied chunks and current residency.

## Server commands

```text
nkm_server_perf
nkm_server_perf_reset
```

Server timings include map generation, validation, JSON encode/decode, file read/write, chunk partition, trace build, per-chunk serialization, stream payload preparation, collision residency initialization, manifest transfer and chunk network sending. Counters report source/manifest/stream bytes, packets, payload transfers, vertices, convex hulls, triangle-surface counts and runtime chunks.

## Measurement procedure

1. Install the exact same runtime on server and clients; restart/reconnect.
2. Reset the server profiler with `nkm_server_perf_reset`.
3. Run a benchmark or `nkm_displacement_test`.
4. Capture `nkm_status`, `nkm_server_chunks` and `nkm_server_perf`.
5. On the client, run `nkm_client_perf_reset` before the map/manifest load if possible. If the map is already loaded, reset and then force a fresh load or travel far enough to unload and reload chunks.
6. Capture `nkm_client_status` and `nkm_client_perf` after nearby chunks settle.
7. For streaming tests, fly with noclip across the map and capture the counters again.

Profiler counters are cumulative until reset. Client data may include earlier map loads if you do not reset before the test. A counter of `No samples yet` simply means the measured event did not occur since the last reset.

## Interpreting nested timings

- `chunk_apply` includes validation, mesh work and trace-map rebuild.
- `trace_rebuild` includes local cache lookup and root BVH work.
- `trace_chunk_build` measures only newly built per-chunk collision/triangle structures.
- `trace_chunk_cache_hits` counts reuse of already-resident per-chunk trace structures.
- `trace_root_bvh_build` measures the top-level BVH and can happen when chunk residency changes.
- Disk cache hits are separate from in-memory Trace Cache hits. `cache_disk_hits` means payload loaded from the persistent client filesystem; `trace_chunk_cache_hits` means collision acceleration data reused from resident runtime chunks.

## Memory caveat

`collectgarbage("count")` reports Lua VM heap only. It excludes native IMesh allocations, VPhysics allocations, materials and engine-side resources. Use it alongside process memory from the operating system and NKM residency counters.

## Benchmark modes (0.9.4+)

- `nkm_benchmark render 500` / `render 1000`: large visual worlds with sparse sampled collision.
- `nkm_benchmark fullphysics 100`: every tile has one convex collision hull; VPhysics proxies remain distance-streamed.
- `nkm_displacement_test`: 25x25 terrain grid with 1,152 triangle faces, rendered through IMesh and collided through PhysicsFromMesh.

## Compatibility

- Runtime: 0.9.5.
- NKM map format: 1.
- 0.9.5 triangle-surface payloads require clients to run 0.9.5 too. Older runtimes do not recognize this streamed field.
