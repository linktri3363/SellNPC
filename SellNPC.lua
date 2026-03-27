_addon.name = 'SellNPCAuto'
_addon.command = 'SellNPC'
_addon.version = '2.1.1'
_addon.author = 'Ivaar, modified by Linktri'

require 'lists'
require 'tables'
require 'strings'
config = require('config')
files = require('files')
packets = require('packets')
res_items = require('resources').items

sales_que = L{}
auto_sell_enabled = false
auto_sell_items = T{}
monitoring = false
actions = false  -- FIX #1: explicitly initialize actions as a global

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

-- Save settings to file
local function save_settings()
    settings:save()
    print('SellNPC: Settings saved.')
end

-- Build lookup table of item IDs for auto-sell
local function build_auto_sell_list()
    auto_sell_items = T{}
    local invalid_items = T{}

    for _, item_name in ipairs(settings.items) do
        local found = false
        for k, v in pairs(res_items) do
            if v.en:lower() == item_name:lower() or v.enl:lower() == item_name:lower() then
                found = true
                if not v.flags['No NPC Sale'] then
                    auto_sell_items[k] = v.en
                else
                    print('SellNPC: %s cannot be sold to NPCs, skipping.':format(v.en))
                end
                break
            end
        end
        if not found then
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

    local item_res = nil
    for k, v in pairs(res_items) do
        if v.en:lower() == item_name:lower() or v.enl:lower() == item_name:lower() then
            item_res = v
            break
        end
    end

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

    for i, existing in ipairs(settings.items) do
        if existing:lower() == item_name:lower() then
            local removed = table.remove(settings.items, i)
            save_settings()
            build_auto_sell_list()
            print('SellNPC: Removed "%s" from auto-sell list.':format(removed))
            return
        end
    end

    for k, v in pairs(res_items) do
        if v.en:lower() == item_name:lower() or v.enl:lower() == item_name:lower() then
            for i, existing in ipairs(settings.items) do
                if existing:lower() == v.en:lower() then
                    local removed = table.remove(settings.items, i)
                    save_settings()
                    build_auto_sell_list()
                    print('SellNPC: Removed "%s" from auto-sell list.':format(removed))
                    return
                end
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

function get_item_res(item)
    for k,v in pairs(res_items) do
        if v.en:lower() == item:lower() or v.enl:lower() == item:lower() then
            return v
        end
    end
    return nil
end

function find_item(item_id)
    local items = windower.ffxi.get_items(0)
    for ind,item in ipairs(items) do
        if item and item.id == item_id and item.status == 0 then
            return ind,item.count
        end
    end
    return false
end

-- Find any auto-sell item in inventory
function find_auto_sell_item()
    local items = windower.ffxi.get_items(0)
    for ind, item in ipairs(items) do
        if item and item.id and auto_sell_items[item.id] and item.status == 0 then
            return item.id, ind, item.count
        end
    end
    return nil
end

-- FIX #2 & #3: check_que now takes an explicit optional item param and uses
-- coroutine.schedule instead of recursive sleep to avoid stack buildup
function check_que(item)
    if item then
        local ind = sales_que:find(item)
        if ind then
            table.remove(sales_que, ind)
        end
    end

    if sales_que[1] then
        return sell_npc_item(sales_que[1])
    elseif auto_sell_enabled and monitoring then
        local item_id = find_auto_sell_item()
        if item_id then
            return sell_npc_item(item_id)
        else
            -- FIX #3: schedule next check instead of recursing with a sleep
            coroutine.schedule(check_que, 0.5)
        end
    else
        print('SellNPC: Selling Finished')
        actions = false
    end
end

function check_item(name)
    name = windower.convert_auto_trans(name)
    local item = get_item_res(name)
    if not item then
        actions = false
        print('SellNPC Error: %s not a valid item name.':format(name))
        return check_que()
    end
    if item.flags['No NPC Sale'] == true then
        actions = false
        print('SellNPC Error: Cannot sell %s to npc vendors':format(item.en))
        return check_que(item.id)
    end
    table.insert(sales_que, item.id)
    if not actions then
        actions = true
        return sell_npc_item(item.id)
    end
end

-- FIX #5: sell_npc_item now has a max retry limit to prevent infinite recursion
local SELL_MAX_RETRIES = 20

