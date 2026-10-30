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

## Command line

`atrium` drives a host's sessions from another computer, Linux included, for people and agents alike: list projects and sessions, read and follow conversations, start sessions, send prompts, interrupt, and answer questions and approvals, all as JSON. See [AtriumCLI/README.md](AtriumCLI/README.md).


## Requirements

- macOS 26.0+

Both providers require their CLI to be installed separately. Codex conversations use its shared app-server and item events. Claude conversations use `--bg`, a local supervisor connection, and authenticated HTTP hooks delivered directly to Atrium.

## License

[MIT](LICENSE)
