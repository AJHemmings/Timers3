--[[
    Data layer for Timers2.
    Owns all runtime state and produces a theme-agnostic result table each frame.
    No display primitives, texts, or images here.

    Return value of collect():
      { left = sections[], right = sections[], custom = sections[] }

    Section contract:  { title, rows[] }
    Row contract:      { cat, name, remaining, total, created_order,
                         [party_name],    -- party buff rows (none mode display)
                         [target_name],   -- party buff rows (player sort)
                         [spell_id],      -- spell recast rows
                         [recast_id],     -- ability recast rows
                         [buff_id] }      -- buff rows (status id)

    left   = merged recast timers (abilities + spells), always headerless
    right  = persistent buff timers (self / AOE / party), layout by group_type
    custom = custom timers, rendered at settings.custom_pos

    group_type controls right-column layout:
      'start'     -- BUFFS-SELF / BUFFS-AOE / [player]
      'character' -- SELF (self-buffs only) / AOE / [player]
      'none'      -- single flat list; party rows carry [CharacterName]/[AOE] suffix

    sort_mode controls row order within every section:
      'duration'  -- by time remaining
      'name'      -- alphabetical
      'player'    -- by target name, then duration
      'creation'  -- by creation order (oldest cast shown first when asc)

    Per-bucket sort direction:
      recast_low_to_high  true  = soonest ready first  (default true)
      buff_low_to_high    true  = soonest expiring first (default false)
      custom_low_to_high  true  = soonest expiring first (default false)
]]

local res = require('resources')
local M   = {}

-------------------------------------------------------------------------------
-- Built-in filters — always available for selection alongside user filters.
-- Same structure as user filters, with optional exclude predicates:
--   spell_exclude(spell_id, spell)   -> true to hide that spell recast row
--   ability_exclude(recast_id, name) -> true to hide that ability recast row
--   buff_exclude(buff_id, name)      -> true to hide that buff row
-- Built-in filter names are reserved; they cannot be created, modified, or
-- deleted by the user via commands.
-------------------------------------------------------------------------------
M.builtin_filters = {
    ['trust magic'] = {
        label       = 'Trust Magic',
        description = 'Hides recast timers for Trust (Alter Ego) summoning spells.',
        categories  = {},
        sort        = '',
        whitelist   = {},
        spell_exclude = function(spell_id, spell)
            -- Trust spells have type == 'Trust' in Windower resources.
            -- Unity Concord trusts share the same type field so are covered.
            return spell ~= nil and spell.type == 'Trust'
        end,
    },
}

-------------------------------------------------------------------------------
-- Mutable state — written by event handlers in Timers2.lua
-------------------------------------------------------------------------------
M.self_buff_timers     = {}   -- [buff_id]   = {name, expires, duration, created_order}
M.party_buff_timers    = {}   -- [key]       = {name, expires, duration, ..., created_order}
M.custom_timers        = {}   -- [name]      = {expires, duration, created_order}
M.spell_recast_peak    = {}   -- [spell_id]  = seconds at first observation
M.ability_recast_peak  = {}   -- [recast_id] = seconds at first observation
M.spell_recast_order   = {}   -- [spell_id]  = created_order number
M.ability_recast_order = {}   -- [recast_id] = created_order number
M.next_order           = 1
M.main_job_id          = nil

-------------------------------------------------------------------------------
-- Static lookups
-------------------------------------------------------------------------------
local ability_recasts_res = res.ability_recasts

