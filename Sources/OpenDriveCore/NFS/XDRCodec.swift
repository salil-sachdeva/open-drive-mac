import Darwin
import Foundation

// MARK: - RFC 5531 / RFC 1813 Constants

enum RPCProgram {
    static let nfs: UInt32 = 100_003
    static let mount: UInt32 = 100_005
}

enum MOUNTv3Procedure: UInt32 {
    case null = 0
    case mnt = 1
    case dump = 2
    case umnt = 3
    case umntAll = 4
    case export = 5
}

enum NFSv3Procedure: UInt32 {
    case null = 0
    case getattr = 1
    case setattr = 2
    case lookup = 3
    case access = 4
    case readlink = 5
    case read = 6
    case write = 7
    case create = 8
    case mkdir = 9
    case symlink = 10
    case mknod = 11
    case remove = 12
    case rmdir = 13
    case rename = 14
    case link = 15
    case readdir = 16
    case readdirPlus = 17
    case fsstat = 18
    case fsinfo = 19
    case pathconf = 20
    case commit = 21
}

enum NFS3Status: UInt32 {
    case ok = 0
    case perm = 1
    case noent = 2
    case io = 5
    case acces = 13
    case exist = 17
    case xdev = 18
    case notdir = 20
    case isdir = 21
    case inval = 22
    case rofs = 30
    case nameTooLong = 63
    case notEmpty = 66
    case stale = 70
    case notSupp = 10_004
}

enum NFS3FileType: UInt32 {
    case regular = 1
    case directory = 2
    case symlink = 5
}

enum NFS3AccessMask {
    static let read: UInt32 = 0x01
    static let lookup: UInt32 = 0x02
    static let modify: UInt32 = 0x04
    static let extend: UInt32 = 0x08
    static let delete: UInt32 = 0x10
    static let execute: UInt32 = 0x20
}

enum NFS3WriteStable {
    static let unstable: UInt32 = 0
    static let dataSync: UInt32 = 1
    static let fileSync: UInt32 = 2
}

enum NFS3CreateMode: UInt32 {
    case unchecked = 0
    case guarded = 1
    case exclusive = 2
}

enum XDRDecodeError: Error {
    case unexpectedEOF
    case invalidRPCMessage
}

struct NFSAttributes: Sendable, Equatable {
    var fileType: NFS3FileType
    var mode: UInt32
    var nlink: UInt32
    var uid: UInt32
    var gid: UInt32
    var size: UInt64
    var usedBytes: UInt64 = 0
    var fileId: UInt64
    var modifiedTime: Double

    var isDirectory: Bool {
        fileType == .directory
    }
}

struct RPCCallHeader: Sendable {
    let xid: UInt32
    let rpcVersion: UInt32
    let program: UInt32
    let programVersion: UInt32
    let procedure: UInt32
}

// MARK: - XDR Reader

struct XDRReader {
    private let data: Data
    private(set) var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remainingBytes: Int {
        max(0, data.count - offset)
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw XDRDecodeError.unexpectedEOF
        }
        offset += count
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw XDRDecodeError.unexpectedEOF
        }
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + offset + i])
        }
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let hi = UInt64(try readUInt32())
        let lo = UInt64(try readUInt32())
        return (hi << 32) | lo
    }

    mutating func readBool() throws -> Bool {
        try readUInt32() != 0
    }

    mutating func readFixedOpaque(_ length: Int) throws -> Data {
        guard length >= 0, offset + length <= data.count else {
            throw XDRDecodeError.unexpectedEOF
        }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + length))
        let padded = (length + 3) & ~3
        guard offset + padded <= data.count else {
            throw XDRDecodeError.unexpectedEOF
        }
        offset += padded
        return slice
    }

    mutating func readOpaque(maxLength: Int = 64 * 1024 * 1024) throws -> Data {
        let len = Int(try readUInt32())
        guard len >= 0, len <= maxLength else {
            throw XDRDecodeError.invalidRPCMessage
        }
        return try readFixedOpaque(len)
    }

    mutating func readString(maxLength: Int = 64 * 1024) throws -> String {
        let raw = try readOpaque(maxLength: maxLength)
        guard let str = String(data: raw, encoding: .utf8) else {
            throw XDRDecodeError.invalidRPCMessage
        }
        return str
    }

    mutating func readFileHandleInode() throws -> UInt64 {
        let opaque = try readOpaque(maxLength: 64)
        guard opaque.count == 8 else {
            throw XDRDecodeError.invalidRPCMessage
        }
        var value: UInt64 = 0
        for b in opaque {
            value = (value << 8) | UInt64(b)
        }
        return value
    }

    mutating func readRPCCallHeader() throws -> RPCCallHeader {
        let xid = try readUInt32()
        let msgType = try readUInt32()
        guard msgType == 0 else {
            throw XDRDecodeError.invalidRPCMessage
        }
        let rpcVersion = try readUInt32()
        let program = try readUInt32()
        let programVersion = try readUInt32()
        let procedure = try readUInt32()
        // Skip cred & verf (auth flavor + opaque body)
        _ = try readUInt32()
        _ = try readOpaque(maxLength: 4096)
        _ = try readUInt32()
        _ = try readOpaque(maxLength: 4096)
        return RPCCallHeader(
            xid: xid,
            rpcVersion: rpcVersion,
            program: program,
            programVersion: programVersion,
            procedure: procedure
        )
    }
}

