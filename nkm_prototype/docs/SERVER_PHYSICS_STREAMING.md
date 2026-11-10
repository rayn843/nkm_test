# NKM Server Physics Streaming (Runtime 0.7.0)

NKM 0.7.0 makes server-side VPhysics collision proxies resident only around active players and nearby physics entities. This is separate from client render streaming.

## Residency policy

Default settings in `lua/nkm/sv_runtime.lua`:

- `NKM.ServerPhysicsLoadDistance = 4096`
- `NKM.ServerPhysicsUnloadDistance = 6144`
- `NKM.ServerPhysicsEntityKeepDistance = 512`
- `NKM.ServerPhysicsUpdateInterval = 0.5`

A non-resident collision chunk is activated when an alive player is within the load distance of its bounds. A resident chunk remains active until all alive players are beyond the unload distance. The two distances provide hysteresis and prevent repeated create/remove cycles near one boundary.

A chunk is also kept resident while a non-NKM `MOVETYPE_VPHYSICS` entity with a valid physics object is within the entity keep distance. This reduces the risk of removing support under props when players move away. NKM collision proxy entities are excluded from this anchor check.

Chunks without collision hulls do not create physics proxies.

## Runtime behavior

- `NKM.CreateCollisionChunk(chunk)` creates the per-chunk, per-surface VPhysics proxies.
- `NKM.RemoveCollisionChunk(chunk)` removes those proxies and updates the global proxy registry.
- `NKM.UpdateServerPhysicsStreaming()` evaluates residency on a throttled server Think hook.
- Newly spawned players trigger an immediate residency refresh.
- Map replacement prepares the new map's nearby collision proxies before removing the old map's proxies.

## Trace behavior

The server's `NKM.TraceMap` still contains collision descriptions for the complete active map. Server-side `NKM.TraceLine`, `NKM.TraceHull`, `NKM.PointContents`, `NKM.FindInBox`, and `NKM.FindInSphere` therefore remain independent of whether a VPhysics proxy is currently resident.

Client traces remain limited to collision data from chunks currently streamed to that client.

## Priority client streaming

The client computes distance from its current position to every chunk AABB. It sorts missing wanted chunks by ascending distance and requests the nearest one first. This prevents manifest ordering from causing a farther chunk to be downloaded before a closer chunk.

## Diagnostics

Server console:

```text
nkm_status
nkm_server_chunks
```

`nkm_status` reports resident versus total collision chunks and hulls. `nkm_server_chunks` reports each collision chunk's residency, proxy count, hull count, and retry timer.

Client console:

```text
nkm_client_status
nkm_client_chunks
```

## Important limits

This is runtime proxy streaming, not yet a complete large-world physics engine:

- The server still keeps all parsed NKM collision descriptions and trace BVH data in memory.
- All chunk JSON payloads are still prepared and retained on the server.
- Physics residency checks scan active chunks and physics entities at the configured interval. Large maps may need a second-level spatial index for the residency manager.
- Removing a proxy is not a substitute for a full contact/constraint migration system. Physics props near a chunk are conservatively used to keep it resident, but complex constraints spanning distant chunks need further handling.
- Client-side predicted movement still uses Source/GMod prediction; NKM does not implement a separate prediction solver.