function sell_npc_item(item, retries)
    retries = retries or 0

    if not appraised then
        actions = false
        return
    end

    -- FIX #5: bail out if we've retried too many times
    if retries >= SELL_MAX_RETRIES then
        print('SellNPC: Gave up trying to sell %s after %d attempts.':format(
            res_items[item] and res_items[item].en or tostring(item), SELL_MAX_RETRIES))
        actions = false
        return check_que(item)
    end

    local index, count = find_item(item)
    if not index then
        actions = false
        if not appraised[item] then
            print('SellNPC Error: %s not found in inventory.':format(res_items[item].en))
        end
        return check_que(item)
    end

    if not appraised[item] then count = 1 end
    windower.packets.inject_outgoing(0x084, string.char(0x084, 0x06, 0, 0, (count % 256), 0, 0, 0, (item % 256), (math.floor((item / 256) % 256)), (index % 256), 0))

    if not appraised[item] then
        appraised[item] = true
        coroutine.sleep((1 + math.random()))
        return sell_npc_item(item, retries + 1)
    end

    windower.packets.inject_outgoing(0x085, string.char(0x085, 0x04, 0, 0, 0x01, 0, 0, 0))
    coroutine.sleep((1 + math.random()))
    return sell_npc_item(item, retries + 1)
end

-- FIX #4: guard against double-starting auto-sell
function start_auto_sell()
    if not appraised then
        print('SellNPC: You must have an NPC shop window open to use auto-sell.')
        return
    end

    -- FIX #4: prevent duplicate monitoring loops
    if auto_sell_enabled and monitoring then
        print('SellNPC: Auto-sell is already running.')
        return
    end

    if auto_sell_items:length() == 0 then
        build_auto_sell_list()
    end

    auto_sell_enabled = true
    monitoring = true
    print('SellNPC: Auto-sell ENABLED. Will sell items as they appear.')
    print('SellNPC: Use "//sellnpc stop" to disable.')

    local item_id = find_auto_sell_item()
    if item_id then
        actions = true
        sell_npc_item(item_id)
    else
        check_que()
    end
end

function stop_auto_sell()
    auto_sell_enabled = false
    monitoring = false
    actions = false  -- FIX #1/#7: ensure actions is cleared on stop
    print('SellNPC: Auto-sell DISABLED.')
end

function show_status()
    print('SellNPC: Auto-sell is %s':format(auto_sell_enabled and 'ENABLED' or 'DISABLED'))
    print('SellNPC: Shop window %s':format(appraised and 'OPEN' or 'CLOSED'))
    if auto_sell_items:length() > 0 then
        print('SellNPC: Tracking %d item types for auto-sell.':format(auto_sell_items:length()))
    end
end

function show_help()
    print('SellNPC Commands:')
    print('  //sellnpc auto          - Start auto-selling items in list')
    print('  //sellnpc stop          - Stop auto-selling')
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
        check_que()
    end
end

windower.register_event('addon command', cmd)

-- FIX #7: reset now also clears actions to prevent stale state
function reset()
    appraised = nil
    monitoring = false
    actions = false
    if auto_sell_enabled then
        print('SellNPC: Shop closed, auto-sell paused. Re-open shop and use "//sellnpc auto" to resume.')
    end
end

windower.register_event('zone change', 'logout', reset)

windower.register_event('incoming chunk', function(id, original, modified, injected, blocked)
    -- 0x0AA: NPC sell window appraisal packet -- server sends this when the
    -- sell menu is actually opened, not just when the NPC is in range
    if id == 0x0AA then
        appraised = {}
        if auto_sell_enabled and not monitoring then
            print('SellNPC: Sell window detected, resuming auto-sell...')
            monitoring = true
            coroutine.schedule(start_auto_sell, 0.5)
        end
    -- 0x034: menu close packet -- sell window has been closed
    elseif id == 0x034 then
        if appraised then
            reset()
        end
    end
end)

windower.register_event('load', function()
    settings = config.load(defaults)

    if settings.items then
        local items_list = T{}

        -- The Windower config library saves sequential tables with numeric string
        -- keys ("1", "2", "3"...) in XML. Collect and sort them to preserve order.
        local numeric_keys = T{}
        for k, v in pairs(settings.items) do
            local n = tonumber(k)
            if n then
                table.insert(numeric_keys, n)
            end
        end

        if #numeric_keys > 0 then
            table.sort(numeric_keys)
            for _, n in ipairs(numeric_keys) do
                local v = settings.items[tostring(n)]
                -- config lib may wrap values in a table; unwrap if needed
                if type(v) == 'table' and v[1] then
                    v = v[1]
                end
                if type(v) == 'string' and v ~= '' then
                    table.insert(items_list, v)
                end
            end
        end

        -- Last resort: try plain ipairs/pairs for raw string values
        if #items_list == 0 then
            for i, v in ipairs(settings.items) do
                if type(v) == 'string' then table.insert(items_list, v) end
            end
        end
        if #items_list == 0 then
            for k, v in pairs(settings.items) do
                if type(v) == 'string' then table.insert(items_list, v) end
            end
        end

        if #items_list > 0 then
            settings.items = items_list
        else
            settings.items = T(default_items:copy())
        end
    else
        settings.items = T(default_items:copy())
    end

    build_auto_sell_list()
end)
