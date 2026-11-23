_addon.name = 'SellNPC'
_addon.command = 'SellNPC'
_addon.version = '2.1.2'
_addon.author = 'Ivaar, modified by Linktri'

require 'tables'
require 'strings'
config = require('config')
res_items = require('resources').items

-- Selling state
sales_que = {}             -- manual queue of item IDs (plain array)
auto_sell_enabled = false  -- user has turned auto-sell on
auto_sell_items = T{}      -- [item_id] = name, built from settings.items
monitoring = false         -- auto-sell is actively watching inventory
actions = false            -- a sell worker is running (only ever one)
appraised = nil            -- nil = no shop open; {} = shop open, [item_id] = price-checked
skipped = {}               -- [item_id] = true for items the NPC refused this shop visit

local worker_gen = 0       -- bumped to retire any running worker
local SELL_DELAY_MIN = 1   -- seconds between sell packets (plus up to 1s random)
local AUTO_POLL = 0.5      -- seconds between inventory scans when idle in auto mode
local SELL_MAX_FAILS = 5   -- consecutive sale attempts that change nothing before giving up on an item
local CLOSED_POLLS = 3     -- consecutive "no menu open" checks before treating the shop as closed

-- Default items (Gr. Velkk Coffer contents)
local default_items = T{
    'Acheron Shield',
    'Beehive Chip',
    'Bird Egg',
    'Chapuli Wing',
    'Chapuli Horn',
    'Colibri Beak',
    'Colibri Feathers',
    'Crab Shell',
    'Craklaw Pincer',
    'Flytrap Leaf',
    'Giant Stinger',
    'Hare Meat',
    'High-Quality Crab Shell',
    'Honey',
    'Matamata Shell',
    'Land Crab Meat',
    'Prize Powder',
    'Raaz Hide',
    'Raaz Tusk',
    'Rabbit Hide',
    'Raptor Skin',
    'Snap. Secretion',
    'Snap. Tendril',
    'Tulfaire Feather',
    'Velkk Mask',
    'Velkk Necklace',
    'Voay Sword -1',
    'Voay Staff -1',
}

-- Settings defaults
local defaults = {
    items = default_items
}

-- Settings will be loaded here
local settings

---------------------------------------------------------------------------
-- Item name lookup (built once instead of scanning all resources per name)
---------------------------------------------------------------------------
local name_index

local function build_name_index()
    name_index = {}
    for id, v in pairs(res_items) do
        for _, name in ipairs({v.en, v.enl}) do
            if name and name ~= '' then
                local key = name:lower()
                local existing = name_index[key]
                -- On duplicate names prefer an NPC-sellable entry, then the lower ID
                if not existing
                    or (existing.flags['No NPC Sale'] and not v.flags['No NPC Sale'])
                    or (existing.flags['No NPC Sale'] == v.flags['No NPC Sale'] and id < existing.id) then
                    name_index[key] = v
                end
            end
        end
    end
end

function get_item_res(item)
    if not name_index then build_name_index() end
    return name_index[item:lower()]
end

