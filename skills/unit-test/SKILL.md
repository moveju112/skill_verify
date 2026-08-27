---
name: unit-test
description: Use right after Codex or Claude finishes modifying code to run approval-gated multi-angle unit tests. Also triggered directly by "단위 테스트", "유닛테스트", "테스트 돌려", "다방면 테스트", "테스트 문서 정리", and the English equivalents "unit test", "run the tests", "multi-angle tests", "write up the test results", and "/unit-test". The active host runs tests locally without calling the counterpart or another LLM. Writes a result report to the project's test directory in the user's language. Not for E2E/integration suites or performance benchmarks.
---

# unit-test — multi-angle unit testing after code changes

The active host designs, runs, and documents unit tests for freshly changed code.
Use the runtime identity supplied by the current session; never infer it from skill paths.
Host-local only: never call the counterpart, crosscheck scripts, or another LLM.
Respond in the language the user writes in — Korean request, Korean output; English request, English output.
The report follows that same language. This rule document stays English regardless.

## 0. Gate — always ask first

- After Codex or Claude finishes a code modification, offer, in the user's language:
  **"단위 테스트를 진행할까요? (변경: <files>)"** / **"Want me to run unit tests? (changed: <files>)"**
- Run ONLY when the user approves. No approval → stop, no test artifacts.
- If the user invoked the skill directly ("테스트 돌려", "run the tests"), that IS the approval — skip the question.
- DB/network-touching tests need a separate explicit permission line in the offer
  (e.g. "dev DB 접속이 필요합니다 — 진행할까요?" / "This needs a dev DB connection — proceed?").
  Never touch remote resources silently.

## 1. Scope — what to test

- `git diff HEAD` (or the session's edit list) → enumerate changed functions/methods.
- Classify each unit: pure logic (testable standalone) / needs fixtures / needs DB.
- Prefer pure-logic units first; they run without any permission.
- Skip generated files, comments-only changes, config values.

## 2. Design — multi-angle case matrix

Pick every applicable angle per unit (skip N/A ones, say so in the report):

| Angle | What it catches |
|---|---|
| happy path | basic contract |
| boundary | 0 / max / off-by-one / time-second edges |
| empty·null·missing | `[]`, `null`, absent keys, no rows |
| error path | invalid input, enum tryFrom fail, exception contract |
| ordering·determinism | sort stability, map-vs-single result order |
| before/after equivalence | refactor: old logic vs new logic on same inputs |
| side effects | state mutation, cache pollution across calls |

- For refactors, equivalence is the top priority: replicate the OLD logic in the
  test as an oracle and diff outputs over a generated input grid.
- Boundary values come from the code (constants, `E_`-style config), not guesses.

## 3. Run

- Prefer the project's existing test framework (`phpunit`, `jest`, `pytest`, `go test`…).
- None available → standalone assert scripts (`php -r`/file with `assert()`, exit code ≠ 0 on fail).
- Script location — resolve in THIS order, stop at first hit:
  1. Test path stated in project rule docs (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` …) — e.g. hnote → `tools/test/`.
  2. Existing test dir auto-detect: `tests/` → `test/` → `tools/test/` → `spec/` → `__tests__/`,
     cross-checked with framework config (`phpunit.xml` testsuite dir, `package.json` test script, `pytest.ini`/`pyproject.toml` testpaths).
  3. Neither exists → create `<project>/test/scripts/`.
- The resolved script dir affects scripts ONLY — the result report stays in `<project>/test/` (step 4) regardless.
- Isolate class dependencies: include only the needed enum/util files instead of full bootstrap
  when the framework bootstrap requires env constants.
- Run everything; capture per-case PASS/FAIL and actual values. Never fake a result —
  a case that could not run is reported as SKIP with the reason.

## 4. Report — `<project>/test/`

- Write `<project>/test/UNITTEST_<YYYYMMDD>_<topic>.md` (create `test/` if absent).
- Written in the user's language, dyslexia-friendly (one sentence per line, short paragraphs).
  Sections (Korean heading / English heading — use one set, matching the report language):
  1. 요약 / Summary — total PASS/FAIL/SKIP counts, one-line conclusion
  2. 대상 / Scope — changed files and functions (file:line)
  3. 케이스 표 / Case table — | # | angle | input | expected | actual | verdict |
  4. 실패 상세 / Failures — reproduction command and cause, failed cases only
  5. 미커버 위험 / Uncovered risk — areas skipped (DB needed, etc.) and why
  6. 환경 / Environment — runtime version, commands run, date
- Multiple runs on the same topic → append a dated section to the existing file, don't overwrite history.
- The report file stays; whether to commit it is the user's call (never auto-commit project repos).

## 5. Cleanup

- Delete task-only test scripts after the run if project rules demand it (hnote does);
  keep them only if the user asks to keep, and note the kept path in the report.
- Report failures honestly in chat: FAIL count first, then the report path.
