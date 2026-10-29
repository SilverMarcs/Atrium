# Atrium

A native macOS workspace for Codex and Claude tasks, built with SwiftUI.
Work across projects with an integrated terminal, editor, and Git inspector.

<img width="1587" height="1103" alt="Screenshot 2026-10-24 at 12 02 11 PM" src="https://github.com/user-attachments/assets/9b29ada6-0e59-4e28-be14-bacceb16ab31" />
<img width="1587" height="1103" alt="Screenshot 2026-10-24 at 12 02 27 PM" src="https://github.com/user-attachments/assets/f88a530c-90c6-4442-9fb0-5422793b146c" />


## iOS Companion App

<img width="200" alt="03F071A0-1450-4507-8983-D16029B95B31_4_5005_c" src="https://github.com/user-attachments/assets/c70cb85b-61d4-4995-9e0e-907e8fef7665" />
<img width="200" alt="9E09C3BA-0DEE-4EF6-8BF2-7B2DFB561098_4_5005_c" src="https://github.com/user-attachments/assets/43744c37-65b2-4147-b130-a520f919a497" />
<img width="200" alt="AB2F2D08-7041-40A5-8C38-6030BA92F3C1_4_5005_c" src="https://github.com/user-attachments/assets/3e43aa2f-5a95-4213-a043-e566545e95a4" />
<img width="200" alt="881C4A0E-665A-4C1A-9683-D78FC5698FF0_4_5005_c" src="https://github.com/user-attachments/assets/b8efb99c-0d15-4167-8887-9286b8fc47fa" />

## Features

- Codex and Claude tasks grouped by project
- Native chat with optional terminal attachment to the same running conversation
- Streaming replies, images, mid-turn guidance, and native approval/question controls
- Workspace-based terminal sessions
- Built-in text editor with syntax highlighting
- Git changes, diffs, branches, and worktrees

## Hosts and clients

Every Mac running Atrium is a host. The host alone touches projects, Git, files and the agent integrations; everything else, including the Mac's own window, is a client of it. The Mac's UI talks to its own host in process, and to other hosts (another Mac's Atrium) through the same end-to-end encrypted relay the iOS app uses. Clients stay connected to all their hosts at once and show every host's tasks in one list, which the host menu filters. Terminals stay on their host, and files on another host are read-only.

Turn on remote access in Settings → Hosts, then scan the pairing QR code with an iPhone or paste the pairing link into Settings → Hosts on another Mac.

Every client shares one implementation, the `AtriumKit` package: `AtriumProtocol` holds the messages, the Noise encryption and the channels they travel over, and `AtriumClient` holds pairing, credentials, reconnection, requests, subscriptions and conversation state. The apps add their own screens, composer, notifications and which task is on screen; the Mac's host (`Atrium/Host`) uses `AtriumProtocol` alone. The package builds on Linux too, where SwiftNIO and swift-crypto stand in for Network and CryptoKit.

## Command line

`atrium` drives a host's sessions from another computer, Linux included, for people and agents alike: list projects and sessions, read and follow conversations, start sessions, send prompts, interrupt, and answer questions and approvals, all as JSON. See [AtriumCLI/README.md](AtriumCLI/README.md).

## Editing conversation messages

Choose **Edit** from a user message’s context menu on Mac or iOS. The existing composer loads a separate edit draft and scrolls to the selected message, without dimming other messages. The checkmark saves it and continues the conversation; **Copy** copies a message’s text. Cancelling leaves the conversation untouched and restores the ordinary composer draft. Submission removes the original message and later replies from active history, keeps earlier conversation and original image attachments, and sends the replacement through normal messaging. Editing is available once the agent finishes or you stop it with the existing Stop control. On iOS the replacement prompt anchors at the top, including when the conversation shrinks; macOS follows its usual send-to-bottom behavior.

Codex uses native [`thread/revert`](https://developers.openai.com/codex/app-server#revert-thread-history), preserving the thread ID. Its rewind boundary is a whole turn, so only the prompt opening a turn is editable; mid-turn guidance cannot be edited independently without discarding earlier messages in that turn. Legacy non-paginated Codex threads do not support this operation and report the provider’s error without a fallback.

Claude’s background daemon has no rewind operation. Atrium stops that conversation’s idle worker, invokes the installed CLI’s native `rewind_conversation` control request in a short-lived headless process, then lets normal messaging resume the same session with `--bg` and its saved launch options. No model call is made to rewind. The control request is undocumented; this path was verified with Claude Code 2.1.310. Atrium follows Claude’s saved active parent chain and rewind leaf so discarded branches stay out of history after reopening.

Rewind replaces provider runtime state as well as history. Codex reloads its thread runtime; Claude restarts its background worker. Provider-managed background terminals, subprocesses, or agents can stop, including jobs started before the edited message. Detached external processes may continue, and their previous runtime handles may no longer work. After resuming, ordinary background execution continues as before. Conversation editing never restores file checkpoints or invokes Git undo; existing filesystem changes remain.

## Requirements

- macOS 26.0+

Both providers require their CLI to be installed separately. Codex conversations use its shared app-server and item events. Claude conversations use `--bg`, a local supervisor connection, and authenticated HTTP hooks delivered directly to Atrium. No Node or Python companion program is bundled. The terminal is created on demand and switching views does not restart the agent.

Claude's supervisor socket is undocumented and isolated in `ClaudeDaemonClient`; CLI updates may require compatibility changes. Claude lists current local sessions regardless of which app created them, using session metadata snapshots and background-worker discovery. Atrium-connected hook messages are saved in Atrium’s own store; external saved conversations are read on demand. Provider session directories are not watched. Codex restores conversations through its app-server API. Resuming an Atrium background job preserves its saved launch options, avoiding an implicit conversation fork. Reopening a Claude conversation loads its current provider history, including replies completed while Atrium was closed, then continues with native hook events for Atrium-connected workers. Unsupported dialogs remain accessible through Terminal.


## License

[MIT](LICENSE)
