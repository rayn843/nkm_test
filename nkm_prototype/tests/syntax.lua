local paths = {
 'lua/autorun/nkm_init.lua',
 'lua/nkm/sh_core.lua',
 'lua/nkm/sh_displacement.lua',
 'lua/nkm/sh_trace.lua',
 'lua/nkm/sh_perf.lua',
 'lua/nkm/sv_runtime.lua',
 'lua/nkm/sv_bsp_import.lua',
 'lua/nkm/cl_renderer.lua'
}
local failed = false
for _, path in ipairs(paths) do
    local fn, err = loadfile(path)
    if not fn then
        io.stderr:write('FAIL ', path, ': ', tostring(err), '\n')
        failed = true
    else
        print('PASS ' .. path)
    end
end
if failed then os.exit(1) end