M.spell_name_by_status = {}
-- sp_name_by_job[job_id]  = name of that job's recast_id=0  SP ability (1-hour)
-- sp2_name_by_job[job_id] = name of that job's recast_id=254 SP ability (1-hour II)
local sp_name_by_job  = {}
local sp2_name_by_job = {}
do
    local winning_id = {}
    for id, spell in pairs(res.spells) do
        if spell.status then
            local eid = winning_id[spell.status]
            if not eid or id < eid then
                M.spell_name_by_status[spell.status] = spell.en or spell.name
                winning_id[spell.status] = id
            end
        end
    end
    for id, ability in pairs(res.job_abilities) do
        if ability.status and not M.spell_name_by_status[ability.status] then
            M.spell_name_by_status[ability.status] = ability.en or ability.name
        end
    end
    -- res.job_abilities does not expose a recast_id field, so we use the known
    -- index formulas: SP Ability (recast 0) lives at 15+job_id, SP Ability II
    -- (recast 254) lives at 322+job_id. Loop covers all 22 current FFXI jobs.
    for job_id = 1, 22 do
        local sp1 = res.job_abilities[15 + job_id]
        if sp1 then sp_name_by_job[job_id] = sp1.en or sp1.name end
        local sp2 = res.job_abilities[322 + job_id]
        if sp2 then sp2_name_by_job[job_id] = sp2.en or sp2.name end
    end
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
local FFXI_EPOCH = 1009810800          -- Unix timestamp of FFXI's internal clock epoch (~Jan 2002)
local WRAP_SECS  = 0x100000000 / 60   -- Seconds per uint32 overflow cycle (~2.27 years)

function M.buff_remaining(ts)
    if ts == 0 then return nil end
    -- Determine how many full wrap cycles have elapsed since the FFXI epoch.
    local base_wraps = math.floor((os.time() - FFXI_EPOCH) / WRAP_SECS)
    -- Reconstruct the Unix expiry time for this cycle. If it's already in the
    -- past the buff's expiry has crossed into the next cycle, so advance by one.
    local expiry = FFXI_EPOCH + base_wraps * WRAP_SECS + ts / 60
    if expiry < os.time() then
        expiry = expiry + WRAP_SECS
    end
    return math.max(0, math.floor(expiry - os.time()))
end

local function append(dst, src)
    for _, v in ipairs(src) do table.insert(dst, v) end
end

local function apply_limit(rows, limit)
    if limit and limit > 0 then
        for i = #rows, limit + 1, -1 do rows[i] = nil end
    end
end

