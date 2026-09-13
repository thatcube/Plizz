# Plozz testing: data-driven selection & build-once policy

Purpose: run the *right* tests fast during the agentic inner loop, and the full
sweep only when it matters — speed without sacrificing quality. All target/suite
knowledge is **derived at runtime** from `swift package dump-package`; nothing in
the test tooling hardcodes the target list, so new targets (e.g. the WebDAV work's
`MediaTransportWebDAVTests`) are picked up automatically.

## The two speed wins

### 1. Build once, run many (`tools/run-tests.sh`)
The old runner looped `xcodebuild test` **once per test target** — 23 separate
build + simulator-install + launch cycles. Since the tests themselves execute in
well under a minute of CPU, ~all the wall-clock was 23× compile + simulator
orchestration. The runner now does **one** `xcodebuild test` against the
always-present `Plozz-Package` scheme:
- **Full sweep:** `xcodebuild test -scheme Plozz-Package` (no `-only-testing`).
- **Subset:** `-scheme Plozz-Package -only-testing:<Suite>` for each selected suite.
- **Single suite with a materialised native `<Suite>` scheme:** used directly (rare
  locally — SPM publishes per-*module* schemes like `CoreModels`, not
  `CoreModelsTests`, and module schemes are not test-configured — so single-suite
  runs normally also go through `Plozz-Package -only-testing`).

`Plozz-Package` is the only test-capable scheme, so build-once relies on the
existing self-heal: a stray generated `Plozz.xcodeproj` shadows the Swift package
and blocks `Plozz-Package`; the runner moves it aside when needed and restores it
on exit.

`-only-testing` filters which suites **run**, not what is **built** — a subset run
still compiles the full test graph once. The win is collapsing 23 build +
orchestration cycles into **one**, not compiling less.

**Flake guard:** if the single run reports specific failed suite bundles, each is
retried **once** in isolation; a suite only fails if it fails twice. A build/compile
failure or an incomplete matrix is not retried. Failed targets are read from
`xcresult`, including tests that crashed before XCTest restarted their bundle.
This covers the occasional
`ProviderPlexTests` StubHTTPClient timing race.

`PLOZZ_PARALLEL=YES` opts into `-parallel-testing-enabled YES`. It is **off by
default, and measurement says keep it that way**: a full parallel sweep on this
Mac had not reported a single bundle result after *8 minutes* (versus ~1m45 total
serially), because xcodebuild clones the tvOS simulator per worker and the boot
cost dwarfs anything it could overlap.

`PLOZZ_LOG_DIR=<dir>` keeps xcodebuild's raw log instead of discarding it. The
per-test `Test Case '-[Suite testX]' passed (N seconds)` lines only exist there,
so this is how you find out which individual tests are slow:

```
PLOZZ_LOG_DIR=/tmp/prof tools/run-tests.sh
grep -Eo "Test Case .*passed \([0-9.]+ seconds\)" /tmp/prof/main.log | sort -t'(' -k2 -rn | head -20
```

### Where a full sweep's time actually goes (measured, warm DerivedData)

| Phase | Cost |
| --- | --- |
| arch-guard + test-hygiene + `dump-package` | ~6s |
| incremental build check + first bundle install | ~15s |
| **per-bundle simulator install/launch, 38 bundles × ~1.0s** | **~38s** |
| test bodies actually executing (4663 tests) | ~27s |
| verdict grace before reaping xcodebuild | ~6s |

The single largest line is **not** the tests — it is the fixed ~1s the simulator
charges to install and launch each of the 38 `.xctest` bundles. That is the price
of the module granularity that makes *scoped* builds cheap, and it is charged per
selected suite, so the inner loop (`test-fast.sh`, 1–3 suites) pays ~1–3s of it
rather than 38s. Consolidating test targets to dodge it would make every scoped
run compile far more than it needs to — a bad trade for the loop that runs
hundreds of times a day. Don't chase it; use `test-fast.sh`.

