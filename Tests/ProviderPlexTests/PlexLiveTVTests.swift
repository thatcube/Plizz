import Foundation
import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

final class PlexLiveTVTests: XCTestCase {
    private let epg = "tv.plex.providers.epg.cloud:12"
    private var providers: String {
        """
        {"MediaContainer":{"MediaProvider":[
          {"identifier":"\(epg)","providerIdentifier":"tv.plex.providers.epg.cloud",
           "protocols":"livetv","Feature":[{"type":"grid","key":"/\(epg)/grid"}]}
        ]}}
        """
    }
    private var channels: String {
        """
        {"MediaContainer":{"size":"2","Channel":[
          {"id":101,"gridKey":"native-grid-101","vcn":"7.1","title":"News","thumb":"https://images.invalid/news.png"},
          {"id":"102","gridKey":"native-grid-102","vcn":9,"title":"News","thumb":"/library/channel.png?X-Plex-Token=bad"}
        ]}}
        """
    }

    private func provider(
        _ http: PlexLiveTVFixtureHTTP,
        baseURL: URL = URL(string: "https://plex.invalid:32400")!
    ) -> PlexProvider {
        PlexProvider(
            session: UserSession(
                server: MediaServer(
                    id: "plex-live-fixture-\(UUID().uuidString)",
                    name: "Fixture PMS",
                    baseURL: baseURL,
                    provider: .plex
                ),
                userID: "fixture-home-user", userName: "Fixture user",
                deviceID: "fixture-device", accessToken: "fixture-home-token"
            ),
            accountID: "fixture-account", http: http, interactiveHTTP: http, probe: http
        )
    }