-------------------------------------------------------------------------------
-- collect(settings) -> { left, right, custom }
-------------------------------------------------------------------------------
function M.collect(settings)
    local now        = os.clock()
    local flt        = settings.filters[settings.active_filter]
                    or M.builtin_filters[settings.active_filter]
    local group_type = settings.group_type or 'start'
    local sort_key   = (flt and flt.sort ~= '' and flt.sort) or settings.sort_mode or 'duration'

    -- Returns the display name for a recast group.
    -- recast_id=0 and 254 are shared SP ability slots; the per-job name is resolved
    -- from sp_name_by_job / sp2_name_by_job built at startup from res.job_abilities.
    local function get_ability_name(recast_id)
        if recast_id == 0 and M.main_job_id then
            return sp_name_by_job[M.main_job_id]
        end
        if recast_id == 254 and M.main_job_id then
            return sp2_name_by_job[M.main_job_id]
        end
        if ability_recasts_res then
            local ar = ability_recasts_res[recast_id]
            if ar then return ar.en end
        end
        return nil
    end

    local recast_asc = settings.recast_low_to_high ~= false  -- default true
    local buff_asc   = settings.buff_low_to_high   == true   -- default false
    local custom_asc = settings.custom_low_to_high == true   -- default false

    local function cat_ok(cat)
        if not flt or not flt.categories or not next(flt.categories) then return true end
        return flt.categories[cat] == true
    end

    local function wl_ok(name)
        if flt and flt.whitelist and next(flt.whitelist) then
            return flt.whitelist[name:lower()] ~= nil
        end
        return true
    end

    -- NOTE: `asc and (a < b) or (a > b)` is a broken ternary here — when asc is
    -- true and (a < b) is false, Lua falls through to the `or` side regardless,
    -- so the comparator returns true for both (a,b) and (b,a) on unequal pairs.
    -- That violates table.sort's ordering contract and corrupts its internal
    -- indexing, which is what the "attempt to index local 'b' (a nil value)"
    -- crash actually is. Plain if/else avoids the trap.
    local function apply_sort_dir(rows, asc)
        if sort_key == 'name' then
            table.sort(rows, function(a, b)
                if asc then return a.name < b.name else return a.name > b.name end
            end)
        elseif sort_key == 'creation' then
            table.sort(rows, function(a, b)
                local ao = a.created_order or 0
                local bo = b.created_order or 0
                if asc then return ao < bo else return ao > bo end
            end)
        elseif sort_key == 'player' then
            table.sort(rows, function(a, b)
                local an = a.target_name or ''
                local bn = b.target_name or ''
                if an ~= bn then return an < bn end
                if asc then return a.remaining < b.remaining else return a.remaining > b.remaining end
            end)
        else  -- 'duration'
            table.sort(rows, function(a, b)
                if asc then return a.remaining < b.remaining else return a.remaining > b.remaining end
            end)
        end
    end

    --------------------------------------------------------------------------
    -- Gather
    --------------------------------------------------------------------------

    -- Ability recasts
    local ability_rows = {}
    if settings.show_abilities and cat_ok('ability') then
        local recasts = windower.ffxi.get_ability_recasts()
        if recasts then
            for recast_id, seconds in pairs(recasts) do
                if seconds > 0 then
                    local peak = M.ability_recast_peak[recast_id]
                    if not peak then
                        peak = seconds
                        M.ability_recast_peak[recast_id]  = peak
                        M.ability_recast_order[recast_id] = M.next_order
                        M.next_order = M.next_order + 1
                    end
                    local aname = get_ability_name(recast_id)
                    if aname then
                        local show = wl_ok(aname)
                            and not (flt and flt.ability_exclude and flt.ability_exclude(recast_id, aname))
                        if next(settings.ability_whitelist) then
                            show = show and settings.ability_whitelist[aname:lower()] ~= nil
                        end
                        if show then
                            table.insert(ability_rows, {
                                cat='ability',
                                name=aname,
                                recast_id=recast_id,
                                remaining=seconds, total=peak,
                                created_order=M.ability_recast_order[recast_id] or 0,
                            })
                        end
                    end
                else
                    M.ability_recast_peak[recast_id]  = nil
                    M.ability_recast_order[recast_id] = nil
                end
            end
        end
    end

    -- Spell recasts
    local spell_rows = {}
    if settings.show_spells and cat_ok('spell') then
        local recasts = windower.ffxi.get_spell_recasts()
        if recasts then
            for spell_id, cs in pairs(recasts) do
                local seconds = cs / 60
                if seconds > 0 then
                    local peak = M.spell_recast_peak[spell_id]
                    if not peak then
                        peak = seconds
                        M.spell_recast_peak[spell_id]  = peak
                        M.spell_recast_order[spell_id] = M.next_order
                        M.next_order = M.next_order + 1
                    end
                    local spell = res.spells[spell_id]
                    if spell and spell.name then
                        local show = wl_ok(spell.name)
                            and not (flt and flt.spell_exclude and flt.spell_exclude(spell_id, spell))
                        if next(settings.spell_whitelist) then
                            show = show and settings.spell_whitelist[spell.name:lower()] ~= nil
                        end
                        if show then
                            table.insert(spell_rows, {
                                cat='spell',
                                name=spell.english_short or spell.name,
                                spell_id=spell_id,
                                remaining=seconds, total=peak,
                                created_order=M.spell_recast_order[spell_id] or 0,
                            })
                        end
                    end
                else
                    M.spell_recast_peak[spell_id]  = nil
                    M.spell_recast_order[spell_id] = nil
                end
            end
        end
    end

    -- Self buffs
    local self_buff_rows = {}
    if settings.show_buffs and cat_ok('buff') then
        for buff_id, entry in pairs(M.self_buff_timers) do
            local remaining = entry.expires - now
            if remaining > 0 then
                if entry.name
                   and not settings.buff_blacklist[entry.name:lower()]
                   and wl_ok(entry.name)
                   and not (flt and flt.buff_exclude and flt.buff_exclude(buff_id, entry.name)) then
                    table.insert(self_buff_rows, {
                        cat='buff', name=entry.name,
                        buff_id=buff_id,
                        remaining=remaining, total=entry.duration,
                        created_order=entry.created_order or 0,
                    })
                end
            else
                M.self_buff_timers[buff_id] = nil
            end
        end
    end

    -- Party buffs — AOE into aoe_rows, single-target into by_player
    local by_player    = {}
    local player_order = {}
    local aoe_rows     = {}
    if settings.show_buffs and cat_ok('buff') then
        for key, entry in pairs(M.party_buff_timers) do
            local remaining = entry.expires - now
            if remaining > 0 then
                if entry.name
                   and not settings.buff_blacklist[entry.name:lower()]
                   and wl_ok(entry.name)
                   and not (flt and flt.buff_exclude and flt.buff_exclude(entry.status_id, entry.name)) then
                    if entry.is_aoe then
                        table.insert(aoe_rows, {
                            cat='buff', name=entry.name,
                            buff_id=entry.status_id,
                            remaining=remaining, total=entry.duration,
                            target_name='AOE',
                            created_order=entry.created_order or 0,
                        })
                    else
                        if not entry.target_name and entry.target_id then
                            local mob = windower.ffxi.get_mob_by_id(entry.target_id)
                            if mob and mob.name then entry.target_name = mob.name end
                        end
                        local pname = entry.target_name or 'Unknown'
                        if not by_player[pname] then
                            by_player[pname] = {}
                            table.insert(player_order, pname)
                        end
                        table.insert(by_player[pname], {
                            cat='buff', name=entry.name,
                            buff_id=entry.status_id,
                            remaining=remaining, total=entry.duration,
                            target_name=entry.target_name,
                            created_order=entry.created_order or 0,
                        })
                    end
                end
            else
                M.party_buff_timers[key] = nil
            end
        end
        table.sort(player_order)
    end

    -- Custom timers
    local custom_rows = {}
    if cat_ok('custom') then
        for name, entry in pairs(M.custom_timers) do
            local remaining = entry.expires - now
            if remaining > 0 then
                table.insert(custom_rows, {
                    cat='custom', name=name,
                    remaining=remaining, total=entry.duration,
                    created_order=entry.created_order or 0,
                })
            else
                M.custom_timers[name] = nil
            end
        end
    end

    --------------------------------------------------------------------------
    -- Sort and limit (per-bucket direction, then truncate)
    --------------------------------------------------------------------------
    local recast_limit = settings.recast_limit or 0
    local buff_limit   = settings.buff_limit   or 0
    local custom_limit = settings.custom_limit or 0

    local recast_rows = {}
    append(recast_rows, ability_rows)
    append(recast_rows, spell_rows)
    apply_sort_dir(recast_rows, recast_asc)
    apply_limit(recast_rows, recast_limit)

    apply_sort_dir(self_buff_rows, buff_asc)
    apply_limit(self_buff_rows, buff_limit)

    apply_sort_dir(aoe_rows, buff_asc)
    apply_limit(aoe_rows, buff_limit)

    for _, pname in ipairs(player_order) do
        apply_sort_dir(by_player[pname], buff_asc)
        apply_limit(by_player[pname], buff_limit)
    end

    apply_sort_dir(custom_rows, custom_asc)
    apply_limit(custom_rows, custom_limit)

    --------------------------------------------------------------------------
    -- Condense party buffs: when the same buff appears on N+ party members,
    -- collapse all their rows into one synthetic row showing the earliest
    -- expiry, with a `count` field for the theme to display (e.g. "Shell V [6]").
    --------------------------------------------------------------------------
    local condense_threshold = settings.condense_party_threshold or 2
    local condensed_party_rows = {}
    if condense_threshold > 0 then
        -- Tally how many player buckets carry each buff_id (one count per pname, not per row).
        -- Counting per-row instead would inflate the count when multiple players share the
        -- same pname bucket (e.g. all resolve to 'Unknown'), triggering premature condensation.
        local buff_tally = {}  -- [buff_id] = {name, total, min_remaining, min_created, count}
        for _, pname in ipairs(player_order) do
            local seen = {}  -- buff_ids already counted for this pname bucket
            for _, row in ipairs(by_player[pname] or {}) do
                local bid = row.buff_id
                if bid ~= nil then
                    if not buff_tally[bid] then
                        buff_tally[bid] = {
                            name=row.name, total=row.total,
                            min_remaining=row.remaining,
                            min_created=row.created_order,
                            count=0,
                        }
                    end
                    local t = buff_tally[bid]
                    if not seen[bid] then
                        seen[bid] = true
                        t.count = t.count + 1
                    end
                    if row.remaining < t.min_remaining then t.min_remaining = row.remaining end
                    if row.created_order < t.min_created then t.min_created = row.created_order end
                end
            end
        end

        -- For each buff that meets the threshold, build a condensed row.
        -- Track condensed buff_ids so the assembly can skip those rows in player sections.
        local condensed_ids = {}
        for bid, tally in pairs(buff_tally) do
            if tally.count >= condense_threshold then
                condensed_ids[bid] = true
                table.insert(condensed_party_rows, {
                    cat='buff', name=tally.name,
                    buff_id=bid,
                    remaining=tally.min_remaining, total=tally.total,
                    count=tally.count,
                    target_name='Party',
                    created_order=tally.min_created,
                })
            end
        end

        apply_sort_dir(condensed_party_rows, buff_asc)

        -- Filter player sections: build per-player row lists excluding condensed buff_ids.
        -- Replaces by_player entries in-scope so the assembly below needs no changes.
        for _, pname in ipairs(player_order) do
            local filtered = {}
            for _, row in ipairs(by_player[pname]) do
                if not condensed_ids[row.buff_id] then
                    table.insert(filtered, row)
                end
            end
            by_player[pname] = filtered
        end
    end

    --------------------------------------------------------------------------
    -- Assemble sections
    --------------------------------------------------------------------------
    local left_sections   = {}
    local right_sections  = {}
    local custom_sections = {}

    -- Left: merged recasts, always headerless
    if #recast_rows > 0 then
        table.insert(left_sections, {title=nil, rows=recast_rows})
    end

    -- Custom: separate position
    if #custom_rows > 0 then
        table.insert(custom_sections, {title='CUSTOM', rows=custom_rows})
    end

    -- Right: buff timers
    if group_type == 'none' then
        local all = {}
        append(all, self_buff_rows)
        for _, row in ipairs(aoe_rows) do
            row.party_name = 'AOE'
            table.insert(all, row)
        end
        for _, row in ipairs(condensed_party_rows) do
            table.insert(all, row)
        end
        for _, pname in ipairs(player_order) do
            local prows = by_player[pname]
            if prows and #prows > 0 then
                for _, row in ipairs(prows) do
                    row.party_name = pname
                    table.insert(all, row)
                end
            end
        end
        apply_sort_dir(all, buff_asc)
        if #all > 0 then
            table.insert(right_sections, {title=nil, rows=all})
        end

    elseif group_type == 'character' then
        if #self_buff_rows > 0 then
            table.insert(right_sections, {title='SELF', rows=self_buff_rows})
        end
        if #aoe_rows > 0 then
            table.insert(right_sections, {title='AOE', rows=aoe_rows})
        end
        if #condensed_party_rows > 0 then
            table.insert(right_sections, {title='PARTY', rows=condensed_party_rows})
        end
        for _, pname in ipairs(player_order) do
            local prows = by_player[pname]
            if prows and #prows > 0 then
                table.insert(right_sections, {title=pname, rows=prows})
            end
        end

    else  -- 'start'
        if #self_buff_rows > 0 then
            table.insert(right_sections, {title='BUFFS - SELF', rows=self_buff_rows})
        end
        if #aoe_rows > 0 then
            table.insert(right_sections, {title='BUFFS - AOE', rows=aoe_rows})
        end
        if #condensed_party_rows > 0 then
            table.insert(right_sections, {title='BUFFS - PARTY', rows=condensed_party_rows})
        end
        for _, pname in ipairs(player_order) do
            local prows = by_player[pname]
            if prows and #prows > 0 then
                table.insert(right_sections, {title=pname, rows=prows})
            end
        end
    end

    return {left=left_sections, right=right_sections, custom=custom_sections}
end

return M
