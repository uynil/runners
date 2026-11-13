import Foundation
import zlib

struct MapTileID: Codable, Hashable {
    let z: Int
    let x: Int
    let y: Int
    var key: String { "\(z)-\(x)-\(y)" }

    static func covering(_ bounds: MapBounds, zoom: Int) throws -> [MapTileID] {
        guard bounds.isValid, bounds.south > -85, bounds.north < 85, (12...14).contains(zoom),
              bounds.areaSquareKilometers <= 100 else { throw MapError.invalid("选区或地图细节无效。") }
        let n = Double(1 << zoom)
        func column(_ lon: Double) -> Int { min(Int(n) - 1, max(0, Int(floor((lon + 180) / 360 * n)))) }
        func row(_ lat: Double) -> Int {
            let r = lat * .pi / 180
            return min(Int(n) - 1, max(0, Int(floor((1 - asinh(tan(r)) / .pi) / 2 * n))))
        }
        let xs = column(bounds.west)...column(bounds.east), ys = row(bounds.north)...row(bounds.south)
        guard xs.count * ys.count <= 256 else { throw MapError.invalid("选区超过 256 个地图分块，请缩小范围或降低细节。") }
        return ys.flatMap { y in xs.map { MapTileID(z: zoom, x: $0, y: y) } }
    }

    func coordinate(x localX: Int, y localY: Int, extent: Int) -> RoutePoint {
        let n = Double(1 << z)
        let worldX = (Double(x) + Double(localX) / Double(extent)) / n
        let worldY = (Double(y) + Double(localY) / Double(extent)) / n
        return RoutePoint(latitude: atan(sinh(.pi * (1 - 2 * worldY))) * 180 / .pi,
                          longitude: min(180, max(-180, worldX * 360 - 180)))
    }
}

/// Bounded protobuf reader for the Mapbox Vector Tile 2.x wire format.
private struct TileProto {
    let bytes: [UInt8]
    var index = 0
    init(_ data: Data) { bytes = Array(data) }
    var done: Bool { index == bytes.count }
    mutating func uint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < bytes.count else { throw VectorTileDecoder.invalid }
            let byte = bytes[index]; index += 1
            guard shift != 63 || byte <= 1 else { throw VectorTileDecoder.invalid }
            result |= UInt64(byte & 127) << shift
            if byte < 128 { return result }
        }
        throw VectorTileDecoder.invalid
    }
    mutating func field() throws -> (Int, Int) {
        let tag = try uint()
        guard tag >> 3 > 0, tag >> 3 <= UInt64(Int32.max) else { throw VectorTileDecoder.invalid }
        return (Int(tag >> 3), Int(tag & 7))
    }
    mutating func data() throws -> Data {
        let size = try uint()
        guard size <= UInt64(bytes.count - index) else { throw VectorTileDecoder.invalid }
        defer { index += Int(size) }
        return Data(bytes[index..<(index + Int(size))])
    }
    mutating func fixed(_ size: Int) throws -> UInt64 {
        guard size <= bytes.count - index else { throw VectorTileDecoder.invalid }
        var result: UInt64 = 0
        for offset in 0..<size { result |= UInt64(bytes[index + offset]) << (offset * 8) }
        index += size
        return result
    }
    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try uint()
        case 1: _ = try fixed(8)
        case 2: _ = try data()
        case 5: _ = try fixed(4)
        default: throw VectorTileDecoder.invalid
        }
    }
}

enum VectorTileDecoder {
    static var invalid: MapError { .invalid("矢量地图分块损坏或格式不受支持。") }
    static let layers = Set(["road", "path", "water", "waterway", "ocean", "landcover", "building", "elevation"])

    static func decode(_ data: Data, tile: MapTileID) throws -> [MapFeature] {
        guard (0...20).contains(tile.z), tile.x >= 0, tile.y >= 0,
              tile.x < (1 << tile.z), tile.y < (1 << tile.z) else { throw invalid }
        guard data.count <= 4 * 1_024 * 1_024 else { throw MapError.invalid("单个地图分块超过 4 MB。") }
        let data = try decompress(data)
        var proto = TileProto(data), features: [MapFeature] = [], pointCount = 0
        while !proto.done {
            let (field, wire) = try proto.field()
            if field == 3, wire == 2 {
                let layer = try proto.data()
                features += try decodeLayer(layer, tile: tile, counter: &pointCount, sequence: features.count)
            } else { try proto.skip(wire) }
        }
        return features
    }

