import Foundation

/// Errors thrown by `VaultCrypto` and `Base64URL`.
public enum VaultCryptoError: Error, LocalizedError, Equatable {
    case invalidHeader
    case authenticationFailed
    case invalidRecoveryPhrase
    case invalidBase64URL
    case chunkIndexOutOfBounds
    case randomGenerationFailed
    case invalidKDFParameters

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: return "Invalid ODE1 encryption header"
        case .authenticationFailed: return "Decryption failed or ciphertext was tampered with"
        case .invalidRecoveryPhrase: return "Invalid 24-word recovery phrase"
        case .invalidBase64URL: return "Invalid Base64URL encoded string"
        case .chunkIndexOutOfBounds: return "Encrypted chunk index out of bounds"
        case .randomGenerationFailed: return "Cryptographic random generation failed"
        case .invalidKDFParameters: return "Invalid or out-of-range key derivation parameters"
        }
    }
}
