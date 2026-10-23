//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Testing
import UIKit

@testable import SignalServiceKit

@MainActor
@Suite(.serialized, .disabled("Enable once StickerManager is refactored to take a sticker cache URL"))
struct StickerInstallFlowTest {
    private let db = InMemoryDB()
    private let stickerManager: StickerManager

    init() {
        // Needed because StickerManager.cacheDirUrl() uses CurrentAppContext,
        // we want to make sure each test has its own sticker dir.
        SetCurrentAppContext(TestAppContext(), isRunningTests: true)
        self.stickerManager = StickerManager(
            appReadiness: AppReadinessMock(),
            dateProvider: { Date() },
            attachmentStore: AttachmentStore(),
            attachmentDownloadStore: AttachmentDownloadStore(dateProvider: { Date() }),
            db: db,
        )
    }

    @Test
    func installStickerHappyPath() async throws {
        let plaintext = sampleStickerPlaintext()
        let info = randomStickerInfo()

        let didInstall = await stickerManager.installSticker(
            stickerInfo: info,
            stickerData: plaintext,
            contentType: MimeType.imagePng.rawValue,
            emojiString: nil,
        )
        #expect(didInstall)

        let record = try #require(db.read { tx in
            StickerManager.fetchInstalledSticker(stickerInfo: info, transaction: tx)
        })
        let localKey = try #require(record.localKey)
        let plaintextLength = try #require(record.plaintextLength)
        #expect(plaintextLength == UInt32(plaintext.count))

        let fileUrl = StickerManager.stickerDataUrl(
            forInstalledSticker: record,
            verifyExists: true,
        )!
        let onDisk = try Data(contentsOf: fileUrl)
        #expect(onDisk != plaintext)

        let metadata = EncryptedStickerMetadata(
            stickerInfo: info,
            stickerType: .apng,
            emojiString: nil,
            encryptedStickerDataUrl: fileUrl,
            encryptionKey: localKey,
            plaintextLength: plaintextLength,
        )

        // Make sure its a valid image.
        let decrypted = try metadata.readStickerData()
        #expect(decrypted == plaintext)
        #expect(DataImageSource(decrypted).ows_isValidImage)
    }

    @Test
    func installStickerReturnsFalseWhenAlreadyInstalled() async throws {
        let plaintext = sampleStickerPlaintext()
        let info = randomStickerInfo()

        #expect(await stickerManager.installSticker(
            stickerInfo: info,
            stickerData: plaintext,
            contentType: MimeType.imagePng.rawValue,
            emojiString: nil,
        ))
        #expect(await !stickerManager.installSticker(
            stickerInfo: info,
            stickerData: plaintext,
            contentType: MimeType.imagePng.rawValue,
            emojiString: nil,
        ))
    }

    // MARK: - Helpers

    private func sampleStickerPlaintext() -> Data {
        return UIImage(systemName: "circle")!.pngData()!
    }

    private func randomStickerInfo() -> StickerInfo {
        return StickerInfo(
            packId: Randomness.generateRandomBytes(16),
            packKey: Randomness.generateRandomBytes(StickerManager.packKeyLength),
            stickerId: UInt32.random(in: 0..<1024),
        )
    }
}
