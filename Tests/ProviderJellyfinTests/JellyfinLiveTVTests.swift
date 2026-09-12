import Foundation
import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

final class JellyfinLiveTVTests: XCTestCase {
    private let channelID = "123"
    private let opening = """
    {"PlaySessionId":"play-fixture","MediaSources":[
      {"Id":"source-fixture","RequiresOpening":true,"OpenToken":"open-fixture"}
    ]}
    """
    private let opened = """
    {"MediaSource":{"Id":"source-fixture","LiveStreamId":"live-fixture",
     "Container":"ts","SupportsDirectStream":true,"MediaStreams":[{"Type":"Video"}]}}
    """

    private func provider(
        _ http: LiveTVFixtureHTTP,
        kind: ProviderKind = .jellyfin,
        token: String = "fixture-user-token",
        revision: CredentialRevision = CredentialRevision()
    ) -> JellyfinProvider {
        JellyfinProvider(
            session: UserSession(
                server: MediaServer(
                    id: "fixture-server", name: "Fixture server",
                    baseURL: URL(string: "https://server.invalid/mediabrowser")!,
                    provider: kind
                ),
                userID: "fixture-user", userName: "Fixture user",
                deviceID: "fixture-device", accessToken: token
            ),
            accountID: "fixture-account", credentialRevision: revision,
            http: http, interactiveHTTP: http
        )
    }

    private func playbackHTTP(
        openResponse: String? = nil, gate: LiveTVFixtureGate? = nil
    ) -> LiveTVFixtureHTTP {
        LiveTVFixtureHTTP([
            "/Items/123/PlaybackInfo": [.init(json: opening)],
            "/LiveStreams/Open": [.init(json: openResponse ?? opened, gate: gate)]
        ])
    }

