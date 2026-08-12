---
name: crosscheck
description: Use when the user wants Claude↔Codex cross-verification ping-pong — both analyze independently (blind), exchange findings, merge conclusions, Claude implements, Codex checks completion. Supports flexible modes (analyze-only / plan-only / full / verify-only). Triggers — "크로스체크", "codex 교차검증", "코덱스랑 핑퐁", "codex 리뷰 받아", "교차검증하고 작업해", "codex한테 물어봐", "둘이 의견 취합해", "/crosscheck". Token-leak-safe — every Codex call goes through scripts/codex_ask.sh which returns only the truncated final verdict; never call codex exec directly, never paste file contents or diffs into prompts.
---

# Codex 크로스체크 (crosscheck)

Claude와 Codex가 **각자 독립 분석**하고, 결과를 교환·취합한다.
합의된 결론으로 Claude가 작업하고, 완료 여부는 Codex가 체크한다.
**코딩 주체는 항상 Claude다. Codex는 독립 분석자 + 검증자다.**

## 모드 — 요청에서 판별, 애매하면 full

| 모드 | 트리거 예 | 실행 단계 |
|---|---|---|
| `analyze` | "둘이 의견 취합해줘", "교차 분석만" | A |
| `plan` | "핑퐁해서 계획만 줘", "계획서 뽑아" | A + B |
| `full` (기본) | "교차검증하고 작업해" | A + B + C + D |
| `verify` | "다 됐는지 codex 체크", "이 변경 검증해" | D |

- 단계는 유동 조합이다. 사용자가 중간에 멈추면 그 단계 산출물로 종료.
- 보고 상세도도 사용자 요청을 따른다. "결과물만" 이라면 최종 결과 + 한 줄 요약만.

## 토큰 누수 방지 철칙 (위반 금지)

1. codex 호출은 **반드시 `scripts/codex_ask.sh` 경유**. `codex exec` 직접 호출 금지.
   - 스크립트가 최종 메시지만 최대 6,000자로 잘라 반환한다. 원 로그는 컨텍스트에 안 들어온다.
2. codex 프롬프트에 **파일 내용·diff 전문을 붙여넣지 않는다.**
   - 경로와 라인 범위만 준다. codex는 read-only 샌드박스로 repo를 직접 읽는다.
   - 구현 리뷰는 "`git diff HEAD`를 직접 실행해 검토하라"고 지시한다.
3. codex에 보내는 요약(분석·계획)은 **15줄 이내**. 문서 전문을 보내지 않는다.
4. 원 로그(`~/.cache/codex-crosscheck/*.jsonl`)를 Read로 통째로 읽지 않는다.
   - 디버깅 필요 시 grep으로 해당 줄만 뽑는다.
5. 라운드 캡: 분석 대조 2, 계획 3, 완료 체크 2.
   - 캡 도달 시 Claude가 재량으로 결정하고, 이견을 최종 보고에 기록한다.

## 스크립트 사용법

> `scripts/` 경로는 이 스킬 디렉터리 기준이다. 실행 전 절대경로로 바꾼다 (`${CLAUDE_PLUGIN_ROOT}/skills/crosscheck/scripts/codex_ask.sh`).

```bash
# 새 세션 시작 (작업 repo를 -C로 지정)
codex_ask.sh new -C /path/to/repo "질문"

# 세션 이어서 핑퐁 (SESSION: 줄에 찍힌 ID 사용, 없으면 last)
# resume은 -C 불필요 — cwd·샌드박스가 원 세션을 따라간다
codex_ask.sh resume <세션ID> "반론/후속 질문"

# 긴 프롬프트는 stdin으로
echo "..." | codex_ask.sh new -C /path/to/repo -
```

- stdout 첫 줄 `SESSION: <id>` — 다음 resume에 쓴다.
- 응답 첫 줄은 항상 `VERDICT: AGREE|DISAGREE|NEED_INFO` (스크립트가 형식을 강제 부착).
- 환경변수: `CROSSCHECK_MAX_CHARS`(기본 6000), `CODEX_MODEL`, `CROSSCHECK_SANDBOX`(기본 read-only).

