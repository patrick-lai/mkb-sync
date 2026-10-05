import Foundation

public enum CodecError: Error, Equatable {
    case truncated
    case unknownType(UInt8)
    case frameTooLarge(Int)
    case invalid(String)
}

/// Big-endian binary writer.
struct BinaryWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { append(v) }
    mutating func u32(_ v: UInt32) { append(v) }
    mutating func u64(_ v: UInt64) { append(v) }
    mutating func i16(_ v: Int16) { append(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { append(UInt32(bitPattern: v)) }
    mutating func i64(_ v: Int64) { append(UInt64(bitPattern: v)) }
    mutating func f64(_ v: Double) { append(v.bitPattern) }
    mutating func raw(_ d: [UInt8]) { bytes.append(contentsOf: d) }

    mutating func blob(_ d: Data) {
        u32(UInt32(d.count))
        bytes.append(contentsOf: d)
    }

    mutating func string(_ s: String) {
        let d = Array(s.utf8)
        u16(UInt16(min(d.count, Int(UInt16.max))))
        bytes.append(contentsOf: d.prefix(Int(UInt16.max)))
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) }
    }
}

/// Big-endian binary reader over a byte slice.
struct BinaryReader {
    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    var isAtEnd: Bool { index >= bytes.endIndex }
    var remaining: ArraySlice<UInt8> { bytes[index...] }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, bytes.endIndex - index >= n else { throw CodecError.truncated }
        defer { index += n }
        return bytes[index..<index + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 { try read() }
    mutating func u32() throws -> UInt32 { try read() }
    mutating func u64() throws -> UInt64 { try read() }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try read()) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try read()) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try read()) }
    mutating func f64() throws -> Double { Double(bitPattern: try read()) }

    mutating func blob() throws -> Data {
        let n = Int(try u32())
        return Data(try take(n))
    }

    mutating func string() throws -> String {
        let n = Int(try u16())
        guard let s = String(bytes: try take(n), encoding: .utf8) else { throw CodecError.invalid("utf8") }
        return s
    }

    private mutating func read<T: FixedWidthInteger>() throws -> T {
        let slice = try take(MemoryLayout<T>.size)
        var v: T = 0
        for b in slice { v = (v << 8) | T(b) }
        return v
    }
}
