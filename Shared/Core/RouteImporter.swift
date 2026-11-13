import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum RouteImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Bounded GPX tracks/routes and KML LineStrings. Segment gaps are never connected.
final class RouteImporter: NSObject, XMLParserDelegate {
    static let maximumBytes = 10 * 1_024 * 1_024
    static let maximumPoints = 100_000
    private var path: [String] = []
    private var text = ""
    private var format = ""
    private var name = ""
    private var segments: [[RoutePoint]] = []
    private var currentSegment: [RoutePoint] = []
    private var parsed: [(String, [[RoutePoint]])] = []
    private var count = 0
    private var failure: Error?

    static func read(_ data: Data, sourceName: String) throws -> [PlannedRoute] {
        guard data.count <= maximumBytes else { throw RouteImportError.invalid("文件超过 10 MB，请先拆分线路。") }
        // XMLParser may skip external declaration callbacks when resolution is disabled.
        // Reject DTDs before parsing, including the NUL-padded markup of UTF-16/32.
        let markup = Data(data.filter { $0 != 0 })
        guard markup.range(of: Data("<!DOCTYPE".utf8)) == nil,
              markup.range(of: Data("<!ENTITY".utf8)) == nil else {
            throw RouteImportError.invalid("不支持含 DTD 或 XML 实体声明的线路文件。")
        }
        let delegate = RouteImporter()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let valid = parser.parse()
        if let error = delegate.failure { throw error }
        guard valid else { throw RouteImportError.invalid("XML 文件损坏或格式不正确。") }
        guard !delegate.parsed.isEmpty else { throw RouteImportError.invalid("没有找到可用线路。支持 GPX 轨迹/路线和 KML LineString。") }
        return delegate.parsed.enumerated().map { index, item in
            let fallback = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
            return PlannedRoute(name: item.0.isEmpty ? "\(fallback) · \(index + 1)" : item.0,
                                sourceName: sourceName, segments: item.1)
        }
    }

    private func fail(_ parser: XMLParser, _ message: String) {
        failure = RouteImportError.invalid(message)
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        path.append(element)
        text = ""
        if path.count == 1 {
            guard element == "gpx" || element == "kml" else {
                fail(parser, "不支持此文件类型，请选择 GPX 或 KML。")
                return
            }
            format = element
        }
        guard path.count <= 64 else { fail(parser, "文件嵌套过深。请简化后导入。"); return }
        if isGPXRoute || (format == "kml" && element == "Placemark") {
            name = ""
            segments = []
        }
        if isSegment { currentSegment = [] }
        if isGPXPoint {
            guard let lat = Double(attributes["lat"] ?? ""), let lon = Double(attributes["lon"] ?? "") else {
                fail(parser, "线路包含无效坐标，未导入此文件。")
                return
            }
            append(latitude: lat, longitude: lon, parser: parser)
        }
    }

    private var isGPXRoute: Bool {
        format == "gpx" && path.count == 2 && ["trk", "rte"].contains(path.last ?? "")
    }
    private var isSegment: Bool {
        path == ["gpx", "trk", "trkseg"] || path == ["gpx", "rte"]
            || (format == "kml" && path.last == "LineString" && path.contains("Placemark"))
    }
    private var isGPXPoint: Bool {
        path == ["gpx", "trk", "trkseg", "trkpt"] || path == ["gpx", "rte", "rtept"]
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let value = String(data: CDATABlock, encoding: .utf8) else {
            fail(parser, "无法读取文件中的 CDATA 内容。")
            return
        }
        text += value
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast(); text = "" }
        if element == "name" && ((format == "gpx" && path.count == 3 && ["trk", "rte"].contains(path[1]))
            || (format == "kml" && path.dropLast().last == "Placemark")) {
            name = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        }
        if format == "kml", element == "coordinates", path.dropLast().last == "LineString", path.contains("Placemark") {
            for tuple in text.split(whereSeparator: { $0.isWhitespace }) {
                let values = tuple.split(separator: ",", omittingEmptySubsequences: false)
                guard (2...3).contains(values.count), let lon = Double(values[0]), let lat = Double(values[1]) else {
                    fail(parser, "KML 包含无效坐标，未导入此文件。")
                    return
                }
                append(latitude: lat, longitude: lon, parser: parser)
                if failure != nil { return }
            }
        }
        if isSegment {
            guard currentSegment.count >= 2 else { fail(parser, "线路分段至少需要两个不同的位置点。"); return }
            segments.append(currentSegment)
            currentSegment = []
        }
        if isGPXRoute || (format == "kml" && element == "Placemark") {
            if !segments.isEmpty { parsed.append((name, segments)) }
        }
    }

    private func append(latitude: Double, longitude: Double, parser: XMLParser) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            fail(parser, "坐标超出有效范围，未导入此文件。")
            return
        }
        count += 1
        guard count <= Self.maximumPoints else { fail(parser, "文件超过 100,000 个位置点，请先拆分线路。"); return }
        let point = RoutePoint(latitude: latitude, longitude: longitude)
        if currentSegment.last != point { currentSegment.append(point) }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, "不支持含 XML 实体声明的线路文件。")
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, "不支持含外部实体的线路文件。")
    }
}
