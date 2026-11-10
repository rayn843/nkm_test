-- NKM Map Editor / Lighting Lab
-- In-game blockout editor for NKM Runtime 0.9.9.
-- Creates box meshes + convex collision, previews the same ambient/Lambert/point-light model,
-- and uploads validated NKM JSON to the server in bounded chunks.

if not CLIENT then return end

local NET_BEGIN = "nkm_editor_upload_begin"
local NET_PART = "nkm_editor_upload_part"
local NET_FINISH = "nkm_editor_upload_finish"
local NET_RESULT = "nkm_editor_upload_result"
local EDITOR_MATERIAL = Material("models/debug/debugwhite")
local EDITOR_LINE_MATERIAL = Material("color")

local function copyColor(color)
    return Color(color.r, color.g, color.b, color.a or 255)
end

local function asVector(value)
    return Vector(value[1] or 0, value[2] or 0, value[3] or 0)
end

local function vectorArray(value)
    return { value.x, value.y, value.z }
end

local function clampColor(value)
    return {
        math.Clamp(math.floor(value[1] or 0), 0, 255),
        math.Clamp(math.floor(value[2] or 0), 0, 255),
        math.Clamp(math.floor(value[3] or 0), 0, 255)
    }
end

local function sanitizeMapName(value)
    return string.Trim(tostring(value or "")):lower()
end

local function getEntry(state, selection)
    if not selection then return nil end
    if selection.kind == "object" then return state.objects[selection.index] end
    if selection.kind == "light" then return state.points[selection.index] end
    return nil
end

local function normalize3(x, y, z)
    local length = math.sqrt(x * x + y * y + z * z)
    if length < 0.00001 then return 0, 0, 1 end
    return x / length, y / length, z / length
end

local function previewLighting(state, position, normal, baseColor)
    local ambient = state.ambient
    local red, green, blue = ambient[1], ambient[2], ambient[3]
    local sun = state.sun

    if sun.intensity > 0.0001 then
        local lx, ly, lz = normalize3(sun.direction[1], sun.direction[2], sun.direction[3])
        local diffuse = math.max(0, normal.x * lx + normal.y * ly + normal.z * lz)
        red = red + 255 * sun.intensity * diffuse
        green = green + 244 * sun.intensity * diffuse
        blue = blue + 225 * sun.intensity * diffuse
    end

    for _, light in ipairs(state.points) do
        local delta = asVector(light.pos) - position
        local distance = delta:Length()
        if distance > 0.0001 and distance < light.radius then
            delta:Normalize()
            local diffuse = math.max(0, normal:Dot(delta))
            local remaining = 1 - distance / light.radius
            local attenuation = remaining * remaining
            local strength = light.intensity * attenuation * diffuse
            red = red + light.color[1] * strength
            green = green + light.color[2] * strength
            blue = blue + light.color[3] * strength
        end
    end

    return Color(
        math.Clamp(math.floor((baseColor[1] or 255) * math.Clamp(red / 255, 0, 1) + 0.5), 0, 255),
        math.Clamp(math.floor((baseColor[2] or 255) * math.Clamp(green / 255, 0, 1) + 0.5), 0, 255),
        math.Clamp(math.floor((baseColor[3] or 255) * math.Clamp(blue / 255, 0, 1) + 0.5), 0, 255),
        255
    )
end

local function boxFaces(object)
    local center = asVector(object.pos)
    local half = asVector(object.size) * 0.5
    local x, y, z = half.x, half.y, half.z
    local p = {
        Vector(center.x - x, center.y - y, center.z - z),
        Vector(center.x + x, center.y - y, center.z - z),
        Vector(center.x + x, center.y + y, center.z - z),
        Vector(center.x - x, center.y + y, center.z - z),
        Vector(center.x - x, center.y - y, center.z + z),
        Vector(center.x + x, center.y - y, center.z + z),
        Vector(center.x + x, center.y + y, center.z + z),
        Vector(center.x - x, center.y + y, center.z + z)
    }

    return {
        { p[4], p[8], p[7], p[3], Vector(0, 1, 0) },
        { p[2], p[3], p[7], p[6], Vector(1, 0, 0) },
        { p[1], p[2], p[6], p[5], Vector(0, -1, 0) },
        { p[4], p[1], p[5], p[8], Vector(-1, 0, 0) },
        { p[5], p[6], p[7], p[8], Vector(0, 0, 1) },
        { p[4], p[3], p[2], p[1], Vector(0, 0, -1) }
    }
end

