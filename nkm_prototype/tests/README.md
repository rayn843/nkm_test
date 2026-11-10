# NKM test suite

Run from the addon root with Lua 5.3 / TeXLua:

```text
texlua tests/syntax.lua
texlua tests/triangle_core.lua
texlua tests/bsp_import.lua
texlua tests/legacy_stub.lua
```

- `syntax.lua`: parses every runtime Lua file.
- `triangle_core.lua`: builds TriangleSurface chunks, tests Source row-major topology and alternating diagonals, validates independent ray/hull channels, and checks TraceLine/TraceHull.
- `bsp_import.lua`: feeds synthetic Source BSP lumps through the actual NikNaks importer code and validates the generated NKM patch, texture projection, vertex order, and inverted BSP contents flags.
- `legacy_stub.lua`: checks legacy convex map compatibility.

These are offline parser/geometry tests; they do not run the Garry's Mod engine, NikNaks' live BSP object, or VPhysics. A real-map import and in-game collision test are still required.
