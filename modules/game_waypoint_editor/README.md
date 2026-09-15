# Waypoint editor

Edit cavebot routes on the map instead of through a list of coordinates. Draw where you hunt to get the
walking waypoints, then place everything else by hand: use, use with, say, function, delay - and drop the
one-click jobs (deposit, buy, sell, refill check) where they belong. Labels and jumps are not objects you
place: you put them on a waypoint from its right-click menu.

## Opening it

| From | What happens |
|---|---|
| **Waypoints** button, bottom-left of the minimap | full map opens, editor opens, brush armed |
| **Draw waypoints** in the bot's Cave tab | same, and it loads the route the cavebot has selected |
| Top bar **Waypoint editor** button | same as the minimap button |
| Ctrl+Shift+M (the client's own full map) | editor opens, brush **not** armed - you were only looking at the map |

Escape closes the full map; Escape inside the editor drops you back to Select mode.

## The map toolbar (top left)

**Mode** decides what a left click on the map does. It is always visible, because a tool that silently
changes what your mouse does is how drawings get ruined.

- **At me** - drops a waypoint of the selected type on the tile you are standing on, so you never have to
  find your own square on the map.
- **Draw** - drag to paint the area you hunt. Brush 1x1 / 3x3 / 5x5 / 9x9, painted as **Normal**, **Hot**
  (walked twice as densely), **No-go** (never a waypoint there) or **Erase**. What you paint appears under
  the cursor immediately.
- **Place** - the palette below lists every waypoint type in the cavebot's own colours, and under them the
  one-click jobs. Pick one and click the map to drop it. The type stays selected, so you can place ten of
  them without re-picking. **Ctrl+click** drops it *and* opens its editor.
- **Select** - click a waypoint to select it, drag it to move it, drop it onto another waypoint to reorder.

**The right button works the same in every mode**: a click opens the waypoint's menu (on release), press
and drag pans the map - so you never have to leave Draw or Place mode to look around.

## The route panel (right)

**ROUTE** - the name is the cavebot config it saves as. **The drawing belongs to the route**: Load brings a
route's drawing back with it, Save keeps the drawing with the route, New starts with an empty map.

- **Load** - lists the routes of the bot preset you are running; picking one shows it on the map and jumps
  the camera to it.
- **Save** - writes the route under the name in the box and reloads the bot, so it appears in the Cave tab
  immediately. The cavebot settings and the supply/loot data of that route are preserved.
- **Save as** - refuses if that name already exists, so you cannot overwrite a working route by accident.
- **New** - empty route.

**DRAW AN AREA, GET GOTO WAYPOINTS**

- spacing buttons **5 / 8 / 12 / 20** or any number 1-100 in the box: one waypoint per N squares.
- **Generate goto** - turns the painted area into `goto` waypoints and nothing else. The new block takes the
  place of the goto waypoints that were on this floor, so a loop you built around them keeps its order, and
  every non-goto waypoint stays exactly where it is.
- **Recipes** - inserts a whole block at once. The first one is the **AFK loop** (refill check, depot trip
  with deposit and supplies, back to the hunt); the others are a supply check, a depot trip with selling, a
  lure block, a hunting loop, a pause while the targetbot fights, and a logout when the backpack is full.
  Waypoints land on walkable ground - one on a wall is pulled to the nearest ground, and paint stranded more
  than 50 squares from the main area is ignored.
- **Clear drawing** - removes the drawing on this floor and says how many tiles it cleared - or that the
  drawing is on another floor. Waypoints are untouched.

**WAYPOINTS** - the route in order, which is what the cavebot actually executes. Colour and letter match
the map marker, and the chips under the buttons count each type. Click a row to select, double click to edit
its value, and use **Edit / Up / Down / Remove / Undo / Centre / Loop end** above the list.

- **Loop end** rotates the goto block so the selected goto is walked last - that is where the loop leaves
  for the depot, so pick the goto nearest the exit. Also in the marker's menu as *Make this the loop end*.
- **Snap to stairs** moves the selected goto onto the nearest floor change (stairs, ladder, hole, teleport -
  what the minimap paints yellow), anywhere on the map; a usable item next to you is the fallback.

Keys: **Delete** removes the selected waypoint, **Ctrl+Z** undoes (ten deep: placing, removing, moving,
editing, generating, recipes and New are all undoable), **Escape** goes back to Select mode.

Nothing destructive happens on one click: **New** asks again when you have unsaved waypoints, **Save** asks
again before overwriting a route you did not load, and **Save as** refuses an existing name outright.

## Waypoint types

| | Type | Value | What it is for |
|---|---|---|---|
| G | Go to | `x,y,z` | walk there |
| U | Use | `x,y,z` or item id | ladders, holes, levers, rope spots, drinking a potion |
| UW | Use with | `itemId,x,y,z` | rope, shovel, machete on a specific tile |
| D | Delay | milliseconds | wait |
| S | Say | text | spells, npc words, commands like `!autoloot` |
| F | Function | lua | anything else: buying, depositing, selling, luring, conditions |

**Labels and jumps** live on a waypoint. Right click it: *Label this waypoint...* names the spot the route
can jump back to; *After this, jump to label...* makes the route continue at that label once this waypoint
is done. The list shows them as `[label hunt]` and `-> jump to hunt` under the waypoint, the marker's tooltip
too. The file still holds the cavebot's own `label` and `gotolabel` rows, so the bot runs it unchanged.

**Function** waypoints open a bigger editor with a **Templates** button: deposit or take out these items,
open the depot next to you, sell loot, buy supplies, walk to a position or to a named npc, travel by boat,
wait for the targetbot, jump to a label when supplies run out, wait for free capacity - plus the examples
the cavebot itself ships with.

## One click jobs

The Place palette has a second block under the cavebot types: **Open depot, Deposit loot (individual items),
Deposit loot (backpacks), Take from depot, Buy supplies, Sell loot, Refill check, Wait for fight**. Each drops
an ordinary `function` waypoint with the script already written. **Where you drop it matters**: the job
walks to that tile first, then does its work - so put the depot jobs on the tile next to the locker and Buy
supplies next to the shopkeeper. Drag the marker to move the tile; the job's marker is where its script says.
The file stays a plain cavebot config - the bot never sees anything it does not understand.

Every job decides for itself whether there is anything to do, so one route serves every trip: Buy supplies
walks past the shop when nothing is short, Deposit loot (backpacks) keeps a nearly empty loot bag when you
only came for supplies, and a job that cannot finish says why and the route carries on. The cavebot is
stopped for two reasons only: no capacity left for the supplies you asked for, and - if the Loot window says
so - no loot backpack to be had at the depot.

## A full afk system

1. Draw the hunting area, **Generate goto**.
2. Right click the goto nearest the exit, **Make this the loop end**. Right click the first goto,
   **Label this waypoint...** `hunt`.
3. **Recipes** - **AFK loop**. It inserts a **Refill check** after the hunt, then the depot trip (Deposit
   loot, Buy supplies) and the jump back to `hunt`. Label the first waypoint of the trip `depo` - that is
   where the Refill check sends you - and drag the jobs onto their tiles (or draw the path to town as goto
   waypoints and **Snap to stairs** on the floor changes).
4. **Loot** window: tick what goes to the depot; set the three loot backpacks if you deposit by the bag.
   **Supplies** window: how many of each to carry.
5. **Save**, then **Bot: on**.

The **Refill check** is a function you can edit: `minCap = 300` (oz of free capacity), `lowPct = 25` (a
supply row below this percent of its target), `label = 'depo'`, `lootFull = true` (also go when the loot
backpack and the bags in it are full). Below any of those it jumps to the label and records why it sent you;
otherwise the hunt goes on.

## Loot

**Loot** (button next to Supplies) is the list the loot jobs read. **Sell loot sells everything the npc
buys, except the items you tick "keep"** - or only the rows ticked "sell", if any are. **Deposit loot** puts
the "depot" items away, and those are kept from selling too. Nothing is hard coded in the scripts - the
jobs read the list when they run, so changing it changes every route at once. **Load from autoloot** takes
your server autoloot list as the deposit list.

**LOOT BACKPACKS** is the fast way to deposit: instead of moving items one by one, the whole loot bag is
dropped off and an empty one taken. Three kinds of backpack, told apart by their item:

- **loot bag** - sits at the top of your main backpack; the server's autoloot fills it (and the sweep below
  keeps it that way).
