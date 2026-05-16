# Turas

A real-time public transport tracker for iOS, covering bus, Luas, and rail services across Ireland — including Dublin Bus, Bus Éireann, Go-Ahead Ireland, TFI Local Link, Irish Rail (DART, Commuter, InterCity), and both Luas lines. Built on TFI GTFS-RT, Irish Rail, and Luas Forecast APIs.

## Features

- **Live vehicle positions** on the map for buses and trains, refreshed every 30 seconds
- **Real-time arrival predictions** at any stop, combining scheduled times with live delay data
- **Per-mode filtering** — switch between Bus, Luas, and Train
- **Route search** across 378 routes nationwide with directional headsigns
- **Nearest-stop detection** with walking-time estimates
- **Offline-friendly** map rendering — bundled GTFS static data means stops and routes draw instantly

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

The iOS app does no direct transit-API integration. All polling, parsing, rate-limit handling, and arrival-time calculation happens on the [Turas-Server](https://github.com/markb-1/turas-server) backend. The app simply consumes a small JSON API.

This keeps the app:
- Tiny (single HTTP client, no protobuf parser on-device)
- Free of API keys for upstream services
- Shielded from upstream API outages (server caches gracefully)

## Tech stack

- **Language:** Swift 5.9
- **UI:** SwiftUI, MapKit (`Map` + `Annotation`)
- **Min iOS:** 17.0
- **Dependencies:** none
- **Project tool:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth

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

The default xcconfig assumes HTTPS. If your server is HTTP-only (e.g. local development), the `${TURAS_SERVER_HOST}` ATS exception in `Info.plist` will allow it. For App Store submission, use HTTPS.

## Project structure

```
Turas/
├── Config.swift              # xcconfig → runtime values
├── Models/                   # Decodable structs (Vehicle, StopArrival, RouteStop, …)
├── Services/                 # LocationService, TurasServerService, bundled-data loaders
├── ViewModels/MapViewModel   # 30s polling, vehicle filtering
├── Views/                    # SwiftUI views (Map, annotations, sheets, search bar)
└── Resources/                # Bundled GTFS static JSON (stops, shapes, lookups)
```

## Acknowledgements

- [Transport for Ireland](https://www.transportforireland.ie/) — GTFS-RT feed
- [Irish Rail](http://api.irishrail.ie/realtime/) — train realtime API
- [Luas / Transdev](https://luasforecasts.rpa.ie/) — Luas Forecast API

This app is not affiliated with any of the above operators.

## License

[MIT](LICENSE) — feel free to fork and adapt.
