# Sharpie's Loot Tracker - Version History

## 🚀 v0.2.0

### ✨ New
- **New look**: flat dark window with your class colour as the accent, same style as Sharpie's Gear Judge. GPH is the big number, with the rest grouped into Rate, Earnings and Session. A status light shows Running, Idle or Paused.
- **New tabs**: All, Mats, Gear, Junk, Other, each with an item count. Your current session carries over.
- **AH vs vendor**: the All tab splits item value into what's priced from the auction house and what's vendor value.
- **Compact bar**: one line with state, time, GPH and bags. Use the button in the header, double-click the header, or `/slt compact`. It replaces the old show/hide list button.
- **Idle pause**: no loot for 5 minutes, or going AFK, pauses the timer as of your last loot. The next loot carries on. `/slt idle <minutes>` (0 = off).
- **Costs**: money spent at vendors (repairs, food, ammo) shows as Costs and comes off GPH. `/slt costs` to turn off.
- **Bags**: free slots and roughly how long until they're full. Alerts when they fill up.
- **Big drop alert**: sound and on-screen warning for a drop worth 5g or more. `/slt alert <gold>` (0 = off).
- **Per kill**: coin and items per kill.
- **Report**: `/slt report` posts a one-line summary to your group, or `say`, `guild`, `raid`, `instance`, `w <name>`, `self`.
- **Ignore list**: Ctrl-right-click a row to always ignore that item. `/slt ignore` lists them, `/slt unignore <item>` undoes. Quest items are ignored by default (`/slt questitems`).
- **Price age**: hovering a row shows where its price came from. Auctionator prices older than 3 days get an orange `*` (`/slt stale <days>`).

### 🐛 Fixes
- **GPH**: shows `--` for the first 2 minutes instead of a huge number from the first drop.
- **TSM prices**: default is now `min(dbmarket, dbminbuyout)`, so slow-selling gear isn't overvalued. `/slt tsm` takes any TSM custom price, checks it with TSM, and `/slt tsm default` restores the default.
- **Loot stops counting**: a missed vendor/mail/bank close no longer blocks loot until a reload.
- **Quest gold**: can't be counted twice if a client also shows it as a money message.
- **Lost loot**: items the game hadn't loaded yet were dropped after ~5 seconds; they now wait and always count.
- **Double counting**: what you get from disenchanting, prospecting, milling or opening clams and lockboxes no longer counts on top of the item it came from.

## 🚀 v0.1.1

### ✨ New
- **Auto-start**: if no session is running, the first coin or item you loot starts one. A session you paused stays paused until you click Continue. `/slt autostart` turns this off.

### 🐛 Fixes
- **Window stays up**: Escape no longer closes the window. It is shown by default and only closes with the X button or `/slt hide`.
- **Copper display**: amounts under 1 silver show as `0c` / `5c` instead of `00c` / `05c`.

## 🚀 v0.1.0

### ✨ First Version
- **Session window**: Start / Pause / Continue and Reset (Shift-click Reset to skip the confirm). The timer only counts time while running and logged in, and a running session carries over across reloads and logouts.
- **Category tabs**: Trash, Gear, Tradegoods, Other stuff and ALL. Each tab shows its own count, value, gold per hour and priciest item. ALL adds looted coin and gives the overall gold per hour.
- **Loot list**: newest first and filtered by tab. Hover shows the tooltip, Shift-click links the item, right-click removes the entry from the session. The ◉ button shows/hides the list.
- **Pricing**: TSM → Auctionator → Auctioneer → vendor (`/slt source` to pick one). Trash and soulbound items use vendor price. An AH price below vendor falls back to vendor (`/slt vendorfloor` to turn off).
- **What counts**: looted coin and items, plus items and gold from quest rewards (`/slt questgold` to toggle gold). Items bought, mailed, traded or taken from the bank are ignored.
- **All clients**: one TOC for Era, Forever, TBC/Anniversary, Wrath, Cata, Mists and Retail. Chat parsing uses each client's own localized strings.
