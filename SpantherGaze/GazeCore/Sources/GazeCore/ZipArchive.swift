import Foundation

/// A .zip of stored (uncompressed) files, written in plain Swift so it builds and tests anywhere: the clinic's export
/// packs a course's raw session CSVs and the data dictionary into one file (architecture proposal, "Fitting the
/// Excellent Brain and Fusion workflow"). CSV files are small and compress well, but storing keeps the writer short and
/// every unzip tool reads it. Names are UTF-8 (flag bit 11), so Cyrillic file names survive.
public struct ZipArchive {
    public struct Entry: Equatable {
        public let name: String
        public let data: Data
        public let modified: Date

        public init(name: String, data: Data, modified: Date) {
            self.name = name
            self.data = data
            self.modified = modified
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func add(_ name: String, data: Data, modified: Date = Date()) {
        entries.append(Entry(name: name, data: data, modified: modified))
    }

    public mutating func add(_ name: String, text: String, modified: Date = Date()) {
        add(name, data: Data(text.utf8), modified: modified)
    }

    /// The archive's bytes: each file's local header and data, then the central directory and its end record.
    public func data() -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = Self.crc32(entry.data)
            let (time, date) = Self.dosTime(entry.modified)
            let offset = UInt32(truncatingIfNeeded: out.count)
            out.appendLE(UInt32(0x0403_4B50))
            out.appendLE(UInt16(20))          // version needed: 2.0
            out.appendLE(UInt16(0x0800))      // UTF-8 names
            out.appendLE(UInt16(0))           // stored
            out.appendLE(time)
            out.appendLE(date)
            out.appendLE(crc)
            out.appendLE(UInt32(truncatingIfNeeded: entry.data.count))
            out.appendLE(UInt32(truncatingIfNeeded: entry.data.count))
            out.appendLE(UInt16(truncatingIfNeeded: name.count))
            out.appendLE(UInt16(0))
            out.append(name)
            out.append(entry.data)

            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(20))      // made by: 2.0
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(time)
            central.appendLE(date)
            central.appendLE(crc)
            central.appendLE(UInt32(truncatingIfNeeded: entry.data.count))
            central.appendLE(UInt32(truncatingIfNeeded: entry.data.count))
            central.appendLE(UInt16(truncatingIfNeeded: name.count))
            central.appendLE(UInt16(0))       // extra
            central.appendLE(UInt16(0))       // comment
            central.appendLE(UInt16(0))       // disk
            central.appendLE(UInt16(0))       // internal attributes
            central.appendLE(UInt32(0))       // external attributes
            central.appendLE(offset)
            central.append(name)
        }
        let centralOffset = UInt32(truncatingIfNeeded: out.count)
        out.append(central)
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(truncatingIfNeeded: entries.count))
        out.appendLE(UInt16(truncatingIfNeeded: entries.count))
        out.appendLE(UInt32(truncatingIfNeeded: central.count))
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }

    /// CRC-32 (ISO 3309, the one zip uses): crc32("123456789") = 0xCBF43926.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// MS-DOS time and date (two-second steps, years from 1980), in UTC.
    static func dosTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, min(2107, c.year ?? 1980))
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let dayOfMonth: Int = c.day ?? 1
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateBits: Int = ((year - 1980) << 9) | (month << 5) | dayOfMonth
        return (UInt16(truncatingIfNeeded: timeBits), UInt16(truncatingIfNeeded: dateBits))
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8(v >> 24))
    }
}