### 2. Change-scoped selection (`tools/test-fast.sh` + `tools/test-impact.py`)
`tools/test-impact.py` builds the package's internal target dependency graph from
`swift package dump-package`, computes for each **test** target the transitive set
of source targets it reaches, and inverts that into `sourceModule → covering test
targets`. `tools/test-fast.sh` maps your `git diff` to a selection and runs only
those suites via `run-tests.sh` (build-once).

Because `CoreModels`, `CoreNetworking`, `MediaTransportCore` etc. are depended on
by many targets, a change to one of them naturally selects everything that depends
on it — **"foundational escalation" falls out of the data with no hardcoded list**.

**Guardrails (never silently skip):** `test-impact.py` forces the **full matrix**
whenever a change could invalidate the map itself or is otherwise unmappable —
`Package.swift`/`Package.resolved`, anything under `tools/` or `.github/`,
`project.yml`/`Config/**`, `*.xctestplan`, or any changed code path it can't map to
a test target. Pure docs/asset changes select nothing. Every run prints the chosen
suites and the reason each was selected.

### 3. Fail fast — you learn a result in seconds, not minutes

Tests *execute* in well under half a minute, but `xcodebuild` on this Mac
routinely stalls for minutes in teardown (result bundle + simulator shutdown)
after the tests have already finished. Two things used to turn that into a
~7-minute wait for an answer that existed at second six:

- The stall looked identical to a wedged build, so the no-progress watchdog
  (`PLOZZ_HANG_SECS`, 180s) killed it…
- …and a watchdog kill triggered the from-clean self-heal, which wiped
  DerivedData and **recompiled everything to reprint the same failures**.

`run-tests.sh` now tracks how many test bundles have reported a bundle-level
result (`Test Suite 'X.xctest' passed|failed`). Those lines are flushed as each
bundle finishes — unlike the final `** TEST FAILED **` banner, which is
block-buffered and often only reaches the log once the process is killed. Once
every expected bundle has reported, the script
waits `PLOZZ_VERDICT_GRACE` (default 6s, polled every `PLOZZ_POLL_SECS`=2s) for a
clean exit, then checks for a finalized `xcresult` before reaping teardown. A
from-clean retry is now only attempted when the run produced **no** results at
all — the case it was actually meant for.

The poll interval matters as much as the grace: at the original 10s granularity a
20s grace could take 30s to fire, so every *green* run paid up to half a minute
of pure waiting after the last bundle had already reported its verdict.

Measured on `ProviderShareTests` (416 tests): a failing suite went 6m53s → 1m12s
(including the isolation retry), a passing suite ~10min → 29s.

Set `PLOZZ_VERDICT_GRACE=0` to check results as soon as the bundles report.
`PLOZZ_RESULT_TIMEOUT` (default 660 seconds) bounds result finalization after the
last bundle reports, allowing Xcode's 600-second simulator diagnostic collection
to finish. This is a ceiling, not a fixed wait. A readable result bundle is
always required; reaching the grace period alone never interrupts its writer.

### Simulator readiness and authoritative results

Before starting XCTest, the runner waits for `simctl bootstatus -b` to finish,
including BackBoard and the system app. A simulator marked Booted can still be
initializing those services; starting SwiftUI image rendering too early can
abort or hang inside UIKit's display initialization. Startup is bounded by
`PLOZZ_SIM_BOOT_TIMEOUT` (300 seconds by default), and a failed boot stops the run.

Bundle-level console summaries only trigger the teardown grace period. XCTest
can restart after a crash, skip the crashed test, and print a passing summary
for the survivors. Every invocation therefore gets a unique retained result
bundle under `$PLOZZ_TEST_RESULTS_DIR` (by default `.build/test-results/`),
outside DerivedData and Xcode's rotating log store.
The runner reads its structured summary with `xcresulttool` and fails closed
when results are missing, unreadable, empty, or failed. Reaping a completed
driver cannot turn a recorded crash into success. Named failures can receive
the normal isolated retry only after every requested bundle reported.

