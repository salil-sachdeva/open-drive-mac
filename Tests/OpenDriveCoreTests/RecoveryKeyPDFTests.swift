import XCTest
@testable import OpenDriveCore

final class RecoveryKeyPDFTests: XCTestCase {
    func testVaultCryptoRecoveryKeyPDFGeneration() throws {
        let words = VaultCrypto.generateRecoveryPhrase()
        XCTAssertEqual(words.count, 24)
        let pdfData = VaultCrypto.generateRecoveryKeyPDF(
            accountName: "Personal Google Drive",
            email: "user@example.com",
            words: words
        )
        let prefix = String(decoding: pdfData.prefix(5), as: UTF8.self)
        XCTAssertEqual(prefix, "%PDF-")
    }
}
