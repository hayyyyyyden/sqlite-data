#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing
  import TestLocals

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private actor DownloadDelegate: SyncEngineDelegate {
    var receivedIDs: [CKRecord.ID] = []
    var rowsAtReceipt: [Int] = []
    var scopes: [CKDatabase.Scope] = []
    var codes: [CKError.Code?] = []
    var delays: [Double?] = []

    func syncEngine(
      _ syncEngine: SyncEngine, didFetchRecords records: [CKRecord],
      databaseScope: CKDatabase.Scope
    ) async {
      receivedIDs += records.map(\.recordID)
      do {
        rowsAtReceipt.append(
          try await syncEngine.userDatabase.database.read { try RemindersList.fetchCount($0) })
      } catch {
        Issue.record(error)
      }
    }

    func syncEngine(
      _ syncEngine: SyncEngine, didFetchRecordZone zoneID: CKRecordZone.ID,
      error: CKError?, databaseScope: CKDatabase.Scope
    ) async {
      scopes.append(databaseScope)
      codes.append(error?.code)
      delays.append(error?.retryAfterSeconds)
    }
  }

  extension BaseCloudKitTests {
    @MainActor
    final class DownloadDelegateTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DownloadDelegate()))
      func receiptPrecedesDatabaseCommit() async throws {
        let delegate = try #require(syncEngineDelegate as? DownloadDelegate)
        let record = CKRecord(
          recordType: RemindersList.tableName,
          recordID: RemindersList.recordID(for: 1))
        record.setValue(1, forKey: "id", at: now)
        record.setValue("Private content", forKey: "title", at: now)
        try await syncEngine.modifyRecords(scope: .private, saving: [record]).notify()

        let receivedIDs = await delegate.receivedIDs
        let rowsAtReceipt = await delegate.rowsAtReceipt
        expectNoDifference(receivedIDs, [record.recordID])
        expectNoDifference(rowsAtReceipt, [0])
        let count = try await userDatabase.database.read { try RemindersList.fetchCount($0) }
        expectNoDifference(count, 1)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(DownloadDelegate()))
      func fetchFailureAndRecoveryPreserveScopeAndRetryInformation() async throws {
        let delegate = try #require(syncEngineDelegate as? DownloadDelegate)
        let zoneID = syncEngine.defaultZone.zoneID
        for error in [
          CKError(
            .requestRateLimited,
            userInfo: [CKErrorRetryAfterKey: 30.0]), nil,
        ] {
          await syncEngine.handleEvent(
            .willFetchRecordZoneChanges(zoneID: zoneID),
            syncEngine: syncEngine.shared)
          await syncEngine.handleEvent(
            .didFetchRecordZoneChanges(zoneID: zoneID, error: error),
            syncEngine: syncEngine.shared)
        }
        let scopes = await delegate.scopes
        let codes = await delegate.codes
        let delays = await delegate.delays
        expectNoDifference(scopes, [.shared, .shared])
        expectNoDifference(codes, [.requestRateLimited, nil])
        expectNoDifference(delays, [30, nil])
      }
    }
  }
#endif