Runner verdict regressions use the existing host-side unittest runner:
`python3 -m unittest discover -s tools/tests -p 'test_xcresult_summary.py'`.

## App-hosted focus integration

`tools/run-focus-tests.sh` runs the `PlozzFocusTests` scheme in a minimal,
separate `PlozzFocusHost` app. It uses the same package code but supplies a real
foreground window scene, which package logic tests cannot provide. The suite
exercises native focus on a loading episode slot and its handoff to an episode
near the end of a 1,000-item row. It uses local fixture artwork, not media servers.

Pass `PLOZZ_SIM_ID` to select a simulator. Run `tools/generate-project.sh` after
changing the host or test target. Results are retained under
`.build/focus-test-results/`; the runner requires an authoritative passing
`xcresult` just like the package runner. Both runners execute in CI.

`DetailTopNavigationHostedTests` pushes a full-height detail hero through native
top tabs, the native sidebar, and a standalone navigation stack. It checks the
physical top edge and horizontal gutter after navigation, late metadata, action
focus changes, scrolling to Cast, and reopening. The shared
`DetailTopSafeAreaBreakout` must remove the actual navigation inset rather than
subtracting a fixed overscan margin. Its artwork-first reveal is checked with
rendered pixels and live focus targets, including the Reduce Motion path.

`CinematicDetailTransitionHostedTests` exercises the card-to-artwork compositor
over a real navigation stack. It checks the actual expanding and shrinking
frames, artwork-only pause, ordered foreground stages, early Back, direct-play
bypass, missing/replaced source fallback, nested-page ownership, and removal of
input guards and visual covers. Real framed and borderless poster tests also
check that the source crop excludes the caption under Reduce Transparency.
The entrance uses 550ms for the zoom, a 500ms visible-artwork pause, and overlapping
320ms foreground reveals spaced 180ms apart. Shows reveal the episode browser
after the controls, retaining the navigation guard through its final 320ms fade;
movies do not acquire that extra stage. Back uses a 380ms return without
the pause. Reduce Motion bypasses the custom sequence and its input wait.
Source snapshots are per-activation, not per-frame; full-window covers are
released at the artwork handoff, and the small return-card image is scoped to its page.

`DetailTransitionVisualRegressionTests` uses the production show page and real
poster cards. It asserts that the outgoing thumbnail is transparent within the
first third of the zoom and is never reused as a loading backdrop. The resolved
detail image joins the expansion as soon as it is available. Reverse endpoints
are compared against rendered focused-artwork pixels for framed/borderless and
outlined/highlight cards; corner radii scale with the artwork and use continuous
corners. The source's focused rectangle and radius are captured at activation;
Back starts toward that shape immediately while native focus restores underneath.
A replaced source or changed window size uses a nonspatial fallback. A temporarily
unrealized source still returns to its captured shape without waiting for focus.
The episode browser keeps its layout while masked until its final reveal and
cannot take entry focus during a whole-show entrance. Episode-context opens
retain their existing initial-focus behavior; Reduce Motion reveals it directly.

When its real backdrop is ready, opening motion starts in card/router activation,
before creating the detail page. An empty destination must not animate: a cold
request keeps the existing source image until the real preview is available,
then starts the same zoom. There is no substitute image or added loading screen.
A late destination adopts an in-flight entrance rather than replaying it.
Render-server snapshots avoid a full-window bitmap draw on the main thread.
The hosted tests also delay destination mounting and withhold return focus to
verify that neither creates a new pre-animation wait.

Prepared title routes use `withCinematicDetailNavigation` to commit the real
stack change without a second native navigation animation. Unprepared routes
retain their normal animation. A UIKit appearance observer keeps the opening
cover until both the artwork has landed and the destination has appeared.
Production detail pages also wait for a displayed backdrop preview before
starting the 500ms pause and title/button reveals. Full-resolution upgrades do
not restart that sequence. Exhausted artwork candidates release the cover and
controls without a picture; Back remains available while artwork is pending,
and a playing trailer satisfies backdrop readiness without waiting for a still.