- **full-loot storage** - a backpack in the depot chest that the full loot bags are dropped into.
- **empty-set storage** - a backpack in the depot chest holding complete sets of empty loot bags (a set is a
  loot bag with *plain bags per set* empty bags inside it).

**Deposit loot (backpacks)** at the depot: sweeps loose loot from the main backpack into the loot bag, drops
the loot bag into the full storage, takes one complete set out of the empty storage, and sweeps what did not
fit into the fresh bag. When no set is left (or the depot will not take your loot bag) the switch under the
rows decides: **stop the cavebot** once the bags are closed, the default, or keep hunting without a loot
backpack - then the next depot trip deposits the loose loot item by item, the slow way. **Swap now** does
the same from the window while you stand at the depot. **Build sets** tidies the chest: nested bags are
unpacked, full loot bags go to the full storage, every loot bag is filled to the set size, complete sets are
parked in the empty storage and short ones wait at the chest top with a note of how many plain bags are
missing. Exactly one storage of each kind stays at the chest top; spares are packed into their storage.

**while hunting, keep moving loose loot...** - the sweep. Every few seconds anything from the deposit list
lying loose in the main backpack is moved into the loot bag (or a bag inside it); when everything is full it
says so once and the Refill check knows.

## Supplies and named items

**Supplies** (button next to Recipes) holds two things:

