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
- UI-test stub runs keep routes and stops in memory only. Older Debug builds wrote the
  stub's answers to `Caches/StaticData` for 7 days, so a simulator that ran them needs
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
  ViewModels/               HomeModel, NearbyModel, SearchModel, RouteFocusModel (all @MainActor)
  Views/Home/               HomeView, DepartureTimeline, SearchResultsView, RouteFocusView
  Views/Components/         RouteBadge, TimeStack, DepartureCard, StopPin, ModeTabs,
                            SearchField, PrimingCard, StatusBanner
TurasTests/                 XCTest unit tests; Fixtures/ holds the contract JSON;
                            Support/ has ManualClock, waitUntil and the fake sources
TurasUITests/               XCUITest smoke test (screenshots as attachments)
```

### Home screen

`HomeModel.screen` is the single source of truth: `.timeline`, `.search` or
`.focus(RouteFocusTarget)`.

| State | Map shows | Bottom half | Polling |
|---|---|---|---|
| `.timeline` | pins from `/nearby`'s `stops` | mode tabs + rows sorted by first time | `/nearby` 30 s |
| `.search` | unchanged | Stops / Routes / Places (8 each) | none (250 ms debounce) |
| `.focus` | one direction's bundled shape, its vehicles, the stop | route, destination, stop, next times, ⇄ | vehicles + arrivals 30 s |

- The timeline follows the map: `HomeView` reports `onMapCameraChange(.onEnd)`, and
  `NearbyModel` fetches 0.6 s later if the centre moved more than 50 m. Opening focus
  pauses the timeline and saves the camera; closing restores both.
- Location: not determined shows the `PrimingCard` ("Allow location" / "Not now");
  denied, restricted or "Not now" centres on O'Connell Bridge with "Showing city
  centre"; revoked while running keeps the map ("Location is off").
- Errors keep the last rows with "Updated N min ago" and Retry; 503 shows "Turas is
  starting up…" and retries; 429 retries silently on the next tick.
- Search stop rows show their modes and distance from the map centre ("Bus · 1.2 km"),
  which tells same-name stops apart.
- Time is injected (`AppClock`); tests drive it with `ManualClock` and never sleep.

### Route identity

A route is `RouteRef(name, agencyId)`. The agency ID is whatever the server's `/routes`
and `/vehicles` report (the GTFS `routes.txt` `agency_id`: `1` Dublin Bus, `2` Bus
Éireann, `3` Go-Ahead, `10000` LUAS, `IR` Irish Rail, ...); never derive it from a
route_id. Bundled routes carry no agency. Short names (220, 120, 73, W4, ...) can exist
under two agencies, so route search results always show the operator name, and
requests send `agency=` when it is known. A nil agency lets the server choose
(most trips; for arrivals, an agency serving the stop).

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
`Caches/StaticData`, 7-day TTL, refreshed in the background at launch). The bundled
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
| `fetchNearby(lat:lon:mode:)` | `GET /api/v1/nearby?lat=&lon=&mode=` -> `{stops: [{id, name, lat, lon, distance_m}], departures: [{route, agency_id, direction, headsign?, stop_id, distance_m, times: [{trip_id, at, delay, source: live\|realtime\|timetable, cancelled}]}]}` |
| `search(query:mode:)` | `GET /api/v1/search?q=[&mode=]` -> `{stops: [{id, name, lat, lon, modes}], routes: [{name, agency_id, agency_name?, mode, headsign_outbound?, headsign_inbound?}]}` |

Errors are `{"error": "..."}`. 401/403 means a bad key, 429 the per-client rate limit
(10 req/s, burst 20), 503 that the server is still loading its schedule after a restart,
502 (`/nearby?mode=luas`) that every Luas forecast call failed; `ServerErrorText.message`
maps each to a message and the models keep their last good data and retry.

### Contract fixtures

`TurasTests/Fixtures/{vehicles,arrivals,routes,stops,error,nearby,search}.json` are byte-identical
copies of the server's `testdata/contract/*.json`, which the server's
`TestContractFixtures` checks against its encoder. `ContractFixtureTests`
(`TurasTests/ContractFixtureTests.swift`) decodes them here. When the server contract
changes, copy the files over in the same change and keep the copies identical
(`cmp ../turas-server/testdata/contract/X.json TurasTests/Fixtures/X.json`).
