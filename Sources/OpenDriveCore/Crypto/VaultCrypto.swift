import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

/// Zero-knowledge `ODE1` random-access chunk cipher, filename encryption, and `.od-meta` key derivation.
///
/// Binary layout of an `ODE1` encrypted file:
/// - Bytes `0..<4`: Magic `"ODE1"` (`0x4F, 0x44, 0x45, 0x31`)
/// - Bytes `4..<12`: 8-byte random `noncePrefix`
/// - Bytes `12..<72`: 60-byte AES-GCM combined box (`wrappedFK`: 12-byte nonce + 32-byte per-file key + 16-byte tag)
/// - Total Header Size: `72` bytes.
/// - Followed by encrypted chunks. Each plaintext chunk of up to `chunkSize` (4 MiB) is encrypted with AES-256-GCM
///   using `fileKey` and a deterministic 12-byte nonce = `noncePrefix (8 bytes) || UInt32(chunkIndex).bigEndian (4 bytes)`.
///   Each encrypted chunk on the wire is `plaintextChunk.count + 16` bytes (ciphertext + 16-byte GCM authentication tag).
public enum VaultCrypto {
    public static let magic = Data("ODE1".utf8)
    public static let noncePrefixLength = 8
    public static let wrappedKeyLength = 12 + 32 + 16 // 60 bytes
    public static let headerSize = 4 + noncePrefixLength + wrappedKeyLength // 72 bytes
    public static let gcmTagSize = 16

    public struct ODE1Header: Sendable, Equatable {
        public let noncePrefix: Data
        public let wrappedFK: Data

        public init(noncePrefix: Data, wrappedFK: Data) {
            self.noncePrefix = noncePrefix
            self.wrappedFK = wrappedFK
        }

        public func serialize() -> Data {
            var out = Data(capacity: VaultCrypto.headerSize)
            out.append(VaultCrypto.magic)
            out.append(noncePrefix)
            out.append(wrappedFK)
            return out
        }

        public static func parse(from data: Data) throws -> ODE1Header {
            guard data.count >= VaultCrypto.headerSize else {
                throw VaultCryptoError.invalidHeader
            }
            let prefix = data.subdata(in: 0..<4)
            guard prefix == VaultCrypto.magic else {
                throw VaultCryptoError.invalidHeader
            }
            let noncePrefix = data.subdata(in: 4..<12)
            let wrappedFK = data.subdata(in: 12..<VaultCrypto.headerSize)
            return ODE1Header(noncePrefix: noncePrefix, wrappedFK: wrappedFK)
        }
    }

    // MARK: - Key Derivation & `.od-meta` Creation / Unlock

    public static func generateMasterKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func createKeyBundle(
        passphrase: String,
        masterKey: SymmetricKey = generateMasterKey()
    ) throws -> (bundle: KeyBundle, recoveryWords: [String], masterKeyData: Data) {
        let saltData = try secureRandomBytes(count: 16)
        let kdf = KeyBundle.KDF(salt: Base64URL.encode(saltData))

        let passKEK = try derivePassphraseKEK(passphrase: passphrase, salt: saltData, iterations: kdf.ops)
        let recoveryWords = generateRecoveryPhrase()
        let recoveryKEK = deriveRecoveryKEK(words: recoveryWords)

        let mkData = masterKey.withUnsafeBytes { Data($0) }
        guard let wrappedByPass = try AES.GCM.seal(mkData, using: passKEK).combined,
              let wrappedByRec = try AES.GCM.seal(mkData, using: recoveryKEK).combined else {
            throw VaultCryptoError.invalidHeader
        }

        let privKey = Curve25519.KeyAgreement.PrivateKey()
        let pubData = privKey.publicKey.rawRepresentation
        guard let wrappedPriv = try AES.GCM.seal(privKey.rawRepresentation, using: masterKey).combined else {
            throw VaultCryptoError.invalidHeader
        }

        let bundle = KeyBundle(
            v: 1,
            kdf: kdf,
            mkByPass: Base64URL.encode(wrappedByPass),
            mkByRecovery: Base64URL.encode(wrappedByRec),
            reqPub: Base64URL.encode(pubData),
            reqPrivByMK: Base64URL.encode(wrappedPriv)
        )
        return (bundle, recoveryWords, mkData)
    }

