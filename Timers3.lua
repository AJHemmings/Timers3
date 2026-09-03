--[[
Copyright © 2024, Gol-exe
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Timers2 nor the names of its contributors may be
      used to endorse or promote products derived from this software without
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL Gol-exe BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-- Timers3, 2026, Mak: forked from Gol-exe/Timers2 — rebrand, taller
-- bars with centered/brighter text, and a drag-to-reposition setup mode.
]]

_addon.name     = 'Timers3'
_addon.author   = 'Mak (fork of Gol-exe/Timers2)'
_addon.version  = '1.2.0'
_addon.commands = {'timers3', 'tm3'}

-- Globals expected by themes and data layer
config  = require('config')
texts   = require('texts')
images  = require('images')
packets = require('packets')
local res = require('resources')
require('logger')
require('tables')
require('lists')
require('sets')
require('strings')

local data = require('data')

-- Both themes are loaded once at startup; switching is just changing the pointer.
local themes = {
    classic = require('themes/classic'),
    slim    = require('themes/slim'),
}

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
local defaults = {
    pos                = {x = 100, y = 450},
    custom_pos         = {x = 480, y = 250},
    show_abilities     = true,
    show_spells        = true,
    show_buffs         = true,
    update_interval    = 0.5,
    ability_whitelist  = {},
    spell_whitelist    = {},
    buff_blacklist     = {},
    sort_mode          = 'duration',   -- 'duration' | 'name' | 'player' | 'creation'
    direction          = 'down',       -- 'down' = time remaining | 'up' = time elapsed
    recast_low_to_high = true,         -- soonest recast available shown first
    buff_low_to_high   = false,        -- longest buff remaining shown first
    custom_low_to_high = false,        -- longest custom timer shown first
    recast_limit             = 0,            -- 0 = no limit
    buff_limit               = 0,
    custom_limit              = 0,
    condense_party_threshold = 2,           -- collapse party buffs shared by N+ members into one row (0 = off)
    show_tenths        = true,         -- sub-second display when < 10s remaining
    show_1hour_name    = false,        -- hide timer for SP abilities (recast_id 0/254 — shared-ID "1-hour" abilities)
    group_type         = 'start',      -- 'start' | 'character' | 'none'
    filters            = {},
    active_filter      = '',
    theme              = 'classic',    -- 'classic' | 'slim'
    themes             = {
        classic = {
            high_color     = {r=0,   g=117, b=0  },
            med_percent    = 0.5,
            med_color      = {r=255, g=255, b=0  },
            low_percent    = 0.25,
            low_color      = {r=255, g=0,   b=0  },
            flash_duration = 0,
            flash_color    = {r=255, g=255, b=0  },
            bar_spacing    = 0,
            bar_height     = 14,
            text_y_offset  = -3,
            scale          = 1,
            bg_color       = {a=50,  r=0,   g=0,  b=0  },
            text_color     = {a=255, r=255, g=255, b=255},
            font_name      = 'Consolas',
            font_size      = 8,
            font_bold      = false,
            outline        = 2,
            slim_mode      = false,
            extend_text    = false,
        },
        slim = {
            flash_duration = 0,
            flash_color    = {r=255, g=255, b=0  },
            text_color     = {a=220, r=220, g=220, b=235},
            font_name      = 'Consolas',
            font_size      = 9,
            font_bold      = false,
        },
    },
}

settings = config.load(defaults)

-------------------------------------------------------------------------------
-- Runtime
-------------------------------------------------------------------------------
local current_theme = themes[settings.theme] or themes.classic
local frame_time    = 0
local player_id     = nil
local main_job_id   = nil

local resist_msgs    = S{75, 283}
local buff_wore_msgs = S{64, 204, 206, 350, 531}
local death_msgs     = S{6, 20, 113, 406, 605, 646}

-- Cache of server-reported buff expiry as absolute os.clock() values, refreshed
-- every 0x063 packet. Storing expiry (not remaining) keeps the value accurate
-- regardless of how much time passes before handle_action consults it.
local buff_sync_expiry = {}

-- Intentional stub: a third-party library will supply real party-buff durations
-- and replace this call site. The 300s placeholder is a deliberate diversion,
-- not an oversight.
local function party_buff_duration_stub() return 300 end

-------------------------------------------------------------------------------
-- Setup mode (drag-to-reposition)
--
-- Windower's texts library makes any text object draggable natively (mouse
-- hit-testing and drag tracking are handled inside the library itself); we
-- just need draggable=true and to poll the object's own position back out
-- with :pos(). See addons/libs/texts.lua in Windower/Lua for texts.pos/draggable.
-------------------------------------------------------------------------------
local setup_mode    = false
local pos_handle     = nil
local custom_handle  = nil

