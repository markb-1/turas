# Turas

A real-time public transport tracker for iOS, covering bus, Luas, and rail services across Ireland — including Dublin Bus, Bus Éireann, Go-Ahead Ireland, TFI Local Link, Irish Rail (DART, Commuter, InterCity), and both Luas lines. Built on TFI GTFS-RT, Irish Rail, and Luas Forecast APIs.

## Features

- **What's leaving near you** — the timeline shows the next departures around the map centre, one row per route and direction from its nearest stop, with the next three times; drag the map and it follows
- **Stop view** — tap any stop on the map (or a stop search result) to see everything leaving it, one row per route and direction with its next three times; a fixed centre marker and a 300 m (bus) or 800 m (Luas, train) circle show what the timeline is looking at
- **Search** stops, routes and places (Apple Maps, Ireland only) from one box
- **Route focus** — tap a row to see the route's line, its live vehicles and the next times at that stop; flip direction with ⇄
- **Bus, Luas and Train** tabs
- **Live, scheduled, late and cancelled** states, refreshed every 30 s
- **Works without location** — say "Not now" and the map starts at O'Connell Bridge
- **VoiceOver and Dynamic Type** throughout

## Architecture

```
┌──────────────────┐   HTTPS    ┌──────────────────┐
│  iOS app         │ ─────────► │  Turas-Server    │
│  (SwiftUI)       │            │  (Go, Oracle VM) │
└──────────────────┘            └────────┬─────────┘
                                         │ proxies + caches
                                         ▼
                                ┌──────────────────┐
                                │  TFI GTFS-RT     │
                                │  Irish Rail XML  │
                                │  Luas Forecast   │
                                └──────────────────┘
```

The iOS app does no direct transit-API integration. All polling, parsing, rate-limit handling, and arrival-time calculation happens on the [Turas-Server](https://github.com/markb-1/turas-server) backend. The app simply consumes a small JSON API: vehicles, arrivals, and the route and stop lists (cached on the device for 7 days). Route shapes are bundled because the server does not serve them.

This keeps the app:
- Tiny (single HTTP client, no protobuf parser on-device)
- Free of API keys for upstream services
- Shielded from upstream API outages (server caches gracefully)

## Tech stack

- **Language:** Swift 5.9
- **UI:** SwiftUI, MapKit (`Map` + `Annotation`)
- **Min iOS:** 17.0
- **Dependencies:** none
- **Project tool:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth; `Turas.xcodeproj` is generated and not committed

## Building from source

### Prerequisites

- macOS with Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A running instance of [Turas-Server](https://github.com/markb-1/turas-server) (or use the public one if you have credentials)

### Setup

1. **Clone the repo:**
   ```bash
   git clone https://github.com/markb-1/turas.git
   cd turas
   ```

2. **Create your config files:**

   `Configuration/Debug.xcconfig`:
   ```
   TURAS_SERVER_HOST = your-server-host.example.com
   TURAS_SERVER_URL = https:/$()/$(TURAS_SERVER_HOST)
   TURAS_SERVER_API_KEY = your-api-key-here
   ```

   `Configuration/Release.xcconfig`:
   ```
   TURAS_SERVER_HOST = your-server-host.example.com
   TURAS_SERVER_URL = https:/$()/$(TURAS_SERVER_HOST)
   TURAS_SERVER_API_KEY = your-production-key-here
   ```

   > The odd `/$()/` is an Xcode quirk to keep `//` from being treated as a comment in xcconfig files.

3. **Generate the Xcode project:**
   ```bash
   xcodegen generate
   ```

4. **Open in Xcode and run:**
   ```bash
   open Turas.xcodeproj
   ```

### App Transport Security note

When `TURAS_SERVER_URL` is plain `http://`, a build phase (`Supporting/add-ats-exception.sh`) adds an App Transport Security exception for `TURAS_SERVER_HOST` to the built Info.plist; Xcode does not expand build settings in plist keys, so the exception cannot live in the source plist. Set `TURAS_SERVER_HOST` to the host name or IP only so the exception matches, and put any port in `TURAS_SERVER_URL` (e.g. `http:/$()/$(TURAS_SERVER_HOST):8080`). Release builds with an HTTP server get a build warning: serve the API over HTTPS before shipping to the App Store.

### Missing configuration

A Debug build without `TURAS_SERVER_URL` / `TURAS_SERVER_API_KEY` stops at launch with a message pointing here. A Release build shows a "Server not configured" screen instead of crashing.

## Tests

```bash
xcodegen generate
xcodebuild test -project Turas.xcodeproj -scheme Turas \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The `TurasTests` unit tests cover distance and mode helpers, the home, nearby, search and route-focus models, configuration parsing, the server client (through a `URLProtocol` stub), the static-data cache, favourites, VoiceOver text, and decoding of the server's golden JSON in `TurasTests/Fixtures/` (byte-identical copies of the server's `testdata/contract/`).

GitHub Actions (`.github/workflows/ci.yml`) runs the tests on every push and pull request on macOS, with placeholder xcconfig files.

## Project structure

```
Turas/
├── Config.swift              # xcconfig → runtime values
├── Formatting.swift          # arrival and VoiceOver text
├── Models/                   # Vehicle, StopArrival, RouteStop, RouteRef, TransitRoute, …
├── Services/                 # TurasServerService, StaticDataStore, LocationService,
│                             # FavouritesStore, bundled-data loaders
├── Theme.swift               # colour tokens, line colours, metrics
├── ViewModels/               # HomeModel, NearbyModel, SearchModel, StopModel, RouteFocusModel
├── Views/                    # Home/ (map, timeline, search, stop view, route focus) and Components/
└── Resources/                # Bundled GTFS static JSON (stops, shapes, lookups)
Supporting/                   # Info.plist and the ATS build-phase script
TurasTests/                   # unit tests and contract fixtures
```

## Acknowledgements

- [Transport for Ireland](https://www.transportforireland.ie/) — GTFS-RT feed
- [Irish Rail](http://api.irishrail.ie/realtime/) — train realtime API
- [Luas / Transdev](https://luasforecasts.rpa.ie/) — Luas Forecast API

This app is not affiliated with any of the above operators.

## License

[MIT](LICENSE) — feel free to fork and adapt.
