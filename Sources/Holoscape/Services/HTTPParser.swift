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

enum HTTPParseOutcome {
    case incomplete
    case request(HTTPRequest)
    case badRequest
    case payloadTooLarge
}

enum HTTPParser {
    /// Parse a bounded HTTP request from raw bytes.
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

        // Decode headers as UTF-8. HTTP headers are ASCII, so this is safe.
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .badRequest }
        let headerLines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return .badRequest }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return .badRequest }
        let method = String(parts[0])
        let fullPath = String(parts[1])

        // Parse header fields (case-insensitive keys per RFC).
        var parsedContentLength: Int?
        for line in headerLines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
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
        }

        let contentLength = parsedContentLength ?? 0

        // Strictly require full body before considering the request complete.
        // Without this check, the parser used to happily return a request with
        // body=nil while headers said Content-Length>0, causing handlers to
        // reject the request with 400 "Invalid JSON body."
        if availableBodyBytes < contentLength { return .incomplete }

        // Split path and query string.
        let pathComponents = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])
        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            let queryString = String(pathComponents[1])
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
}
