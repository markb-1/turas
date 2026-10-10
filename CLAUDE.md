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
- Some agent environments have no Swift toolchain. If you cannot compile, say so, keep
  changes small and reviewable, and rely on CI.

## Architecture

```
Turas/
  TurasApp.swift            entry point; AppDependencies creates the services once
  Config.swift              Info.plist -> ServerConfig (nil -> ServerNotConfiguredView)
  Formatting.swift          arrival text and VoiceOver labels (unit tested)
  Models/                   Vehicle, StopArrival, RouteStop, RouteShape, RouteRef,
                            TransitRoute, TransportMode, NearbyStop
  Services/
    TurasServerService      actor; the only HTTP client (x-api-key header)
    StaticDataStore         actor; routes/stops from server -> disk cache -> bundle
    RouteStopService        actor; bundled route_stops.json, nearby-stop search
    RouteShapeService       actor; bundled route_shapes.json
    LocationService         @MainActor CLLocationManager wrapper (async/await)
    FavouritesStore         @MainActor recents (max 20) and starred routes, UserDefaults
  ViewModels/MapViewModel   @MainActor; selection state machine, polling, camera
  Views/                    ContentView (map), RouteSearchBar, sheets, annotations
TurasTests/                 XCTest unit tests; Fixtures/ holds the contract JSON
```

Large JSON is decoded inside actors (off the main thread) and preloaded when the map
appears. Views talk only to `MapViewModel` (plus `FavouritesStore` for the star and
recent rows) and `TurasServerService` (arrivals sheet).

### Selection state machine

`MapViewModel.selection: RouteSelection` is the single source of truth. `searchText`
only backs the text field.

| State | Map shows | Polling |
|---|---|---|
| `.idle` | nearby stops (500 m, bundled data) | off |
| `.route(RouteRef)` | all shapes of the route, its vehicles, direction picker | vehicles every 30 s |
| `.routeAndDirection(RouteRef, direction:)` | one direction's shape, stops, vehicles; nearest stop | vehicles every 30 s |

- `selectRoute`, `selectDirection`, `clearDirection`, `clearSearch`, `selectMode`,
  `submitSearch` (Done/return: selects the route the text uniquely identifies, so "39a"
  selects "39A"; otherwise stays in search) and `selectSaved` (recent/starred) are the
  transitions.
- Polling stops when the scene goes to the background and restarts on `.active` when a
  route is selected. An empty vehicle list replaces the old one; errors keep it.
- Direction options are the union of shape, bundled-stop and server directions; without a
  headsign they read "Direction 0/1".
- Stop sheets refetch arrivals every 30 s while open and support pull to refresh.

### Route identity

A route is `RouteRef(name, agencyId)`. The agency ID is whatever the server's `/routes`
and `/vehicles` report (the GTFS `routes.txt` `agency_id`: `1` Dublin Bus, `2` Bus
Éireann, `3` Go-Ahead, `10000` LUAS, `IR` Irish Rail, ...); never derive it from a
route_id. Bundled routes carry no agency. Short names (220, 120, 73, W4, ...) can exist
under two agencies, so the search chips show the operator name when a
name is ambiguous, and requests send `agency=` when it is known. A nil agency lets the
server choose (most trips; for arrivals, an agency serving the stop).

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
routes and stops are the fallback when the cache is empty and the network fails, and the
source for nearby-stop search.

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

Errors are `{"error": "..."}`. 401/403 means a bad key, 429 the per-client rate limit
(10 req/s, burst 20), 503 that the server is still loading its schedule after a restart;
`MapViewModel.userFriendlyError` maps each to a message and polling retries.

### Contract fixtures

`TurasTests/Fixtures/{vehicles,arrivals,routes,stops,error}.json` are byte-identical
copies of the server's `testdata/contract/*.json`, which the server's
`TestContractFixtures` checks against its encoder. `ContractFixtureTests`
(`TurasTests/ContractFixtureTests.swift`) decodes them here. When the server contract
changes, copy the files over in the same change and keep the copies identical
(`cmp ../turas-server/testdata/contract/X.json TurasTests/Fixtures/X.json`).