    private static func decompress(_ data: Data) throws -> Data {
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var output = Data(), status = Z_OK
            repeat {
                var chunk = [UInt8](repeating: 0, count: 32 * 1_024)
                status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw invalid }
                output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                guard output.count <= 4 * 1_024 * 1_024 else { throw MapError.invalid("地图分块解压后超过 4 MB。") }
            } while status != Z_STREAM_END
            return output
        }
    }

    private static func value(_ data: Data) throws -> String {
        var proto = TileProto(data), result = ""
        while !proto.done {
            let (field, wire) = try proto.field()
            switch (field, wire) {
            case (1, 2): result = String(data: try proto.data(), encoding: .utf8) ?? ""
            case (2, 5): result = String(Float(bitPattern: UInt32(try proto.fixed(4))))
            case (3, 1): result = String(Double(bitPattern: try proto.fixed(8)))
            case (4, 0), (5, 0): result = String(try proto.uint())
            case (6, 0): let n = try proto.uint(); result = String(Int64(bitPattern: n >> 1) ^ -Int64(n & 1))
            case (7, 0): result = try proto.uint() == 0 ? "false" : "true"
            default: try proto.skip(wire)
            }
        }
        return result
    }

    private static func packed(_ data: Data) throws -> [UInt64] {
        var proto = TileProto(data), values: [UInt64] = []
        while !proto.done {
            guard values.count < 300_000 else { throw invalid }
            values.append(try proto.uint())
        }
        return values
    }

    private static func decodeLayer(_ data: Data, tile: MapTileID, counter: inout Int, sequence: Int) throws -> [MapFeature] {
        var proto = TileProto(data), name = "", keys: [String] = [], values: [String] = []
        var rawFeatures: [Data] = [], extent = 4096, version = 1
        while !proto.done {
            let (field, wire) = try proto.field()
            switch (field, wire) {
            case (1, 2): name = String(data: try proto.data(), encoding: .utf8) ?? ""
            case (2, 2):
                guard rawFeatures.count < 20_000 else { throw invalid }
                rawFeatures.append(try proto.data())
            case (3, 2): keys.append(String(data: try proto.data(), encoding: .utf8) ?? "")
            case (4, 2): values.append(try value(proto.data()))
            case (5, 0): let n = try proto.uint(); guard (1...65_536).contains(n) else { throw invalid }; extent = Int(n)
            case (15, 0): let n = try proto.uint(); guard n <= 2 else { throw invalid }; version = Int(n)
            default: try proto.skip(wire)
            }
        }
        guard (1...2).contains(version) else { throw invalid }
        guard layers.contains(name) else { return [] }
        var output: [MapFeature] = []
        for data in rawFeatures {
            var feature = TileProto(data), tags: [UInt64] = [], geometry: [UInt64] = [], type: UInt64 = 0
            while !feature.done {
                let (field, wire) = try feature.field()
                switch (field, wire) {
                case (2, 2): tags += try packed(feature.data())
                case (3, 0): type = try feature.uint()
                case (4, 2): geometry += try packed(feature.data())
                default: try feature.skip(wire)
                }
            }
            guard tags.count % 2 == 0 else { throw invalid }
            var attributes: [String: String] = [:]
            for index in stride(from: 0, to: tags.count, by: 2) {
                guard tags[index] < keys.count, tags[index + 1] < values.count else { throw invalid }
                attributes[keys[Int(tags[index])]] = values[Int(tags[index + 1])]
            }
            guard type == 2 || type == 3 else { continue }
            if name == "elevation" {
                guard let height = Double(attributes["height"] ?? ""), height.isFinite,
                      abs(height.truncatingRemainder(dividingBy: tile.z >= 14 ? 20 : 50)) < 0.1 else { continue }
            }
            let paths = try decodeGeometry(geometry, polygon: type == 3, counter: &counter)
            let kind: String
            switch name {
            case "road", "path": kind = attributes["highway"] ?? name
            case "ocean": kind = "water"
            case "elevation": kind = "contour"
            default: kind = name
            }
            let label = name == "elevation" ? attributes["height"].map { "\($0)m" } : attributes["name"]
            let featureStart = output.count
            for path in paths {
                let points = path.map { tile.coordinate(x: $0.0, y: $0.1, extent: extent) }
                guard points.count >= 2, points.allSatisfy(\.isValid) else { throw invalid }
                let area = zip(path, path.dropFirst()).reduce(0.0) { $0 + Double($1.0.0) * Double($1.1.1) - Double($1.1.0) * Double($1.0.1) }
                if type == 3, area < 0 {
                    guard output.count > featureStart else { throw invalid }
                    output[output.count - 1].holes = (output[output.count - 1].holes ?? []) + [points]
                } else {
                    let id = Int64(tile.y * (1 << tile.z) + tile.x) * 100_000 + Int64(sequence + output.count)
                    output.append(MapFeature(id: id, kind: kind, name: label, points: points))
                }
            }
        }
        return output
    }

    private static func decodeGeometry(_ values: [UInt64], polygon: Bool, counter: inout Int) throws -> [[(Int, Int)]] {
        var cursor = 0, x = 0, y = 0, paths: [[(Int, Int)]] = [], current: [(Int, Int)] = []
        while cursor < values.count {
            let command = values[cursor]; cursor += 1
            let op = command & 7, count = command >> 3
            guard count > 0, count <= 50_000 else { throw invalid }
            if op == 7 {
                guard polygon, count == 1, current.count >= 3 else { throw invalid }
                current.append(current[0]); paths.append(current); current = []
            } else if op == 1 || op == 2 {
                guard count <= (values.count - cursor) / 2, op == 1 || !current.isEmpty else { throw invalid }
                for _ in 0..<Int(count) {
                    if op == 1, !current.isEmpty { paths.append(current); current = [] }
                    let dx = values[cursor], dy = values[cursor + 1]; cursor += 2
                    guard dx <= UInt32.max, dy <= UInt32.max else { throw invalid }
                    x += Int(dx >> 1) ^ -Int(dx & 1); y += Int(dy >> 1) ^ -Int(dy & 1)
                    guard abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { throw invalid }
                    counter += 1; guard counter <= 50_000 else { throw invalid }
                    current.append((x, y))
                }
            } else { throw invalid }
        }
        if !current.isEmpty { guard !polygon else { throw invalid }; paths.append(current) }
        return paths
    }
}
