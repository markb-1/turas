# Stop view: tap any stop, see what's leaving it

Date: 2026-10-12
Status: design approved in brainstorming; awaiting spec review
Repos: `markb-1/turas` (app), `markb-1/turas-server` (server)

## Goal

Tapping a stop on the map should show everything leaving that stop. Today a pin only scrolls
the timeline to its first row, and only stops the timeline uses get pins, so many bus stops
cannot be tapped at all. Luas appears to work only because Luas stops are far apart: centring
the map on one makes the nearby timeline roughly that stop's departures.

This change makes the point the timeline measures from visible (a fixed centre marker), shows
every stop around it, and adds a stop view.

Saving stops (★) is out of scope and belongs to the saved-journeys work that follows. Searching
by stop number is a possible follow-up.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Anchor | A fixed marker at the map centre; the map moves under it (ride-hailing pattern), not a draggable pin |
| Radius | Bus 300 m; Luas and train 800 m. Shown as a faint circle around the marker |
| Bus pins | Every bus stop within 300 m of the marker |
| Luas and train pins | Every station of the mode, always (one pin per Luas stop, not per platform) |
| Tap a pin or a stop search result | Opens the stop view |
| Stop view | Replaces the timeline in the bottom panel, like route focus |
| Saving stops | Later (saved journeys) |

**Why 300 m for bus.** Counted from the bundled stops at 13 Dublin locations: 300 m gives 3–17
bus stops everywhere sampled, while 400 m gives 25–48 in the city centre. In 10 of the 13
locations the routes within 300 m equal those within 400 m. The furthest nearest stop was 176 m
(Knocklyon). Planning convention is ~400 m for bus and ~800 m for rail; because the marker moves,
a tighter radius for what is shown costs little.

**Why 800 m for Luas and train.** With 300 m the Luas and train timelines would be empty unless
the marker sat almost on a station.

## User experience

### Timeline (changed)

- A **centre marker** sits over the middle of the map. It ignores touches, so a pin underneath
  stays tappable. While the map is being dragged it lifts slightly; when the camera settles it
  drops back (the timeline refetch follows, as today).
- A **faint circle** around the marker shows the mode's radius (300 m bus, 800 m Luas and
  train). Marker and circle are hidden in route focus and the stop view.
- **Pins:**
  - Bus: every bus stop within 300 m (from `/nearby`'s `stops`).
  - Luas and train: every station of the mode (from `/stations`), labelled at higher zoom as
    today.
- Tapping a pin opens the stop view (it no longer scrolls the timeline).
- The timeline rows come from stops within the mode's radius (was 500 m for all modes).

### Search (changed)

- Selecting a stop result moves the map to the stop and opens its stop view directly.

### Stop view (new)

- Entered by tapping any pin, or a stop search result.
- **Header:** back chevron, stop name, a caption with the stop number when known ("Stop 7602")
  and, when location is authorised, the straight-line distance from the user ("Stop 7602 · 240 m").
- **Rows:** one per route and direction leaving the stop, with its next 3 times, soonest first,
  in the window [now − 2 min, now + 90 min]. They reuse `DepartureCard`, so live, late,
  timetable and cancelled times look the same as the timeline. The stop name line on each card
  is dropped (it is the header).
- **Luas:** both platforms of the stop together, so both directions appear.
- **Train:** every route and direction calling at the station.
- **Empty:** "Nothing leaving in the next 90 minutes".
- **Refresh:** every 30 s; paused in the background and while route focus is open; the usual
  "Updated N min ago".
- **Map:** centred on the stop with its pin enlarged (`StopPin(isHighlighted: true)`). Other pins
  stay visible and tappable; tapping one switches the stop view to that stop.
- **Navigation:**
  - A row opens route focus for that route and direction at this stop.
  - Back from route focus returns to the stop view (not the timeline).
  - Back from the stop view returns to the timeline and restores the camera saved when the
    stop view opened.

### Errors

- Stop view: a failed refresh keeps the last rows and shows the existing `StatusBanner` with
  Retry; 503 shows "Turas is starting up…" and retries; 429 retries on the next tick; 404 shows
  "This stop is no longer in the timetable".
- Station list: if `/stations` fails, the map falls back to `/nearby`'s `stops` as pins for that
  mode and tries again the next time the mode is selected.

### Accessibility

- The centre marker is decorative (hidden from VoiceOver).
- Pins: label "Stop, <name>", hint "Shows departures from this stop".
- The stop view header is a heading; rows keep the existing `DepartureCard` labels.

## Server changes (`turas-server`)

### Stop numbers

- `stops.txt` `stop_code` is parsed into `model.StopInfo.Code` (string, may be empty).

### `GET /api/v1/nearby` (changed)

- **Radius:** `maxDistance` becomes per mode: 300 m bus, 800 m Luas and train.
- **`stops`:** every stop of the mode within the radius, nearest first, capped at 30 (was: only
  the stops `departures` reference). Every stop a row references is within the radius, so it is
  still listed. Rows are still built from the nearest 15 candidates (`maxCandidates`).
- Same response shape; the old app shows extra pins whose taps find no row and do nothing.
- The 15 s cache is unchanged.

### `GET /api/v1/stations?mode=luas|train` (new)

- Every station of the mode:

```json
[{"id": "8250GA00286", "name": "Dawson", "lat": 53.3402, "lon": -6.2588}]
```

- **Luas:** one entry per Luas Forecast code; the two GTFS platforms of a stop collapse to the
  one with the lower stop ID; its coordinates are the mean of the platforms'.
- **Train:** one entry per GTFS stop served by a train route.
- Sorted by name. Built at load (in `LoadZip`, swapped with the other tables), so the request
  is a copy.
- `mode=bus` or a missing or invalid mode: 400 (bus has ~10,000 stops; the app uses `/nearby`).
  503 while loading.

### `GET /api/v1/departures?stop_id=X` (new)

```json
{
  "stop": {"id": "8220DB000400", "name": "College Green", "code": "400", "lat": 53.3441, "lon": -6.2595, "modes": ["bus"]},
  "departures": [
    {"route": "39A", "agency_id": "1", "direction": 0, "headsign": "Ongar", "stop_id": "8220DB000400", "distance_m": 0,
     "times": [{"trip_id": "…", "at": "2026-10-12T19:52:00+01:00", "delay": 120, "source": "live", "cancelled": false}]}
  ]
}
```

- `departures` has exactly the `/nearby` row shape (`model.NearbyDeparture`), with
  `distance_m: 0` and `stop_id` the requested stop (for Luas, the one the request named).
  Sorted by first time, then route name, agency and direction.
- `code` is omitted when empty; `modes` lists the modes of the routes serving the stop.
- **Bus and train:** the `/nearby` schedule computation with this stop as the only candidate:
  every route and direction calling there, trips on today's or yesterday's service day, trip
  updates through `Calculator.PredictLocked`, next 3 times in the window.
- **Luas:** the stop's forecast code, both directions of every Luas route calling there (the
  `/nearby` Luas code, refactored to take a list of stops). 502 when every forecast fails.
