import SwiftUI
import CryptoKit
import Security
import XToolMobileCore

enum IDESecretStore {
    static func read(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "XToolIDE", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "XToolIDE", kSecAttrAccount as String: account]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw MobileProjectBuildError.invalid("Could not store credential in Keychain (\(added))") }
        } else if result != errSecSuccess { throw MobileProjectBuildError.invalid("Could not update Keychain (\(result))") }
    }
}

@MainActor final class IDEGitHubClient: ObservableObject {
    @Published var status = "Not connected"
    @Published var busy = false
    @Published var userCode = ""
    @Published var verificationURL: URL?
    @Published var account = ""
    private var token = IDESecretStore.read("github")
    private var operation: Task<Void, Never>?

    struct Baseline: Codable { let sha: String; let hash: String }
    struct Checkout: Codable {
        let repository: String
        let branch: String
        let commit: String
        let files: [String: Baseline]
    }
    static func checkout(in root: URL) -> Checkout? {
        (try? Data(contentsOf: root.appendingPathComponent(".xtool/github.json")))
            .flatMap { try? JSONDecoder().decode(Checkout.self, from: $0) }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    private func api(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.github.com/" + path)!)
        request.timeoutInterval = 60
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MobileProjectBuildError.invalid("GitHub request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check access and rate limits.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MobileProjectBuildError.invalid("Unexpected GitHub response") }
        return object
    }
    private func oauth(_ path: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://github.com/" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.sorted(by: { $0.key < $1.key }).map { component($0.key) + "=" + component($0.value) }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MobileProjectBuildError.invalid("GitHub sign-in request failed") }
        return object
    }
    func useToken(_ value: String) async throws {
        let previous = token
        token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let user = try await api("user")
            try IDESecretStore.save(token, account: "github")
            account = user["login"] as? String ?? "GitHub"
            status = "Connected as \(account)"
        } catch { token = previous; throw error }
    }
    func login(clientID: String) {
        guard !busy else { return }
        guard !clientID.isEmpty else { status = "Enter an OAuth app client ID with Device Flow enabled, or use a personal access token."; return }
        busy = true
        operation = Task {
            defer { busy = false; userCode = ""; verificationURL = nil }
            do {
                let start = try await oauth("login/device/code", fields: ["client_id": clientID, "scope": "repo"])
                guard let device = start["device_code"] as? String, let code = start["user_code"] as? String,
                      let uri = start["verification_uri"] as? String, let url = URL(string: uri), url.scheme == "https", url.host == "github.com" else {
                    throw MobileProjectBuildError.invalid("Device Flow is unavailable for this OAuth app")
                }
                userCode = code; verificationURL = url; status = "Enter the code on GitHub, then return here."
                var interval = max(5, start["interval"] as? Int ?? 5)
                let expires = Date().addingTimeInterval(Double(start["expires_in"] as? Int ?? 900))
                while Date() < expires {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                    let result = try await oauth("login/oauth/access_token", fields: ["client_id": clientID, "device_code": device, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
                    if let token = result["access_token"] as? String { try await useToken(token); return }
                    switch result["error"] as? String {
                    case "authorization_pending": continue
                    case "slow_down": interval += 5
                    default: throw MobileProjectBuildError.invalid("GitHub sign-in ended: \(result["error"] as? String ?? "unknown response")")
                    }
                }
                status = "Sign-in code expired. Start again."
            } catch is CancellationError { status = "Cancelled" }
            catch { status = String(describing: error) }
        }
    }
    func cancel() { operation?.cancel() }
    func logout() {
        cancel()
        do { try IDESecretStore.save("", account: "github"); token = ""; account = ""; status = "Signed out" }
        catch { status = String(describing: error) }
    }

    /// GitHub tree snapshots, pinned to a commit. Pull preserves local changes
    /// and refuses conflicts; it does not pretend to create a local Git database.
    func synchronize(repository input: String, branch requestedBranch: String, root: URL) async throws {
        var repository = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if repository.hasPrefix("https://github.com/") { repository = String(repository.dropFirst(19)) }
        if repository.hasSuffix(".git") { repository.removeLast(4) }
        let parts = repository.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else {
            throw MobileProjectBuildError.invalid("Use owner/repository or its GitHub URL")
        }
        let prefix = "repos/\(component(String(parts[0])))/\(component(String(parts[1])))"
        let repo = try await api(prefix)
        let branch = requestedBranch.isEmpty ? (repo["default_branch"] as? String ?? "main") : requestedBranch
        let commit = try await api(prefix + "/commits/" + component(branch))
        guard let sha = commit["sha"] as? String, let details = commit["commit"] as? [String: Any],
              let tree = details["tree"] as? [String: Any], let treeSHA = tree["sha"] as? String else { throw MobileProjectBuildError.invalid("Could not resolve branch") }
        let response = try await api(prefix + "/git/trees/" + component(treeSHA) + "?recursive=1")
        guard response["truncated"] as? Bool != true, let treeEntries = response["tree"] as? [[String: Any]] else { throw MobileProjectBuildError.invalid("Repository tree is too large for snapshot import") }
        let entries = treeEntries.filter { $0["type"] as? String != "tree" }
        guard entries.count <= 2000, entries.allSatisfy({ ["100644", "100755"].contains($0["mode"] as? String ?? "") }),
              entries.reduce(0, { $0 + ($1["size"] as? Int ?? 0) }) <= 200_000_000 else {
            throw MobileProjectBuildError.invalid("Snapshot import supports up to 2,000 regular files / 200 MB. Submodules and symlinks require a prepared project.")
        }
        let previous = Self.checkout(in: root)
        if let previous, previous.repository != repository || previous.branch != branch { throw MobileProjectBuildError.invalid("Import another branch into a new folder") }
        let baseline = previous?.files ?? [:]
        var remote: [String: (String, String)] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String, let blob = entry["sha"] as? String, let mode = entry["mode"] as? String else { throw MobileProjectBuildError.invalid("Malformed repository entry") }
            _ = try MobileWorkspaceTools.destination(path, in: root)
            guard !remote.keys.contains(where: { $0.lowercased() == path.lowercased() }) else { throw MobileProjectBuildError.invalid("Repository has colliding paths: \(path)") }
            remote[path] = (blob, mode)
        }
        let changed = Set(remote.keys).union(baseline.keys).filter { remote[$0]?.0 != baseline[$0]?.sha }.sorted()
        let fm = FileManager.default
        func currentHash(_ path: String) throws -> String? {
            let url = try MobileWorkspaceTools.destination(path, in: root)
            return fm.fileExists(atPath: url.path) ? Self.hash(try Data(contentsOf: url)) : nil
        }
        for path in changed {
            guard try currentHash(path) == baseline[path]?.hash else { throw MobileProjectBuildError.invalid("Pull conflict: \(path). Local changes were preserved. Resolve it or import a fresh snapshot.") }
        }
        let stage = root.appendingPathComponent(".xtool/Incoming/\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var next = baseline
        for (index, path) in changed.enumerated() {
            try Task.checkCancellation()
            status = "Downloading \(index + 1)/\(changed.count): \(path)"
            guard let entry = remote[path] else { next.removeValue(forKey: path); continue }
            let blob = try await api(prefix + "/git/blobs/" + component(entry.0))
            guard blob["encoding"] as? String == "base64", let content = blob["content"] as? String,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters), data.count <= 20_000_000 else { throw MobileProjectBuildError.invalid("Unsupported or oversized blob: \(path)") }
            let staged = try MobileWorkspaceTools.destination(path, in: stage)
            try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: staged)
            next[path] = Baseline(sha: entry.0, hash: Self.hash(data))
        }
        for path in changed {
            guard try currentHash(path) == baseline[path]?.hash else { throw MobileProjectBuildError.invalid("File changed while downloading: \(path)") }
        }
        let backup = root.appendingPathComponent(".xtool/PullBackups/\(UUID().uuidString)")
        var applied: [String] = []
        do {
            for path in changed {
                let target = try MobileWorkspaceTools.destination(path, in: root)
                if fm.fileExists(atPath: target.path) {
                    let saved = backup.appendingPathComponent(path)
                    try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: target, to: saved)
                }
                applied.append(path)
                if let entry = remote[path] {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(contentsOf: stage.appendingPathComponent(path)).write(to: target, options: .atomic)
                    try fm.setAttributes([.posixPermissions: entry.1 == "100755" ? 0o755 : 0o644], ofItemAtPath: target.path)
                } else { try fm.removeItem(at: target) }
            }
            let metadata = Checkout(repository: repository, branch: branch, commit: sha, files: next)
            try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent(".xtool/github.json"), options: .atomic)
        } catch {
            for path in applied.reversed() {
                let target = root.appendingPathComponent(path), saved = backup.appendingPathComponent(path)
                if fm.fileExists(atPath: saved.path) { try? Data(contentsOf: saved).write(to: target, options: .atomic) }
                else { try? fm.removeItem(at: target) }
            }
            throw error
        }
        status = "Updated \(changed.count) files at \(sha.prefix(8)). Local-only changes preserved."
    }

    func perform(repository: String, branch: String, root: URL, completion: @escaping (URL) -> Void) {
        guard !busy else { return }
        busy = true
        operation = Task {
            defer { busy = false }
            do { try await synchronize(repository: repository, branch: branch, root: root); completion(root) }
            catch is CancellationError { status = "Cancelled; existing project files were preserved." }
            catch { status = String(describing: error) }
        }
    }
}

