-- ============================================================
-- main.lua
-- ============================================================

-- Optional debugger bootstrap 
-- local IS_DEBUG = (arg and arg[2] == "debug") or (os.getenv("LOCAL_LUA_DEBUGGER_VSCODE") == "1")
-- if IS_DEBUG then
--     print("Starting lldebugger...")
--     require("lldebugger").start()
--     function love.errorhandler(msg) error(msg, 2) end
-- end
--

-- ============================================================
-- Constants / Enums
-- ============================================================

error_messages = {
    MONSTER_FAILED_TO_LOAD = "MONSTER_FAILED_TO_LOAD",
    COULD_NOT_CREATE_FILE  = "COULD_NOT_CREATE_FILE",
    COULD_NOT_SAVE         = "COULD_NOT_SAVE",
    MONSTER_NOT_ADDED      = "MONSTER_NOT_ADDED",
    FAILED_TO_LOAD         = "FAILED_TO_LOAD"
}

exit_codes = {
    OK = 0,
    PLAYER_LOST = 1,
    PLAYER_WON = 2,
    MISSING_ASSET = 3,
    CRASH = 4,
    DEBUG_QUIT = 5
}

-- ============================================================
-- Debug flags (separate "environments")
--   dbg.ui      -> in-game overlay (toggle with 'e')
--   dbg.terminal-> terminal verbose (toggle with 'f')
-- ============================================================
dbg = { ui = false, terminal = false }

local function term_print(msg)
    if dbg.terminal then print(msg) end
end

-- ============================================================
-- Player state (simple for now)
-- ============================================================
player_xp = 0

-- ============================================================
-- Monster canvas cache
-- ============================================================
MonsterCache = {
    canvases = {}, -- [id_str] -> Canvas
    order = {},    -- FIFO order
    max = 200
}

function cache_evict_if_needed()
    while #MonsterCache.order > MonsterCache.max do
        local oldId = table.remove(MonsterCache.order, 1)
        local c = MonsterCache.canvases[oldId]
        if c then c:release() end
        MonsterCache.canvases[oldId] = nil
    end
end

-- ============================================================
-- Atlas helpers (border scan + layout build)
-- ============================================================
function sameColor(r1,g1,b1,a1, r2,g2,b2,a2)
    return r1==r2 and g1==r2 and b1==b2 and a1==a2
end

-- NOTE: fix sameColor bug above (g1==r2) would be catastrophic.
-- Correct implementation:
function sameColor(r1,g1,b1,a1, r2,g2,b2,a2)
    return r1==r2 and g1==g2 and b1==b2 and a1==a2
end

function isBorder(atlas, x, y, br,bg,bb,ba)
    local r,g,b,a = atlas:getPixel(x,y)
    return sameColor(r,g,b,a, br,bg,bb,ba)
end