local function make_handle(r, g, b)
    local t = texts.new('', {
        bg      = {visible = true, alpha = 190, red = r, green = g, blue = b},
        text    = {size = 10, font = 'Consolas', red = 255, green = 255, blue = 255, alpha = 255},
        flags   = {draggable = true},
        padding = 3,
    })
    t:stroke_width(1)
    t:stroke_color(0, 0, 0)
    t:stroke_alpha(255)
    t:hide()
    return t
end

-- Reads each handle's live drag position back into settings, and refreshes its
-- own label. Called every frame while setup mode is active so the real panels
-- visually track the drag instead of jumping on the next throttled update.
local function sync_setup_handles()
    if pos_handle then
        local x, y = pos_handle:pos()
        settings.pos.x, settings.pos.y = math.floor(x), math.floor(y)
        pos_handle:text(('TIMERS3  %d,%d\ndrag me - //tm3 lock to save'):format(settings.pos.x, settings.pos.y))
    end
    if custom_handle then
        local x, y = custom_handle:pos()
        settings.custom_pos.x, settings.custom_pos.y = math.floor(x), math.floor(y)
        custom_handle:text(('CUSTOM  %d,%d'):format(settings.custom_pos.x, settings.custom_pos.y))
    end
end

local function enter_setup_mode()
    if not pos_handle    then pos_handle    = make_handle(40,  90, 220) end
    if not custom_handle then custom_handle = make_handle(210, 140, 30) end
    pos_handle:pos(settings.pos.x, settings.pos.y)
    pos_handle:draggable(true)
    pos_handle:show()
    custom_handle:pos(settings.custom_pos.x, settings.custom_pos.y)
    custom_handle:draggable(true)
    custom_handle:show()
    setup_mode = true
    sync_setup_handles()
    windower.add_to_chat(8, '[Timers3] Setup mode ON. Drag the blue handle to move recasts/buffs, the orange handle to move custom timers.')
    windower.add_to_chat(8, '[Timers3] Other commands still work while dragging: classic font/textcolor/barheight/highcolor, etc. //tm3 lock when done.')
end

local function exit_setup_mode()
    setup_mode = false
    if pos_handle    then pos_handle:draggable(false)    ; pos_handle:hide()    end
    if custom_handle then custom_handle:draggable(false) ; custom_handle:hide() end
    config.save(settings)
    windower.add_to_chat(8, ('[Timers3] Setup mode OFF. Saved: pos %d,%d — custom %d,%d.'):format(
        settings.pos.x, settings.pos.y, settings.custom_pos.x, settings.custom_pos.y))
end

-------------------------------------------------------------------------------
-- Packet handlers
-------------------------------------------------------------------------------
local function handle_action(act)
    if not player_id then return end

    if act.category == 4 and act.actor_id == player_id then
        local spell = res.spells[act.param]

        if not spell or not spell.duration or spell.duration <= 0 then return end

        local status_id = spell.status or act.param

        -- Collect all non-resisted targets first so we can detect AOE.
        local hit_self   = false
        local party_hits = {}
        for _, target in ipairs(act.targets) do
            for _, action in ipairs(target.actions) do
                if not resist_msgs:contains(action.message) then
                    if target.id == player_id then
                        hit_self = true
                    else
                        local mob = windower.ffxi.get_mob_by_id(target.id)
                        if mob and not mob.is_npc then
                            table.insert(party_hits, target)
                        end
                    end
                    break
                end
            end
        end

        if hit_self and #party_hits <= 1 then
            local now_clock = os.clock()
            local d = spell.duration
            -- Derive remaining from cached server expiry (os.clock()-based) so the
            -- value is accurate even if the last 0x063 arrived minutes ago.
            local cached_expiry = buff_sync_expiry[status_id]
            local synced_remaining = cached_expiry and math.max(0, cached_expiry - now_clock) or 0
            if synced_remaining > d then d = synced_remaining end

            local existing_entry     = data.self_buff_timers[status_id]
            local existing_remaining = existing_entry and (existing_entry.expires - now_clock) or 0
            if existing_remaining <= d then
                data.self_buff_timers[status_id] = {
                    name=spell.name, expires=now_clock+d, duration=d,
                    created_order=existing_entry and existing_entry.created_order or data.next_order,
                }
                if not existing_entry then data.next_order = data.next_order + 1 end
            end
        end

        if #party_hits > 1 then
            -- AOE: compress all party targets into one entry.
            local d = party_buff_duration_stub()
            data.party_buff_timers['aoe_' .. tostring(status_id)] = {
                name=spell.name, expires=os.clock()+d, duration=d,
                is_aoe=true, status_id=status_id,
                created_order=data.next_order,
            }
            data.next_order = data.next_order + 1
        elseif #party_hits == 1 then
            local target = party_hits[1]
            local d      = party_buff_duration_stub()
            local mob    = windower.ffxi.get_mob_by_id(target.id)
            local pkey   = status_id .. '_' .. tostring(target.id)
            data.party_buff_timers[pkey] = {
                name=spell.name, expires=os.clock()+d, duration=d,
                target_name = mob and mob.name or nil,
                target_id   = target.id,
                status_id   = status_id,
                created_order=data.next_order,
            }
            data.next_order = data.next_order + 1
        end

    elseif (act.category == 6 or act.category == 14 or act.category == 15)
            and act.actor_id == player_id then
        local ability = res.job_abilities[act.param]
        if not ability or not ability.duration or ability.duration <= 0 then return end
        local key = ability.status or act.param
        data.self_buff_timers[key] = {
            name=ability.name, expires=os.clock()+ability.duration, duration=ability.duration,
            created_order=data.next_order,
        }
        data.next_order = data.next_order + 1
    end
