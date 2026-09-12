import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVServerGuideImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPlexDiscoversEntireLineupButOnlyWarmsFirstViewportAndFillsFocusedFutureChannel() async throws {
        let channels = (0..<2_000).map { ServerLiveTVChannel(id: "channel-\($0)", name: "Channel \($0)") }
        let provider = WindowGuideProvider(
            channels: channels, programs: [program("future", channelID: "channel-50", offset: 7 * 86_400)]
        )
        let (imports, model) = makeImport(provider, kind: .plex)
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 2_000)
        let initial = await provider.guideCalls
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial[0].channelIDs, Array(channels.prefix(12).map(\.id)))
        let id = try globalID("channel-50", in: imports)
        let start = now.addingTimeInterval(7 * 86_400)
        let end = start.addingTimeInterval(21_600)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .unrequested)
        XCTAssertEqual(imports.gapState(for: try XCTUnwrap(model.channel(id: id))), .unrequested)
        await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model)
        XCTAssertEqual(model.programs(for: id, from: start, hours: 6).map(\.title), ["future"])
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .noListings)
        let calls = await provider.guideCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].channelIDs, ["channel-50"])
        let catalogs = await provider.catalogLoads
        let opens = await provider.opens
        XCTAssertEqual(catalogs, 1)
        XCTAssertEqual(opens, 0)
    }

    func testFutureCoverageLongerThan48HoursSplitsRequestsWithoutLimitingOverallGuide() async throws {
        let provider = WindowGuideProvider(
            channels: channels,
            programs: [program("current", offset: 0), program("day-four", offset: 4 * 86_400)]
        )
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let start = now.addingTimeInterval(86_400)
        let end = now.addingTimeInterval(7 * 86_400 + 21_600)
        await imports.reloadServerGuides(channelIDs: [id, id], from: start, to: end, into: model)
        let allCalls = await provider.guideCalls
        let calls = Array(allCalls.dropFirst())
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.first?.from, start)
        XCTAssertEqual(calls.last?.to, end)
        XCTAssertTrue(calls.allSatisfy { $0.to.timeIntervalSince($0.from) <= 48 * 3_600 })
        XCTAssertTrue(calls.allSatisfy { $0.channelIDs == ["one"] })
        XCTAssertEqual(model.currentProgram(for: id)?.title, "current")
        XCTAssertEqual(
            model.programs(for: id, from: now.addingTimeInterval(4 * 86_400), hours: 6).map(\.title),
            ["day-four"]
        )
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .noListings)
    }

    func testBulkGuideSplitsLargeLineupIntoProviderSupportedChannelBatches() async throws {
        let channels = (0..<2_001).map { ServerLiveTVChannel(id: "channel-\($0)", name: "Channel \($0)") }
        let provider = WindowGuideProvider(channels: channels)
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let calls = await provider.guideCalls
        XCTAssertEqual(model.channels.count, 2_001)
        XCTAssertEqual(calls.map { $0.channelIDs.count }, [2_000, 1])
        XCTAssertEqual(calls.flatMap(\.channelIDs), channels.map(\.id))
        XCTAssertTrue(calls.allSatisfy { $0.to.timeIntervalSince($0.from) <= 48 * 3_600 })
        XCTAssertTrue(imports.serverChannelReferences.values.allSatisfy { $0.authorizationID == "active-profile" })
        XCTAssertTrue(model.channels.allSatisfy {
            imports.serverGuideState(channelID: $0.id, from: now, to: now.addingTimeInterval(21_600)) == .noListings
        })
    }

    func testWindowReplacementPreservesOtherChannelsAndPreviouslyFetchedWindows() async throws {
        let current = [program("one-now"), program("two-now", channelID: "two")]
        let firstFuture = now.addingTimeInterval(2 * 86_400)
        let secondFuture = now.addingTimeInterval(3 * 86_400)
        let provider = WindowGuideProvider(
            channels: channels,
            programs: current + [
                program("one-future", offset: 2 * 86_400),
                program("two-future", channelID: "two", offset: 2 * 86_400),
                program("one-later", offset: 3 * 86_400)
            ]
        )
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let one = try globalID("one", in: imports)
        let two = try globalID("two", in: imports)
        await imports.reloadServerGuides(
            channelIDs: [one, two], from: firstFuture, to: firstFuture.addingTimeInterval(21_600), into: model
        )
        await imports.reloadServerGuides(
            channelIDs: [one], from: secondFuture, to: secondFuture.addingTimeInterval(21_600), into: model
        )
        await provider.replacePrograms(current)
        await imports.reloadServerGuides(
            channelIDs: [one], from: firstFuture, to: firstFuture.addingTimeInterval(21_600),
            into: model, force: true
        )
        XCTAssertTrue(model.programs(for: one, from: firstFuture, hours: 6).isEmpty)
        XCTAssertEqual(model.programs(for: two, from: firstFuture, hours: 6).map(\.title), ["two-future"])
        XCTAssertEqual(model.programs(for: one, from: secondFuture, hours: 6).map(\.title), ["one-later"])
        XCTAssertEqual(model.currentProgram(for: one)?.title, "one-now")
        XCTAssertEqual(model.currentProgram(for: two)?.title, "two-now")
        XCTAssertEqual(imports.programCount, 4)
    }

    func testNeighborhoodRequestsReuseLoadedCoverageAndOnlyFetchMissingChannels() async throws {
        let provider = WindowGuideProvider(channels: channels)
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let one = try globalID("one", in: imports)
        let two = try globalID("two", in: imports)
        let start = now.addingTimeInterval(86_400)
        let end = start.addingTimeInterval(21_600)
        await imports.reloadServerGuides(channelIDs: [one], from: start, to: end, into: model)
        await imports.reloadServerGuides(channelIDs: [one, two], from: start, to: end, into: model)
        await imports.reloadServerGuides(channelIDs: [one, two], from: start, to: end, into: model)
        let calls = await provider.guideCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[1].channelIDs, ["one"])
        XCTAssertEqual(calls[2].channelIDs, ["two"])
        XCTAssertEqual(imports.serverGuideState(channelID: one, from: start, to: end), .noListings)
        XCTAssertEqual(imports.serverGuideState(channelID: two, from: start, to: end), .noListings)
    }

    func testViewportReusesIdenticalAndContainedInFlightInitialWarmup() async throws {
        let provider = WindowGuideProvider(channels: channels, programs: [program("current")])
        let (imports, model) = makeImport(provider)
        let started = expectation(description: "Initial warmup suspended")
        await provider.suspendNextGuide(started)
        let warmup = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        let id = try globalID("one", in: imports)
        await imports.reloadServerGuides(
            channelIDs: model.channels.map(\.id), from: now, to: now.addingTimeInterval(21_600), into: model
        )
        await imports.reloadServerGuides(
            channelIDs: [id], from: now.addingTimeInterval(3_600), to: now.addingTimeInterval(10_800), into: model
        )
        let calls = await provider.guideCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: now, to: now.addingTimeInterval(7_200)), .loading)
        await provider.resume()
        await warmup.value
        XCTAssertEqual(model.currentProgram(for: id)?.title, "current")
        XCTAssertFalse(imports.isLoading)
    }

    func testViewportFetchesOnlyNewChannelsWhileExistingNeighborhoodIsLoading() async throws {
        let channels = (0..<13).map { ServerLiveTVChannel(id: "channel-\($0)", name: "Channel \($0)") }
        let provider = WindowGuideProvider(
            channels: channels,
            programs: [
                program("warming", channelID: "channel-11"),
                program("new-channel", channelID: "channel-12")
            ]
        )
        let (imports, model) = makeImport(provider, kind: .plex)
        let started = expectation(description: "Initial neighborhood suspended")
        await provider.suspendNextGuide(started)
        let warmup = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        let warming = try globalID("channel-11", in: imports)
        let next = try globalID("channel-12", in: imports)
        await imports.reloadServerGuides(
            channelIDs: [warming, next], from: now, to: now.addingTimeInterval(21_600), into: model
        )
        let calls = await provider.guideCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.channelIDs, ["channel-12"])
        await provider.resume()
        await warmup.value
        XCTAssertEqual(model.currentProgram(for: warming)?.title, "warming")
        XCTAssertEqual(model.currentProgram(for: next)?.title, "new-channel")
        XCTAssertFalse(imports.isLoading)
    }

    func testPartialLoadingCoverageDoesNotSuppressFetchingUncoveredWindowTail() async throws {
        let start = now.addingTimeInterval(86_400)
        let provider = WindowGuideProvider(
            channels: channels, programs: [program("uncovered", offset: 86_400 + 12_600)]
        )
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let started = expectation(description: "Partial window suspended")
        await provider.suspendNextGuide(started)
        let pending = Task {
            await imports.reloadServerGuides(
                channelIDs: [id], from: start, to: start.addingTimeInterval(10_800), into: model
            )
        }
        await fulfillment(of: [started], timeout: 2)
        await imports.reloadServerGuides(
            channelIDs: [id], from: start.addingTimeInterval(7_200),
            to: start.addingTimeInterval(14_400), into: model
        )
        let calls = await provider.guideCalls
        XCTAssertEqual(calls.count, 3)
        await provider.resume()
        await pending.value
        XCTAssertEqual(model.programs(for: id, from: start.addingTimeInterval(10_800), hours: 1).map(\.title), ["uncovered"])
        XCTAssertFalse(imports.isLoading)
    }

    func testGuideOnlyFetchDoesNotRefreshOrAlterOtherConfiguredServers() async throws {
        let first = serverSource
        let second = LiveTVServerSource(id: "second", name: "Second", accountID: "other-account")
        let firstProvider = WindowGuideProvider(
            channels: channels, programs: [program("first-now"), program("first-future", offset: 86_400)]
        )
        let secondProvider = WindowGuideProvider(channels: channels, programs: [program("second-now")])
        let contexts = [
            first.accountID: context(firstProvider),
            second.accountID: LiveTVAuthorizedServerProvider(
                accountID: second.accountID, authorizationID: "other-profile", kind: .emby, provider: secondProvider
            )
        ]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [first, second]),
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let one = try XCTUnwrap(imports.serverChannelReferences.first {
            $0.value.sourceID == first.id && $0.value.channelID == "one"
        }?.key)
        let two = try XCTUnwrap(imports.serverChannelReferences.first {
            $0.value.sourceID == second.id && $0.value.channelID == "one"
        }?.key)
        let originalStatus = imports.serverSources.first { $0.id == second.id }
        let originalWindows = imports.serverGuideWindows.filter { $0.sourceID == second.id }
        await imports.reloadServerGuides(
            channelIDs: [one], from: now.addingTimeInterval(86_400),
            to: now.addingTimeInterval(86_400 + 21_600), into: model
        )
        XCTAssertEqual(model.currentProgram(for: two)?.title, "second-now")
        XCTAssertEqual(imports.serverSources.first { $0.id == second.id }, originalStatus)
        XCTAssertEqual(imports.serverGuideWindows.filter { $0.sourceID == second.id }, originalWindows)
        let calls = await secondProvider.guideCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].channelIDs, ["one", "two"])
    }

    func testFailureIsWindowSpecificAndDoesNotLabelLoadedEarlierGuideAsFailed() async throws {
        let provider = WindowGuideProvider(channels: channels, programs: [program("current")])
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let start = now.addingTimeInterval(86_400)
        let end = start.addingTimeInterval(21_600)
        await provider.setGuideFailure(.invalidGuideWindow)
        await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .failed)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: now, to: now.addingTimeInterval(21_600)), .noListings)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "current")
        XCTAssertEqual(imports.serverSources[0].guideFailure, .invalidGuide)
        await provider.setGuideFailure(nil)
        await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .noListings)
        XCTAssertNil(imports.serverSources[0].guideFailure)
    }

    func testOversizedWindowPreservesLastGoodScheduleAndReportsSanitizedGuideFailure() async throws {
        let provider = WindowGuideProvider(
            channels: channels, programs: [program("current"), program("last-good", offset: 86_400)]
        )
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let start = now.addingTimeInterval(86_400)
        let end = start.addingTimeInterval(21_600)
        await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model)
        await provider.replacePrograms([
            ServerLiveTVProgramme(
                id: "oversized", channelID: "one",
                title: String(repeating: "x", count: LiveTVXMLTVParser.maximumRetainedTextBytes + 1),
                startDate: start, endDate: start.addingTimeInterval(3_600)
            )
        ])
        await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model, force: true)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "current")
        XCTAssertEqual(model.programs(for: id, from: start, hours: 6).map(\.title), ["last-good"])
        XCTAssertEqual(imports.serverSources[0].guideFailure, .invalidGuide)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .failed)
        XCTAssertNotNil(imports.serverGuideWindows.last?.lastRefresh)
    }

    func testLateOverlappingRequestCannotOverwriteNewerWindowResults() async throws {
        let start = now.addingTimeInterval(86_400)
        let end = start.addingTimeInterval(21_600)
        let provider = WindowGuideProvider(channels: channels, programs: [program("stale", offset: 86_400)])
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let started = expectation(description: "Old window suspended")
        await provider.suspendNextGuide(started)
        let old = Task { await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .loading)
        await provider.replacePrograms([program("fresh", offset: 86_400)])
        await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model, force: true)
        await provider.resume()
        await old.value
        let calls = await provider.guideCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(model.programs(for: id, from: start, hours: 6).map(\.title), ["fresh"])
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .noListings)
    }

    func testDisjointWindowsCanFinishOutOfOrderWithoutLosingEitherSchedule() async throws {
        let first = now.addingTimeInterval(86_400)
        let second = now.addingTimeInterval(2 * 86_400)
        let provider = WindowGuideProvider(
            channels: channels, programs: [program("first", offset: 86_400), program("second", offset: 2 * 86_400)]
        )
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let started = expectation(description: "First window suspended")
        await provider.suspendNextGuide(started)
        let old = Task {
            await imports.reloadServerGuides(
                channelIDs: [id], from: first, to: first.addingTimeInterval(21_600), into: model
            )
        }
        await fulfillment(of: [started], timeout: 2)
        await imports.reloadServerGuides(
            channelIDs: [id], from: second, to: second.addingTimeInterval(21_600), into: model
        )
        await provider.resume()
        await old.value
        XCTAssertEqual(model.programs(for: id, from: first, hours: 6).map(\.title), ["first"])
        XCTAssertEqual(model.programs(for: id, from: second, hours: 6).map(\.title), ["second"])
        XCTAssertFalse(imports.isLoading)
    }

    func testRemovingSourceDuringWindowFetchCannotRepublishItsGuideOrChannels() async throws {
        let provider = WindowGuideProvider(channels: channels, programs: [program("future", offset: 86_400)])
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let started = expectation(description: "Window suspended")
        await provider.suspendNextGuide(started)
        let task = Task {
            await imports.reloadServerGuides(
                channelIDs: [id], from: now.addingTimeInterval(86_400),
                to: now.addingTimeInterval(86_400 + 21_600), into: model
            )
        }
        await fulfillment(of: [started], timeout: 2)
        try imports.applyConfiguration(.empty, into: model)
        await provider.resume()
        await task.value
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertTrue(imports.serverGuideWindows.isEmpty)
        XCTAssertEqual(imports.programCount, 0)
        XCTAssertFalse(imports.isLoading)
    }

    func testProfileChangeDuringWindowFetchRejectsDataFromPreviousAuthorization() async throws {
        let provider = WindowGuideProvider(channels: channels, programs: [program("future", offset: 86_400)])
        let authorization = WindowAuthorization()
        let source = serverSource
        authorization.context = context(provider, authorizationID: "old-profile")
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [source]),
            serverProviderResolver: { _ in authorization.context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let started = expectation(description: "Window suspended")
        await provider.suspendNextGuide(started)
        let task = Task {
            await imports.reloadServerGuides(
                channelIDs: [id], from: now.addingTimeInterval(86_400),
                to: now.addingTimeInterval(86_400 + 21_600), into: model
            )
        }
        await fulfillment(of: [started], timeout: 2)
        authorization.context = context(provider, authorizationID: "new-profile")
        await provider.resume()
        await task.value
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertTrue(imports.serverGuideWindows.isEmpty)
        XCTAssertEqual(imports.serverSources[0].failure, .accountUnavailable)
    }

    func testCancelledWindowRemainsUnrequestedWhilePreviouslyLoadedGuideSurvives() async throws {
        let provider = WindowGuideProvider(channels: channels, programs: [program("current")])
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        let start = now.addingTimeInterval(86_400)
        let end = start.addingTimeInterval(21_600)
        let started = expectation(description: "Window suspended")
        await provider.suspendNextGuide(started)
        let task = Task { await imports.reloadServerGuides(channelIDs: [id], from: start, to: end, into: model) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await provider.resume()
        await task.value
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: start, to: end), .unrequested)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "current")
        XCTAssertNil(imports.serverSources[0].guideFailure)
        XCTAssertFalse(imports.isLoading)
    }

    func testCancelledExplicitRefreshRetainsPreviouslyLoadedWindowCoverage() async throws {
        let provider = WindowGuideProvider(channels: channels, programs: [program("current")])
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let ids = model.channels.map(\.id)
        let start = now
        let end = now.addingTimeInterval(21_600)
        let started = expectation(description: "Refresh suspended")
        await provider.suspendNextGuide(started)
        let task = Task {
            await imports.reloadServerGuides(channelIDs: ids, from: start, to: end, into: model, force: true)
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await provider.resume()
        await task.value
        XCTAssertTrue(ids.allSatisfy {
            imports.serverGuideState(channelID: $0, from: start, to: end) == .noListings
        })
        XCTAssertEqual(imports.serverSources[0].guidePhase, .loaded)
        XCTAssertFalse(imports.isLoading)
    }

    func testDisablingOrChangingAccountDuringWindowFetchInvalidatesOnlyThatSource() async throws {
        for disable in [true, false] {
            let provider = WindowGuideProvider(channels: channels, programs: [program("future", offset: 86_400)])
            let (imports, model) = makeImport(provider)
            await imports.reload(into: model)
            let id = try globalID("one", in: imports)
            let start = now.addingTimeInterval(86_400)
            let started = expectation(description: "Window suspended")
            await provider.suspendNextGuide(started)
            let task = Task {
                await imports.reloadServerGuides(
                    channelIDs: [id], from: start, to: start.addingTimeInterval(21_600), into: model
                )
            }
            await fulfillment(of: [started], timeout: 2)
            var updated = serverSource
            if disable { updated.isEnabled = false }
            else { updated.accountID = "different-account" }
            try imports.applyConfiguration(LiveTVSourcesConfiguration(servers: [updated]), into: model)
            await provider.resume()
            await task.value
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertTrue(imports.serverGuideWindows.isEmpty)
            XCTAssertEqual(imports.programCount, 0)
            XCTAssertFalse(imports.isLoading)
        }
    }

    func testNoGuideCapabilityAndInvalidWindowDoNotTriggerRequests() async throws {
        let provider = WindowGuideProvider(channels: channels, supportsGuide: false)
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        await imports.reloadServerGuides(channelIDs: [id], from: now, to: now.addingTimeInterval(21_600), into: model)
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: now, to: now.addingTimeInterval(21_600)), .disabled)
        await imports.reloadServerGuides(channelIDs: [id], from: now, to: now, into: model)
        let calls = await provider.guideCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(imports.serverSources[0].guideFailure, .invalidGuide)
    }

    func testWindowMetadataIsBoundedWithoutDeletingUnrelatedRetainedProgrammes() async throws {
        let provider = WindowGuideProvider(channels: channels, programs: [program("current")])
        let (imports, model) = makeImport(provider)
        await imports.reload(into: model)
        let id = try globalID("one", in: imports)
        for offset in 1...140 {
            let start = now.addingTimeInterval(Double(offset) * 21_600)
            await imports.reloadServerGuides(
                channelIDs: [id], from: start, to: start.addingTimeInterval(21_600), into: model
            )
        }
        XCTAssertLessThanOrEqual(imports.serverGuideWindows.count, 128)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "current")
        XCTAssertFalse(imports.isLoading)
    }

    func testChannelRemovedThenRediscoveredDoesNotReuseCoverageForDiscardedSchedule() async throws {
        let channels = (0..<30).map { ServerLiveTVChannel(id: "channel-\($0)", name: "Channel \($0)") }
        let provider = WindowGuideProvider(
            channels: channels, programs: [program("twenty", channelID: "channel-20")]
        )
        let (imports, model) = makeImport(provider, kind: .plex)
        await imports.reload(into: model)
        let id = try globalID("channel-20", in: imports)
        let end = now.addingTimeInterval(21_600)
        await imports.reloadServerGuides(channelIDs: [id], from: now, to: end, into: model)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "twenty")
        await provider.replaceChannels(Array(channels.prefix(12)))
        await imports.reloadServers(into: model)
        XCTAssertNil(model.channel(id: id))
        await provider.replaceChannels(channels)
        await imports.reloadServers(into: model)
        XCTAssertNotNil(model.channel(id: id))
        XCTAssertNil(model.currentProgram(for: id))
        XCTAssertEqual(imports.serverGuideState(channelID: id, from: now, to: end), .unrequested)
    }

    private var channels: [ServerLiveTVChannel] {
        ["one", "two"].map { ServerLiveTVChannel(id: $0, name: $0) }
    }

    private var serverSource: LiveTVServerSource {
        LiveTVServerSource(id: "server", name: "Server", accountID: "account")
    }

    private func program(_ title: String, channelID: String = "one", offset: TimeInterval = 0) -> ServerLiveTVProgramme {
        ServerLiveTVProgramme(
            id: title, channelID: channelID, title: title,
            startDate: now.addingTimeInterval(offset), endDate: now.addingTimeInterval(offset + 3_600)
        )
    }

    private func context(
        _ provider: WindowGuideProvider, kind: LiveTVPrototypeSource = .jellyfin,
        authorizationID: String = "active-profile"
    ) -> LiveTVAuthorizedServerProvider {
        LiveTVAuthorizedServerProvider(
            accountID: serverSource.accountID, authorizationID: authorizationID, kind: kind, provider: provider
        )
    }

    private func makeImport(
        _ provider: WindowGuideProvider, kind: LiveTVPrototypeSource = .jellyfin
    ) -> (LiveTVPrototypeImportModel, LiveTVPrototypeModel) {
        let authorized = context(provider, kind: kind)
        return (
            LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: [serverSource]),
                serverProviderResolver: { _ in authorized }
            ),
            LiveTVPrototypeModel(now: now, channels: [])
        )
    }

    private func globalID(_ nativeID: String, in imports: LiveTVPrototypeImportModel) throws -> String {
        try XCTUnwrap(imports.serverChannelReferences.first { $0.value.channelID == nativeID }?.key)
    }
}

