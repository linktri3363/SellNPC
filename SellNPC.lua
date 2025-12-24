_addon.name = 'SellNPCAuto'
_addon.command = 'SellNPC'
_addon.version = '2.1.0'
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
            print('  - ' .. name)
        end
    end
    
    print('SellNPC: Auto-sell list built with %d items.':format(auto_sell_items:length()))
end

-- Add item to the auto-sell list
local function add_item(item_name)
    item_name = windower.convert_auto_trans(item_name)
    
    -- Validate item exists
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
    
    -- Check if already in list
    for _, existing in ipairs(settings.items) do
        if existing:lower() == item_res.en:lower() then
            print('SellNPC: %s is already in the auto-sell list.':format(item_res.en))
            return
        end
    end
    
    -- Check if sellable
    if item_res.flags['No NPC Sale'] then
        print('SellNPC Error: %s cannot be sold to NPCs.':format(item_res.en))
        return
    end
    
    -- Add to list
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
    
    -- Try matching against resource names
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

function check_que(item)
    local ind = sales_que:find(item)
    if ind then
        table.remove(sales_que, ind)
    end
    if sales_que[1] then
        return sell_npc_item(sales_que[1])
    elseif auto_sell_enabled and monitoring then
        -- Check for more auto-sell items
        local item_id, index, count = find_auto_sell_item()
        if item_id then
            return sell_npc_item(item_id)
        else
            -- No items found, keep monitoring
            coroutine.sleep(0.5)
            if auto_sell_enabled and monitoring then
                return check_que()
            end
        end
    else
        print('SellNPC: Selling Finished')
    end
end

function check_item(name)
    name = windower.convert_auto_trans(name)
    local item = get_item_res(name)
    if not item then actions=false,print('SellNPC Error: %s not a valid item name.':format(name)) return check_que() end
    if item.flags['No NPC Sale'] == true then actions=false,print('SellNPC Error: Cannot sell %s to npc vendors':format(item.en)) return check_que(item.id) end
    table.insert(sales_que, item.id)
    if not actions then actions = true return sell_npc_item(item.id) end
end

function sell_npc_item(item)
    if not appraised then actions = false return end
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
        return sell_npc_item(item) 
    end
    windower.packets.inject_outgoing(0x085, string.char(0x085, 0x04, 0, 0, 0x01, 0, 0, 0))
    coroutine.sleep((1 + math.random()))
    return sell_npc_item(item)
end

function start_auto_sell()
    if not appraised then
        print('SellNPC: You must have an NPC shop window open to use auto-sell.')
        return
    end
    
    if auto_sell_items:length() == 0 then
        build_auto_sell_list()
    end
    
    auto_sell_enabled = true
    monitoring = true
    print('SellNPC: Auto-sell ENABLED. Will sell items as they appear.')
    print('SellNPC: Use "//sellnpc stop" to disable.')
    
    -- Start the monitoring loop
    local item_id, index, count = find_auto_sell_item()
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
    actions = false
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
    local commands = T{...}
    local arg1 = commands[1] and commands[1]:lower()
    
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
    elseif arg1 == 'add' and commands[2] then
        add_item(table.concat(commands, ' ', 2))
    elseif arg1 == 'remove' or arg1 == 'rem' or arg1 == 'delete' or arg1 == 'del' then
        if commands[2] then
            remove_item(table.concat(commands, ' ', 2))
        else
            print('SellNPC Error: Specify an item to remove.')
        end
    elseif arg1 == 'clear' then
        clear_list()
    elseif arg1 == 'reset' or arg1 == 'default' or arg1 == 'defaults' then
        reset_list()
    elseif commands[1] then
        -- Original behavior - sell specific item
        check_item(table.concat(commands, ' ', 1))
    elseif appraised then
        check_que()
    end
end

windower.register_event('addon command', cmd)

function reset()
    appraised = nil
    monitoring = false
    if auto_sell_enabled then
        print('SellNPC: Shop closed, auto-sell paused. Re-open shop and use "//sellnpc auto" to resume.')
    end
end

windower.register_event('zone change', 'logout', reset)

windower.register_event('incoming chunk', function(id, original, modified, injected, blocked)
    if id == 0x03C then
        appraised = {}
        if auto_sell_enabled and not monitoring then
            print('SellNPC: Shop detected, resuming auto-sell...')
            monitoring = true
            coroutine.schedule(start_auto_sell, 0.5)
        end
    end
end)

-- Initialize on load
windower.register_event('load', function()
    settings = config.load(defaults)
    -- Ensure items is a proper table
    if not settings.items or type(settings.items) ~= 'table' then
        settings.items = T(default_items:copy())
    end
    build_auto_sell_list()
end)
