import Foundation

/// The set of pieces a peer has, in the wire layout: high bit first.
public struct Bitfield: Sendable, Equatable {
    public let count: Int
    private var bytes: [UInt8]

    public init(count: Int) {
        self.count = count
        self.bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
    }

    /// Accepts a peer's bitfield message; spare trailing bits are ignored.
    public init?(count: Int, data: Data) {
        guard data.count == (count + 7) / 8 else { return nil }
        self.count = count
        self.bytes = [UInt8](data)
        let spare = bytes.count * 8 - count
        if spare > 0 { bytes[bytes.count - 1] &= 0xFF << UInt8(spare) }
    }

    public static func full(count: Int) -> Bitfield {
        var b = Bitfield(count: count)
        for i in 0..<count { b.set(i) }
        return b
    }

    public subscript(index: Int) -> Bool {
        guard index >= 0, index < count else { return false }
        return bytes[index >> 3] & (0x80 >> UInt8(index & 7)) != 0
    }

    public mutating func set(_ index: Int) {
        guard index >= 0, index < count else { return }
        bytes[index >> 3] |= 0x80 >> UInt8(index & 7)
    }

    public var setCount: Int {
        bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    public var isComplete: Bool { setCount == count }

    public var data: Data { Data(bytes) }
}