*What to keep in the backpack.* One line per item: a name (`great mana potion`) or a raw id, and how many.
One line may instead say **fill cap** with a number, which means "top this up until only N capacity is left".
A **Buy supplies** waypoint buys whatever the list is short of, cheapest constraint first: it stops at the
gold you are carrying (golden nuggets count), and at the capacity you asked to keep free - and walks past
the shop when nothing is short.

*How the counts are known.* By default the number the game prints when you use an item ("Using one of 148
great mana potions...") is trusted, so nothing has to be opened; the switch at the bottom of the window
counts by opening every bag instead (exact, slow). Bags are opened one window at a time and only until the
count is high enough.

*Named items.* A table of name to id that scripts can use - `RouteItems.id('great mana potion')` gives 238.
It starts with the usual potions, runes and tools, and every shop you open adds the names it advertises, so
the table fills itself in as you play.

## Which route does the bot run?

Two things can differ: the route open in the editor, and the route the cavebot is set to. The header says so
when they do - *WAYPOINTS - 74 in agent_showcase (bot is on "route test")* - and two buttons move between them:

- **Bot: on** runs the route you have open. If the cavebot is set to something else it is pointed at this
  route first, then started. An unsaved route cannot be run - Save it first.
- **Running** loads whatever the cavebot is set to into the editor.

Save, with the bot off, also points the cavebot at the route you just saved, so the next **Bot: on** runs it.
With the bot on, Save leaves it running and tells you how to switch.

The live highlight - the white segment on the route line, the outlined marker, the `>` row in the list -
follows the bot only when both are the same route, because the bot's row numbers mean nothing against a
different list.

## What is on the map

Goto, use, use with and the jobs carry their own position and get a full marker, numbered like the list.
Delay, say and a function without a position run between two positions, so they are drawn as small chips
hanging off the waypoint before them, four to a row. Everything clicks and right clicks alike.

While the cavebot is running, the waypoint it is on is outlined in white and the line it is walking is drawn
brighter on top of the route. On a floor change the old floor's line is hidden until the new one is drawn.

**Hide** puts everything the editor draws away and gives you the plain map back; the small **Waypoints**
button in the corner brings it all back. The small minimap shows nothing of the editor unless you tick
*also draw the route on the small minimap* in the editor's options; the other option there, *open the route
the bot is running when the client starts*, is off too - the editor starts empty.

## What it costs

Measured on this client with a 2,500 tile drawing and up to 500 waypoints:

```
paint a stroke      0 ms (the stroke draws itself, the full image is rebuilt 300 ms after you stop)
redraw the drawing  16-25 ms, once, only when the drawing changed
markers             0-1.5 ms       sequence list   0-1.5 ms
add a waypoint      1.5 ms at 25 waypoints, 11 ms at 500
zoom or pan         0 ms - the image is built in tile space and the widget scales it
```

## Checking it still works

`modules.game_waypoint_editor.selftest()` runs its checks and writes `userdata/waypoint_editor_selftest.txt`. The
last one audits every function template, one-click job and recipe against the *running* bot preset, so if
you switch to a preset that is missing a function the templates use, it tells you which call and which
template - it does not wait for the waypoint to fail mid-hunt.
