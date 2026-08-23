# Switchrail

Switchrail is a local, cross-platform TUI orchestrator for existing AI
coding-agent CLIs. It reads implementation specifications from NoteVault,
creates an isolated Git worktree for each task, runs an executor, opens a
GitHub Pull Request, and coordinates an independent review/fix loop until
approval — and, when you opt in, a policy-gated delivery station through green
CI to merge.

Switchrail coordinates existing tools. It is **not** an AI agent, does **not**
call LLM provider APIs, and does **not** store provider API keys. Authentication
and subscription stay with each agent runtime (CLI or ACP) and with `gh`.

## Install on linux/macOS

```bash
curl -fsSL https://raw.githubusercontent.com/nekstep/switchrail-releases/main/install.sh | bash
```

## Install on Windows

```powershell
irm https://raw.githubusercontent.com/nekstep/switchrail-releases/main/install.ps1 | iex
```
## Quick start (current Git repository)

No project `config.toml` is required to **launch** the TUI.

```text
cd <your-git-repository>
switchrail
```

1. **Initialize** (once per repo): `/init` in the TUI, or headless
   `switchrail init`. This creates `.switchrail/` and ensures `/.switchrail/`
   is gitignored. Until then mutating commands refuse with an actionable
   message.
2. **Connect NoteVault:** `/mcp` → set Streamable HTTP URL → Save & Connect →
   Authorize if the server requires OAuth (`notes:read` only). Connect never
   opens a browser by itself; use Authorize (or copy the URL if the opener
   fails).
3. **Check agents:** `/agents` — executor/reviewer should show **OK**.
4. **Configure defaults:** `/settings` (profiles, agents, delivery, limits).
5. **Run:** `/run` or `a` — pick a leaf note. For a first smoke without review:

   ```text
   /run --no-review
   ```

   Success ends in **`DELIVERED`** with an open PR that is **not** merged under
   the default delivery policy.

Optional one-shot flags:

```text
switchrail --repository /path/to/repo
switchrail --check          # print resolved paths / schema; no TUI
switchrail --version
```

## Core user experience

```text
select a NoteVault specification
              ↓
            /run
              ↓
 watch implementation and review
              ↓
     APPROVED  or  DELIVERED (--no-review)
```

## MVP scope

- Read a folder/note tree and note bodies from NoteVault through MCP.
- Select a leaf specification in a keyboard-driven TUI (mouse is optional).
- Run configured coding-agent CLIs through replaceable adapters (Codex, Claude,
  Devin, Cursor, Grok). Optional ACP transport for Cursor, Devin, and Grok.
- Pass arbitrary model names to the selected adapter as strings.
- Create one Git branch and worktree per task.
- Push the branch and find or create a GitHub PR through `gh`.
- Run an independent reviewer and normalize `APPROVE`, `NEEDSFIX`, or `ERROR`.
- Repeat `FIX → REVIEW` up to a configurable iteration limit.
- Schedule Runs concurrently with a global limit and per-agent limits.
- Stream and persist stdout/stderr for every agent run.
- Persist tasks, runs, sessions, events, and PR/worktree references in SQLite.
- Preserve an immutable specification snapshot and SHA-256 hash for every Task.
- Recover safely after a TUI restart without reattaching to orphan processes.
- Optional policy-gated merge (`[delivery].policy = ask|auto`) after green CI.
- Work as a first-class application on Windows, Linux, and macOS.

## Explicit limitations

- **One effective repository** per process (`--repository` or cwd).
  `repository.path` in config does not redirect the process.
- **One live process per data-dir** via `runtime/instance.lock`.
- **NoteVault is read-only** — no create/update/delete/move/tag/status.
- **`DELIVERED`** is the successful `--no-review` terminal state (not merge).
- **No auto-merge by default** — `[delivery].policy` defaults to `never`.
- **No remote daemon**, **no PTY reattach**, **no automatic** branch/worktree
  cleanup after success. Missing cleanup is a storage limitation; a **new**
  Task on a finished note still gets fresh coordinates (Task-id component).
- **No provider API keys in Switchrail** — agent CLIs/ACP runtimes and `gh`
  own credentials.
- Not in MVP: multiple repositories, web UI, distributed execution, embedded
  terminal, cost accounting, agent marketplace, installer GUI, auto-update.

## Runtime workflow

```text
NEW
  → QUEUED
  → PREPARING
  → IMPLEMENTING
  → PR_READY
      ├─ --no-review → DELIVERED
      └─ review      → REVIEWING
                        ├─ APPROVE  → APPROVED
                        │              ├─ delivery.policy=never → final
                        │              └─ ask|auto → GREENING → MERGED
                        └─ NEEDSFIX → NEEDS_FIX → FIXING → REVIEWING

any active stage → BLOCKED → /retry after user resolution
```

`TaskState` and `RunStatus` are independent state machines. Additional
terminal/recovery states include `FAILED`, `STOPPED`, `INTERRUPTED`, and
`FAILED_REVIEW_LIMIT`. `BLOCKED` carries a persisted `blocking_reason` and is
not a failure. Error reasons stay separate from the state enum.

