# Live TV prototype

A native, Debug-only Live TV destination for iterating on a physical Apple TV,
iPhone and iPad. It combines configured IPTV playlists, authorized server
channels and scheduled library channels, using Plozz's existing AetherEngine
(`PlozzigenVideoEngine`) integration.
It lives
inside Plozz's actual navigation instead of replacing the application root.
Release navigation and onboarding remain unchanged.

## Run

Generate the project using the normal wrapper:

```sh
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
tools/generate-project.sh
```

Open `Plozz.xcodeproj` and run a Debug **Plozz** build on Apple TV or
**PlozziOS** on iPhone/iPad. Choose a media server or **Live TV / IPTV** during
first-run setup, then complete the ordinary profile and appearance steps.
Standalone IPTV requires no media-server account. Select **Live TV** in
navigation. Apple TV supports the top tabs, native sidebar and custom
navigation rail variations; iPhone/iPad expose the same destination in their
tab shell. Device installation must be authorized; a build alone does not
install anything.

For isolated physical-TV iteration, build a branded Debug app using the existing
per-branch build configuration. It has its own bundle ID, preferences and data;
normal Plozz remains installed and untouched. Cloud sync and Top Shelf are not
enabled for branded builds. A branded app therefore needs its own normal
profile/source setup. Once installed, launch that bundle explicitly:

```sh
xcrun devicectl device process launch --device <device-id> \
  <branded-bundle-id>
```

The old `--live-tv-prototype` and remembered prototype-entry preference no
longer bypass Plozz's root or its background services. The older prototype
schemes also open the normal app; enter Live TV through navigation.

Additional launch arguments:

- `--live-tv-5000`: repeat the real catalog into 5,000 clearly labeled rows for
  scrolling tests. These are copies, not 5,000 distinct stations.

The former `--live-tv-guide` flag is no longer needed: channels and their guide
are one screen, including when no listings exist.

The entry route, live host and UI are compiled out of Release builds.

## Try

An empty configuration opens source setup; it does not contact a public feed or
play an unsolicited channel. Add your own M3U playlist or use an authorized
connected server. Plozz does not provide or offer a public channel catalog.
Enabled sources are combined;
adding one does not replace another. Channels become available before guide
loading finishes. There is one unified
channel guide, not separate Channels and Guide tabs. It groups up to three
**Recently watched** channels first, then **Favorites**, then the full filtered
channel list. Empty groups are omitted. Recent and Favorite entries are
independent shortcuts: a channel can appear in both and always remains in the
main list. Each section/channel occurrence has its own stable row and focus ID.
Search, categories and view filters apply across every group.
Search, categories, sorting and Favorites survive opening the player,
returning to the guide and refreshing sources.
Favorites and recent channels are saved per Plozz profile and restored across
sessions. Initially empty or temporarily unavailable source catalogs do not
erase saved IDs. Unreadable preferences are not overwritten, and failed writes
offer a retry rather than displaying an unsaved change as successful.
Search/category state remains session-scoped. Playlist addresses, optional guide
addresses and their order, source names, and enabled states are stored securely
per profile. Server sources store an account reference, not duplicate credentials.
View preferences and source management live in **Settings > Live TV**.
On Apple TV, Sources shows the actual source controls in the existing detail
pane, without an intermediate Manage sources page. Enable/disable and removal
are available there; playlist/guide editing and server renaming open their
specific editors directly. Hidden-channel restoration also lives in its detail
pane. Setup and source pages reuse Plozz's shared settings groups, row labels,
switches, focus/card styles and page heading.
Earlier prototype builds did not store Favorites or Recents on disk, so there
is no prior in-memory history to migrate on the first updated launch.

- Browse, search names/numbers/categories/sources, filter and sort.
- Select a channel logo to open its Play, Favorite and Hide actions. The
  right-hand programme/channel-name area plays directly; long-press actions
  remain available there.
  Hidden channels are excluded from Search and every guide section for this
  profile. Restore them in Settings > Live TV > Hidden channels. Hiding retains
  their favorite/recent metadata and source data, and does not end deliberate
  playback. After hiding, focus goes to the next remaining row, or the previous
  row when the hidden row was last; another occurrence of that channel is not
  a replacement. An all-hidden catalog explains where to restore channels.
