--[[
    Classic theme for Timers3.
    Renders each row as a progress bar with an icon (or category dot),
    spell name and time remaining rendered inside the bar.

    Interface: load(settings), update(result, settings), unload()

    Theme settings (settings.themes.classic):
      high_color      {r,g,b}         bar fill color when remaining > med_percent  (default green)
      med_percent     0-1             threshold below which mid color activates     (default 0.5)
      med_color       {r,g,b}         bar fill color in mid range                  (default yellow)
      low_percent     0-1             threshold below which low color activates     (default 0.25)
      low_color       {r,g,b}         bar fill color in low range                  (default red)
      flash_duration  seconds         override fill with flash_color below this    (default 2)
      flash_color     {r,g,b}         fill color used during flash                 (default yellow)
      bar_spacing     pixels          extra vertical gap between rows               (default 0)
      bar_height      pixels          bar height; taller gives text more room inside it (default 14)
      text_y_offset   pixels          vertical text offset from the bar's top edge        (default -3)
      scale           multiplier      scales bar/icon/font/spacing sizes together          (default 1)
      bg_color        {a,r,g,b}       bar background color                         (default dark)
      text_color      {a,r,g,b}       row label and time text color                (default white)
      font_name       string          font family                                   (default Consolas)
      font_size       points          row label font size                           (default 8)
      font_bold       bool            bold row labels                               (default false)
      outline         pixels          text stroke/outline width (0 = none)          (default 2)
      slim_mode       bool            hide all text, show bars+icons only          (default false)
      extend_text     bool            position time outside bar (right side)       (default false)
]]

local res = require('resources')
local T   = {}

-------------------------------------------------------------------------------
-- Fixed layout constants (base/scale-1 values — see `scale` in T.update())
-------------------------------------------------------------------------------
local BASE_ICON_GAP   = 3
local BASE_BAR_W      = 190
local DEFAULT_BAR_H   = 14   -- fallback when settings.themes.classic.bar_height is unset
local BASE_BAR_PAD    = 4
local BASE_TIME_W     = 44
local BASE_SEC_H      = 11
local BASE_GAP        = 3
local BASE_COLUMN_GAP = 12
local BASE_FONT_SEC   = 8
local MAX_ROWS        = 64   -- shared pool across all three columns (left + right + custom)
local MAX_SECS        = 24

local COL_SEC = {180, 180, 215}   -- section header text (not user-configurable)

local ICON_DIRS = {
    ability = windower.addon_path .. 'icons/abilities/',
    spell   = windower.addon_path .. 'icons/spells/',
}

-------------------------------------------------------------------------------
-- Icon name->id/cat lookup
-------------------------------------------------------------------------------
local icon_by_name = {}
for id, spell in pairs(res.spells) do
    local name = spell.en or spell.name
    if name then icon_by_name[name:lower()] = {id=id, cat='spell'} end
end
for id, ability in pairs(res.job_abilities) do
    local name = ability.en or ability.name
    if name and ability.recast_id and not icon_by_name[name:lower()] then
        icon_by_name[name:lower()] = {id=ability.recast_id, cat='ability'}
    end
end

local function resolve_icon(row)
    if row.cat == 'spell'   then return row.spell_id,  'spell'   end
    if row.cat == 'ability' then return row.recast_id, 'ability' end
    if row.cat == 'buff' then
        local ico = row.name and icon_by_name[row.name:lower()]
        if ico then return ico.id, ico.cat end
        return row.buff_id, 'buff'
    end
    return nil, nil
end

-------------------------------------------------------------------------------
-- Primitive helpers
-------------------------------------------------------------------------------
local owned_prims = {}

local function pn(type, i) return 'ti3_' .. type .. '_' .. i end

local function prim_own(name, a, r, g, b)
    table.insert(owned_prims, name)
    windower.prim.create(name)
    windower.prim.set_color(name, a, r, g, b)
    windower.prim.set_visibility(name, false)
end

local function prim_rect(name, x, y, w, h)
    windower.prim.set_position(name, x, y)
    windower.prim.set_size(name, w, h)
    windower.prim.set_visibility(name, true)
end

local function prim_hide(name)
    windower.prim.set_visibility(name, false)
end

