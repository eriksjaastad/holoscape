import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let queryParams: [String: String]
    let body: Data?

    /// Extract a path component after a prefix, e.g. "/channels/abc" with prefix "/channels/" returns "abc"
    func pathComponent(after prefix: String) -> String? {
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = String(path.dropFirst(prefix.count))
        // Take up to next slash
        return remainder.split(separator: "/").first.map(String.init)
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
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let fullPath = String(parts[1])

        // Split path and query string
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

        // Extract body (after blank line)
        var body: Data?
        if let blankIndex = lines.firstIndex(of: "") {
            let bodyString = lines[(blankIndex + 1)...].joined(separator: "\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        return HTTPRequest(method: method, path: path, queryParams: queryParams, body: body)
    }
}
