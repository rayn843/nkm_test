-- NKM 0.9.7 - NikNaks Map Runtime
-- Install as: garrysmod/addons/nkm_prototype/

if SERVER then
    AddCSLuaFile("nkm/sh_core.lua")
    AddCSLuaFile("nkm/sh_displacement.lua")
    AddCSLuaFile("nkm/sh_trace.lua")
    AddCSLuaFile("nkm/sh_perf.lua")
    AddCSLuaFile("nkm/cl_renderer.lua")
end

include("nkm/sh_core.lua")
include("nkm/sh_displacement.lua")
include("nkm/sh_trace.lua")
include("nkm/sh_perf.lua")

if SERVER then
    include("nkm/sv_runtime.lua")
    include("nkm/sv_bsp_import.lua")
else
    include("nkm/cl_renderer.lua")
end
