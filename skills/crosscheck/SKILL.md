---
name: crosscheck
description: Use when the user wants Claude↔Codex cross-verification ping-pong — both analyze independently (blind), exchange findings, merge conclusions, Claude implements, Codex checks completion. Supports flexible modes (analyze-only / plan-only / full / verify-only). Triggers — "크로스체크", "codex 교차검증", "코덱스랑 핑퐁", "codex 리뷰 받아", "교차검증하고 작업해", "codex한테 물어봐", "둘이 의견 취합해", and the English equivalents "crosscheck", "cross-check with codex", "ping-pong with codex", "get a codex review", "ask codex", "have codex verify this", "merge both opinions", "/crosscheck". Korean and English triggers are equivalent; reply in whichever language the user writes. Token-leak-safe — every Codex call goes through scripts/codex_ask.sh which returns only the truncated final verdict; never call codex exec directly, never paste file contents or diffs into prompts.
---

# Codex Crosscheck (crosscheck)

> Response language — follow the language the user writes in. Korean request, report in Korean; English request, report in English.
> This rule document is written in English; that has no bearing on the language of the output delivered to the user.

Claude and Codex each **analyze independently**, then exchange and merge results.
Claude implements the agreed conclusion; Codex checks whether it is done.
**Claude is always the one coding. Codex is an independent analyst + verifier.**

## Modes — infer from the request; when ambiguous, use full

| Mode | Trigger examples | Phases run |
|---|---|---|
| `analyze` | "둘이 의견 취합해줘", "교차 분석만" / "just cross-analyze", "merge both opinions only" | A |
| `plan` | "핑퐁해서 계획만 줘", "계획서 뽑아" / "ping-pong a plan only", "plan but do not implement" | A + B |
| `full` (default) | "교차검증하고 작업해" / "cross-check it and do the work" | A + B + C + D |
| `verify` | "다 됐는지 codex 체크", "이 변경 검증해" / "have codex check it is done", "verify this change" | D |