function get_atlas_rowcol_dimensions(atlas)
    local W, H = atlas:getWidth(), atlas:getHeight()

    -- 1) border color from upper-left pixel
    local br,bg,bb,ba = atlas:getPixel(0,0)

    -- 2) walk diagonally until we find a non-border pixel
    local x, y = 0, 0
    while x < W and y < H and isBorder(atlas, x, y, br,bg,bb,ba) do
        x = x + 1
        y = y + 1
    end
    assert(x < W and y < H, "Never left the border; is the whole image border-colored?")

    -- 3) snap to earliest interior corner
    while y > 0 and not isBorder(atlas, x, y-1, br,bg,bb,ba) do y = y - 1 end
    while x > 0 and not isBorder(atlas, x-1, y, br,bg,bb,ba) do x = x - 1 end
    local first_x, first_y = x, y

    -- 4) measure cell width
    local x2 = first_x
    while x2 < W and not isBorder(atlas, x2, first_y, br,bg,bb,ba) do x2 = x2 + 1 end
    local cell_w = x2 - first_x
    assert(cell_w > 0, "Cell width measured as 0")

    -- 5) measure row1 height
    local y2 = first_y
    while y2 < H and not isBorder(atlas, first_x, y2, br,bg,bb,ba) do y2 = y2 + 1 end
    local row1_h = y2 - first_y
    assert(row1_h > 0, "Row height measured as 0")

    -- 6) detect all row heights (rows may differ)
    local rows = { row1_h }

    -- Find border thickness between row1 and row2 (border_y)
    local border_y = 0
    do
        local cy = first_y + row1_h
        while cy < H and isBorder(atlas, first_x, cy, br,bg,bb,ba) do
            border_y = border_y + 1
            cy = cy + 1
        end
    end
    if border_y == 0 then border_y = 1 end -- safe default

    -- Measure remaining rows
    do
        local cy = first_y + row1_h + border_y
        while cy < H do
            if isBorder(atlas, first_x, cy, br,bg,bb,ba) then
                cy = cy + 1
            else
                local start = cy
                while cy < H and not isBorder(atlas, first_x, cy, br,bg,bb,ba) do
                    cy = cy + 1
                end
                local rh = cy - start
                if rh > 0 then table.insert(rows, rh) end

                -- skip next border chunk
                while cy < H and isBorder(atlas, first_x, cy, br,bg,bb,ba) do
                    cy = cy + 1
                end
            end
        end
    end

    -- 7) columns: count + border_x
    local col_count = 0

    -- measure border_x from first row
    local border_x = 0
    do
        local cx = first_x + cell_w
        while cx < W and isBorder(atlas, cx, first_y, br,bg,bb,ba) do
            border_x = border_x + 1
            cx = cx + 1
        end
    end
    if border_x == 0 then border_x = 1 end -- safe default

    -- count columns across
    do
        local cx = first_x
        while cx < W do
            if isBorder(atlas, cx, first_y, br,bg,bb,ba) then break end
            col_count = col_count + 1
            cx = cx + cell_w + border_x
        end
    end

    -- precompute starts for fast lookup
    local row_starts = {}
    do
        local off = 0
        for i=1,#rows do
            row_starts[i] = off
            off = off + rows[i] + border_y
        end
    end

    local col_starts = {}
    do
        for c=1,col_count do
            col_starts[c] = (c-1) * (cell_w + border_x)
        end
    end

    return {
        border_color = {br,bg,bb,ba},
        first_origin = {first_x, first_y},
        cell_w = cell_w,
        row_heights = rows,
        border_x = border_x,
        border_y = border_y,
        col_count = col_count,
        row_starts = row_starts,
        col_starts = col_starts,
    }
end

function buildMonsterAtlasLayout(imgData, img)
    local d = get_atlas_rowcol_dimensions(imgData)
    local img_w, img_h = img:getDimensions()

    return {
        img = img,
        img_w = img_w,
        img_h = img_h,

        x_origin = d.first_origin[1],
        y_origin = d.first_origin[2],

        cell_w = d.cell_w,
        row_heights = d.row_heights,

        border_x = d.border_x,
        border_y = d.border_y,

        col_count = d.col_count,
        row_starts = d.row_starts,
        col_starts = d.col_starts,
    }
end

function debug_print_atlas_layout()
    print("Atlas origin:", monsterAtlas.x_origin, monsterAtlas.y_origin)
    print("cell_w:", monsterAtlas.cell_w, "border_x:", monsterAtlas.border_x, "border_y:", monsterAtlas.border_y)
    print("rows:", #monsterAtlas.row_heights, "cols:", monsterAtlas.col_count)
    for i,h in ipairs(monsterAtlas.row_heights) do
        print((" row %d: startY=%d height=%d"):format(i, monsterAtlas.row_starts[i], h))
    end
end

-- ============================================================
-- Atlas quad + Monster canvas builder
-- ============================================================

function atlasQuad(row, col, colIndexBase)
    colIndexBase = colIndexBase or 0
    local c = col + (colIndexBase == 0 and 1 or 0)  -- normalize to 1-based column number

    local src_x = monsterAtlas.x_origin + monsterAtlas.col_starts[c]
    local src_y = monsterAtlas.y_origin + monsterAtlas.row_starts[row]

    local w = monsterAtlas.cell_w
    local h = monsterAtlas.row_heights[row]

    return love.graphics.newQuad(src_x, src_y, w, h, monsterAtlas.img_w, monsterAtlas.img_h)
end

function getMonsterImage(monsterId, parts)
    local key = tostring(monsterId)
    local cached = MonsterCache.canvases[key]
    if cached then return cached end

    local w = monsterAtlas.cell_w
    local total_h = 0
    for i=1,#monsterAtlas.row_heights do
        total_h = total_h + monsterAtlas.row_heights[i]
    end

    local canvas = love.graphics.newCanvas(w, total_h)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0,0,0,0)

    local dy = 0
    for row = 1, #monsterAtlas.row_heights do
        local col = parts[row]
        if col ~= nil then
            local q = atlasQuad(row, col, 0) -- parts are 0..7 currently
            love.graphics.draw(monsterAtlas.img, q, 0, dy)
        end
        dy = dy + monsterAtlas.row_heights[row]
    end

    love.graphics.setCanvas()

    MonsterCache.canvases[key] = canvas
    table.insert(MonsterCache.order, key)
    cache_evict_if_needed()

    return canvas
