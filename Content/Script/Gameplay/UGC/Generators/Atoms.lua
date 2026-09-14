--[[
    Atoms.lua
    原子分布函数：纯算坐标列表，不 spawn Actor。
    供 Gen_*.lua 组合使用。

    所有函数返回的是点数组：
        { { x=..., y=..., z=..., yaw=... [, pitch, roll, prefab] }, ... }

    随机性：所有需要随机的函数都接受 seed 参数（确定性 LCG），
    便于地图存档/重放完全复现。
]]

local M = {}

--============================================================
-- 确定性随机（线性同余 LCG，seed 相同则结果相同）
--============================================================

local function makeRng(seed)
    local s = (seed or 0) % 2147483647
    if s == 0 then s = 1 end
    return function()
        s = (s * 1103515245 + 12345) % 2147483647
        return s / 2147483647   -- 0~1
    end
end

M.makeRng = makeRng

--============================================================
-- 1. RandomScatter：在指定区域内随机散布
-- area_spec:
--   { kind="box",    center={x,y,z}, sx, sy, sz }
--   { kind="circle", center={x,y,z}, radius }    -- XY 平面圆盘
--   { kind="sphere", center={x,y,z}, radius }    -- 3D 球内
-- opts: { rotation = "none" | "yaw_random" }
--============================================================

