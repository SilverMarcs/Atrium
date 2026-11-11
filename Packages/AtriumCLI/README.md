# atrium — command-line client

`atrium` drives the Claude and Codex sessions on an Atrium host (a Mac running Atrium): listing and reading them, starting and prompting them, answering their questions and approvals, and the task menu's actions. It is a thin interface over `AtriumClient`, the same library the Mac and iOS apps use, so it can do exactly what they can, and nothing more: no terminal, saved commands, Git, files, project editing or device management. One tool serves the agents Atrium runs, an agent on another computer such as ChatGPT's Dot, and the user.

`atrium help` describes every command for the agent reading it; `atrium help <command>` describes one.

## On the Mac: the agents Atrium runs

Atrium.app carries `atrium` in `Contents/Helpers`, so it updates with the app, and puts it first on the PATH of every session it runs (Claude's settings `env`, Codex's `shell_environment_policy`). There is nothing to pair: the bundled client connects to the app it's inside through a Unix socket in Atrium's Application Support folder that only this user can open, as the built-in "Local agents" device. The socket is open only while the Orchestrator is on in Settings → Integrations; turning it off closes it and every connection on it at once, so agents' commands fail with `unreachable`.

Each agent exports its session's ID to its commands (`CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID`). Commands inherit them, so the client puts the nearest agent among its parent processes first, and the host takes the first candidate that's working as the caller; a Codex subagent's thread counts as its session. A session the caller starts or prompts is linked under it: apps list it under the caller's Subagents, its prompt shows as relayed from the caller, its final reply comes back to the caller as a new message that wakes it, together with any question it asks, and stopping the caller stops it. Agents can't `--wait` for such a session; they end their turn instead.

Codex's own sandbox (workspace-write without network) blocks every socket, Unix ones included, and Codex 0.166 doesn't apply `network.unix_sockets` from config, so in that sandbox `atrium` reports that the sandbox blocked it and the agent asks to run it outside, which the user approves once (Codex offers to remember the `atrium` prefix).

## Anywhere else: pair

Atrium releases carry static binaries for x86_64 and arm64 Linux. They need nothing else installed, so on any distribution:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://github.com/SilverMarcs/Atrium/releases/latest/download/atrium-linux-$(uname -m).tar.gz \
  | tar -xz -C ~/.local/bin atrium
atrium --version
```

`atrium-linux-sha256.txt` in the same release lists their checksums. To build from source instead, with Swift 6.2 or later:

```sh
swift build --package-path Packages/AtriumCLI -c release
```

On the Mac, turn on remote access in Atrium Settings → Remote and copy the pairing link. Each link pairs one device and is replaced once used:

```sh
atrium pair 'atrium://pair?v=3&host=…' --name Dot
```

The device keeps its identity and token in `~/.config/atrium/credentials.json` (or `$XDG_CONFIG_HOME/atrium`, or `$ATRIUM_CONFIG_DIR`), in a folder only its user can open. The Mac lists it under Paired Devices, where removing it revokes the token. Sessions a paired client starts are listed apart on the Mac and iPhone, in a section under the device's name, and alert only when they need an answer. With several paired hosts, choose one with `--host` or `ATRIUM_HOST`.

For relay connections on Linux, `https_proxy` (or `HTTPS_PROXY`) may name an `http://` CONNECT proxy, with optional URL-encoded credentials; `no_proxy` (or `NO_PROXY`) bypasses it for listed hosts. TLS still validates the relay inside the tunnel.

## Output

Standard output carries exactly one JSON document per command, or one JSON object per line for streams. Failures print `{"error": {"code", "message", …}}` and exit non-zero:

| Exit | Code | Meaning |
| --- | --- | --- |
| 0 | | Done. |
| 1 | `rejected`, `not_found`, `ambiguous`, `needs_mac`, `unsupported`, `failed` | The host declined, or nothing matched. `needs_mac`: only the agent's own interface on the Mac can answer it. |
| 3 | `not_paired`, `revoked`, `pairing_failed` | Pair (again). |
| 4 | `unreachable` | Couldn't reach the host; nothing was sent. |
| 5 | `outcome_unknown` | Sent, but the reply was lost; it may have happened. Repeat with the same `--id`. |
| 6 | `timeout` | `--timeout` passed while waiting or following. |
| 64 | `invalid_argument` | Invalid usage. |

## Unattended use

- **Reading is passive.** `sessions`, `show`, `read` and `follow` never mark a result read or report this device as in use. Only `mark-read` acknowledges a result.
- **No duplicate prompts.** Every `start` and `send` has an ID (`--id`, any UUID; generated when omitted and printed as `id`). The host performs each ID once per device for a day, so after exit status 5 the same command with the same `--id` returns the first result instead of prompting again.
- **Approvals.** `respond <session> --allow` or `--decline` answers a tool approval; `--answer` answers questions. An agent can finish a task unattended, or report back what only the user can answer.
- **Concurrency.** Commands can run at once, such as a long `follow` beside `send` and `respond`.

```sh
atrium start --project api --provider claude --wait "Run the tests and fix any failure" > turn.json
session=$(jq -r .sessionID turn.json)
jq -e '.session.interactions | length > 0' turn.json && atrium respond "$session" --allow
atrium send "$session" --id "$(uuidgen)" --wait "Now open a pull request"
atrium settle "$session"
```

Linux reaches hosts through the relay only; Macs also connect directly on the local network.
