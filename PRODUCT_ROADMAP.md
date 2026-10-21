# Signage Studio product roadmap

Signage Studio should cover the core jobs handled by mature digital-signage platforms while keeping its own product identity and implementation. The target is functional coverage, not a copy of ScreenCloud's branding, source code, or proprietary assets.

## Current foundation

- Native Android TV player with pairing, heartbeat, offline playback, auto-start, remote sync/restart, live content feeds, multi-zone layouts, schedules, and temporary screen casts.
- Admin screens for screen inventory, groups, live status, playlists, channels, media, team roles, and audit activity.
- Supabase-backed authentication, row-level access policies, storage, and GitHub Pages hosting.
- Live TV screenshots are being added; the player must connect to the network before screenshots and live status can be confirmed on the physical TV.

## Product coverage

| Area | Current coverage | Next product milestone |
| --- | --- | --- |
| Screens and devices | Pairing, groups, online status, previews, bulk actions, remote restart/sync, device diagnostics, and a scheduled online/offline transition history | Add actionable alerts and remote troubleshooting actions |
| Content | Text, image, video, web links, JSON feeds, reusable library | Robust upload pipeline, expiry/approval, reusable native app instances |
| Playlists and channels | Reusable playlists, recurring schedules, priority, multi-zone, weekly per-screen channel calendar | Drag ordering, preview before publish, schedule conflict visibility, playlist-level calendar entries |
| Live data and apps | Native Pulse/JSON feed and web dashboard support; reusable Pulse connections with protected credentials; per-screen feed status, HTTP/network errors, last success and source host | Expand connector catalog with OAuth-backed business apps, refreshable credentials, and setup health checks |
| Remote screen operations | Set content, temporary cast, sync and restart | Screenshot refresh on demand, remote settings, support bundle, actionable alerts |
| Team and organization | Roles, screen groups, group-scoped access, audit log | Spaces/locations, granular content permissions, invitations and activity export |
| Playback reporting | Reported player content transitions, per-screen history, estimated display duration, filters and CSV export | Aggregated proof-of-play analytics, per-content totals and scheduled reports |
| Player fleet | Android TV player, offline cache and autostart | Managed kiosk mode, player update channel, compatibility matrix and recovery workflow |
| Creation tools | Structured text and feed presentation | Template-based canvas/editor and reusable branded layouts |

## Delivery order

1. Stabilize the player-to-admin operations loop: confirmed heartbeats, live previews, duplicate-screen cleanup, clear online/offline states.
2. Make content publishing dependable: library lifecycle, preview, schedule visibility, and predictable caching/offline behavior.
3. Add operational reporting: playback proof, screen health history, alerts, and exports.
4. Expand live integrations through a documented connector model; keep secrets in protected storage and show failures clearly.
5. Add organization-scale workflows: locations/spaces, granular access, approval, and multi-screen publishing.
6. Add creation and fleet-management tools after the publishing and reporting foundations are reliable.

## Product rules

- One physical player should map to one screen record; pairing and recovery must preserve that record.
- A screen should always identify the active channel/playlist/item and the time of its last successful heartbeat.
- Publishing must distinguish saved drafts from content actually acknowledged by a player.
- Playback history records what the player reports; it must not claim independent visual verification of the TV panel.
- Native feeds should refresh without browser-cache dependence and keep the last valid result for offline use.
- Player-facing secrets stay server-side; team access is enforced in the database.