Known movie/show backdrops warm after 350ms of stable card/hero focus, with only
one unclaimed focus warmup active and image work on the background lane. The
warmup preserves provider priority rather than pinning a provisional fallback.
The exact preferred preview is retained under its policy-qualified preview key
and can paint the first frame at selection. If selection happens during lookup,
navigation adopts that lookup and uses foreground image loading; it does not
start another provider lookup or let focus loss cancel the selected request.
Blur/disappearance cancels unclaimed work. A full-quality upgrade keeps the
chosen reference, including when the upgrade fails.

Selection starts any still-needed first-paint request, scoped to the navigation
and joined by the destination. Its preview can feed the expansion before the
page mounts. Poster-only discovery still waits for its authoritative
enrichment. `ArtworkResolutionState` relays the displayed image itself (including
cached and fallback previews) and terminal failure, rather than making the
transition wait for a final-resolution URL callback and another cache lookup.
Focused regressions check request adoption, preview delivery within 500ms,
late-artwork ordering, failure, trailer readiness, and Back during the wait.

`PlozzHomeFixtureTests` builds the real Home view with local provider/artwork data
and drives native left/right/up/down movements without manual input. It is an
isolated simulator workload, not an emulation of an older TV's processor.
`ArtworkLatencyDiagnosticsTests` is separately opt-in: explicit environment
paths identify a sanitized Home snapshot and a local configuration bundle; its
attachment records provider lookup/image durations, never credentials.

Back restores the captured source page behind the moving artwork immediately,
not a snapshot of the outgoing detail page. The popped content stays hidden
through teardown. The cover remains until both reverse motion and the real pop
finish; source scroll offsets and focus are restored beneath it before removal.
Home and detail hero focus handlers ignore these restoration events rather than
starting another scroll/recede animation. Ordinary user-driven timing is unchanged.
Coverage deliberately delays the pop by 700ms (longer than the reverse animation),
checks both spatial and nonspatial covers, restores a displaced scroll offset,
and observes actual UIKit navigation animation flags. Window-scoped ownership
keeps the return alive after the SwiftUI page is removed, then releases it at
handoff. The source snapshot is also released on a memory warning.

Pinned navigation's passive arrow/swipe observers must honor the cinematic
input gate: a consumed Left is not an unresolved page boundary. Capture the
window's input epoch at gesture start and recheck it before any deferred rail
action, so work queued across a transition cannot open navigation afterward.
The native Search boundary observer and explicit sidebar-open requests use the
same gate. Visual completion does not release a held press or touch: suppression
drains through its end/cancellation and the rest of that event's observers.
Fresh input works without a cooldown; Back remains native, and app deactivation
or forced teardown removes the guard immediately. `PinnedReturnInputHostedTests`
covers blocked/queued Left, held and mixed input, swipe epochs, fresh navigation,
and the real pinned-edge callback changing UIKit focus.