-- Parse items directly from settings.xml, preferring the character-specific
-- block over global. Bypasses config lib's broken character detection.
local function load_items_from_xml()
    local player = windower.ffxi.get_player()
    local char_name = player and player.name or nil

    local xml_path = windower.addon_path .. 'data/settings.xml'
    local f = io.open(xml_path, 'r')
    if not f then
        return nil
    end

    local content = f:read('*all')
    f:close()

    -- Try character block first, fall back to global
    local blocks_to_try = {}
    if char_name then
        table.insert(blocks_to_try, char_name)
    end
    table.insert(blocks_to_try, 'global')

    for _, block_name in ipairs(blocks_to_try) do
        local block = content:match('<' .. block_name .. '>(.-)</' .. block_name .. '>')
        if block then
            local items_block = block:match('<items>(.-)</items>')
            if items_block then
                local items_list = T{}
                for item_val in items_block:gmatch('<[^>]+>([^<]+)<[^>]+>') do
                    local trimmed = item_val:match('^%s*(.-)%s*$')
                    -- Decode XML entities
                    trimmed = trimmed:gsub('&apos;', "'"):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&')
                    if trimmed ~= '' then
                        table.insert(items_list, trimmed)
                    end
                end
                if #items_list > 0 then
                    print('SellNPC: Loaded %d items from <%s> block.':format(#items_list, block_name))
                    return items_list
                end
            end
        end
    end

    return nil
end

local function save_items_to_xml(items_list)
    local player = windower.ffxi.get_player()
    local char_name = player and player.name or 'global'

    local xml_path = windower.addon_path .. 'data/settings.xml'
    local f = io.open(xml_path, 'r')
    local content = f and f:read('*all') or '<?xml version="1.1" ?>\n<settings>\n</settings>'
    if f then f:close() end

    -- Build new items block
    local items_xml = '        <items>\n'
    for i, name in ipairs(items_list) do
        local encoded = name:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub("'", '&apos;')
        items_xml = items_xml .. ('            <%d>%s</%d>\n'):format(i, encoded, i)
    end
    items_xml = items_xml .. '        </items>'

    -- Replace or insert character block
    local repl = items_xml:gsub('%%', '%%%%')
    if content:find('<' .. char_name .. '>') then
        -- Replace existing items block inside character block (or add one)
        local n
        content, n = content:gsub(
            '(<' .. char_name .. '>.-)<items>.-</items>(.-</' .. char_name .. '>)',
            '%1' .. repl .. '%2', 1
        )
        if n == 0 then
            content = content:gsub('<' .. char_name .. '>', '<' .. char_name .. '>\n' .. repl, 1)
        end
    else
        -- Insert new character block before </settings>
        local char_block = '    <' .. char_name .. '>\n' .. items_xml .. '\n    </' .. char_name .. '>\n'
        content = content:gsub('</settings>', (char_block:gsub('%%', '%%%%')) .. '</settings>', 1)
    end

    local f_out = io.open(xml_path, 'w')
    if f_out then
        f_out:write(content)
        f_out:close()
    end
end

-- Save settings to file
local function save_settings()
    save_items_to_xml(settings.items)
    print('SellNPC: Settings saved.')
end

-- Build lookup table of item IDs for auto-sell
local function build_auto_sell_list()
    auto_sell_items = T{}
    local invalid_items = T{}

    for _, item_name in ipairs(settings.items) do
        local v = get_item_res(item_name)
        if v then
            if not v.flags['No NPC Sale'] then
                auto_sell_items[v.id] = v.en
            else
                print('SellNPC: %s cannot be sold to NPCs, skipping.':format(v.en))
            end
        else
            table.insert(invalid_items, item_name)
        end
    end

    if #invalid_items > 0 then
        print('SellNPC: Warning - %d item(s) not found in resources:':format(#invalid_items))
        for _, name in ipairs(invalid_items) do
            print(' - ' .. name)
        end
    end

    print('SellNPC: Auto-sell list built with %d items.':format(auto_sell_items:length()))
end

-- Add item to the auto-sell list
local function add_item(item_name)
    item_name = windower.convert_auto_trans(item_name)

    local item_res = get_item_res(item_name)
    if not item_res then
        print('SellNPC Error: "%s" is not a valid item name.':format(item_name))
        return
    end

    for _, existing in ipairs(settings.items) do
        if existing:lower() == item_res.en:lower() then
            print('SellNPC: %s is already in the auto-sell list.':format(item_res.en))
            return
        end
    end

    if item_res.flags['No NPC Sale'] then
        print('SellNPC Error: %s cannot be sold to NPCs.':format(item_res.en))
        return
    end

    table.insert(settings.items, item_res.en)
    save_settings()
    build_auto_sell_list()
    print('SellNPC: Added "%s" to auto-sell list.':format(item_res.en))
end

-- Remove item from the auto-sell list
local function remove_item(item_name)
    item_name = windower.convert_auto_trans(item_name)

    -- Match the saved name directly, or the resource's short name if a long name was typed
    local targets = {item_name:lower()}
    local v = get_item_res(item_name)
    if v then table.insert(targets, v.en:lower()) end

    for _, target in ipairs(targets) do
        for i, existing in ipairs(settings.items) do
            if existing:lower() == target then
                local removed = table.remove(settings.items, i)
                save_settings()
                build_auto_sell_list()
                print('SellNPC: Removed "%s" from auto-sell list.':format(removed))
                return
            end
        end
    end

    print('SellNPC Error: "%s" not found in auto-sell list.':format(item_name))
end

-- Clear all items from the list
local function clear_list()
    settings.items = T{}
    save_settings()
    build_auto_sell_list()
    print('SellNPC: Auto-sell list cleared.')
end

-- Reset to default items
local function reset_list()
    settings.items = T(default_items:copy())
    save_settings()
    build_auto_sell_list()
    print('SellNPC: Auto-sell list reset to defaults.')
end

---------------------------------------------------------------------------
-- Inventory helpers
---------------------------------------------------------------------------
function find_item(item_id)
    local items = windower.ffxi.get_items(0)
    for ind, item in ipairs(items) do
        if item and item.id == item_id and item.status == 0 then
            return ind, item.count
        end
    end
    return nil
end

-- Find any auto-sell item in inventory
function find_auto_sell_item()
    local items = windower.ffxi.get_items(0)
    for ind, item in ipairs(items) do
        if item and item.id and auto_sell_items[item.id] and not skipped[item.id] and item.status == 0 then
            return item.id, ind, item.count
        end
    end
    return nil
end

local function item_name(id)
    return res_items[id] and res_items[id].en or tostring(id)
end

local function remove_from_que(item_id)
    for i = #sales_que, 1, -1 do
        if sales_que[i] == item_id then
            table.remove(sales_que, i)
        end
    end
end

---------------------------------------------------------------------------
-- Shop state
---------------------------------------------------------------------------
-- The server tells us when a shop opens (0x03C) but not when it closes, so
-- while selling we also watch the client's menu flag.
local function menu_closed()
    local info = windower.ffxi.get_info()
    return info and info.menu_open == false
end

function reset(silent)
    worker_gen = worker_gen + 1  -- retire any running worker
    appraised = nil
    monitoring = false
    actions = false
    skipped = {}
    if auto_sell_enabled and not silent then
        print('SellNPC: Shop closed, auto-sell paused. It will resume when you open a shop.')
    end
end

---------------------------------------------------------------------------
-- Selling engine: one worker coroutine processes the manual queue first,
-- then (in auto mode) keeps scanning inventory until the shop closes.
---------------------------------------------------------------------------
local function wait(gen, seconds)
    coroutine.sleep(seconds)
    return gen == worker_gen and appraised ~= nil
end

-- Sells one stack. Returns true if the stack disappeared or shrank.
local function sell_stack(gen, item_id, index, count)
    if not appraised[item_id] then
        -- First sale of this item at this shop: price check with a single unit
        windower.packets.inject_outgoing(0x084, string.char(0x084, 0x06, 0, 0, 1, 0, 0, 0,
            item_id % 256, math.floor(item_id / 256) % 256, index % 256, 0))
        appraised[item_id] = true
        if not wait(gen, SELL_DELAY_MIN + math.random()) then return false end
        index, count = find_item(item_id)
        if not index then return true end
    end

    windower.packets.inject_outgoing(0x084, string.char(0x084, 0x06, 0, 0, count % 256, 0, 0, 0,
        item_id % 256, math.floor(item_id / 256) % 256, index % 256, 0))
    windower.packets.inject_outgoing(0x085, string.char(0x085, 0x04, 0, 0, 0x01, 0, 0, 0))
    if not wait(gen, SELL_DELAY_MIN + math.random()) then return false end

    local new_index, new_count = find_item(item_id)
    return not (new_index == index and new_count == count)
end

local function worker(gen)
    local fails = {}        -- [item_id] = consecutive attempts with no effect
    local closed_polls = 0

    while gen == worker_gen and appraised do
        if menu_closed() then
            closed_polls = closed_polls + 1
            if closed_polls >= CLOSED_POLLS then
                reset()
                return
            end
            coroutine.sleep(AUTO_POLL)
        else
            closed_polls = 0

            -- Pick the next item: manual queue first, then auto-sell list
            local item_id, index, count
            while sales_que[1] and not item_id do
                local id = sales_que[1]
                index, count = find_item(id)
                if index then
                    item_id = id
                else
                    table.remove(sales_que, 1)
                    if not appraised[id] then
                        print('SellNPC Error: %s not found in inventory.':format(item_name(id)))
                    end
                end
            end
            if not item_id and auto_sell_enabled and monitoring then
                item_id, index, count = find_auto_sell_item()
            end

            if item_id then
                if sell_stack(gen, item_id, index, count) then
                    fails[item_id] = 0
                else
                    if gen ~= worker_gen or not appraised then break end
                    fails[item_id] = (fails[item_id] or 0) + 1
                    if fails[item_id] >= SELL_MAX_FAILS then
                        print('SellNPC: Gave up trying to sell %s after %d attempts.':format(
                            item_name(item_id), SELL_MAX_FAILS))
                        skipped[item_id] = true
                        remove_from_que(item_id)
                    end
                end
            elseif auto_sell_enabled and monitoring then
                coroutine.sleep(AUTO_POLL)
            else
                print('SellNPC: Selling Finished')
                break
            end
        end
    end

    if gen == worker_gen then
        actions = false
    end
end

-- Start the worker if it isn't already running
local function kick()
    if actions or not appraised then return end
    actions = true
    worker_gen = worker_gen + 1
    local gen = worker_gen
    coroutine.schedule(function() worker(gen) end, 0)
end

function check_item(name)
    name = windower.convert_auto_trans(name)
    local item = get_item_res(name)
    if not item then
        print('SellNPC Error: %s not a valid item name.':format(name))
        return
    end
    if item.flags['No NPC Sale'] then
        print('SellNPC Error: Cannot sell %s to npc vendors':format(item.en))
        return
    end

    skipped[item.id] = nil  -- an explicit request gets another try
    local queued = false
    for _, id in ipairs(sales_que) do
        if id == item.id then queued = true break end
    end
    if not queued then
        table.insert(sales_que, item.id)
    end

    if appraised then
        kick()
    else
        print('SellNPC: %s queued; it will sell when you open a shop.':format(item.en))
    end
end

function start_auto_sell()
    if auto_sell_items:length() == 0 then
        build_auto_sell_list()
    end

    if auto_sell_enabled and monitoring then
        print('SellNPC: Auto-sell is already running.')
        return
    end

    auto_sell_enabled = true
    if not appraised then
        print('SellNPC: Auto-sell ENABLED. It will start when you open an NPC shop.')
        return
    end

    monitoring = true
    print('SellNPC: Auto-sell ENABLED. Will sell items as they appear.')
    print('SellNPC: Use "//sellnpc stop" to disable.')
    kick()
end

function stop_auto_sell()
    auto_sell_enabled = false
    monitoring = false
    sales_que = {}
    worker_gen = worker_gen + 1  -- stop the current worker immediately
    actions = false
    print('SellNPC: Auto-sell DISABLED. Selling stopped.')
end

function show_status()
    print('SellNPC: Auto-sell is %s':format(auto_sell_enabled and 'ENABLED' or 'DISABLED'))
    print('SellNPC: Shop window %s':format(appraised and 'OPEN' or 'CLOSED'))
    if #sales_que > 0 then
        print('SellNPC: %d item(s) in the manual sell queue.':format(#sales_que))
    end
    if auto_sell_items:length() > 0 then
        print('SellNPC: Tracking %d item types for auto-sell.':format(auto_sell_items:length()))
    end
end

function show_help()
    print('SellNPC Commands:')
    print('  //sellnpc auto          - Start auto-selling items in list')
    print('  //sellnpc stop          - Stop all selling (auto and queued)')
    print('  //sellnpc status        - Show current status')
    print('  //sellnpc list          - Show items in auto-sell list')
    print('  //sellnpc add <item>    - Add item to auto-sell list')
    print('  //sellnpc remove <item> - Remove item from auto-sell list')
    print('  //sellnpc clear         - Clear all items from list')
    print('  //sellnpc reset         - Reset list to default items')
    print('  //sellnpc <item>        - Manually sell specific item')
end

function show_list()
    print('SellNPC Auto-sell items (%d):':format(#settings.items))
    for i, name in ipairs(settings.items) do
        print('  %d. %s':format(i, name))
    end
end

function cmd(...)
    local args = {...}
    local arg1 = args[1] and args[1]:lower()

    if arg1 == 'auto' or arg1 == 'start' then
        start_auto_sell()
    elseif arg1 == 'stop' or arg1 == 'off' then
        stop_auto_sell()
    elseif arg1 == 'status' then
        show_status()
    elseif arg1 == 'list' then
        show_list()
    elseif arg1 == 'help' then
        show_help()
    elseif arg1 == 'add' then
        if args[2] then
            add_item(table.concat(args, ' ', 2))
        else
            print('SellNPC Error: Specify an item to add.')
        end
    elseif arg1 == 'remove' or arg1 == 'rem' or arg1 == 'delete' or arg1 == 'del' then
        if args[2] then
            remove_item(table.concat(args, ' ', 2))
        else
            print('SellNPC Error: Specify an item to remove.')
        end
    elseif arg1 == 'clear' then
        clear_list()
    elseif arg1 == 'reset' or arg1 == 'default' or arg1 == 'defaults' then
        reset_list()
    elseif args[1] then
        check_item(table.concat(args, ' ', 1))
    elseif appraised then
        kick()
    end
end

windower.register_event('addon command', cmd)

windower.register_event('zone change', 'logout', function() reset() end)

windower.register_event('incoming chunk', function(id, original, modified, injected, blocked)
    -- 0x03C: Shop item list -- sent when an NPC shop opens (may arrive in
    -- several pages, so only the first one starts a new shop session)
    if id == 0x03C and not appraised then
        reset(true)
        appraised = {}
        if auto_sell_enabled then
            print('SellNPC: Shop detected, resuming auto-sell...')
            monitoring = true
        end
        if monitoring or sales_que[1] then
            coroutine.schedule(kick, 0.5)
        end
    end
end)

local function load_settings()
    -- Use config lib for initialization, then override items with direct XML parse
    settings = config.load(defaults)

    local items_from_xml = load_items_from_xml()
    if items_from_xml and #items_from_xml > 0 then
        settings.items = items_from_xml
    elseif settings.items then
        local items_list = T{}
        for i, v in ipairs(settings.items) do
            if type(v) == 'string' and v ~= '' then
                table.insert(items_list, v)
            end
        end
        settings.items = #items_list > 0 and items_list or T(default_items:copy())
    else
        settings.items = T(default_items:copy())
    end

    if not name_index then build_name_index() end
    build_auto_sell_list()
end

windower.register_event('load', load_settings)
windower.register_event('login', load_settings)