local function drawEditorGrid()
    local extent = 1024
    local step = 64
    for value = -extent, extent, step do
        local major = value == 0 or value % (step * 4) == 0
        local color = major and Color(92, 111, 132, 210) or Color(55, 68, 84, 150)
        render.DrawLine(Vector(value, -extent, 0), Vector(value, extent, 0), color, true)
        render.DrawLine(Vector(-extent, value, 0), Vector(extent, value, 0), color, true)
    end
    render.DrawLine(Vector(-extent, 0, 0.5), Vector(extent, 0, 0.5), Color(210, 90, 90), true)
    render.DrawLine(Vector(0, -extent, 0.5), Vector(0, extent, 0.5), Color(90, 180, 220), true)
end

local function drawEditorScene(state, camera, viewport)
    local orbit = Angle(-camera.pitch, camera.yaw, 0)
    local cameraPosition = camera.target + orbit:Forward() * camera.distance
    local viewAngle = (camera.target - cameraPosition):Angle()
    local sx, sy = viewport:LocalToScreen(0, 0)
    local width, height = viewport:GetWide(), viewport:GetTall()

    surface.SetDrawColor(17, 22, 30, 255)
    surface.DrawRect(0, 0, width, height)

    render.SetScissorRect(sx, sy, sx + width, sy + height, true)
    cam.Start3D(cameraPosition, viewAngle, 52, sx, sy, width, height, 2, 50000)
    render.SetMaterial(EDITOR_MATERIAL)
    drawEditorGrid()

    for index, object in ipairs(state.objects) do
        local faces = boxFaces(object)
        for _, face in ipairs(faces) do
            local p1, p2, p3, p4, normal = face[1], face[2], face[3], face[4], face[5]
            local center = (p1 + p2 + p3 + p4) * 0.25
            local tint = previewLighting(state, center, normal, object.color)
            render.SetMaterial(EDITOR_MATERIAL)
            render.DrawQuad(p1, p2, p3, p4, tint)
        end

        if state.selection and state.selection.kind == "object" and state.selection.index == index then
            local half = asVector(object.size) * 0.5
            render.DrawWireframeBox(asVector(object.pos), angle_zero,
                Vector(-half.x, -half.y, -half.z), Vector(half.x, half.y, half.z), Color(255, 190, 70), true)
        end
    end

    for index, light in ipairs(state.points) do
        local point = asVector(light.pos)
        local lightColor = Color(light.color[1], light.color[2], light.color[3], 210)
        render.DrawWireframeSphere(point, math.max(8, light.radius), 16, 10, Color(lightColor.r, lightColor.g, lightColor.b, 70), true)
        render.DrawWireframeSphere(point, 10, 12, 8, lightColor, true)
        if state.selection and state.selection.kind == "light" and state.selection.index == index then
            render.DrawWireframeSphere(point, 16, 16, 10, Color(255, 220, 80), true)
        end
    end

    local sun = state.sun
    if sun.intensity > 0.001 then
        local dx, dy, dz = normalize3(sun.direction[1], sun.direction[2], sun.direction[3])
        local start = camera.target + Vector(0, 0, 220)
        render.DrawLine(start, start + Vector(dx, dy, dz) * 180, Color(255, 235, 150), true)
        render.DrawWireframeSphere(start, 7, 10, 8, Color(255, 235, 150), true)
    end

    cam.End3D()
    render.SetScissorRect(0, 0, 0, 0, false)
end

local function addQuadVertex(vertices, point, normal, u, v, color)
    vertices[#vertices + 1] = {
        p = { point.x, point.y, point.z },
        n = { normal.x, normal.y, normal.z },
        uv = { u, v },
        color = { color[1], color[2], color[3], 255 }
    }
end