## Phase 0 — 게이트

사소한 작업(오타 수정, 1파일 소규모 변경)이면 크로스체크 생략을 제안하고 바로 구현한다.
크로스체크는 분석·설계 판단이 갈릴 수 있는 작업에만 쓴다.

## Phase A — 독립 교차 분석 (blind, 대조 최대 2라운드)

핵심: **둘이 같은 질문을 각자 조사한다. 서로의 결과를 보기 전까지는 blind.**

1. Claude가 스스로 분석한다 (코드 조사·grep 등). 결론을 10줄 이내로 메모.
2. **같은 질문**을 codex에 `new` 세션으로 보낸다.
   - ★ Claude의 분석 결과를 프롬프트에 넣지 않는다. 앵커링되면 교차검증이 무의미하다.
   - 프롬프트 틀: `"<질문>. 관련 코드를 직접 조사해 근거와 함께 답하라. 시작점: <경로 힌트>"`
3. 두 분석을 대조한다 — 일치점 / 불일치점 목록 작성.
4. **불일치점만** `resume`으로 들이민다:
   ```
   내 독립 분석은 이렇다: <불일치 항목 요약>.
   네 분석과 다르다. 각자 근거(파일:라인)를 대조해 어느 쪽이 맞는지 판정하라.
   ```
5. 최대 2라운드 대조 후 통합 결론 확정. 미해소 항목은 이견으로 기록.
6. `analyze` 모드면 통합 결론 보고 후 종료.

## Phase B — 계획 합의 (최대 3라운드)

1. Phase A 통합 결론을 기반으로 Claude가 계획 작성 — 목표·변경 파일·접근 방식, **15줄 이내**.
2. Phase A 세션에 `resume`으로 전송 (분석 맥락 재사용):
   ```
   합의된 분석 위에서 계획이다: [계획 요약]
   놓친 엣지케이스, 더 단순한 대안, 기존 코드와의 충돌을 지적하라.
   ```
3. VERDICT 판정:
   - `AGREE` — 다음 단계로.
   - `NEED_INFO` — 질문에 답해 `resume` 재전송.
   - `DISAGREE` — 수용할 지적은 계획에 반영, 반박할 것은 근거와 함께 `resume` 재질문.
4. 3라운드 후에도 `DISAGREE`면 Claude 재량 결정 + 이견 기록.
5. `plan` 모드면 합의된 계획서 보고 후 종료.

## Phase C — 구현

합의된 계획대로 Claude가 코딩한다. 세션의 기존 코딩 규칙 전부 적용.

## Phase D — 완료 체크 (최대 2라운드)

"작업이 다 됐는가"를 codex가 판정한다.

1. **새 세션**으로 요청 — 분석·계획 세션을 잇지 않는다 (앵커링 없는 새 시선).
   ```
   codex_ask.sh new -C <repo> "git diff HEAD를 직접 실행해 이 변경을 검증하라.
   요구사항: <합의된 계획 요점 3줄 이내>.
   ① 요구사항 충족 여부 항목별 판정 ② 버그·누락 케이스·회귀 위험 지적."
   ```
2. `DISAGREE` 지적 중 타당한 것은 수정하고 같은 세션 `resume`으로 재검.
3. 2라운드 캡. 잔여 이견은 기록.

## Phase E — 최종 보고 (모드별 산출물)

- `analyze`: 통합 결론 + 일치/불일치/미해소 목록.
- `plan`: 합의된 계획서 + 라운드 요약.
- `full`: 결과 요약 + VERDICT 흐름 (예: 분석 대조 1R, 계획 DISAGREE→AGREE 2R, 완료 체크 AGREE 1R).
- 공통: 수용한 지적 / 반박·기각한 지적 / 미합의 이견을 구분해 한 줄씩.
- 사용자가 "결과만" 원하면 산출물 + 한 줄 요약으로 축약.