    public static func unlockMasterKey(passphrase: String, bundle: KeyBundle) throws -> SymmetricKey {
        guard bundle.v == 1,
              bundle.kdf.alg == "PBKDF2-HMAC-SHA256",
              (10_000...2_000_000).contains(bundle.kdf.ops) else {
            throw VaultCryptoError.invalidKDFParameters
        }
        let saltData = try Base64URL.decode(bundle.kdf.salt)
        guard saltData.count >= 16 else {
            throw VaultCryptoError.invalidKDFParameters
        }
        let passKEK = try derivePassphraseKEK(passphrase: passphrase, salt: saltData, iterations: bundle.kdf.ops)
        let combined = try Base64URL.decode(bundle.mkByPass)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let mkData = try AES.GCM.open(box, using: passKEK)
            return SymmetricKey(data: mkData)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    public static func unlockMasterKey(recoveryWords: [String], bundle: KeyBundle) throws -> SymmetricKey {
        guard recoveryWords.count == 24 else {
            throw VaultCryptoError.invalidRecoveryPhrase
        }
        let recoveryKEK = deriveRecoveryKEK(words: recoveryWords)
        let combined = try Base64URL.decode(bundle.mkByRecovery)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let mkData = try AES.GCM.open(box, using: recoveryKEK)
            return SymmetricKey(data: mkData)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    // MARK: - Per-File `ODE1` Chunk Encryption & Random-Access Decryption

    public static func makeFileHeader(masterKey: SymmetricKey) throws -> (header: ODE1Header, fileKey: SymmetricKey) {
        let fileKey = SymmetricKey(size: .bits256)
        let fkData = fileKey.withUnsafeBytes { Data($0) }
        let noncePrefix = try secureRandomBytes(count: noncePrefixLength)

        guard let wrappedFK = try AES.GCM.seal(fkData, using: masterKey).combined else {
            throw VaultCryptoError.invalidHeader
        }
        let header = ODE1Header(noncePrefix: noncePrefix, wrappedFK: wrappedFK)
        return (header, fileKey)
    }

    public static func unwrapFileKey(header: ODE1Header, masterKey: SymmetricKey) throws -> SymmetricKey {
        do {
            let box = try AES.GCM.SealedBox(combined: header.wrappedFK)
            let fkData = try AES.GCM.open(box, using: masterKey)
            return SymmetricKey(data: fkData)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    public static func chunkNonce(noncePrefix: Data, chunkIndex: Int) throws -> AES.GCM.Nonce {
        guard noncePrefix.count == noncePrefixLength, chunkIndex >= 0, chunkIndex <= Int(UInt32.max) else {
            throw VaultCryptoError.chunkIndexOutOfBounds
        }
        var nonceBytes = Data(capacity: 12)
        nonceBytes.append(noncePrefix)
        var idxBE = UInt32(chunkIndex).bigEndian
        withUnsafeBytes(of: &idxBE) { nonceBytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: nonceBytes)
    }

    /// Encrypts a single plaintext chunk (`index`) using the file's `fileKey` and `noncePrefix`.
    public static func encryptChunk(
        _ plaintextChunk: Data,
        chunkIndex: Int,
        noncePrefix: Data,
        fileKey: SymmetricKey
    ) throws -> Data {
        let nonce = try chunkNonce(noncePrefix: noncePrefix, chunkIndex: chunkIndex)
        let sealed = try AES.GCM.seal(plaintextChunk, using: fileKey, nonce: nonce)
        var out = Data(capacity: sealed.ciphertext.count + sealed.tag.count)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Decrypts a single encrypted chunk (`index`) back to plaintext.
    public static func decryptChunk(
        _ encryptedChunk: Data,
        chunkIndex: Int,
        noncePrefix: Data,
        fileKey: SymmetricKey
    ) throws -> Data {
        guard encryptedChunk.count >= gcmTagSize else {
            throw VaultCryptoError.authenticationFailed
        }
        let nonce = try chunkNonce(noncePrefix: noncePrefix, chunkIndex: chunkIndex)
        let cipherLen = encryptedChunk.count - gcmTagSize
        let ciphertext = encryptedChunk.subdata(in: 0..<cipherLen)
        let tag = encryptedChunk.subdata(in: cipherLen..<encryptedChunk.count)
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: fileKey)
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    /// Computes the remote encrypted byte range `(offset, length)` for a given chunk index.
    public static func encryptedChunkRange(
        chunkIndex: Int,
        plaintextFileSize: Int64,
        chunkSize: Int = OpenDrivePaths.defaultChunkSize
    ) -> (offset: Int64, length: Int)? {
        let plainStart = Int64(chunkIndex) * Int64(chunkSize)
        if plainStart >= plaintextFileSize && plaintextFileSize > 0 {
            return nil
        }
        let remainingPlain = max(0, plaintextFileSize - plainStart)
        let thisPlainLen = Int(min(Int64(chunkSize), remainingPlain))
        let encryptedOffset = Int64(headerSize) + Int64(chunkIndex) * Int64(chunkSize + gcmTagSize)
        let encryptedLength = thisPlainLen + gcmTagSize
        return (encryptedOffset, encryptedLength)
    }

    /// Encrypts an entire plaintext buffer into an `ODE1` stream (Header + AES-GCM chunks).
    public static func encryptFileData(
        _ plaintext: Data,
        masterKey: SymmetricKey,
        chunkSize: Int = OpenDrivePaths.defaultChunkSize
    ) throws -> Data {
        let (header, fileKey) = try makeFileHeader(masterKey: masterKey)
        var output = header.serialize()
        if plaintext.isEmpty {
            let emptyChunk = try encryptChunk(Data(), chunkIndex: 0, noncePrefix: header.noncePrefix, fileKey: fileKey)
            output.append(emptyChunk)
            return output
        }

        var offset = 0
        var chunkIndex = 0
        while offset < plaintext.count {
            let end = min(offset + chunkSize, plaintext.count)
            let slice = plaintext.subdata(in: offset..<end)
            let encrypted = try encryptChunk(slice, chunkIndex: chunkIndex, noncePrefix: header.noncePrefix, fileKey: fileKey)
            output.append(encrypted)
            offset = end
            chunkIndex += 1
        }
        return output
    }

    /// Decrypts a complete `ODE1` stream back to plaintext.
    public static func decryptFileData(
        _ encryptedData: Data,
        masterKey: SymmetricKey,
        chunkSize: Int = OpenDrivePaths.defaultChunkSize
    ) throws -> Data {
        let header = try ODE1Header.parse(from: encryptedData)
        let fileKey = try unwrapFileKey(header: header, masterKey: masterKey)
        let body = encryptedData.subdata(in: headerSize..<encryptedData.count)
        let wireChunkSize = chunkSize + gcmTagSize

        var output = Data()
        var offset = 0
        var chunkIndex = 0
        while offset < body.count {
            let end = min(offset + wireChunkSize, body.count)
            let slice = body.subdata(in: offset..<end)
            let plain = try decryptChunk(slice, chunkIndex: chunkIndex, noncePrefix: header.noncePrefix, fileKey: fileKey)
            output.append(plain)
            offset = end
            chunkIndex += 1
        }
        return output
    }

    /// Streams `sourceURL` chunk-by-chunk into an `ODE1` file at `destinationURL` without loading the entire file into RAM.
    @discardableResult
    public static func encryptFile(
        at sourceURL: URL,
        to destinationURL: URL,
        masterKey: SymmetricKey,
        chunkSize: Int = OpenDrivePaths.defaultChunkSize
    ) throws -> Int64 {
        let (header, fileKey) = try makeFileHeader(masterKey: masterKey)
        try OpenDrivePaths.createPrivateDirectory(at: destinationURL.deletingLastPathComponent())
        FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        OpenDrivePaths.setPrivateFilePermissions(at: destinationURL)

        let reader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destinationURL)
        defer { try? writer.close() }

        let headerData = header.serialize()
        try writer.write(contentsOf: headerData)
        var totalWritten = Int64(headerData.count)

        var chunkIndex = 0
        while true {
            let plainChunk = try reader.read(upToCount: chunkSize) ?? Data()
            if plainChunk.isEmpty {
                if chunkIndex == 0 {
                    let emptyChunk = try encryptChunk(
                        Data(),
                        chunkIndex: 0,
                        noncePrefix: header.noncePrefix,
                        fileKey: fileKey
                    )
                    try writer.write(contentsOf: emptyChunk)
                    totalWritten += Int64(emptyChunk.count)
                }
                break
            }
            let encrypted = try encryptChunk(
                plainChunk,
                chunkIndex: chunkIndex,
                noncePrefix: header.noncePrefix,
                fileKey: fileKey
            )
            try writer.write(contentsOf: encrypted)
            totalWritten += Int64(encrypted.count)
            chunkIndex += 1
        }

        try writer.synchronize()
        return totalWritten
    }

    // MARK: - Filename & Symlink Encryption (`ODNames` / `ODSymlink`)

    public static func deriveNameKey(masterKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            info: Data("ODNames-v1".utf8),
            outputByteCount: 32
        )
    }

    public static func encryptFilename(_ name: String, masterKey: SymmetricKey) throws -> String {
        let nameKey = deriveNameKey(masterKey: masterKey)
        let plainData = Data(name.utf8)
        guard let combined = try AES.GCM.seal(plainData, using: nameKey).combined else {
            throw VaultCryptoError.invalidHeader
        }
        return Base64URL.encode(combined)
    }

    public static func decryptFilename(_ encName: String, masterKey: SymmetricKey) throws -> String {
        let nameKey = deriveNameKey(masterKey: masterKey)
        let combined = try Base64URL.decode(encName)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plainData = try AES.GCM.open(box, using: nameKey)
        guard let decoded = String(data: plainData, encoding: .utf8) else {
            throw VaultCryptoError.authenticationFailed
        }
        return decoded
    }

    public static func deriveSymlinkKey(masterKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            info: Data("ODSymlink-v1".utf8),
            outputByteCount: 32
        )
    }

    public static func encryptSymlinkTarget(_ target: String, masterKey: SymmetricKey) throws -> String {
        let key = deriveSymlinkKey(masterKey: masterKey)
        let plainData = Data(target.utf8)
        guard let combined = try AES.GCM.seal(plainData, using: key).combined else {
            throw VaultCryptoError.invalidHeader
        }
        return Base64URL.encode(combined)
    }

    public static func decryptSymlinkTarget(_ encoded: String, masterKey: SymmetricKey) throws -> String {
        let key = deriveSymlinkKey(masterKey: masterKey)
        let combined = try Base64URL.decode(encoded)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plainData = try AES.GCM.open(box, using: key)
        guard let decoded = String(data: plainData, encoding: .utf8) else {
            throw VaultCryptoError.authenticationFailed
        }
        return decoded
    }

    /// Decrypts remote encrypted filename (`encName`) and inline symlink target when present.
    public static func decryptRemoteMetadata(_ item: DriveItem, masterKey: SymmetricKey?) -> DriveItem {
        guard item.isEncrypted, let masterKey else {
            return item
        }
        var copy = item
        if let encName = copy.encName,
           let clearName = try? decryptFilename(encName, masterKey: masterKey) {
            copy.name = clearName
        }
        if copy.isSymlink, let rawSym = copy.symlinkTarget, !rawSym.isEmpty,
           let clearTarget = try? decryptSymlinkTarget(rawSym, masterKey: masterKey) {
            copy.symlinkTarget = clearTarget
            copy.size = Int64(clearTarget.utf8.count)
        }
        return copy
    }

    // MARK: - Internal KDF, Zeroization & Recovery Phrase Helpers

    private static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            zeroize(&bytes)
            throw VaultCryptoError.randomGenerationFailed
        }
        let data = Data(bytes)
        zeroize(&bytes)
        return data
    }

