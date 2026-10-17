import Foundation

enum TerminalEnvironment {
    static func isUTF8Locale(_ locale: String?) -> Bool {
        guard let locale, !locale.isEmpty else { return false }
        let modifierComponents = locale.split(separator: "@", omittingEmptySubsequences: false)
        guard modifierComponents.count <= 2,
              let base = modifierComponents.first,
              !base.isEmpty else { return false }
        if modifierComponents.count == 2, modifierComponents[1].isEmpty { return false }
        let components = base.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
              components.allSatisfy({ !$0.isEmpty }) else { return false }
        let codeset = String(components.last ?? "")
        return codeset.caseInsensitiveCompare("utf8") == .orderedSame
            || codeset.caseInsensitiveCompare("utf-8") == .orderedSame
    }
}

struct AuthEnvironmentBuilder {
    static func buildEnvironment(
        for authType: AgentAuthType,
        workingDirectory: URL
    ) -> [String: String] {
        var env: [String: String] = [
            "PATH": "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "SHELL": "/bin/zsh",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
        ]
        switch authType {
        case .oauth:
            // Explicitly do NOT set ANTHROPIC_API_KEY — bills to subscription
            break
        case .apiKey(let key):
            env["ANTHROPIC_API_KEY"] = key
        case .deferredAPIKey:
            preconditionFailure("Deferred API-key auth must resolve before building a launch environment")
        }
        return env
    }
}