local function prim_color(name, a, r, g, b)
    windower.prim.set_color(name, a, r, g, b)
end

-------------------------------------------------------------------------------
-- Text helpers
-------------------------------------------------------------------------------
local TEXT_BG_OFF = {visible = false, alpha = 0}
local NO_DRAG     = {draggable = false}

local function new_text(font_sz, font_name, r, g, b, outline)
    local t = texts.new('', {
        bg    = TEXT_BG_OFF,
        text  = {size=font_sz, font=font_name, red=r, green=g, blue=b, alpha=255},
        flags = NO_DRAG,
        padding = 1,
    })
    t:stroke_width(outline or 2)
    t:stroke_color(0, 0, 0)
    t:stroke_alpha(255)
    t:hide()
    return t
end

local function format_time(seconds, show_tenths)
    if show_tenths and seconds > 0 and seconds < 10 then
        return ('%.1f'):format(seconds)
    end
    if seconds <= 0 then return '0:00' end
    return ('%d:%02d'):format(math.floor(seconds / 60), math.floor(seconds % 60))
end

-------------------------------------------------------------------------------
-- Object pools
-------------------------------------------------------------------------------
local sec_labels      = {}
local row_labels      = {}
local row_times       = {}
local row_icons       = {}
local icon_path_cache = {}
local pool_ready      = false

-- Pool slots are grown lazily (one row/section at a time, the first time that
-- index is actually rendered) instead of eagerly building all MAX_ROWS/MAX_SECS
-- slots at load. Building the full pool up front is ~730 native prim/text/image
-- objects in one synchronous burst, which is enough to stall the client on load.
local allocated_rows = 0
local allocated_secs = 0
local pool_font_name, pool_font_size, pool_tc, pool_bar_h, pool_outline

local function ensure_row(i)
    if i <= allocated_rows then return end
    prim_own(pn('dot', i), 255, 255, 255, 255)
    prim_own(pn('brd', i), 255, 255, 220, 0)
    prim_own(pn('bga', i), 50, 0, 0, 0)
    prim_own(pn('bgb', i), 50, 0, 0, 0)
    prim_own(pn('bgc', i), 50, 0, 0, 0)
    prim_own(pn('fla', i), 255, 0, 117, 0)
    prim_own(pn('flb', i), 255, 0, 117, 0)
    prim_own(pn('flc', i), 255, 0, 117, 0)
    local img = images.new({draggable = false})
    img:fit(false)
    img:size(pool_bar_h, pool_bar_h)
    img:hide()
    row_icons[i]  = img
    row_labels[i] = new_text(pool_font_size, pool_font_name, pool_tc.r, pool_tc.g, pool_tc.b, pool_outline)
    row_times[i]  = new_text(pool_font_size, pool_font_name, pool_tc.r, pool_tc.g, pool_tc.b, pool_outline)
    allocated_rows = i
end

local function ensure_sec(i)
    if i <= allocated_secs then return end
    sec_labels[i] = new_text(BASE_FONT_SEC, pool_font_name, COL_SEC[1], COL_SEC[2], COL_SEC[3], pool_outline)
    allocated_secs = i
end

local function get_icon_path(cat, id)
    if not id then return false end
    local key = cat .. '_' .. tostring(id)
    if icon_path_cache[key] ~= nil then return icon_path_cache[key] end
    local dir      = ICON_DIRS[cat]
    local filename = (cat == 'buff') and (tostring(id) .. '.png')
                                      or (string.format('%05d', id) .. '.png')
    local path = dir and (dir .. filename)
    icon_path_cache[key] = (path and windower.file_exists(path)) and path or false
    return icon_path_cache[key]
end

local function hide_from(from_row, from_sec)
    -- Bounded by what's actually been allocated, not MAX_ROWS/MAX_SECS — most
    -- of that range was never created (see ensure_row/ensure_sec above).
    for i = from_row, allocated_rows do
        prim_hide(pn('dot', i))
        prim_hide(pn('brd', i))
        prim_hide(pn('bga', i))
        prim_hide(pn('bgb', i))
        prim_hide(pn('bgc', i))
        prim_hide(pn('fla', i))
        prim_hide(pn('flb', i))
        prim_hide(pn('flc', i))
        if row_icons[i]  then row_icons[i]:hide()  end
        if row_labels[i] then row_labels[i]:hide() end
        if row_times[i]  then row_times[i]:hide()  end
    end
    for i = from_sec, allocated_secs do
        if sec_labels[i] then sec_labels[i]:hide() end
    end
