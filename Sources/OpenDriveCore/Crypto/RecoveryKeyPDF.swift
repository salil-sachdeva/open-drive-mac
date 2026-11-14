import CoreGraphics
import CoreText
import Foundation

extension VaultCrypto {
    /// Generates a printable US-Letter PDF recovery sheet containing the 24-word recovery phrase.
    public static func generateRecoveryKeyPDF(
        accountName: String,
        email: String?,
        words: [String],
        createdAt: Date = Date()
    ) -> Data {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter (8.5 x 11 in)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data(words.joined(separator: " ").utf8)
        }

        context.beginPDFPage(nil)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateStr = dateFormatter.string(from: createdAt)

        var numberedWords: [String] = []
        for (idx, word) in words.enumerated() {
            numberedWords.append(String(format: "%2d. %@", idx + 1, word))
        }
        let gridLines = stride(from: 0, to: numberedWords.count, by: 4).map { start in
            let end = min(start + 4, numberedWords.count)
            return numberedWords[start..<end].map { $0.padding(toLength: 16, withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }.joined(separator: "\n")

        let documentText = """
        OPEN DRIVE — ZERO-KNOWLEDGE VAULT RECOVERY KEY
        ==============================================================

        Account:   \(accountName)\(email.map { " (\($0))" } ?? "")
        Generated: \(dateStr)
        Format:    FDE1 (AES-256-GCM + 24-Word Recovery Key)

        IMPORTANT:
        Keep this recovery sheet in a safe place (e.g., a password manager
        or printed in a secure location). Open Drive uses zero-knowledge
        encryption—if you forget your vault passphrase, this 24-word phrase
        is the ONLY way to recover your encrypted Google Drive files.

        24-WORD RECOVERY PHRASE:
        --------------------------------------------------------------
        \(gridLines)
        --------------------------------------------------------------

        Full Phrase (single line):
        \(words.joined(separator: " "))
        """

        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 11.0, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        let attrString = NSAttributedString(string: documentText, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let path = CGPath(rect: CGRect(x: 54, y: 54, width: 504, height: 684), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attrString.length), path, nil)
        CTFrameDraw(frame, context)

        context.endPDFPage()
        context.closePDF()
        return pdfData as Data
    }

    /// Exports a printable recovery sheet PDF to the specified file URL.
    public static func exportRecoveryKeyPDF(
        to url: URL,
        accountName: String,
        email: String?,
        words: [String]
    ) throws {
        let data = generateRecoveryKeyPDF(accountName: accountName, email: email, words: words)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
