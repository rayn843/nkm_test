# NKM Network and Chunk Streaming

## Runtime 0.7.0

### Manifest

The server sends a compact manifest first. It contains chunk IDs, world-space bounds, payload size, CRC and mesh/collision counts. The manifest lets each client decide what it needs without downloading every chunk immediately.

### Client chunk requests

The client computes distance from its current position to each chunk AABB. Missing chunks inside `NKM.ChunkLoadDistance` are collected and sorted nearest-first. One request is sent per update interval. Loaded chunks are retained until they cross `NKM.ChunkUnloadDistance`, preventing boundary thrashing.

The server validates the active map generation, chunk index, request rate and the requesting player's distance to the chunk before sending payload data.

### Server physics residency

The server independently creates/removes VPhysics collision proxies per collision chunk. See [SERVER_PHYSICS_STREAMING.md](SERVER_PHYSICS_STREAMING.md).

This does not affect the server's custom NKM trace data: server traces retain the full map's collision representation. Client traces use only collision data from chunks currently resident on that client.

### Transfer integrity

Manifest and chunk transfers are split into bounded network pieces. The client validates byte counts and CRC before decoding and applying a chunk. A map generation ID prevents data from a previous map load from being applied after a runtime map switch.

### Current limitations

- Chunk payloads are still all retained in server memory.
- No persistent client disk cache yet.
- No compression or delta transfer yet.
- No transfer-level acknowledgement/retransmission protocol beyond client timeout and retry.
- Chunk residency scans are adequate for the prototype but should move to a spatial index for very large maps.
