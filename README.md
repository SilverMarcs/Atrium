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

Turn on remote access in Settings → Remote, then scan the pairing QR code with an iPhone or paste the pairing link into Settings → Remote on another Mac.

## Agent tools and the Orchestrator

Atrium gives every Claude and Codex session it runs an MCP server of its own tools, turned on in Settings → Integrations:

- **Orchestrator**: sessions find projects, agents and other sessions, read their conversations, and delegate work to a new or idle session. Delegating returns a task ID at once; the delegating agent ends its turn, and Atrium sends it the result as a new message, marked as another agent's output, when the other session finishes. Results that arrive while it's busy wait for its turn to end and go together. Each chain of delegated work has a budget, so agents can't keep waking each other.
- **HTML in chat**: agents show charts, diagrams and mockups in the conversation.

Each session reaches the tools with its own credential, so Atrium knows who is calling. Sessions get the tools that are on when they start or resume; turning one off also stops sessions already running from using it. Approvals stay with you in Atrium.

### ChatGPT

ChatGPT can use the Orchestrator's tools (never HTML in chat) through OpenAI's [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels). Nothing is exposed to the internet: OpenAI's `tunnel-client` runs on this Mac and connects out to OpenAI. Create a tunnel and a restricted runtime key (Tunnels Read + Use) in OpenAI Platform, then run `tunnel-client` with a profile pointing at the MCP server URL in Settings → Integrations and sending the header from the file shown there:

```yaml
mcp:
  server_urls:
    - channel: main
      url: http://127.0.0.1:<port>/mcp
  extra_headers:
    Authorization: "file:/Users/<you>/Library/Application Support/Atrium/ClaudeBridge/chatgpt-authorization"
```

Add the tunnel in ChatGPT as a custom MCP server with no authentication; Atrium checks its own token. ChatGPT can't be woken when delegated work finishes, so it checks with `task_status`, and the sessions it starts sit in the collapsed ChatGPT section of the task list.

## Requirements

- macOS 26.0+

Both providers require their CLI to be installed separately. Codex conversations use its shared app-server and item events. Claude conversations use `--bg`, a local supervisor connection, and authenticated HTTP hooks delivered directly to Atrium.

## License

[MIT](LICENSE)