struct IDEGitHubView: View {
    let projectRoot: URL?
    let prepareMutation: () throws -> Void
    let onOpen: (URL) -> Void
    @StateObject private var client = IDEGitHubClient()
    @AppStorage("githubOAuthClientID") private var clientID = ""
    @State private var repository = ""
    @State private var branch = ""
    @State private var personalToken = ""
    @State private var error = ""
    var body: some View {
        Form {
            Section("GitHub account") {
                TextField("OAuth app client ID", text: $clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Sign in to GitHub") { client.login(clientID: clientID) }.disabled(client.busy)
                if !client.userCode.isEmpty {
                    Text(client.userCode).font(.title.monospaced()).textSelection(.enabled)
                    if let url = client.verificationURL { Link("Open GitHub to enter code", destination: url) }
                }
                DisclosureGroup("Use a personal access token") {
                    SecureField("Token with repository Contents read access", text: $personalToken)
                    Button("Connect token") { Task { do { try await client.useToken(personalToken); personalToken = "" } catch { self.error = String(describing: error) } } }.disabled(client.busy)
                }
                Button("Sign out", role: .destructive) { client.logout() }.disabled(client.busy)
                Text("Public repositories can be imported without signing in. OAuth Device Flow must be enabled on your GitHub OAuth app.").font(.caption)
            }
            Section("Repository") {
                TextField("owner/repository", text: $repository).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Branch (blank uses default)", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Import repository") {
                    do {
                        try prepareMutation()
                        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Projects/GitHub-\(UUID().uuidString.prefix(8))")
                        client.perform(repository: repository, branch: branch, root: root, completion: onOpen)
                    } catch { self.error = String(describing: error) }
                }.disabled(client.busy || repository.isEmpty)
                if let root = projectRoot, let checkout = IDEGitHubClient.checkout(in: root) {
                    Text("\(checkout.repository) · \(checkout.branch) · \(checkout.commit.prefix(8))").font(.caption)
                    Button("Pull updates into current project") {
                        do { try prepareMutation(); client.perform(repository: checkout.repository, branch: checkout.branch, root: root, completion: onOpen) }
                        catch { self.error = String(describing: error) }
                    }.disabled(client.busy)
                }
                Text("Imports a source snapshot. Pull stops on conflicting local edits. SwiftPM dependencies still need host preparation for on-device builds.").font(.caption)
            }
            Section {
                if client.busy { ProgressView(); Button("Cancel") { client.cancel() } }
                Text(client.status).textSelection(.enabled)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle("GitHub")
    }
}
