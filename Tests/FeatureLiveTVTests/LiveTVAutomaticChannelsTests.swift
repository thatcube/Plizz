#if DEBUG && canImport(SwiftUI)
import CoreModels
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVAutomaticChannelsTests: XCTestCase {
    func testDisabledDoesNotClaimAnEnabledEmptyLineup() {
        let value = state()
        XCTAssertEqual(value.status, .disabled)
        XCTAssertFalse(value.needsEmptyState)
    }

    func testPreparingEmptyFailureAndReadyRemainDistinct() {
        XCTAssertEqual(state(enabled: true, working: true).status, .preparing)
        XCTAssertEqual(state(enabled: true).status, .empty)
        XCTAssertEqual(state(enabled: true, count: 5).status, .ready)
        XCTAssertEqual(state(enabled: true, issue: .sourceUnavailable).status, .failed(.sourceUnavailable))
        for value in [
            state(enabled: true), state(enabled: true, working: true),
            state(enabled: true, count: 5), state(issue: .storageFailed)
        ] {
            XCTAssertTrue(value.needsEmptyState)
        }
    }

    func testFailureDoesNotDisappearBehindDisabledOrPreviouslyReadyState() {
        XCTAssertEqual(state(issue: .storageFailed).status, .failed(.storageFailed))
        XCTAssertEqual(state(enabled: true, issue: .sourceUnavailable, count: 5).status, .failed(.sourceUnavailable))
    }

    func testEnableDisableAndRetryUseOnlyTheirInjectedActions() async {
        var enabledValues: [Bool] = []
        var retries = 0
        let action = LiveTVAutomaticChannelsAction()
        let disabled = state(setEnabled: { enabledValues.append($0) })
        await action.setEnabled(true, state: disabled, canManage: { true })
        let enabled = state(
            enabled: true, setEnabled: { enabledValues.append($0) }, retry: { retries += 1 })
        action.retry(state: enabled, canManage: { true })
        await action.setEnabled(false, state: enabled, canManage: { true })
        XCTAssertEqual(enabledValues, [true, false])
        XCTAssertEqual(retries, 1)
        XCTAssertFalse(action.isUpdating)
    }

    func testRepeatedEnableIsIgnoredWhileAnActionIsSuspended() async {
        let action = LiveTVAutomaticChannelsAction()
        var calls = 0
        var finish: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Enable callback started")
        let value = state(setEnabled: { _ in
            calls += 1
            await withCheckedContinuation {
                finish = $0
                started.fulfill()
            }
        })
        let first = Task { await action.setEnabled(true, state: value, canManage: { true }) }
        await fulfillment(of: [started], timeout: 2)
        await action.setEnabled(true, state: value, canManage: { true })
        XCTAssertEqual(calls, 1)
        finish?.resume()
        await first.value
        XCTAssertFalse(action.isUpdating)
    }

    func testCancelledUIActionDoesNotChangeThePreference() async {
        var calls = 0
        let action = LiveTVAutomaticChannelsAction()
        let value = state(setEnabled: { _ in calls += 1 })
        let task = Task { await action.setEnabled(true, state: value, canManage: { true }) }
        task.cancel()
        await task.value
        XCTAssertEqual(calls, 0)
    }

    func testRevokedManagementAccessBlocksEnableDisableAndRetry() async {
        var calls = 0
        let action = LiveTVAutomaticChannelsAction()
        let value = state(enabled: true, setEnabled: { _ in calls += 1 }, retry: { calls += 1 })
        await action.setEnabled(false, state: value, canManage: { false })
        await action.setEnabled(true, state: state(setEnabled: { _ in calls += 1 }), canManage: { false })
        action.retry(state: value, canManage: { false })
        XCTAssertEqual(calls, 0)
    }

    func testGenerationBlocksRepeatedEnableAndRetryButAllowsOptOut() async {
        var values: [Bool] = []
        var retries = 0
        let action = LiveTVAutomaticChannelsAction()
        let preparing = state(
            enabled: true, working: true, setEnabled: { values.append($0) }, retry: { retries += 1 })
        await action.setEnabled(true, state: preparing, canManage: { true })
        action.retry(state: preparing, canManage: { true })
        await action.setEnabled(false, state: preparing, canManage: { true })
        XCTAssertEqual(values, [false])
        XCTAssertEqual(retries, 0)
    }

    func testDisabledPreferenceFailureCanRetryWithoutOptingIn() {
        var enabledValues: [Bool] = []
        var retries = 0
        let value = state(
            issue: .storageFailed, setEnabled: { enabledValues.append($0) }, retry: { retries += 1 })
        LiveTVAutomaticChannelsAction().retry(state: value, canManage: { true })
        XCTAssertEqual(retries, 1)
        XCTAssertTrue(enabledValues.isEmpty)
    }

    func testGeneratedDefinitionsNeverAppearInTheCustomEditorSection() {
        let custom = LibraryChannelDefinition(profileID: "profile", revisions: [])
        let generated = LibraryChannelDefinition(profileID: "profile", revisions: [], automaticKey: "movies")
        let sections = LibraryChannelManagementLineup(definitions: [custom, generated])
        XCTAssertEqual(sections.automatic.map(\.id), [generated.id])
        XCTAssertEqual(sections.custom.map(\.id), [custom.id])
    }

    private func state(
        enabled: Bool = false, working: Bool = false, issue: LibraryChannelError? = nil, count: Int = 0,
        setEnabled: @escaping @MainActor (Bool) async -> Void = { _ in },
        retry: @escaping @MainActor () -> Void = {}
    ) -> LiveTVAutomaticChannelsState {
        LiveTVAutomaticChannelsState(
            enabled: enabled, isWorking: working, issue: issue,
            channelCount: count, skippedItemCount: 0, setEnabled: setEnabled, retry: retry)
    }
}
#endif