end

-------------------------------------------------------------------------------
-- Theme interface
-------------------------------------------------------------------------------
function T.load(settings)
    -- Destroy existing prims; text/image objects are hidden (matches the
    -- original reload behavior) and dropped for the lazy pool to rebuild.
    for _, name in ipairs(owned_prims) do windower.prim.delete(name) end
    owned_prims = {}
    for _, img in pairs(row_icons)  do img:hide() end
    for _, t   in pairs(row_labels) do t:hide() end
    for _, t   in pairs(row_times)  do t:hide() end
    for _, t   in pairs(sec_labels) do t:hide() end
    row_icons, row_labels, row_times, sec_labels = {}, {}, {}, {}
    allocated_rows, allocated_secs = 0, 0

    local ts       = (settings and settings.themes and settings.themes.classic) or {}
    pool_font_name = ts.font_name or 'Consolas'
    pool_font_size = ts.font_size or 8
    pool_tc        = ts.text_color or {a=255, r=255, g=255, b=255}
    pool_bar_h     = ts.bar_height or DEFAULT_BAR_H
    pool_outline   = ts.outline or 2

    pool_ready = true
end

function T.unload()
    for _, name in ipairs(owned_prims) do windower.prim.delete(name) end
    owned_prims = {}
    for _, img in pairs(row_icons)  do if img then img:hide() end end
    for _, t   in pairs(sec_labels) do if t   then t:hide()   end end
    for _, t   in pairs(row_labels) do if t   then t:hide()   end end
    for _, t   in pairs(row_times)  do if t   then t:hide()   end end
    pool_ready = false
end

local dot_colors = {
    ability = {255, 165,  40},
    spell   = { 75, 158, 255},
    buff    = { 75, 218,  96},
    custom  = {238, 218,  55},
}

