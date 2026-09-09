#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import GRDB
  import SQLiteData
  import SQLiteDataTestSupport
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.serialized)
    final class PendingRecordRecoveryTests: BaseCloudKitTests, @unchecked Sendable {
      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func throttledSecondBatchKeepsProgressAndResumesAfterRetryAfter() async throws {
        let parent = makeParent()
        let parentChange = try syncEngine.modifyRecords(scope: .private, saving: [parent])
        for batch in 0..<3 {
          let children = (1...100).map { makeChild(id: batch * 100 + $0, parent: parent) }
          try await syncEngine.modifyRecords(scope: .private, saving: children).notify()
        }
        container.privateCloudDatabase.state.withValue {
          $0.recordFetchBatches.removeAll()
          $0.recordFetchErrors[3] = CKError(
            .requestRateLimited, userInfo: [CKErrorRetryAfterKey: 15.0])
        }
        await withKnownIssue { await parentChange.notify() }
        let firstBatchCount = try await userDatabase.read { try Reminder.fetchCount($0) }
        try #require(firstBatchCount == 150)
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 3)

        await syncEngine.handleFetchedRecordZoneChanges(syncEngine: syncEngine.private)
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 3)
        await testClock.advance(by: .seconds(14))
        await #expect(throws: (any Error).self) { try await testClock.checkSuspension() }
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 3)
        let restored = Task {
          for try await count in ValueObservation.tracking({ try Reminder.fetchCount($0) })
            .values(in: userDatabase.database, scheduling: .immediate)
          where count == 300 { return }
        }
        await testClock.advance(by: .seconds(1))
        try await restored.value
        let finalCount = try await userDatabase.read { try Reminder.fetchCount($0) }
        expectNoDifference(finalCount, 300)
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 4)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func stoppingCancelsThrottledRecovery() async throws {
        let parent = makeParent()
        let parentChange = try syncEngine.modifyRecords(scope: .private, saving: [parent])
        try await syncEngine.modifyRecords(
          scope: .private, saving: [makeChild(id: 1, parent: parent)]
        ).notify()
        container.privateCloudDatabase.state.withValue {
          $0.recordFetchBatches.removeAll()
          $0.recordFetchErrors[2] = CKError(
            .serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 20.0])
        }
        await withKnownIssue { await parentChange.notify() }
        syncEngine.stop()
        await testClock.advance(by: .seconds(30))
        try await testClock.checkSuspension()
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 2)
        let count = try await userDatabase.read { try Reminder.fetchCount($0) }
        expectNoDifference(count, 0)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func coldRestoreDoesNotRefetchChildrenUntilTheirParentArrives() async throws {
        let parent = makeParent()
        let parentChange = try syncEngine.modifyRecords(scope: .private, saving: [parent])
        for batch in 0..<5 {
          let children = (1...100).map { makeChild(id: batch * 100 + $0, parent: parent) }
          try await syncEngine.modifyRecords(scope: .private, saving: children).notify()
        }
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 5)
        let beforeParent = try await userDatabase.read { try Reminder.fetchCount($0) }
        expectNoDifference(beforeParent, 0)

        await parentChange.notify()

        let afterParent = try await userDatabase.read { try Reminder.fetchCount($0) }
        expectNoDifference(afterParent, 500)
        expectNoDifference(
          container.privateCloudDatabase.state.recordFetchBatches.flatMap { $0 }.count, 1_001)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func emptyFetchRecoversExistingBacklogInTheCorrectDatabase() async throws {
        let parent = makeParent()
        _ = try syncEngine.modifyRecords(scope: .private, saving: [parent])
        try await syncEngine.modifyRecords(
          scope: .private, saving: [makeChild(id: 1, parent: parent)]
        ).notify()
        try await userDatabase.write { db in
          try RemindersList.insert { RemindersList(id: 1, title: "Personal") }.execute(db)
        }

        await syncEngine.handleFetchedRecordZoneChanges(syncEngine: syncEngine.shared)
        expectNoDifference(container.sharedCloudDatabase.state.recordFetchBatches, [])
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 1)

        await syncEngine.handleEvent(.willFetchChanges, syncEngine: syncEngine.private)
        await syncEngine.handleEvent(.didFetchChanges, syncEngine: syncEngine.private)
        let restored = try await userDatabase.read { try Reminder.fetchCount($0) }
        expectNoDifference(restored, 1)
        expectNoDifference(container.privateCloudDatabase.state.recordFetchBatches.count, 2)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      @Test func retryDelayUsesTheLongestServerDelayInAPartialFailure() {
        let error = CKError(
          .partialFailure,
          userInfo: [
            CKPartialErrorsByItemIDKey: [
              AnyHashable("first"): CKError(
                .requestRateLimited, userInfo: [CKErrorRetryAfterKey: 15.0]) as NSError,
              AnyHashable("second"): CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 28.0])
                as NSError,
            ]
          ])
        expectNoDifference(SyncEngine.pendingRecordRetryDelay(for: error), 28)
        expectNoDifference(SyncEngine.pendingRecordRetryDelay(for: CKError(.networkFailure)), 5)
        expectNoDifference(
          SyncEngine.pendingRecordRetryDelay(for: CKError(.permissionFailure)), nil)
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func makeParent(id: Int = 1) -> CKRecord {
        let record = CKRecord(
          recordType: RemindersList.tableName, recordID: RemindersList.recordID(for: id))
        record.setValue(id, forKey: "id", at: now)
        record.setValue("Personal", forKey: "title", at: now)
        return record
      }

      @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
      private func makeChild(id: Int, parent: CKRecord) -> CKRecord {
        let record = CKRecord(recordType: Reminder.tableName, recordID: Reminder.recordID(for: id))
        record.setValue(id, forKey: "id", at: now)
        record.setValue("Reminder", forKey: "title", at: now)
        record.setValue(1, forKey: "remindersListID", at: now)
        record.parent = CKRecord.Reference(record: parent, action: .none)
        return record
      }
    }
  }
#endif
