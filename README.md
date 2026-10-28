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

## Requirements

- macOS 26.0+

Both providers require their CLI to be installed separately. Codex conversations use its shared app-server and item events. Claude conversations use `--bg`, a local supervisor connection, and authenticated HTTP hooks delivered directly to Atrium. No Node or Python companion program is bundled. The terminal is created on demand and switching views does not restart the agent.

Claude's supervisor socket is undocumented and isolated in `ClaudeDaemonClient`; CLI updates may require compatibility changes. Claude lists current local sessions regardless of which app created them, using session metadata snapshots and background-worker discovery. Atrium-connected hook messages are saved in Atrium’s own store; external saved conversations are read on demand. Provider session directories are not watched. Codex restores conversations through its app-server API. Resuming an Atrium background job preserves its saved launch options, avoiding an implicit conversation fork. Reopening a Claude conversation loads its current provider history, including replies completed while Atrium was closed, then continues with native hook events for Atrium-connected workers. Unsupported dialogs remain accessible through Terminal.


## License

[MIT](LICENSE)
