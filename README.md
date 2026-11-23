SellNPC
Version: 2.1.2
Author: Ivaar, modified by Linktri
Command: //sellnpc
A Windower addon for Final Fantasy XI that automates selling items to NPC vendors. Supports both manual single-item selling and a persistent auto-sell mode that continuously monitors your inventory and sells configured items as they appear.

Features

Auto-sell mode — Monitors inventory and automatically sells listed items whenever an NPC shop is open
Persistent item list — Your sell list is saved to a config file and persists across sessions
Pre-loaded default list — Ships with a default list of common Gr. Velkk Coffer drops
Item validation — Warns you about invalid item names and skips items flagged as non-NPC-sellable
Shop state detection — Detects when an NPC shop opens, pauses when the shop menu closes, and resumes automatically the next time you open a shop
Manual sell mode — Sell a specific item by name without touching the auto-sell list


Installation

Copy the SellNPC folder into your Windower addons directory:

   Windower/addons/SellNPC/

Load the addon in-game:

   //lua load SellNPC
Or add it to your addons.txt to load automatically on startup.

Usage
All commands use the //sellnpc prefix.
Auto-Sell Mode
CommandAliasesDescription//sellnpc autostartStart auto-selling items in your list (starts now if a shop is open, otherwise as soon as you open one)//sellnpc stopoffStop all selling (auto-sell and any queued manual sales)//sellnpc status—Show current auto-sell status and shop state
How it works:

Open an NPC shop window.
Run //sellnpc auto.
The addon sells any matching items currently in your inventory, then watches for new ones.
When you close the shop or zone, auto-sell pauses automatically.
Open any NPC shop again and auto-sell resumes on its own (until you run //sellnpc stop).

Managing the Item List
CommandDescription//sellnpc listDisplay all items currently in your auto-sell list//sellnpc add <item name>Add an item to the auto-sell list//sellnpc remove <item name>Remove an item from the auto-sell list//sellnpc clearRemove all items from the list//sellnpc resetRestore the default item list
Examples:
//sellnpc add Hare Meat
//sellnpc remove Bird Egg
//sellnpc add Rabbit Hide

Item names are case-insensitive. The addon validates names against the game's item resources and will notify you if a name is invalid or if the item cannot be sold to NPCs.

Manual Selling
You can sell a specific item by name without using auto-sell mode:
//sellnpc <item name>
Example:
//sellnpc Hare Meat
If no shop is open, the item is queued and sells as soon as you open one.
Help
//sellnpc help

Default Item List
The addon ships pre-configured with common Gr. Velkk Coffer drops:
Acheron ShieldBeehive ChipBird EggChapuli WingChapuli HornColibri BeakColibri FeathersCrab ShellCraklaw PincerFlytrap LeafGiant StingerHare MeatHigh-Quality Crab ShellHoneyLand Crab MeatMatamata ShellPrize PowderRaaz HideRaaz TuskRabbit HideRaptor SkinSnap. SecretionSnap. TendrilTulfaire FeatherVelkk MaskVelkk NecklaceVoay Sword -1Voay Staff -1
Use //sellnpc reset at any time to restore this list.

Configuration
Your item list is saved automatically to:
Windower/addons/SellNPC/data/settings.xml
Changes made via //sellnpc add / //sellnpc remove / //sellnpc clear / //sellnpc reset are written to this file immediately. You can edit it manually if needed — the addon loads the config on startup.

Notes

The addon cannot open a shop on its own; selling only happens while an NPC shop is open.
Items flagged with the No NPC Sale property (e.g. rare/ex gear) are automatically skipped with a warning.
The addon resets shop state on zone change or logout. With auto-sell enabled, it resumes the next time you open a shop.
If an NPC keeps refusing an item (5 attempts with no change), that item is skipped until you next open a shop.
Item names support auto-translation input (e.g. pressing the auto-translate button in-game for item names works as expected).


Requirements

Windower 4
Final Fantasy XI

Windower Libraries Used

tables
strings
config
resources
