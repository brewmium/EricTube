# EricTube

A native macOS wrapper around the real, logged-in YouTube — with a better
organization layer built alongside YouTube's own interface, not on top of it.

Runs the actual `youtube.com` / `music.youtube.com` in embedded web views,
signed in as the real account (Premium / ad-free preserved). EricTube's value
is everything *around* the player: sessions, subscriptions-by-genre, a real
watch pipeline, kept reference libraries, and a persistent music session.

See [docs/CREATION.md](docs/CREATION.md) for the full design.

## Status

Design phase. No code yet — the creation document is the source of truth.

## Stack

- macOS, Swift + SwiftUI
- `WKWebView` for browse/playback (real logged-in YouTube session)
- YouTube Data API v3 for metadata (subscriptions, playlists)
- Local store (SwiftData) for the organization overlay