- Search transforms the current screen rather than opening a second results
  dialog. Apple TV uses the native inline search keyboard above the familiar
  channel/programme rows; iPhone/iPad replace the hero with an inline search field.
  Both use the same query and filtered catalog, not an extra eight-result list.
  On TV, each actual guide row supplies a row-sized native focus boundary.
  This keeps keyboard-collapse scrolling aimed at that row rather than the
  entire SwiftUI results host; retain `PrototypeSearchFocusBoundary` around
  rows when changing the guide layout.
  The current category remains identified. Leaving Search restores the
  original guide occurrence and time position; the video stays in the same player.
  On Apple TV, Back works from both the native keyboard and the results.
  Search has a full-screen, transparent navigation host rather than an inset
  sheet. The old guide fades away, then the native search surface fades in
  without sliding down; closing reverses that handoff. Reduce Motion removes
  the fade timing. Temporarily opening playback or another sheet hides Search
  without discarding its query or results host.
  App navigation is suppressed before the TV keyboard opens and stays suppressed
  through closing and guide-focus restoration, so Back does not briefly open the
  native navigation menu or pinned rail.
  Live TV is the root of its native navigation stack, with no hidden empty page
  for Back to expose. Its shell sends Search/playback chrome visibility directly
  to that owning stack, restoring native navigation while browsing. With native
  navigation, watching uses a real fullscreen presentation above the tab shell,
  rather than relying on a root toolbar preference to hide its menu chip.
  The existing playback owner transfers the same engine's output view into
  that presentation and back; it does not create another engine or reload the
  channel. Pending startup survives the handoff. Presentation does not slide
  the picture in, and dismissal restores the retained guide before restoring
  its focus. The custom pinned rail
  retains its existing chrome coordinator.
  Live TV also participates in the profile's Hide or Reorder Navigation list,
  alongside Home, Search and the other destinations. Settings remains visible
  but can be moved. Press-and-hold Hide keeps focus at the vacated list position;
  Move Up/Down follows the moved item.
  Pinned navigation reveals its selected row before requesting native focus,
  including Settings or another destination below a long list's visible area.
  An open request expands the complete panel instead of leaving a thin backing
  at collapsed width. Collapsed icons have no panel behind them.
- Wide screens pin Search and an independently scrolling category list
  to the left of the guide. Search never scrolls away
  with either list. Select a category directly; Right returns to the remembered
  guide channel/program. Compact or short windows keep pinned horizontal controls.
  With pinned navigation visible, the Live TV controls also clear its title-safe
  margin; native top-bar/sidebar styles keep their tighter leading spacing.
  The selected category uses a checkmark rather than a second focused-looking
  box. Favorites are grouped in the guide, not a separate sidebar button.
  The More menu is gone: sorting, Auto preview, Favorites-only and guide-only
  preferences are in Settings > Live TV. Sources and Guide time remain
  directly available through channel/programme context menus; failed or empty
  imports also expose Sources beside Retry.
  On Apple TV, Back from a guide row focuses Search without scrolling the list.
  Back from the controls goes to the
  surrounding app navigation. Holding Select on a channel/program also opens
  its context menu with Search channels, Sources, Guide time when available,
  and Back to top. The sidebar's bottom clock remains removed.
  The channel/program context-menu Back to top action remains and does not
  reset the selected time.
- Compact category choices use an explicit navigation list with checkmarked
  selections, not nested system Picker presentations inside a sheet. Sorting
  uses the app's standard Settings controls.
- The guide sits in one rounded tray with roomier channel rows and
  quieter programme tiles. Logo plates, channel tiles and the outer tray use
  concentric radii derived from their insets. TV rows are 128 points tall,
  with full-height 200 x 128-point logo plates and 16-point row spacing.
  On first entry, focus moves to the first available channel's current programme
  to the right of its logo. With no guide data, the channel-name area remains
  separately focusable and playable. Missing-listing gaps have their own focus
  identities rather than pretending to be programmes. Subsequent playback/Search
  returns keep their remembered row; an explicit visit to a logo is still
  preserved when returning from browsing controls.
  The backing fills the complete station focus bounds, with the same corner
  radius and no outside gutter. Artwork fits inside without stretching, with
  eight additional points of inner padding; the full-height plate stays unchanged.
  Guide, Search, preview metadata and the player use the same `ChannelLogoArtwork`
  component. Solid logo plates replace the gradients that faded into the page.
  Detected source backings are extended unchanged, including white boxes inside
  transparent margins. Otherwise a restrained, desaturated brand tint sits over
  a light or charcoal plate; even a small bright wordmark can require charcoal.
  A quiet perimeter stroke keeps
  the plate boundary visible. Brand pixels are not recoloured or haloed.
  The existing shared hero preparation cache and synchronous memo resolve the
  logo and its backing together, so a warmed guide logo appears immediately in
  the player with the same appearance. Hero/search/player sizes remain
  independent of the full-row guide treatment.
  Station tiles show only the logo, or a name fallback when artwork is missing,
  rather than repeating names, numbers and badges beside it. Names and numbers
  remain searchable and available to accessibility; the focused channel's name
  and full programme title remain in the hero.
  No second surface surrounds the logo backing. Programme surfaces are quieter,
  with lighter-weight 26-point TV titles and the standard Plozz system font,
  not a separate rounded face.
  A small Liquid Glass surface anchors Search on the left; compact windows
  retain the glass control group. Programme cells do not create individual glass
  surfaces. Glass reduction preferences and Reduce Transparency use the existing shared
  fallbacks. Guide focus uses a crisp rounded outline and tonal fill, with a
  solid high-contrast treatment under increased contrast or Reduce Transparency.
  Focus outlines pair a bright outer edge with a dark inner keyline so white
  artwork cannot hide focus. Both strokes sit inside the existing rounded bounds,
  with no extra gutter, and strengthen under increased contrast.
  Focus and selection never swap the button's structural identity.
