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
The new entrance uses 550ms for the zoom, a 500ms artwork pause, and overlapping
320ms foreground reveals spaced 180ms apart. Back uses a 380ms return without
the pause. Reduce Motion bypasses the custom sequence and its input wait.
Source snapshots are per-activation, not per-frame; full-window covers are
released after the zoom, and the small return-card image is scoped to its page.

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
Episode previews stay drawn but cannot take entry focus during a whole-show
entrance; episode-context opens retain their existing initial-focus behavior.

Opening motion starts in the card/router activation, before creating the detail
page, and a late destination adopts that in-flight entrance instead of replaying
it. Render-server snapshots avoid a full-window bitmap draw on the main thread.
The hosted tests also delay destination mounting and withhold return focus to
verify that neither creates a new pre-animation wait.

Back restores the captured source page behind the moving artwork immediately,
not a snapshot of the outgoing detail page. Its real content is hidden during
the pop. Coverage deliberately delays the native pop by 250ms and samples an
uncovered corner during the reverse animation. The source-page snapshot is
released after returning, on a memory warning, or with the page's lifetime.

Card focus has three independent options: System (native tvOS projection),
Highlight (custom sheen/lean) and Outline (custom glass). Absent per-profile
preferences use System; saved `highlight` and `outlined` values are not migrated.
The System path must not instantiate custom focus growth, sheen, lean, halo or
settling tasks. System uses standard SwiftUI `Button` controls with the native
`.borderless` style and `.hoverEffect(.automatic)` on artwork. The OS owns focus
motion and accessibility appearance. There is no UIKit carrier image, hosted
overlay, custom focus callback bridge, forced lift, or app-level High Contrast
override. Highlight and Outline retain their existing custom treatments.

Media-card focus uses `PlozzCardFocus`, a shared wrapper around the platform's
`FocusState`. Raw `FocusState` surfaces with independent focus chrome, such as
multiview picture controls, retain ordinary SwiftUI focus.
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
