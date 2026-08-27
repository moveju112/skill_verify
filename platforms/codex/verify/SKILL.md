---
name: verify
description: Use in Codex for evidence-based local verification, or for explicit Claude↔Codex crosschecks where Codex is the host and Claude is the independent reviewer. Local triggers include "검증해줘", "다 됐는지 확인", "verify", and "review this change". Crosscheck triggers include "클로드랑 크로스체크", "Claude 교차검증", "클로드 리뷰 받아", "cross-check with Claude", and "ask Claude to review". Multi-angle unit-test requests belong to the shared unit-test skill. Generic verification stays local and never calls an external LLM.
---

# Verify

Verify from the current source of truth.

## Route

- **Local verify:** For ordinary verification requests, inspect and test locally. Never call an external LLM.
- **Claude crosscheck:** Only when the user explicitly asks to involve Claude in this task. Codex remains the host and owns implementation; Claude analyzes and verifies in read-only plan mode.
- Infer `analyze`, `plan`, `full`, or `verify` from the request. If implementation is excluded, stop before it. Otherwise an explicit request to crosscheck and do the work uses `full`.

## Shared rules

- Treat review-only requests as read-only. Fix findings only when the user asks for changes.
- Start with `git status --short` and the relevant diff or stated baseline.
- Trace callers, contracts, authorization, state changes, and cache or persistence effects before judging completion.
- Confirm each finding at the cited file and reachable call path. Do not accept another agent's claim without checking it.
- Run the smallest existing local checks that cover the change. Prefer the project's test command; use syntax or build checks only when they prove the relevant property.
- A direct request to run tests is approval for local tests. Ask separately before DB, network, remote, destructive, or service-changing checks.
- Never call `codex`, `codex exec`, or `codex_ask.sh` from this Codex entrypoint.
- A generic "검증해줘" is not permission to call Claude. An explicit task-scoped request such as "클로드랑 크로스체크해줘" authorizes Claude calls only for that crosscheck run.

## Claude call boundary

All Claude calls must use `scripts/claude_ask.sh`; never invoke `claude -p` directly.
Resolve that path against this `SKILL.md` directory before the first call and use the resulting absolute path from any target repository.

- Run `claude_ask.sh check` before the first call. It checks Claude, Bubblewrap, local dependencies, and authentication without a model request.
- For `new` and `resume`, set `CROSSCHECK_REMOTE_APPROVED=1` on that process only after explicit task-scoped permission.
- Give paths and line ranges, not file contents or full diffs. Claude reads `/workspace` through a restricted read-only tool allowlist and a read-only OS mount.
- Keep summaries sent to Claude at 15 lines or fewer.
- Never read raw files under `~/.cache/claude-crosscheck` wholesale. They can contain repository content.
- Use a caller timeout of at least 930 seconds; the wrapper stops at 900 seconds by default.
- Start a new session after three rounds or a topic change. Never resume an implicit "latest" session.
- The wrapper starts Claude with user/project customizations and subagents disabled. Admin-managed Claude policy can still apply. Do not ask the reviewer to invoke Codex or another model.
- Claude receives only `Read`, `Glob`, and `Grep`; Bash, workflows, subagents, external tools, and mutation tools are unavailable.
- Bubblewrap exposes the target repository read-only at `/workspace`, the current evidence read-only at `/evidence`, and only the current Claude session home as writable. The host user home, unrelated repositories, credentials, and older crosscheck sessions are not mounted.
- Authentication enters through a one-use file descriptor, not a mounted credential file or inherited secret environment variable.
- The wrapper runs the bundled `review_git.sh` locally first and puts status, HEAD, diff, and untracked-file artifacts in the current owner-only evidence directory. Set `CROSSCHECK_BASE_SHA` to the recorded base commit when it is not `HEAD`.
- Diff does not contain untracked file contents. Claude must read every path in the untracked artifact directly from the target repository before deciding completion.

```bash
# 먼저 이 SKILL.md 기준 절대경로로 변환
CLAUDE_ASK=/absolute/skill/path/scripts/claude_ask.sh

# 프리플라이트
"$CLAUDE_ASK" check

# 새 검토 세션
CROSSCHECK_REMOTE_APPROVED=1 CROSSCHECK_BASE_SHA=<base-commit> \
    "$CLAUDE_ASK" new -C /path/to/repo "질문"

# 명시적인 세션만 재개
CROSSCHECK_REMOTE_APPROVED=1 "$CLAUDE_ASK" resume <session-uuid> -C /path/to/repo "후속 질문"
```

The first line is `SESSION: <uuid>`. Save that exact UUID and pass it to the next explicit `resume` call. The verdict starts with `VERDICT: AGREE|DISAGREE|NEED_INFO`.
If the wrapper returns `CLAUDE_PERMISSION_REQUIRED`, `CLAUDE_AUTH_ERROR`, `CLAUDE_QUOTA_ERROR`, `CLAUDE_TIMEOUT`, or `CLAUDE_FORMAT_WARNING`, follow that status rather than guessing a verdict.

## Crosscheck workflow

1. **Gate:** Record `git rev-parse HEAD` and `git status --short`. Run the wrapper preflight.
2. **Blind analysis:** Before investigating, fix the Claude prompt to the user's question and path hints without any Codex conclusion.
   - When the execution tool provides a live-session handle, start `claude_ask.sh new` with a short initial yield and retain that exact handle.
   - While Claude runs, Codex investigates independently and records a concise conclusion without changing the in-flight prompt or sending intermediate findings.
   - Until Codex's conclusion is recorded, treat an early completion notification only as a ready signal; do not poll, collect, read, or act on Claude's output.
   - Collect the same live session's result and `SESSION:` UUID before comparison, then send only disagreements back by finding number.
   - Never fire-and-forget or attach to an implicit latest session.
   - If live execution is unavailable, use the original foreground sequence after Codex's analysis. If collection loses the session or output, retry once in the foreground with the same pre-fixed prompt.
3. **Plan agreement:** Codex drafts a plan of at most 15 lines. Ask Claude for missed edge cases, simpler alternatives, and conflicts with existing code. Cap analysis at two comparison rounds and planning at three rounds; record unresolved dissent.
4. **Implementation:** In `full` mode, Codex implements the agreed plan under the user's existing permissions. Claude never edits.
5. **Completion check:** Start a fresh Claude session. Ask it to inspect `git diff <base>` and `git status --short`, quote the original requirement in at most three lines, and judge requirement coverage, regressions, and unverified risks. Cap formal review at two rounds; one confirmation-only pass is allowed after applying the final accepted finding.

Before accepting a Claude finding, read its cited line, trace the reachable call flow, and reproduce the issue when practical.
Reject or rebut unsupported findings instead of changing code to satisfy them.

If Claude becomes unavailable during `full` mode, continue locally and report that the remaining crosscheck phases were not performed.
If the user's request was analysis-only or verify-only, stop because a solo result would not satisfy the explicit crosscheck request.

## Report

For local verification, lead with `PASS`, `FAIL`, or `PARTIAL`.
For crosscheck, report the merged conclusion, round flow, accepted findings, rebutted findings, and unresolved dissent.

Include only:

1. Findings ordered by severity with `file:line` evidence.
2. Checks actually run and their results.
3. Unverified risks or skipped checks and why.

Do not call work tested when only static inspection or syntax checks ran.
