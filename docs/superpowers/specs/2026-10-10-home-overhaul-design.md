# Home screen overhaul: "What's leaving near me"

Date: 2026-10-10
Status: design approved in brainstorming; awaiting spec review
Repos: `markb-1/turas` (app), `markb-1/turas-server` (server)

## Goal

Turas is for daily use by its author and for release to others, with no sign-up. This
overhaul makes the app useful the moment it opens: it shows **what is leaving near the
centre of the map**, and lets people **search on the map** for stops, routes and places.
It replaces today's route-first flow (pick a route, then a direction, then a stop) and gives
the app a distinctive visual identity.

Saved journeys (starred routes and stops with their next times), widgets, release work
(HTTPS, privacy, TestFlight) and refreshing the bundled route lines are out of scope and
follow later, in that order.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Home layout | Fixed split: map on the top half, one "leaving soonest" timeline on the bottom half |
| Modes | Keep Bus / Luas / Train tabs; the timeline shows one mode at a time |
| Repeats | One row per route and direction, from the nearest stop that has a departure in the window, with its next 3 times |
| Tap a row | Route focus: the route's line and live vehicles on the map, the stop highlighted, its next times below |
| Panning | The timeline follows the map centre; a "near me" button snaps back to the user's location |
| Search | One box; results grouped as Stops, Routes and Places |
| Style | "Irish, card-based": teal palette, soft cards, pill badges; light and dark |
| Computation | Server-side: one `/nearby` request per refresh |

## User experience

### Timeline (default state)

- The map fills the top half. The search box floats at its top. The bottom half shows the mode
  tabs and the timeline.
- Each timeline row is a card: route badge, destination, stop name and distance, the first time
  large, and the next two times small. Example: `39A · Ongar · College Green 90 m · 2 min · 14 · 27`.
- Rows are sorted by their first time. Timetable-only times are muted.
- The stops used by the timeline appear on the map as small teal pins, labelled at higher zoom.
  Tapping a pin scrolls the timeline to that stop's first row.
- Dragging the map refetches for the new centre about 0.6 s after the camera settles, and only
  if it moved more than 50 m. A "near me" button returns to the user's location.

### Search state

- Tapping the search box expands it. Results update as the user types (250 ms debounce), in
  three groups of up to 8 each:
  - **Stops** (server): selecting one flies the map to the stop. The timeline then follows the
    map centre, which is now that stop.
  - **Routes** (server): selecting one opens route focus.
  - **Places** (Apple MapKit local search, limited to Ireland, on device): selecting one flies the
    map there.
- Cancel or an empty query returns to the timeline.

### Route focus state

- Entered by tapping a timeline row (route, direction and stop known) or a route search result
  (no stop yet: use the stop on that route nearest the map centre).
- **Map:** the route's line for that direction (bundled shapes), its live vehicles, and the stop
  highlighted. The camera fits the stop and the nearby part of the route, not the whole line.
- **Bottom half:** route badge, destination, stop name and walk time, then the next several
  times at that stop with live, late and cancelled states. A ⇄ button flips the direction.
- Back chevron or swipe down returns to the timeline with its scroll position intact.
- Data: existing `/stops`, `/vehicles`, `/arrivals` and `/luas/arrivals`, refreshed every 30 s
  while open.

### First launch and location

- If location authorisation is not determined, the timeline area shows a priming card:
  "See what's leaving near you", with **Allow location** (which then shows the iOS prompt) and
  **Not now**. The iOS prompt never appears unexplained.
- Not now, denied or restricted: the map centres on O'Connell Bridge (53.3472, -6.2592) with a
  "Showing city centre" note. Everything works, because the timeline follows the map.

### Refresh, empty and error states

- The timeline refreshes every 30 s while visible and the app is active, and pauses in the background.
- Offline or server error: keep the last results, show "Updated N min ago" with a retry.
- 503 (server loading): "Turas is starting up…", with automatic retry.
- Nothing in range: "Nothing leaving within 500 m in the next 90 min", with a hint to switch
  mode or move the map.
- 429 (rate limited): silent retry on the next tick.

### Accessibility

- Each row has one VoiceOver label, e.g. "39A to Ongar from College Green, 90 metres. Live,
  2 minutes, then 14 and 27 minutes."
- All text uses Dynamic Type; times stay legible at accessibility sizes (the row wraps rather than
  truncating the time).
- Mode tabs, pins and buttons have labels and traits; colour is never the only signal (live has a
  dot, cancelled is struck through and labelled).

## Server changes (`turas-server`)

### `GET /api/v1/nearby?lat=&lon=&mode=bus|luas|train`

Same auth (`x-api-key`), rate limit and 503-while-loading behaviour as the other `/api/` routes.
`lat`/`lon` are required decimals; `mode` is required. Bad input returns 400.