function M.RandomScatter(area, count, seed, opts)
    opts = opts or {}
    local rng = makeRng(seed)
    local pts = {}
    local cx = area.center.x or 0
    local cy = area.center.y or 0
    local cz = area.center.z or 0
    local rotMode = opts.rotation or "none"

    for _ = 1, count do
        local x, y, z
        if area.kind == "box" then
            x = cx + (rng() - 0.5) * (area.sx or 0)
            y = cy + (rng() - 0.5) * (area.sy or 0)
            z = cz + (rng() - 0.5) * (area.sz or 0)
        elseif area.kind == "circle" then
            local theta = rng() * 2 * math.pi
            local r     = math.sqrt(rng()) * (area.radius or 0)
            x = cx + r * math.cos(theta)
            y = cy + r * math.sin(theta)
            z = cz
        elseif area.kind == "sphere" then
            local theta = rng() * 2 * math.pi
            local phi   = math.acos(2 * rng() - 1)
            local r     = (rng() ^ (1/3)) * (area.radius or 0)
            x = cx + r * math.sin(phi) * math.cos(theta)
            y = cy + r * math.sin(phi) * math.sin(theta)
            z = cz + r * math.cos(phi)
        else
            x, y, z = cx, cy, cz
        end
        local yaw = (rotMode == "yaw_random") and (rng() * 360) or 0
        pts[#pts+1] = { x=x, y=y, z=z, yaw=yaw }
    end
    return pts
end

--============================================================
-- 2. Grid：以 origin 为中心的 rows × cols 网格
--============================================================

function M.Grid(origin, rows, cols, spacing_x, spacing_y, z)
    local pts = {}
    local ox = origin.x or 0
    local oy = origin.y or 0
    z = z or origin.z or 0
    local total_w = (cols - 1) * spacing_x
    local total_h = (rows - 1) * spacing_y
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            pts[#pts+1] = {
                x   = ox - total_w/2 + c * spacing_x,
                y   = oy - total_h/2 + r * spacing_y,
                z   = z,
                yaw = 0,
            }
        end
    end
    return pts
end

--============================================================
-- 3. Line：from→to 之间均匀分布 count 个点
--============================================================

function M.Line(from, to, count, z_offset)
    local pts = {}
    z_offset = z_offset or 0
    if count < 1 then return pts end
    local yaw = math.deg(math.atan2(to.y - from.y, to.x - from.x))
    if count == 1 then
        pts[1] = {
            x = (from.x + to.x) / 2,
            y = (from.y + to.y) / 2,
            z = (from.z + to.z) / 2 + z_offset,
            yaw = yaw,
        }
        return pts
    end
    for i = 0, count - 1 do
        local t = i / (count - 1)
        pts[#pts+1] = {
            x = from.x + (to.x - from.x) * t,
            y = from.y + (to.y - from.y) * t,
            z = from.z + (to.z - from.z) * t + z_offset,
            yaw = yaw,
        }
    end
    return pts
end

--============================================================
-- 4. Circle：环形分布 count 个点
-- yaw_facing: true 时每个点的 yaw 朝向圆心切线方向
--============================================================

function M.Circle(center, radius, count, z, yaw_facing)
    local pts = {}
    z = z or center.z or 0
    for i = 0, count - 1 do
        local angle = (i / count) * 2 * math.pi
        local x = center.x + math.cos(angle) * radius
        local y = center.y + math.sin(angle) * radius
        local yaw = yaw_facing and (math.deg(angle) + 90) or 0
        pts[#pts+1] = { x=x, y=y, z=z, yaw=yaw }
    end
    return pts
end

--============================================================
-- 5. Wall：from→to 沿线垒墙，自动按 segment_length 分段
-- height_layers: 堆叠层数；layer_height: 每层 z 增量
-- 返回的点 yaw 自动对齐到墙体方向
--============================================================

function M.Wall(from, to, segment_length, height_layers, layer_height)
    local pts = {}
    height_layers = height_layers or 1
    layer_height  = layer_height  or segment_length
    local dx, dy = to.x - from.x, to.y - from.y
    local length = math.sqrt(dx*dx + dy*dy)
    if length < 1 then return pts end
    local segs = math.max(1, math.floor(length / segment_length))
    local yaw  = math.deg(math.atan2(dy, dx))
    for i = 0, segs - 1 do
        local t  = (i + 0.5) / segs
        local bx = from.x + dx * t
        local by = from.y + dy * t
        for layer = 0, height_layers - 1 do
            pts[#pts+1] = {
                x = bx,
                y = by,
                z = (from.z or 0) + layer * layer_height,
                yaw = yaw,
            }
        end
    end
    return pts
end

--============================================================
-- 6. PlaceAt：单点精确放置（含完整旋转）
--============================================================

function M.PlaceAt(x, y, z, yaw, pitch, roll)
    return { { x=x or 0, y=y or 0, z=z or 0,
               yaw=yaw or 0, pitch=pitch or 0, roll=roll or 0 } }
end

--============================================================
-- 7. PlaceAlongPath：沿任意折线均匀间隔放置
-- points: { {x,y,z}, {x,y,z}, ... }
-- spacing: 相邻 Actor 间距（cm）
-- yaw_align: true 时每个 Actor yaw 对齐到当前段方向
--============================================================

function M.PlaceAlongPath(points, spacing, yaw_align)
    local pts = {}
    if not points or #points < 2 or not spacing or spacing <= 0 then
        return pts
    end

    -- 计算每段长度与累计长度
    local segLens = {}
    local total = 0
    for i = 1, #points - 1 do
        local a, b = points[i], points[i+1]
        local dx = (b.x or 0) - (a.x or 0)
        local dy = (b.y or 0) - (a.y or 0)
        local dz = (b.z or 0) - (a.z or 0)
        local L = math.sqrt(dx*dx + dy*dy + dz*dz)
        segLens[i] = L
        total = total + L
    end
    if total < 1 then return pts end

    -- 沿折线步进 spacing 距离取点
    local nSteps = math.floor(total / spacing) + 1
    for k = 0, nSteps - 1 do
        local target = k * spacing
        local segIdx = 1
        local acc = 0
        while segIdx <= #segLens and acc + segLens[segIdx] < target do
            acc = acc + segLens[segIdx]
            segIdx = segIdx + 1
        end
        if segIdx > #segLens then break end
        local a, b = points[segIdx], points[segIdx+1]
        local segL = segLens[segIdx]
        local t = (segL > 0) and ((target - acc) / segL) or 0
        local dx = (b.x or 0) - (a.x or 0)
        local dy = (b.y or 0) - (a.y or 0)
        local yaw = yaw_align and math.deg(math.atan2(dy, dx)) or 0
        pts[#pts+1] = {
            x = (a.x or 0) + dx * t,
            y = (a.y or 0) + dy * t,
            z = (a.z or 0) + ((b.z or 0) - (a.z or 0)) * t,
            yaw = yaw,
        }
    end
    return pts
end

--============================================================
-- 8. FillPolygon：在任意 2D 多边形内按密度随机填充（XY 平面）
-- vertices: { {x,y}, {x,y}, ... }（按顺/逆时针均可）
-- density: 期望 Actor 数量（不是面积密度，便于直观控制）
-- z: 统一 Z 坐标
-- seed: 随机种子
-- 算法：bounding box 内拒绝采样 + 射线交叉判内
--============================================================

local function pointInPolygon(px, py, verts)
    local inside = false
    local n = #verts
    local j = n
    for i = 1, n do
        local xi, yi = verts[i].x or 0, verts[i].y or 0
        local xj, yj = verts[j].x or 0, verts[j].y or 0
        if ((yi > py) ~= (yj > py)) and
           (px < (xj - xi) * (py - yi) / ((yj - yi) ~= 0 and (yj - yi) or 1e-9) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function M.FillPolygon(vertices, density, z, seed, opts)
    opts = opts or {}
    local pts = {}
    if not vertices or #vertices < 3 or not density or density < 1 then
        return pts
    end
    z = z or 0
    local rng = makeRng(seed)
    local rotMode = opts.rotation or "none"

    -- bounding box
    local xmin, ymin = math.huge, math.huge
    local xmax, ymax = -math.huge, -math.huge
    for _, v in ipairs(vertices) do
        local vx, vy = v.x or 0, v.y or 0
        if vx < xmin then xmin = vx end
        if vy < ymin then ymin = vy end
        if vx > xmax then xmax = vx end
        if vy > ymax then ymax = vy end
    end

    -- 拒绝采样：最多尝试 density × 30 次
    local maxTries = math.max(50, density * 30)
    local tries = 0
    while #pts < density and tries < maxTries do
        tries = tries + 1
        local x = xmin + rng() * (xmax - xmin)
        local y = ymin + rng() * (ymax - ymin)
        if pointInPolygon(x, y, vertices) then
            local yaw = (rotMode == "yaw_random") and (rng() * 360) or 0
            pts[#pts+1] = { x=x, y=y, z=z, yaw=yaw }
        end
    end
    return pts
end

return M
