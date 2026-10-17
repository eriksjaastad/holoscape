import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let queryParams: [String: String]
    let body: Data?

    /// Extract a path component after a prefix, e.g. "/channels/abc" with prefix "/channels/" returns "abc".
    /// Returns nil (not an arbitrary non-empty later segment) when the component is literally empty,
    /// so routes like /channels///input surface as "missing channel ID" instead of matching "input".
    func pathComponent(after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = String(path.dropFirst(prefix.count))
        // Take exactly up to the next slash (or end of string). Preserve empty
        // segments so /channels//input yields "" → caller treats as missing.
        if let slash = remainder.firstIndex(of: "/") {
            let component = String(remainder[..<slash])
            return component.isEmpty ? nil : component
        }
        return remainder.isEmpty ? nil : remainder
    }
}

struct HTTPResponse {
    let status: Int
    let statusText: String
    let body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else {
            let errorBody = Data(#"{"error":"Failed to encode JSON response"}"#.utf8)
            return HTTPResponse(
                status: 500,
                statusText: statusText(for: 500),
                body: errorBody
            )
        }
        return HTTPResponse(status: status, statusText: statusText(for: status), body: data)
    }

    static func jsonData(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, statusText: statusText(for: status), body: data)
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        json(["error": message], status: status)
    }

    func serialize() -> Data {
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        guard let headerData = header.data(using: .utf8) else { return Data() }
        return headerData + body
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 404: return "Not Found"
        case 400: return "Bad Request"
        case 413: return "Payload Too Large"
        case 503: return "Service Unavailable"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

/// Result of parsing one bounded request from the local control API.
/// Malformed syntax is a 400-class outcome; a request that cannot fit within
/// the byte budget is a 413-class outcome; incomplete input may be read again.
enum HTTPParseOutcome {
    case incomplete
    case request(HTTPRequest)
    case badRequest
    case payloadTooLarge
}

enum HTTPParser {
    /// Parse one origin-form HTTP/1.0 or HTTP/1.1 request from raw bytes.
    /// Transfer codings are unsupported. Content-Length must be decimal and
    /// fit with the headers inside `maximumRequestBytes`.
    static func parse(_ data: Data, maximumRequestBytes: Int) -> HTTPParseOutcome {
        guard maximumRequestBytes >= 0, data.count <= maximumRequestBytes else {
            return .payloadTooLarge
        }

        // Locate the end-of-headers marker in raw bytes. If not present yet,
        // the request is incomplete and the caller must keep reading.
        let crlfcrlf = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let hdrRange = data.range(of: crlfcrlf) else { return .incomplete }

        // Slice out headers (before \r\n\r\n) and body (after).
        let headerData = data.subdata(in: data.startIndex..<hdrRange.lowerBound)
        let bodyStart = hdrRange.upperBound
        let availableBodyBytes = data.count - bodyStart

        // Foundation strips a leading UTF-8 BOM during decoding. Validate the
        // first raw method byte so a BOM cannot disappear before grammar checks.
        guard let firstHeaderByte = headerData.first, isTokenByte(firstHeaderByte) else {
            return .badRequest
        }

        // Decode headers as UTF-8. This local control API accepts textual headers.
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .badRequest }
        let headerLines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return .badRequest }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              isToken(parts[0]),
              isValidRequestTarget(parts[1]),
              parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1" else {
            return .badRequest
        }
        let method = String(parts[0])
        let fullPath = String(parts[1])

        // Parse header fields (case-insensitive keys per RFC).
        var parsedContentLength: Int?
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                return .badRequest
            }
            let rawName = line[..<colon]
            guard isToken(rawName) else { return .badRequest }

            let name = rawName.lowercased()
            let rawValue = line[line.index(after: colon)...]
            guard isValidFieldValue(rawValue) else { return .badRequest }
            let value = trimmingHTTPWhitespace(rawValue)
            // This server does not implement transfer codings. Ignoring this
            // field would make the request boundary ambiguous when a sender
            // also supplies Content-Length.
            if name == "transfer-encoding" {
                return .badRequest
            }
            if name == "content-length" {
                guard !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }) else {
                    return .badRequest
                }
                guard let contentLength = Int(value) else { return .payloadTooLarge }
                guard bodyStart <= maximumRequestBytes,
                      contentLength <= maximumRequestBytes - bodyStart else {
                    return .payloadTooLarge
                }
                if let parsedContentLength, parsedContentLength != contentLength {
                    return .badRequest
                }
                parsedContentLength = contentLength
            }
        }

        let contentLength = parsedContentLength ?? 0

        // Strictly require full body before considering the request complete.
        // Without this check, the parser used to happily return a request with
        // body=nil while headers said Content-Length>0, causing handlers to
        // reject the request with 400 "Invalid JSON body."
        if availableBodyBytes < contentLength { return .incomplete }

        // Split path and query string.
        let querySeparator = fullPath.firstIndex(of: "?")
        let path = querySeparator.map { String(fullPath[..<$0]) } ?? fullPath
        var queryParams: [String: String] = [:]
        if let querySeparator {
            let queryString = fullPath[fullPath.index(after: querySeparator)...]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    queryParams[key] = value
                }
            }
        }

        // Extract exactly contentLength body bytes from the raw data, preserving
        // the original byte sequence (no line-ending normalization, no UTF-8
        // round-trip). Handlers that need text can decode it themselves.
        let body: Data?
        if contentLength > 0 {
            let bodyEnd = bodyStart + contentLength
            body = data.subdata(in: bodyStart..<bodyEnd)
        } else {
            body = nil
        }

        return .request(HTTPRequest(method: method, path: path, queryParams: queryParams, body: body))
    }

    private static func isToken(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy(isTokenByte)
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122:
            return true
        case 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            return true
        default:
            return false
        }
    }

    private static func isValidRequestTarget(_ value: Substring) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.first == 47 else { return false }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37 {
                guard index + 2 < bytes.count,
                      isHexDigit(bytes[index + 1]),
                      isHexDigit(bytes[index + 2]) else {
                    return false
                }
                index += 3
                continue
            }
            if byte == 63 {
                index += 1
                continue
            }
            guard byte == 47 || isPChar(byte) else {
                return false
            }
            index += 1
        }
        return true
    }

    private static func isValidFieldValue(_ value: Substring) -> Bool {
        value.utf8.allSatisfy { byte in
            byte == 9 || byte >= 32 && byte != 127
        }
    }

    private static func trimmingHTTPWhitespace(_ value: Substring) -> Substring {
        var start = value.startIndex
        var end = value.endIndex
        while start < end, value[start] == " " || value[start] == "\t" {
            start = value.index(after: start)
        }
        while start < end {
            let previous = value.index(before: end)
            guard value[previous] == " " || value[previous] == "\t" else { break }
            end = previous
        }
        return value[start..<end]
    }

    private static func isPChar(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122:
            return true
        case 33, 36, 38, 39, 40, 41, 42, 43, 44, 45, 46, 58, 59, 61, 64, 95, 126:
            return true
        default:
            return false
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
