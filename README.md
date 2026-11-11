# Atrium

A native macOS workspace for Codex and Claude tasks, built with SwiftUI.
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

- Codex and Claude tasks grouped by project
- Native chat, with any conversation one click away in your terminal app, attached to the same running session
- Streaming replies, images, mid-turn guidance, and native approval/question controls
- Saved commands per project that run on its host, with their output, replies and keys from the Mac or iPhone
- Built-in text editor with syntax highlighting
- Git changes, diffs, branches, and worktrees

## Hosts and clients

Every Mac running Atrium is a host. The host alone touches projects, Git, files and the agent integrations; everything else, including the Mac's own window, is a client of it. The Mac's UI talks to its own host in process, and to other hosts (another Mac's Atrium) through the same end-to-end encrypted relay the iOS app uses. Clients stay connected to all their hosts at once and show every host's tasks in one list, which the host menu filters. Commands run on their host, a conversation opens in a terminal only on its own host, and files on another host are read-only.

Turn on remote access in Settings → Remote, then scan the pairing QR code with an iPhone, paste the pairing link into Settings → Remote on another Mac, or pass it to `atrium pair` on another computer.

## What Atrium tells agents

Atrium appends a short, fixed set of instructions to every session it runs (Claude's system prompt, Codex's developer instructions): showing images as Markdown pointing at files on the Mac, and, with Visualizations on in Settings → Integrations, pages (charts, diagrams, mockups) as an HTML document in a fenced `atrium-page` block, which Atrium shows as a page instead of code. Each chat keeps the instructions it was created with on every resume, relaunch and fork, so it stays in the cached prompt prefix; the switches in Settings → Integrations only change new chats.

## Command line and agents working together

`atrium` is Atrium's command-line client, built on the same client library as the apps; see [Packages/AtriumCLI/README.md](Packages/AtriumCLI/README.md). Atrium.app bundles it and puts it on the PATH of every session it runs. With the Orchestrator on in Settings → Integrations, agents use it to start and prompt other Claude and Codex sessions with nothing to pair: a session one starts is listed under it, its result comes back as a message that wakes it, its questions are passed up, and stopping one stops the sessions working for it. Turning the Orchestrator off shuts agents out at once.

Anywhere else, such as ChatGPT's Dot in its own Linux shell, `atrium pair` pairs the client over the relay like any device. It can then start sessions, wait for their turns, answer their questions and approvals, and settle them, and the Mac lists what it starts under its name.

## Requirements

- macOS 26.0+

Both providers require their CLI to be installed separately. Codex conversations use its shared app-server and item events. Claude conversations use `--bg`, a local supervisor connection, and authenticated HTTP hooks delivered directly to Atrium.

## License

[MIT](LICENSE)
