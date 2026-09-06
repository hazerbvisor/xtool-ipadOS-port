import Foundation
import SwiftUI
import CryptoKit
import Security
import XToolMobileCore

enum IDESecretStore {
    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "XToolIDE",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "XToolIDE",
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw MobileProjectBuildError.invalid("Could not store credential in Keychain (\(added))")
            }
        } else if result != errSecSuccess {
            throw MobileProjectBuildError.invalid("Could not update Keychain (\(result))")
        }
    }
}

@MainActor
final class IDEGitHubClient: ObservableObject {
    @Published var status = "Public repositories are ready to import."
    @Published var lastError = ""
    @Published var credentialWarning = ""
    @Published var busy = false
    @Published var userCode = ""
    @Published var verificationURL: URL?
    @Published var account = ""

    private var restored = false
    private var token = IDESecretStore.read("github")
    private var operation: Task<Void, Never>?

    struct Baseline: Codable, Hashable {
        let sha: String
        let hash: String
    }

    struct Checkout: Codable, Hashable {
        let repository: String
        let branch: String
        let commit: String
        let files: [String: Baseline]
    }

    static func checkout(in root: URL) -> Checkout? {
        (try? Data(contentsOf: root.appendingPathComponent(".xtool/github.json")))
            .flatMap { try? JSONDecoder().decode(Checkout.self, from: $0) }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private func api(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.github.com/" + path)!)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            throw MobileProjectBuildError.invalid(
                MobileConnectionSettings.githubFailure(
                    status: http?.statusCode ?? 0,
                    rateLimited: http?.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                )
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileProjectBuildError.invalid("Unexpected GitHub response")
        }
        return object
    }