local function buildMapTable(state, name)
    local origin = state.origin
    local meshes, collision = {}, {}

    for _, object in ipairs(state.objects) do
        local vertices = {}
        for _, face in ipairs(boxFaces(object)) do
            local p1, p2, p3, p4, normal = face[1], face[2], face[3], face[4], face[5]
            local translated = {
                p1 + origin, p2 + origin, p3 + origin, p4 + origin
            }
            addQuadVertex(vertices, translated[1], normal, 0, 0, object.color)
            addQuadVertex(vertices, translated[2], normal, 1, 0, object.color)
            addQuadVertex(vertices, translated[3], normal, 1, 1, object.color)
            addQuadVertex(vertices, translated[1], normal, 0, 0, object.color)
            addQuadVertex(vertices, translated[3], normal, 1, 1, object.color)
            addQuadVertex(vertices, translated[4], normal, 0, 1, object.color)
        end
        meshes[#meshes + 1] = {
            material = "models/debug/debugwhite",
            vertices = vertices
        }

        if object.collision then
            local center = asVector(object.pos) + origin
            local half = asVector(object.size) * 0.5
            collision[#collision + 1] = {
                surface = "concrete",
                vertices = {
                    { center.x - half.x, center.y - half.y, center.z - half.z },
                    { center.x - half.x, center.y - half.y, center.z + half.z },
                    { center.x - half.x, center.y + half.y, center.z - half.z },
                    { center.x - half.x, center.y + half.y, center.z + half.z },
                    { center.x + half.x, center.y - half.y, center.z - half.z },
                    { center.x + half.x, center.y - half.y, center.z + half.z },
                    { center.x + half.x, center.y + half.y, center.z - half.z },
                    { center.x + half.x, center.y + half.y, center.z + half.z }
                }
            }
        end
    end

    local directional = {}
    if state.sun.intensity > 0.0001 then
        directional[1] = {
            direction = {
                state.sun.direction[1], state.sun.direction[2], state.sun.direction[3]
            },
            color = { 255, 244, 225 },
            intensity = state.sun.intensity,
            shadows = true
        }
    end

    local points = {}
    for _, light in ipairs(state.points) do
        local position = asVector(light.pos) + origin
        points[#points + 1] = {
            position = vectorArray(position),
            color = { light.color[1], light.color[2], light.color[3] },
            intensity = light.intensity,
            radius = light.radius,
            shadows = true,
            dynamic = light.dynamic == true
        }
    end

    return {
        format = NKM.FormatMagic,
        version = NKM.Version,
        name = name,
        description = "Created with NKM Map Editor / Lighting Lab",
        chunkSize = 512,
        meshes = meshes,
        collision = collision,
        lighting = {
            enabled = true,
            shadows = true,
            ambient = { state.ambient[1], state.ambient[2], state.ambient[3] },
            directional = directional,
            point = points,
            deferred = {
                ao = true,
                contactShadows = true,
                aoRadius = 72,
                aoStrength = 0.35
            }
        },
        editor = {
            version = "0.1",
            origin = vectorArray(origin),
            sourceMap = game.GetMap()
        }
    }
end

local function makeDefaultState()
    local ply = LocalPlayer()
    local origin = IsValid(ply) and (ply:GetPos() + ply:GetForward() * 512 + Vector(0, 0, 8)) or Vector(0, 0, 0)
    return {
        origin = origin,
        objects = {},
        points = {},
        selection = nil,
        ambient = { 40, 44, 54 },
        sun = {
            direction = { -0.10, -0.95, 0.30 },
            intensity = 0.85
        }
    }
end

local function makeBox(name, position, size, color)
    return {
        name = name,
        pos = { position[1], position[2], position[3] },
        size = { size[1], size[2], size[3] },
        color = { color[1], color[2], color[3] },
        collision = true
    }
end

local function addTestScene(state)
    state.objects = {
        makeBox("Floor", { 0, 0, -8 }, { 640, 640, 16 }, { 205, 205, 205 }),
        makeBox("Back wall", { 0, 312, 160 }, { 640, 16, 320 }, { 185, 195, 210 }),
        makeBox("Left wall", { -312, 0, 160 }, { 16, 640, 320 }, { 180, 190, 205 }),
        makeBox("Right wall", { 312, 0, 160 }, { 16, 640, 320 }, { 180, 190, 205 }),
        -- Front doorway: the opening is deliberate, not missing wall geometry.
        makeBox("Front wall left", { -200, -312, 160 }, { 240, 16, 320 }, { 180, 190, 205 }),
        makeBox("Front wall right", { 200, -312, 160 }, { 240, 16, 320 }, { 180, 190, 205 }),
        makeBox("Front doorway lintel", { 0, -312, 280 }, { 160, 16, 80 }, { 180, 190, 205 }),
        makeBox("Ceiling", { 0, 0, 320 }, { 640, 640, 16 }, { 165, 175, 190 }),
        makeBox("Pillar", { -120, 20, 80 }, { 64, 64, 160 }, { 205, 205, 205 }),
        makeBox("Test block", { 105, -100, 48 }, { 96, 96, 96 }, { 205, 205, 205 }),
        makeBox("Raised platform", { 80, 170, 24 }, { 180, 120, 48 }, { 205, 205, 205 })
    }
    state.points = {
        {
            name = "Warm point light",
            pos = { -165, -75, 240 },
            color = { 255, 145, 75 },
            intensity = 2.2,
            radius = 520
        },
        {
            name = "Cool point light",
            pos = { 165, 55, 170 },
            color = { 90, 155, 255 },
            intensity = 1.65,
            radius = 410,
            dynamic = true
        }
    }
    state.ambient = { 40, 44, 54 }
    state.sun.intensity = 0.85
    state.sun.direction = { -0.10, -0.95, 0.30 }
    state.selection = { kind = "object", index = 1 }
