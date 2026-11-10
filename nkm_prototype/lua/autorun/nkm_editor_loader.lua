-- NKM Editor loader. Waits until the NKM runtime has initialized.
if SERVER then
    AddCSLuaFile() -- Distribute this loader so clients register the editor UI command.
    AddCSLuaFile("nkm_editor/cl_editor.lua")

    timer.Create("NKM.Editor.ServerBootstrap", 0.25, 0, function()
        if not NKM or not NKM.WriteMap or not NKM.LoadMap or not NKM.BakeMapLighting or not NKM.TraceLine then return end
        timer.Remove("NKM.Editor.ServerBootstrap")
        include("nkm_editor/sv_editor.lua")
        print("[NKM Editor] Server editor bridge loaded. Client command: nkm_editor")
    end)
else
    include("nkm_editor/cl_editor.lua")
end
