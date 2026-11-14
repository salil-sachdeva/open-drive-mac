import CryptoKit
import XCTest
@testable import OpenDriveCore

final class VaultCryptoTests: XCTestCase {
    func testVaultCryptoKeyBundleAndFDE1RandomAccessChunks() throws {
        let (bundle, recoveryWords, _) = try VaultCrypto.createKeyBundle(passphrase: "correct-horse-battery-staple")
        XCTAssertEqual(recoveryWords.count, 24)

        let unlockedByPass = try VaultCrypto.unlockMasterKey(passphrase: "correct-horse-battery-staple", bundle: bundle)
        let unlockedByRec = try VaultCrypto.unlockMasterKey(recoveryWords: recoveryWords, bundle: bundle)
        XCTAssertEqual(
            unlockedByPass.withUnsafeBytes { Data($0) },
            unlockedByRec.withUnsafeBytes { Data($0) }
        )

        XCTAssertThrowsError(try VaultCrypto.unlockMasterKey(passphrase: "wrong-passphrase", bundle: bundle))

        let encName = try VaultCrypto.encryptFilename("Quarterly Financials 2026.xlsx", masterKey: unlockedByPass)
        let decName = try VaultCrypto.decryptFilename(encName, masterKey: unlockedByPass)
        XCTAssertEqual(decName, "Quarterly Financials 2026.xlsx")

        let smallChunkSize = 1024
        var plainPayload = Data(count: 2500)
        for i in 0..<plainPayload.count {
            plainPayload[i] = UInt8(i % 251)
        }
        let encryptedStream = try VaultCrypto.encryptFileData(
            plainPayload,
            masterKey: unlockedByPass,
            chunkSize: smallChunkSize
        )
        let fullDecrypted = try VaultCrypto.decryptFileData(
            encryptedStream,
            masterKey: unlockedByPass,
            chunkSize: smallChunkSize
        )
        XCTAssertEqual(fullDecrypted, plainPayload)

        let header = try VaultCrypto.FDE1Header.parse(from: encryptedStream)
        let fileKey = try VaultCrypto.unwrapFileKey(header: header, masterKey: unlockedByPass)
        let range1 = VaultCrypto.encryptedChunkRange(
            chunkIndex: 1,
            plaintextFileSize: Int64(plainPayload.count),
            chunkSize: smallChunkSize
        )!
        let wireSlice1 = encryptedStream.subdata(in: Int(range1.offset)..<Int(range1.offset) + range1.length)
        let plainChunk1 = try VaultCrypto.decryptChunk(
            wireSlice1,
            chunkIndex: 1,
            noncePrefix: header.noncePrefix,
            fileKey: fileKey
        )
        XCTAssertEqual(plainChunk1, plainPayload.subdata(in: 1024..<2048))
    }
}