end

local function sendUpload(mapTable, loadAfterSave, statusCallback)
    local json = util.TableToJSON(mapTable, false)
    if not isstring(json) or json == "" then
        statusCallback("Не удалось сериализовать NKM-карту.", false)
        return
    end

    local maxBytes = NKM.MaxMapBytes or (2 * 1024 * 1024)
    if #json > maxBytes then
        statusCallback("Карта превышает лимит NKM: " .. #json .. " / " .. maxBytes .. " байт.", false)
        return
    end

    local compressed = util.Compress(json)
    if not isstring(compressed) or #compressed < 1 or #compressed > maxBytes then
        statusCallback("Не удалось сжать карту или сжатый файл слишком велик.", false)
        return
    end

    local partBytes = 48000
    local partCount = math.ceil(#compressed / partBytes)
    if partCount > 65535 then
        statusCallback("Слишком много частей для передачи.", false)
        return
    end

    net.Start(NET_BEGIN)
        net.WriteString(mapTable.name)
        net.WriteUInt(#compressed, 32)
        net.WriteUInt(partCount, 16)
        net.WriteString(util.CRC(compressed))
        net.WriteBool(loadAfterSave == true)
    net.SendToServer()

    for partIndex = 1, partCount do
        local first = (partIndex - 1) * partBytes + 1
        local part = string.sub(compressed, first, first + partBytes - 1)
        net.Start(NET_PART)
            net.WriteUInt(partIndex, 16)
            net.WriteUInt(#part, 16)
            net.WriteData(part, #part)
        net.SendToServer()
    end

    net.Start(NET_FINISH)
    net.SendToServer()
    statusCallback(string.format("Передача %s: %d байт JSON, %d частей…", mapTable.name, #json, partCount), true)
end

net.Receive(NET_RESULT, function()
    local saved = net.ReadBool()
    local loaded = net.ReadBool()
    local message = net.ReadString()
    chat.AddText(Color(90, 190, 255), "[NKM Editor] ", saved and Color(120, 230, 140) or Color(255, 130, 110), message)

    if IsValid(NKMEditorFrame) and IsValid(NKMEditorFrame.NKMStatus) then
        NKMEditorFrame.NKMStatus:SetText(message)
        NKMEditorFrame.NKMStatus:SetTextColor(saved and Color(100, 205, 130) or Color(225, 125, 105))
    end
end)

local function openEditor()
    if not NKM or not NKM.ValidateMap or not NKM.BakeMapLighting then
        chat.AddText(Color(255, 120, 100), "[NKM Editor] Требуется NKM Lighting 0.9.9 или новее.")
        return
    end
    if IsValid(NKMEditorFrame) then
        NKMEditorFrame:MakePopup()
        NKMEditorFrame:Center()
        return
    end

    local state = makeDefaultState()
    addTestScene(state)
    local camera = {
        target = Vector(0, 0, 90),
        distance = 1050,
        yaw = -90,
        pitch = 24
    }

    local frame = vgui.Create("DFrame")
    NKMEditorFrame = frame
    frame:SetTitle("NKM Map Editor — Lighting Lab")
    frame:SetSize(math.min(ScrW() - 80, 1440), math.min(ScrH() - 80, 900))
    frame:SetMinWidth(1050)
    frame:SetMinHeight(680)
    frame:Center()
    frame:MakePopup()
    frame:SetDeleteOnClose(true)
    frame.OnClose = function()
        NKMEditorFrame = nil
    end

    local function setStatus(message, good)
        if IsValid(frame.NKMStatus) then
            frame.NKMStatus:SetText(message)
            frame.NKMStatus:SetTextColor(good and Color(100, 205, 130) or Color(225, 170, 105))
        end
    end

    local top = vgui.Create("DPanel", frame)
    top:Dock(TOP)
    top:SetTall(42)
    top:DockPadding(8, 6, 8, 5)
    top.Paint = function(_, w, h)
        surface.SetDrawColor(29, 36, 47, 255)
        surface.DrawRect(0, 0, w, h)
    end

    local mapLabel = vgui.Create("DLabel", top)
    mapLabel:Dock(LEFT)
    mapLabel:SetWide(68)
    mapLabel:SetText("Map name:")
    mapLabel:SetTextColor(Color(225, 230, 240))

    local mapName = vgui.Create("DTextEntry", top)
    mapName:Dock(LEFT)
    mapName:SetWide(170)
    mapName:SetText("nkm_light_test")
    mapName:SetUpdateOnType(true)

    local originButton = vgui.Create("DButton", top)
    originButton:Dock(LEFT)
    originButton:DockMargin(8, 0, 0, 0)
    originButton:SetWide(150)
    originButton:SetText("Set origin to player")
    originButton.DoClick = function()
        local ply = LocalPlayer()
        if IsValid(ply) then
            state.origin = ply:GetPos() + ply:GetForward() * 512 + Vector(0, 0, 8)
            setStatus("Origin moved to player position + 512 units forward.", true)
        end
    end

    local originText = vgui.Create("DLabel", top)
    originText:Dock(LEFT)
    originText:DockMargin(10, 0, 0, 0)
    originText:SetTextColor(Color(165, 180, 200))
    originText.Think = function(self)
        local o = state.origin
        self:SetText(string.format("Origin: %.0f, %.0f, %.0f   |   Source: %s", o.x, o.y, o.z, game.GetMap()))
        self:SizeToContents()
    end

    local bottom = vgui.Create("DPanel", frame)
    bottom:Dock(BOTTOM)
    bottom:SetTall(38)
    bottom:DockPadding(7, 5, 7, 5)
    bottom.Paint = function(_, w, h)
        surface.SetDrawColor(29, 36, 47, 255)
        surface.DrawRect(0, 0, w, h)
    end

    local status = vgui.Create("DLabel", bottom)
    frame.NKMStatus = status
    status:Dock(LEFT)
    status:SetWide(480)
    status:SetText("Shadow test room loaded. Sunlight enters through the doorway; solid NKM geometry should occlude light rays.")
    status:SetTextColor(Color(165, 195, 220))

    local left = vgui.Create("DPanel", frame)
    left:Dock(LEFT)
    left:SetWide(250)
    left:DockPadding(6, 6, 6, 6)
    left.Paint = function(_, w, h)
        surface.SetDrawColor(31, 38, 49, 255)
        surface.DrawRect(0, 0, w, h)
    end

    local rightScroll = vgui.Create("DScrollPanel", frame)
    rightScroll:Dock(RIGHT)
    rightScroll:SetWide(310)
    rightScroll:DockMargin(0, 4, 4, 4)
    local right = rightScroll:GetCanvas()

    local viewport = vgui.Create("DPanel", frame)
    viewport:Dock(FILL)
    viewport:DockMargin(4, 4, 4, 4)
    viewport:SetMouseInputEnabled(true)
    viewport:SetKeyboardInputEnabled(false)
    viewport.Paint = function(self, w, h)
        drawEditorScene(state, camera, self)
    end
    viewport.PaintOver = function(self, w, h)
        draw.SimpleText("ЛКМ: вращать   ПКМ: панорама   Колесо: масштаб", "DermaDefault", 12, h - 24,
            Color(225, 230, 240, 210), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText("Flat-face lighting preview; Save + Load runs the actual NKM vertex bake", "DermaDefault", 12, 12,
            Color(150, 190, 220, 220), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    viewport.OnMousePressed = function(self, mouseCode)
        self.NKMDragMode = mouseCode == MOUSE_RIGHT and "pan" or "orbit"
        self.NKMLastMouseX = gui.MouseX()
        self.NKMLastMouseY = gui.MouseY()
        self:MouseCapture(true)
        return true
    end
    viewport.OnMouseReleased = function(self)
        self.NKMDragMode = nil
        self:MouseCapture(false)
    end
    viewport.OnCursorMoved = function(self)
        if not self.NKMDragMode then return end
        local x, y = gui.MouseX(), gui.MouseY()
        local dx, dy = x - (self.NKMLastMouseX or x), y - (self.NKMLastMouseY or y)
        self.NKMLastMouseX, self.NKMLastMouseY = x, y
        if self.NKMDragMode == "orbit" then
            camera.yaw = camera.yaw - dx * 0.45
            camera.pitch = math.Clamp(camera.pitch + dy * 0.35, -78, 78)
        else
            local orbit = Angle(-camera.pitch, camera.yaw, 0)
            local rightVector = orbit:Right()
            local upVector = Vector(0, 0, 1)
            local scale = camera.distance * 0.0018
            camera.target = camera.target + rightVector * (-dx * scale) + upVector * (dy * scale)
        end
    end
    viewport.OnMouseWheeled = function(_, delta)
        camera.distance = math.Clamp(camera.distance * (delta > 0 and 0.88 or 1.14), 120, 12000)
        return true
    end

    local function addLeftButton(label, callback)
        local button = vgui.Create("DButton", left)
        button:Dock(TOP)
        button:SetTall(27)
        button:DockMargin(0, 0, 0, 4)
        button:SetText(label)
        button.DoClick = callback
        return button
    end

    local refreshList, refreshProperties

    local function addObject(name, pos, size, color)
        if #state.objects >= 120 then
            setStatus("Object limit reached (120).", false)
            return
        end
        state.objects[#state.objects + 1] = makeBox(name, pos, size, color or { 205, 205, 205 })
        state.selection = { kind = "object", index = #state.objects }
        refreshList()
        refreshProperties()
        setStatus("Added " .. name .. ".", true)
    end

    local function addPointLight()
        if #state.points >= 32 then
            setStatus("NKM supports up to 32 point lights in this version.", false)
            return
        end
        state.points[#state.points + 1] = {
            name = "Point light " .. (#state.points + 1),
            pos = { 0, 0, 190 },
            color = { 255, 190, 130 },
            intensity = 1.5,
            radius = 420,
            dynamic = false
        }
        state.selection = { kind = "light", index = #state.points }
        refreshList()
        refreshProperties()
        setStatus("Added point light.", true)
    end

    addLeftButton("Create lighting test room", function()
        addTestScene(state)
        camera.target = Vector(0, 0, 90)
        camera.distance = 1050
        refreshList()
        refreshProperties()
        setStatus("Test room created: enclosed room, doorway, ceiling, pillar, block, platform and 2 shadow-casting lights.", true)
    end)
    addLeftButton("+ Add box", function()
        addObject("Box " .. (#state.objects + 1), { 0, 0, 48 }, { 96, 96, 96 })
    end)
    addLeftButton("+ Add floor", function()
        addObject("Floor " .. (#state.objects + 1), { 0, 0, -8 }, { 512, 512, 16 })
    end)
    addLeftButton("+ Add wall", function()
        addObject("Wall " .. (#state.objects + 1), { 0, 180, 96 }, { 512, 16, 192 })
    end)
    addLeftButton("+ Add point light", addPointLight)
    addLeftButton("Move selected to aim trace", function()
        local selected = getEntry(state, state.selection)
        if not selected then
            setStatus("Select an object or point light first.", false)
            return
        end
        local ply = LocalPlayer()
        if not IsValid(ply) then return end
        local trace = ply:GetEyeTrace()
        if not trace or not trace.Hit then
            setStatus("Aim at a surface first.", false)
            return
        end
        local localPos = trace.HitPos - state.origin
        selected.pos = vectorArray(localPos)
        setStatus("Selected item moved to your aim position.", true)
        refreshProperties()
    end)
    addLeftButton("Duplicate selected", function()
        local selected = getEntry(state, state.selection)
        if not selected then return end
        if state.selection.kind == "object" then
            if #state.objects >= 120 then return end
            local duplicate = table.Copy(selected)
            duplicate.name = selected.name .. " copy"
            duplicate.pos[1] = duplicate.pos[1] + 48
            duplicate.pos[2] = duplicate.pos[2] + 48
            state.objects[#state.objects + 1] = duplicate
            state.selection = { kind = "object", index = #state.objects }
        else
            if #state.points >= 32 then return end
            local duplicate = table.Copy(selected)
            duplicate.name = selected.name .. " copy"
            duplicate.pos[1] = duplicate.pos[1] + 48
            state.points[#state.points + 1] = duplicate
            state.selection = { kind = "light", index = #state.points }
        end
        refreshList()
        refreshProperties()
    end)
    addLeftButton("Delete selected", function()
        if not state.selection then return end
        if state.selection.kind == "object" then
            table.remove(state.objects, state.selection.index)
        else
            table.remove(state.points, state.selection.index)
        end
        state.selection = nil
        refreshList()
        refreshProperties()
        setStatus("Selected item deleted.", true)
    end)

    local listTitle = vgui.Create("DLabel", left)
    listTitle:Dock(TOP)
    listTitle:SetTall(24)
    listTitle:SetText("Scene objects and lights")
    listTitle:SetTextColor(Color(220, 228, 240))

    local sceneList = vgui.Create("DListView", left)
    sceneList:Dock(FILL)
    sceneList:AddColumn("Item")
    sceneList:AddColumn("Kind"):SetFixedWidth(64)

    local function clearPanel(panel)
        for _, child in ipairs(panel:GetChildren()) do
            child:Remove()
        end
    end

    local function addSection(parent, text)
        local label = vgui.Create("DLabel", parent)
        label:Dock(TOP)
        label:DockMargin(4, 9, 4, 3)
        label:SetTall(22)
        label:SetFont("DermaDefaultBold")
        label:SetTextColor(Color(205, 220, 240))
        label:SetText(text)
        return label
    end

    local function addSlider(parent, label, value, minValue, maxValue, decimals, callback)
        local slider = vgui.Create("DNumSlider", parent)
        slider:Dock(TOP)
        slider:SetTall(34)
        slider:DockMargin(5, 0, 5, 0)
        slider:SetText(label)
        slider:SetMinMax(minValue, maxValue)
        slider:SetDecimals(decimals or 0)
        slider:SetValue(value)
        slider.OnValueChanged = function(_, newValue)
            callback(newValue)
            if IsValid(viewport) then viewport:InvalidateLayout() end
        end
        return slider
    end

    local function addColorMixer(parent, initial, callback)
        local mixer = vgui.Create("DColorMixer", parent)
        mixer:Dock(TOP)
        mixer:DockMargin(5, 4, 5, 5)
        mixer:SetTall(130)
        mixer:SetPalette(false)
        mixer:SetAlphaBar(false)
        mixer:SetWangs(true)
        mixer:SetColor(Color(initial[1], initial[2], initial[3]))
        mixer.ValueChanged = function(_, color)
            callback({ math.floor(color.r), math.floor(color.g), math.floor(color.b) })
            if IsValid(viewport) then viewport:InvalidateLayout() end
        end
        return mixer
    end

    refreshProperties = function()
        if not IsValid(right) then return end
        clearPanel(right)
        addSection(right, "NKM Lighting")
        addSlider(right, "Ambient red", state.ambient[1], 0, 255, 0, function(value) state.ambient[1] = math.floor(value + 0.5) end)
        addSlider(right, "Ambient green", state.ambient[2], 0, 255, 0, function(value) state.ambient[2] = math.floor(value + 0.5) end)
        addSlider(right, "Ambient blue", state.ambient[3], 0, 255, 0, function(value) state.ambient[3] = math.floor(value + 0.5) end)
        addSlider(right, "Sun intensity", state.sun.intensity, 0, 4, 2, function(value) state.sun.intensity = value end)
        addSlider(right, "Sun direction X", state.sun.direction[1], -1, 1, 2, function(value) state.sun.direction[1] = value end)
        addSlider(right, "Sun direction Y", state.sun.direction[2], -1, 1, 2, function(value) state.sun.direction[2] = value end)
        addSlider(right, "Sun direction Z", state.sun.direction[3], -1, 1, 2, function(value) state.sun.direction[3] = value end)

        local selected = getEntry(state, state.selection)
        if not selected then
            addSection(right, "Selection")
            local hint = vgui.Create("DLabel", right)
            hint:Dock(TOP)
            hint:DockMargin(7, 0, 7, 5)
            hint:SetWrap(true)
            hint:SetAutoStretchVertical(true)
            hint:SetText("Select an item in the left list to edit its transform, size and color. Point-light settings are baked when the map is loaded.")
            hint:SetTextColor(Color(175, 185, 200))
            return
        end

        if state.selection.kind == "object" then
            addSection(right, "Geometry: " .. selected.name)
            addSlider(right, "Position X", selected.pos[1], -4096, 4096, 0, function(value) selected.pos[1] = value end)
            addSlider(right, "Position Y", selected.pos[2], -4096, 4096, 0, function(value) selected.pos[2] = value end)
            addSlider(right, "Position Z", selected.pos[3], -4096, 4096, 0, function(value) selected.pos[3] = value end)
            addSlider(right, "Size X", selected.size[1], 4, 4096, 0, function(value) selected.size[1] = math.max(4, value) end)
            addSlider(right, "Size Y", selected.size[2], 4, 4096, 0, function(value) selected.size[2] = math.max(4, value) end)
            addSlider(right, "Size Z", selected.size[3], 4, 4096, 0, function(value) selected.size[3] = math.max(4, value) end)
            addSection(right, "Surface color")
            addColorMixer(right, selected.color, function(color) selected.color = color end)
            local collision = vgui.Create("DCheckBoxLabel", right)
            collision:Dock(TOP)
            collision:DockMargin(7, 4, 7, 8)
            collision:SetText("Generate collision hull")
            collision:SetValue(selected.collision and 1 or 0)
            collision.OnChange = function(_, value) selected.collision = value == true end
        else
            addSection(right, "Point light: " .. selected.name)
            addSlider(right, "Position X", selected.pos[1], -4096, 4096, 0, function(value) selected.pos[1] = value end)
            addSlider(right, "Position Y", selected.pos[2], -4096, 4096, 0, function(value) selected.pos[2] = value end)
            addSlider(right, "Position Z", selected.pos[3], -4096, 4096, 0, function(value) selected.pos[3] = value end)
            addSlider(right, "Radius", selected.radius, 16, 4096, 0, function(value) selected.radius = value end)
            addSlider(right, "Intensity", selected.intensity, 0, 8, 2, function(value) selected.intensity = value end)
            local dynamic = vgui.Create("DCheckBoxLabel", right)
            dynamic:Dock(TOP)
            dynamic:DockMargin(7, 4, 7, 8)
            dynamic:SetText("Dynamic point light (GShader deferred)")
            dynamic:SetValue(selected.dynamic and 1 or 0)
            dynamic.OnChange = function(_, value) selected.dynamic = value == true end
            addSection(right, "Light color")
            addColorMixer(right, selected.color, function(color) selected.color = color end)
        end
    end

    refreshList = function()
        if not IsValid(sceneList) then return end
        sceneList:Clear()
        for index, object in ipairs(state.objects) do
            local line = sceneList:AddLine(object.name, "Geometry")
            line.NKMSelection = { kind = "object", index = index }
            if state.selection and state.selection.kind == "object" and state.selection.index == index then
                sceneList:SelectItem(line)
            end
        end
        for index, light in ipairs(state.points) do
            local line = sceneList:AddLine(light.name, "Point light")
            line.NKMSelection = { kind = "light", index = index }
            if state.selection and state.selection.kind == "light" and state.selection.index == index then
                sceneList:SelectItem(line)
            end
        end
    end

    sceneList.OnRowSelected = function(_, _, line)
        if not line or not line.NKMSelection then return end
        state.selection = table.Copy(line.NKMSelection)
        refreshProperties()
        viewport:InvalidateLayout()
    end

    local function makeCurrentMap()
        local name = sanitizeMapName(mapName:GetValue())
        if not NKM.IsValidMapName(name) then
            setStatus("Map name must contain only letters, numbers, _ or - (max 48 chars).", false)
            return nil
        end
        if #state.objects < 1 then
            setStatus("Add at least one geometry object before saving.", false)
            return nil
        end
        local hulls = 0
        for _, object in ipairs(state.objects) do if object.collision then hulls = hulls + 1 end end
        if hulls > (NKM.MaxCollisionConvexes or 128) then
            setStatus("Too many collision hulls. Disable collision on some objects.", false)
            return nil
        end
        if #state.points > (NKM.MaxLightingPointLights or 32) then
            setStatus("Too many point lights for this NKM runtime.", false)
            return nil
        end
        local mapTable = buildMapTable(state, name)
        local valid, detail = NKM.ValidateMap(mapTable)
        if not valid then
            setStatus("NKM validation failed: " .. tostring(detail), false)
            return nil
        end
        return mapTable
    end

    local function addBottomButton(label, width, callback)
        local button = vgui.Create("DButton", bottom)
        button:Dock(RIGHT)
        button:SetWide(width)
        button:DockMargin(5, 0, 0, 0)
        button:SetText(label)
        button.DoClick = callback
        return button
    end

    addBottomButton("Export JSON", 100, function()
        local mapTable = makeCurrentMap()
        if not mapTable then return end
        local json = util.TableToJSON(mapTable, true)
        file.CreateDir("nkm_editor")
        file.Write("nkm_editor/" .. mapTable.name .. ".json", json)
        setStatus("Exported to data/nkm_editor/" .. mapTable.name .. ".json", true)
    end)

    addBottomButton("Save to server", 115, function()
        local mapTable = makeCurrentMap()
        if not mapTable then return end
        sendUpload(mapTable, false, function(message, good) setStatus(message, good) end)
    end)

    addBottomButton("Save + Load", 105, function()
        local mapTable = makeCurrentMap()
        if not mapTable then return end
        sendUpload(mapTable, true, function(message, good) setStatus(message, good) end)
    end)

    addBottomButton("Reset camera", 100, function()
        camera.target = Vector(0, 0, 90)
        camera.distance = 1050
        camera.yaw = -90
        camera.pitch = 24
    end)

    refreshList()
    refreshProperties()
    setStatus("Test room loaded in editor. The viewport previews NKM's current static lighting model.", true)
end

concommand.Add("nkm_editor", openEditor)
