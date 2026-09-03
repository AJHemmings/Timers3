--[[
    Slim theme for Timers2.
    Renders all active timers as plain text: "spellname: M:SS"
    No icons, bars, or graphics — maximum readability at minimum screen space.

    Interface: load(settings), update(result, settings), unload()

    Theme settings (settings.themes.slim):
      flash_duration  seconds   rows below this remaining prefix with '! '  (default 2)
      text_color      {a,r,g,b} display text color                          (default light blue-white)
      font_name       string    font family                                  (default Consolas)
      font_size       points    font size                                    (default 9)
      font_bold       bool      bold text                                    (default false)
]]

local T = {}

local COLUMN_GAP = 120   -- pixels between left and right text columns

local display_left   = nil
local display_right  = nil
local display_custom = nil

local function format_time(seconds, show_tenths)
    if show_tenths and seconds > 0 and seconds < 10 then
        return ('%.1f'):format(seconds)
    end
    if seconds <= 0 then return '0:00' end
    return ('%d:%02d'):format(math.floor(seconds / 60), math.floor(seconds % 60))
end

local function new_display(settings)
    local ts   = (settings and settings.themes and settings.themes.slim) or {}
    local tc   = ts.text_color or {a=220, r=220, g=220, b=235}
    local font = ts.font_name  or 'Consolas'
    local size = ts.font_size  or 9
    local t = texts.new('', {
        bg      = {visible = false, alpha = 0},
        text    = {size=size, font=font, red=tc.r, green=tc.g, blue=tc.b, alpha=tc.a},
        flags   = {draggable = false},
        padding = 2,
    })
    t:stroke_width(1)
    t:stroke_color(0, 0, 0)
    t:stroke_alpha(200)
    t:hide()
    return t
end

function T.load(settings)
    if display_left   then display_left:hide()   end
    if display_right  then display_right:hide()  end
    if display_custom then display_custom:hide() end
    display_left   = new_display(settings)
    display_right  = new_display(settings)
    display_custom = new_display(settings)
end

function T.unload()
    if display_left   then display_left:hide()   end
    if display_right  then display_right:hide()  end
    if display_custom then display_custom:hide() end
end

local function sections_to_lines(sections, flash_dur, show_tenths, show_1hour, count_up)
    local lines = {}
    for _, sec in ipairs(sections) do
        if sec.title then table.insert(lines, sec.title) end
        local indent = sec.title and '  ' or ''
        for _, row in ipairs(sec.rows) do
            local label = row.count and (row.name .. ' [' .. row.count .. ']')
                          or (row.party_name and (row.name .. ' [' .. row.party_name .. ']'))
                          or  row.name
            local display_secs = count_up
                                  and math.max(0, row.total - row.remaining)
                                  or  row.remaining
            local time_str
            if show_1hour and (row.recast_id == 0 or row.recast_id == 254) then
                time_str = nil
            else
                time_str = format_time(display_secs, show_tenths)
            end
            local flash = (row.cat == 'buff' and row.remaining <= flash_dur) and (math.floor(os.clock() * 2) % 2 == 0 and '! ' or '  ') or ''
            if time_str then
                table.insert(lines, ('%s%s%s: %s'):format(indent, flash, label, time_str))
            else
                table.insert(lines, ('%s%s%s'):format(indent, flash, label))
            end
        end
    end
    return lines
end

function T.update(result, settings)
    if not display_left then return end

    local left   = result.left   or {}
    local right  = result.right  or {}
    local custom = result.custom or {}

    local ts         = (settings.themes and settings.themes.slim) or {}
    local flash_dur  = ts.flash_duration or 0
    local show_tenths = settings.show_tenths ~= false
    local show_1hour  = settings.show_1hour_name == true
    local count_up    = (settings.direction or 'down') == 'up'

    local px = settings.pos.x
    local py = settings.pos.y
    local cpos = settings.custom_pos or {x = px, y = py}

    local left_lines   = sections_to_lines(left,   flash_dur, show_tenths, show_1hour, count_up)
    local right_lines  = sections_to_lines(right,  flash_dur, show_tenths, show_1hour, count_up)
    local custom_lines = sections_to_lines(custom, flash_dur, show_tenths, show_1hour, count_up)

    if #left_lines > 0 then
        display_left:pos(px, py)
        display_left:text(table.concat(left_lines, '\n'))
        display_left:show()
    else
        display_left:hide()
    end

    if #right_lines > 0 then
        display_right:pos(px + COLUMN_GAP, py)
        display_right:text(table.concat(right_lines, '\n'))
        display_right:show()
    else
        display_right:hide()
    end

    if #custom_lines > 0 then
        display_custom:pos(cpos.x, cpos.y)
        display_custom:text(table.concat(custom_lines, '\n'))
        display_custom:show()
    else
        display_custom:hide()
    end
end

return T
