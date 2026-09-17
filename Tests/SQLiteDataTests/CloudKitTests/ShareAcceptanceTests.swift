#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import SQLiteData
  import Testing

  struct ShareAcceptanceTests {
    @available(iOS 17, tvOS 17, macOS 14, watchOS 10, *)
    @Test func returnsAcceptedShare() async throws {
      let share = CKShare(rootRecord: CKRecord(recordType: "Test"))

      let accepted = try await acceptCloudKitShare { completion in
        completion(share, nil)
      }

      expectNoDifference(accepted.recordID, share.recordID)
    }

    @available(iOS 17, tvOS 17, macOS 14, watchOS 10, *)
    @Test func emptyCompletionThrowsInsteadOfTrapping() async throws {
      let error = await #expect(throws: CKError.self) {
        try await acceptCloudKitShare { completion in
          completion(nil, nil)
        }
      }

      expectNoDifference(error?.code, .internalError)
    }

    @available(iOS 17, tvOS 17, macOS 14, watchOS 10, *)
    @Test(arguments: [false, true])
    func preservesFailureEvenWhenAShareIsReturned(hasShare: Bool) async {
      let share = hasShare ? CKShare(rootRecord: CKRecord(recordType: "Test")) : nil
      await #expect(throws: Failure.rejected) {
        try await acceptCloudKitShare { completion in
          completion(share, Failure.rejected)
        }
      }
    }

    private enum Failure: Error {
      case rejected
    }
  }
#endif
