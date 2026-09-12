# Native Live TV regression fixture

This independent XcodeGen project supplies the `UIWindowScene` and native remote
input that a package-only test host cannot provide. It is deliberately separate
from `Package.swift` and the shipping app's `project.yml`. All fixture sources and
the project specification are checked in here; no private project, generated
source, or pre-existing `.build` content is required.

## Run

Requirements: Xcode with a tvOS 26-or-newer simulator, XcodeGen, and the repository's
normal Apple-build prerequisites. The current fixture was verified on tvOS 27.
Select the appropriate Xcode with `DEVELOPER_DIR` if it differs from `xcode-select`.

From the repository root:

```bash
# Choose an available tvOS simulator; do not use a physical device.
xcrun simctl list devices available
export TVOS_SIMULATOR_ID='REPLACE_WITH_TVOS_SIMULATOR_UDID'

# Needed for Swift package resolution on hosts enforcing explicit bare repos.
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"

xcodegen generate \
  --spec Tests/FeatureLiveTVRemoteTests/project.yml \
  --project Tests/FeatureLiveTVRemoteTests

tools/with-apple-build-lease.sh plozz-native-fixture -- \
  xcodebuild \
  -project Tests/FeatureLiveTVRemoteTests/LiveTVSearchFixture.xcodeproj \
  -scheme LiveTVSearchFixture \
  -destination "platform=tvOS Simulator,id=$TVOS_SIMULATOR_ID" \
  -derivedDataPath .build/live-tv-native-fixture \
  -resultBundlePath ".build/live-tv-native-results-$(date +%Y%m%d-%H%M%S).xcresult" \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:SearchFocusTests/LiveTVGuideFocusTests \
  -only-testing:SearchFocusTests/LiveTVSearchBoundaryTests \
  -only-testing:SearchFocusTests/LiveChannelFullscreenPresentationTests \
  -only-testing:SearchRemoteTests \
  test
```

Use a new result-bundle path for each run. Existing DerivedData can be reused; do
not clear shared caches. The generated `.xcodeproj` is ignored by Git. This command
does not regenerate the shipping app project or install the app on an Apple TV.

## Coverage and isolation

- Actual `PrototypeBrowser` inside native `PrototypeNativeSearch`: keyboard entry,
  every row in a 30-channel guide, reverse traversal, keyboard reentry, right-to-left
  programme rows, and Back from empty and filtered searches.
- Existing package Search focus, dismissal, retained-state, and row-boundary tests
  run in a scene-backed unit-test host.
- Existing native fullscreen tests verify output-surface identity, pending startup,
  retuning, and return-to-guide without their package-host scene skips. Their source
  file is referenced directly, not copied; the selectors above exclude unrelated
  player tests from this focused run.
- Source onboarding uses an isolated `ProfilesModel`, an empty in-memory source
  store, and an HTTP(S)-blocking `URLProtocol`. Smokes open the playlist form and
  return, inspect the no-server state, and navigate a
  typed Sources destination into its child editor and back. They assert zero
  configured sources, writes, and HTTP(S) requests, and no free-channel offers.
- Setup-card coverage checks matching dimensions, all three remote actions,
  stacked narrow/accessibility layouts, and right-to-left Light appearance.
  Screenshot attachments preserve each layout for visual review.
- Automatic-channel fixtures exercise the enable-first management route,
  preparing/empty/failure states, opt-out and optional custom-channel creation.
  They use isolated state and never generate channels from the user's libraries.
  Progress fixtures show a named library, real-shaped page/total counts, elapsed
  and waiting states, and verify that cancellation remains reachable.
- The actual Live TV Settings split view embeds source management directly.
  Smokes enter its playlist editor without a Manage sources intermediary, toggle
  a saved fixture source, and edit it directly. All stores remain isolated; the
  toggle writes only to the in-memory fixture and causes no network requests.
- Pinned navigation uses the production shell with 30 synthetic libraries and a
  selected Settings destination below the fold. Remote tests assert actual focus
  on entry, return to page controls, collapse, explicit opening and reentry after
  reordering, plus repeated entry and return around the native Search keyboard.
  They do not substitute focus-state assignments for remote input.

UI tests terminate their fixture application after each test. They do not access
real accounts, servers, playlists, production preferences, or playback streams.
