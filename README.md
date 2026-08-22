# skill_verify

A Claude Code plugin (`verify`) that bundles two code-verification skills: an
adversarial cross-check against OpenAI Codex, and a multi-angle unit-test pass
run by Claude alone.

| Skill | Role |
|---|---|
| `verify:crosscheck` | Claude↔Codex ping-pong review. Claude designs and writes the code; Codex analyzes independently and verifies completion. |
| `verify:unit-test` | Approval-gated unit testing right after a code change, across 7 angles. Writes a report to `<project>/test/`. |

Both skills talk to the user in Korean. The rules and prompts are Korean; this
README is the English entry point.

## Install

```bash
claude plugin marketplace add moveju112/skill_verify
claude plugin install verify@verify
```

Inside a Claude Code session:

```
/plugin marketplace add moveju112/skill_verify
/plugin install verify@verify
```

## Requirements

- Claude Code with plugin support.
- `crosscheck` only: the [Codex CLI](https://github.com/openai/codex)
  (`npm i -g @openai/codex`), logged in (`codex login`). Without it the skill
  degrades to a documented Claude-only fallback instead of failing.
- `unit-test` has no external dependency.

## Usage

Say the trigger, or call the slash command:

| Intent | Say | Command |
|---|---|---|
| Cross-verify with Codex | "크로스체크", "codex 교차검증" | `/verify:crosscheck` |
| Unit-test the last change | "단위 테스트", "테스트 돌려" | `/verify:unit-test` |

---

## crosscheck

Claude and Codex analyze **independently and blind**, then exchange and merge
findings. Claude always owns the code; Codex is an independent analyst and
verifier, never an author.

### Modes

Picked from the request; ambiguous requests default to `full`.

| Mode | Phases | Example trigger |
|---|---|---|
| `analyze` | A | "둘이 의견 취합해줘" (cross-analysis only) |
| `plan` | A + B | "핑퐁해서 계획만 줘" (stop at the plan) |
| `full` | A + B + C + D | "교차검증하고 작업해" (default) |
| `verify` | D | "다 됐는지 codex 체크" (completion check only) |

- **A — blind analysis.** Both sides analyze without seeing each other's output.
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
- Follow-ups reference numbers only (`"#1 반박: <근거>, #2 수용·수정함"`) — never
  restate the finding. Cheaper, and it keeps the comparison exact.
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

---

## unit-test

Claude-only. It never calls Codex or any other external model.

- **Gate.** After a code change, the skill offers "단위 테스트를 진행할까요?" and
  runs only on approval. Invoking it directly counts as approval. Tests that
  touch a database or the network need their own explicit permission line.
- **Scope.** Changed functions from `git diff HEAD`, classified as pure logic /
  needs fixtures / needs DB. Pure logic goes first — it needs no permission.
- **Angles.** happy path, boundary, empty·null·missing, error path,
  ordering·determinism, before/after equivalence, side effects. Angles that do
  not apply are skipped and named as skipped in the report.
- **Output.** `<project>/test/UNITTEST_<date>_<topic>.md`, in Korean. Script
  location is resolved in three steps: project rule docs → an existing test
  directory → create `test/scripts/`.

---

## Development

```bash
bash tests/codex_ask.test.sh   # injects a fake codex + timeout; makes no API calls
```

```
.claude-plugin/     plugin.json + marketplace.json
skills/crosscheck/  SKILL.md + scripts/codex_ask.sh
skills/unit-test/   SKILL.md
tests/              wrapper test suite
```

## License

MIT — see [LICENSE](LICENSE).