    func testNoConfiguredTunerNeverNegotiatesPlayback() async throws {
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Info": [.init(json: #"{"IsEnabled":false,"Services":[]}"#)]
        ])
        let availability = try await provider(http).liveTVAvailability()
        XCTAssertEqual(availability.status, .notConfigured)
        XCTAssertFalse(availability.hasChannels)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/LiveTv/Info"])
    }

    func testEnabledBuiltInServiceWithNoChannelsIsNotReady() async throws {
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Info": [.init(json: #"{"IsEnabled":true,"Services":[{"Status":"Ok"}]}"#)],
            "/LiveTv/Channels": [.init(json: #"{"Items":[],"TotalRecordCount":0}"#)]
        ])
        let availability = try await provider(http).liveTVAvailability()
        XCTAssertEqual(availability.status, .noChannels)
        XCTAssertFalse(availability.supportsPlayback)
    }

    func testPermissionAuthenticationAndMissingAPIStayDistinct() async throws {
        for (status, expected) in [
            (403, ServerLiveTVAvailability.Status.permissionDenied), (404, .unsupportedAPI)
        ] {
            let http = LiveTVFixtureHTTP(["/LiveTv/Info": [.init(status: status)]])
            let result = try await provider(http).liveTVAvailability()
            XCTAssertEqual(result.status, expected)
        }
        let unauthorized = LiveTVFixtureHTTP(["/LiveTv/Info": [.init(status: 401)]])
        do {
            _ = try await provider(unauthorized).liveTVAvailability()
            XCTFail("Authentication failures must not become an empty tuner list")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
        let offline = LiveTVFixtureHTTP(["/LiveTv/Info": [.init(error: .serverUnreachable)]])
        do {
            _ = try await provider(offline).liveTVAvailability()
            XCTFail("Offline is not unconfigured")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
    }

    func testChannelPaginationNativeIdentityAndCurrentProgramme() async throws {
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Channels": [
                .init(json: """
                {"TotalRecordCount":3,"Items":[
                  {"Id":"1","Name":"News","ChannelNumber":"7.1",
                   "CurrentProgram":{"Id":"p1","Name":"Morning",
                   "StartDate":"2026-09-09T07:00:00-07:00","EndDate":"2026-09-09T08:00:00-07:00"}},
                  {"Id":"2","Name":"News","ChannelType":"Radio"}]}
                """),
                .init(json: #"{"TotalRecordCount":3,"Items":[{"Id":"3","Name":"Cinema"}]}"#)
            ]
        ])
        let channels = try await provider(http).liveTVChannels()
        XCTAssertEqual(channels.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(channels[0].currentProgramme?.channelID, "1")
        XCTAssertEqual(channels[0].number, "7.1")
        XCTAssertTrue(channels[1].isRadio)
        XCTAssertFalse(channels[0].imageURL!.absoluteString.contains("token"))
        let requests = await http.requests
        XCTAssertEqual(requests.map { $0.query("StartIndex") }, ["0", "2"])
        XCTAssertTrue(requests.allSatisfy { $0.query("UserId") == "fixture-user" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"]?.contains("fixture-user-token") == true })
    }

    func testRepeatedPaginationDoesNotLoopOrSilentlyTruncate() async throws {
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Channels": [.init(json: #"{"TotalRecordCount":20,"Items":[{"Id":"1","Name":"News"}]}"#)]
        ])
        do {
            _ = try await provider(http).liveTVChannels()
            XCTFail("A repeated page is not a complete catalog")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testGuideUsesOverlapFiltersAndRejectsUnrelatedOrMalformedAirings() async throws {
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Programs": [.init(json: """
            {"Items":[
              {"Id":"p1","ChannelId":"123","Name":"In progress","StartDate":"2026-09-09T09:30:00Z","EndDate":"2026-09-09T10:30:00.000Z"},
              {"Id":"p2","ChannelId":"other","Name":"Wrong channel","StartDate":"2026-09-09T10:00:00Z","EndDate":"2026-09-09T11:00:00Z"},
              {"Id":"p3","ChannelId":"123","Name":"Broken","StartDate":"bad","EndDate":"2026-09-09T11:00:00Z"},
              {"Id":"p4","ChannelId":"123","Name":"Ended","StartDate":"2026-09-09T09:00:00Z","EndDate":"2026-09-09T10:00:00Z"}
            ]}
            """)]
        ])
        let start = ISO8601DateFormatter().date(from: "2026-09-09T10:00:00Z")!
        let programmes = try await provider(http).liveTVGuide(
            channelIDs: ["123"], from: start, to: start.addingTimeInterval(3_600)
        )
        XCTAssertEqual(programmes.map(\.title), ["In progress"])
        let requests = await http.requests
        XCTAssertEqual(requests[0].query("MinEndDate"), "2026-09-09T10:00:00Z")
        XCTAssertEqual(requests[0].query("MaxStartDate"), "2026-09-09T11:00:00Z")
        XCTAssertNil(requests[0].query("MinStartDate"))
        XCTAssertTrue(requests.allSatisfy { $0.method == .get })
    }

    func testExplicitOpenReportingAndConcurrentCloseKeepOpeningIdentity() async throws {
        let http = playbackHTTP()
        let revision = CredentialRevision()
        let provider = provider(http, revision: revision)
        let lease = try await provider.openLiveTVChannel(id: channelID)
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            await lease.close()
            return XCTFail("Live server playback must remain authenticated")
        }
        XCTAssertEqual(locator.accountID, "fixture-account")
        XCTAssertEqual(locator.credentialRevision, revision)
        XCTAssertEqual(locator.resource.path, "Videos/123/stream.ts")
        XCTAssertEqual(locator.resource.pathBase, .configuredBaseURL)
        XCTAssertEqual(locator.playSessionID, "play-fixture")
        XCTAssertEqual(locator.resource.queryItems.first { $0.name == "LiveStreamId" }?.value, "live-fixture")
        XCTAssertFalse(locator.resource.queryItems.contains { $0.name.lowercased().contains("token") })

        await lease.report(.init(state: .started))
        await lease.report(.init(state: .started))
        await lease.report(.init(state: .paused, positionSeconds: 2.5))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { await lease.close() } }
        }
        await lease.report(.init(state: .playing, positionSeconds: 5))
        await provider.teardown()
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Open" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/Videos/ActiveEncodings" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/Sessions/Playing" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/Sessions/Playing/Progress" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/Sessions/Playing/Stopped" }.count, 1)
        let stopped = try XCTUnwrap(requests.first { $0.path == "/Sessions/Playing/Stopped" })
        XCTAssertEqual(stopped.json?["LiveStreamId"] as? String, "live-fixture")
        XCTAssertEqual(stopped.json?["MediaSourceId"] as? String, "source-fixture")
        XCTAssertEqual(stopped.json?["PositionTicks"] as? Int, 25_000_000)
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"]?.contains("fixture-user-token") == true })
        XCTAssertTrue(requests.allSatisfy { $0.redirectPolicy == .sameOrigin })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Cache-Control"] == "no-store" })
        let negotiation = try XCTUnwrap(requests.first { $0.path.hasSuffix("/PlaybackInfo") })
        XCTAssertEqual(negotiation.json?["AutoOpenLiveStream"] as? Bool, false)
        XCTAssertNotNil(negotiation.json?["DeviceProfile"])
        let open = try XCTUnwrap(requests.first { $0.path == "/LiveStreams/Open" })
        XCTAssertEqual(open.json?["OpenToken"] as? String, "open-fixture")
        XCTAssertNil(open.query("OpenToken"))
        XCTAssertEqual(open.json?["ItemId"] as? String, "123")
    }

    func testEmbyOpenUsesNumericItemIDAndAccepts200Close() async throws {
        let http = playbackHTTP()
        await http.set("/LiveStreams/Close", replies: [.init(status: 200)])
        let lease = try await provider(http, kind: .emby).openLiveTVChannel(id: channelID)
        await lease.close()
        let requests = await http.requests
        let open = try XCTUnwrap(requests.first { $0.path == "/LiveStreams/Open" })
        XCTAssertEqual(open.json?["ItemId"] as? Int, 123)
        XCTAssertFalse(open.json?["ItemId"] is String)
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            return XCTFail("Expected authenticated locator")
        }
        XCTAssertEqual(locator.provider, .emby)
    }

    func testEmbyAuthorizedNativeLineupTunesWithoutGuideOrAdministrativeDiscovery() async throws {
        // Independent Emby-shaped fixture: numeric item identity and already-open
        // live source, not a relabeled Jellyfin RequiresOpening fixture.
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Info": [.init(json: #"{"IsEnabled":true,"EnabledUsers":["fixture-user"]}"#)],
            "/LiveTv/Channels": [.init(json: """
            {"Items":[{"Id":"847","Name":"Emby antenna","ChannelNumber":"5.2",
              "ChannelType":"TV"}],"TotalRecordCount":1}
            """)],
            "/Items/847/PlaybackInfo": [.init(json: """
            {"PlaySessionId":"emby-viewer","MediaSources":[{
              "Id":"emby-source","LiveStreamId":"emby-own-consumer",
              "RequiresOpening":false,"SupportsDirectStream":true,
              "Container":"ts","MediaStreams":[{"Type":"Video"}]}]}
            """)]
        ])
        let provider = provider(http, kind: .emby)
        let available = try await provider.liveTVAvailability()
        XCTAssertEqual(available.status, .available)
        XCTAssertEqual(available.channelCount, 1)
        let channels = try await provider.liveTVChannels()
        XCTAssertNil(channels.first?.currentProgramme)
        let lease = try await provider.openLiveTVChannel(id: "847")
        await lease.close()
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            return XCTFail("Expected account-scoped Emby stream")
        }
        XCTAssertEqual(locator.provider, .emby)
        XCTAssertEqual(locator.resource.path, "Videos/847/stream.ts")
        XCTAssertEqual(locator.playSessionID, "emby-viewer")
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path == "/LiveStreams/Open" })
        XCTAssertFalse(requests.contains { $0.path.contains("TunerHosts") || $0.path.contains("Configuration") })
        XCTAssertEqual(requests.first { $0.path == "/LiveStreams/Close" }?.query("LiveStreamId"), "emby-own-consumer")
    }

    func testEmbyEnabledUsersRestrictionDoesNotBecomeEmptyLineup() async throws {
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Info": [.init(json: #"{"IsEnabled":true,"EnabledUsers":["other-user"]}"#)]
        ])
        let availability = try await provider(http, kind: .emby).liveTVAvailability()
        XCTAssertEqual(availability.status, .permissionDenied)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/LiveTv/Info"])
    }

    func testEmbyExplicitEntitlementResponseIsNotPermissionDeniedOrUnconfigured() async throws {
        // Protocol error fixture, not evidence that every Emby version returns 402.
        let http = LiveTVFixtureHTTP(["/LiveTv/Info": [.init(status: 402)]])
        let availability = try await provider(http, kind: .emby).liveTVAvailability()
        XCTAssertEqual(availability.status, .subscriptionRequired)
        XCTAssertFalse(availability.supportsPlayback)
    }

    func testMissingEmbySubscriptionMetadataDoesNotInventEntitlementFailure() async throws {
        let http = LiveTVFixtureHTTP([
            "/LiveTv/Info": [.init(json: #"{"IsEnabled":true,"EnabledUsers":["fixture-user"]}"#)],
            "/LiveTv/Channels": [.init(json: #"{"Items":[],"TotalRecordCount":0}"#)]
        ])
        let availability = try await provider(http, kind: .emby).liveTVAvailability()
        XCTAssertEqual(availability.status, .noChannels)
    }

    func testCancellationWaitsForLateOpenAndRollsItBack() async throws {
        let gate = LiveTVFixtureGate()
        let http = playbackHTTP(gate: gate)
        let provider = provider(http)
        let task = Task { try await provider.openLiveTVChannel(id: "123") }
        let requested = await http.expectationForRequest("/LiveStreams/Open")
        await fulfillment(of: [requested], timeout: 2)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled opens must not return a lease")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/Videos/ActiveEncodings" }.count, 1)
    }

    func testProviderRetirementDuringOpenRollsBackWithOriginalCredentials() async throws {
        let gate = LiveTVFixtureGate()
        let http = playbackHTTP(gate: gate)
        let provider = provider(http, token: "opening-identity-token")
        let task = Task { try await provider.openLiveTVChannel(id: "123") }
        let requested = await http.expectationForRequest("/LiveStreams/Open")
        await fulfillment(of: [requested], timeout: 2)
        await provider.teardown()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("An evicted provider cannot publish a new lease")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await http.requests
        let close = try XCTUnwrap(requests.first { $0.path == "/LiveStreams/Close" })
        XCTAssertTrue(close.headers["Authorization"]?.contains("opening-identity-token") == true)
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
    }

    func testMalformedOpenedPayloadStillReleasesItsKnownHandle() async throws {
        let http = playbackHTTP(openResponse: """
        {"MediaSource":{"LiveStreamId":"live-fixture","Container":{"unexpected":"shape"}}}
        """)
        do {
            _ = try await provider(http).openLiveTVChannel(id: channelID)
            XCTFail("Malformed opening must fail")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
    }

    func testCrossOriginTranscodingIsRejectedAndRolledBack() async throws {
        let http = playbackHTTP(openResponse: """
        {"MediaSource":{"Id":"source-fixture","LiveStreamId":"live-fixture",
         "TranscodingUrl":"https://external.invalid/master.m3u8?api_key=foreign",
         "TranscodingSubProtocol":"hls"}}
        """)
        do {
            _ = try await provider(http).openLiveTVChannel(id: channelID)
            XCTFail("Server credentials cannot follow a supplied external origin")
        } catch {
            XCTAssertEqual(error as? ServerLiveTVError, .unsupportedPlaybackMode)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
    }

    func testSameOriginHLSKeepsBasePathAndStripsWireCredentials() async throws {
        let http = playbackHTTP(openResponse: """
        {"MediaSource":{"Id":"source-fixture","LiveStreamId":"live-fixture",
         "TranscodingUrl":"https://server.invalid/mediabrowser/Videos/123/master.m3u8?api_key=wire-token&PlaySessionId=play-fixture&LiveStreamId=live-fixture",
         "TranscodingSubProtocol":"hls"}}
        """)
        let lease = try await provider(http).openLiveTVChannel(id: channelID)
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            await lease.close()
            return XCTFail("Expected authenticated locator")
        }
        XCTAssertEqual(locator.resource.pathBase, .serverRoot)
        XCTAssertEqual(locator.resource.path, "/mediabrowser/Videos/123/master.m3u8")
        XCTAssertEqual(locator.deliveryMode, .hls)
        XCTAssertEqual(locator.resource.queryItems.map(\.name), ["LiveStreamId"])
        await lease.close()
    }

    func testAlreadyOpenedSourceDoesNotTuneAgain() async throws {
        let http = LiveTVFixtureHTTP([
            "/Items/123/PlaybackInfo": [.init(json: """
            {"PlaySessionId":"play-fixture","MediaSources":[
              {"Id":"source-fixture","LiveStreamId":"live-fixture","RequiresOpening":true,
               "Container":"ts","SupportsDirectStream":true}]}
            """)]
        ])
        let lease = try await provider(http).openLiveTVChannel(id: channelID)
        await lease.close()
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path == "/LiveStreams/Open" })
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
    }

    func testDirectFlagAloneDoesNotPretendTunerPlaybackIsSessionless() async throws {
        let http = LiveTVFixtureHTTP([
            "/Items/123/PlaybackInfo": [.init(json: """
            {"PlaySessionId":"play-fixture","MediaSources":[
              {"Id":"source-fixture","Container":"ts","SupportsDirectStream":true}]}
            """)]
        ])
        do {
            _ = try await provider(http).openLiveTVChannel(id: channelID)
            XCTFail("An unowned implicit tune is unsupported")
        } catch {
            XCTAssertEqual(error as? ServerLiveTVError, .unsupportedPlaybackMode)
        }
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path.contains("/stream") })
    }

    func testOneCleanupFailureDoesNotSkipOtherOwnedCleanupOrRetry() async throws {
        let http = playbackHTTP()
        await http.set("/LiveStreams/Close", replies: [.init(status: 500)])
        let lease = try await provider(http).openLiveTVChannel(id: channelID)
        await lease.close()
        await lease.close()
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/Videos/ActiveEncodings" }.count, 1)
    }

    func testNegotiationRejectionDoesNotOpenATuner() async throws {
        for (code, expected) in [
            ("NotAllowed", ServerLiveTVError.permissionDenied),
            ("NoCompatibleStream", .noCompatibleStream)
        ] {
            let http = LiveTVFixtureHTTP([
                "/Items/123/PlaybackInfo": [.init(json: #"{"ErrorCode":"\#(code)","MediaSources":[]}"#)]
            ])
            do {
                _ = try await provider(http).openLiveTVChannel(id: channelID)
                XCTFail("Rejected negotiation must fail")
            } catch {
                XCTAssertEqual(error as? ServerLiveTVError, expected)
            }
            let requests = await http.requests
            XCTAssertEqual(requests.map(\.path), ["/Items/123/PlaybackInfo"])
        }
    }

    func testBusyTunerIsReturnedWithoutClosingAnotherChannel() async throws {
        let http = playbackHTTP()
        await http.set("/LiveStreams/Open", replies: [.init(status: 409)])
        do {
            _ = try await provider(http).openLiveTVChannel(id: channelID)
            XCTFail("A busy tuner is not a successful stream")
        } catch {
            XCTAssertEqual(error as? ServerLiveTVError, .tunerUnavailable)
        }
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path == "/LiveStreams/Close" })
        XCTAssertEqual(requests.filter { $0.path == "/Videos/ActiveEncodings" }.count, 1)
    }

    func testRadioDeliveryUsesAudioEndpointWithTheSameOwnedLiveHandle() async throws {
        let http = playbackHTTP(openResponse: """
        {"MediaSource":{"Id":"source-fixture","LiveStreamId":"live-fixture",
         "Container":"mp3","SupportsDirectStream":true,"MediaStreams":[{"Type":"Audio"}]}}
        """)
        let lease = try await provider(http).openLiveTVChannel(id: channelID)
        await lease.close()
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            return XCTFail("Expected authenticated radio locator")
        }
        XCTAssertEqual(locator.resource.path, "Audio/123/stream.mp3")
    }

    func testTranscodingCannotSubstituteAnotherLiveStreamHandle() async throws {
        let http = playbackHTTP(openResponse: """
        {"MediaSource":{"Id":"source-fixture","LiveStreamId":"live-fixture",
         "TranscodingUrl":"/Videos/123/master.m3u8?LiveStreamId=someone-elses-stream",
         "TranscodingSubProtocol":"hls"}}
        """)
        do {
            _ = try await provider(http).openLiveTVChannel(id: channelID)
            XCTFail("Mismatched live identity must fail before playback")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let requests = await http.requests
        let close = try XCTUnwrap(requests.first { $0.path == "/LiveStreams/Close" })
        XCTAssertEqual(close.query("LiveStreamId"), "live-fixture")
    }

    func testCancelledCallerCanStillAwaitExactlyOnceCleanup() async throws {
        let http = playbackHTTP()
        let lease = try await provider(http).openLiveTVChannel(id: channelID)
        let gate = LiveTVFixtureGate()
        let task = Task {
            await gate.wait()
            await lease.close()
        }
        task.cancel()
        await gate.release()
        await task.value
        await lease.close()
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/LiveStreams/Close" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/Videos/ActiveEncodings" }.count, 1)
    }

    func testClosingOneOfTwoSameDeviceLeasesOnlyStopsItsOwnResources() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = LiveTVFixtureHTTP([
                "/Items/123/PlaybackInfo": [.init(json: """
                {"PlaySessionId":"play-first","MediaSources":[
                  {"Id":"source-first","RequiresOpening":true,"OpenToken":"open-first"}]}
                """)],
                "/Items/456/PlaybackInfo": [.init(json: """
                {"PlaySessionId":"play-second","MediaSources":[
                  {"Id":"source-second","RequiresOpening":true,"OpenToken":"open-second"}]}
                """)],
                "/LiveStreams/Open": [
                    .init(json: """
                    {"MediaSource":{"Id":"source-first","LiveStreamId":"live-first",
                     "TranscodingUrl":"/Videos/123/master.m3u8?LiveStreamId=live-first&PlaySessionId=play-first",
                     "TranscodingSubProtocol":"hls"}}
                    """),
                    .init(json: """
                    {"MediaSource":{"Id":"source-second","LiveStreamId":"live-second",
                     "TranscodingUrl":"/Videos/456/master.m3u8?LiveStreamId=live-second&PlaySessionId=play-second",
                     "TranscodingSubProtocol":"hls"}}
                    """)
                ]
            ])
            let provider = provider(http, kind: kind)
            let first = try await provider.openLiveTVChannel(id: "123")
            let second: any LiveTVStreamLease
            do {
                second = try await provider.openLiveTVChannel(id: "456")
            } catch {
                await first.close()
                throw error
            }
            await first.report(.init(state: .started))
            await second.report(.init(state: .started))
            await first.close()
            await first.close()
            await second.report(.init(state: .playing, positionSeconds: 12))

            let afterFirstClose = await http.requests
            let liveCloses = afterFirstClose.filter { $0.path == "/LiveStreams/Close" }
            XCTAssertEqual(liveCloses.map { $0.query("LiveStreamId") }, ["live-first"])
            let encodingStops = afterFirstClose.filter { $0.path == "/Videos/ActiveEncodings" }
            XCTAssertEqual(encodingStops.map { $0.query("playSessionId") }, ["play-first"])
            XCTAssertEqual(encodingStops.map { $0.query("deviceId") }, ["fixture-device"])
            let stops = afterFirstClose.filter { $0.path == "/Sessions/Playing/Stopped" }
            XCTAssertEqual(stops.map { $0.json?["PlaySessionId"] as? String }, ["play-first"])
            let progress = afterFirstClose.filter { $0.path == "/Sessions/Playing/Progress" }
            XCTAssertEqual(progress.last?.json?["PlaySessionId"] as? String, "play-second")
            XCTAssertEqual(progress.last?.json?["LiveStreamId"] as? String, "live-second")

            await second.close()
            await provider.teardown()
            let allRequests = await http.requests
            XCTAssertEqual(
                allRequests.filter { $0.path == "/LiveStreams/Close" }
                    .map { $0.query("LiveStreamId") },
                ["live-first", "live-second"]
            )
            XCTAssertEqual(
                allRequests.filter { $0.path == "/Videos/ActiveEncodings" }
                    .map { $0.query("playSessionId") },
                ["play-first", "play-second"]
            )
        }
    }

    func testCleanupRejectsEmptyHandlesInsteadOfSendingDeviceWideStop() async throws {
        let http = LiveTVFixtureHTTP([:])
        let client = provider(http).client
        for id in ["", " \n"] {
            do {
                try await client.liveTVStopEncoding(playSessionID: id)
                XCTFail("A device-only transcode stop is forbidden")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
            do {
                try await client.liveTVClose(liveStreamID: id)
                XCTFail("A close requires a particular live-stream handle")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnselectedMediaSourceHandleIsNeverClaimedForCleanup() async throws {
        let http = LiveTVFixtureHTTP([
            "/Items/123/PlaybackInfo": [.init(json: """
            {"PlaySessionId":"play-selected","MediaSources":[
              {"Id":"source-selected","LiveStreamId":"live-selected",
               "Container":"ts","SupportsDirectStream":true},
              {"Id":"source-unselected","LiveStreamId":"live-unselected",
               "Container":"ts","SupportsDirectStream":true}
            ]}
            """)]
        ])
        let lease = try await provider(http).openLiveTVChannel(id: channelID)
        await lease.close()
        let requests = await http.requests
        XCTAssertEqual(
            requests.filter { $0.path == "/LiveStreams/Close" }
                .map { $0.query("LiveStreamId") },
            ["live-selected"]
        )
    }
}

private actor LiveTVFixtureGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor LiveTVFixtureHTTP: HTTPClient {
    struct Reply: Sendable {
        var status = 200
        var json = "{}"
        var gate: LiveTVFixtureGate?
        var error: AppError?
    }

    private var replies: [String: [Reply]]
    private(set) var requests: [Endpoint] = []
    private var waiters: [String: [XCTestExpectation]] = [:]

    init(_ replies: [String: [Reply]]) {
        self.replies = replies
        for path in [
            "/LiveStreams/Close", "/Videos/ActiveEncodings",
            "/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"
        ] where self.replies[path] == nil {
            self.replies[path] = [.init(status: 204)]
        }
    }

    func set(_ path: String, replies: [Reply]) {
        self.replies[path] = replies
    }

    func expectationForRequest(_ path: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Fixture receives \(path)")
        if requests.contains(where: { $0.path == path }) {
            expectation.fulfill()
        } else {
            waiters[path, default: []].append(expectation)
        }
        return expectation
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await sendRaw(endpoint, baseURL: baseURL)
        guard (200..<300).contains(result.1.statusCode) else { throw AppError.invalidResponse }
        return result
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        waiters.removeValue(forKey: endpoint.path)?.forEach { $0.fulfill() }
        guard var matches = replies[endpoint.path], let reply = matches.first else {
            XCTFail("Unstubbed fixture endpoint: \(endpoint.path)")
            throw AppError.invalidResponse
        }
        if matches.count > 1 {
            matches.removeFirst()
            replies[endpoint.path] = matches
        }
        await reply.gate?.wait()
        if let error = reply.error { throw error }
        return (
            Data(reply.json.utf8),
            HTTPURLResponse(url: baseURL, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        )
    }
}

private extension Endpoint {
    func query(_ name: String) -> String? {
        queryItems.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any]? {
        body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}
