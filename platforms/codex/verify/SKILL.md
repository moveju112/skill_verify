---
name: verify
description: Use when the user asks Codex to verify, review, test, or confirm that a code change is complete. Inspect the real diff and call flow, run the smallest relevant local checks, and report evidence. Also triggers on "검증해줘", "다 됐는지 확인", "테스트 돌려", "verify", and "review this change". Do not use for performance optimization or implementation-only requests.
---

# Verify

Verify from the current source of truth.

## Rules

- Treat review-only requests as read-only. Fix findings only when the user asks for changes.
- Start with `git status --short` and the relevant diff or stated baseline.
- Trace callers, contracts, authorization, state changes, and cache or persistence effects before judging completion.
- Confirm each finding at the cited file and reachable call path. Do not accept another agent's claim without checking it.
- Run the smallest existing local checks that cover the change. Prefer the project's test command; use syntax or build checks only when they prove the relevant property.
- A direct request to run tests is approval for local tests. Ask separately before DB, network, remote, destructive, or service-changing checks.
- Never call `codex`, `codex exec`, `codex_ask.sh`, or another external LLM from this skill. For non-trivial work, use an available independent reviewer sub-agent and verify its evidence locally.
- Claude-Codex ping-pong remains Claude's `verify:crosscheck` workflow. If the user explicitly wants Claude called from Codex, obtain remote-access permission for that task first.

## Report

Lead with `PASS`, `FAIL`, or `PARTIAL`.

Include only:

1. Findings ordered by severity with `file:line` evidence.
2. Checks actually run and their results.
3. Unverified risks or skipped checks and why.

Do not call work tested when only static inspection or syntax checks ran.
