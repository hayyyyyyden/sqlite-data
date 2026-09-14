#if canImport(CloudKit)
  import CloudKit
  import ConcurrencyExtrasTestSupport
  import CustomDump
  import DependenciesTestSupport
  import Foundation
  import InlineSnapshotTesting
  import SQLiteData
  import SQLiteDataTestSupport
  import SnapshotTestingCustomDump
  import Testing
  import TestLocals

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private actor UploadDelegate: SyncEngineDelegate {
    var scopes: [CKDatabase.Scope] = []
    var savedIDs: [CKRecord.ID] = []
    var failedIDs: [CKRecord.ID] = []

    func syncEngine(
      _ syncEngine: SyncEngine,
      didSendRecords savedRecords: [CKRecord],
      failedRecordSaves: [(record: CKRecord, error: CKError)],
      deletedRecordIDs: [CKRecord.ID],
      databaseScope: CKDatabase.Scope
    ) async {
      scopes.append(databaseScope)
      savedIDs.append(contentsOf: savedRecords.map(\.recordID))
      failedIDs.append(contentsOf: failedRecordSaves.map { $0.record.recordID })
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private actor ZoneDeletionDelegate: SyncEngineDelegate {
    var deletedZoneIDs: [CKRecordZone.ID] = []
    var remainingRows: Int?

    func syncEngine(
      _ syncEngine: SyncEngine,
      didDeleteRecordZones zoneIDs: [CKRecordZone.ID],
      databaseScope: CKDatabase.Scope
    ) async {
      deletedZoneIDs += zoneIDs
      remainingRows = try? await syncEngine.userDatabase.database.read { db in
        try RemindersList.fetchCount(db)
      }
    }
  }

  extension BaseCloudKitTests {
    @MainActor
    final class SyncEngineDelegateTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test
      func destructiveResetWaitsForCallbacksAndIgnoresTheStoppedEngine() async throws {
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Old account") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let originalEngine = syncEngine.private
        let record = try container.privateCloudDatabase.record(
          for: RemindersList.recordID(for: 1))
        #expect(syncEngine.beginCallback(for: originalEngine))
        syncEngine.stop()
        #expect(!syncEngine.beginCallback(for: originalEngine))
        await #expect(throws: CancellationError.self) {
          try await syncEngine.discardLocalData()
        }
        syncEngine.endCallback()
        try await syncEngine.suspendForDataDeletion()
        try await syncEngine.discardLocalData()
        #expect(!syncEngine.isRunning)
        await syncEngine.handleEvent(
          .fetchedRecordZoneChanges(modifications: [record], deletions: []),
          syncEngine: originalEngine)
        let count = try await userDatabase.database.read { db in
          try RemindersList.fetchCount(db)
        }
        expectNoDifference(count, 0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(ZoneDeletionDelegate()))
      func zoneDeletionNotifiesAfterRemovingRowsAndNewZoneCanBeCreated() async throws {
        let delegate = try #require(syncEngineDelegate as? ZoneDeletionDelegate)
        try await userDatabase.userWrite { db in
          try db.seed { RemindersList(id: 1, title: "Old account") }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)
        let zoneID = syncEngine.defaultZone.zoneID
        await syncEngine.handleFetchedDatabaseChanges(
          modifications: [], deletions: [(zoneID: zoneID, reason: .deleted)],
          syncEngine: syncEngine.private)
        let deletedZoneIDs = await delegate.deletedZoneIDs
        let remainingRows = await delegate.remainingRows
        expectNoDifference(deletedZoneIDs, [zoneID])
        expectNoDifference(remainingRows, 0)
        #expect(
          syncEngine.private.state.pendingDatabaseChanges.contains(
            .saveZone(syncEngine.defaultZone)))
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test($syncEngineDelegate.set(UploadDelegate()))
      func uploadResultsAndQuotaRetry() async throws {
        let delegate = try #require(syncEngineDelegate as? UploadDelegate)
        let record = CKRecord(
          recordType: "remindersLists", recordID: RemindersList.recordID(for: 1))
        syncEngine.private.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])

        await syncEngine.handleSentRecordZoneChanges(
          failedRecordSaves: [(record, CKError(.quotaExceeded))],
          syncEngine: syncEngine.private
        )

        #expect(await delegate.scopes == [.private])
        #expect(await delegate.failedIDs == [record.recordID])
        #expect(
          syncEngine.private.state.pendingRecordZoneChanges.contains(.saveRecord(record.recordID)))

        syncEngine.private.state.remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        await syncEngine.handleSentRecordZoneChanges(
          savedRecords: [record], syncEngine: syncEngine.private
        )
        #expect(await delegate.savedIDs == [record.recordID])
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)

      @Test($syncEngineDelegate.set(MyDelegate()))
      func accountChanged() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        await signOut()

        assertQuery(RemindersList.all, database: userDatabase.database) {
          """
          ┌─────────────────────┐
          │ RemindersList(      │
          │   id: 1,            │
          │   title: "Personal" │
          │ )                   │
          └─────────────────────┘
          """
        }
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     title: "Personal"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 0                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        try await userDatabase.userWrite { db in
          try RemindersList.find(1).update { $0.title = "My stuff" }.execute(db)
        }

        assertQuery(RemindersList.all, database: userDatabase.database) {
          """
          ┌─────────────────────┐
          │ RemindersList(      │
          │   id: 1,            │
          │   title: "My stuff" │
          │ )                   │
          └─────────────────────┘
          """
        }
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          ┌────────────────────────────────────────────────────────────────────┐
          │ SyncMetadata(                                                      │
          │   id: SyncMetadata.ID(                                             │
          │     recordPrimaryKey: "1",                                         │
          │     recordType: "remindersLists"                                   │
          │   ),                                                               │
          │   zoneName: "zone",                                                │
          │   ownerName: "__defaultOwner__",                                   │
          │   recordName: "1:remindersLists",                                  │
          │   parentRecordID: nil,                                             │
          │   parentRecordName: nil,                                           │
          │   lastKnownServerRecord: CKRecord(                                 │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil                                                     │
          │   ),                                                               │
          │   _lastKnownServerRecordAllFields: CKRecord(                       │
          │     recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__), │
          │     recordType: "remindersLists",                                  │
          │     parent: nil,                                                   │
          │     share: nil,                                                    │
          │     id: 1,                                                         │
          │     title: "Personal"                                              │
          │   ),                                                               │
          │   share: nil,                                                      │
          │   _isDeleted: false,                                               │
          │   _hasLastKnownServerRecord: true,                                 │
          │   _isShared: false,                                                │
          │   userModificationTime: 0                                          │
          │ )                                                                  │
          └────────────────────────────────────────────────────────────────────┘
          """
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }

        await signIn()
        try await syncEngine.processPendingDatabaseChanges(scope: .private)
      }

      @Test($syncEngineDelegate.set(DefaultImplementationDelegate()))
      func accountChanged_DefaultImplementation() async throws {
        try await userDatabase.userWrite { db in
          try db.seed {
            RemindersList(id: 1, title: "Personal")
          }
        }
        try await syncEngine.processPendingRecordZoneChanges(scope: .private)

        await signOut()

        assertQuery(RemindersList.all, database: userDatabase.database) {
          """
          (No results)
          """
        }
        assertQuery(SyncMetadata.all, database: syncEngine.metadatabase) {
          """
          (No results)
          """
        }
        assertInlineSnapshot(of: container, as: .customDump) {
          """
          MockCloudContainer(
            privateCloudDatabase: MockCloudDatabase(
              databaseScope: .private,
              storage: [
                [0]: CKRecord(
                  recordID: CKRecord.ID(1:remindersLists/zone/__defaultOwner__),
                  recordType: "remindersLists",
                  parent: nil,
                  share: nil,
                  id: 1,
                  title: "Personal"
                )
              ]
            ),
            sharedCloudDatabase: MockCloudDatabase(
              databaseScope: .shared,
              storage: []
            )
          )
          """
        }
      }
    }
  }

  final class MyDelegate: SyncEngineDelegate {
    let wasCalled = LockIsolated(false)
    func syncEngine(
      _ syncEngine: SQLiteData.SyncEngine,
      accountChanged changeType: CKSyncEngine.Event.AccountChange.ChangeType
    ) async {
      wasCalled.withValue { $0 = true }
    }
    deinit {
      guard wasCalled.withValue(\.self)
      else {
        Issue.record("Delegate method 'syncEngine(_:accountChanged:)' was not called.")
        return
      }
    }
  }

  final class DefaultImplementationDelegate: SyncEngineDelegate {
  }
#endif
