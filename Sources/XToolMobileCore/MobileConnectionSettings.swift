import Foundation

public enum MobileConnectionSettings {
    /// Accept a pasted HTTPS proxy address, but never downgrade transport security.
    public static func codexEndpoint(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MobileProjectBuildError.invalid("Enter your Codex server address first. A ChatGPT website address is not a Codex server.") }
        guard var parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw MobileProjectBuildError.invalid("Use the server address without passwords, query parameters or fragments.")
        }
        if parts.scheme?.lowercased() == "https" { parts.scheme = "wss" }
        let scheme = parts.scheme?.lowercased()
        guard scheme == "wss" || (scheme == "ws" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())) else {
            throw MobileProjectBuildError.invalid("Use wss:// with a trusted TLS certificate. Plain ws:// only works on this device's localhost.")
        }
        guard !["chatgpt.com", "chat.openai.com", "api.openai.com", "auth.openai.com", "github.com"].contains(host.lowercased()) else {
            throw MobileProjectBuildError.invalid("That is a service website. Enter the address of your separately running Codex app-server.")
        }
        parts.scheme = scheme
        guard let url = parts.url else { throw MobileProjectBuildError.invalid("The server address is invalid.") }
        return url
    }

    public static func githubFailure(status: Int, rateLimited: Bool = false) -> String {
        if status == 429 || (status == 403 && rateLimited) {
            return "GitHub’s request limit was reached. Wait for it to reset, then retry; signing in increases the public request allowance."
        }
        switch status {
        case 401: return "GitHub rejected the token. Generate a new personal access token and connect again. Do not enter your GitHub password."
        case 403: return "GitHub denied access. Check token permissions, expiry and organization approval or SSO requirements."
        case 404: return "Repository or branch not found, or your token cannot read it. Check the name and grant Contents: Read access to that repository."
        default: return "GitHub returned HTTP \(status). Retry when the service is available."
        }
    }
}
