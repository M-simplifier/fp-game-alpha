# Two authored survival campaigns

These are new live-campaign meanings, not a recovered claim about the archived
0.6 campaign IDs. The immutable archive remains at `references/red-dune`.

## A Settlement That Lasts

Forty named residents start at 06:00 with a fixed physical colony. Complete a
66-hour horizon with a final uninterrupted 24-hour stable service interval:

1. Extract real water and operate the farm/kitchen chain
2. Transport freshly cooked ration in a vehicle, reach the pantry and actually
   consume at least 10,000 g of it. Opening ration grants never count
3. Construct new storage or production capacity and actually use it
4. Restore the kitchen after its announced hour-24 breakdown
5. Keep every resident living, health at least 950/1000, fully served during the
   current hour, and at least two hours of water/food in the pantry
6. Keep production, replenishment and maintenance policies enabled throughout the
   counted stable interval

The opening stock can delay fresh-food evidence because actual FEFO consumption
serves older food first. Merely accepting a delivery, making a batch, waiting,
saving, or restoring cannot complete that objective.

## The Broken Supply Line

The same underlying physical model starts with no warehouse ration reserves and
a broken kitchen. The pantry has twelve hours of food. Repair, production and
transport compete for the same carts and reserve crew. Survive 42 elapsed hours
and achieve eighteen uninterrupted stable hours. The different opening constraint
requires recovery before the food chain's first delivery, rather than responding
to the later announced breakdown.

## Policies and player decisions

The survival preset explicitly assigns named crews in all three shifts and enables
visible production/replenishment/maintenance policies. Targets and batch sizes are
editable; disabling policies, starving a source or overfilling a destination has
ordinary simulation consequences. Policies do not grant stock, teleport cargo,
instant-build structures or skip work. Incoming reserved stock counts once, and
replenishment uses a target-minus-batch band to avoid thousands of tiny requests.

Guided warehouse expansion queues five road plans followed by a warehouse at a
known unoccupied western site. Every plan must receive its full material bill by
cart, escrow it, complete named-crew work and commission its real facet. Free
placement remains available through the ordinary construction command/preview.
The reserve-water policy makes the finished warehouse physically useful.

Maintenance of production sites first transports the required Parts into the
facility's input. Only then does it request a maintenance job and assign a named
reserve worker. Repairs take priority over construction for the spare crew. No
second live repair is issued for the same facility.

## Implemented construction scope

The live construction module lists 22 supported facilities plus roads. It includes
production/extraction, warehouses, pantries, Water tanks, housing, solar and battery
facets. The same content-defined cost/work/snapshot and spatial lifecycle are used.
Powered facilities commission a physical cable along existing roads to a reachable
wire; isolated circuits remain isolated. New batteries contain zero stored energy.

Tanks currently hold Water. Workshops default to Parts. Quarries select the recipe
matching the bound Stone or Sand deposit. Generator staffing, depot founding,
school, shelter, garage and observatory are explicitly unsupported. Technology,
contracts, immigration and weather storms are outside these authored campaigns.
A catalog row is not a claim that its whole associated system is implemented.

## Editable packs

`data/campaign-pack-v1.json` is the complete strict JSON pack. Revisions can change
scenario text, duration, stability and opening-ration constraints; recipe amounts
and work; building costs and maintenance; and labels. Geometry/workforce counts
are pinned to the authored forty-person layout. Passive storage/housing remains
unpowered and maintenance-free. Validation preflights the actual starting world,
references, dimensions, economic capacity, IDs and ranges. It does not promise that
an arbitrary rebalance is enjoyable or winnable.

Staging validates the entire candidate and requires a newer revision. Invalid or
stale candidates leave the prior stage and current game untouched. A running game
pins its full economy and scenario; staged content activates only on a new game.
Live saves carry both the pinned and staged packs, not mutable filenames.
