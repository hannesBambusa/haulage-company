# Core gameplay loop

## Rules (from the designer)

1. Review opportunities in Contracts.
2. Evaluate capacity: storage, docks, employee load, equipment and deadlines.
3. Accept a contract.
4. Inbound visit is scheduled.
5. Truck arrives and is assigned to a compatible dock.
6. Assigned employees automatically unload cargo into the Inbound Zone.
7. Player decides where the cargo should be stored.
8. Employees/equipment physically move the cargo to the chosen storage location.
9. Cargo occupies space and generates storage revenue according to the contract.
10. Client eventually schedules pickup.
11. Player identifies the correct cargo and sends it to the Outbound Zone.
12. Employees physically gather the selected cargo.
13. Correct cargo is automatically loaded when the pickup truck docks.
14. Wrong cargo remains in outbound and must be sent back to storage.
15. Contract completes; player receives final handling/storage payment and reputation outcome.
16. Player spends profit on upgrades that enable larger or more profitable contracts.

## Milestone 1 scope (core loop slice)

In:

- Contracts list with Accept. Accepting is blocked when free pallet spaces are fewer than the contract needs (rules 1-3, storage part of 2).
- Accepting schedules an inbound truck at a set game time (rule 4).
- Truck goes to the first free dock (rule 5). Every truck fits every dock for now.
- Workers unload pallets one by one into the Inbound Zone (rule 6).
- Player clicks inbound cargo, then clicks a free rack slot or floor slot (rule 7).
- A worker or forklift carries each pallet to that slot (rule 8).
- Stored pallets add storage revenue per game day (rule 9).
- After the contract's storage days, the client schedules a pickup (rule 10).
- Player selects stored pallets and sends them to the Outbound Zone; workers carry them there (rules 11-12).
- Pickup truck docks and loads the pallets that belong to the contract (rule 13).
- Contract completes and pays the handling fee plus storage (rule 15).

Out for now:

- Employee load, equipment limits and deadline checks in the capacity step (rule 2).
- Dock compatibility by truck or cargo type (rule 5).
- Wrong cargo in outbound and sending it back (rule 14). Outbound accepts only cargo from the active pickup.
- Reputation (rule 15).
- Upgrades (rule 16). The Upgrades tab stays a placeholder.

## Tuning

Milestone 1 values, all in `scripts/gameplay/gameplay_config.gd` (`GameplayConfig`) unless noted.

- Real-time clock: at 1x one game second passes per real second (`GameState.minutes_per_second` = 1/60). Forklifts, trucks, workers and the clock all run on the same game time. Speeds are 1x, 2x, 5x, 10x and 30x (`GameState.SPEEDS`); the HUD speed button and Tab cycle them, Space pauses. The HUD clock shows HH:MM, so at 1x it moves one minute per 60 real seconds.
- Motion stays physical at every speed: movement runs in fixed steps of at most 1/60 game second (forklifts, workers, trucks), with traffic checks every 4 steps, so 30x moves the same way as 1x, only more steps per frame.
- 1 contract day = 20 game minutes (`MINUTES_PER_CONTRACT_DAY`): a 2-day storage contract stores for 40 game minutes, 4 real minutes at 10x or 80 s at 30x. Storage fees and storage durations count in contract days.
- Storage fee accrues continuously: pallets in storage x fee per pallet per day x elapsed contract days. It is paid with the handling fee when the pickup truck has loaded the last pallet.
- The storage-day timer starts when every pallet of the contract is in storage. When it runs out, the pickup truck is booked 10 game minutes later (`PICKUP_LEAD_MINUTES`).
- The inbound truck arrives 5 to 10 game minutes after accepting (`INBOUND_DELAY_RANGE`, used by `ContractManager.inbound_delay_range`).
- A whole contract (accept, unload, put-away, storage, picking, loading) takes about 1 to 1.5 game hours: a few real minutes at 30x.
- Docks run in physical mode in the game (`Dock.physical_transfer`): a pallet counts when the forklift sets it down in INBOUND (unloading) or on its trailer slot (loading), not on a timer. Unloading ends when the trailer is empty; loading ends when every pallet is inside and the Loader has left the trailer. One forklift unloads an 8-pallet trailer in about 7 game minutes. Timer mode (`minutes_per_pallet`) is kept for the UI preview.
- One trailer holds 10 pallets (`TRAILER_CAPACITY`), so a contract has at most 10.
- The "Storage space low" toast fires when free storage slots drop below 12 (`STORAGE_LOW_THRESHOLD`).
- Six contracts are on offer (`POOL_SIZE`). Every 30 game minutes the oldest offer is replaced (`POOL_REFRESH_MINUTES`).
- Each rack bay holds 2 pallets per beam level. `RackStock.fill` (default 0.5) caps the share of rack slots taken by decorative house stock.
- Worker duties are tuned in game seconds in `scripts/gameplay/duties/duty_config.gd` (`DutyConfig`), so they follow the same clock.

## Pallet lifecycle

