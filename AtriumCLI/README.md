# atrium — command-line client

`atrium` operates the sessions on an Atrium host (a Mac running Atrium with remote access on) from another computer, such as a Linux server running an agent. It is a thin interface over `AtriumClient`, the same library the Mac and iOS apps use, so pairing, the end-to-end encrypted relay connection, reconnection, requests and subscriptions behave exactly as they do in the apps. Projects, agents and sessions stay on the host.

## Install

Atrium releases carry static binaries for x86_64 and arm64 Linux. They need nothing else installed, so on any distribution:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://github.com/SilverMarcs/Atrium/releases/latest/download/atrium-linux-$(uname -m).tar.gz \
  | tar -xz -C ~/.local/bin atrium
atrium --version
```

`atrium-linux-sha256.txt` in the same release lists their checksums. Update by downloading again; use the release that matches the Atrium version on the Mac.

To build from source instead, with Swift 6.2 or later (on Linux, with [Swift's dependencies](https://www.swift.org/install/linux/)), from a checkout of this repository:

```sh
swift build --package-path AtriumCLI -c release
install -m 755 AtriumCLI/.build/release/atrium ~/.local/bin/atrium
```

## Pair

On the Mac, turn on remote access in Atrium Settings → Hosts and copy the pairing link. Each link pairs one device and is replaced once used. Then:

```sh
atrium pair 'atrium://pair?v=3&host=…' --name Dot
```

The device gets its own identity and token, kept in `~/.config/atrium/credentials.json` (or `$XDG_CONFIG_HOME/atrium`, or `$ATRIUM_CONFIG_DIR`) in a folder only its user can open. The Mac lists it in Settings → Hosts, where removing it revokes the token; the next command then fails with `revoked` and the local credentials are deleted. `atrium forget` deletes them locally only.

With several paired hosts, choose one with `--host <id or name>` or `ATRIUM_HOST`.

## Commands

| Command | Does |
| --- | --- |
| `pair <link> [--name]` | Pairs this device. |
| `hosts`, `forget`, `status` | Lists paired hosts, forgets one, connects and reports the host. |
| `projects` | Lists projects, which sessions start in. |
| `sessions [--project P] [--status S]… [--all] [--limit N]` | Lists sessions, newest first; settled ones only with `--all`. |
| `show <session>` | One session, with questions and approvals waiting for an answer. |
| `read <session> [--last N] [--after ID]` | The recent conversation. |
| `follow <session> [--until idle\|input] [--timeout S] [--history N]` | Streams the conversation and status as JSON lines. |
| `models` | The host's agents and the models each can run. |
| `start --project P [--provider] [--model] [--effort] [--fast] [PROMPT]` | Starts a session with its first prompt. |
| `send <session> [PROMPT]` | Sends a prompt; one sent while the agent works joins its turn. |
| `interrupt <session>` | Stops the current turn. |
| `respond <session> [interaction] --allow\|--decline\|--answer …` | Answers a question or approval. |
| `rename`, `settle`, `restore`, `snooze [--hours]`, `unsnooze`, `mark-read`, `mark-unread`, `fork`, `configure [--model] [--effort] [--fast]`, `delete --confirm` | The task menu's actions. |

Sessions are named by ID or by a prefix only they have; projects by ID, name or folder. A prompt of `-`, or none, is read from standard input. `--image photo.jpg` attaches JPEG images (up to 10).

`start` and `send` return once the host has handed the prompt to the agent. Add `--wait` to return when the turn finishes or needs input, with the prompt and everything after it, or `--follow` to stream the turn. Both take `--timeout`.

Every command that connects takes `--connect-timeout` (default 30 s; the relay holds the connection while the Mac is asleep or offline), `--pretty` and `--verbose` (connection progress on standard error).

## Output

Standard output carries exactly one JSON document per command, or one JSON object per line for streams. Failures print `{"error": {"code", "message", …}}` and exit non-zero:

| Exit | Code | Meaning |
| --- | --- | --- |
| 0 | | Done. |
| 1 | `rejected`, `not_found`, `ambiguous`, `unsupported`, `failed` | The host declined, or nothing matched. |
| 3 | `not_paired`, `revoked`, `pairing_failed` | Pair (again). |
| 4 | `unreachable` | Couldn't reach the host; nothing was sent. |
| 5 | `outcome_unknown` | Sent, but the reply was lost; it may have happened. Repeat with the same `--id`. |
| 6 | `timeout` | `--timeout` passed while waiting or following. |
| 64 | `invalid_argument` | Invalid usage. |

A session has `id`, `title`, `provider`, `status` (`processing`, `waiting`, `done`, `idle`, `failed`, `stopped` or `offline`), `project`, `directory`, `updatedAt`, `unread`, `settled`, `snoozedUntil`, `model`, `reasoningEffort`, `fastMode`, `actions` (what the host allows now, such as `prompt` or `interrupt`) and `interactions`. Unknown values are `null`. An agent needs an answer when `interactions` isn't empty; each lists its `questions` and their `options`, and `canRespond` is false for ones only its terminal on the Mac can answer. A status of `waiting` with no interactions can pass on its own.

A message has `id`, `role` (`user` or `assistant`), `text`, `blocks` (`text` and `tools` runs in order), `imageCount` and `steer` (sent mid-turn). The host sends a window of recent turns; when a turn completes it may replace live messages with saved ones under new IDs, which a stream reports as new `message` events followed by `removed`.

`follow` emits `session`, `message`, `removed`, `connection` (`connecting`, `connected` or `offline` with a `reason`; it reconnects on its own), `unavailable`, and finally `end` with a `reason`: `idle`, `input`, `turn`, `timeout` or `removed`. `send --follow` and `start --follow` begin with `{"type": "delivered", "id", "sessionID"}`.

## Unattended use

- **Reading is passive.** `sessions`, `show`, `read` and `follow` never mark a result read and never report this device as in use, so the Mac's alerts keep going to the people using Atrium. Only `mark-read` acknowledges a result.
- **No duplicate prompts.** Every `start` and `send` has an ID (`--id`, any UUID; generated when omitted and printed as `id`). The host performs each ID once per device, so after exit status 5, run the same command with the same `--id`: it returns the first result instead of prompting again. `start` covers both the new session and its prompt. The host remembers IDs for a day, in memory; a host that restarted in between has forgotten them.
- **Concurrency.** Commands can run at once, for example a long `follow` beside `send` and `respond`; each opens its own connection, and the host serves them side by side.
- **Waiting.** Prefer `send --wait` or `--follow` over a separate `follow --until idle`, which ends at once if it starts before the agent picks up the prompt.

```sh
atrium start --project api --model sonnet --wait "Run the tests and fix any failure" > turn.json
session=$(jq -r .sessionID turn.json)
jq -e '.session.interactions | length > 0' turn.json && atrium respond "$session" --allow
atrium send "$session" --id "$(uuidgen)" --follow "Now open a pull request"
```

Linux reaches hosts through the relay only; the apps also connect directly on the local network.
