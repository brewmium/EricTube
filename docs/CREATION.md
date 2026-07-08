# EricTube — Creation Document

**Status:** Design (pre-code) · **Date:** 2026-07-08 · **Owner:** Eric (ejh237)

This is the source of truth for what EricTube is and how it should be built.
It's written to be handed to an implementer (likely Fable) to build from.

---

## 1. What this is

A native macOS app that wraps the **real, logged-in YouTube** and layers a
better organization interface *alongside* it — not a reimplementation.

The problem: YouTube's own UX is unusable for how Eric actually uses YouTube.
He runs several modes at once — a home-base browse screen he doesn't want to
disturb, videos queued to watch soon, reference videos kept for years, and
music playing in the background — and today he fakes all of this with a mess of
Chrome tabs, windows, and YouTube's broken playlists.

EricTube keeps the genuine YouTube underneath (so Premium, ad-free, watch
history, and his account all Just Work) and provides the layer YouTube won't:
sessions, subscriptions grouped by genre, a real watch pipeline, kept reference
libraries, and a dedicated persistent music session.

## 2. Guiding principles

- **Real YouTube underneath.** Never reimplement the player or the site. Point
  a web view at `youtube.com` / `music.youtube.com`, logged in as the real
  account. Premium / ad-free is preserved because it's the actual session.
- **Our value is the layer around it** — organization, sessions, findability.
- **No-loss.** Archive, never delete. Old reference material is kept, not lost.
- **One-handed operation.** Magic Mouse right-click needs the Control key, so
  the default UI must not depend on modifier-clicks.
- **Build a touchable skeleton, then pivot.** Several decisions are explicitly
  deferred until Eric can see his real data and touch the UI.

## 3. Platform & technology

- **macOS**, native, **Swift + SwiftUI**.
- **Browse & playback:** `WKWebView` pointed at real YouTube pages. This is
  WebKit, not literally Chrome — irrelevant for YouTube; the point was a real
  logged-in browser session, which Chrome only gave "for free."
- **Single shared `WKWebsiteDataStore`** across every web view → one login,
  shared cookies, persists across launches. Every session is already signed in.
- **Metadata:** YouTube Data API v3 via OAuth on the same Google account —
  `subscriptions.list(mine=true)`, channel details, `playlists` /
  `playlistItems` (to import existing saved lists).
- **Local store:** SwiftData (or JSON) for EricTube's overlay — genre taxonomy,
  favorite tiers, watch-pipeline state, reference state, custom lists.
- **Premium concurrency caveat:** a personal Premium account effectively allows
  one active stream at a time. If music and a video both try to *play*, YouTube
  pauses one. In practice sessions sit paused when not focused; see §9.

## 4. Session model

The core realization: this isn't one browser with tabs. It's **pinned sessions
+ ephemeral watch sessions**, all sharing one login.

- **Music session — pinned, leftmost.** Its own persistent web view
  (`music.youtube.com` or a music playlist). Keeps playing and keeps its
  position while Eric browses or watches elsewhere; he toggles back to it. This
  mirrors reserving the leftmost Chrome tabs for music.
- **Master session — pinned.** One always-alive web view on `youtube.com` in
  YouTube's native interface. This is home base for browsing/discovery. It
  **never reloads or loses its place** because something else was watched.
- **Watch sessions — ephemeral.** Real `youtube.com/watch` pages spun up on
  demand to actually watch a video, each independent of the master. These are
  the "tabs" in the rail: flip between them, close when done.

Order in the rail: **Music (pinned) · Master (pinned) · watch tabs (ephemeral).**

## 5. The two axes (core data model)

Everything Eric saves splits cleanly into two independent axes. Keeping them
separate is exactly what YouTube fails to do.

### Axis 1 — Library: *what it's about*

Hierarchical, because he doesn't have flat genres, he has lists of lists:

```
Home Projects            <- genre (meta-category)
  Deck rebuild           <- list
  Garage                 <- list
Creative Hobbies
  Woodturning
  ...
```

