import CloudKit
import CoreModels
import FeatureSyncCloud
import XCTest

final class LiveTVCloudSyncSchemaTests: XCTestCase {
    func testLiveTVUsesDeployedRecordFieldsButIsolatedZoneFromOlderClients() {
        let live = CloudSyncSchemaDescriptor.liveTVStateV1
        let media = CloudSyncSchemaDescriptor.mediaStateV1
        XCTAssertEqual(live.recordType, media.recordType)
        XCTAssertEqual(live.fieldValue, media.fieldValue)
        XCTAssertEqual(live.fieldEditedAt, media.fieldEditedAt)
        XCTAssertNotEqual(live.zoneID, media.zoneID)
        XCTAssertFalse(live.encryptsValue)
    }

    func testRecordMappingRoundTripsOnlyThroughLiveTVChannel() throws {
        let schema = CloudSyncSchemaDescriptor.liveTVStateV1
        let key = LiveTVPortableRecordKey(profileID: "profile", kind: .channel, entityID: "channel")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let upload = SyncUpload(recordName: key.recordName, value: bytes, editedAt: 42, systemFields: nil)
        let record = CKRecord(recordType: schema.recordType, recordID: schema.recordID(forRecordName: key.recordName))
        upload.populate(record, schema: schema)
        XCTAssertEqual(SyncRemoteRecord(ckRecord: record, schema: schema)?.value, bytes)
        XCTAssertNil(SyncRemoteRecord(ckRecord: record, schema: .mediaStateV1))
        XCTAssertNil(SyncRemoteRecord(ckRecord: record, schema: .configV3))
    }
}