    private func oauth(_ path: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://github.com/" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            fields.sorted(by: { $0.key < $1.key })
                .map { component($0.key) + "=" + component($0.value) }
                .joined(separator: "&").utf8
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileProjectBuildError.invalid("GitHub sign-in request failed")
        }
        return object
    }

    func useToken(_ value: String) async throws {
        let previous = token
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw MobileProjectBuildError.invalid("Paste a personal access token from GitHub. Your password will not work here.")
        }
        token = value
        do {
            let user = try await api("user")
            try Task.checkCancellation()
            do {
                try IDESecretStore.save(token, account: "github")
                credentialWarning = ""
            } catch {
                credentialWarning = "Connected for this session, but Keychain could not save the token. Re-enter it after restarting XTool."
            }
            account = user["login"] as? String ?? "GitHub"
            status = "Connected as \(account)"
        } catch {
            token = previous
            throw error
        }
    }

    func restoreAccount() async {
        guard !restored, !busy else { return }
        restored = true
        guard !token.isEmpty else { return }
        await connectToken(token)
    }

    func connectToken(_ value: String) async {
        guard !busy else { return }
        busy = true
        lastError = ""
        status = "Checking GitHub account…"
        defer { busy = false }
        do {
            try await useToken(value)
        } catch {
            lastError = String(describing: error)
            status = "Account connection failed"
        }
    }

    func login(clientID input: String) {
        let clientID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy else { return }
        guard !clientID.isEmpty else {
            status = "Enter an OAuth app client ID with Device Flow enabled, or use a personal access token."
            return
        }
        busy = true
        lastError = ""
        operation = Task {
            defer {
                busy = false
                userCode = ""
                verificationURL = nil
            }
            do {
                let start = try await oauth("login/device/code", fields: ["client_id": clientID, "scope": "repo"])
                guard let device = start["device_code"] as? String,
                      let code = start["user_code"] as? String,
                      let uri = start["verification_uri"] as? String,
                      let url = URL(string: uri),
                      url.scheme == "https", url.host == "github.com" else {
                    throw MobileProjectBuildError.invalid(
                        "GitHub could not start device sign-in (\(start["error"] as? String ?? "invalid response")). Check your OAuth client ID and enable Device Flow, or use a personal access token."
                    )
                }
                userCode = code
                verificationURL = url
                status = "Enter the code on GitHub, then return here."
                var interval = max(5, start["interval"] as? Int ?? 5)
                let expires = Date().addingTimeInterval(Double(start["expires_in"] as? Int ?? 900))
                while Date() < expires {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                    let result = try await oauth(
                        "login/oauth/access_token",
                        fields: [
                            "client_id": clientID,
                            "device_code": device,
                            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        ]
                    )
                    if let accessToken = result["access_token"] as? String {
                        try await useToken(accessToken)
                        return
                    }
                    switch result["error"] as? String {
                    case "authorization_pending":
                        continue
                    case "slow_down":
                        interval += 5
                    default:
                        throw MobileProjectBuildError.invalid(
                            "GitHub sign-in ended: \(result["error"] as? String ?? "unknown response")"
                        )
                    }
                }
                status = "Sign-in code expired. Start again."
            } catch is CancellationError {
                status = "Cancelled"
            } catch {
                lastError = String(describing: error)
                status = "GitHub action failed"
            }
        }
    }

    func cancel() {
        operation?.cancel()
    }

    func usePublicAccess() {
        guard !busy else { return }
        token = ""
        account = ""
        lastError = ""
        status = "Public access for this session. Saved token remains in Keychain."
    }

    func logout() {
        guard !busy else { return }
        cancel()
        lastError = ""
        restored = true
        do {
            try IDESecretStore.save("", account: "github")
            token = ""
            account = ""
            status = "Signed out"
        } catch {
            lastError = String(describing: error)
            status = "GitHub action failed"
        }
    }

    /// Snapshot-based GitHub sync. Pulls keep local-only files and reject
    /// conflicts when a remotely changed path has also changed locally.
    func synchronize(repository input: String, branch requestedBranch: String, root: URL) async throws {
        var repository = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if repository.hasPrefix("https://github.com/") {
            repository = String(repository.dropFirst("https://github.com/".count))
        }
        while repository.hasSuffix("/") { repository.removeLast() }
        if repository.hasSuffix(".git") { repository.removeLast(4) }

        let parts = repository.split(separator: "/")
        guard parts.count == 2,
              parts.allSatisfy({ part in
                  part.allSatisfy { ch in
                      ch.isASCII && (ch.isLetter || ch.isNumber || "-_.".contains(ch))
                  }
              }) else {
            throw MobileProjectBuildError.invalid("Use owner/repository or its GitHub URL")
        }

        let prefix = "repos/\(component(String(parts[0])))/\(component(String(parts[1])))"
        let repo = try await api(prefix)
        let requestedBranch = requestedBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = requestedBranch.isEmpty ? (repo["default_branch"] as? String ?? "main") : requestedBranch
        let commitObject = try await api(prefix + "/commits/" + component(branch))
        guard let commitSHA = commitObject["sha"] as? String,
              let details = commitObject["commit"] as? [String: Any],
              let tree = details["tree"] as? [String: Any],
              let treeSHA = tree["sha"] as? String else {
            throw MobileProjectBuildError.invalid("Could not resolve branch")
        }

        let response = try await api(prefix + "/git/trees/" + component(treeSHA) + "?recursive=1")
        guard response["truncated"] as? Bool != true,
              let treeEntries = response["tree"] as? [[String: Any]] else {
            throw MobileProjectBuildError.invalid("Repository tree is too large for snapshot import")
        }
        let entries = treeEntries.filter { $0["type"] as? String != "tree" }
        let totalBytes = entries.reduce(0) { $0 + ($1["size"] as? Int ?? 0) }
        guard entries.count <= 2000,
              totalBytes <= 200_000_000,
              entries.allSatisfy({ ["100644", "100755"].contains($0["mode"] as? String ?? "") }) else {
            throw MobileProjectBuildError.invalid(
                "Snapshot import supports up to 2,000 regular files / 200 MB. Submodules and symlinks require a prepared project."
            )
        }

        let previous = Self.checkout(in: root)
        if let previous,
           previous.repository != repository || previous.branch != branch {
            throw MobileProjectBuildError.invalid("Import another branch into a new folder")
        }
        let baseline = previous?.files ?? [:]

        var remote: [String: (sha: String, mode: String)] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String,
                  let blob = entry["sha"] as? String,
                  let mode = entry["mode"] as? String else {
                throw MobileProjectBuildError.invalid("Malformed repository entry")
            }
            _ = try MobileWorkspaceTools.destination(path, in: root)
            guard !remote.keys.contains(where: { $0.lowercased() == path.lowercased() }) else {
                throw MobileProjectBuildError.invalid("Repository has colliding paths: \(path)")
            }
            remote[path] = (blob, mode)
        }

        let changed = Set(remote.keys)
            .union(baseline.keys)
            .filter { remote[$0]?.sha != baseline[$0]?.sha }
            .sorted()
        let fm = FileManager.default

        func currentHash(_ path: String) throws -> String? {
            let url = try MobileWorkspaceTools.destination(path, in: root)
            return fm.fileExists(atPath: url.path) ? Self.hash(try Data(contentsOf: url)) : nil
        }

        for path in changed {
            guard try currentHash(path) == baseline[path]?.hash else {
                throw MobileProjectBuildError.invalid(
                    "Pull conflict: \(path). Local changes were preserved. Resolve it or import a fresh snapshot."
                )
            }
        }

        let stage = root.appendingPathComponent(".xtool/Incoming/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        var next = baseline
        for (index, path) in changed.enumerated() {
            try Task.checkCancellation()
            status = "Downloading \(index + 1)/\(changed.count): \(path)"
            guard let entry = remote[path] else {
                next.removeValue(forKey: path)
                continue
            }
            let blob = try await api(prefix + "/git/blobs/" + component(entry.sha))
            guard blob["encoding"] as? String == "base64",
                  let content = blob["content"] as? String,
                  let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
                  data.count <= 20_000_000 else {
                throw MobileProjectBuildError.invalid("Unsupported or oversized blob: \(path)")
            }
            let staged = try MobileWorkspaceTools.destination(path, in: stage)
            try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: staged)
            next[path] = Baseline(sha: entry.sha, hash: Self.hash(data))
        }

        for path in changed {
            guard try currentHash(path) == baseline[path]?.hash else {
                throw MobileProjectBuildError.invalid("File changed while downloading: \(path)")
            }
        }

        let backup = root.appendingPathComponent(".xtool/PullBackups/\(UUID().uuidString)", isDirectory: true)
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
                    try fm.setAttributes(
                        [.posixPermissions: entry.mode == "100755" ? 0o755 : 0o644],
                        ofItemAtPath: target.path
                    )
                } else {
                    try fm.removeItem(at: target)
                }
            }
            let metadata = Checkout(repository: repository, branch: branch, commit: commitSHA, files: next)
            let metadataURL = root.appendingPathComponent(".xtool/github.json")
            try fm.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        } catch {
            for path in applied.reversed() {
                let target = root.appendingPathComponent(path)
                let saved = backup.appendingPathComponent(path)
                if fm.fileExists(atPath: saved.path) {
                    try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? Data(contentsOf: saved).write(to: target, options: .atomic)
                } else {
                    try? fm.removeItem(at: target)
                }
            }
            throw error
        }

        status = "Updated \(changed.count) files at \(commitSHA.prefix(8)). Local-only changes preserved."
    }

    func perform(repository: String, branch: String, root: URL, completion: @escaping (URL) -> Void) {
        guard !busy else { return }
        busy = true
        lastError = ""
        operation = Task {
            defer { busy = false }
            do {
                try await synchronize(repository: repository, branch: branch, root: root)
                completion(root)
            } catch is CancellationError {
                status = "Cancelled; existing project files were preserved."
            } catch {
                lastError = String(describing: error)
                status = "GitHub action failed"
            }
        }
    }
}

