# Signage Studio product roadmap

Signage Studio should cover the core jobs handled by mature digital-signage platforms while keeping its own product identity and implementation. The target is functional coverage, not a copy of ScreenCloud's branding, source code, or proprietary assets.

See [SCREENCLOUD_PARITY.md](SCREENCLOUD_PARITY.md) for the capability map, delivery sequence, and product guarantees. The active development track is conflict-safe scheduling and authoring, then connector coverage, fleet lifecycle, and organization controls.

## Current foundation

- Native Android TV player with pairing, heartbeat, offline playback, auto-start, remote sync/restart, live content feeds, multi-zone layouts, schedules, and temporary screen casts.
- Admin screens for screen inventory, groups, live status, playlists, channels, media, team roles, and audit activity.
- Supabase-backed authentication, row-level access policies, storage, and GitHub Pages hosting.
- Live TV screenshots and health reporting are available when the player is online; a screenshot confirms the app render, not the physical panel or TV power state.

## Product coverage

| Area | Current coverage | Next product milestone |
| --- | --- | --- |
| Screens and devices | Pairing/recovery, stable player identity, unique active names, grouped legacy profiles, one-TV selectors and bulk actions, groups, locations, online status, previews, remote restart/sync, device diagnostics, scheduled online/offline history, player publication acknowledgements, and downloadable support bundles | Safely merge or archive legacy duplicate profiles; add guided remote troubleshooting |
| Content | Text, image, video, web links, JSON feeds, reusable library, expiring media, versioned per-screen publishing snapshots, player revision acknowledgements, and editor-to-admin approval | Processing/transcoding, document/PDF support, reusable native app instances |
| Playlists and channels | Reusable playlists with atomic drag or keyboard ordering, recurring schedules, priority, multi-zone, weekly per-screen channel calendar, inline channel and screen schedule editing, atomic channel playlist reordering, draft preview, version history, restore, queued player sync, delivered revision status, per-screen bulk publishing, and editor approval requests for selected screens | Playlist-level calendar entries and automatic conflict resolution suggestions |
| Live data and apps | Native Pulse/JSON feed and web dashboard support; reusable Pulse connections with protected credentials; per-screen feed status, HTTP/network errors, last success and source host | Expand connector catalog with OAuth-backed business apps, refreshable credentials, and setup health checks |
| Remote screen operations | Set content, temporary cast and multi-screen text/image/video broadcasts with scheduled start, offline-safe expiry, cancel, per-screen reported playback receipts and 30-day history, sync, restart, and on-demand screenshot capture | Remote settings, guided troubleshooting |
| Team and organization | Admin/editor/viewer/group-member roles, invitations, screen groups, location-scoped screen/content read access, audit log | Granular creator/publisher/manager permissions, activity export, SSO and optional custom roles |
| Playback reporting | Reported player content transitions, offline-aware playback segments, per-screen history, estimated display duration, filters and CSV export | Aggregated proof-of-play analytics, per-content totals and scheduled reports |
| Player fleet | Android TV player, offline cache and autostart | Managed kiosk mode, player update channel, compatibility matrix and recovery workflow |
| Creation tools | Structured text and feed presentation | Template-based canvas/editor and reusable branded layouts |

Screen draft preview and append-only restore are available in the screen cards; restoring an older revision queues it as a new publication and leaves editable drafts untouched. Editors can submit an immutable snapshot for admin approval; approving publishes exactly that snapshot even if the working draft changes later.

## Delivery order

1. Stabilize the player-to-admin operations loop: confirmed heartbeats, live previews, duplicate-screen cleanup, clear online/offline states, and actionable operational alerts with admin-configurable thresholds.
2. Make content publishing dependable: library lifecycle, schedule visibility, and predictable caching/offline behavior.
3. Add operational reporting: playback proof, screen health history, alerts, and exports.
4. Expand live integrations through a documented connector model; keep secrets in protected storage and show failures clearly.
5. Extend organization workflows: granular creator/publisher/manager access, exportable audit, SSO, and multi-screen publishing.
6. Add creation and fleet-management tools after the publishing and reporting foundations are reliable.

## Product rules

- One physical player should map to one screen record; pairing and recovery must preserve that record.
- A screen should always identify the active channel/playlist/item and the time of its last successful heartbeat.
- Publishing must distinguish saved drafts from content actually acknowledged by a player.
- Playback history records what the player reports; it must not claim independent visual verification of the TV panel.
- Native feeds should refresh without browser-cache dependence and keep the last valid result for offline use.
- Player-facing secrets stay server-side; team access is enforced in the database.
