# NKM Persistent Chunk Cache (0.8.0)

## Storage

Verified chunk payloads are stored on the client under:

```text
garrysmod/data/nkm/cache/<mapName>/format_<formatVersion>/chunk_<index>_<crc>.dat
```

The cache stores the exact JSON payload received from the server. It does not store generated IMesh handles or VPhysics objects; those are rebuilt when a chunk becomes resident.

## Cache key and validation

A cache entry is identified by map name, NKM format version, chunk index and the CRC advertised in the manifest. Before a cached payload is decoded, the client verifies both its byte length and CRC. The normal chunk identity validator then checks map name, chunk ID, coordinates, mesh-group count and collision count. Invalid entries are deleted and requested again from the server.

## Lifecycle

- On a cache miss, the client requests the nearest wanted chunk from the server.
- After a successful network transfer and successful chunk application, the raw payload is written to DATA.
- On later visits, the same chunk is read from disk and applied without a network payload transfer.
- When a chunk is unloaded, its IMesh and in-memory collision description are released; its disk cache entry remains.
- When a new manifest arrives, cache files for that map which are not referenced by the new manifest are removed. Old format-version folders for the same map are also pruned.
- Cache data survives disconnects and game restarts.

## Commands

Client console:

```text
nkm_cache_status
nkm_cache_clear [mapName]
```

Without a map name, `nkm_cache_clear` clears NKM chunk cache files for all maps. It does not remove map source files, game content or unrelated DATA files.

## Diagnostics

`nkm_client_status` includes cached file count, bytes, hits, misses, writes, corruptions and evictions. `nkm_cache_status` also reports the last chunk cache source (`disk` or `network (cached)`).

## Limitations

- This prototype uses `util.CRC` as an integrity check, not a cryptographic authenticity guarantee. Network payloads are still validated against the server manifest and the NKM map validator.
- Only chunk payloads are cached. The manifest is small and is received from the server for each map generation.
- Cached raw JSON still has to be decoded and converted into IMesh when the chunk is loaded.