Card focus has three independent options: System (native tvOS projection),
Highlight (custom sheen/lean) and Outline (custom glass). Absent per-profile
preferences use System; saved `highlight` and `outlined` values are not migrated.
The System path uses actual TVUIKit media controls: `TVPosterView` for media
Posters and `TVCardView` for composed Cards and read-only information. Images are
assigned to `TVPosterView.image`, never directly to its internal image view.
The shared artwork loader remains responsible for caching, provider selection
and spoiler-safe sources; a stable poster control stays mounted while it loads.
Native titles/subtitles use the poster's footer. Badges and resume controls live
in its documented image overlay. Series artwork extension and spoiler blur are
content preparation only, not focus effects.
Prepared poster images use the displayed content size in points and the device
display scale in pixels. TVUIKit derives focus growth from the image, so raw
high-resolution cache dimensions must not become the poster's logical size.
For original artwork, adjust UIImage point-scale metadata without redrawing the
pixels or changing their alpha channel. Only extended/blurred content is rendered.
Pin decorations to the native overlay container with constraints; do not rewrite
their frames during native focus layout.
`TVCardView` hosts live content in its documented `contentView`. Neither control
overrides `focusSizeIncrease`, adds transforms or manufactures lighting/outlines.
Hosted text uses a light-surface palette inside TVCardView so the native light
platter does not receive white text from the surrounding dark app. Card fitting
honors finite width proposals; unspecified-width probes must not install the
10,000-point expanded fitting size as the card's content width.
Unspecified-height queries use compressed Auto Layout fitting, not an expanded
height: flexible rating labels otherwise become 10,000 points tall and inflate
the About column's text measurements. Subtract the control's native chrome
(`intrinsicContentSize - contentSize`) before measuring its hosted content, then
add it back once to the returned size. `NativeInformationCardHostedTests` covers
the actual information grid with a long synopsis and four ratings, checking
bounded, stable card dimensions and matching native/SwiftUI widths.
Native monogram photos are prepared as square, circular-alpha image data, so a
tall source portrait cannot protrude into its caption on focus.
System bypasses app-defined focus surfaces, edge strokes, resting shadows and
focused z-index changes. Custom Highlight/Outline retain their styling.
Horizontal rails do not clip native focus overflow.
Captions reserve clearance without an additional custom focus animation.
In the season episode row, the System focus owner encloses only the thumbnail
and its artwork badges, not the title or synopsis below it. Both the episode
thumbnail and interactive loading/retry placeholder use TVPosterView, so the
native outline and image use the same corner geometry. Cast/artist portraits use
TVMonogramView, with their captions outside the native control rather than on a
focused card platter. Regular media poster footer labels retain the existing
density-aware title/subtitle font sizes. Custom Highlight/Outline retain
their existing whole-column focus routing and artwork-only visuals.

`NativePosterComparisonTests` is an opt-in, simulator-only comparison, enabled by
`TEST_RUNNER_PLOZZ_NATIVE_POSTER_COMPARISON=1` on `PlozzHomeRemoteTests`. It captures
compositor screenshots of bare TVPosterView controls and the production adapter
with the same source pixels/content size in Default and High Contrast modes.
Red image landmarks and yellow overlay landmarks distinguish scaling from
edge cropping. It also isolates initialization order, subclassing, SwiftUI
hosting and overlay-hosting choices without changing production styling.

On tvOS 27, accessing `TVPosterView.imageView` while `image` is nil reproduced a
zero `focusSizeIncrease` that persisted after assigning an image. Image-first
construction retained the native 20-point horizontal / 11-point vertical
expansion defaults for the 400x225 fixture. Reading intrinsic size, subclassing,
SwiftUI hosting and adding a SwiftUI overlay after the image did not cause that
zero. Bare native controls also showed slight image-edge cropping under High
Contrast, so that observation alone is not proof of an app-authored transform.
The production adapter therefore initializes TVPosterView with its image before
accessing imageView. While artwork loads, a cached opaque placeholder supplies
the correct image geometry; it is content, not a replacement focus effect.
Replacing that placeholder keeps the same native control and expansion defaults.

The same opt-in comparison includes `TVMediaItemContentConfiguration.wideCell()`
in stock collection-view cells, updated with the native cell configuration state.
On the tested tvOS 27 runtime, image landmarks grew about 11% in Default mode;
under High Contrast they became about 3% closer while a white outline appeared.
Overlay landmarks stayed almost unchanged under High Contrast. This reproduced
the contrast-specific behavior without Plozz's media adapter or custom focus
styling. The focused frame guide alone is not evidence of actual image growth:
use the captured image/overlay landmarks and screenshots.

Media-card focus uses `PlozzCardFocus`: native focus notifications update ordinary
observed state, while explicit focus requests remain separate. A TVUIKit focus
notification must not write back into `FocusState` and reset the containing scope.
Surfaces with independent focus chrome retain ordinary SwiftUI focus.
`SystemDirectionalFocusTests` drives real remote arrows through production media
rows with a preferred hero above, including horizontal scrolling, direction
reversals and vertical row changes in both card layouts. Programmatically
requesting the next focus target is not an adequate substitute for this test.

