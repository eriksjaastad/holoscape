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
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data()
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
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

enum HTTPParser {
    /// Parse an HTTP request from raw bytes.
    /// Returns nil if the request is incomplete (no `\r\n\r\n` separator yet,
    /// or fewer body bytes than `Content-Length` promises). Callers should
    /// treat nil as "need more data" and keep reading from the socket.
    static func parse(_ data: Data) -> HTTPRequest? {
        // Locate the end-of-headers marker in raw bytes. If not present yet,
        // the request is incomplete and the caller must keep reading.
        let crlfcrlf = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let hdrRange = data.range(of: crlfcrlf) else { return nil }

        // Slice out headers (before \r\n\r\n) and body (after).
        let headerData = data.subdata(in: data.startIndex..<hdrRange.lowerBound)
        let bodyStart = hdrRange.upperBound
        let availableBodyBytes = data.count - bodyStart

        // Decode headers as UTF-8. HTTP headers are ASCII, so this is safe.
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let headerLines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let fullPath = String(parts[1])

        // Parse header fields (case-insensitive keys per RFC).
        var contentLength = 0
        for line in headerLines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "content-length", let n = Int(value) {
                    contentLength = n
                }
            }
        }

        // Strictly require full body before considering the request complete.
        // Without this check, the parser used to happily return a request with
        // body=nil while headers said Content-Length>0, causing handlers to
        // reject the request with 400 "Invalid JSON body."
        if availableBodyBytes < contentLength { return nil }

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

        return HTTPRequest(method: method, path: path, queryParams: queryParams, body: body)
    }
}
