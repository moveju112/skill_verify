# skill_verify

[![Release](https://img.shields.io/github/v/release/moveju112/skill_verify?color=blue)](https://github.com/moveju112/skill_verify/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

```bash
npx skills add moveju112/skill_verify
```

A shared Claude Code, Codex, and pi verification bundle. The active host owns
the implementation while the other agent independently analyzes and verifies it.
It also includes a host-neutral multi-angle unit-test pass shared by Claude and Codex.

| Skill | Role |
|---|---|
| `verify:crosscheck` in Claude | Claude designs and writes the code; Codex independently analyzes and verifies completion. |
| `verify` in Claude, Codex, or pi | Ordinary requests stay local. Explicit crosschecks select the other model family as the read-only reviewer. |
| `unit-test` in Claude or Codex | Approval-gated unit testing right after a code change, across 7 angles. Writes a report to `<project>/test/`. |

Both skills work in **English and Korean**. Triggers are registered in both
languages, and the output — chat replies and the test report — follows whichever
language you write in.

## Install

```bash
npx skills add moveju112/skill_verify
```

The self-contained shared entrypoint is `skills/verify`, including both reviewer
wrappers. `platforms/codex/verify` remains a compatibility path; its files point
to the same shared implementation. Existing `verify:crosscheck` remains available.

### Shared installation on each server (Linux)

Clone this repository to any location, then run from its root:

```bash
bash scripts/install-shared.sh
```

This links `~/.agents/skills/verify` to this checkout and links Claude and Codex
to that shared entrypoint. It respects `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
Pi reads `~/.agents/skills` directly; no duplicate pi skill link is created.
No packages are installed and no model or network calls are made by the installer.
Existing ordinary files/directories are never overwritten: move them to a backup
location before installing. Existing symlinks are replaced. Keep this checkout
available for as long as its skills are installed.

When migrating from the old shared-agent setup, remove the `codex:verify` entry
from `~/.agents/runtime-only.txt` if present. If your server uses `agents-sync.sh`,
run it and `agents-doctor.sh` after installation, resolving any diagnostics.
Do not copy another server's runtime-only exceptions blindly.

After a commit has been pushed, update **each server** from its checkout:

```bash
git pull --ff-only
bash scripts/install-shared.sh
```

Push alone does not update other servers. Reload pi with `/reload` and use
`/skill:verify`; start a new Claude/Codex session for rediscovery. The installed
links follow subsequent checkout updates. Moving the checkout requires rerunning
the installer from its new location.

Local, network-free portability regression check:

```bash
bash tests/shared_install.test.sh
```

As a Claude Code plugin instead:

```bash
claude plugin marketplace add moveju112/skill_verify
claude plugin install verify@verify
```

Or from inside a Claude Code session:

```
/plugin marketplace add moveju112/skill_verify
/plugin install verify@verify
```

## Requirements

- Claude-hosted crosscheck: Claude Code plus a logged-in Codex CLI.
- Codex-hosted crosscheck: Codex plus a logged-in Claude Code CLI and Linux
  Bubblewrap (`bwrap`). Calling Claude requires explicit task-scoped permission;
  generic verification never calls it.
- `unit-test` has no external dependency.

## Usage

Say the trigger in either language, or call the slash command:

| Intent | English | Korean | Command |
|---|---|---|---|
| Cross-verify with Codex | "crosscheck", "cross-check with codex", "get a codex review" | "크로스체크", "codex 교차검증", "코덱스랑 핑퐁" | `/verify:crosscheck` |
| Cross-verify with Claude from Codex | "cross-check with Claude", "ask Claude to review" | "클로드랑 크로스체크", "클로드 리뷰 받아" | `$verify` or natural language |
| Unit-test the last change | "unit test", "run the tests", "multi-angle tests" | "단위 테스트", "테스트 돌려", "다방면 테스트" | `/unit-test`, `/verify:unit-test`, or `$unit-test` |

---

## crosscheck

Claude and Codex analyze **independently and blind**, then exchange and merge
findings. The agent running the user's session owns the code; the counterpart
is an independent analyst and verifier, never an author.

### Modes

Picked from the request; ambiguous requests default to `full`.

| Mode | Phases | Example trigger |
|---|---|---|
| `analyze` | A | "merge both opinions" / "둘이 의견 취합해줘" |
| `plan` | A + B | "ping-pong it and just give me the plan" / "핑퐁해서 계획만 줘" |
| `full` | A + B + C + D | "cross-check it and do the work" / "교차검증하고 작업해" (default) |
| `verify` | D | "have codex check whether this is done" / "다 됐는지 codex 체크" |

- **A — parallel blind analysis.** The reviewer call starts in the background
  from a pre-fixed prompt while the host analyzes independently. The exact task
  result is collected before comparison; dependent later phases remain sequential.
- **B — merge into a plan.** Disagreements are numbered and resolved.
- **C — implementation.** Claude only.
- **D — completion check.** A fresh Codex session judges whether the work meets
  the requirement, with the diff scope pinned to a baseline SHA. It is fired in
  the background by default; the run does not close before the result is
  collected.

Phases compose freely. Stop the run mid-way and you keep that phase's output.

### Why the wrapper exists — token-leak safety

A naive `codex exec` call drags Codex's full reasoning trace, every file it
read, and its raw logs back into Claude's context. This bundle routes **every**
call through `scripts/codex_ask.sh`, which is the only supported entry point:

- Raw Codex output is confined to a log file; only the final message reaches
  stdout, truncated to 6,000 characters by default.
- File contents and diffs are **never** pasted into prompts. Codex reads the
  repository itself from a read-only sandbox; prompts carry paths and line
  ranges only.
- Logs may contain source read by Codex, so they are created with `umask 077`
  (owner-only) and pruned after 14 days.
- `resume` accepts an explicit session UUID only. Resuming "the latest session"
  globally is deliberately unsupported — under parallel runs it attaches to
  someone else's thread.

### Review discipline

- Findings arrive numbered and severity-tagged: `#N [blocking|minor]`.
- Follow-ups reference numbers only (`"#1 rebutted: <evidence>, #2 accepted and
  fixed"`) — never restate the finding. Cheaper, and it keeps the comparison exact.
- A Codex finding is a **hypothesis until verified**. Before acting on one, read
  the cited `file:line` and confirm the path is actually reachable. Measured on
  this bundle, 15 of 23 responses came back DISAGREE — and some of those had
  misread a project rule or the review scope.
- Round caps: 2 for analysis, 3 for planning, 2 for completion checks. On cap,
  Claude decides and records the dissent in the final report.
- Sessions are replaced, not extended forever: `resume` resends the whole thread
  each time (one measured confirmation round cost 4.5M input tokens). Past 3
  rounds, or on a topic change, start a new session.

### `codex_ask.sh`

```bash
codex_ask.sh check                                # preflight: login state, no tokens spent
codex_ask.sh new    [-C <repo>] "prompt"          # start a session
codex_ask.sh resume <session-uuid> "prompt"       # continue one (UUID only)
echo "long prompt" | codex_ask.sh new -C <repo> - # '-' reads the prompt from stdin
```

The first stdout line is `SESSION: <id>`; feed it to the next `resume`. Call it
with a Bash timeout of **930000 ms** — the script's own ceiling is 900 s, and a
shorter caller timeout kills Codex from the outside and discards the round.

| Env var | Default | Meaning |
|---|---|---|
| `CROSSCHECK_MAX_CHARS` | `6000` | stdout truncation limit |
| `CROSSCHECK_TIMEOUT` | `900` | per-call ceiling, seconds |
| `CROSSCHECK_SANDBOX` | `read-only` | Codex sandbox mode |
| `CROSSCHECK_LOG_DAYS` | `14` | log retention, days |
| `CROSSCHECK_STATE_DIR` | `~/.cache/codex-crosscheck` | log location |
| `CODEX_MODEL` | Codex default | model override |
| `CODEX_EFFORT` | Codex default | `minimal｜low｜medium｜high` |

Status strings on stdout: `CODEX_OK`, `CODEX_NOT_INSTALLED`, `CODEX_AUTH_ERROR`,
`CODEX_QUOTA_ERROR`, `CODEX_TIMEOUT`, `CODEX_ERROR`, `CODEX_FORMAT_WARNING`.

`CODEX_FORMAT_WARNING` means the response broke its output contract (missing
`VERDICT:` first line, missing severity tag, non-sequential finding numbers,
over 3,000 characters, or more than 7 bullets). Re-ask instead of guessing the
verdict — except for a lone length warning, which is safe to accept.

### `claude_ask.sh` (Codex host)

The reciprocal Codex entrypoint calls Claude only through
`platforms/codex/verify/scripts/claude_ask.sh`:

```bash
claude_ask.sh check
CROSSCHECK_REMOTE_APPROVED=1 claude_ask.sh new -C <repo> "prompt"
CROSSCHECK_REMOTE_APPROVED=1 claude_ask.sh resume <session-uuid> -C <repo> "follow-up"
```

- `check` is local-only and verifies Claude login plus required commands.
- `new` and `resume` refuse to run without the task-scoped
  `CROSSCHECK_REMOTE_APPROVED=1` gate.
- Bubblewrap mounts only the target repository (read-only), current Git evidence
  (read-only), and the current session's isolated home (writable). Host
  credentials, unrelated repositories, and older review sessions are absent.
- Claude receives only `Read`, `Glob`, and `Grep`; mutation, Bash, workflow,
  subagent, and external-tool entrypoints are disabled.
- The auth secret is passed through a one-use file descriptor. It is not mounted
  into the sandbox or inherited as a secret environment variable.

| Env var | Default | Meaning |
|---|---|---|
| `CROSSCHECK_REMOTE_APPROVED` | unset | must be `1` for each approved Claude run |
| `CROSSCHECK_BASE_SHA` | `HEAD` | baseline for the precomputed review diff |
| `CROSSCHECK_MAX_CHARS` | `6000` | stdout truncation limit |
| `CROSSCHECK_TIMEOUT` | `900` | per-call ceiling, seconds |
| `CROSSCHECK_LOG_DAYS` | `14` | evidence, raw-log, and session retention |
| `CROSSCHECK_STATE_DIR` | `~/.cache/claude-crosscheck` | owner-only state root, outside the reviewed repo |
| `CLAUDE_MODEL` | Claude default | model override |
| `CLAUDE_EFFORT` | Claude default | effort override |

Status strings on stdout: `CLAUDE_OK`, `CLAUDE_NOT_INSTALLED`,
`CLAUDE_PERMISSION_REQUIRED`, `CLAUDE_AUTH_ERROR`, `CLAUDE_QUOTA_ERROR`,
`CLAUDE_TIMEOUT`, `CLAUDE_ERROR`, `CLAUDE_FORMAT_WARNING`.

---

## unit-test

Shared by Claude and Codex through the same host-neutral skill source.
The active host runs the tests and never calls the counterpart or another model.

- **Gate.** After a code change, the skill offers to run the tests and proceeds
  only on approval. Invoking it directly counts as approval. External DB,
  network, runtime, and performance checks are excluded and require a separate
  verification step with its own permission.
- **Scope.** Changed functions from `git diff HEAD`, classified as pure logic /
  local fixtures / external verification. Unit testing stays local; DB, network,
  runtime, and performance checks are routed to a separate verification step.
- **Angles.** happy path, boundary, empty·null·missing, error path,
  ordering·determinism, before/after equivalence, side effects. Angles that do
  not apply are skipped and named as skipped in the report.
- **Efficiency.** Focused tests run first. One full-suite owner runs on the final
  stable change; an official build/release wrapper owns that gate when it already
  runs the suite, preventing duplicate full runs. Proven baseline failures are
  recorded once instead of rerun after every edit.
- **Output.** `<project>/test/UNITTEST_<date>_<topic>.md`, written in your
  language. Unit counts are validated against case rows, reports roll over at
  300 lines or a changed objective, and external checks never enter unit totals.
  Script location is resolved in three steps: project rule docs → an existing
  test directory → create `test/scripts/`.

---

## Development

```bash
bash tests/codex_ask.test.sh    # fake Codex CLI; no API calls
bash tests/claude_ask.test.sh   # fake Claude CLI; no API calls
bash tests/claude_sandbox.test.sh # real Bubblewrap boundary; no API calls
bash tests/review_git.test.sh   # temporary local Git repository
bash tests/unit_test_skill.test.sh # shared host-neutral unit-test contract
```

```
.claude-plugin/     plugin.json + marketplace.json
skills/crosscheck/  SKILL.md + scripts/codex_ask.sh
skills/unit-test/   SKILL.md + scripts/validate_report.py
platforms/codex/    reciprocal Codex host entrypoint + read-only wrappers
tests/              wrappers + sandbox/Git boundaries + shared unit-test contract
```

## License

MIT — see [LICENSE](LICENSE).
