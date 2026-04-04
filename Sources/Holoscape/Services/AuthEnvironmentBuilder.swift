import Foundation

struct AuthEnvironmentBuilder {
    static func buildEnvironment(
        for authType: AgentAuthType,
        workingDirectory: URL
    ) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
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
        }
        return env
    }
}
