import XCTest
@testable import GazeCore

final class ZipArchiveTests: XCTestCase {
    func testCRCCheckValue() {
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    func testDosTime() {
        // 2026-11-15 13:45:58 UTC
        let date = Date(timeIntervalSince1970: 1_794_750_358)
        let (time, day) = ZipArchive.dosTime(date)
        XCTAssertEqual(Int(time >> 11), 13)
        XCTAssertEqual(Int((time >> 5) & 0x3F), 45)
        XCTAssertEqual(Int(time & 0x1F) * 2, 58)
        XCTAssertEqual(Int(day >> 9) + 1980, 2026)
        XCTAssertEqual(Int((day >> 5) & 0x0F), 11)
        XCTAssertEqual(Int(day & 0x1F), 15)
    }

    /// Reads the archive back the way an unzip tool does: from the end record to the central directory to each
    /// local header, and checks the names, sizes, checksums and bytes.
    func testArchiveReadsBack() throws {
        var zip = ZipArchive()
        let csv = Data("kind;t\nframe;0,016\n".utf8)
        zip.add("К-07/сессия-01.csv", data: csv, modified: Date(timeIntervalSince1970: 1_794_750_358))
        zip.add("README.txt", text: "data dictionary")
        zip.add("empty.csv", data: Data())
        let bytes = [UInt8](zip.data())

        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        let end = bytes.count - 22
        XCTAssertEqual(u32(end), 0x0605_4B50)
        XCTAssertEqual(u16(end + 10), 3)
        let centralSize = u32(end + 12), centralOffset = u32(end + 16)
        XCTAssertEqual(centralOffset + centralSize, end)

        var at = centralOffset
        var found: [String: Data] = [:]
        for _ in 0..<3 {
            XCTAssertEqual(u32(at), 0x0201_4B50)
            XCTAssertEqual(u16(at + 8) & 0x0800, 0x0800, "UTF-8 names")
            XCTAssertEqual(u16(at + 10), 0, "stored")
            let crc = u32(at + 16), size = u32(at + 20)
            XCTAssertEqual(size, u32(at + 24))
            let nameLength = u16(at + 28)
            let name = try XCTUnwrap(String(bytes: bytes[(at + 46)..<(at + 46 + nameLength)], encoding: .utf8))
            let local = u32(at + 42)
            XCTAssertEqual(u32(local), 0x0403_4B50)
            XCTAssertEqual(u32(local + 14), crc)
            let dataStart = local + 30 + u16(local + 26) + u16(local + 28)
            let data = Data(bytes[dataStart..<(dataStart + size)])
            XCTAssertEqual(Int(ZipArchive.crc32(data)), crc)
            found[name] = data
            at += 46 + nameLength + u16(at + 30) + u16(at + 32)
        }
        XCTAssertEqual(found["К-07/сессия-01.csv"], csv)
        XCTAssertEqual(found["README.txt"], Data("data dictionary".utf8))
        XCTAssertEqual(found["empty.csv"], Data())
    }
}