`NativeFocusProjectionTests` covers the perspective/Z transform that ordinary
2D layer conversion loses. Real card tests compare the projected artwork's
rectangle and rounded corners against painted pixels through a native pop.
The opt-in `FocusStyleSettingsCaptureTests` runs only on a disposable simulator,
sets the real High Contrast Focus Style, checks the on-screen ring and circular
shape, checks its accessibility label, verifies Select fires once and long press
opens a context menu without selecting, then restores the original setting. Run it
with `TEST_RUNNER_PLOZZ_SYSTEM_FOCUS_CAPTURE=1` on the `PlozzHomeRemoteTests`
scheme after building/installing `PlozzFocusHost`.

Hosted coverage includes actual projected circular artwork, framed/borderless
return geometry and loading-row overflow. These are correctness checks, **not
Apple TV performance evidence**. Before calling System an improvement, compare
all three options on the same physical TV, profile, warm artwork and navigation
sequence (horizontal/vertical moves and rapid reversals). Use the
[performance playbook](performance-debugging.md) to compare hitch ratio, frame
times, main-thread stalls and memory, while checking clipping, captions and
Reduce Motion. Keep Home movement/backdrop timings and networking fixed in the
comparison; do not remove either custom option based on simulator results.

## Guards that run before the compile

Validate workflow edits with `actionlint .github/workflows/ci.yml` before
pushing. GitHub rejects invalid context references before creating a runner or
job log. Runner-local package storage is initialized in a step via
`RUNNER_TEMP` and `GITHUB_ENV`; the `runner` expression context is not available
in job-level `env`.

CI selects a tvOS simulator matching the selected Xcode SDK and shares its
`PLOZZ_SIM_ID` across package and app-hosted tests. It fails if that runtime is
missing rather than silently choosing the first installed (possibly much older)
runtime. The full matrix has a 40-minute wall-clock deadline; raw logs and
result bundles are retained as workflow artifacts for seven days.

Native typography tests compare against the runtime's `UIFontMetrics` behavior:
older tvOS versions keep those metrics fixed, while newer runtimes scale them.
Both paths assert the matching geometry rather than skipping older runtimes.

Both are host-side Python (the tests run inside the tvOS Simulator sandbox and
cannot read the repo tree), both are wired into `run-tests.sh`, `test-fast.sh`
and CI, and both are skippable via an env var for debugging:

| Guard | What it catches | Skip |
| --- | --- | --- |
| `tools/arch-guard.py` | forbidden module edges, layering cycles, vendor SDK leaks | `PLOZZ_SKIP_ARCH_GUARD=1` |
| `tools/test-hygiene.py` | tests XCTest will never run | `PLOZZ_SKIP_TEST_HYGIENE=1` |

`test-hygiene.py` exists because a `func testX()` declared **inside another
function** compiles cleanly, reads exactly like a real test in review, and is
never executed — XCTest only discovers methods declared as members of an
`XCTestCase`. The audit that added the guard found three such tests, all of which
pass once hoisted, i.e. three tests' worth of authoring effort that had been
buying zero coverage. Nested XCTestCase *classes* are fine and explicitly allowed
(the ObjC runtime does register them — verified against a real run log).

## Shared test doubles

SwiftPM cannot list one file in two targets, so a double needed by several suites
has to live in its own target or it gets copy-pasted. `TestSupportNetworking`
(`Tests/TestSupportNetworking`, a plain `.target`, not a test target) holds the
ones that were already duplicated:

- `RecordingHTTPClient` — was four byte-identical copies (Trakt/Simkl/AniList/MAL),
  three of which had drifted to name the wrong service in their doc comment.
- `StubURLProtocol` — was two byte-identical copies (HTTP/WebDAV).

Consumers use `@testable import TestSupportNetworking`, so nothing in it needs to
be `public`.

## SOURCE → TEST map (illustrative — computed live, do not hand-maintain)