Genre -> List -> Items (videos). Channels are also tagged into genres.
**The exact list/sub-list mechanics are deferred** until existing playlists are
imported and visible (see §8, §9) — e.g. the woodworking channel is a mix of
"interesting," "want to make," and "shop upgrades," and how that subdivides is a
decision to make with real data in front of us.

### Axis 2 — Watch pipeline: *when I'll watch it*

A queued video sits in one tier and is promoted/demoted along:

**Watch Next → Watch Later → Maybe Someday**

### Reference lifecycle (a state, cutting across the above)

Some saved videos aren't "to watch" — they're **knowledge kept for years**.
Example: the Prius HV-battery videos — the fix is done, but they're kept for
five-years-from-now; meanwhile the touch-screen set is active. So items/lists
carry an **Active ↔ Archived-reference** state. **Archived never means deleted.**

A saved video therefore carries: its **list membership** (what it's about), a
**pipeline tier** if it's queued to watch (when), and an **active/archived**
state (live vs kept reference). Filter by any of these.

## 6. Channels / subscriptions

- Grouped by **genre** — this is the baseline findability that YouTube lacks.
- Two explicit favorite tiers on top so the real favorites don't drown:
  - **Shortlist** — "channels I want to find again."
  - **Favorites** — the actual top ones.
- Starring applies to **channels**; marking-to-watch applies to **videos**.
- (Open: 2 tiers vs 3 levels of prominence — see §9.)

## 7. UI / layout

- **Left rail (segmented):**
  - **Sessions** — Music, Master, and live watch tabs.
  - **Subscriptions** — channels grouped by genre, with shortlist / favorites.
  - **Library** — the genre → list tree.
- **Top bar:** the watch pipeline as a left-to-right switch —
  **Next / Later / Maybe** — plus search and a quick "add current video to…".
- **Item rows:** a **Play** (watch-now) button plus a **"…" kebab menu** for
  per-entry actions (move tier, assign to list, archive, …). Popups are
  welcome; the action set is fleshed out later (§9).
- **Interaction — one-handed:** hovering a video reveals a small
  **"watch in new tab"** affordance (one hand, one click, no Control key). A
  normal click browses the master as usual. **No modifier-click by default**
  (Magic Mouse concern); ⌘-click may be *added* later if wanted.

## 8. Data sources & the import-first step

- **YouTube Data API v3** (OAuth, read scopes): pull subscriptions, channels,
  and — critically — **existing playlists and their contents**.
- **Import first, decide later.** The first substantive milestone is surfacing
  everything Eric already has (all playlists + items) so the list/sub-list
  structure (§5) and channel tiers (§6) can be decided against real data.
- **Local overlay store:** EricTube's own metadata (genres, lists, tiers,
  favorites, reference state) lives locally on top of YouTube's data.

## 9. Deferred decisions / open questions

- **List/sub-list mechanics** — decided after playlist import (§8).
- **Kebab action set** — the full list of per-entry actions (§7).
- **Channel prominence** — two tiers (shortlist + favorites) vs three levels.
- **Music source** — YouTube Music vs a curated playlist as the music session.
- **Concurrency UX** — how to handle Premium's one-active-stream limit when
  music + a video are both loaded (auto-pause the unfocused one?).
- **⌘-click** — whether to add it later as a power-user alternative to hover.

## 10. Build roadmap (touchable skeleton first)

- **Phase 0 — Skeleton.** SwiftUI app + window; a `WKWebView` master session on
  `youtube.com`; login persists across launches; empty left-rail shell.
- **Phase 1 — Sessions.** Pinned Music + Master sessions, ephemeral watch tabs,
  session switching, the hover "watch in new tab" affordance.
- **Phase 2 — Import & see.** OAuth to the Data API; pull subscriptions +
  playlists + items; display them raw. (The "see everything" milestone.)
- **Phase 3 — Library layer.** Genre taxonomy; assign channels/videos to
  genre → list; Active/Archived reference state.
- **Phase 4 — Watch pipeline.** Next / Later / Maybe tiers with promote/demote;
  the top bar.
- **Phase 5 — Channel tiers + per-entry actions.** Shortlist/favorites; the
  kebab action set; refinement once Eric has touched it.
