import Foundation

/// Wrapped master-key metadata bundle stored at the vault root as `.fd-meta`.
public struct KeyBundle: Codable, Sendable, Equatable {
    public struct KDF: Codable, Sendable, Equatable {
        public var alg: String
        public var ops: Int
        public var mem: Int
        public var salt: String

        public init(alg: String = "PBKDF2-HMAC-SHA256", ops: Int = 210_000, mem: Int = 0, salt: String) {
            self.alg = alg
            self.ops = ops
            self.mem = mem
            self.salt = salt
        }
    }

    public var v: Int
    public var kdf: KDF
    public var mkByPass: String
    public var mkByRecovery: String
    public var reqPub: String?
    public var reqPrivByMK: String?

    public init(
        v: Int = 1,
        kdf: KDF,
        mkByPass: String,
        mkByRecovery: String,
        reqPub: String? = nil,
        reqPrivByMK: String? = nil
    ) {
        self.v = v
        self.kdf = kdf
        self.mkByPass = mkByPass
        self.mkByRecovery = mkByRecovery
        self.reqPub = reqPub
        self.reqPrivByMK = reqPrivByMK
    }
}
