# Waypoint editor

Edit cavebot routes on the map instead of through a list of coordinates. Draw where you hunt to get the
walking waypoints, then place everything else by hand: use, use with, say, function, label, delay.

## Opening it

| From | What happens |
|---|---|
| **Waypoints** button, bottom-left of the minimap | full map opens, editor opens, brush armed |
| **Draw waypoints** in the bot's Cave tab | same, and it loads the route the cavebot has selected |
| Top bar **Waypoint editor** button | same as the minimap button |
| Ctrl+Shift+M (the client's own full map) | editor opens, brush **not** armed - you were only looking at the map |

Escape closes the full map; Escape inside the editor drops you back to Select mode.

## The map toolbar (top left)

**Mode** decides what a click on the map does. It is always visible, because a tool that silently changes
what your mouse does is how drawings get ruined.

- **At me** - drops a waypoint of the selected type on the tile you are standing on, so you never have to
  find your own square on the map.
- **Draw** - drag to paint the area you hunt. Brush 1x1 / 3x3 / 5x5 / 9x9, painted as **Normal**, **Hot**
  (walked twice as densely) or **Erase**. What you paint appears under the cursor immediately.
- **Place** - the palette below lists every waypoint type in the cavebot's own colours. Pick one and click
  the map to drop it. The type stays selected, so you can place ten of them without re-picking.
  **Ctrl+click** drops it *and* opens its editor.
- **Select** - click a waypoint to select it, drag it to move it, right click it for its menu.

## The route panel (right)

**ROUTE** - the name is the cavebot config it saves as.

- **Load** - lists the routes of the bot preset you are running; picking one shows it on the map and jumps
  the camera to it.
- **Save** - writes the route under the name in the box and reloads the bot, so it appears in the Cave tab
  immediately. The cavebot settings and the supply/depositer data of that route are preserved.
- **Save as** - refuses if that name already exists, so you cannot overwrite a working route by accident.
- **New** - empty route.

**DRAW AN AREA, GET GOTO WAYPOINTS**

- spacing buttons **5 / 8 / 12 / 20** or any number 1-100 in the box: one waypoint per N squares.
- **Generate goto** - turns the painted area into `goto` waypoints and nothing else. The new block takes the
  place of the goto waypoints that were on this floor, so a loop you built around them keeps its order, and
  every non-goto waypoint stays exactly where it is.
- **Recipes** - inserts a whole block at once: a depot trip (deposit, sell, buy, back to hunting), a supply
  check that jumps to a refill label, a lure block, a hunting loop, a pause while the targetbot fights, or a
  logout when the backpack is full. Waypoints land on walkable ground - one on a wall is
  pulled to the nearest ground, and paint stranded more than 50 squares from the main area is ignored.
- **Clear paint** - removes the painted area on this floor. Waypoints are untouched.

**WAYPOINTS** - the route in order, which is what the cavebot actually executes. Colour and letter match
the map marker, and the chips under the buttons count each type. Click a row to select, double click to edit
its value, and use **Edit / Up / Down / Remove / Undo / Centre** above the list.

Keys: **Delete** removes the selected waypoint, **Ctrl+Z** undoes (ten deep: placing, removing, moving,
editing, generating, recipes and New are all undoable), **Escape** goes back to Select mode.

Nothing destructive happens on one click: **New** asks again when you have unsaved waypoints, **Save** asks
again before overwriting a route you did not load, and **Save as** refuses an existing name outright.

## Waypoint types

| | Type | Value | What it is for |
|---|---|---|---|
| G | Go to | `x,y,z` | walk there |
| U | Use | `x,y,z` or item id | ladders, holes, levers, ropes spots, drinking a potion |
| UW | Use with | `itemId,x,y,z` | rope, shovel, machete on a specific tile |
| L | Label | name | a point the route can jump back to |
| GL | Go to label | name | the jump itself - this is how loops and branches are built |
| D | Delay | milliseconds | wait |
| S | Say | text | spells, npc words, commands like `!autoloot` |
| F | Function | lua | anything else: buying, depositing, selling, luring, conditions |

**Function** waypoints open a bigger editor with a **Templates** button: deposit everything, open the depot
next to you, sell loot, buy potions, travel by boat, wait for the targetbot, jump to a label when supplies
run out, wait for free capacity - plus the examples the cavebot itself ships with.

## A full afk system

1. Draw the hunting area, **Generate goto**.
2. **Place** a `label` called `hunt` at the start of the loop.
3. At the end of the loop place a `function` with the *supplies* template, so it jumps to a label when the
   potions run out.
4. Place `goto` waypoints back to town (or draw that path too), then `use` on the depot, a `function` with
   the deposit template, a `function` with the sell template, `say`/`function` to buy supplies, and finally
   a `go to label` back to `hunt`.
5. **Save**. The cavebot runs it, and the whole thing is one file you can hand to someone else.

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

`modules.game_route_paint.selftest()` runs 11 checks and writes `userdata/route_paint_selftest.txt`. The last
one audits every function template and recipe against the *running* bot preset, so if you switch to a preset
that is missing a function the templates use, it tells you which call and which template - it does not wait
for the waypoint to fail mid-hunt.

## Modes

**Move** is where it starts, and it is the plain map: drag to look around, wheel to zoom, nothing of the
editor gets in the way. The other three add to it rather than replace it.

| mode | what the left button does |
| --- | --- |
| Default | the map as it always was - and a click on one of our waypoints selects it, a drag moves it, a drop **onto another waypoint reorders** |
| Draw | paints the area you hunt |
| Place | drops a waypoint of the selected type (ctrl+click opens its editor) |

Waypoints can be grabbed in every mode; the modes only change what a click on empty map does.

A click that lands on the toolbar, a menu or the editor window never reaches the map underneath, so pressing
a button in Place mode no longer leaves a waypoint behind it.

**Hide** puts everything the editor draws away and gives you the plain map back; the small **Waypoints**
button in the corner brings it all back.

The editor **starts empty**. Tick *load this preset's last route when the client starts* if you would rather
it opened where you left off.

## What is on the map

Goto, use and usewith carry their own position and get a full marker. The other five - label, go to label,
delay, say, function - run between two positions, so they are drawn as small chips hanging off the waypoint
before them, four to a row. They click and right click like any other waypoint.

While the cavebot is running, the waypoint it is on is outlined in white and the line it is walking is drawn
brighter on top of the route.

## Supplies and named items

**Supplies** (button next to Recipes) holds two things:

*What to keep in the backpack.* One line per item: a name (`great mana potion`) or a raw id, and how many.
One line may instead say **full cap minus N**, which means "fill the rest of the capacity with this, leaving
N free". A **Buy supplies** waypoint buys whatever the list is short of, cheapest constraint first: it stops
at the gold you are carrying, and at the capacity you asked to keep free.

*Named items.* A table of name to id that scripts can use - `RouteItems.id('great mana potion')` gives 238.
It starts with the usual potions, runes and tools, and every shop you open adds the names it advertises, so
the table fills itself in as you play.

## One click jobs

The Place palette has a second block under the eight cavebot types: Open depot, Deposit loot, Take from depot,
Buy supplies, Sell loot, Wait for fight. Each drops an ordinary `function` waypoint with the script already
written. **Where you drop it matters**: the job walks to that tile first, then does its work - so put Open
depot on the tile next to the locker and Buy supplies next to the shopkeeper. Drag the chip to move the tile.
The file stays a plain cavebot config - the bot never sees anything it does not understand.

## The no-go brush

A third paint weight next to Normal and Hot. Tiles painted with it are drawn like any other, but a waypoint is
never generated on them and a snapped waypoint never lands on one either.

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

## Loot

**Loot** (button next to Supplies) is the list the two loot jobs read. **Sell loot sells everything the npc
buys, except the items you tick "keep"** - so you list the handful worth protecting, not the hundred worth
selling. **Deposit loot** puts the "depot" items away, and those are kept from selling too (selling them first
would empty the backpack before the depot run). Nothing is hard coded in the scripts - the jobs read the list
when they run, so changing it changes every route at once.