// MARK: - XDR Writer

struct XDRWriter {
    private(set) var data = Data()

    init(capacity: Int = 256) {
        data.reserveCapacity(capacity)
    }

    mutating func writeUInt32(_ value: UInt32) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    mutating func writeUInt64(_ value: UInt64) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    mutating func writeBool(_ value: Bool) {
        writeUInt32(value ? 1 : 0)
    }

    mutating func writeFixedOpaque(_ bytes: Data) {
        data.append(bytes)
        let rem = bytes.count & 3
        if rem != 0 {
            data.append(contentsOf: repeatElement(UInt8(0), count: 4 - rem))
        }
    }

    mutating func writeOpaque(_ bytes: Data) {
        writeUInt32(UInt32(bytes.count))
        writeFixedOpaque(bytes)
    }

    mutating func writeString(_ value: String) {
        writeOpaque(Data(value.utf8))
    }

    mutating func appendRaw(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writeFileHandle(_ inode: UInt64) {
        writeUInt32(8)
        writeUInt64(inode)
    }

    mutating func writeNFSTime(_ timestamp: Double) {
        guard timestamp.isFinite else {
            writeUInt32(0)
            writeUInt32(0)
            return
        }
        let clamped = min(Double(UInt32.max), max(0, timestamp))
        let secs = UInt32(clamped.rounded(.towardZero))
        let nsecsDouble = (clamped - Double(secs)) * 1_000_000_000
        let nsecs = UInt32(min(999_999_999, max(0, Int(nsecsDouble))))
        writeUInt32(secs)
        writeUInt32(nsecs)
    }

    mutating func writeFattr3(_ attrs: NFSAttributes) {
        writeUInt32(attrs.fileType.rawValue)
        writeUInt32(attrs.mode)
        writeUInt32(attrs.nlink)
        writeUInt32(attrs.uid)
        writeUInt32(attrs.gid)
        writeUInt64(attrs.size)
        writeUInt64(attrs.usedBytes)
        writeUInt32(0) // rdev.specdata1
        writeUInt32(0) // rdev.specdata2
        writeUInt64(1) // fsid
        writeUInt64(attrs.fileId)
        writeNFSTime(attrs.modifiedTime) // atime
        writeNFSTime(attrs.modifiedTime) // mtime
        writeNFSTime(attrs.modifiedTime) // ctime
    }

    mutating func writePostOpAttr(_ attrs: NFSAttributes?) {
        if let attrs {
            writeBool(true)
            writeFattr3(attrs)
        } else {
            writeBool(false)
        }
    }

    mutating func writeWccData(pre: NFSAttributes? = nil, post: NFSAttributes?) {
        if let pre {
            writeBool(true)
            writeUInt64(pre.size)
            writeNFSTime(pre.modifiedTime)
            writeNFSTime(pre.modifiedTime)
        } else {
            writeBool(false)
        }
        writePostOpAttr(post)
    }

    mutating func writePostOpFileHandle(_ inode: UInt64?) {
        if let inode {
            writeBool(true)
            writeFileHandle(inode)
        } else {
            writeBool(false)
        }
    }

    /// Wraps an RPC reply body with RFC 5531 TCP record marking.
    static func acceptedReply(xid: UInt32, acceptStatus: UInt32 = 0, body: Data = Data()) -> Data {
        var writer = XDRWriter(capacity: 28 + body.count)
        writer.writeUInt32(0) // placeholder for record mark
        writer.writeUInt32(xid)
        writer.writeUInt32(1) // REPLY
        writer.writeUInt32(0) // MSG_ACCEPTED
        writer.writeUInt32(0) // AUTH_NONE
        writer.writeUInt32(0)
        writer.writeUInt32(acceptStatus)
        writer.data.append(body)

        let payloadLength = UInt32(writer.data.count - 4)
        var mark = (0x8000_0000 | payloadLength).bigEndian
        writer.data.replaceSubrange(0..<4, with: withUnsafeBytes(of: &mark) { Data($0) })
        return writer.data
    }
}