    func testAbsentProvidersProduceUnconfiguredStateWithoutAdministrativeProbe() async throws {
        for casing in ["DVR", "Dvr"] {
            let http = PlexLiveTVFixtureHTTP([
                "/media/providers": [.init(json: #"{"MediaContainer":{"MediaProvider":[]}}"#)],
                "/livetv/dvrs": [.init(json: #"{"MediaContainer":{"\#(casing)":[]}}"#)]
            ])
            let result = try await provider(http).liveTVAvailability()
            XCTAssertEqual(result.status, .notConfigured)
            XCTAssertFalse(result.hasChannels)
            XCTAssertFalse(result.supportsPlayback)
            let requests = await http.requests
            XCTAssertTrue(requests.allSatisfy { $0.method == .get })
            XCTAssertEqual(requests.map(\.path), ["/media/providers"])
        }
    }

    func testNoAdvertisedLineupDoesNotInspectAdministrativeDVRConfiguration() async throws {
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: #"{"MediaContainer":{"MediaProvider":[]}}"#)],
            "/livetv/dvrs": [.init(json: #"{"MediaContainer":{"Dvr":[{"key":12,"uuid":"fixture-dvr","lineup":"fixture-lineup"}]}}"#)]
        ])
        let result = try await provider(http).liveTVAvailability()
        XCTAssertEqual(result.status, .notConfigured)
        XCTAssertFalse(result.supportsPlayback)
    }

    func testAuthorizedChannelsAdvertisePlaybackWithoutOpeningTuner() async throws {
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: providers)],
            "/\(epg)/lineups/dvr/channels": [.init(json: channels)]
        ])
        let result = try await provider(http).liveTVAvailability()
        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.channelCount, 2)
        XCTAssertTrue(result.hasChannels)
        XCTAssertTrue(result.supportsGuide)
        XCTAssertTrue(result.supportsPlayback)
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path == "/livetv/dvrs" },
                       "A Home user's readable channels must not depend on administrative DVR inspection")
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Plex-Token"] == "fixture-home-token" })
        XCTAssertTrue(requests.allSatisfy { $0.redirectPolicy == .sameOrigin })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Cache-Control"] == "no-store" })
        XCTAssertTrue(requests.allSatisfy { !$0.queryItems.contains { $0.name == "X-Plex-Token" } })
    }

    func testChannelsPreserveScalarVariantsDistinctNativeIDsAndSecretFreeArtwork() async throws {
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: providers)],
            "/\(epg)/lineups/dvr/channels": [.init(json: channels)]
        ])
        let result = try await provider(http).liveTVChannels()
        XCTAssertEqual(result.map(\.id), ["\(epg)|101", "\(epg)|102"])
        XCTAssertEqual(result.map(\.name), ["News", "News"])
        XCTAssertEqual(result.map(\.number), ["7.1", "9"])
        XCTAssertEqual(result[0].imageURL?.host, "images.invalid")
        XCTAssertNil(result[1].imageURL)
    }

    func testDifferentEPGProvidersNamespaceOtherwiseIdenticalChannels() async throws {
        let second = "tv.plex.providers.epg.xmltv:47"
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: """
            {"MediaContainer":{"MediaProvider":[
              {"identifier":"\(epg)","protocols":"livetv","Feature":[{"type":"grid","key":"/\(epg)/grid"}]},
              {"identifier":"\(second)","protocols":"livetv","Feature":[{"type":"grid","key":"/\(second)/grid"}]}
            ]}}
            """)],
            "/\(epg)/lineups/dvr/channels": [.init(json: channels)],
            "/\(second)/lineups/dvr/channels": [.init(json: channels)]
        ])
        let result = try await provider(http).liveTVChannels()
        XCTAssertEqual(Set(result.map(\.id)).count, 4)
        XCTAssertTrue(result.contains { $0.id == "\(second)|101" })
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path.contains("cloud:1/") })
    }

    func testNativeGuideFlattensAndDeduplicatesOnlyAuthoritativeMatchingAirings() async throws {
        let start: TimeInterval = 1_789_034_400
        let guide = """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"programme-1","title":"Episode title","grandparentTitle":"Show title",
           "summary":"Native server guide","Genre":[{"tag":"News"}],
           "Media":[
             {"beginsAt":"\(start - 900)","endsAt":\(start + 900),"channelIdentifier":101,"protocol":"livetv"},
             {"beginsAt":\(start),"endsAt":\(start + 1800),"channelIdentifier":102,"protocol":"livetv"},
             {"beginsAt":\(start),"endsAt":\(start - 100),"channelIdentifier":101,"protocol":"livetv"},
             {"beginsAt":"invalid","endsAt":\(start + 900),"channelIdentifier":101,"protocol":"livetv"}
           ]}
        ]}}
        """
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: providers)],
            "/\(epg)/lineups/dvr/channels": [.init(json: channels)],
            "/\(epg)/grid": [.init(json: guide)]
        ])
        let result = try await provider(http).liveTVGuide(
            channelIDs: ["\(epg)|101"],
            from: Date(timeIntervalSince1970: start),
            to: Date(timeIntervalSince1970: start + 3_600)
        )
        XCTAssertEqual(result.count, 1)
        let airing = try XCTUnwrap(result.first)
        XCTAssertEqual(airing.channelID, "\(epg)|101")
        XCTAssertEqual(airing.title, "Show title")
        XCTAssertEqual(airing.subtitle, "Episode title")
        XCTAssertEqual(airing.categories, ["News"])
        XCTAssertEqual(airing.startDate.timeIntervalSince1970, start - 900)
        let requests = await http.requests
        let grids = requests.filter { $0.path.hasSuffix("/grid") }
        XCTAssertTrue(grids.count >= 3, "Include adjacent lineup dates without fabricating timezone metadata")
        XCTAssertTrue(grids.allSatisfy { $0.query("channelGridKey") == "native-grid-101" })
        XCTAssertTrue(grids.allSatisfy { $0.query("date")?.count == 10 })
        XCTAssertTrue(requests.allSatisfy { $0.method == .get })
    }

    func testUnsafeEPGIdentifierCannotBecomeAuthenticatedRequestPath() async throws {
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: """
            {"MediaContainer":{"MediaProvider":[
              {"identifier":"tv.plex.providers.epg.cloud:12/../../admin","protocols":"livetv"},
              {"identifier":"https://external.invalid/tv.plex.providers.epg.cloud:12","protocols":"livetv"}
            ]}}
            """)],
            "/livetv/dvrs": [.init(json: #"{"MediaContainer":{"DVR":[]}}"#)]
        ])
        let result = try await provider(http).liveTVAvailability()
        XCTAssertFalse(result.supportsPlayback)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/media/providers"])
    }

    func testExternalGridFeatureDoesNotReceiveServerCredentials() async throws {
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: """
            {"MediaContainer":{"MediaProvider":[
              {"identifier":"\(epg)","protocols":"livetv","Feature":[
                {"type":"grid","key":"https://external.invalid/grid"}]}
            ]}}
            """)],
            "/\(epg)/lineups/dvr/channels": [.init(json: channels)]
        ])
        let result = try await provider(http).liveTVAvailability()
        XCTAssertTrue(result.hasChannels)
        XCTAssertFalse(result.supportsGuide)
        let guide = try await provider(http).liveTVGuide(
            channelIDs: ["\(epg)|101"], from: Date(), to: Date().addingTimeInterval(3_600)
        )
        XCTAssertTrue(guide.isEmpty)
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path.contains("external") })
    }

    func testUnknownChannelCannotTuneOrAdminTerminate() async throws {
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: providers)],
            "/\(epg)/lineups/dvr/channels": [.init(json: channels)]
        ])
        do {
            _ = try await provider(http).openLiveTVChannel(id: "\(epg)|unknown")
            XCTFail("Only an authorized native channel can tune")
        } catch {
            XCTAssertEqual(error as? ServerLiveTVError, .invalidChannel)
        }
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/tune") })
    }

    func testPermissionDeniedIsDifferentFromExpiredCredentials() async throws {
        let denied = PlexLiveTVFixtureHTTP(["/media/providers": [.init(status: 403)]])
        let deniedResult = try await provider(denied).liveTVAvailability()
        XCTAssertEqual(deniedResult.status, .permissionDenied)
        let expired = PlexLiveTVFixtureHTTP(["/media/providers": [.init(status: 401)]])
        do {
            _ = try await provider(expired).liveTVAvailability()
            XCTFail("Authentication error must remain actionable")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
    }

    func testGuideRejectsUnboundedWindowsBeforeMakingRequests() async throws {
        let http = PlexLiveTVFixtureHTTP([:])
        do {
            _ = try await provider(http).liveTVGuide(
                channelIDs: ["\(epg)|101"], from: Date(), to: Date().addingTimeInterval(172_801)
            )
            XCTFail("Guide requests must be bounded")
        } catch {
            XCTAssertEqual(error as? ServerLiveTVError, .invalidGuideWindow)
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private let sessionPath = "/livetv/sessions/shared-tuner"
    private let playlistPath = "/livetv/sessions/shared-tuner/own-consumer/index.m3u8"

    private func playbackHTTP(
        tune: String? = nil, decision: String? = nil,
        tuneGate: PlexLiveTVGate? = nil, decisionGate: PlexLiveTVGate? = nil
    ) -> PlexLiveTVFixtureHTTP {
        PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: providers)],
            "/\(epg)/lineups/dvr/channels": [.init(json: channels)],
            "/livetv/dvrs/12/channels/7.1/tune": [.init(
                json: tune ?? """
                {"MediaContainer":{"MediaGrabOperation":[{"Metadata":{
                  "key":"\(sessionPath)","ratingKey":4321,"live":true,
                  "Media":[{"uuid":"shared-tuner","Part":[{}]}]}}]}}
                """, gate: tuneGate
            )],
            "/video/:/transcode/universal/decision": [.init(
                json: decision ?? """
                {"MediaContainer":{"mdeDecisionCode":1000,"Metadata":[{
                  "key":"\(sessionPath)","Media":[{"Part":[{
                  "decision":"directplay","key":"\(playlistPath)?offset=0"}]}]}]}}
                """, gate: decisionGate
            )],
            playlistPath: [.init(json: "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:3,\n0.ts\n")],
            "/video/:/transcode/universal/start.m3u8": [.init(json: "#EXTM3U\n#EXT-X-TARGETDURATION:3\n")],
            "/:/timeline": [.init(status: 200)],
            "/video/:/transcode/universal/stop": [.init(status: 200)]
        ])
    }

    func testTuneNegotiatesServerIssuedConsumerWithoutCurrentGuideRecord() async throws {
        let http = playbackHTTP()
        let provider = provider(http)
        let lease = try await provider.openLiveTVChannel(id: "\(epg)|101")
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            await lease.close()
            return XCTFail("Expected account-scoped authenticated HLS")
        }
        XCTAssertEqual(locator.resource.path, String(playlistPath.dropFirst()))
        XCTAssertEqual(locator.resource.pathBase, .configuredBaseURL)
        XCTAssertEqual(locator.accountID, "fixture-account")
        XCTAssertEqual(locator.credentialRevision, provider.credentialRevision)
        XCTAssertEqual(locator.itemID, "\(epg)|101")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(locator.playSessionID)))
        XCTAssertFalse(locator.resource.queryItems.contains { $0.name.lowercased().contains("token") })
        XCTAssertEqual(locator.resource.queryItems.first { $0.name == "X-Plex-Client-Identifier" }?.value,
                       "fixture-device")
        await lease.report(.init(state: .playing, positionSeconds: 13))
        await lease.close()
        let requests = await http.requests
        let tune = try XCTUnwrap(requests.first { $0.path.hasSuffix("/tune") })
        XCTAssertEqual(tune.method, .post)
        XCTAssertEqual(tune.headers["X-Plex-Session-Identifier"], locator.playSessionID)
        let decision = try XCTUnwrap(requests.first { $0.path.hasSuffix("/decision") })
        XCTAssertEqual(decision.query("path"), sessionPath)
        XCTAssertEqual(decision.query("session"), locator.playSessionID)
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Plex-Token"] == "fixture-home-token" })
        XCTAssertTrue(requests.allSatisfy { $0.redirectPolicy == .sameOrigin })
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/grid") || $0.path == "/livetv/dvrs" })
        XCTAssertFalse(requests.contains { $0.path.contains("/library/") || $0.path.contains("/scrobble") })
        let stop = try XCTUnwrap(requests.first { $0.path == "/:/timeline" && $0.query("state") == "stopped" })
        XCTAssertEqual(stop.method, .post)
        XCTAssertEqual(stop.query("key"), sessionPath)
        XCTAssertEqual(stop.query("ratingKey"), "4321")
        XCTAssertEqual(stop.headers["X-Plex-Session-Identifier"], locator.playSessionID)
    }

    func testConversionDecisionStartsOnlyOwnedTranscodeSession() async throws {
        let http = playbackHTTP(decision: #"{"MediaContainer":{"generalDecisionCode":1001}}"#)
        let lease = try await provider(http).openLiveTVChannel(id: "\(epg)|101")
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            await lease.close()
            return XCTFail("Expected authenticated HLS")
        }
        XCTAssertEqual(locator.resource.path, "video/:/transcode/universal/start.m3u8")
        XCTAssertEqual(locator.resource.queryItems.first { $0.name == "path" }?.value, sessionPath)
        await lease.close()
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/start.m3u8") }.count, 1)
        XCTAssertEqual(requests.last?.query("session"), locator.playSessionID)
        XCTAssertFalse(requests.contains { $0.path.contains("/terminate") || $0.method == .delete })
    }

    func testPublishedLegacyMediaUUIDTuneShapeIsSupported() async throws {
        let http = playbackHTTP(tune: """
        {"MediaContainer":{"Metadata":[{"live":true,"Media":[
          {"uuid":"shared-tuner","Part":[{"Stream":[{"codec":"h264","streamType":1}]}]}]}]}}
        """)
        let lease = try await provider(http).openLiveTVChannel(id: "\(epg)|101")
        await lease.close()
        let requests = await http.requests
        XCTAssertEqual(requests.first { $0.path == "/:/timeline" }?.query("key"), sessionPath)
        XCTAssertNil(requests.first { $0.path == "/:/timeline" }?.query("ratingKey"))
    }

    func testCancellationDuringTuneWaitsForOwnedHandleAndRollsBack() async throws {
        let gate = PlexLiveTVGate()
        let http = playbackHTTP(tuneGate: gate)
        let provider = provider(http)
        let task = Task { try await provider.openLiveTVChannel(id: "\(epg)|101") }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled tune must not hand off playback")
        } catch is CancellationError {}
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/decision") })
        XCTAssertEqual(requests.filter { $0.path == "/:/timeline" && $0.query("state") == "stopped" }.count, 1)
        XCTAssertEqual(requests.first { $0.path == "/:/timeline" }?.query("key"), sessionPath)
    }

    func testProviderRetirementDuringConsumerOpenRollsBackAndCannotReopen() async throws {
        let gate = PlexLiveTVGate()
        let http = playbackHTTP(decisionGate: gate)
        let provider = provider(http)
        let task = Task { try await provider.openLiveTVChannel(id: "\(epg)|101") }
        await gate.waitUntilEntered()
        await provider.teardown()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Retired credentials must not hand off playback")
        } catch is CancellationError {}
        do {
            _ = try await provider.openLiveTVChannel(id: "\(epg)|101")
            XCTFail("Retired providers cannot allocate")
        } catch is CancellationError {}
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/tune") }.count, 1)
        XCTAssertFalse(requests.contains { $0.path == playlistPath })
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/stop") }.count, 1)
    }

    func testForeignOrMismatchedConsumerAndMalformedDecisionRollBackOwnTune() async throws {
        for key in [
            "https://untrusted.invalid\(playlistPath)",
            "http://plex.invalid:32400\(playlistPath)",
            "https://plex.invalid:443\(playlistPath)",
            "/livetv/sessions/other-viewer/other-consumer/index.m3u8",
            "/livetv/sessions/shared-tuner/../index.m3u8"
        ] {
            let http = playbackHTTP(decision: """
            {"MediaContainer":{"mdeDecisionCode":1000,"Metadata":[{
              "Media":[{"Part":[{"decision":"directplay","key":"\(key)"}]}]}]}}
            """)
            do {
                _ = try await provider(http).openLiveTVChannel(id: "\(epg)|101")
                XCTFail("Foreign resource must not receive account credentials")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.path == "/:/timeline" }.count, 1)
            XCTAssertFalse(requests.contains { $0.path.contains("other-viewer") })
        }
    }

    func testConcurrentIdempotentCloseDoesNotStopSecondViewerOnSharedTuner() async throws {
        let http = playbackHTTP()
        let provider = provider(http)
        let first = try await provider.openLiveTVChannel(id: "\(epg)|101")
        let secondPlaylist = "/livetv/sessions/shared-tuner/second-consumer/index.m3u8"
        await http.set("/video/:/transcode/universal/decision", replies: [.init(json: """
        {"MediaContainer":{"mdeDecisionCode":1000,"Metadata":[{"Media":[{"Part":[
          {"decision":"directplay","key":"\(secondPlaylist)"}]}]}]}}
        """)])
        await http.set(secondPlaylist, replies: [.init(json: "#EXTM3U\n#EXT-X-TARGETDURATION:3\n")])
        let second = try await provider.openLiveTVChannel(id: "\(epg)|101")
        guard case .authenticatedHTTP(let firstLocator) = first.playbackSource,
              case .authenticatedHTTP(let secondLocator) = second.playbackSource else {
            await first.close(); await second.close()
            return XCTFail("Expected authenticated locators")
        }
        XCTAssertNotEqual(firstLocator.playSessionID, secondLocator.playSessionID)
        XCTAssertNotEqual(firstLocator.resource.path, secondLocator.resource.path)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { await first.close() } }
        }
        await first.report(.init(state: .playing))
        await second.report(.init(state: .playing))
        let requests = await http.requests
        let stops = requests.filter { $0.path.hasSuffix("/stop") }
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.query("session"), firstLocator.playSessionID)
        XCTAssertEqual(requests.last?.headers["X-Plex-Session-Identifier"], secondLocator.playSessionID)
        XCTAssertEqual(requests.last?.query("state"), "playing")
        await second.close()
        await provider.teardown()
    }

    func testExplicitLivePermissionAndSubscriptionDoNotLookUnconfigured() async throws {
        let denied = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: #"{"MediaContainer":{"allowTuners":false,"MediaProvider":[]}}"#)]
        ])
        let deniedResult = try await provider(denied).liveTVAvailability()
        XCTAssertEqual(deniedResult.status, .permissionDenied)
        let gated = PlexLiveTVFixtureHTTP(["/media/providers": [.init(status: 402)]])
        let gatedResult = try await provider(gated).liveTVAvailability()
        XCTAssertEqual(gatedResult.status, .subscriptionRequired)
    }

    func testHeartbeatAndCloseStaySerializedWithinOnePlaybackIdentity() async throws {
        let http = playbackHTTP()
        let provider = provider(http)
        let store = PlexLiveTVLeaseStore()
        let playbackID = UUID().uuidString
        let resources = PlexLiveTVResources(client: provider.client, playbackID: playbackID, store: store)
        await resources.adopt(sessionPath: sessionPath, ratingKey: "987")
        await resources.report(.init(state: .started))
        await resources.sendHeartbeat()
        await resources.report(.init(state: .paused, positionSeconds: 42))
        await resources.close()
        await resources.sendHeartbeat()
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/:/timeline" }.map { $0.query("state") },
                       ["playing", "playing", "paused", "stopped"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Plex-Session-Identifier"] == playbackID })
        XCTAssertTrue(requests.filter { $0.path == "/:/timeline" }.allSatisfy {
            $0.query("key") == sessionPath && $0.query("time") == "0" && $0.query("duration") == "0"
        })
        XCTAssertEqual(requests.last?.query("session"), playbackID)
    }

    func testFailedPlaylistHandoffReleasesConsumerAndRetryUsesFreshGeneration() async throws {
        let http = playbackHTTP()
        let provider = provider(http)
        await http.set(playlistPath, replies: [.init(status: 404)])
        do {
            _ = try await provider.openLiveTVChannel(id: "\(epg)|101")
            XCTFail("A missing consumer playlist cannot be handed to the player")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
        let failed = await http.requests
        let firstPlayback = try XCTUnwrap(failed.first { $0.path.hasSuffix("/tune") }?
            .headers["X-Plex-Session-Identifier"])
        XCTAssertEqual(failed.last?.query("session"), firstPlayback)
        await http.set(playlistPath, replies: [.init(json: "#EXTM3U\n#EXT-X-TARGETDURATION:3\n")])
        let lease = try await provider.openLiveTVChannel(id: "\(epg)|101")
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            await lease.close()
            return XCTFail("Expected authenticated stream")
        }
        XCTAssertNotEqual(locator.playSessionID, firstPlayback)
        await lease.close()
    }

    func testTransportFailureNeverRetriesSpeculativeTuneAndNeverUsesAdminSessionStop() async throws {
        let http = playbackHTTP()
        await http.set("/livetv/dvrs/12/channels/7.1/tune", replies: [.init(error: .serverUnreachable)])
        do {
            _ = try await provider(http).openLiveTVChannel(id: "\(epg)|101")
            XCTFail("An ambiguous allocation failure must not open another tuner")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/tune") }.count, 1)
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/decision") })
        XCTAssertFalse(requests.contains { $0.path.contains("/status/sessions") || $0.method == .delete })
    }

    func testMalformedSuccessfulTuneCanOnlyAttemptItsOwnPlaybackRelease() async throws {
        let http = playbackHTTP(tune: #"{"MediaContainer":{"Metadata":"invalid"}}"#)
        do {
            _ = try await provider(http).openLiveTVChannel(id: "\(epg)|101")
            XCTFail("No invented tune handle")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let requests = await http.requests
        let ownID = try XCTUnwrap(requests.first { $0.path.hasSuffix("/tune") }?
            .headers["X-Plex-Session-Identifier"])
        XCTAssertEqual(requests.last?.query("session"), ownID)
        XCTAssertNil(requests.first { $0.path == "/:/timeline" }?.query("key"))
    }

    func testPeriodicHeartbeatStartsWithoutPlayerProgressAndStopsWithLease() async throws {
        let http = playbackHTTP()
        let provider = provider(http)
        let firstTick = PlexLiveTVGate()
        let nextTick = PlexLiveTVGate()
        let resources = PlexLiveTVResources(
            client: provider.client, playbackID: UUID().uuidString, store: PlexLiveTVLeaseStore(),
            sleep: { duration in
                if duration == .seconds(3) { await firstTick.enter() }
                else {
                    XCTAssertEqual(duration, .seconds(10))
                    await nextTick.enter()
                }
            }
        )
        await resources.adopt(sessionPath: sessionPath, ratingKey: nil)
        await resources.startHeartbeat()
        await firstTick.waitUntilEntered()
        await firstTick.release()
        await nextTick.waitUntilEntered()
        let beforeStop = await http.requests
        XCTAssertEqual(beforeStop.filter { $0.path == "/:/timeline" }.map { $0.query("state") }, ["buffering"])
        await resources.close()
        await nextTick.release()
        await resources.sendHeartbeat()
        let afterStop = await http.requests
        XCTAssertEqual(afterStop.filter { $0.path == "/:/timeline" }.map { $0.query("state") },
                       ["buffering", "stopped"])
    }

    func testSameOriginConsumerPreservesConfiguredReverseProxyPrefixAtResolution() async throws {
        let baseURL = URL(string: "https://plex.invalid:32400/reverse-proxy")!
        let http = playbackHTTP(decision: """
        {"MediaContainer":{"mdeDecisionCode":1000,"Metadata":[{"Media":[{"Part":[{
          "decision":"directplay",
          "key":"https://plex.invalid:32400/reverse-proxy\(playlistPath)?X-Plex-Token=obsolete"
        }]}]}]}}
        """)
        let lease = try await provider(http, baseURL: baseURL).openLiveTVChannel(id: "\(epg)|101")
        guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
            await lease.close()
            return XCTFail("Expected authenticated locator")
        }
        XCTAssertEqual(locator.resource.pathBase, .configuredBaseURL)
        XCTAssertEqual(locator.resource.path, String(playlistPath.dropFirst()))
        XCTAssertFalse(locator.resource.queryItems.contains { $0.value == "obsolete" })
        await lease.close()
    }

    func testConsumerWithOtherPlaybackIdentityCannotBeAdopted() async throws {
        let http = playbackHTTP(decision: """
        {"MediaContainer":{"mdeDecisionCode":1000,"Metadata":[{"Media":[{"Part":[{
          "decision":"directplay","key":"\(playlistPath)?session=another-viewer"
        }]}]}]}}
        """)
        do {
            _ = try await provider(http).openLiveTVChannel(id: "\(epg)|101")
            XCTFail("Do not adopt another viewer's consumer identity")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.query("session") == "another-viewer" })
    }

    func testReleaseCannotSendEmptyOrMismatchedViewerIdentity() async throws {
        let http = PlexLiveTVFixtureHTTP([:])
        let client = provider(http).client
        for id in ["", " ", "not-a-playback-uuid"] {
            do {
                _ = try await client.liveTVSessionRequest(
                    path: "/video/:/transcode/universal/stop",
                    query: [URLQueryItem(name: "session", value: id)], playbackID: id
                )
                XCTFail("Unscoped cleanup is forbidden")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
        }
        do {
            _ = try await client.liveTVSessionRequest(
                path: "/video/:/transcode/universal/stop",
                query: [URLQueryItem(name: "session", value: UUID().uuidString)],
                playbackID: UUID().uuidString
            )
            XCTFail("Cleanup must match this viewer")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInconsistentAdvertisedDVRIdentityIsNotReplacedWithFirstHouseholdTuner() async throws {
        let http = PlexLiveTVFixtureHTTP([
            "/media/providers": [.init(json: """
            {"MediaContainer":{"MediaProvider":[{"identifier":"\(epg)",
              "parentID":47,"protocols":"livetv"}]}}
            """)]
        ])
        do {
            _ = try await provider(http).openLiveTVChannel(id: "\(epg)|101")
            XCTFail("The lineup must identify its own DVR")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/media/providers"])
    }
}

private actor PlexLiveTVFixtureHTTP: HTTPClient {
    struct Reply: Sendable {
        var status = 200
        var json = "{}"
        var gate: PlexLiveTVGate?
        var error: AppError?
    }
    private var replies: [String: [Reply]]
    private(set) var requests: [Endpoint] = []

    init(_ replies: [String: [Reply]]) {
        self.replies = replies
    }

    func set(_ path: String, replies: [Reply]) {
        self.replies[path] = replies
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await sendRaw(endpoint, baseURL: baseURL)
        guard (200..<300).contains(result.1.statusCode) else { throw AppError.invalidResponse }
        return result
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        guard var matches = replies[endpoint.path], let reply = matches.first else {
            XCTFail("Unstubbed fixture endpoint: \(endpoint.path)")
            throw AppError.invalidResponse
        }
        if matches.count > 1 {
            matches.removeFirst()
            replies[endpoint.path] = matches
        }
        await reply.gate?.enter()
        if let error = reply.error { throw error }
        return (
            Data(reply.json.utf8),
            HTTPURLResponse(url: baseURL, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        )
    }

}

private actor PlexLiveTVGate {
    private var entered = false
    private var released = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        entrants.forEach { $0.resume() }
        entrants = []
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entrants.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private extension Endpoint {
    func query(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }
}