Each `Sources/<Module>` is covered by `Tests/<Module>Tests` when that test target
exists. Modules with **no** test target (e.g. `FeatureSettings`, `TopShelfKit`,
`CrashReporting`, the metadata `*Service` shims) map to nothing directly but are
still covered transitively by `AppShellTests` and any feature that depends on them.
Run `tools/test-impact.py --list-tests` for the authoritative current list, or
`tools/test-fast.sh --dry-run <Module>` to see what a change would select.

There are currently **38 test targets** covering **4,663 tests**. The list is not
reproduced here on purpose — it went stale the moment it was written (it claimed
23 targets, and named `FeatureSearchTests`, which does not exist). Ask the tool
instead: `tools/test-impact.py --list-tests`.

## Writing tests that stay fast

The audit that produced these numbers found 56 tests (1.2% of the suite)
accounting for 70% of all execution time, and nearly all of it came from three
avoidable habits:

1. **A production delay with no seam.** `RemoteSubtitleAcquisition` polled 4×
   with a hardcoded 700ms sleep, so exercising its exhausted-poll path cost 2.5s
   of pure sleeping. The fix is an injected interval with the production value as
   the default — not a weaker assertion.
2. **A `waitUntil` that returns silently on timeout.** It converts a real
   regression into a green test that merely takes `timeout` seconds, and it
   reports the failure as some confusing downstream symptom. Every wait helper
   must `XCTFail` when its condition never holds.
3. **Sleeping instead of waiting for a signal.** `await waitUntil(timeout: 0.5)
   { false }` — "give the task time to bail" — proves nothing and costs 0.5s
   every run. Wait on an effect the code actually produces (a call counter, a
   published state), then assert what must *not* have happened.

Genuine scale guards (`…ForOneAndTenThousandRecords`, `testLargeMovieRegroup…`,
the FTP socket-timeout tests) are worth their ~1s each and should be left alone.

## Tiered policy — which command when

1. **Inner loop (every change):** `tools/test-fast.sh` — auto-detects changed
   modules and runs only the covering suite(s). Or name them explicitly:
   `tools/test-fast.sh CoreModels FeatureAuth`. Preview with `--dry-run`.
2. **Pre-integration (handing a branch off):** `tools/test-fast.sh` already expands
   foundational changes to the affected set.
3. **Pre-merge / CI gate (before merging to main):** full sweep
   `tools/run-tests.sh` (no args) — build-once, all suites.

### `tools/test-fast.sh` usage
```
tools/test-fast.sh                 # diff vs merge-base with origin/main
tools/test-fast.sh --staged        # only staged changes
tools/test-fast.sh --base HEAD~3   # diff against a specific ref
tools/test-fast.sh CoreModels …    # explicit module or suite names
tools/test-fast.sh --dry-run …     # print the selection, don't run
```

## Notes / gotchas

- **`swift test` does not work on this Mac** — AetherEngine's FFmpeg binary
  xcframeworks are tvOS-only (no macOS slice), so SwiftPM resolution fails. It
  only runs in the Linux CI container. Locally, always use `tools/run-tests.sh` /
  `tools/test-fast.sh` (tvOS Simulator).
- **`export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"`** before any
  `swift`/`xcodebuild` invocation (the scripts set it themselves).
- **Data-driven, so it survives target churn.** When the WebDAV branch adds
  `MediaTransportWebDAV(+Tests)`, `run-tests.sh`, `test-fast.sh` and
  `test-impact.py` pick it up with no edits; a change to `MediaTransportCore` then
  automatically includes `MediaTransportWebDAVTests` in its impacted set.

## Known issues to fix (do NOT mask by weakening tests)

- **`FeatureHomeTests`** was previously quarantined (a data race in the shared
  `FakeMediaProvider` test double crashed the xctest host and hung the run). Fixed
  by locking the fake's counters; it now runs by default. No assertions weakened.
- The old "flaky Plex network-probe" tests are deterministic (injected `HTTPClient`
  doubles, fake hosts); only the occasional host-launch timing race remains, which
  the runner's retry-once absorbs.