- Trigger examples are illustrative, not exhaustive; Korean and English phrasings are equivalent. Match on intent, not wording.
- Before falling back to `full`, check whether the request excludes implementation ('analysis only', 'plan only', 'don't change code').
  Only default to `full` when implementation is genuinely implied.
- Phases combine freely. If the user stops midway, end with that phase's deliverable.
- Report detail follows the user's request too. If they say "결과물만" / "just the deliverable", give the final result + a one-line summary only.

## Token-leak prevention (MUST NOT violate)

1. Codex calls MUST go **through `scripts/codex_ask.sh`**. NEVER invoke `codex exec` directly.
   - The script returns only the final message, truncated to 6,000 chars. Raw logs never enter context.
2. NEVER paste file contents or a full diff into a codex prompt.
   - Give paths and line ranges only. Codex reads the repo directly in a read-only sandbox.
   - For implementation review, instruct it to run `git diff <기준SHA>` and `git status --short` itself and review from that.
3. Summaries sent to codex (analysis, plan) MUST be **15 lines or fewer**. Never send a full document.
4. NEVER Read the raw logs (`~/.cache/codex-crosscheck/*.jsonl`) whole.
   - When debugging, grep out only the line you need.
   - Logs retain, verbatim, the file contents codex read. The script creates them owner-only via `umask 077` and
     auto-deletes anything past `CROSSCHECK_LOG_DAYS` (default 14 days).
5. **The caller MUST set the Bash timeout — `timeout: 930000` (930s).**
   - The script's internal cap is 900s (`CROSSCHECK_TIMEOUT`). A shorter caller timeout kills codex from the outside,
     no final response file is written, and that round's work is discarded entirely.
   - Measured: median duration of a successful call 132s, max 468s. Bash's default 120s kills half of them.
6. Round caps: analysis comparison 2, planning 3, completion check 2 (formal review).
   - On reaching a cap, Claude decides at its discretion and records the dissent in the final report.
   - Exception: immediately after accepting and applying the previous round's findings, **one confirmation-only pass** is allowed outside the cap (see Phase D).
     A cheap pass that stops the last fix from going unverified.
7. **Session-swap rule** — `resume` resends the entire thread every time (measured: 4,489,268 input tokens for one confirmation call).
   Switch to a `new` session after more than 3 rounds in the same session, or when the topic changes.

## Script usage

> The `scripts/` path is relative to this skill directory. Convert it to an absolute path before running (`${CLAUDE_PLUGIN_ROOT}/skills/crosscheck/scripts/codex_ask.sh`).

```bash
# 새 세션 시작 (작업 repo를 -C로 지정)
codex_ask.sh new -C /path/to/repo "질문"

# 세션 이어서 핑퐁 (SESSION: 줄에 찍힌 UUID만 — UUID 형식이 아니면 스크립트가 거부한다)
# resume은 -C 불필요 — cwd·샌드박스가 원 세션을 따라간다
codex_ask.sh resume <세션ID> "반론/후속 질문"

# 긴 프롬프트는 stdin으로
echo "..." | codex_ask.sh new -C /path/to/repo -
```

- Call example: `codex_ask.sh new -C <repo> "질문"` — **give the Bash tool `timeout` 930000.**
- First stdout line `SESSION: <id>` — use it for the next resume.
  On `SESSION: UNKNOWN`, NEVER resume (the script rejects it). Re-supply the context you want continued as a summary to a `new` session.
  Resuming the globally latest session (`--last`) is not supported — it prevents attaching to someone else's session during parallel runs.
- If `CODEX_FORMAT_WARNING` comes attached, the response violated the format. Do not guess the verdict; re-ask the same question.
  Checked items: first-line VERDICT / severity tag on findings / finding-number continuity / over 3000 chars / over 7 bullets.
  When only the length warning fires on its own and the content is valid, use it as-is; no re-ask needed.
- The first response line is always `VERDICT: AGREE|DISAGREE|NEED_INFO` (the script force-attaches the format).
- DISAGREE findings arrive numbered as `#N [blocking|minor]`.
  In resume, **reference by number only** — like `"#1 반박: <근거>, #2 수용·수정함"` — never restate the finding (saves tokens + keeps the comparison exact).
  Review blocking findings for an immediate fix; minor ones may be recorded and left to the user's judgment.
- Env vars: `CROSSCHECK_MAX_CHARS` (chars, default 6000), `CROSSCHECK_TIMEOUT` (seconds, default 900),
  `CROSSCHECK_LOG_DAYS` (default 14), `CODEX_MODEL`, `CODEX_EFFORT` (minimal|low|medium|high), `CROSSCHECK_SANDBOX` (default read-only).
- Failure codes: `CODEX_TIMEOUT` (cap exceeded — narrow the question and retry) / `CODEX_AUTH_ERROR` / `CODEX_QUOTA_ERROR` / `CODEX_ERROR`.
- Effort guidance: analysis, planning, and completion checks follow the codex default (high); lower only simple confirmation questions to `CODEX_EFFORT=medium`.

## Phase 0 — Gate

1. For trivial work (typo fix, small single-file change), propose skipping the crosscheck and implement directly.
   Crosscheck is for work where analysis or design judgment can diverge.
2. **Record the base commit**: before starting, capture `git rev-parse HEAD` and `git status --short`.
   It is the reference point for Phase D's verification scope — the diff stays tight even if intermediate commits land or new files remain untracked.
3. **Preflight**: run `codex_ask.sh check` before the first codex call (costs no tokens).
   - `CODEX_OK` — proceed. The `CODEX_BIN`/`CODEX_VERSION` that follow are diagnostic
     (they let you trace, after the fact, a stale codex on PATH swallowing a flag — proceed even with empty values).
   - `CODEX_AUTH_ERROR` / `CODEX_NOT_INSTALLED` — crosscheck impossible. Go to the fallback below.

### Fallback — when codex is unavailable

Claude is the main. Work does not stop without codex.

- Tell the user the cause in one line (login expired → guide to `codex login` / quota exceeded → wait for reset).
- Continue with Claude alone, but **state "crosscheck not performed" in the final report.**
- Same fallback if a mid-run call dies with `CODEX_QUOTA_ERROR`/`CODEX_AUTH_ERROR`.
  Verdicts already received stay valid — run only the remaining phases solo.
- When the user asked for the crosscheck itself (analyze/verify mode), going solo is pointless: stop and ask.

## Phase A — Independent cross-analysis (blind, up to 2 comparison rounds)

Core: **both investigate the same question separately. Blind until they see each other's results.**

1. Claude analyzes on its own (code inspection, grep, etc.). Note the conclusion in 10 lines or fewer.
   - Blind integrity: **NEVER carry a past conclusion over as-is.** Memory and earlier session summaries are hypotheses only;
     re-establish the evidence from code this round. Flag any reused past conclusion in the final report.
2. Send **the same question** to codex in a `new` session.
   - ★ Do not put Claude's analysis into the prompt. Once anchored, the cross-verification is worthless.
   - Prompt template: `"<질문>. 관련 코드를 직접 조사해 근거와 함께 답하라. 시작점: <경로 힌트>"`
3. Compare the two analyses — write out the agreements / disagreements.
4. Push **only the disagreements** back via `resume`:
   ```
   내 독립 분석은 이렇다: <불일치 항목 요약>.
   네 분석과 다르다. 각자 근거(파일:라인)를 대조해 어느 쪽이 맞는지 판정하라.
   ```
5. After at most 2 comparison rounds, fix the merged conclusion. Record unresolved items as dissent.
6. In `analyze` mode, report the merged conclusion and stop.

## Finding-acceptance gate (shared by Phases A, B, D — MUST NOT violate)

A codex finding **is a hypothesis until verified.** Measured DISAGREE rate 15/23 — among those were rule misreads and scope errors.
Check in order before accepting one and changing code:

1. Read the cited `파일:라인` directly and confirm it matches the claim.
2. Check that code's call flow — whether the path is actually reachable.
3. Where possible, confirm the defect by eye with a minimal repro (a test or one log line).

- Fix only findings that pass 1–3. A finding that fails **is NOT fixed** — record it as dissent and rebut it with evidence.
- If a finding claims a project-rule violation, check the rule text — codex can misread the target repo's rules.

## Phase B — Plan agreement (up to 3 rounds)

1. On top of the Phase A merged conclusion, Claude writes the plan — goal, files to change, approach, **15 lines or fewer**.
2. Send it to the Phase A session via `resume` (reusing the analysis context):
   ```
   합의된 분석 위에서 계획이다: [계획 요약]
   놓친 엣지케이스, 더 단순한 대안, 기존 코드와의 충돌을 지적하라.
   ```
3. VERDICT handling:
   - `AGREE` — move to the next phase.
   - `NEED_INFO` — answer the question and re-send via `resume`.
   - `DISAGREE` — fold accepted findings into the plan; re-ask via `resume` with evidence for the ones you rebut (reference findings by `#N`).
4. Still `DISAGREE` after 3 rounds: Claude decides at its discretion + records the dissent.
5. In `plan` mode, report the agreed plan and stop.

## Phase C — Implementation

Claude codes to the agreed plan. All existing coding rules of the session apply.

## Phase D — Completion check (formal review, up to 2 rounds)

Codex judges whether "the work is done".

0. **Execution — background by default.** Fire Phase D calls with Bash `run_in_background: true`.
   A completion check takes hundreds of seconds; in foreground the session stalls for that whole time.
   - Foreground as an exception: the change is a small 1–2 files, or the user explicitly asked to wait.
   - **Collection contract**: after firing, wait for the completion notification. **NEVER close out full mode before collecting the result.**
     If collection itself fails (lost notification, lost output), retry once in foreground.
   - If the collected result is `CODEX_AUTH_ERROR`/`CODEX_QUOTA_ERROR`/`CODEX_TIMEOUT`, apply the existing fallback instead of retrying.
1. Request it in a **new session** — do not continue the analysis or planning session (a fresh view, unanchored).
   - **Name the changed paths to pin the diff scope** — stops unrelated working-tree changes from muddying verification.
   - For requirements, **quote the user's original request or the original review text first**. If the side being verified (Claude) writes the summary, it can be framed favorably.
   ```
   codex_ask.sh new -C <repo> "git diff <Phase 0 기준SHA> -- <대상 경로들> 과 git status --short 를
   직접 실행해 이 변경을 검증하라. 신규 파일은 untracked일 수 있으니 status로 확인해 함께 검토하라.
   대상 외 파일에 diff가 있으면 범위 밖으로 표시만 하라.
   요구사항: <사용자 원 요청 원문 인용, 3줄 이내>.
   ① 요구사항 충족 여부 항목별 판정 ② 버그·누락 케이스·회귀 위험 지적
   ③ 명시된 요구사항 외에 스스로 도출한 성공 기준 미달도 지적하라.

   탐색 축 — 이 변경에 실제 해당하는 축만 검사한다 (해당 없으면 건너뛰고 지어내지 않는다):
   인증·권한·신뢰경계 / 데이터 손실·중복·되돌릴 수 없는 상태 변경 / 롤백·재시도·부분 실패·멱등성 /
   경합·순서 가정·오래된 상태·재진입 / 빈값·null·타임아웃·의존성 열화 /
   버전 편차·스키마 드리프트·마이그레이션·호환성 / 실패를 가리는 관측 공백.

   지적 기준 — 각 지적은 네 가지에 답해야 한다: 무엇이 잘못될 수 있는가 / 왜 그 경로가 취약한가 /
   영향은 무엇인가 / 어떤 구체적 변경이 위험을 줄이는가.
   스타일·네이밍·근거 없는 추측은 지적하지 않는다.
   약한 지적 여러 개보다 강한 하나가 낫다. 안전해 보이면 그렇다고 말하고 지적을 만들지 마라."
   ```
2. Respond to `DISAGREE` findings by number — fix what you accept, re-review rebuttals with evidence via `resume` in the same session.
   e.g. `"#1 반박: <파일:라인 근거>. #2 수용해 수정했다. 재검하라."`
3. Formal review caps at 2 rounds. **If you fixed the previous findings at the cap, one confirmation-only pass** (outside the cap):
   - `resume` the same session with `CODEX_EFFORT=low` — `"직전 수정분(<파일:라인>)만 반영 여부 확인. 새 이슈 탐색 금지."`
   - Do not fix new findings raised here. Record them as dissent and only report them to the user.
4. Record remaining dissent.

## Phase E — Final report (deliverable per mode)

- `analyze`: merged conclusion + agreements/disagreements/unresolved list.
- `plan`: agreed plan + round summary.
- `full`: result summary + VERDICT flow (e.g. analysis comparison 1R, plan DISAGREE→AGREE 2R, completion check AGREE 1R).
- All modes: one line each, separating accepted findings / rebutted-or-rejected findings / unresolved dissent.
- If the user wants "결과만" / "just the result", condense to the deliverable + a one-line summary.