- The preview spans the screen width behind the upper guide. One continuous
  fade reaches the page colour before the video's lower edge; the date/time
  header no longer starts an opaque panel. The tray begins at five percent
  opacity rather than disappearing completely, then grows more opaque lower
  down, with a solid fallback for Reduce Transparency or increased contrast.
  A compact, noninteractive Now pointer sits just below the fixed time ruler,
  with a small shadow for contrast rather than a line through the channel rows.
  A subtle fill marks elapsed time inside programme cells, no-guide rows and
  gaps between listings, staying aligned with the pointer when the timeline
  scrolls. The pointer disappears when the current time is outside the visible
  window. Wide guides retain the time ruler and pointer even when
  no channel has listings. On no-guide rows this indicates elapsed clock time,
  not a known programme duration; channel names remain stationary. Compact
  channel-only layouts without a time ruler do not imply programme progress.
  Shared smooth edge masks dissolve rows underneath the fixed time header and
  programme cells at the horizontal viewport edges. The guide has no bottom
  fade and extends to the TV screen's bottom and trailing edges in both Search
  and normal browsing, without a trailing gutter or rounded trailing edge;
  the sidebar controls retain their safe inset. Touch layouts retain their
  bottom safe-area clearance. Each remaining fade ramps in only
  when content extends beyond that edge, keeping reached endpoints readable.
  Programme containers match the full height and corner radius of their station
  logo plates. Row spacing still separates channels; time widths and inner text
  padding are unchanged.
- **Sources** adds, edits, pauses and removes playlists and connected servers.
  Playlist checks finish before saving, and stale editors cannot overwrite a
  newer source. Guides are optional and can be added, removed or reordered later.
  The address can describe an M3U channel list or a direct HLS stream. A direct
  master or media manifest imports one channel, not one channel per segment.
  Channel-list entries can also point to HLS streams.
  Source details retain playlist/skipped-entry counts, guide matches, loaded
  listings and per-feed failures; the guide overview shows loaded coverage.
  Settings restores authorized cached channels and guide statistics without
  starting network requests merely by opening Sources. Refresh sources loads
  fresh data there; source changes refresh the retained Settings catalog.
  Failed sources do not block successful ones or erase their last-good data.
  **With guide listings** filters populated channels without changing source
  authorization or stopping a hidden, deliberately watched channel.
- Guide retains all channels, even if none has a schedule. Unknown intervals
  remain honest gaps; they do not hide channels or shift later programs under
  the wrong time. Channel buttons still tune live without guide data.
  Missing listings show the channel name to the right of the logo in place of
  a program, without inventing a show title, start time or duration. Real
  listings still show their programme title. Entirely unlisted rows
  keep that label stationary rather than drawing an empty six-hour program.
  Detailed diagnostics remain in Sources, not repeated on every channel.
  A focused missing-listing row can show a loading, failed or not-yet-requested
  state. Program details identify the selected guide source.
- On wide screens, the station/logo column stays fixed while program rows scroll
  horizontally through a shared six-hour window. The time ruler stays above the
  vertical list and follows the same horizontal offset. Its leading label
  identifies the visible channel group instead of showing a date and buttons.
  Guide time in the context menu retains the date and Earlier/Now/Later controls.
  Earlier/Later shifts the
  window from one day back through seven days ahead, subject to source coverage.
  The time anchor does not jump at the half hour while browsing; **Now** recenters
  it on the current wall clock. The header pointer tracks that same clock.
  Focused programme details above the grid show the full title and broadcast times,
  including for very narrow cells.
- Wide-guide stations, programme cells and horizontal scrollers share one scaled
  row height. Short programmes and clipped edge intervals cannot enlarge an
  entire row through timestamp wrapping, including cells outside the viewport.
  Wide cells prioritize titles rather than repeating timestamps/progress bars in
  every row; very small slices show an ellipsis. Compact touch cards retain times.
  Their time widths remain accurate, and full titles/times remain available
  through accessibility and programme details.
- iPhone and narrow iPad windows use compact rows with horizontally browsable
  program cards; no-guide rows put the channel name beside its logo.
  Video stays above the scrolling list. Touch browsing does not automatically
  open streams; selecting a channel starts playback, and returning leaves its
  preview visible. Use Watch channel to reopen playback.
- Select a channel or its currently airing program to watch real video.
  Past/future programs open details, not a pretend future broadcast.
  The live host exposes real buffering,
  failure/retry and live transport state rather than a fabricated VOD timeline.
  Recently watched records only deliberate fullscreen viewing after the matching
  source is playing and has presented video. Automatic previews, failed startup
  and stale callbacks do not count. Revisiting moves a channel to the front.
  Next/Previous snapshots the filtered guide order, deduplicated by channel, when watching starts, so
  promoting a channel into Recents cannot make transport bounce between stations.
  This channel history never writes movie/episode progress or watched status.

### Connected-server Live TV and standalone setup

