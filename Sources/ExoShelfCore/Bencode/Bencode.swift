import Foundation

/// A decoded bencode value. Dictionary keys are kept as raw bytes decoded to
/// strings; BitTorrent only ever uses ASCII keys.
public enum BValue: Sendable, Equatable {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([String: BValue])

    public subscript(key: String) -> BValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    public var int: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var data: Data? {
        if case .bytes(let v) = self { return v }
        return nil
    }

    public var string: String? {
        guard case .bytes(let v) = self else { return nil }
        return String(data: v, encoding: .utf8) ?? String(data: v, encoding: .isoLatin1)
    }

    public var list: [BValue]? {
        if case .list(let v) = self { return v }
        return nil
    }

    public var dict: [String: BValue]? {
        if case .dict(let v) = self { return v }
        return nil
    }
}

public enum BencodeError: Error, Equatable {
    case unexpectedEnd
    case invalid(at: Int)
}

/// Decodes bencode from a byte buffer. `rawRanges` records where the value of
/// each top-level dictionary key starts and ends, which is how the info hash
/// is taken over the exact bytes of the `info` dictionary.
public struct BencodeDecoder {
    private let bytes: [UInt8]
    private var pos = 0
    private var depth = 0
    public private(set) var rawRanges: [String: Range<Int>] = [:]

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    public static func decode(_ data: Data) throws -> BValue {
        var d = BencodeDecoder(data)
        return try d.decode()
    }

    public mutating func decode() throws -> BValue {
        try value()
    }

    /// Decodes one value and returns how many bytes it took, for messages
    /// where bencode is followed by raw payload (ut_metadata, ut_pex).
    public mutating func decodePrefix() throws -> (BValue, Int) {
        let v = try value()
        return (v, pos)
    }

    private mutating func value() throws -> BValue {
        guard pos < bytes.count else { throw BencodeError.unexpectedEnd }
        switch bytes[pos] {
        case UInt8(ascii: "i"):
            pos += 1
            let n = try integer(until: UInt8(ascii: "e"))
            return .int(n)
        case UInt8(ascii: "l"):
            pos += 1
            depth += 1
            var out: [BValue] = []
            while true {
                guard pos < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[pos] == UInt8(ascii: "e") { pos += 1; break }
                out.append(try value())
            }
            depth -= 1
            return .list(out)
        case UInt8(ascii: "d"):
            pos += 1
            depth += 1
            var out: [String: BValue] = [:]
            while true {
                guard pos < bytes.count else { throw BencodeError.unexpectedEnd }
                if bytes[pos] == UInt8(ascii: "e") { pos += 1; break }
                let keyBytes = try byteString()
                let key = String(decoding: keyBytes, as: UTF8.self)
                let start = pos
                let v = try value()
                if depth == 1 { rawRanges[key] = start..<pos }
                out[key] = v
            }
            depth -= 1
            return .dict(out)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .bytes(Data(try byteString()))
        default:
            throw BencodeError.invalid(at: pos)
        }
    }

    private mutating func integer(until terminator: UInt8) throws -> Int64 {
        var negative = false
        var n: Int64 = 0
        var digits = 0
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { negative = true; pos += 1 }
        while true {
            guard pos < bytes.count else { throw BencodeError.unexpectedEnd }
            let c = bytes[pos]
            if c == terminator { pos += 1; break }
            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { throw BencodeError.invalid(at: pos) }
            n = n &* 10 &+ Int64(c - UInt8(ascii: "0"))
            digits += 1
            pos += 1
        }
        guard digits > 0 else { throw BencodeError.invalid(at: pos) }
        return negative ? -n : n
    }

    private mutating func byteString() throws -> ArraySlice<UInt8> {
        let length = try integer(until: UInt8(ascii: ":"))
        guard length >= 0, pos + Int(length) <= bytes.count else { throw BencodeError.unexpectedEnd }
        let slice = bytes[pos..<(pos + Int(length))]
        pos += Int(length)
        return slice
    }
}

/// Encodes values for the few messages we send that carry bencode
/// (the extension handshake). Keys are written in sorted order, as the
/// format requires.
public enum BencodeEncoder {
    public static func encode(_ value: BValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: BValue, into out: inout Data) {
        switch value {
        case .int(let n):
            out.append(contentsOf: Array("i\(n)e".utf8))
        case .bytes(let d):
            out.append(contentsOf: Array("\(d.count):".utf8))
            out.append(d)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            for item in items { write(item, into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let d):
            out.append(UInt8(ascii: "d"))
            for key in d.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                let k = Data(key.utf8)
                out.append(contentsOf: Array("\(k.count):".utf8))
                out.append(k)
                write(d[key]!, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}