An `APPROVED` task has passed review. With default `delivery.policy = never`
it is final and **not** merged. With `ask` or `auto`, delivery may reach
`MERGED` only after green CI and independent `gh` observation (ADR 0014).

## Slash commands

| Command | Purpose |
|---|---|
| `/help [command]` | Show commands or contextual help |
| `/refresh` | Refresh the read-only NoteVault tree |
| `/mcp [status\|connect\|auth\|disconnect\|logout]` | Manage the NoteVault MCP connection |
| `/agents` | Show configured agent binaries, readiness, and capabilities |
| `/init` | Initialize `.switchrail/` for this repository (wizard; stays in TUI) |
| `/settings` | Edit repository configuration (detached draft; Save/Apply) |
| `/run` | Open the launch picker (leaf notes, spec preview, profiles); Enter launches |
| `/notes` | Dedicated Notes tree + specification screen (Courtyard stays home) |
| `/track [list\|create\|edit\|start\|pause\|resume\|stop]` | Dependency tracks: list, create, edit edges, plan preview, start/pause |
| `/status [task-or-note-id]` | Task Detail: stations, sessions, events, intervention cards, live log |
| `/tasks` | Open Courtyard (task list home screen) |
| `/logs [implement\|review\|fix\|green]` | Bounded stdout/stderr tail of a Run |
| `/open pr` | Open the Task PR URL in the system browser (never merges) |
| `/review` | Start a REVIEW Run for an existing PR |
| `/fix` | Start a FIX Run from the latest NEEDSFIX feedback |
| `/mouse [on\|off\|toggle]` | Enable or disable mouse reporting |
| `/stop [task-or-note-id]` | Stop a queued or active Task (keeps worktree/PR/logs) |
| `/retry [task-or-note-id]` | Reconcile Git/PR milestones and resume the next safe durable action |
| `/blocked` | List BLOCKED Tasks with reason and suggested next action |

`/run` supports:

```text
--executor <profile>
--model <model>
--reasoning <effort>
--reviewer <profile>
--review-model <model>
--review-reasoning <effort>
--no-review
```

Flags pre-fill the picker. Enter on a free note launches IMPLEMENT; Enter on a
note that already has an unfinished Task opens that Task instead. With
`--no-review`, reviewer flags are rejected and success ends in `DELIVERED`.

## Configuration

By default each Git repository owns its Switchrail state under:

```text
<repository-root>/.switchrail/
  config.toml
  runtime/          # switchrail.db, instance.lock, logs/, prompts/
  agents/           # Switchrail-owned agent homes (for example grok/)
```

The whole `.switchrail/` directory is local-only and should be gitignored
(`/.switchrail/`). See **[CONFIGURATION.md](CONFIGURATION.md)** for the full
TOML reference, `[limits]`, optional `worktrees_root`, single-instance lock
semantics, and upgrade notes.

Ready-to-copy example: [`config.example.toml`](config.example.toml).
`repository.path` must stay empty/commented — it is ignored for resolution.

```toml
[repository]
base_branch = "main"
remote = "origin"
# worktrees_root = "../worktrees/my-repo"   # optional; empty → <parent>/worktrees/<basename>

[notevault]
transport = "streamable-http"
url = "https://notes.example.com/mcp"
auth = "oauth"
registration = "auto"

[defaults]
executor_profile = "devin-default"
reviewer_profile = "claude-default"
max_parallel_tasks = 6
max_review_iterations = 5

[delivery]
policy = "never"

[limits]
devin = 3
claude = 3
codex = 3
cursor = 3
grok = 3

[agents.devin]
binary = "devin"
enabled = true
# transport = "acp"   # optional; default cli

[agents.claude]
binary = "claude"
enabled = true
# Optional ACP: binary must be a local bridge path (never npx). role_restriction=none (S4a).
# transport = "acp"

[agents.codex]
binary = "codex"
enabled = true
# Optional ACP: binary must be a local codex-acp path. role_restriction=none (S5a).
# transport = "acp"

[profiles.devin-default]
agent = "devin"
model = "sonnet"

[profiles.claude-default]
agent = "claude"
model = "sonnet"
```

## NoteVault integration

Primary transport is MCP over Streamable HTTP. OAuth uses Authorization Code +
PKCE with scope `notes:read` only. Tokens live in the OS credential store,
never in `config.toml` or SQLite. The adapter is strictly read-only
(`notes_list`, `note_get`, plus optional graph read tools when present).

Use `/mcp` for endpoint setup, Authorize, reconnect, and logout. A failed body
read for one note never hides persisted Tasks.

## Agent Client Protocol (ACP) transport

Agents default to the existing CLI transport. Set `[agents.<name>].transport = "acp"`
to opt a Task snapshot into ACP (Cursor, Devin, Grok, or Claude/Codex bridges).
Switchrail never flips the default itself. `/agents` shows `role_restriction`
for ACP runners:

- Cursor / Devin: `enforced`
- Grok / Claude bridge / Codex bridge: `none`

Claude and Codex have no native ACP entry point. For ACP, set `binary` to a
**locally installed, version-pinned bridge** (never dynamic `npx` on spawn).
Capabilities and REVIEW start milestones show the paired versions
`bridge + agent` (underlay CLI probed via `claude`/`codex --version`).