IPTV playlists and XMLTV guides do not require a media server. The library-channel
runtime loads local definitions without querying unrelated connected servers.
Automatic library discovery is limited to libraries referenced by enabled Plozz
channels; opening their editor explicitly discovers the other available libraries.
A failure in an unused server is not reported as a broken channel in the IPTV
guide. Failures affecting configured Plozz channels and saved schedules remain
visible, and editor-only discovery errors stay in the editor.

Jellyfin, Emby and Plex adapters discover authorized channels, load native guide
data, and open explicitly owned live-stream sessions. Plex tunes the selected
DVR/channel, negotiates a consumer through the playback decision API, and uses
the returned HLS consumer path or an individually identified universal
transcode. A current guide programme is not fabricated or required by Plozz.
No adapter invokes administrative or device-wide session termination.

The provider-neutral `LiveTVServerEnrollmentCoordinator` accepts the existing
authorized account choices and resolver. Composition calls `refresh` at login,
profile activation and refresh, then reloads source catalogs. Configuration and
removed-account suppression are read again before each source is saved, so a
concurrent remove, manual add, rename or disable wins. Call `invalidate` before
changing profile/account authorization. Source IDs are stable account-derived
identities; secret tokens and server-user credentials remain in the existing
account resolver, not source configuration.

Checking a server is metadata-only and never acquires a tuner. The chooser
distinguishes missing tuner setup, no channels, permissions, an unreachable
service, explicit subscription requirements, unsupported APIs and guide-only
playback limitations. It uses only
accounts available to the current profile, including effective Plex Home
credentials, and rejects stale results after profile or authorization changes.
Source configuration uses the existing household parental-PIN policy.

Plex gives each pane/tune a fresh playback UUID, carried on tune, consumer
decision/start, timeline reports and scoped transcode stop. A detached allocation
request is observed to completion even after cancellation, then rolled back
using the same identity. Provider retirement fences late opens. Heartbeats run
every ten seconds; close serializes behind outstanding reports, sends the
owned viewer's stopped timeline, and stops only its own transcoder identity.
Stopping one viewer never deletes the shared live-session UUID.

#### Server API evidence and verification boundary