end

-- ============================================================
-- Save / Monster state
-- ============================================================

function save_file_search(id, base_speed)
    local key = tostring(id)
    local m = loaded_save.monsters[key]

    if not m then
        m = {
            timesSeen = 0,
            kills = 0,
            level = 1,
            base_speed = base_speed
        }
        loaded_save.monsters[key] = m
    end

    m.timesSeen = m.timesSeen + 1
    return m
end

-- ============================================================
-- Wave / Monster generation
-- ============================================================

function addMonstertoWave(parts, monsterId, base_speed)
    local spawn_pad = 50
    local sides = { "left", "top", "right", "bottom" }
    local random_side = sides[love.math.random(1, #sides)]

    local screen_x, screen_y
    if random_side == "right" then
        screen_x = M_WIDTH + spawn_pad
        screen_y = love.math.random(-spawn_pad, M_HEIGHT + spawn_pad)
    elseif random_side == "bottom" then
        screen_y = M_HEIGHT + spawn_pad
        screen_x = love.math.random(-spawn_pad, M_WIDTH + spawn_pad)
    elseif random_side == "left" then
        screen_x = -spawn_pad
        screen_y = love.math.random(-spawn_pad, M_HEIGHT + spawn_pad)
    else -- "top"
        screen_y = -spawn_pad
        screen_x = love.math.random(-spawn_pad, M_WIDTH + spawn_pad)
    end

    local img = getMonsterImage(monsterId, parts)
    return {
        spawn_x = screen_x,
        spawn_y = screen_y,
        image = img,
        base_speed = base_speed, -- stored per-monsterId, consistent
        inside_ring = false
    }
end

function waveStart()
    local parts, monsterId, base_speed = generateMonster()
    local spawn = addMonstertoWave(parts, monsterId, base_speed)
    if spawn then
        table.insert(spawn_table.quads, spawn)
    end
end

function generateMonster()
    local parts = {}
    for row = 1, 6 do
        parts[row] = love.math.random(1,8) - 1 -- 0..7
    end

    local id = pack(parts)

    -- initial / base speed  rng between [0.25, 0.99]
    local base_speed = 0.25 + love.math.random() * 0.74

    local monsterData = save_file_search(id, base_speed)
    base_speed = monsterData.base_speed -- if monster already generated keep saved value

    local encoded = json.encode(loaded_save, {indent = true})
    assert(type(encoded) == "string", "json.encode did not return a string")
    love.filesystem.write(save_file, encoded)

    return parts, id, base_speed
end

-- ============================================================
-- Packing / Bit helpers
-- ============================================================

bin_lookup = {
  [0] = "000", [1] = "001", [2] = "010", [3] = "011",
  [4] = "100", [5] = "101", [6] = "110", [7] = "111"
}

function get_binary(a) return bin_lookup[a] end

function to_three_binbits(n)
    local s = bin_lookup[n]
    assert(s, "to_three_binbits(): expected 0..7, got " .. tostring(n))
    return s
end

function to_binary_fixed(n, width)
    local out = {}
    for i = width - 1, 0, -1 do
        local b = bit.band(bit.rshift(n, i), 1)
        out[#out + 1] = (b == 1) and "1" or "0"
    end
    return table.concat(out)
end

function pack(parts)
    local bits_per_part = 3
    local id = 0
    local raw = ""

    for i = 1, #parts do
        local value = parts[i]
        raw = raw .. tostring(value)

        assert(value ~= nil, "pack(): parts[" .. i .. "] is nil")
        assert(value >= 0 and value <= 7, "pack(): parts[" .. i .. "] out of range: " .. tostring(value))

        local shift = bits_per_part * (i - 1)
        local forced_bin = to_three_binbits(value)

        local shifted = bit.lshift(value, shift)
        id = bit.bor(id, shifted)

        if dbg.terminal then
            term_print(string.format("Part %d: value=%d 3bit=%s shift=%d -> shifted=%d id=%d",
                i, value, forced_bin, shift, shifted, id))
        end
    end

    if dbg.terminal then
        term_print("RAW=" .. raw .. "  ID=" .. tostring(id) .. "  bits=" .. to_binary_fixed(id, #parts * bits_per_part))
    end

    return id
end

-- ============================================================
-- Small math helpers
-- ============================================================
local function distance(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return math.sqrt(dx*dx + dy*dy)
end

local function normalize(dx, dy)
    local len = math.sqrt(dx*dx + dy*dy)
    if len == 0 then return 0, 0 end
    return dx / len, dy / len
end

-- ============================================================
-- LÖVE callbacks
-- ============================================================

function love.load()
    local load_start = love.timer.getTime()

    M_WIDTH, M_HEIGHT = love.graphics.getDimensions()
    json = require("dkjson")

    -- Fonts
    font_h = 15
    default_font = love.graphics.newFont("fonts/FiraCode-Regular.ttf", font_h)
    love.graphics.setFont(default_font)

    -- Background
    local r, g, b = love.math.colorFromBytes(178, 178, 249)
    love.graphics.setBackgroundColor(r, g, b)

    -- Ring
    the_ring = {
        center = {x = M_WIDTH / 2, y = M_HEIGHT / 2},
        radius = 100,
        radius_max = 200,
        radius_min = 20,
        radius_growth_speed = 60,
        radius_growth = true
    }

    -- Save
    save_file = "game_save.json"

    -- Atlas
    monsterAtlas_Data = love.image.newImageData("drawing_shapes.png")
    monsterAtlas_img  = love.graphics.newImage(monsterAtlas_Data)
    monsterAtlas = buildMonsterAtlasLayout(monsterAtlas_Data, monsterAtlas_img)

    monsterAtlas.w = monsterAtlas.col_count
    monsterAtlas.h = #monsterAtlas.row_heights

    debug_print_atlas_layout()

    -- Runtime D structures
    wave_quad = {}
    hadError = ""
    spawn_table = { quads = {} }

    -- ============================================================
    -- Save / Load (robust + versioned)
    -- ============================================================

    local CURRENT_SAVE_VERSION = 1

    local function make_fresh_save()
        return {
            save_version = CURRENT_SAVE_VERSION,
            meta = { saveName = "Default" },
            player = { xp = 0 },
            monsters = {}
        }
    end

    local function write_save(tbl)
        local encoded, err = json.encode(tbl, { indent = true })
        assert(type(encoded) == "string", "json.encode failed: " .. tostring(err))
        love.filesystem.write(save_file, encoded)
    end

    local function migrate_save(s)
        -- This is the "after you load/decode" step:
        -- We now have a Lua table `s`, and we can upgrade it if it's older.
        s.save_version = s.save_version or 1

        -- Example placeholder (no changes yet):
        -- if s.save_version < 2 then
        --     -- apply v2 migration steps here
        --     s.save_version = 2
        -- end

        return s
    end

    -- Try to load existing save
    loaded_save = nil
    if love.filesystem.getInfo(save_file) then
        local contents = love.filesystem.read(save_file)
        if contents and contents ~= "" then
            loaded_save = json.decode(contents)
        end
    end

    -- If missing/empty/corrupt -> create fresh save
    if type(loaded_save) ~= "table" then
        loaded_save = make_fresh_save()
        write_save(loaded_save)
    else
        loaded_save = migrate_save(loaded_save)
        -- Optionally persist migrations/normalization:
        write_save(loaded_save)
    end

    -- Ensure required fields exist (future-proofing)
    loaded_save.monsters = loaded_save.monsters or {}
    loaded_save.player   = loaded_save.player   or {}
    loaded_save.player.xp = loaded_save.player.xp or 0

    player_xp = loaded_save.player.xp

    load_data = love.timer.getTime() - load_start
end

function love.update(dt)
    -- Ring radius in/out
    if the_ring.radius_growth then
        the_ring.radius = the_ring.radius + the_ring.radius_growth_speed * dt
        if the_ring.radius >= the_ring.radius_max then
            the_ring.radius = the_ring.radius_max
            the_ring.radius_growth = false
        end
    else
        the_ring.radius = the_ring.radius - the_ring.radius_growth_speed * dt
        if the_ring.radius <= the_ring.radius_min then
            the_ring.radius = the_ring.radius_min
            the_ring.radius_growth = true
        end
    end

    -- Ring center movement (WASD)
    if love.keyboard.isDown("a") then the_ring.center.x = the_ring.center.x - 1 end
    if love.keyboard.isDown("s") then the_ring.center.y = the_ring.center.y + 1 end
    if love.keyboard.isDown("w") then the_ring.center.y = the_ring.center.y - 1 end
    if love.keyboard.isDown("d") then the_ring.center.x = the_ring.center.x + 1 end

    -- Clamp ring fully on screen
    if (the_ring.center.x + the_ring.radius) > M_WIDTH then
        the_ring.center.x = M_WIDTH - the_ring.radius
    elseif (the_ring.center.x - the_ring.radius) < 0 then
        the_ring.center.x = the_ring.radius
    end

    if (the_ring.center.y + the_ring.radius) > M_HEIGHT then
        the_ring.center.y = M_HEIGHT - the_ring.radius
    elseif (the_ring.center.y - the_ring.radius) < 0 then
        the_ring.center.y = the_ring.radius
    end

    -- Monsters follow ring center, but can only cross the ring boundary while contracting.
    local cx, cy = the_ring.center.x, the_ring.center.y
    local ringR = the_ring.radius
    local contracting = (the_ring.radius_growth == false)

    for i = 1, #spawn_table.quads do
        local m = spawn_table.quads[i]
        local img = m.image
        local iw, ih = img:getDimensions()

        -- monster center
        local mx = m.spawn_x + iw * 0.5
        local my = m.spawn_y + ih * 0.5

        -- direction to ring center
        local dx, dy = normalize(cx - mx, cy - my)

        -- speed: treat base_speed as a scalar, convert to pixels/sec via multiplier
        local pixels_per_sec = (m.base_speed or 0.5) * 180
        local step = pixels_per_sec * dt

        -- proposed next
        local next_x = m.spawn_x + dx * step
        local next_y = m.spawn_y + dy * step
        local next_mx = next_x + iw * 0.5
        local next_my = next_y + ih * 0.5

        local dist_now = distance(mx, my, cx, cy)
        local dist_next = distance(next_mx, next_my, cx, cy)

        if m.inside_ring then
            m.spawn_x, m.spawn_y = next_x, next_y
        else
            local crossing = (dist_now > ringR) and (dist_next <= ringR)
            if crossing then
                if contracting then
                    m.inside_ring = true
                    m.spawn_x, m.spawn_y = next_x, next_y
                else
                    -- blocked at boundary while expanding: do not move this frame
                end
            else
                m.spawn_x, m.spawn_y = next_x, next_y
            end
        end
    end
end

function love.draw()
    -- Ring
    love.graphics.setColor(1,1,1,1)
    love.graphics.circle("line", the_ring.center.x, the_ring.center.y, the_ring.radius)

    -- Monsters
    for _, spawn in ipairs(spawn_table.quads) do
        love.graphics.draw(spawn.image, spawn.spawn_x, spawn.spawn_y)
    end

    -- UI Debug overlay (UI-only)
    love.graphics.setColor(255/255, 192/255, 203/255)
    local UI_debug_print = {}
    local report = the_ring.radius_growth and "Expanding" or "Contracting"

    if dbg.ui then
        UI_debug_print = {
            "char_x: " .. the_ring.center.x .. ", char_y: " .. the_ring.center.y,
            ("Rad = %.2f"):format(the_ring.radius),
            report,
            "alive monsters: " .. tostring(#spawn_table.quads),
            "terminal dbg (f): " .. tostring(dbg.terminal),
            "XP: " .. tostring(player_xp)
        }
    else
        UI_debug_print = {
            "Press 'e' for UI debug overlay",
            "Press 'f' for terminal debug",
            "Press SPACE to spawn a monster",
            "XP: " .. tostring(player_xp)
        }
    end

    local lt_width = default_font:getWidth("Load time:")
    love.graphics.printf("Load time: " .. load_data .. " sec", M_WIDTH - 50 - lt_width, 25, lt_width, "right")

    for i,v in ipairs(UI_debug_print) do
        love.graphics.print(v, 20, i * 20)
    end
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    elseif key == "space" then
        waveStart()
    elseif key == "e" then
        dbg.ui = not dbg.ui
    elseif key == "f" then
        dbg.terminal = not dbg.terminal
        print("[terminal debug] " .. tostring(dbg.terminal))
    end
end

function love.mousepressed(x, y, button)
    if button ~= 1 then return end -- left click

    -- click-to-kill ONLY if inside the ring
    for i = #spawn_table.quads, 1, -1 do
        local m = spawn_table.quads[i]
        if m.inside_ring then
            local iw, ih = m.image:getDimensions()
            if x >= m.spawn_x and x <= (m.spawn_x + iw) and
               y >= m.spawn_y and y <= (m.spawn_y + ih) then

                table.remove(spawn_table.quads, i)

                -- XP gain (just an int ftm)
                player_xp = player_xp + 25
                loaded_save.player.xp = player_xp
                local encoded = json.encode(loaded_save, {indent = true})
                if type(encoded) == "string" then
                    love.filesystem.write(save_file, encoded)
                end

                return
            end
        end
    end
end