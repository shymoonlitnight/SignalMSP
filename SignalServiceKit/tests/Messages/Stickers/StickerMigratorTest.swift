//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import Testing
import UIKit

@testable import SignalServiceKit

@MainActor
@Suite(.serialized, .disabled("Enable once StickerManager is refactored to take a sticker cache URL"))
struct StickerMigratorTest {
    private typealias Columns = InstalledStickerRecord.CodingKeys

    private let db = InMemoryDB()
    private let migrator: StickerMigrator
    private let mockKVStore = NewKeyValueStore(collection: "StickerMigrator")

    init() {
        // Needed because StickerManager.cacheDirUrl() uses CurrentAppContext,
        // we want to make sure each test has its own sticker dir.
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        self.migrator = StickerMigrator(db: db)
    }

    @Test
    func testNeedsToRun_trueWhenNoStoredLastSeenId() {
        #expect(migrator.needsToRun())
    }

    @Test
    func testNeedsToRun_falseWhenLastSeenIdZero() throws {
        db.write { tx in
            mockKVStore.writeValue(0, forKey: "lastSeenRowId", tx: tx)
        }
        #expect(!migrator.needsToRun())
    }

    @Test
    func testNeedsToRun_falseAfterRunCompletes() async throws {
        let record = insertUnmigratedRecord()
        try writeStickerFile(sampleStickerPlaintext(), for: record)

        try await migrator.run()

        #expect(!migrator.needsToRun())
    }

    @Test
    func testMigrationHappyPath() async throws {
        let plaintext = sampleStickerPlaintext()
        let record = insertUnmigratedRecord()
        try writeStickerFile(plaintext, for: record)

        try await migrator.run()

        let migrated = fetchRecord(id: record.id!)!
        let localKey = migrated.localKey!
        let plaintextLength = migrated.plaintextLength!
        #expect(plaintextLength == UInt32(plaintext.count))

        let onDisk = try Data(contentsOf: stickerUrl(for: record))
        #expect(onDisk != plaintext)

        let metadata = EncryptedStickerMetadata(
            stickerInfo: record.info,
            stickerType: .apng,
            emojiString: nil,
            encryptedStickerDataUrl: stickerUrl(for: record),
            encryptionKey: localKey,
            plaintextLength: plaintextLength,
        )
        let decrypted = try metadata.readStickerData()
        #expect(decrypted == plaintext)
        #expect(DataImageSource(decrypted).ows_isValidImage)
    }

    @Test
    func deletesRowAndFileWhenOnDiskBytesAreNotValidImage() async throws {
        // Simulates a crash during migration, where we've updated the bytes on disk
        // but haven't updated the DB.
        let record = insertUnmigratedRecord()
        try writeStickerFile(Randomness.generateRandomBytes(512), for: record)

        try await migrator.run()

        #expect(fetchRecord(id: record.id!) == nil)
        #expect(!FileManager.default.fileExists(atPath: stickerUrl(for: record).path))
    }

    @Test
    func leavesRowAloneWhenStickerFileIsMissing() async throws {
        let record = insertUnmigratedRecord()
        // do not write a file to disk.

        try await migrator.run()

        let after = try #require(fetchRecord(id: record.id!))
        #expect(after.localKey == nil)
        #expect(after.plaintextLength == nil)
        #expect(!migrator.needsToRun())
    }

    // MARK: - Helpers

    private func sampleStickerPlaintext() -> Data {
        return UIImage(systemName: "circle")!.pngData()!
    }

    private func insertUnmigratedRecord() -> InstalledStickerRecord {
        let mockPlaintextInstalledRecord = InstalledStickerRecord.mockPlaintext(
            contentType: MimeType.imagePng.rawValue,
        )
        db.write { tx in
            mockPlaintextInstalledRecord.anyInsert(transaction: tx)
        }
        return mockPlaintextInstalledRecord
    }

    private func fetchRecord(id: Int64) -> InstalledStickerRecord? {
        return db.read { tx in
            InstalledStickerRecord.anyFetch(rowId: id, transaction: tx)
        }
    }

    private func stickerUrl(for record: InstalledStickerRecord) -> URL {
        let stickerType = StickerType.stickerType(forContentType: record.contentType)
        return StickerManager.cacheDirUrl()
            .appendingPathComponent("\(record.uniqueId).\(stickerType.fileExtension)")
    }

    private func writeStickerFile(
        _ data: Data,
        for record: InstalledStickerRecord,
    ) throws {
        let url = stickerUrl(for: record)
        try data.write(to: url)
    }
}
