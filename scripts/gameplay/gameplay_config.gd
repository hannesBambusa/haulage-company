class_name GameplayConfig
extends RefCounted
## Tuning constants for the Milestone 1 core loop. See docs/design/core-loop.md, "Tuning".

## Game minutes in one contract day. The clock runs in real time (1 game
## second per real second at 1x), so storage fees and storage durations count
## in short contract days: a 2-day contract stores for 40 game minutes
## (4 real minutes at 10x, 80 s at 30x) instead of two full clock days.
const MINUTES_PER_CONTRACT_DAY: float = 20.0
## Game minutes between scheduling a pickup and the pickup truck arriving.
const PICKUP_LEAD_MINUTES: float = 10.0
## Inbound truck arrives this many game minutes after accepting ([min, max]).
const INBOUND_DELAY_RANGE: Vector2 = Vector2(5.0, 10.0)
## Free storage slots below this fire the "Storage space low" toast.
const STORAGE_LOW_THRESHOLD: int = 12
## Contracts kept in the Available list, and how often one is swapped out.
const POOL_SIZE: int = 6
const POOL_REFRESH_MINUTES: float = 30.0
## Pallets one trailer holds (Slot_01..Slot_10, 2 across x 5 rows). A
## contract never has more, since every pallet rides in one truck.
const TRAILER_CAPACITY: int = 10
## Most slots generated in each of the INBOUND and OUTBOUND zones.
const ZONE_MAX_SLOTS: int = 12

## Physics layers used by the click raycast (bits 20 and 21).
const CARGO_LAYER: int = 1 << 19
const SLOT_LAYER: int = 1 << 20