@MainActor
private final class WindowAuthorization {
    var context: LiveTVAuthorizedServerProvider?
}

private actor WindowGuideProvider: ServerLiveTVProviding {
    struct GuideCall: Sendable {
        let channelIDs: [String]
        let from: Date
        let to: Date
    }

    var channels: [ServerLiveTVChannel]
    var programs: [ServerLiveTVProgramme]
    let supportsGuide: Bool
    var suspended: XCTestExpectation?
    var continuation: CheckedContinuation<Void, Never>?
    var guideFailure: ServerLiveTVError?
    private(set) var guideCalls: [GuideCall] = []
    private(set) var catalogLoads = 0
    private(set) var opens = 0

    init(channels: [ServerLiveTVChannel], programs: [ServerLiveTVProgramme] = [], supportsGuide: Bool = true) {
        self.channels = channels
        self.programs = programs
        self.supportsGuide = supportsGuide
    }

    func replacePrograms(_ value: [ServerLiveTVProgramme]) { programs = value }
    func replaceChannels(_ value: [ServerLiveTVChannel]) { channels = value }
    func setGuideFailure(_ value: ServerLiveTVError?) { guideFailure = value }
    func suspendNextGuide(_ expectation: XCTestExpectation) { suspended = expectation }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        ServerLiveTVAvailability(status: .available, channelCount: channels.count, supportsGuide: supportsGuide)
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        catalogLoads += 1
        return channels
    }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        guideCalls.append(GuideCall(channelIDs: channelIDs, from: from, to: to))
        let requested = Set(channelIDs)
        let response = programs.filter { requested.contains($0.channelID) && $0.endDate > from && $0.startDate < to }
        let failure = guideFailure
        if let expectation = suspended {
            suspended = nil
            await withCheckedContinuation {
                continuation = $0
                expectation.fulfill()
            }
        }
        if let failure { throw failure }
        return response
    }

    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        opens += 1
        throw ServerLiveTVError.unsupportedPlaybackMode
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
