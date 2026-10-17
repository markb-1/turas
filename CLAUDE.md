# Turas iOS app: notes for coding agents

SwiftUI app (iOS 17+, Swift 5.9 language mode, no dependencies) showing live Dublin and
Irish buses, Luas and trains. All transit data comes from the Turas server
(github.com/markb-1/turas-server); the app bundles only fallbacks and route shapes.

## Build and test

```bash
brew install xcodegen
# Create Configuration/Debug.xcconfig and Release.xcconfig (see README); never commit them.
xcodegen generate                      # project.yml is the source of truth
xcodebuild test -project Turas.xcodeproj -scheme Turas \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

- `Turas.xcodeproj` is generated and gitignored. Edit `project.yml`, never the project.
- CI (`.github/workflows/ci.yml`, macos-latest) writes placeholder xcconfig files,
  runs `xcodegen generate` and `xcodebuild test` on the newest iPhone simulator.
- Never commit `Configuration/*.xcconfig`: they hold the server URL and API key.
- `Supporting/Info.plist` is shared by both configurations and has no ATS settings. When
  `TURAS_SERVER_URL` is `http://`, the `Supporting/add-ats-exception.sh` build phase adds
  an exception for `TURAS_SERVER_HOST` to the built plist (Xcode does not expand build
  settings in plist keys, so `$(TURAS_SERVER_HOST)` as a source key never matches).
  Release builds warn while the server is plain HTTP.
- UI tests (`-only-testing:TurasUITests`) launch the app with `TURAS_UITEST_STUB=1`, so
  Debug builds answer from `UITestStubServer` and a canned place search (no server or
  network). `TEST_RUNNER_TURAS_UITEST_LIVE=1 xcodebuild test ...` runs them against the
  real server and MapKit. Set the simulator's location first
  (`xcrun simctl location <id> set 53.3441,-6.2595`); to see the priming card again,
  `xcrun simctl privacy <id> reset location com.turas.Turas`.
- Stub runs keep routes and stops in memory only. Older Debug builds wrote the stub's
  answers to `Caches/StaticData` for 7 days, so a simulator that ran them needs
  `xcrun simctl uninstall <id> com.turas.Turas` once before a live run.
- Some agent environments have no Swift toolchain. If you cannot compile, say so, keep
  changes small and reviewable, and rely on CI.

## Architecture

```
Turas/
  TurasApp.swift            entry point; AppDependencies creates the services once
  Config.swift              Info.plist -> ServerConfig (nil -> ServerNotConfiguredView)
  Theme.swift               colour tokens (Assets.xcassets, light/dark), line colours, metrics
  Formatting.swift          departure/arrival text, VoiceOver labels, error text (unit tested)
  Models/                   Vehicle, StopArrival, RouteStop, RouteShape, RouteRef, TransitRoute,
                            TransportMode, Nearby (NearbyResponse...), Search (SearchResponse...),
                            Stop (Station, StopInfo, StopDepartures, StopTarget),
                            RouteLabelling (shared operatorLabel/headsign(for:) for
                            TransitRoute and RouteSearchResult)
  Services/
    TurasServerService      actor; the only HTTP client (x-api-key header)
    StaticDataStore         actor; routes/stops from server -> disk cache -> bundle
    RouteStopService        actor; bundled route_stops.json
    RouteShapeService       actor; bundled route_shapes.json
    PlaceSearchService      PlaceSearching; MapKitPlaceSearch (MKLocalSearch) limited to Ireland,
                            addresses and points of interest as two requests
    LocationService         @MainActor CLLocationManager wrapper; LocationProviding
    AppClock                now + sleep, injected into the models
    FavouritesStore         @MainActor recents and starred routes (no UI yet)
    StationStore            @MainActor Luas and train station lists from /stations, one fetch per mode per session
  ViewModels/               HomeModel, NearbyModel, SearchModel, StopModel, RouteFocusModel (all @MainActor)
  Views/Home/               HomeView, DepartureTimeline, SearchResultsView, StopView, RouteFocusView
  Views/Components/         RouteBadge, TimeStack, DepartureCard, StopPin, CentreMarker, ModeTabs,
                            SearchField, PrimingCard, StatusBanner
TurasTests/                 XCTest unit tests; Fixtures/ holds the contract JSON;
                            Support/ has ManualClock, waitUntil and the fake sources
TurasUITests/               XCUITest smoke test (screenshots as attachments)
```

### Home screen

`HomeModel.screen` is the single source of truth: `.timeline`, `.search`, `.stop(StopTarget)`
or `.focus(RouteFocusTarget)`.

| State | Map shows | Bottom half | Polling |
|---|---|---|---|
| `.timeline` | a fixed centre marker (drawn in `Theme.ink`), a faint circle of the mode's radius (300 m bus, 800 m Luas/train), and pins from `HomeModel.mapPins`: bus stops from `/nearby`'s `stops`, Luas/train stations from `/stations` | mode tabs + rows sorted by first time | `/nearby` 30 s |
| `.search` | unchanged | Stops / Routes / Places (8 each) | none (250 ms debounce) |
| `.stop` | the same pins, centred on the stop with its pin highlighted (added if it is not among them); no marker or circle | stop name, "Stop 7602 · 240 m" (the "Stop <code>" part for bus only; Luas and train show just the distance), one row per route and direction with its next 3 times (`StopModel`) | `/departures` 30 s |
| `.focus` | one direction's bundled shape, its vehicles, the stop | route, destination, stop, next times, ⇄ | vehicles + arrivals 30 s |

- The timeline follows the map: `HomeView` reports `onMapCameraChange(.onEnd)`, and
  `NearbyModel` fetches 0.6 s later if the centre moved more than 50 m. The marker lifts
  while the map moves (`.continuous`) and drops when it settles. Opening the stop view or
  route focus pauses the timeline and saves the camera; closing the last of them restores both.
- Tapping a pin or a stop search result opens the stop view (`HomeModel.openStop`); tapping
  another pin switches stop. A stop view has one mode (the tab's, or the search result's own
  mode when the tab's does not serve it; the tab is not changed). A row opens route focus
  over the stop view (the stop model pauses); back returns to the stop view, back again to the
  timeline. A 404 from `/departures` shows "This stop is no longer in the timetable" and ends
  polling; an empty answer shows "Nothing leaving in the next 90 minutes".
- Luas and train pins come from `StationStore` (`/stations`, fetched on the first selection of
  the mode and kept for the session). While it loads or after it fails, `/nearby`'s stops are
  the pins and the next selection of the mode fetches again. Bus never asks for stations.
- Location: not determined shows the `PrimingCard` ("Allow location" / "Not now");
  denied, restricted or "Not now" centres on O'Connell Bridge with "Showing city
  centre"; revoked while running keeps the map ("Location is off"). Returning to the
  foreground with authorisation asks for a fresh fix; the stop view's distance (which
  follows each new fix) and route focus's walking time use it only while authorised.
- Errors keep the last rows with "Updated N min ago" and Retry; 503 shows "Turas is
  starting up…" and retries; 429 retries silently on the next tick.
- Each render drops times more than 30 s past (`Upcoming`) in the timeline, stop view and
  route focus, hides rows with none left and re-sorts by the new first time, so kept rows
  never turn into a column of "Due".
- Search stop rows show their modes and distance from the map centre ("Bus · 1.2 km"),
  which tells same-name stops apart.
- A realtime or live first time 2 or more minutes late shows "3 min late" in `Theme.late`
  ahead of the later times (timeline and stop view), and its VoiceOver label says so.
- Shown times re-format every 5 s (`DepartureFormatting.tick`) against the model's
  clock (`now()`), not the `TimelineView` date, so fresh rows are never formatted late.
- Time is injected (`AppClock`); tests drive it with `ManualClock` and never sleep.

### Route identity

A route is `RouteRef(name, agencyId)`. The agency ID is whatever the server's `/routes`
and `/vehicles` report (the GTFS `routes.txt` `agency_id`: `1` Dublin Bus, `2` Bus
Éireann, `3` Go-Ahead, `10000` LUAS, `IR` Irish Rail, ...); never derive it from a
route_id. Bundled routes carry no agency. Short names (220, 120, 73, W4, ...) can exist
under two agencies, so route search results always show the operator name, and
requests send `agency=` when it is known. A nil agency lets the server choose
(most trips; for arrivals, an agency serving the stop).

A timeline or stop view row (`NearbyDeparture.id`) is agency, route, direction and
headsign: the server splits a Luas direction by destination, so two rows can share route
and direction. A row opens route focus with its own headsign.

## Bundled data

`Turas/Resources/` holds data pre-processed from the TFI static GTFS feed (the scripts
are not in the repo):

- `route_lookup.json`: raw route_id -> short name (412 routes). It predates TFI's current
  free-form route_ids, so its `5242_`/`5422_` prefixes give the mode but its agency
  prefixes are not the server's agency IDs and are ignored.
- `headsign_lookup.json`: `"<name>_<direction>"` -> destination.
- `route_stops.json`: short name -> `[{direction, stops: [{id, name, lat, lon, seq, t}]}]`.
  Keyed by name only, so shared names merge both agencies' entries.
- `route_shapes.json`: short name -> `[{direction, coordinates: [[lat, lon]]}]`,
  Douglas-Peucker simplified. The server does not serve shapes; these stay bundled.
  Routes 447 and 448 have stops but no shapes.

Routes and stops come from the server when possible (`StaticDataStore`, JSON cache in
`Caches/StaticData`, 7-day TTL, refreshed in the background at launch and on return to
the foreground). The bundled
routes and stops are the fallback when the cache is empty and the network fails.

## Server contract

Base URL and key come from `TURAS_SERVER_URL` / `TURAS_SERVER_API_KEY`. Every request
sends `x-api-key`. Dates are RFC 3339; the decoder accepts whole or fractional seconds.

| Call | Endpoint |
|---|---|
| `fetchVehicles(mode:)` | `GET /api/v1/vehicles?mode=bus\|luas\|train` -> `[Vehicle]` |
| `fetchRoutes(mode:)` | `GET /api/v1/routes?mode=` -> `[{name, agency_id, agency_name?, headsign_outbound?, headsign_inbound?, directions}]` |
| `fetchStops(route:agency:direction:)` | `GET /api/v1/stops?route=&direction=[&agency=]` -> `[RouteStop]` |
| `fetchArrivals(stopId:route:direction:)` | `GET /api/v1/arrivals?stop_id=&route=&direction=[&agency=]` -> `[StopArrival]` |
| `fetchLuasArrivals(stopId:direction:routeName:)` | `GET /api/v1/luas/arrivals?stop_id=&direction=&route=` |
| `fetchNearby(lat:lon:mode:)` | `GET /api/v1/nearby?lat=&lon=&mode=` -> `{stops: [{id, name, lat, lon, distance_m}], departures: [{route, agency_id, direction, headsign?, stop_id, distance_m, times: [{trip_id, at, delay, source: live\|realtime\|timetable, cancelled}]}]}`; `stops` is every stop of the mode within the radius (300 m bus, 800 m Luas/train), nearest first, at most 30 |
| `fetchDepartures(stopId:)` | `GET /api/v1/departures?stop_id=` -> `{stop: {id, name, code?, lat, lon, modes}, departures: [...]}` (rows as `/nearby`, `distance_m` 0, `stop_id` the requested stop; Luas: both platforms); 404 `unknown stop`; 502 for a Luas stop when every forecast call failed or it has no forecast code |
| `fetchStations(mode:)` | `GET /api/v1/stations?mode=luas\|train` -> `[{id, name, lat, lon}]` (one per Luas stop, platforms merged into the lower stop ID); 400 for bus |
| `search(query:mode:)` | `GET /api/v1/search?q=[&mode=]` -> `{stops: [{id, name, lat, lon, modes}], routes: [{name, agency_id, agency_name?, mode, headsign_outbound?, headsign_inbound?}]}` |

Errors are `{"error": "..."}`. 401/403 means a bad key, 429 the per-client rate limit
(10 req/s, burst 20), 503 that the server is still loading its schedule after a restart,
502 (`/nearby?mode=luas`, `/departures` for a Luas stop) that the Luas forecasts are
unavailable; `ServerErrorText.message` maps each to a message and the models keep their
last good data and retry.

### Contract fixtures

`TurasTests/Fixtures/{vehicles,arrivals,routes,stops,error,nearby,search,departures,stations}.json` are byte-identical
copies of the server's `testdata/contract/*.json`, which the server's
`TestContractFixtures` checks against its encoder. `ContractFixtureTests`
(`TurasTests/ContractFixtureTests.swift`) decodes them here. When the server contract
changes, copy the files over in the same change and keep the copies identical
(`cmp ../turas-server/testdata/contract/X.json TurasTests/Fixtures/X.json`).