**Algorithm**

1. **Candidate stops:** stops served by at least one route of `mode`, within 500 m of the point
   (haversine via `internal/geo`), nearest first, capped at 15. A linear scan over the ~10k stops
   is acceptable (measured against the latency budget below).
2. **Departures per stop**, in the window [now − 2 min, now + 90 min]:
   - **Bus and train:** for each route serving the stop (new index: stop → routes), take the trips of
     that route (new index: route → trip IDs) that run on today's or yesterday's service day (see
     `ServicesOnLocked`). Look up each trip's scheduled time at the stop.
     - If the trip has a GTFS-RT trip update, use the existing `Calculator` logic (delay propagation,
       `start_date`, cancellations) to predict it.
     - Otherwise the time is the scheduled time, `source: "timetable"`.
   - **Luas:** for the nearest 3 Luas stops with a Luas code, call the existing Luas service (30 s
     cache) and map its forecasts to departures (`source: "live"`). Luas trips have no GTFS trip
     IDs; use the Luas service's synthetic IDs.
3. **Source per time:**
   - `live`: a vehicle reports for the trip (GTFS-RT vehicle, or an Irish Rail train matched by
     train code), or the Luas forecast.
   - `realtime`: a trip update exists but no vehicle reports.
   - `timetable`: no trip update.
4. **Group** by (route, agency, direction). For each group keep the **nearest stop** that has at
   least one time in the window, and its next 3 times, sorted ascending.
5. **Sort** rows by their first time; ties by distance, then route name.

**Response**

```json
{
  "stops": [
    {"id": "8220DB000400", "name": "College Green", "lat": 53.3441, "lon": -6.2595, "distance_m": 90}
  ],
  "departures": [
    {
      "route": "39A", "agency_id": "1", "direction": 0, "headsign": "Ongar",
      "stop_id": "8220DB000400", "distance_m": 90,
      "times": [
        {"trip_id": "5913_56733", "at": "2026-10-10T19:52:00+01:00", "delay": 120, "source": "live", "cancelled": false}
      ]
    }
  ]
}
```

- `stops` lists only stops referenced by `departures` (these become the map pins).
- `headsign` is the trip's own `trip_headsign` when known, else the route and direction headsign.
- Lists are `[]`, never `null`. Times are RFC 3339 with whole seconds. `distance_m` is an integer.
- `cancelled` is always present (a bool); a cancelled trip keeps its timetabled time.

**Caching and cost**

- Responses are cached for 15 s, keyed by (mode, lat/lon rounded to a ~50 m grid). The cache is
  bounded (LRU, 2,000 entries) and cleared when a new GTFS zip loads.
- New indexes are built in `LoadZip` alongside the existing route tables, and swapped under the
  same lock:
  - stop → routes: the inverse of `RouteStopSets`;
  - route → trip IDs.
- **Latency budget:** p95 under 50 ms on the VM for an uncached request in central Dublin
  (measured with a Go benchmark on the real feed before merging).

### `GET /api/v1/search?q=&mode=`

