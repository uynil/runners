import XCTest
@testable import RunnersPhoneCore

final class MapChunkTests: XCTestCase {
    func testChunkResumeDuplicateAndChecksumValidation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receiver = MapChunkReceiver(directory: folder)
        let raw = Data("abcdefgh".utf8), digest = MapBundleStorage.digest(raw)
        let id = UUID()
        let first = MapChunk(id: id, checksum: digest, total: 8, offset: 0, data: raw.prefix(4))
        XCTAssertNil(try receiver.accept(first))
        XCTAssertNil(try receiver.accept(first))
        let restarted = MapChunkReceiver(directory: folder)
        XCTAssertThrowsError(try restarted.accept(MapChunk(id: id, checksum: digest, total: 8, offset: 6, data: Data("gh".utf8))))
        XCTAssertEqual(try restarted.accept(MapChunk(id: id, checksum: digest, total: 8, offset: 4, data: raw.suffix(4))), raw)
        XCTAssertThrowsError(try receiver.accept(MapChunk(id: UUID(), checksum: digest, total: 4, offset: 0, data: Data("fake".utf8))))
        XCTAssertThrowsError(try receiver.accept(MapChunk(id: UUID(), checksum: digest, total: MapBundleStorage.maximumBytes + 1, offset: 0, data: raw)))
    }
}
