---
name: unit-test
version: "1.1.0"
description: Use right after Claude finishes modifying code — proactively ASK the user "단위 테스트를 진행할까요?" and run ONLY on approval. Also triggered directly by "단위 테스트", "유닛테스트", "테스트 돌려", "다방면 테스트", "테스트 문서 정리", "/unit-test". Runs multi-angle unit tests (happy path / boundary / empty / error / ordering / before-after equivalence / side effects) using Claude only — never codex or other LLM agents. Writes a Korean result report to <project>/test/. Not this skill for E2E/integration suites or performance benchmarks.
---

# unit-test — multi-angle unit testing after code changes

Claude designs, runs, and documents unit tests for freshly changed code.
Claude-only: never call codex, crosscheck scripts, or any external LLM.
Respond to the user in Korean (all user-facing output and the report stay Korean).

## 0. Gate — always ask first

- After finishing a code modification, offer: **"단위 테스트를 진행할까요? (변경: <files>)"**
- Run ONLY when the user approves. No approval → stop, no test artifacts.
- If the user invoked the skill directly ("테스트 돌려"), that IS the approval — skip the question.
- DB/network-touching tests need a separate explicit permission line in the offer
  (e.g. "dev DB 접속이 필요합니다 — 진행할까요?"). Never touch remote resources silently.

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
- Korean, dyslexia-friendly (one sentence per line, short paragraphs). Sections:
  1. 요약 — 전체 PASS/FAIL/SKIP 수, 한 줄 결론
  2. 대상 — 변경 파일·함수 목록 (파일:라인)
  3. 케이스 표 — | # | 각도 | 입력 | 기대 | 실제 | 판정 |
  4. 실패 상세 — 실패 케이스만 재현 커맨드·원인 분석
  5. 미커버 위험 — DB 필요 등으로 SKIP한 영역과 사유
  6. 환경 — PHP/노드 버전, 실행 커맨드, 날짜
- Multiple runs on the same topic → append a dated section to the existing file, don't overwrite history.
- The report file stays; whether to commit it is the user's call (never auto-commit project repos).

## 5. Cleanup

- Delete task-only test scripts after the run if project rules demand it (hnote does);
  keep them only if the user asks to keep, and note the kept path in the report.
- Report failures honestly in chat: FAIL count first, then the report path.
