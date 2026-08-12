---
name: crosscheck
description: Use when the user wants Claude↔Codex cross-verification ping-pong — Claude designs/codes, Codex reviews, iterate until consensus, then Claude implements. Triggers — "크로스체크", "codex 교차검증", "코덱스랑 핑퐁", "codex 리뷰 받아", "교차검증하고 작업해", "codex한테 물어봐", "/crosscheck". Token-leak-safe — every Codex call goes through scripts/codex_ask.sh which returns only the truncated final verdict; never call codex exec directly, never paste file contents or diffs into prompts.
---

# Codex 크로스체크 (crosscheck)

Claude가 설계·코딩하고, Codex가 검증한다.
합의될 때까지 핑퐁, 합의 후 Claude가 구현한다.
**코딩 주체는 항상 Claude다. Codex는 검증만 한다.**

## 토큰 누수 방지 철칙 (위반 금지)

1. codex 호출은 **반드시 `scripts/codex_ask.sh` 경유**. `codex exec` 직접 호출 금지.
   - 스크립트가 최종 메시지만 최대 6,000자로 잘라 반환한다. 원 로그는 컨텍스트에 안 들어온다.
2. codex 프롬프트에 **파일 내용·diff 전문을 붙여넣지 않는다.**
   - 경로와 라인 범위만 준다. codex는 read-only 샌드박스로 repo를 직접 읽는다.
   - 구현 리뷰는 "`git diff HEAD`를 직접 실행해 검토하라"고 지시한다.
3. codex에 보내는 계획 요약은 **15줄 이내**. 설계 문서 전문을 보내지 않는다.
4. 원 로그(`~/.cache/codex-crosscheck/*.jsonl`)를 Read로 통째로 읽지 않는다.
   - 디버깅 필요 시 grep으로 해당 줄만 뽑는다.
5. 라운드 캡: **계획 3라운드, 구현 리뷰 2라운드.**
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

## 절차

### Phase 0 — 게이트

사소한 작업(오타 수정, 1파일 소규모 변경)이면 크로스체크 생략을 제안하고 바로 구현한다.
크로스체크는 설계 판단이 갈릴 수 있는 작업에만 쓴다.

### Phase 1 — 계획 합의 (최대 3라운드)

1. Claude가 계획 요약 작성 — 목표·변경 파일·접근 방식, **15줄 이내**.
2. `codex_ask.sh new -C <repo>` 로 전송. 프롬프트 틀:
   ```
   아래 계획을 검증하라. 관련 파일은 직접 읽어라: <경로 목록>
   [계획 요약]
   놓친 엣지케이스, 더 단순한 대안, 기존 코드와의 충돌을 지적하라.
   ```
3. VERDICT 판정:
   - `AGREE` — Phase 2로.
   - `NEED_INFO` — 질문에 답해 `resume` 재전송.
   - `DISAGREE` — 각 지적을 평가. 수용할 것은 계획에 반영, 반박할 것은 근거와 함께 `resume`으로 재질문.
4. 3라운드 후에도 `DISAGREE`면 Claude가 재량 결정. 이견 내용을 기록해 둔다.

### Phase 2 — 구현

합의된 계획대로 Claude가 코딩한다. 세션의 기존 코딩 규칙 전부 적용.

### Phase 3 — 구현 검증 (최대 2라운드)

1. **새 세션**으로 리뷰 요청 — 계획 세션을 잇지 않는다 (앵커링 없는 새 시선이 교차검증의 목적).
   ```
   codex_ask.sh new -C <repo> "git diff HEAD를 직접 실행해 이 변경을 리뷰하라.
   변경 의도: <1-2줄>. 버그·누락 케이스·회귀 위험만 지적하라."
   ```
2. `DISAGREE` 지적 중 타당한 것은 수정하고 같은 세션 `resume`으로 재검.
3. 2라운드 캡. 잔여 이견은 기록.

### Phase 4 — 최종 보고

- 결과 요약 + 라운드 수 + VERDICT 흐름 (예: 계획 DISAGREE→AGREE 2라운드, 구현 AGREE 1라운드).
- 수용한 지적 / 반박·기각한 지적 / 미합의 이견을 구분해 한 줄씩.