- **Errors:** 400 for a missing `stop_id`; 404 `{"error": "unknown stop"}` for an ID not in the
  index; 503 while loading.
- **Cache:** 15 s per stop ID, in the existing LRU, cleared on a GTFS reload.

### Contract

- New fixtures `testdata/contract/departures.json` and `stations.json`; `TestContractFixtures`
  covers them; byte-identical copies in the app's `TurasTests/Fixtures/`.
- `CLAUDE.md` in both repos documents the two endpoints and the `/nearby` changes.

## App changes (`turas`)

| Unit | Change |
|---|---|
| `HomeModel` | `Screen` gains `.stop(StopTarget)`. Focus remembers whether it came from a stop view, and back returns there. Pin taps and stop results call `openStop`. Saves and restores the camera like focus. Pauses `NearbyModel` while a stop view or focus is open |
| `StopModel` (new, @MainActor) | For one stop: fetch `/departures`, 30 s refresh, scene-phase pause, last good rows with timestamp, error and empty state. Injected clock, like `RouteFocusModel` |
| `StationStore` (new, @MainActor) | `/stations` per mode, fetched on first selection of Luas or train, kept in memory for the session |
| `TurasServerService` | `fetchDepartures(stopId:)`, `fetchStations(mode:)` |
| Models | `StopDepartures` (`stop` + `[NearbyDeparture]`), `Station` |
| `StopView` (new) | The bottom panel for `.stop`, built from the `RouteFocusView` header pattern and `DepartureCard` |
| `CentreMarker` (new) | The fixed marker overlay (non-hit-testing) and its lift animation |
| `HomeView` | Marker and `MapCircle` in `.timeline`; pins per mode as above; pin tap opens the stop view; `.stop` panel |
| `NearbyModel` | `firstRow(atStop:)` and `HomeModel.selectPin` removed (pins no longer scroll) |
| `UITestStubServer` | Answers `/departures` and `/stations` |

`RouteFocusTarget` already carries a `FocusStop`, so a row in the stop view opens focus
without a new type.

## Testing

- **Server (Go, `gtfstest` feeds, `httptest` for Luas):**
  - `/nearby`: per-mode radius, `stops` lists all stops in the radius (including ones without
    rows), the 30-stop cap.
  - `/departures`: every route and direction at the stop, the 3-time cap, the window,
    past-midnight trips, cancelled trips, realtime and live sources, Luas both directions and
    a platform ID, 400, 404, 502, 503.
  - `/stations`: Luas platforms merged by code, train stops, sorting, 400 for bus.
  - `stop_code` parsing, including a feed without the column.
- **App (XCTest, fakes and `ManualClock`):**
  - `StopModel`: refresh, pause and resume, last good on error, 404, empty.
  - `HomeModel`: pin tap and stop result open `.stop`; row → focus → back → stop → back →
    timeline with the camera restored; tapping another pin switches stop.
  - `StationStore`: one fetch per mode, retry after failure.
  - Contract decoding for `departures.json` and `stations.json`.
- **UI smoke test:** timeline → tap a pin → stop view → row → route focus → back → back; Luas
  tab shows station pins and opens a Luas stop view. Screenshots as attachments.

## Delivery

1. **Server PR:** `stop_code`, `/nearby` changes, `/stations`, `/departures`, fixtures, docs.
   Additive apart from the radius and the longer `stops` list, which the current app tolerates.
   Merge, then deploy to the VM (not during the AI Gaffer tick at :35).
2. **App PR:** the units above, tests, UI smoke test updates, before and after screenshots.
   Verified against the deployed server.

## Risks and notes

- **Pin density.** Very central spots may reach the 30-stop cap; the nearest 30 are kept.
  Measure on O'Connell Street during review.
- **Luas forecast load.** A Luas stop view issues up to 4 forecast requests (2 routes × 2
  directions at interchange stops), shared with `/nearby` through the Luas service's 30 s cache.
- **Stop numbers.** If TFI's `stop_code` is missing for some stops, the caption shows only the
  distance.
- **Radius change.** Moving bus from 500 m to 300 m shortens some suburban timelines (e.g.
  Knocklyon: 4 routes at 400 m, 2 at 300 m). The marker can be moved, and the circle makes the
  limit visible.
- **Same-name stops in search.** `/search` merges same-name stops within 30 m and keeps one, so
  a stop result opens one side of the road. The other side is a pin tap away on the map.
