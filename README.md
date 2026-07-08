# EricTube

A native macOS wrapper around the real, logged-in YouTube — with a better
organization layer built alongside YouTube's own interface, not on top of it.

Runs the actual `youtube.com` / `music.youtube.com` in embedded web views,
signed in as the real account (Premium / ad-free preserved). EricTube's value
is everything *around* the player: sessions, subscriptions-by-genre, a real
watch pipeline, kept reference libraries, and a persistent music session.

See [docs/CREATION.md](docs/CREATION.md) for the full design.

## Status

Phase 0 skeleton: master session on youtube.com, persistent login via the
shared `WKWebsiteDataStore`, empty left-rail shell. The creation document
remains the source of truth.

## Building

The Xcode project is generated, not checked in:

```
xcodegen generate
open EricTube.xcodeproj
```

Or from the command line:

```
xcodebuild -project EricTube.xcodeproj -scheme EricTube -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/EricTube.app
```

## Stack

- macOS, Swift + SwiftUI
- `WKWebView` for browse/playback (real logged-in YouTube session)
- YouTube Data API v3 for metadata (subscriptions, playlists)
- Local store (SwiftData) for the organization overlay