end

local function handle_self_buff_update(raw)
    local new = {}
    local now = os.clock()
    buff_sync_expiry = {}  -- Rebuild cache from current server state
    for i = 0, 31 do
        local buff_id = raw:unpack('H', 9  + i * 2)
        local ts      = raw:unpack('I', 73 + i * 4)
        if buff_id and buff_id > 0 and buff_id ~= 0xFF and buff_id ~= 0xFFFF then
            local remaining = data.buff_remaining(ts)
            -- Cache as absolute os.clock() expiry so the value stays accurate
            -- over time without needing to account for elapsed wall time later.
            if remaining and remaining > 0 then
                buff_sync_expiry[buff_id] = now + remaining
            end
            -- Only refresh buffs we actively tracked via a cast; ignore anything
            -- else in the packet so pre-existing buffs are never introduced.
            local existing = data.self_buff_timers[buff_id]
            if existing then
                if remaining == nil or remaining > 0 then
                    local duration
                    if remaining == nil then
                        duration = math.huge
                    elseif existing.duration ~= math.huge
                            and existing.duration >= remaining then
                        duration = existing.duration
                    else
                        duration = remaining
                    end
                    new[buff_id] = {
                        name          = existing.name,
                        expires       = remaining and (now + remaining) or math.huge,
                        duration      = duration,
                        created_order = existing.created_order,
                    }
                end
                -- remaining == 0: buff expired, omit from new (drops the entry)
            end
        end
    end
    data.self_buff_timers = new
end

local function handle_action_message(packet)
    local target_id  = packet['Target']
    local status_id  = packet['Param 1']
    local message_id = packet['Message']

    if buff_wore_msgs:contains(message_id) then
        if target_id == player_id then data.self_buff_timers[status_id] = nil end
        data.party_buff_timers[tostring(status_id) .. '_' .. tostring(target_id)] = nil
    end
    if death_msgs:contains(message_id) and target_id == player_id then
        data.self_buff_timers  = {}
        data.party_buff_timers = {}
    end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
local function refresh_player()
    local player = windower.ffxi.get_player()
    if player then
        player_id           = player.id
        main_job_id         = player.main_job_id
        data.main_job_id    = player.main_job_id
    end
end

windower.register_event('load', 'login', function()
    current_theme.load(settings)
    local info = windower.ffxi.get_info()
    if info.logged_in then refresh_player() end
end)

windower.register_event('unload', function()
    current_theme.unload()
end)

windower.register_event('logout', function()
    player_id                = nil
    main_job_id              = nil
    data.main_job_id         = nil
    data.self_buff_timers    = {}
    data.party_buff_timers   = {}
    data.spell_recast_peak   = {}
    data.ability_recast_peak = {}
    buff_sync_expiry         = {}
end)

windower.register_event('job change', function()
    refresh_player()
end)

windower.register_event('zone change', function()
    data.self_buff_timers    = {}
    data.party_buff_timers   = {}
    data.spell_recast_peak   = {}
    data.ability_recast_peak = {}
    buff_sync_expiry         = {}
end)

windower.register_event('incoming chunk', function(id, raw)
    if id == 0x028 then
        handle_action(windower.packets.parse_action(raw))
    elseif id == 0x029 then
        handle_action_message(packets.parse('incoming', raw))
    elseif id == 0x063 and raw:byte(5) == 0x09 then
        handle_self_buff_update(raw)
    end

end)

