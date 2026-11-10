-- NKM Map Editor server bridge for NKM Runtime 0.9.9.
-- Receives bounded, chunked JSON uploads from admins and stores them through NKM.WriteMap.

if not SERVER then return end
if not NKM or not NKM.WriteMap or not NKM.LoadMap then return end

local NET_BEGIN = "nkm_editor_upload_begin"
local NET_PART = "nkm_editor_upload_part"
local NET_FINISH = "nkm_editor_upload_finish"
local NET_RESULT = "nkm_editor_upload_result"

local MAX_UPLOAD_BYTES = NKM.MaxMapBytes or (2 * 1024 * 1024)
local PART_BYTES = 48000
local UPLOAD_TIMEOUT = 120

util.AddNetworkString(NET_BEGIN)
util.AddNetworkString(NET_PART)
util.AddNetworkString(NET_FINISH)
util.AddNetworkString(NET_RESULT)

local function canEdit(ply)
    return IsValid(ply) and ply:IsPlayer() and ply:IsAdmin()
end

local function sendResult(ply, saved, loaded, message)
    if not IsValid(ply) then return end
    net.Start(NET_RESULT)
        net.WriteBool(saved == true)
        net.WriteBool(loaded == true)
        net.WriteString(string.sub(tostring(message or ""), 1, 240))
    net.Send(ply)
end

local function clearUpload(ply)
    if IsValid(ply) then ply.NKMEditorUpload = nil end
end

net.Receive(NET_BEGIN, function(_, ply)
    if not canEdit(ply) then return end

    local mapName = net.ReadString()
    local compressedBytes = net.ReadUInt(32)
    local partCount = net.ReadUInt(16)
    local checksum = net.ReadString()
    local loadAfterSave = net.ReadBool()

    if not NKM.IsValidMapName(mapName) then
        sendResult(ply, false, false, "Invalid NKM map name")
        return
    end
    if compressedBytes < 1 or compressedBytes > MAX_UPLOAD_BYTES then
        sendResult(ply, false, false, "Upload exceeds NKM map size limit")
        return
    end

    local expectedParts = math.ceil(compressedBytes / PART_BYTES)
    if partCount ~= expectedParts or partCount < 1 or partCount > 65535 then
        sendResult(ply, false, false, "Invalid upload part count")
        return
    end

    local now = CurTime()
    if now < (ply.NKMEditorNextUploadAt or 0) then
        sendResult(ply, false, false, "Please wait before starting another editor upload")
        return
    end
    ply.NKMEditorNextUploadAt = now + 1
    ply.NKMEditorUpload = {
        mapName = mapName,
        compressedBytes = compressedBytes,
        partCount = partCount,
        checksum = checksum,
        loadAfterSave = loadAfterSave,
        parts = {},
        receivedParts = 0,
        receivedBytes = 0,
        startedAt = now
    }
end)

net.Receive(NET_PART, function(_, ply)
    if not canEdit(ply) then return end
    local upload = ply.NKMEditorUpload
    if not upload then return end
    if CurTime() - upload.startedAt > UPLOAD_TIMEOUT then
        clearUpload(ply)
        sendResult(ply, false, false, "Editor upload timed out")
        return
    end

    local partIndex = net.ReadUInt(16)
    local byteCount = net.ReadUInt(16)
    if partIndex < 1 or partIndex > upload.partCount or byteCount < 1 or byteCount > PART_BYTES then
        clearUpload(ply)
        sendResult(ply, false, false, "Invalid editor upload part")
        return
    end

    local data = net.ReadData(byteCount)
    if not isstring(data) or #data ~= byteCount then
        clearUpload(ply)
        sendResult(ply, false, false, "Incomplete editor upload part")
        return
    end

    if upload.parts[partIndex] then
        -- Duplicate reliable packet: do not count it twice.
        return
    end

    upload.parts[partIndex] = data
    upload.receivedParts = upload.receivedParts + 1
    upload.receivedBytes = upload.receivedBytes + #data
    if upload.receivedBytes > upload.compressedBytes then
        clearUpload(ply)
        sendResult(ply, false, false, "Editor upload size mismatch")
    end
end)

net.Receive(NET_FINISH, function(_, ply)
    if not canEdit(ply) then return end
    local upload = ply.NKMEditorUpload
    if not upload then
        sendResult(ply, false, false, "No active editor upload")
        return
    end

    if CurTime() - upload.startedAt > UPLOAD_TIMEOUT then
        clearUpload(ply)
        sendResult(ply, false, false, "Editor upload timed out")
        return
    end
    if upload.receivedParts ~= upload.partCount or upload.receivedBytes ~= upload.compressedBytes then
        clearUpload(ply)
        sendResult(ply, false, false, "Editor upload is incomplete")
        return
    end

    local parts = {}
    for index = 1, upload.partCount do
        if not upload.parts[index] then
            clearUpload(ply)
            sendResult(ply, false, false, "Missing editor upload part " .. index)
            return
        end
        parts[index] = upload.parts[index]
    end

    local compressed = table.concat(parts)
    local mapName = upload.mapName
    local loadAfterSave = upload.loadAfterSave
    local checksum = upload.checksum
    clearUpload(ply)

    if #compressed ~= upload.compressedBytes or util.CRC(compressed) ~= checksum then
        sendResult(ply, false, false, "Editor upload checksum mismatch")
        return
    end

    local json = util.Decompress(compressed)
    if not isstring(json) or #json < 2 or #json > MAX_UPLOAD_BYTES then
        sendResult(ply, false, false, "Could not decompress editor map or map is too large")
        return
    end

    local mapTable = util.JSONToTable(json)
    if not istable(mapTable) then
        sendResult(ply, false, false, "Editor map JSON is invalid")
        return
    end
    if mapTable.name ~= mapName then
        sendResult(ply, false, false, "Map name does not match upload target")
        return
    end

    local writeOK, writeResult = NKM.WriteMap(mapName, mapTable)
    if not writeOK then
        sendResult(ply, false, false, "Map validation/save failed: " .. tostring(writeResult))
        return
    end

    if not loadAfterSave then
        sendResult(ply, true, false, string.format("Saved %s (%d bytes). Use Load in Editor to test it.", mapName, writeResult))
        return
    end

    local loadOK, loadResult = NKM.LoadMap(mapName)
    if not loadOK then
        sendResult(ply, true, false, "Saved, but runtime load failed: " .. tostring(loadResult))
        return
    end

    sendResult(ply, true, true, string.format("Saved and loaded '%s'. Check nkm_lighting_status on the client.", mapName))
end)

hook.Add("PlayerDisconnected", "NKM.Editor.CleanupUpload", function(ply)
    clearUpload(ply)
end)
