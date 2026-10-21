# Signage Studio capability target

This document uses ScreenCloud's publicly described product areas as a capability benchmark. Signage Studio will use its own code, product identity, layouts, and interaction design. The goal is equivalent customer outcomes where the current TV/player stack supports them, with explicit boundaries where managed hardware or third-party integrations are required.

## Capability map

| Product area | Signage Studio today | Work to reach a mature platform |
| --- | --- | --- |
| Screen fleet | Native Android TV player, pairing/recovery, locations and groups, online state, current item, live captures, diagnostics, duplicate-profile grouping in TV views, categorized admin workspaces, bulk sync/restart, deduplicated pending operations | Safe merge/archive for legacy duplicate profiles; remote device settings and recovery; email/webhook alert routing |
| Content library | Text, image, video, web, JSON/Pulse feeds, tags, folders, reuse, expiry, resumable uploads, file replacement and restore history | Processing/transcoding, document/PDF support, and TV-side codec validation |
| Authoring | Structured text/feed presentation; scheduled draft preview for the main area and ticker/side zone; configurable side-panel width and ticker height per screen | Screen canvas/editor, reusable brand templates, safe-area controls, reusable app configurations |
| Playlists | Ordered or randomized reusable playlists, screen assignment, multi-zone support, playlist copy including slide schedule and ordering, automatic immutable snapshots and copy-from-history recovery | Destructive in-place rollback is intentionally avoided because playlists and library items can be shared |
| Channels and scheduling | Reusable channels, playlist priority, recurring schedules, calendar with one-click unique-priority suggestions for equal-rank overlaps, temporary casts, expiry, draft preview, atomic per-screen publish and append-only version restore | Explicit discard, broader cross-screen conflict resolution and richer recurrence/availability rules |
| Apps and integrations | Native Pulse and JSON feeds with offline cache, web dashboards that reload in the player on a configurable no-cache interval, real-data Pulse draft preview with server-side credentials and interval-based feed refresh | Documented connector framework, OAuth integrations, Microsoft 365/Google Workspace/calendar/social/streaming connectors, connection health and credential renewal |
| Publishing and broadcast | Per-screen versioned publishing, queued sync, draft preview, publication history, restore-as-new-version, player acknowledgement of locally stored revisions, editor-to-admin approval requests over immutable snapshots, bulk publish/request for selected screens, and scheduled text/image/video broadcasts with direct screen targeting and location/group filters, per-screen reported playback receipts and a 30-day history | Rich emergency broadcast campaigns, staged rollout and long-term consolidated delivery reporting |
| People and governance | Admin/editor/viewer/group-member roles, invitations, groups, location-scoped screen/content read access, audit log | Creator/publisher/manager permissions; approval rules by location; SSO and optional custom roles; audit export |
| Operations and proof | Reported playback transitions with offline gaps bounded at the last heartbeat, reconnect segments, history, CSV, screen health timeline, feed errors | Aggregated proof-of-play, delivery acknowledgement, scheduled reports, operational dashboards, alert routing to email/webhooks, and alert escalation |
| Player fleet lifecycle | Android TV APK, offline cache, autostart, sync/restart, diagnostics | Managed kiosk/device-owner mode, signed update channels, staged rollout, rollback/recovery, broader hardware support and remote device management |
| Extensibility | Supabase-backed player APIs and protected integrations | Versioned public API/webhooks, custom app SDK/runtime, connector documentation, organization audit export |

## Delivery sequence

1. **Safe publishing:** separate working changes from live content; preview a channel; publish atomically; retain the last published version; restore or discard drafts; show which screens acknowledged the new version.
2. **Locations and governance:** extend location-scoped read access to granular editing, publishing, and approval permissions while preserving existing group grants.
3. **Creation and media reliability:** processing/transcoding, document/PDF support, content validation and preview, native layouts/templates, and a clear preview for the target TV aspect ratio.
4. **Broadcast and workflow:** approval states, publisher permissions, emergency/temporary announcements, target selection, expiry, and delivery receipts.
5. **Integrations and APIs:** connector contract, credential lifecycle, health diagnostics, prioritized OAuth integrations, webhooks, and public API documentation.
6. **Fleet operations and reporting:** device settings where Android permits them, managed kiosk deployment, safe player updates, proof-of-play aggregates, exports, and alert routing.

## Product guarantees

- Draft edits never reach players until published.
- Publishing is atomic from a player's point of view and leaves its previous valid version available offline.
- The admin UI distinguishes saved, published, delivered, and currently reported playback states.
- A player screenshot is evidence of what its app rendered at capture time; it does not prove the physical panel was visible or powered.
- Access boundaries are enforced by database policies, not only by hiding UI controls.
- Credentials for connected systems remain server-side and are never embedded in a public page, player URL, or APK.
- Device management claims are limited to controls supported by the actual TV hardware, Android version, and provisioning mode.

## References

- [ScreenCloud product features](https://screencloud.com/features)
- [ScreenCloud Studio channels](https://help.screencloud.com/en/articles/10120125-screencloud-studio-channels)
- [Channels setup and scheduling](https://help.screencloud.com/en/articles/10110358-channels-setup-guide-scheduling-content-using-layouts-and-adding-music-to-your-screens)
- [ScreenCloud media library](https://help.screencloud.com/en/articles/10120107-screencloud-studio-media-library)
- [People, groups, and spaces](https://help.screencloud.com/en/articles/10120942-people-groups-and-spaces-managing-users-teams-with-screencloud)
- [Digital signage device management](https://help.screencloud.com/en/articles/12569847-what-are-screencloud-s-capabilities-for-managing-and-controlling-tv-displays-across-locations-and-devices)