The [official Plex Media Server OpenAPI](https://developer.plex.tv/pms/)
(embedded schema 1.2.2, inspected September 8, 2026) documents channel tune,
live-session/consumer HLS, universal decision/start, and `POST /:/timeline`.
The timeline contract explicitly specifies a separate
`X-Plex-Session-Identifier` for simultaneous playback on one client and a
ten-second LAN/WAN cadence. It does **not** document a consumer DELETE endpoint:
none is invented here. Session-specific universal stop and the live stopped
timeline are additionally corroborated by independent existing clients,
including [Rivulet's playback client](https://github.com/l984-451/Rivulet/blob/6985966892ba00dcbeb1822a6360142fc5764b19/RivuletCore/Plex/PlexNetworkManager.swift)
and [live timeline implementation](https://github.com/l984-451/Rivulet/blob/6985966892ba00dcbeb1822a6360142fc5764b19/Rivulet/Services/LiveTV/PlexLiveTimelineKeepalive.swift).
These are API-behavior references, not a claim of local real-server testing.

[Plex's permission documentation](https://support.plex.tv/articles/115007689648-watching-live-tv/)
limits Live TV sharing to permitted Plex Home users. OTA viewing must not be
rejected merely because the owner lacks Plex Pass.
[Emby's Live TV setup](https://emby.media/support/articles/Live-TV.html) requires
Premiere; [its user-authenticated Info API](https://dev.emby.media/reference/RestAPI/LiveTvService/getLivetvInfo.html)
exposes enabled users, while its [Open](https://dev.emby.media/reference/RestAPI/MediaInfoService/postLivestreamsOpen.html)
and [Close](https://dev.emby.media/reference/RestAPI/MediaInfoService/postLivestreamsClose.html)
contracts identify individual stream handles. Missing entitlement metadata is
not evidence that Premiere is missing. An explicit HTTP 402 is distinguished
from permission denial; fixtures for this status do not assert which server
versions emit it.

Jellyfin's [API reference](https://api.jellyfin.org/) and
[official LiveTv controller](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/LiveTvController.cs)
identify the authenticated `LiveTvAccess` policy on channel/Info requests.
Discovery does not require its administrative tuner-configuration endpoints.

Focused deterministic selectors: `PlexLiveTVTests`, `JellyfinLiveTVTests`
(including independent Emby response shapes), `LiveTVServerEnrollmentTests`,
`LiveTVServerImportTests`, `LiveTVServerProbeTests`, and
`LiveTVServerGuideImportTests`. Fixtures cover no-guide tuning, permission and
subscription states, cancellation/retirement, same-tuner independent viewers,
failed handoff cleanup and concurrent source opt-outs. These are not integration
tests against a configured server. No supported-server-version matrix or
physical tuner contention, long-running renewal, remote streaming or
Home-user two-viewer release result is claimed without authorized real-server
verification.

Native guides bypass XMLTV name matching. The browser requests the displayed
two-/six-hour window for a bounded neighborhood of at most 12 rows; recently
watched and favorite duplicates do not produce duplicate requests. Loaded or
in-flight coverage is reused. Larger requested windows are split at the provider
limits rather than downloading every Plex channel for every day on entry.

Standalone admission is an explicit, device-local choice, separate from
accounts, profiles and source count. Deleting the last source or signing out of
the final server does not strand an opted-in installation at server login.
Existing profile confirmation and PIN/Plex Home gates remain intact. An explicit
first entry can temporarily expose a hidden Live TV destination; later launches
respect navigation customization, including Settings-only layouts. Builds
without the Debug-only destination do not honor standalone admission.

### Channel scanning

After importing a source, an optional scan can check channel availability
without blocking browsing or playback. Sources exposes Scan channels,
Scan results, Show hidden and Rescan channels. Browsing also exposes Check
channels. Importing a playlist does not start probes automatically.

Results belong to the profile, source, channel and stream identity. Confirmed
missing links can be hidden reversibly without deleting playlist entries,
Favorites or guide mappings. Restore is separate from manually hiding a channel.
Timeouts, offline checks, authentication/geo restrictions and unsupported
playback remain uncertain; one failed request does not remove a channel.
An HTTP 200 master playlist alone is not evidence of playable media, and
reachability checks are not decoder compatibility tests.

Concurrency, response sizes, deadlines and retries are bounded, with progress
and cancellation. Source refreshes, authorization changes and profile changes
fence old results. Each profile has one active scan owner. Scans inspect imported
IPTV links, not network discovery or tuner-consuming Plex/Jellyfin/Emby streams,
and do not commandeer the playing engine.

### Audible previews and seamless viewing

On Apple TV, resting on a different channel for **600 ms** requests its preview.
Rapid scrolling cancels pending requests; moving between programs on the same
channel does not restart the delay or retune. The delay is **not** a stream
startup guarantee: network, source, keyframe and decoder startup follow it.
Ordinary guide preview and fullscreen viewing share one active player, with
sound on while browsing. No second decoder is opened to fake an instant
crossfade. A server change can prepare a replacement
session while the current feed remains visible, then retire the old owned session.
Tuner contention offers an explicit stop-current-and-retry action rather than
silently interrupting playback. Cleanup attempts completing cannot guarantee
that an unreachable server has released its tuner.
Search, controls, sheets and inactive
scenes cancel pending focus-driven tunes.

Live video fills the upper backdrop rather than a boxed preview. A leading scrim
protects programme details and a continuous bottom fade blends through the
translucent upper guide into the solid page background.
The picture remains anchored while either guide axis scrolls. The backdrop
extends through the safe-area margins; only text and controls receive the
navigation rail's leading inset. Selecting a ready preview slides/fades the guide
away and expands the existing surface to unobscured, aspect-fit playback.
Back restores the guide's row, program, filters and time position; it does not
stop, reload or replace the engine. Reduced Motion removes the spatial animation.
On Apple TV, Search and surrounding navigation remain unavailable during the
focus handoff. The playing channel's currently airing programme receives focus
in the same Recent, Favorite or main-list occurrence used to start watching;
programme rollover selects the new programme, and missing listings fall back to
the channel. If a shortcut no longer exists, the same channel's main-list entry
is used instead. A changed channel or offscreen programme is brought into view.
Focus restoration waits for the row to mount and for native focus confirmation,
not merely an assigned focus binding. A bounded station fallback releases the
entry gates if it fails, so the guide cannot remain unreachable from Search.
Moving from the sidebar toward the guide reveals its remembered occurrence even
when that row was scrolled offscreen.
Returning from fullscreen keeps the chosen channel playing while its guide
focus is restored. **Auto preview** remains enabled by default after watching:
subsequent focus movement uses the same 600 ms settling delay. The separate
per-profile **Keep watching while browsing** setting opts into retaining the
deliberately watched channel instead. Turning Auto preview off still prevents
focus-driven tuning. No preview can commit during focus restoration, and stale
restoration callbacks cannot rearm it. The remote's Play/Pause also works during
browsing.
The normal tvOS player header has no Close button; Back returns to the guide.
Transport focus selects an available playback action instead of a removed
header target. Startup and interruption escape/retry controls remain available,
and iPhone/iPad retain their touch Close button.
The player also offers Add to Favorites / Remove from Favorites for the channel
being watched, using the same profile preferences as the guide. The star reflects
saved state; failed saves keep the previous state and surface the existing retry
alert. Favorite changes do not retune or restart playback.

Tuning another channel reuses the engine with a new, fenced source attempt.
Loading/failure states remain local and nonfocusable in the preview, with an
opaque placeholder until the new source actually produces a first frame.
Opening a failed preview exposes the existing full retry/close UI.
Leaving the Live TV destination releases playback and invalidates pending tunes,
including when a native tab keeps its view alive. Ordinary playback tears down
on background entry; explicit mobile PiP/AirPlay follows the authorization-gated
continuation policy below.

## Developer test inputs and artwork

These public addresses are developer test inputs only. They are not offered
in onboarding or Sources, and the importer has no default playlist or guides.
To use one for manual testing, add its address explicitly through the ordinary
playlist editor. Previously saved sources remain editable and are not removed:

- Playlist: `https://iptv-org.github.io/iptv/countries/us.m3u`
- Pluto TV US: `https://i.mjh.nz/PlutoTV/us.xml.gz`
- Samsung TV Plus US: `https://i.mjh.nz/SamsungTVPlus/us.xml.gz`
- Plex US: `https://i.mjh.nz/Plex/us.xml.gz`
- EPGShare US2: `https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz`
- EPGShare Plex: `https://epgshare01.online/epgshare01/epg_ripper_PLEX1.xml.gz`

The September 6, 2026 source snapshots import 1,468 stream entries across 28
primary categories, with 1,443 logo URLs. The multi-feed import provides listings
for 253 streams, compared with 70 in the original US2-only build. Evaluated at
2026-09-07 03:04 UTC, all 253 had current listings, with 11,257 programs retained.
The selected sources supply 185 Pluto, two Samsung, three Plex and 63 US2
schedules; EPGShare Plex supplies overlapping fallback data, not extra channels.
These counts describe those snapshots, not guaranteed availability or coverage.
The remaining 1,215 streams stay available without invented program information.

Playlist entries are not necessarily distinct stations: feeds can include
alternate resolutions and stream providers. Stable stream identities preserve
variants without duplicate row IDs. Channel logos come from `tvg-logo` metadata
in the [iptv-org catalog](https://github.com/iptv-org/iptv).
Channel and hero marks reuse `HeroLogoArtwork`: cached off-main preparation,
transparent/solid-margin trimming, ink-aware sizing, monochrome contrast and
contrast analysis. A bounded fit contains the whole mark inside the station plate;
measured ink chooses a legible solid backing. The existing preparation pass
retains the background colour it already detects before removing a solid plate.
That sample follows the prepared-logo cache and synchronous memo to the host.
The solid plate adds no image download, resampling pass, blur or continuous animation.
Multicolour artwork is not recoloured. Failed/missing artwork keeps a readable
fixed-size text fallback. Loading artwork never changes the reserved row height.

The original nine-channel `LiveTVPrototypeCatalog` remains a small regression
fixture, not the app's default catalog or a channel limit.

Availability and regional restrictions may change. These are developer test inputs, not a
Plozz-provided channel service, broadcaster endorsement, or permission to
rebroadcast, record or redistribute content. No third-party image binaries
are committed.

Import does not certify that every stream plays. A reachable master alone is
not sufficient: inspect its media playlist and segments, then exercise actual
device playback. Playlist request headers pass through the live host to Aether,
including retries and automatic source resets.

For example, ABC News Live 1's published master returned HTTP 200 on September 7,
2026, while all ten advertised media playlists returned HTTP 404. A guide match
or a valid master cannot make those missing media playlists playable. The
prototype keeps the supplied channel identity rather than silently substituting
a different ABC feed.

Guide loading and parsing run outside the main actor. Listings are associated
with imported channel identities, not synthetic layout scenarios. Unknown or
ambiguous matches receive no schedule. Guide failure does not remove a working
playlist; failed refreshes preserve the last successfully imported data that
still belongs to current channels.

Matching first uses exact native Pluto IDs from recognized stream URLs, then
explicit guide IDs, verified aliases and unique display names. Provider guides
only use name matching for streams identified as that provider; similarly named
streams from unknown or different providers are not silently assigned a FAST
schedule. Explicit foreign Samsung stream origins are excluded from the US
guide even when the playlist's station ID ends in `.us`. Country, affiliate
and time-shift conflicts continue to prevent name-based matches. An unmatched
native Pluto ID is not replaced with a guessed same-name station.

Each stream receives one whole schedule, never interleaved programs from
different feeds. Stronger identity evidence wins. Equal-confidence matches
prefer a schedule with upcoming listings, then the source order shown above.
An unavailable refresh retains that source's last good data for current channels.
Source changes fence late network/parse results before reloading.

Compressed input, expanded XML, retained text and program counts are bounded.
The combined in-memory guide cache is also capped at 250,000 programs and
32 MiB of program title/subtitle text. Sequential feed loading limits transient
memory. Two streaming XML passes discover channel metadata before retaining
matched programs, supporting feeds that interleave channel declarations and
listings without keeping all unmatched programs in memory. Plain XML and gzip
are accepted. Normal external XMLTV DOCTYPE headers are accepted without
retrieving the DTD; entity declarations remain rejected.
Custom-source setup is available in Debug. The production importer uses an
encrypted, indexed catalog and guide cache. Guide windows and program searches
fetch only the requested channel IDs and time range; a large import does not
publish its entire schedule into observable UI state. Cached data is bound to
the current source URL and profile authority. Changing credentials cannot
restore streams or guide data from the previous source binding. A failed
refresh retains the last good generation for an unchanged, still-authorized
source. Backend playback handles remain runtime-only.

## Boundaries

The Debug integration includes manual guide mapping, durable channel identity,
generated library channels, indexed program search, channel checks and four-channel
Multiview. Multiview retains each player's decoder and prepared stream through
side-by-side/corner layout changes, audio selection and returning to one player.
Setup keeps the pictures inside a bounded canvas with room for controls.
Focus outlines hug the actual video aspect, reported by the retained player,
rather than its letterbox area or caption. Add and Replace return to the actual
guide in selection mode: the same channel/programme rows, vertical catalog,
Favorites, Recents, category sidebar and native Search, backed by the same
profile model and loaded guide. There is no separate channel browser or
horizontal all-channel shelf. The current audible picture remains in the guide
preview, and browsing never retunes a Multiview player. Selecting a station or
programme adds/replaces its live channel, then returns to setup. Already-added
channels are marked; selecting one returns to it without allocating another
player. Cancel preserves every stream and the existing composition.

Watch switches to the full physical-screen canvas, including safe-area edges,
with no video focus outlines. Two channels split horizontally in landscape and
vertically in portrait; three or four use a two-row grid. Main and stack places
one large picture on the left and up to three separate pictures stacked on the
right, without overlap. Corner mode retains its overlaid inset column.
Each renderer fits its source without cropping. Edit layout returns to setup;
ordinary viewing never reserves permanent space for controls.

On Apple TV, native pane focus selects that channel's audio once its source is
prepared. Moving into the controls keeps the last selected audio. Select opens
the focused picture full-screen; Back restores all retained players without
retuning. On touch devices, tapping a picture selects its audio and expands it;
Show all restores the layout. Tapping again reveals hidden controls.
Watching hides controls after four seconds of inactivity. Editing, native menus,
channel selection, preparation failures and VoiceOver keep them available.
Native menu focus notifications do not write back into the pinned controls'
activity state, avoiding an update loop that can repeatedly rebuild the menu.
Back from a guide row still focuses Search; Back from those controls or Cancel
returns to setup. In Multiview, Back restores all pictures if expanded, then
leaves setup or dismisses active controls. Any Back or Close Multiview action
that would end the composition asks for confirmation. Keep watching dismisses
the confirmation without closing streams.

Favorite saves channel IDs in display order, the main picture and the chosen
layout. The guide's Multiviews control opens these saved compositions. Favorites
are profile-scoped and device-local, survive relaunches, and store no stream
URLs, credentials or tuner leases. Restoring resolves channels against the
current catalog and authorization; missing or unauthorized channels produce an
error without replacing current playback. Channel identity migrations update
the saved composition, and ordinary channel preferences or portable preference
imports preserve it. Required lifecycle or authorization cleanup never waits
for exit confirmation.

Its hardware decoder capacity, mixed HDR/SDR behavior and long-running resource
use still need real-device acceptance; controlled fixtures are not proof of
those guarantees.

Generated channels use immutable schedules and seek into the current program
when joined, rather than resuming an ordinary movie or episode session. Library
history defaults to Off. With consent, sufficient actual watched coverage can
produce a canonical watched completion through the existing profile outbox.
Generated completion never writes resume position or sends a legacy
playback-stop event. Pending completions retain runtime consent and account
authorization checks; restoring an outbox cannot recreate an expired grant.

Optional portable Live TV state covers channel preferences, matching hints and
generated definitions/snapshots, not source URLs, imported playlist bytes,
credentials, parental approvals, history grants or channel health. Incomplete
snapshot transfers remain pending. Identity changes are deferred while
playback holds their identities, while authorization revocation takes effect
immediately. Each device still configures and authorizes its own sources.

Channel checks use bounded probes and keep unsupported, blocked and uncertain
results distinct. Only confidently missing streams can be automatically hidden;
restoring a scan-hidden channel does not change a manual hide. Scanner network
permissions do not grant the media engine a transport capability it lacks.

Xtream-compatible login, DVB-I, DASH-specific integration, catch-up,
programme-rating restrictions and recording management are outside this
implementation. Source-configuration PIN protection is not a
programme-content rating filter. Real tuner installations remain a validation
gate beyond controlled provider fixtures. Many streams still lack a confidently identified schedule;
more name guesses are not a substitute for accurate provider/region mapping.

The normal shell owns account/profile models; the Live TV feature does not
create a second account or profile stack. The small
`FeaturePlayback.LiveChannelPlayerView` hosts the existing real engine without
constructing the VOD `PlayerViewModel`, VOD reporting sessions, resume
writers or trackers. Live server sessions have separate UUID-scoped first-frame,
progress and cleanup reporting. This avoids incorrectly treating an endless channel as a
movie while leaving ordinary library playback unchanged. The app shells inject the
player into `FeatureLiveTV`; UI feature modules do not import one another.
The app also injects the `LiveChannelEngine` implementation into the host, so
`FeaturePlayback` does not depend back on `EnginePlozzigen`. Engine initialization
failures are visible; the prototype never silently substitutes direct AVPlayer.

The paired `FeatureLiveTV` / `FeatureLiveTVCore` types are explicitly named
`LiveTVPrototype*`; they are not a final provider API. The core's synthetic
30-channel fixture catalog remains for deterministic guide/filter/state tests,
separate from the real catalog used by the app.

## Live activity and diagnostics

The centered activity indicator is owned by `LiveChannelPlayerModel` and driven
by AetherEngine's typed `playbackPhase`, gated on
`hasFirstFrameReadyForDisplay` for initial video. Connecting, buffering, seeking
and reconnecting are distinct. The host no longer reconstructs engine state
from AVPlayer transport hints or a second playback-clock classifier.

TV controls keep one stable set of focus targets. Live playback reuses the normal
player's `InfoActionButtonStyle`: white labels at rest and black labels on a
white capsule when focused, with both colours changing together. The same style
covers transport, Favorite, loading, retry and close actions. Its type stays
constant as focus changes, avoiding replacement of the focused control.
Shared CoreUI focus-activity observation and monotonic inactivity tracking
keep native remote input non-consuming and use the same four-second grace
across live-player and Multiview overlays.
An available transport or recovery action receives focus; normal TV playback
has no top-right Close control. The connecting indicator does not intercept input. On-device regression checks
must include video rendering and Back/Close while a channel is still connecting;
the headless package test runner has no window scene to exercise TV focus.

Live loads use `isLive: true`, the stable `.standard` join profile and native
remote HLS with Aether's compatibility fallback. A native HLS route still uses
AVPlayer internally; Aether owns route selection, engine state and recovery.
The host uses actual live seekable ranges and Aether's Go Live API, never a
fabricated movie timeline or a guessed seek target.
Native HLS uses the origin's actual sliding window; no local DVR duration is
invented. If compatibility recovery switches to ingest without a DVR window,
timeshift controls disable rather than promising unavailable rewind.

The host subscribes to `liveSourceReset` before loading. A fixed public channel
reopens the same URL, with one automatic retune in flight, at least 20 seconds
between automatic attempts and at most three per channel-viewing session.
Duplicate signals coalesce, pause/inactivity defers recovery, and exhaustion is
visible. Two manual retries remain available; they do not replenish automatic
recovery's budget. Startup is bounded at 30 seconds and sustained activity/stall
at 60 seconds, leaving room for Aether's own recovery before failing visibly.

Brief inactivity pauses the current feed and cancels pending tunes without
releasing the current server lease. Background entry or leaving Live TV closes
ordinary playback; an explicitly authorized mobile PiP/AirPlay continuation
retains its exact player and preparation until it ends or loses authority.
Returning to active browsing follows the Auto preview preference; touch browsing
still requires selecting a channel. Stop, failure, authorization changes and
replacement invalidate outstanding loads and seeks. Ordinary VOD playback and
its lifecycle remain unchanged.

Mobile cellular playback is allowed by default. The optional "Stop without
Wi-Fi or Ethernet" control stops playback after detecting a network change.
The engine does not expose per-request cellular restrictions, so this is not
a guarantee of zero cellular bytes during a handoff.

Debug diagnostics use the existing `HandoffDiagnostics` bounded playback journal
and `PlozzLog` recent-log ring, tagged `LIVE_TV` with `engine=AetherEngine`.
Snapshots include typed playback phase, actual video route, first-frame readiness,
playback/buffered positions, behind-live time and seekable bounds. Changes are coalesced to at most one
snapshot per second; steady playback emits a heartbeat every ten seconds.
Lifecycle and classified failure events are also recorded. Correlation uses a
random session ID, not a channel name, locator or credential. Error text and
raw URLs are never included in these new events.

Committed focus previews record monotonic `settleMs` separately from the
player's tune-to-first-frame timing. A canceled focus request emits no tune
event. Startup timings describe actual first-frame readiness, not merely a
manifest response or successful `load` return.

The journal is `Library/Caches/Plozz/playback-trace.log` (64 KiB limit).
Use existing in-app diagnostics export when available. Do not copy the active
tvOS app container, attach a debugger, or relaunch with `--console` during
someone's viewing without authorization: these can interrupt playback.
The existing `PlozzigenVideoEngine` log mirror is reused; the live host installs
no competing `EngineLog.handler`.

Terminal live errors retain Aether's typed `PlaybackErrorInfo` classification.
Explicit source HTTP refusals, connection failures, rate limiting and decoder
failures receive distinct channel-specific copy, rather than generic media-server
or sign-in instructions. Native AVFoundation failures do not imply a particular
HTTP status unless the engine actually supplies it. Bounded failure diagnostics
include an allowlisted error kind/domain and numeric code; messages are not
regex-parsed for classification, and raw locators are not added to those fields.

Run the focused model and native layout tests through the existing simulator runner:

```sh
tools/run-tests.sh FeatureLiveTVTests FeatureLiveTVCoreTests FeaturePlaybackTests EnginePlozzigenTests
```

`LiveChannelFullscreenPresentationTests` additionally needs an app-hosted tvOS
test target with a window scene; the standalone package runner skips it.
It exercises native sidebar/top-bar presentation, actual dismissal, focus
ownership, in-flight startup, channel changes and reuse of the engine's output
view. It does not substitute for a physical Siri Remote usability pass.

The [native Live TV regression fixture](../Tests/FeatureLiveTVRemoteTests/README.md)
provides that scene-backed host, actual remote Search traversal and isolated
source-onboarding navigation. Its independent project and inputs are committed;
it does not require a configured server or download a channel feed.