    private static func zeroize(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        _ = memset_s(&bytes, bytes.count, 0, bytes.count)
    }

    private static func derivePassphraseKEK(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard salt.count >= 16, (10_000...2_000_000).contains(iterations) else {
            throw VaultCryptoError.invalidKDFParameters
        }
        var derived = [UInt8](repeating: 0, count: 32)
        var passBytes = Array(passphrase.utf8)
        defer {
            zeroize(&derived)
            zeroize(&passBytes)
        }
        let rc: Int32 = passBytes.withUnsafeBufferPointer { passPtr in
            salt.withUnsafeBytes { saltPtr in
                let passBase = passPtr.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }
                let saltBase = saltPtr.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passBase,
                    passPtr.count,
                    saltBase,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derived.count
                )
            }
        }
        guard rc == kCCSuccess else {
            throw VaultCryptoError.authenticationFailed
        }
        return SymmetricKey(data: Data(derived))
    }

    private static func deriveRecoveryKEK(words: [String]) -> SymmetricKey {
        var normalizedBytes = Array(
            words.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
                .utf8
        )
        defer { zeroize(&normalizedBytes) }
        let ikm = SymmetricKey(data: Data(normalizedBytes))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("OpenDrive-BIP39-Recovery-v1".utf8),
            info: Data("mkByRecovery".utf8),
            outputByteCount: 32
        )
    }

    private static let wordList: [String] = [
        "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract",
        "absurd", "abuse", "access", "accident", "account", "accuse", "achieve", "acid",
        "acoustic", "acquire", "across", "act", "action", "actor", "actress", "actual",
        "adapt", "add", "addict", "address", "adjust", "admit", "adult", "advance",
        "advice", "aerobic", "affair", "afford", "afraid", "again", "age", "agent",
        "agree", "ahead", "aim", "air", "airport", "aisle", "alarm", "album",
        "alcohol", "alert", "alien", "all", "alley", "allow", "almost", "alone",
        "alpha", "already", "also", "alter", "always", "amateur", "amazing", "among",
        "amount", "amused", "analyst", "anchor", "ancient", "anger", "angle", "angry",
        "animal", "ankle", "announce", "annual", "another", "answer", "antenna", "antique",
        "anxiety", "any", "apart", "apology", "appear", "apple", "approve", "april",
        "arch", "arctic", "area", "arena", "argue", "arm", "armed", "armor",
        "army", "around", "arrange", "arrest", "arrive", "arrow", "art", "artefact",
        "artist", "artwork", "ask", "aspect", "assault", "asset", "assist", "assume",
        "asthma", "athlete", "atom", "attack", "attend", "attitude", "attract", "auction",
        "audit", "august", "aunt", "author", "auto", "autumn", "average", "avocado",
        "avoid", "awake", "aware", "away", "awesome", "awful", "awkward", "axis",
        "baby", "bachelor", "bacon", "badge", "bag", "balance", "balcony", "ball",
        "bamboo", "banana", "banner", "bar", "barely", "bargain", "barrel", "base",
        "basic", "basket", "battle", "beach", "bean", "beauty", "because", "become",
        "beef", "before", "begin", "behave", "behind", "believe", "below", "belt",
        "bench", "benefit", "best", "betray", "better", "between", "beyond", "bicycle",
        "bid", "bike", "bind", "biology", "bird", "birth", "bitter", "black",
        "blade", "blame", "blanket", "blast", "bleak", "bless", "blind", "blood",
        "blossom", "blouse", "blue", "blur", "blush", "board", "boat", "body",
        "boil", "bomb", "bone", "bonus", "book", "boost", "border", "boring",
        "borrow", "boss", "bottom", "bounce", "box", "boy", "bracket", "brain",
        "brand", "brass", "brave", "bread", "breeze", "brick", "bridge", "brief",
        "bright", "bring", "brisk", "broccoli", "broken", "bronze", "broom", "brother",
        "brown", "brush", "bubble", "buddy", "budget", "buffalo", "build", "bulb",
        "bulk", "bullet", "bundle", "bunker", "burden", "burger", "burst", "bus",
        "business", "busy", "butter", "buyer", "buzz", "cabbage", "cabin", "cable"
    ]

    public static func generateRecoveryPhrase() -> [String] {
        let randomKey = SymmetricKey(size: .bits256)
        return randomKey.withUnsafeBytes { raw in
            (0..<24).map { idx in wordList[Int(raw[idx]) % wordList.count] }
        }
    }
}