Every pallet is a `CargoUnit` with an ID (`PL-000123`), a state, a location code and a history: one entry per state change with the game day and time, the state, the location and who moved it. Click a pallet in 3D (in a trailer, a zone, a rack or on a forklift) for the Pallet panel; the Storage tab lists every pallet per contract with a state filter.

States, in order. Every pallet goes through all of them:

| State | Where | Who |
|---|---|---|
| In truck | On a trailer slot of the inbound truck | |
| Unloading | On the forks | Forklift 1 (Unloader) |
| Inbound | INBOUND zone slot | Forklift 1 (Unloader) sets it down |
| Put-away | On the forks | Forklift 2 (Rack), after the player picks a rack slot |
| Stored | Rack slot (floor slots only when every rack slot is full) | Forklift 2 (Rack) |
| Picking | On the forks | Forklift 2 (Rack), after the pickup is scheduled and the player sends it out |
| Outbound | OUTBOUND zone slot | Forklift 2 (Rack) |
| Loading | On the forks | Forklift 3 (Loader) |
| Loaded | Trailer slot of the pickup truck, filled from the nose (Slot_01) back | Forklift 3 (Loader) |
| Delivered | Left with the pickup truck | |

Roles: three forklifts, each with its own driver and one role. A job waits for its role's forklift; the others never take it. Workers do no cargo moves; they stand at rest spots off the traffic lanes.

Location codes: trailer slots `T-Dock1-03`, zone slots `INBOUND-05` and `OUTBOUND-02`, rack slots `<rack>-L<level>-<position>` from the rack node name (`RackA1` level 2 position 1 is `A1-L2-1`), floor slots `FLOOR-07`. While carried, the location is the forklift (`Forklift 1 (Unloader)`).

Motion and traffic (scripts/gameplay/carry_agent.gd, traffic.gd, motion_path.gd):

- Forklifts follow drivable paths: Dubins arcs (radius 1.8 m, never rotating in place) and straights round a grid route, with reversing manoeuvres where needed. 2 m/s on open floor, 1.2 m/s on ramps, in trailers and on final approaches, 1 m/s² acceleration and braking, slower on arcs. Forks move at 0.35 m/s, only standing or creeping.
- Slots are approached square-on along a straight of at least 2 m and left in reverse. INBOUND is entered from the dock side, OUTBOUND from the hall side (its other side is the yard). Slots without room for that approach are not used.
- One agent at a time in a dock lane (ramp and trailer), in front of INBOUND, in front of OUTBOUND, in the floor storage and in each rack aisle. Others plan around a held area and queue outside it: at the dock's queue spot, or at their parking spot when they stand in a work area. A lock is freed once the holder has left the area (or driven 9 m).
- Forklifts never park or wait inside a zone front, a dock lane or its apron, a rack aisle or a slot approach (`Traffic.in_keep_clear`). Idle forklifts drive to their parking spot, which is checked at startup to be off those areas, off the workers' rest spots and apart from the others (and moved if not). When an agent waits for a lock whose holder is idle, the holder leaves; when the holder is stuck, the waiter clears out of its way.
- Distances (edge to edge, people centre to centre) are never below 2.5 m between vehicles, 1.5 m between a vehicle and a person and 1.0 m between people. Movers start to yield at 3.0 m, 1.9 m and 1.2 m and never close in below 2.6 m, 1.6 m and 1.05 m, also with the right of way. Two exceptions, both narrow: members of one conversation group stand 0.72 m apart from each other, and a worker servicing a parked forklift (walking up, kneeling beside it, packing up) comes right up to it while it stands with no job; the JobBoard holds it while the worker kneels there, so it cannot drive off. A loaded vehicle or a lock holder has priority, then the lower id; after 3 s of waiting on each other the other one backs off and plans again.
- Everyone accelerates and brakes at no more than 1 m/s^2, forklifts and workers alike. Workers walk at 1.3 to 1.6 m/s.
- Slots with no drivable way in from the hall floor (the turn into a narrow aisle does not fit a 1.8 m radius) are not used.

Pallets never block anyone (scripts/gameplay/storage_grid.gd `placement_ok`, carry_agent.gd):

- A pallet is never set down where it stands in a dock lane or its apron or in another area's approach room, where its own approach holds another pallet (the placer leaves the way it came), or in the approach of a slot that a delivery is coming to, of a pallet due to be picked up, or of a slot in another area. Zone columns still fill from the back: a resting pallet with no job may have another set down in front of it.
- Before setting down, the forklift checks its target again and takes another valid slot when it would now block someone.
- Before driving in to pick a pallet up, the forklift looks for pallets standing in that slot's approach (someone did a poor job, or the player sent the back pallet of a column first). It moves each one itself to a slot where it blocks nobody: its own area first (INBOUND stays INBOUND, OUTBOUND stays OUTBOUND, stored pallets to storage), else the floor, else any free storage slot. The pallet keeps its lifecycle state; its history gets an entry with the new location and "Moved to clear path by Forklift N (Role)". Then the forklift goes on with its job.