windower.register_event('prerender', function()
    if setup_mode then sync_setup_handles() end

    local curr     = os.clock()
    local interval = setup_mode and 0 or settings.update_interval
    if curr > frame_time + interval then
        frame_time = curr
        current_theme.update(data.collect(settings), settings)
    end
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------
windower.register_event('addon command', function(command, ...)
    command = command and command:lower() or 'help'
    local args = L{...}

    if command == 'theme' then
        local name = (args[1] or ''):lower()
        if not themes[name] then
            windower.add_to_chat(8, '[Timers3] Unknown theme. Available: classic, slim')
            return
        end
        current_theme.unload()
        current_theme = themes[name]
        current_theme.load(settings)
        settings.theme = name
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Theme: %s'):format(name))

    elseif command == 'create' or command == 'c' then
        local name     = args:remove(1)
        local duration = tonumber(args:remove(1))
        if not name or not duration then
            error('Usage: //tm3 create <name> <duration>') ; return
        end
        data.custom_timers[name] = {
            expires=os.clock()+duration, duration=duration,
            created_order=data.next_order,
        }
        data.next_order = data.next_order + 1
        local m, s = math.floor(duration / 60), math.floor(duration % 60)
        windower.add_to_chat(8, ('[Timers3] Created timer "%s" (%d:%02d).'):format(name, m, s))

    elseif command == 'delete' or command == 'd' then
        local name = args:concat(' ')
        if data.custom_timers[name] then
            data.custom_timers[name] = nil
            windower.add_to_chat(8, ('[Timers3] Deleted timer "%s".'):format(name))
        else
            windower.add_to_chat(8, ('[Timers3] No custom timer "%s".'):format(name))
        end

    elseif command == 'abilities' or command == 'ab' then
        settings.show_abilities = not settings.show_abilities
        config.save(settings)
        windower.add_to_chat(8, '[Timers3] Abilities ' .. (settings.show_abilities and 'shown' or 'hidden') .. '.')

    elseif command == 'spells' or command == 'sp' then
        settings.show_spells = not settings.show_spells
        config.save(settings)
        windower.add_to_chat(8, '[Timers3] Spells ' .. (settings.show_spells and 'shown' or 'hidden') .. '.')

    elseif command == 'buffs' or command == 'bu' then
        settings.show_buffs = not settings.show_buffs
        config.save(settings)
        windower.add_to_chat(8, '[Timers3] Buffs ' .. (settings.show_buffs and 'shown' or 'hidden') .. '.')

    elseif command == 'sort' then
        local mode = (args[1] or ''):lower()
        if mode ~= 'duration' and mode ~= 'name' and mode ~= 'player' and mode ~= 'creation' then
            windower.add_to_chat(8, 'Usage: //tm3 sort <duration|name|player|creation>') ; return
        end
        settings.sort_mode = mode ; config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Sort mode: %s.'):format(mode))

    elseif command == 'group' then
        local mode = (args[1] or ''):lower()
        if mode ~= 'start' and mode ~= 'character' and mode ~= 'none' then
            windower.add_to_chat(8, 'Usage: //tm3 group <start|character|none>') ; return
        end
        settings.group_type = mode ; config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Group type: %s.'):format(mode))

    elseif command == 'filter' or command == 'f' then
        local sub = (args:remove(1) or ''):lower()

        if sub == 'create' then
            local fname = args:concat(' '):lower()
            if fname == '' then
                windower.add_to_chat(8, 'Usage: //tm3 filter create <name>') ; return
            end
            if data.builtin_filters[fname] then
                windower.add_to_chat(8, ('[Timers3] "%s" is a built-in filter and cannot be replaced.'):format(fname))
                return
            end
            if not settings.filters[fname] then
                settings.filters[fname] = {categories={}, sort='', whitelist={}}
                config.save(settings)
                windower.add_to_chat(8, ('[Timers3] Filter "%s" created.'):format(fname))
            else
                windower.add_to_chat(8, ('[Timers3] Filter "%s" already exists.'):format(fname))
            end

        elseif sub == 'delete' then
            local fname = args:concat(' '):lower()
            if data.builtin_filters[fname] then
                windower.add_to_chat(8, ('[Timers3] "%s" is a built-in filter and cannot be deleted.'):format(fname))
                return
            end
            if settings.filters[fname] then
                settings.filters[fname] = nil
                if settings.active_filter == fname then settings.active_filter = '' end
                config.save(settings)
                windower.add_to_chat(8, ('[Timers3] Filter "%s" deleted.'):format(fname))
            else
                windower.add_to_chat(8, ('[Timers3] No filter "%s".'):format(fname))
            end

        elseif sub == 'select' then
            local fname = args:concat(' '):lower()
            if fname == '' or fname == 'none' then
                settings.active_filter = '' ; config.save(settings)
                windower.add_to_chat(8, '[Timers3] Filter cleared.')
            elseif settings.filters[fname] or data.builtin_filters[fname] then
                settings.active_filter = fname ; config.save(settings)
                windower.add_to_chat(8, ('[Timers3] Filter "%s" active.'):format(fname))
            else
                windower.add_to_chat(8, ('[Timers3] No filter "%s".'):format(fname))
            end

        elseif sub == 'list' then
            windower.add_to_chat(8, '[Timers3] Built-in filters:')
            for fname, fdata in pairs(data.builtin_filters) do
                local marker = (settings.active_filter == fname) and ' [ACTIVE]' or ''
                windower.add_to_chat(8, ('  "%s"%s — %s'):format(fname, marker, fdata.description or ''))
            end
            windower.add_to_chat(8, '[Timers3] Saved filters:')
            local any = false
            for fname, fdata in pairs(settings.filters) do
                any = true
                local cats = {}
                for c in pairs(fdata.categories or {}) do table.insert(cats, c) end
                local marker = (settings.active_filter == fname) and ' [ACTIVE]' or ''
                windower.add_to_chat(8, ('  "%s"%s  sort=%s  cats=%s'):format(
                    fname, marker,
                    (fdata.sort ~= '' and fdata.sort) or 'default',
                    #cats > 0 and table.concat(cats, ',') or 'all'))
            end
            if not any then windower.add_to_chat(8, '  (none)') end

        elseif sub == 'sort' then
            local fname = (args:remove(1) or ''):lower()
            local mode  = (args:remove(1) or ''):lower()
            if data.builtin_filters[fname] then
                windower.add_to_chat(8, ('[Timers3] "%s" is a built-in filter and cannot be modified.'):format(fname))
                return
            end
            if fname == '' or not settings.filters[fname]
               or (mode ~= 'duration' and mode ~= 'name' and mode ~= 'player') then
                windower.add_to_chat(8, 'Usage: //tm3 filter sort <filter_name> <duration|name|player>')
                return
            end
            settings.filters[fname].sort = mode ; config.save(settings)
            windower.add_to_chat(8, ('[Timers3] Filter "%s" sort: %s.'):format(fname, mode))

        elseif sub == 'category' or sub == 'cat' then
            local fname  = (args:remove(1) or ''):lower()
            local action = (args:remove(1) or ''):lower()
            local cat    = (args:remove(1) or ''):lower()
            local valid  = S{'ability', 'spell', 'buff', 'custom'}
            if data.builtin_filters[fname] then
                windower.add_to_chat(8, ('[Timers3] "%s" is a built-in filter and cannot be modified.'):format(fname))
                return
            end
            if fname == '' or not settings.filters[fname]
               or (action ~= 'add' and action ~= 'remove')
               or not valid:contains(cat) then
                windower.add_to_chat(8, 'Usage: //tm3 filter category <filter_name> <add|remove> <ability|spell|buff|custom>')
                return
            end
            settings.filters[fname].categories[cat] = (action == 'add') and true or nil
            config.save(settings)
            windower.add_to_chat(8, ('[Timers3] Filter "%s": %s category "%s".'):format(fname, action, cat))

        elseif sub == 'whitelist' or sub == 'wl' then
            local fname  = (args:remove(1) or ''):lower()
            local action = (args:remove(1) or ''):lower()
            local entry  = args:concat(' ')
            if data.builtin_filters[fname] then
                windower.add_to_chat(8, ('[Timers3] "%s" is a built-in filter and cannot be modified.'):format(fname))
                return
            end
            if fname == '' or not settings.filters[fname]
               or (action ~= 'add' and action ~= 'remove') or entry == '' then
                windower.add_to_chat(8, 'Usage: //tm3 filter whitelist <filter_name> <add|remove> <name>')
                return
            end
            settings.filters[fname].whitelist[entry:lower()] = (action == 'add') and true or nil
            config.save(settings)
            windower.add_to_chat(8, ('[Timers3] Filter "%s" whitelist: %s "%s".'):format(fname, action, entry))

        else
            windower.add_to_chat(8, 'Filter subcommands: create, delete, select, list, sort, category, whitelist')
        end

    elseif command == 'pos' then
        local x = tonumber(args[1])
        local y = tonumber(args[2])
        if not x or not y then
            windower.add_to_chat(8, 'Usage: //tm3 pos <x> <y>') ; return
        end
        settings.pos.x = math.floor(x)
        settings.pos.y = math.floor(y)
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Position set to %d, %d.'):format(settings.pos.x, settings.pos.y))

    elseif command == 'setup' or command == 'reposition' then
        local sub = (args[1] or ''):lower()
        if sub == 'off' then
            exit_setup_mode()
        else
            enter_setup_mode()
        end

    elseif command == 'lock' then
        exit_setup_mode()

    elseif command == 'saveall' or command == 'saveglobal' then
        -- config.save(t, 'all') writes to the shared <global> section instead
        -- of the current character's own section (Windower's config library
        -- defaults every other save call to the logged-in character's name).
        -- This also collapses any existing per-character override sections
        -- back into global, so every character ends up on these settings
        -- unless they're individually re-tuned afterward.
        config.save(settings, 'all')
        windower.add_to_chat(8, '[Timers3] Current settings saved as the shared default for all characters.')

    elseif command == 'interval' or command == 'i' then
        local interval = tonumber(args[1])
        if not interval or interval < 0 then
            error('Usage: //tm3 interval <seconds>  (0 = update every frame, smoothest but more CPU)') ; return
        end
        settings.update_interval = interval ; config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Update interval: %ss.'):format(interval))

    elseif command == 'whitelist' or command == 'wl' then
        local list_type = (args:remove(1) or ''):lower()
        local action    = (args:remove(1) or ''):lower()
        local entry     = args:concat(' ')
        local list_map  = {abilities='ability_whitelist', spells='spell_whitelist'}
        local list_key  = list_map[list_type]
        if not list_key or (action ~= 'add' and action ~= 'remove') or entry == '' then
            error('Usage: //tm3 whitelist <abilities|spells> <add|remove> <name>') ; return
        end
        settings[list_key][entry:lower()] = (action == 'add') and true or nil
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] %s whitelist: %s "%s".'):format(list_type, action, entry))

    elseif command == 'blacklist' or command == 'bl' then
        local action = (args:remove(1) or ''):lower()
        local entry  = args:concat(' ')
        if (action ~= 'add' and action ~= 'remove') or entry == '' then
            error('Usage: //tm3 blacklist <add|remove> <buff name>') ; return
        end
        settings.buff_blacklist[entry:lower()] = (action == 'add') and true or nil
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Buff blacklist: %s "%s".'):format(action, entry))

    elseif command == 'tenths' then
        settings.show_tenths = not settings.show_tenths
        config.save(settings)
        windower.add_to_chat(8, '[Timers3] Show tenths: ' .. (settings.show_tenths and 'ON' or 'OFF') .. '.')

    elseif command == '1hourname' then
        settings.show_1hour_name = not settings.show_1hour_name
        config.save(settings)
        windower.add_to_chat(8, '[Timers3] Show 1-hour name only: ' .. (settings.show_1hour_name and 'ON' or 'OFF') .. '.')

    elseif command == 'direction' or command == 'dir' then
        local dir = (args[1] or ''):lower()
        if dir ~= 'up' and dir ~= 'down' then
            windower.add_to_chat(8, 'Usage: //tm3 direction <up|down>') ; return
        end
        settings.direction = dir ; config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Direction: %s (%s).'):format(
            dir, dir == 'up' and 'show elapsed' or 'show remaining'))

    elseif command == 'recastdir' then
        local dir = (args[1] or ''):lower()
        if dir ~= 'asc' and dir ~= 'desc' then
            windower.add_to_chat(8, 'Usage: //tm3 recastdir <asc|desc>') ; return
        end
        settings.recast_low_to_high = (dir == 'asc')
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Recast sort direction: %s.'):format(dir))

    elseif command == 'buffdir' then
        local dir = (args[1] or ''):lower()
        if dir ~= 'asc' and dir ~= 'desc' then
            windower.add_to_chat(8, 'Usage: //tm3 buffdir <asc|desc>') ; return
        end
        settings.buff_low_to_high = (dir == 'asc')
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Buff sort direction: %s.'):format(dir))

    elseif command == 'customdir' then
        local dir = (args[1] or ''):lower()
        if dir ~= 'asc' and dir ~= 'desc' then
            windower.add_to_chat(8, 'Usage: //tm3 customdir <asc|desc>') ; return
        end
        settings.custom_low_to_high = (dir == 'asc')
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Custom sort direction: %s.'):format(dir))

    elseif command == 'recastlimit' then
        local n = tonumber(args[1])
        if not n or n < 0 then windower.add_to_chat(8, 'Usage: //tm3 recastlimit <N> (0=no limit)') ; return end
        settings.recast_limit = math.floor(n) ; config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Recast row limit: %d.'):format(settings.recast_limit))

    elseif command == 'bufflimit' then
        local n = tonumber(args[1])
        if not n or n < 0 then windower.add_to_chat(8, 'Usage: //tm3 bufflimit <N> (0=no limit)') ; return end
        settings.buff_limit = math.floor(n) ; config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Buff row limit: %d.'):format(settings.buff_limit))

    elseif command == 'customlimit' then
        local n = tonumber(args[1])
        if not n or n < 0 then windower.add_to_chat(8, 'Usage: //tm3 customlimit <N> (0=no limit)') ; return end
        settings.custom_limit = math.floor(n) ; config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Custom row limit: %d.'):format(settings.custom_limit))

    elseif command == 'custompos' then
        local x = tonumber(args[1])
        local y = tonumber(args[2])
        if not x or not y then windower.add_to_chat(8, 'Usage: //tm3 custompos <x> <y>') ; return end
        settings.custom_pos.x = math.floor(x)
        settings.custom_pos.y = math.floor(y)
        config.save(settings)
        windower.add_to_chat(8, ('[Timers3] Custom timer position: %d, %d.'):format(settings.custom_pos.x, settings.custom_pos.y))

    elseif command == 'classic' or command == 'slim' then
        local tname = command
        local tsub  = (args:remove(1) or ''):lower()
        local tc    = settings.themes and settings.themes[tname]
        if not tc then
            windower.add_to_chat(8, '[Timers3] Theme settings not found: ' .. tname) ; return
        end

        local function parse_rgb()
            local r = tonumber(args:remove(1))
            local g = tonumber(args:remove(1))
            local b = tonumber(args:remove(1))
            return r, g, b
        end
        local function parse_argb()
            local a = tonumber(args:remove(1))
            local r, g, b = parse_rgb()
            return a, r, g, b
        end

        local needs_reload = false

        if tsub == 'highcolor' then
            local r, g, b = parse_rgb()
            if not r then windower.add_to_chat(8, 'Usage: //tm3 bars highcolor R G B') ; return end
            tc.high_color = {r=r, g=g, b=b}
        elseif tsub == 'medpercent' then
            local p = tonumber(args[1])
            if not p then windower.add_to_chat(8, 'Usage: //tm3 bars medpercent 0-1') ; return end
            tc.med_percent = p
        elseif tsub == 'medcolor' then
            local r, g, b = parse_rgb()
            if not r then windower.add_to_chat(8, 'Usage: //tm3 bars medcolor R G B') ; return end
            tc.med_color = {r=r, g=g, b=b}
        elseif tsub == 'lowpercent' then
            local p = tonumber(args[1])
            if not p then windower.add_to_chat(8, 'Usage: //tm3 bars lowpercent 0-1') ; return end
            tc.low_percent = p
        elseif tsub == 'lowcolor' then
            local r, g, b = parse_rgb()
            if not r then windower.add_to_chat(8, 'Usage: //tm3 bars lowcolor R G B') ; return end
            tc.low_color = {r=r, g=g, b=b}
        elseif tsub == 'flash' then
            local dur = tonumber(args:remove(1))
            if not dur then windower.add_to_chat(8, 'Usage: //tm3 '..tname..' flash SECONDS [R G B]') ; return end
            tc.flash_duration = dur
            local r, g, b = parse_rgb()
            if r then tc.flash_color = {r=r, g=g, b=b} end
        elseif tsub == 'spacing' and tname == 'classic' then
            local n = tonumber(args[1])
            if not n then windower.add_to_chat(8, 'Usage: //tm3 bars spacing N') ; return end
            tc.bar_spacing = math.floor(n)
        elseif tsub == 'barheight' and tname == 'classic' then
            local n = tonumber(args[1])
            if not n or n <= 0 then windower.add_to_chat(8, 'Usage: //tm3 classic barheight PX') ; return end
            tc.bar_height = math.floor(n)
        elseif tsub == 'textoffset' and tname == 'classic' then
            local n = tonumber(args[1])
            if not n then windower.add_to_chat(8, 'Usage: //tm3 classic textoffset N  (pixels down from the bar\'s top edge; can be negative)') ; return end
            tc.text_y_offset = math.floor(n)
        elseif tsub == 'scale' and tname == 'classic' then
            local n = tonumber(args[1])
            if not n or n <= 0 then windower.add_to_chat(8, 'Usage: //tm3 classic scale N  (e.g. 1, 1.5, 2 ... bar/icon/font/spacing all scale together)') ; return end
            tc.scale = n
        elseif tsub == 'bgcolor' and tname == 'classic' then
            local a, r, g, b = parse_argb()
            if not a then windower.add_to_chat(8, 'Usage: //tm3 bars bgcolor A R G B') ; return end
            tc.bg_color = {a=a, r=r, g=g, b=b}
        elseif tsub == 'textcolor' then
            local a, r, g, b = parse_argb()
            if not a then windower.add_to_chat(8, 'Usage: //tm3 '..tname..' textcolor A R G B') ; return end
            tc.text_color = {a=a, r=r, g=g, b=b}
            needs_reload = true
        elseif tsub == 'font' then
            local fname = args:remove(1)
            local fsize = tonumber(args:remove(1))
            if not fname then windower.add_to_chat(8, 'Usage: //tm3 '..tname..' font NAME SIZE') ; return end
            tc.font_name = fname
            if fsize then tc.font_size = fsize end
            needs_reload = true
        elseif tsub == 'bold' and tname == 'classic' then
            tc.font_bold = not tc.font_bold
            needs_reload = true
        elseif tsub == 'outline' and tname == 'classic' then
            local n = tonumber(args[1])
            if not n or n < 0 then windower.add_to_chat(8, 'Usage: //tm3 classic outline N  (0 = no outline, default 2)') ; return end
            tc.outline = math.floor(n)
            needs_reload = true
        elseif tsub == 'slim' and tname == 'classic' then
            tc.slim_mode = not tc.slim_mode
            windower.add_to_chat(8, '[Timers3] Slim mode: ' .. (tc.slim_mode and 'ON' or 'OFF') .. '.')
        elseif tsub == 'extend' and tname == 'classic' then
            tc.extend_text = not tc.extend_text
            windower.add_to_chat(8, '[Timers3] Extend text: ' .. (tc.extend_text and 'ON' or 'OFF') .. '.')
        else
            windower.add_to_chat(8, '[Timers3] Unknown '..tname..' setting: ' .. tsub)
            return
        end

        config.save(settings)
        if needs_reload and settings.theme == tname then
            current_theme.load(settings)
        end
        windower.add_to_chat(8, ('[Timers3] %s.%s updated.'):format(tname, tsub))

    elseif command == 'help' or command == 'h' then
        windower.add_to_chat(8, 'Timers3 v' .. _addon.version)
        windower.add_to_chat(8, '  theme <classic|slim>               Switch display theme')
        windower.add_to_chat(8, '  setup / reposition                 Drag handles to move panels; //tm3 lock to save')
        windower.add_to_chat(8, '  lock                                Exit setup mode and save position')
        windower.add_to_chat(8, '  saveall / saveglobal                Save current settings as the shared default for every character')
        windower.add_to_chat(8, '  create <name> <dur>               Custom timer')
        windower.add_to_chat(8, '  delete <name>                      Remove custom timer')
        windower.add_to_chat(8, '  abilities / spells / buffs          Toggle section visibility')
        windower.add_to_chat(8, '  sort <duration|name|player|creation>  Sort order')
        windower.add_to_chat(8, '  direction <up|down>                up=elapsed, down=remaining (default)')
        windower.add_to_chat(8, '  recastdir <asc|desc>               Recast sort direction')
        windower.add_to_chat(8, '  buffdir <asc|desc>                 Buff sort direction')
        windower.add_to_chat(8, '  customdir <asc|desc>               Custom sort direction')
        windower.add_to_chat(8, '  recastlimit / bufflimit / customlimit <N>  Row cap (0=off)')
        windower.add_to_chat(8, '  group <start|character|none>       Grouping mode')
        windower.add_to_chat(8, '  pos <x> <y>                        Set main panel position')
        windower.add_to_chat(8, '  custompos <x> <y>                  Set custom timer position')
        windower.add_to_chat(8, '  tenths                             Toggle sub-second display')
        windower.add_to_chat(8, '  1hourname                          Toggle hide timer for 1-hour SP abilities')
        windower.add_to_chat(8, '  classic/slim flash <sec> [R G B]   Flash color when expiring')
        windower.add_to_chat(8, '  classic/slim textcolor A R G B     Text color')
        windower.add_to_chat(8, '  classic/slim font NAME SIZE        Font name and size')
        windower.add_to_chat(8, '  classic highcolor/medcolor/lowcolor R G B')
        windower.add_to_chat(8, '  classic medpercent/lowpercent 0-1  Color threshold')
        windower.add_to_chat(8, '  classic bgcolor A R G B            Bar background color')
        windower.add_to_chat(8, '  classic spacing N                  Extra pixels between rows')
        windower.add_to_chat(8, '  classic barheight N                Bar height in pixels')
        windower.add_to_chat(8, '  classic textoffset N               Vertical text offset from the bar\'s top edge')
        windower.add_to_chat(8, '  classic scale N                    Scales bar/icon/font/spacing together (e.g. 1.5, 2)')
        windower.add_to_chat(8, '  classic outline N                  Text stroke/outline width, 0=none (default 2)')
        windower.add_to_chat(8, '  classic slim                       Toggle hide text labels')
        windower.add_to_chat(8, '  classic extend                     Toggle time outside bar')
        windower.add_to_chat(8, '  filter create <name>               Create a named filter')
        windower.add_to_chat(8, '  filter delete / select / list / sort / category / whitelist')
        windower.add_to_chat(8, '  whitelist <abilities|spells> <add|remove> <name>')
        windower.add_to_chat(8, '  blacklist <add|remove> <buff name>')
        windower.add_to_chat(8, '  interval <seconds>                 Refresh rate (default 0.5; 0 = every frame)')

    else
        windower.add_to_chat(8, ('[Timers3] Unknown command "%s". Type //tm3 help.'):format(command))
    end
end)