- `q` is required, 1–64 characters; `mode` is optional (when given, that mode's results first).
- **Normalisation:** case-folded, diacritics removed ("dun laoghaire" matches "Dún Laoghaire"),
  punctuation collapsed. Normalised names are precomputed at load.
- **Stops:** name contains the query; prefix matches rank first, then shorter names. Up to 8.
  Stops with the same name within 30 m are merged; keep the one served by most routes.
- **Routes:** route short name has the query as a prefix ("39" finds 39 and 39A), or a headsign
  contains it ("ongar" finds 39A). Up to 8; exact name first.
- **Response:**

```json
{
  "stops":  [{"id": "…", "name": "Dún Laoghaire (Mallin)", "lat": 53.29, "lon": -6.13, "modes": ["train"]}],
  "routes": [{"name": "46A", "agency_id": "1", "agency_name": "Dublin Bus", "mode": "bus", "headsign_outbound": "Dún Laoghaire", "headsign_inbound": "Phoenix Park"}]
}
```

### Contract

- `testdata/contract/nearby.json` and `search.json` are added, with `TestContractFixtures`
  covering them.
- Byte-identical copies go in the app's `TurasTests/Fixtures/`.
- `CLAUDE.md` (both repos) documents both endpoints.

## App changes (`turas`)

### Structure

| Unit | Responsibility | Depends on |
|---|---|---|
| `HomeModel` (@MainActor) | Screen state (`timeline` / `search` / `focus(RouteFocusTarget)`), selected mode, map camera and centre, "near me" | `LocationService`, the three models below |
| `NearbyModel` (@MainActor) | Fetch `/nearby` for (centre, mode); settle debounce (0.6 s, ≥ 50 m); 30 s refresh; scene-phase pause; last-good results with timestamp; error and empty state | `TurasServerService`, clock |
| `SearchModel` (@MainActor) | 250 ms debounce; server search plus `MKLocalSearch` (Ireland region); merged grouped results; cancellation of stale queries | `TurasServerService`, a `PlaceSearching` protocol wrapping MapKit |
| `RouteFocusModel` (@MainActor) | For one route, direction and stop: stops and line (bundled shape), vehicles filtered to the route, arrivals at the stop; 30 s refresh; flip direction | `TurasServerService`, `StaticDataStore`, `RouteShapeService` |
| `Theme` | Colour tokens (asset catalog, light and dark), type styles, spacing, mode and line colours | none |
| Components | `RouteBadge`, `DepartureCard`, `TimeStack`, `StopPin`, `ModeTabs`, `SearchField`, `PrimingCard`, `StatusBanner` | `Theme` |
| `HomeView` | Composes map, search and bottom panel per screen state | `HomeModel` |

**Removed:** `MapViewModel`, `RouteSearchBar`, `BusDetailSheet`, `StopDetailSheet`,
`NearbyStopSheet`, and nearby-stop search over bundled data (`RouteStopService.nearbyStops`)
once unused.

**Kept:** `TurasServerService` (adds `fetchNearby`, `search`), `LocationService`,
`StaticDataStore`, `RouteShapeService`, `FavouritesStore` (no UI until saved journeys),
`Formatting` (extended).

### Map

- `.mapStyle(.standard(pointsOfInterest: .excludingAll))`.
- Pins come only from `/nearby`'s `stops` in timeline state.
- In route focus: the line, vehicles and highlighted stop.
- The user location dot is always shown when authorised.

### Visual system (style C)

| Token | Light | Dark |
|---|---|---|
| `brand` | `#007A6C` | `#2BB3A0` |
| `ink` | `#0F2A24` | `#E8F0ED` |
| `surface` | `#F6F8F7` | `#0E1513` |
| `card` | `#FFFFFF` | `#17211E` |
| `muted` | `#5F716C` | `#8FA39D` |
| `late` | `#9C5F00` | `#F0A93B` |
| `cancelled` | `#B3261E` | `#F2867E` |

- **Badges:** pill shape.
  - Bus: `ink` background, `card` text.
  - Luas Green line `#00A651`, Red line `#E3001B`.
  - DART `#00A28C`.
  - Other Irish Rail `#00843D`.
- **Type:** system font. Destination is body; stop and distance are caption in `muted`. The
  first time is title3 semibold in `brand` (live or realtime) or `muted` (timetable). Later times
  are caption.
- **Cards:** 12 pt corner radius, 6 pt spacing, `card` on `surface`.

## Testing

- **Server (Go):**
  - `/nearby`: nearest-stop rule, the 3-time cap, the 500 m and 90 min limits, timetable-only
    trips, realtime and live source flags, midnight (yesterday's trips), Luas mapping with a stub
    upstream, caching, 400s, 503 while loading.
  - `/search`: accent and case folding, prefix ranking, headsign match, mode ordering, merging of
    nearby same-name stops.
  - A benchmark for `/nearby` on a synthetic feed; manual timing on the VM's real feed before merge.
- **App (XCTest):**
  - Models with fake services and an injected clock: debounce and settle thresholds, refresh
    pause and resume, last-good on error, state transitions, search grouping and cancellation,
    focus direction flip.
  - Contract fixture decoding for `nearby.json` and `search.json`.
- **UI smoke test** (new `TurasUITests` target, committed): launches with location granted at
  College Green, then walks timeline → search (stop, route, place) → route focus → back, plus the
  Luas and Train tabs. It saves screenshots as test attachments. Run locally and in CI.

## Delivery

1. **Server PR:** indexes, `/nearby`, `/search`, fixtures, docs. These are additions; the current
   app is unaffected. Merge, then deploy to the VM (not during the AI Gaffer tick at :35).
2. **App PR:** theme, components, models, `HomeView`, removals, tests and the UI smoke test.
   Verified against the deployed server, with before and after screenshots in the PR for review
   before merging.

## Risks and notes

- **Stale route lines.** Route focus draws bundled shapes from an older dataset; newer or renamed
  routes may have no line (times and vehicles still work). Fixed by the later data-freshness work.
- **Luas positions.** The Luas has no live positions in TFI's feed, so Luas route focus shows the
  line and stop times only, with no vehicles.
- **TFI quota.** `/nearby` reads the in-memory feed and adds no TFI requests. Luas API calls are
  bounded by the 30 s cache and the 3-stop cap.
- **Server cost.** Building the new indexes adds memory; measure the heap after load, and keep the
  increase under ~60 MB.