struct IDEGitHubView: View {
    let projectRoot: URL?
    let prepareMutation: () throws -> Void
    let onOpen: (URL) -> Void
    @ObservedObject var client: IDEGitHubClient

    @AppStorage("githubOAuthClientID") private var clientID = ""
    @State private var tab = "Repositories"
    @State private var repository = ""
    @State private var branch = ""
    @State private var personalToken = ""
    @State private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            IDEConnectionBanner(
                title: tab == "Projects" ? "Projects" : "GitHub",
                subtitle: bannerSubtitle,
                symbol: tab == "Projects" ? "square.grid.2x2" : "point.3.connected.trianglepath.dotted",
                connected: tab == "Projects" || !client.account.isEmpty
            )

            Picker("Workspace", selection: $tab) {
                Text("Repositories").tag("Repositories")
                Text("Projects").tag("Projects")
                Text("Account").tag("Account")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 12)

            Form {
                switch tab {
                case "Projects":
                    IDEProjectManagerView(currentRoot: projectRoot, onOpen: onOpen)
                case "Account":
                    accountSection
                default:
                    repositorySection
                }

                if tab != "Projects" {
                    Section("Activity") {
                        if client.busy {
                            ProgressView(client.status)
                            Button("Cancel") { client.cancel() }
                        } else {
                            Text(client.status)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !client.credentialWarning.isEmpty {
                            Text(client.credentialWarning)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !client.lastError.isEmpty {
                            Label(client.lastError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        if !error.isEmpty {
                            Text(error)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(tab == "Projects" ? "Project Manager" : "GitHub")
        .task { await client.restoreAccount() }
    }

    private var bannerSubtitle: String {
        if tab == "Projects" {
            return projectRoot.map { "Current: \($0.lastPathComponent)" } ?? "Manage projects saved on this iPad"
        }
        return client.account.isEmpty
            ? "Import public projects without signing in"
            : "Signed in as @" + client.account
    }

    @ViewBuilder
    private var repositorySection: some View {
        Section {
            Label("Bring a project to your iPad", systemImage: "arrow.down.doc")
                .font(.headline)
            TextField("Repository URL or owner/repository", text: $repository)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Branch · leave blank for default", text: $branch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                importRepository()
            } label: {
                Label("Import repository", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(client.busy || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                tab = "Projects"
            } label: {
                Label("Open Project Manager", systemImage: "square.grid.2x2")
            }

            if client.account.isEmpty {
                Button("Connect an account for private repositories") { tab = "Account" }
            }
        } footer: {
            Text("Source files are downloaded to Projects. Buildable projects need xtool-mobile.json; dependencies may need host preparation.")
        }

        if let root = projectRoot, let checkout = IDEGitHubClient.checkout(in: root) {
            Section("Current checkout") {
                Label(checkout.repository, systemImage: "folder")
                    .font(.headline)
                Text("\(checkout.branch) · \(checkout.commit.prefix(8))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button("Pull latest changes") {
                    do {
                        error = ""
                        try prepareMutation()
                        client.perform(
                            repository: checkout.repository,
                            branch: checkout.branch,
                            root: root,
                            completion: onOpen
                        )
                    } catch {
                        self.error = String(describing: error)
                    }
                }
                .disabled(client.busy)
                Text("Conflicting local edits stop the pull so you can resolve them.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if !client.account.isEmpty {
            Section("Connected account") {
                Label("@" + client.account, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Sign out", role: .destructive) { client.logout() }
                    .disabled(client.busy)
            }
        }

        Section {
            Label("Connect with a personal access token", systemImage: "key.fill")
                .font(.headline)
            Text("1. Create a fine-grained token on GitHub. Select your repositories and set Contents to Read-only.")
            Link(
                "Create token on GitHub",
                destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!
            )
            Text("2. Copy the token, return here and paste it below. Use a token, not your GitHub password.")
            SecureField("Paste GitHub token", text: $personalToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect GitHub") {
                Task {
                    await client.connectToken(personalToken)
                    if client.lastError.isEmpty {
                        personalToken = ""
                        tab = "Repositories"
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(client.busy || personalToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } footer: {
            Text("Saved on this iPad in Keychain. Private organization repositories may require organization approval.")
        }

        Section("Other options") {
            Button("Continue with public repositories") {
                client.usePublicAccess()
                tab = "Repositories"
            }
            .disabled(client.busy)

            DisclosureGroup("Advanced: OAuth device sign-in") {
                Text("Requires your own registered GitHub OAuth app with Device Flow enabled. A GitHub username is not a client ID.")
                    .font(.caption)
                Link("Register an OAuth app", destination: URL(string: "https://github.com/settings/developers")!)
                TextField("OAuth client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Get sign-in code") { client.login(clientID: clientID) }
                    .disabled(client.busy || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !client.userCode.isEmpty {
                Text(client.userCode)
                    .font(.title.monospaced())
                    .textSelection(.enabled)
                if let url = client.verificationURL {
                    Link("Open GitHub to enter this code", destination: url)
                }
                Text("Return here after approving. You can close this panel while sign-in finishes.")
                    .font(.caption)
            }
        }
    }

    private func importRepository() {
        do {
            error = ""
            try prepareMutation()
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Projects/GitHub-\(UUID().uuidString.prefix(8))", isDirectory: true)
            client.perform(repository: repository, branch: branch, root: root) { url in
                onOpen(url)
            }
        } catch {
            self.error = String(describing: error)
        }
    }
}