function T.update(result, settings)
    if not pool_ready then return end

    local left   = result.left   or {}
    local right  = result.right  or {}
    local custom = result.custom or {}

    local total_rows = 0
    for _, sec in ipairs(left)   do total_rows = total_rows + #sec.rows end
    for _, sec in ipairs(right)  do total_rows = total_rows + #sec.rows end
    for _, sec in ipairs(custom) do total_rows = total_rows + #sec.rows end

    if total_rows == 0 then hide_from(1, 1); return end

    -- Resolve theme settings with defaults
    local ts           = (settings.themes and settings.themes.classic) or {}
    -- `scale` multiplies every size/spacing constant below together, so the
    -- whole row (icon, bar, text, gaps) grows/shrinks as one proportional unit
    -- instead of each dimension needing to be re-tuned independently.
    local scale         = ts.scale or 1
    local BAR_H         = (ts.bar_height or DEFAULT_BAR_H) * scale
    local ROW_H         = BAR_H + 3 * scale
    local ICON_GAP      = BASE_ICON_GAP   * scale
    local BAR_W         = BASE_BAR_W      * scale
    local BAR_PAD       = BASE_BAR_PAD    * scale
    local TIME_W        = BASE_TIME_W     * scale
    local SEC_H         = BASE_SEC_H      * scale
    local GAP           = BASE_GAP        * scale
    local COLUMN_GAP    = BASE_COLUMN_GAP * scale
    local FONT_SEC      = BASE_FONT_SEC   * scale
    local font_size_px  = (ts.font_size or 8) * scale
    local text_y_off    = (ts.text_y_offset or -3) * scale
    local high_col    = ts.high_color     or {r=0,   g=117, b=0  }
    local med_pct     = ts.med_percent    or 0.5
    local med_col     = ts.med_color      or {r=232, g=226, b=51 }
    local low_pct     = ts.low_percent    or 0.25
    local low_col     = ts.low_color      or {r=255, g=0,   b=0  }
    local flash_dur   = ts.flash_duration or 0
    local flash_col   = ts.flash_color    or {r=255, g=255, b=0  }
    local bar_spc     = (ts.bar_spacing or 0) * scale
    local bg_col      = ts.bg_color       or {a=50,  r=0,   g=0,  b=0  }
    local txt_col     = ts.text_color     or {a=255, r=255, g=255, b=255}
    local slim        = ts.slim_mode      or false
    local ext_text    = ts.extend_text    or false
    local row_height  = ROW_H + bar_spc
    local show_tenths = settings.show_tenths ~= false
    local show_1hour  = settings.show_1hour_name == true

    local count_up = (settings.direction or 'down') == 'up'

    -- For count-up, fill ratio and displayed time are based on elapsed,
    -- not remaining. Flash still triggers on remaining <= flash_dur (near expiry).
    local function row_display(row)
        local ratio
        if row.total > 0 then
            local r = math.max(0, math.min(row.remaining / row.total, 1))
            ratio = count_up and (1 - r) or r
        else
            ratio = 0
        end
        local display_seconds = count_up and math.max(0, row.total - row.remaining) or row.remaining
        return ratio, display_seconds
    end

    local function fill_color(row, ratio)
        if ratio <= low_pct then
            return 255, low_col.r, low_col.g, low_col.b
        elseif ratio <= med_pct then
            return 255, med_col.r, med_col.g, med_col.b
        else
            return 255, high_col.r, high_col.g, high_col.b
        end
    end

    local px      = settings.pos.x
    local py      = settings.pos.y
    local right_x = px + BAR_H + ICON_GAP + BAR_W + COLUMN_GAP
    local cpos    = settings.custom_pos or {x = px, y = py}

    local row_idx = 1
    local sec_idx = 1

    local function render_column(sections, col_x, start_y)
        local bar_x = col_x + BAR_H + ICON_GAP
        local cur_y = start_y

        for _, sec in ipairs(sections) do
            if sec.title and sec_idx <= MAX_SECS then
                ensure_sec(sec_idx)
                sec_labels[sec_idx]:size(FONT_SEC)
                sec_labels[sec_idx]:pos(bar_x, cur_y)
                sec_labels[sec_idx]:text(sec.title)
                sec_labels[sec_idx]:show()
                cur_y   = cur_y + SEC_H + GAP
                sec_idx = sec_idx + 1
            end

            for _, row in ipairs(sec.rows) do
                if row_idx > MAX_ROWS then break end
                ensure_row(row_idx)

                local icon_x = col_x
                local bar_y  = cur_y + math.floor((row_height - BAR_H) / 2)
                local icon_y = bar_y

                -- Icon or coloured dot
                local icon_shown = false
                local slot_img   = row_icons[row_idx]
                if slot_img then
                    local icon_id, icon_cat = resolve_icon(row)
                    local path = icon_id and get_icon_path(icon_cat, icon_id)
                    if path then
                        slot_img:size(BAR_H, BAR_H)
                        slot_img:path(path)
                        slot_img:pos(icon_x, icon_y)
                        slot_img:show()
                        icon_shown = true
                    else
                        slot_img:hide()
                    end
                end

                if not icon_shown then
                    local dc = dot_colors[row.cat] or dot_colors.custom
                    prim_color(pn('dot', row_idx), 255, dc[1], dc[2], dc[3])
                    prim_rect(pn('dot', row_idx), icon_x, icon_y, BAR_H, BAR_H)
                else
                    prim_hide(pn('dot', row_idx))
                end

                -- Flash border — 1px outline just outside the bar, alternates at ~2 Hz.
                -- Created before bg layers so the bg draws on top, exposing only the edge.
                if flash_dur > 0 and row.cat == 'buff' and row.remaining <= flash_dur
                        and math.floor(os.clock() * 2) % 2 == 0 then
                    prim_color(pn('brd', row_idx), 255, flash_col.r, flash_col.g, flash_col.b)
                    prim_rect(pn('brd', row_idx), bar_x - 1, bar_y - 1, BAR_W + 2, BAR_H + 2)
                else
                    prim_hide(pn('brd', row_idx))
                end

                -- Bar background — 3-layer rounded rect (2px corner radius)
                -- bga: full height, 2px inset each side
                -- bgb: 1px inset all sides
                -- bgc: full width, 2px inset top/bottom
                -- Union of the three traces a smooth 2px rounded corner.
                prim_color(pn('bga', row_idx), bg_col.a, bg_col.r, bg_col.g, bg_col.b)
                prim_rect(pn('bga', row_idx), bar_x + 2, bar_y,     BAR_W - 4, BAR_H)
                prim_color(pn('bgb', row_idx), bg_col.a, bg_col.r, bg_col.g, bg_col.b)
                prim_rect(pn('bgb', row_idx), bar_x + 1, bar_y + 1, BAR_W - 2, BAR_H - 2)
                prim_color(pn('bgc', row_idx), bg_col.a, bg_col.r, bg_col.g, bg_col.b)
                prim_rect(pn('bgc', row_idx), bar_x,     bar_y + 2, BAR_W,     BAR_H - 4)

                -- Bar fill — same 3-layer approach; right edge is also rounded.
                local ratio, display_secs = row_display(row)
                local fill_w = math.floor(ratio * BAR_W + 0.5)
                local fa, fr, fg, fb = fill_color(row, ratio)

                if fill_w > 0 then
                    -- flc: full fill width, 2px inset top/bottom (always shown when fill > 0)
                    prim_color(pn('flc', row_idx), fa, fr, fg, fb)
                    prim_rect(pn('flc', row_idx), bar_x, bar_y + 2, fill_w, BAR_H - 4)
                    -- flb: 1px inset all sides
                    local fw_b = fill_w - 2
                    if fw_b > 0 then
                        prim_color(pn('flb', row_idx), fa, fr, fg, fb)
                        prim_rect(pn('flb', row_idx), bar_x + 1, bar_y + 1, fw_b, BAR_H - 2)
                    else
                        prim_hide(pn('flb', row_idx))
                    end
                    -- fla: full height, 2px inset each side
                    local fw_a = fill_w - 4
                    if fw_a > 0 then
                        prim_color(pn('fla', row_idx), fa, fr, fg, fb)
                        prim_rect(pn('fla', row_idx), bar_x + 2, bar_y, fw_a, BAR_H)
                    else
                        prim_hide(pn('fla', row_idx))
                    end
                else
                    prim_hide(pn('fla', row_idx))
                    prim_hide(pn('flb', row_idx))
                    prim_hide(pn('flc', row_idx))
                end

                -- Text labels (hidden in slim mode). This primitive's vertical anchor
                -- doesn't match a simple top-left assumption, so the offset is a live
                -- tunable setting (//tm3 classic textoffset N) rather than computed.
                if not slim then
                    local text_y = bar_y + text_y_off
                    local label  = row.count and (row.name .. ' [' .. row.count .. ']')
                                   or (row.party_name and (row.name .. ' [' .. row.party_name .. ']'))
                                   or  row.name
                    row_labels[row_idx]:size(font_size_px)
                    row_labels[row_idx]:pos(bar_x + BAR_PAD, text_y)
                    row_labels[row_idx]:text(label)
                    row_labels[row_idx]:color(txt_col.r, txt_col.g, txt_col.b)
                    row_labels[row_idx]:alpha(txt_col.a)
                    row_labels[row_idx]:show()

                    if show_1hour and (row.recast_id == 0 or row.recast_id == 254) then
                        row_times[row_idx]:hide()
                    else
                        local time_x = ext_text
                                       and (bar_x + BAR_W + 2)
                                       or  (bar_x + BAR_W - TIME_W)
                        row_times[row_idx]:size(font_size_px)
                        row_times[row_idx]:pos(time_x, text_y)
                        row_times[row_idx]:text(format_time(display_secs, show_tenths))
                        row_times[row_idx]:color(txt_col.r, txt_col.g, txt_col.b)
                        row_times[row_idx]:alpha(txt_col.a)
                        row_times[row_idx]:show()
                    end
                else
                    row_labels[row_idx]:hide()
                    row_times[row_idx]:hide()
                end

                cur_y   = cur_y + row_height
                row_idx = row_idx + 1
            end

            cur_y = cur_y + GAP
        end
    end

    local left_y = py + SEC_H + GAP
    render_column(left,   px,       left_y)
    render_column(right,  right_x,  py)
    render_column(custom, cpos.x,   cpos.y)

    hide_from(row_idx, sec_idx)
end

return T
