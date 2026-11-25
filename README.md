# Diffs

A native macOS workspace for Codex, Claude and Antigravity tasks, built with SwiftUI.
Work across projects with native chat, a command runner, an editor, and a Git inspector.

[Download for macOS](https://github.com/SilverMarcs/Atrium/releases/latest) · [Get the iOS app](https://apps.apple.com/app/id6765783787)

<img width="1587" height="1103" alt="Screenshot 2026-10-24 at 12 02 11 PM" src="https://github.com/user-attachments/assets/9b29ada6-0e59-4e28-be14-bacceb16ab31" />
<img width="1587" height="1103" alt="Screenshot 2026-10-24 at 12 02 27 PM" src="https://github.com/user-attachments/assets/f88a530c-90c6-4442-9fb0-5422793b146c" />


## iOS Companion App

<img width="200" alt="03F071A0-1450-4507-8983-D16029B95B31_4_5005_c" src="https://github.com/user-attachments/assets/c70cb85b-61d4-4995-9e0e-907e8fef7665" />
<img width="200" alt="9E09C3BA-0DEE-4EF6-8BF2-7B2DFB561098_4_5005_c" src="https://github.com/user-attachments/assets/43744c37-65b2-4147-b130-a520f919a497" />
<img width="200" alt="AB2F2D08-7041-40A5-8C38-6030BA92F3C1_4_5005_c" src="https://github.com/user-attachments/assets/3e43aa2f-5a95-4213-a043-e566545e95a4" />
<img width="200" alt="881C4A0E-665A-4C1A-9683-D78FC5698FF0_4_5005_c" src="https://github.com/user-attachments/assets/b8efb99c-0d15-4167-8887-9286b8fc47fa" />

## Features

- Codex, Claude and Antigravity tasks grouped by project
- Native chat, with any conversation one click away in your terminal app, attached to the same running session
- Streaming replies, images, mid-turn guidance, and native approval/question controls
- Saved commands per project that run on its host, with their output, replies and keys from the Mac or iPhone
- Built-in text editor with syntax highlighting
- Git changes, diffs, branches, and worktrees

## Hosts and clients

Every Mac running Diffs is a host. The host alone touches projects, Git, files and the agent integrations; everything else, including the Mac's own window, is a client of it. The Mac's UI talks to its own host in process, and to other hosts (another Mac's Diffs) through the same end-to-end encrypted relay the iOS app uses. Clients stay connected to all their hosts at once and show every host's tasks in one list, which the host menu filters. Commands run on their host, a conversation opens in a terminal only on its own host, and files on another host are read-only.

Clients offer the agents their host reports as available, so hosts can retire a provider without requiring every client to update first. Retired-provider requests from an older client fail without disconnecting it; saved threads for other providers are preserved. Updated clients also ignore unsupported-provider rows from older hosts while keeping their supported tasks.

Turn on remote access in Settings → Remote, then scan the pairing QR code with an iPhone or paste the pairing link into Settings → Remote on another Mac.

## What Diffs tells agents

Diffs appends a short, fixed set of instructions to every session it runs (Claude's system prompt, Codex's developer instructions, the system prompt Antigravity appends for a new conversation): showing images as Markdown pointing at files on the Mac, asking for secrets with `request_secret`, and, with Visualizations on in Settings → Integrations, pages (charts, diagrams, mockups) written to an HTML file and shown with the `show_page` tool, which Diffs shows as a page card in the reply. Agents revise a page by editing its file, not rewriting it; the host copies the file the first time it reads each reply that shows it (Application Support `Pages/`, dropped after 30 days), so earlier replies keep their versions. Pages that older chats wrote as fenced `atrium-page` blocks still show. Each chat keeps the instructions it was created with on every resume, relaunch and fork, so it stays in the cached prompt prefix; the switches in Settings → Integrations change new chats' instructions, take tools away from every agent at once, and give them to chats as they start or reconnect.

HTML pages load images on demand from their task folder and any absolute image folder explicitly written as a quoted path ending in `/` in the page, such as `const base='/path/to/images/';`. This lets JavaScript construct filenames and switch content without listing every image in advance. Individually referenced images outside those folders also remain supported. The host records each page's image scope once, checks canonical paths to prevent traversal or symlink escapes, and uses the existing image size limits and client cache. Image requests include the page key; Markdown and older clients retain their existing transcript-based access. Folder authorization avoids evaluating JavaScript, enumerating directories, or bundling unused images. Local image files must remain on the host for later viewing.

## Agents working together

The host runs one MCP server with one set of tools, and what a caller may use depends on its credential, checked both when it lists the tools and when it calls one.

- **Agents Diffs runs** reach it on the agent bridge, Diffs’ loopback endpoint, with the bridge's token: Claude through `--mcp-config`, Codex through each thread's config and Antigravity through each session's MCP servers. Diffs tells which session a call comes from: Claude's PreToolUse hook names the tool call, and Codex's and Antigravity's call metadata name their thread. With the Orchestrator on in Settings → Integrations, they get `list_projects`, `list_sessions`, `read_session`, `start_session`, `send_prompt`, `respond`, `stop_session` and `settle_session`: a session one starts is listed under it, its result comes back as a message that wakes it, its questions are passed up, a follow-up to a working session waits for its turn, and stopping one stops the sessions working for it. They always get `request_secret`, and `show_page` while Visualizations is on.
- **ChatGPT** connects through the MCP gateway at `https://atrium-relay.lynksphere.com/mcp`, a stateless part of the relay Worker with OAuth. Install the connector in ChatGPT, open Diffs from its sign-in page and approve the connection: the Mac pairs ChatGPT as a device that can only use the tools, turns on remote access, and hands the gateway its token, sealed into ChatGPT's OAuth tokens. Each MCP request then reaches the Mac through its relay room like an iPhone, encrypted from the gateway to the Mac; the gateway itself reads ChatGPT's requests. When approving, the user picks Full Access, Supervised (what it hands work to asks before edits and commands, and it can't approve tool runs) or Read Only. ChatGPT never gets `show_page` or `request_secret`, and what it starts is listed under its name. Removing it in Settings → Remote revokes it. Agents on the Mac likewise never hand work to a session with broader permissions than their own.

## Requirements

- macOS 26.0+

Each provider requires its CLI to be installed separately. Codex conversations use its shared app-server and item events. Claude conversations use `--bg`, a local supervisor connection, and authenticated HTTP hooks delivered directly to Diffs. Antigravity conversations use `agy acp`, its Agent Client Protocol server, which Diffs runs as one child process for all of them; What ACP lacks, forking, rewinding, renaming and deleting conversations, Diffs asks of the server's own local language server, as Antigravity's terminal app does; side chats are forks Diffs deletes when they end. Its permission modes are the ones Antigravity's ACP server offers, plus Full Access, which runs in Antigravity's Default mode while Diffs approves every tool request.

## Repository layout

- `App/Shared`, compiled into both apps: `Protocol` is what hosts and clients say to each other and the encrypted channels they say it over; `Client` connects to hosts and keeps what each one reports; the rest is SwiftUI shared by both apps.
- `App/macOS`, the Mac app. `App/macOS/Host` is the host every Mac runs: projects, Git, files, the agent integrations, the tools agents use, and the server clients reach it through. The Mac app talks to its own host in process like any other client.
- `App/iOS`, the iPhone and iPad app, a client of the hosts it pairs with; `App/NotificationService` is its push extension.
- `relay`, the Cloudflare Worker: relay rooms, APNs pushes and ChatGPT's MCP gateway. `npm run check` type-checks it.
- `scripts`, for running and releasing the apps.

## License

[MIT](LICENSE)
