# XTool iPad IDE features

Open the workspace tools menu beside the project status. The existing build action still creates an **unsigned IPA**; signing remains external.

## Editing and projects

- Swift syntax highlighting, keyword/project-identifier suggestions above the keyboard, and build diagnostic underlines. Completion is lexical, not SourceKit semantic completion; errors update after a build.
- Find/replace (`Command-F`), project search (`Command-Shift-F`), save all (`Command-Shift-S`), and split editors (`Command-\\`). Drag the panel dividers to resize them.
- Project tools create files/folders, rename or move entries, and move deleted entries to project trash with undo. Editors accept UTF-8 files up to 2 MB. Search is bounded to 500 matches.
- The console Issues tab opens diagnostics at their source location. SDK diagnostics outside the project remain in the log.
- Builds show target/link/package progress and reuse a module cache keyed by project, manifest, compiler and SDK identity. A first SwiftUI build can still be slow. Build history opens recovered logs and exports previous IPAs; its clear-cache action forces regeneration.

## GitHub

Open **GitHub** in workspace tools. Either enter a personal access token with repository Contents read permission, or enter the client ID of your registered GitHub OAuth app with **Device Flow enabled**, then choose sign in and open the GitHub verification page. No OAuth client secret belongs in the iPad app. Tokens are stored in Keychain.

Enter `owner/repository` and a branch to import. Pull fetches an immutable commit snapshot and compares it with the previous snapshot. Local changes are preserved when the remote file is unchanged; conflicting local and remote edits stop the pull. Successful pulls retain backups in `.xtool/PullBackups`. Save/commit your work separately before major reorganizations.

This is repository snapshot import/pull, not a full Git client: it does not push, merge branches, resolve submodules or materialize Git LFS pointers. Imports are limited to 2,000 regular files and 200 MB total (20 MB per blob); symlinks and submodules are rejected. Only supported Swift projects with the mobile build configuration can build on iPad. SwiftPM dependency graphs still need the existing host preparation workflow. File-to-directory conflicts may require a fresh import.

## ChatGPT assistant

The assistant uses the official **Codex app-server** protocol and ChatGPT device-code sign-in. It requires a separately running, reachable Codex host; the Codex runtime is not bundled into XTool. It starts its own conversation and does not import this ChatGPT chat.

1. Install a current Codex CLI on a trusted host that supports `app-server --ws-auth` and ChatGPT device-code login. Use a dedicated account/container without unrelated repositories, credentials, MCP integrations or plugins. The host holds the ChatGPT session and can see the selected code and prompts.
2. From this checkout run `bash scripts/run-mobile-codex-server.sh`. It creates a private connection-token file and starts on loopback port 4500. It disables shell and unified-exec tools. It does not configure public hosting.
3. Put a trusted TLS WebSocket reverse proxy in front, forwarding the `Authorization` header. Restrict access to your devices. Use its `wss://` address on iPad. The app permits plain `ws://` only for localhost; a LAN address is not localhost.
4. In **Assistant → Connection & ChatGPT sign-in**, enter the WSS endpoint and the contents of the host's connection-token file. Connect, select **Sign in with ChatGPT**, and complete the official OpenAI device-code page. Account settings may need device-code authentication enabled. Sign out logs out the host's Codex session.
5. Open project files, select which ones to share (200 KB total), and send your request. Expand each proposed change to review its before/after text, then choose **Apply reviewed changes**. Existing files must have been shared and must still match the supplied snapshot. New files are allowed inside the project; traversal and reserved metadata paths are rejected. Undo is available for the last applied batch while the panel remains open; backups persist in `.xtool/Edits`.

The client requests a read-only, network-disabled execution sandbox and declines approval requests. Read-only does not mean the host cannot read its own files; use the dedicated host described above. Proposals are applied locally by XTool after review, not by host filesystem tools. Closing the assistant disconnects the UI; use **Stop** before closing an active turn. WebSocket transport is experimental, so client/server versions must remain compatible. No paid API key is required by this integration; account/model eligibility is determined by Codex.

References: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [GitHub device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow).

## Validation

`scripts/test-mobile-project.sh` runs portable Swift pipeline/workspace checks and Python build-tool tests. The host one-shot build runs these checks before building the app. UIKit/SwiftUI compilation and live GitHub/ChatGPT authentication must be checked on the host/device; they cannot be exercised by the Linux Python checks alone.
