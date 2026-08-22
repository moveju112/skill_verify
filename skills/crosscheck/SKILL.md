---
name: crosscheck
description: Use when the user wants Claude↔Codex cross-verification ping-pong — both analyze independently (blind), exchange findings, merge conclusions, Claude implements, Codex checks completion. Supports flexible modes (analyze-only / plan-only / full / verify-only). Triggers — "크로스체크", "codex 교차검증", "코덱스랑 핑퐁", "codex 리뷰 받아", "교차검증하고 작업해", "codex한테 물어봐", "둘이 의견 취합해", and the English equivalents "crosscheck", "cross-check with codex", "ping-pong with codex", "get a codex review", "ask codex", "have codex verify this", "merge both opinions", "/crosscheck". Korean and English triggers are equivalent; reply in whichever language the user writes. Token-leak-safe — every Codex call goes through scripts/codex_ask.sh which returns only the truncated final verdict; never call codex exec directly, never paste file contents or diffs into prompts.
---

# Codex 크로스체크 (crosscheck)

> 응답 언어 — 사용자가 쓴 언어를 따른다. 한국어 요청이면 한국어, 영어 요청이면 영어로 보고한다.
> 아래 규칙 문서 자체는 한국어지만, 사용자에게 나가는 산출물 언어와는 무관하다.

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
   - 구현 리뷰는 "`git diff <기준SHA>`와 `git status --short`를 직접 실행해 검토하라"고 지시한다.
3. codex에 보내는 요약(분석·계획)은 **15줄 이내**. 문서 전문을 보내지 않는다.
4. 원 로그(`~/.cache/codex-crosscheck/*.jsonl`)를 Read로 통째로 읽지 않는다.
   - 디버깅 필요 시 grep으로 해당 줄만 뽑는다.
   - 로그에는 codex가 읽은 파일 내용이 그대로 남는다. 스크립트가 `umask 077`로 소유자 전용 생성하고
     `CROSSCHECK_LOG_DAYS`(기본 14일) 초과분을 자동 삭제한다.
5. **호출측 Bash 타임아웃을 반드시 지정한다 — `timeout: 930000`(930초).**
   - 스크립트 내부 상한이 900초(`CROSSCHECK_TIMEOUT`)다. 호출측이 더 짧으면 codex가 외부에서 죽어
     최종 응답 파일이 안 생기고 그 회차 작업이 전부 버려진다.
   - 실측: 성공 호출 지속시간 중앙값 132초, 최대 468초. Bash 기본 120초로는 절반이 죽는다.
6. 라운드 캡: 분석 대조 2, 계획 3, 완료 체크 2 (정식 리뷰 기준).
   - 캡 도달 시 Claude가 재량으로 결정하고, 이견을 최종 보고에 기록한다.
   - 예외: 직전 라운드 지적을 수용·수정한 직후에는 **확인 전용 패스 1회**를 캡 밖으로 허용 (Phase D 참조).
     마지막 수정분이 검증 안 된 채 종결되는 것을 막기 위한 저비용 패스다.
7. **세션 교체 기준** — `resume`은 스레드 전체를 매번 재전송한다(확인성 1회에 입력 4,489,268토큰 실측).
   같은 세션에서 3라운드를 넘겼거나 주제가 바뀌면 `new` 세션으로 갈아탄다.

## 스크립트 사용법

> `scripts/` 경로는 이 스킬 디렉터리 기준이다. 실행 전 절대경로로 바꾼다 (`${CLAUDE_PLUGIN_ROOT}/skills/crosscheck/scripts/codex_ask.sh`).

```bash
# 새 세션 시작 (작업 repo를 -C로 지정)
codex_ask.sh new -C /path/to/repo "질문"

# 세션 이어서 핑퐁 (SESSION: 줄에 찍힌 UUID만 — UUID 형식이 아니면 스크립트가 거부한다)
# resume은 -C 불필요 — cwd·샌드박스가 원 세션을 따라간다
codex_ask.sh resume <세션ID> "반론/후속 질문"

# 긴 프롬프트는 stdin으로
echo "..." | codex_ask.sh new -C /path/to/repo -
```

- 호출 예: `codex_ask.sh new -C <repo> "질문"` — **Bash 도구 `timeout`은 930000으로 준다.**
- stdout 첫 줄 `SESSION: <id>` — 다음 resume에 쓴다.
  `SESSION: UNKNOWN`이면 resume 금지(스크립트가 거부한다). 이어갈 맥락은 `new` 세션에 요약해 다시 준다.
  전역 최신 세션 이어가기(`--last`)는 지원하지 않는다 — 병렬 실행 중 남의 세션에 붙는 사고를 막기 위해서다.
- `CODEX_FORMAT_WARNING`이 붙어 오면 응답이 형식을 어긴 것이다. verdict를 추정하지 말고 같은 질문을 재요청한다.
  검사 항목: 첫 줄 VERDICT / 지적 심각도 표기 / 지적 번호 연속성 / 3000자 초과 / bullet 7개 초과.
  분량 초과 경고만 단독으로 뜬 경우는 내용이 유효하면 그대로 쓰고 재요청하지 않아도 된다.
- 응답 첫 줄은 항상 `VERDICT: AGREE|DISAGREE|NEED_INFO` (스크립트가 형식을 강제 부착).
- DISAGREE 지적은 `#N [blocking|minor]` 번호로 온다.
  resume에서 "#1 반박: <근거>, #2 수용·수정함"처럼 **번호로만 참조**한다 — 지적 내용 재서술 금지 (토큰 절약 + 대조 정확).
  blocking은 즉시 수정 검토, minor는 기록 후 사용자 판단에 맡겨도 된다.
- 환경변수: `CROSSCHECK_MAX_CHARS`(문자 수, 기본 6000), `CROSSCHECK_TIMEOUT`(초, 기본 900),
  `CROSSCHECK_LOG_DAYS`(기본 14), `CODEX_MODEL`, `CODEX_EFFORT`(minimal|low|medium|high), `CROSSCHECK_SANDBOX`(기본 read-only).
- 실패 코드: `CODEX_TIMEOUT`(상한 초과 — 질문 범위를 좁혀 재시도) / `CODEX_AUTH_ERROR` / `CODEX_QUOTA_ERROR` / `CODEX_ERROR`.
- effort 권장: 분석·계획·완료 체크는 codex 기본값(high)을 따르고, 단순 확인성 질문만 `CODEX_EFFORT=medium`으로 낮춘다.

## Phase 0 — 게이트

1. 사소한 작업(오타 수정, 1파일 소규모 변경)이면 크로스체크 생략을 제안하고 바로 구현한다.
   크로스체크는 분석·설계 판단이 갈릴 수 있는 작업에만 쓴다.
2. **기준 커밋 기록**: 작업 시작 전 `git rev-parse HEAD`와 `git status --short`를 남긴다.
   Phase D 검증 범위의 기준점이다 — 중간 커밋이 끼거나 신규 파일이 untracked로 남아도 diff가 새지 않는다.
3. **프리플라이트**: 첫 codex 호출 전 `codex_ask.sh check` 실행 (토큰 소모 없음).
   - `CODEX_OK` — 진행. 뒤따르는 `CODEX_BIN`/`CODEX_VERSION`은 진단용이다
     (PATH에 낡은 codex가 걸려 플래그가 안 먹는 사고를 사후 추적하려는 것 — 값이 없어도 진행한다).
   - `CODEX_AUTH_ERROR` / `CODEX_NOT_INSTALLED` — 크로스체크 불가. 폴백(아래)으로.

### 폴백 — codex 사용 불가 시

메인은 Claude다. codex가 없어도 작업은 멈추지 않는다.

- 사용자에게 원인을 한 줄로 알린다 (로그인 풀림 → `codex login` 안내 / 한도 초과 → 리셋 대기).
- Claude 단독으로 계속 진행하되, **최종 보고에 "크로스체크 미수행" 명시.**
- 진행 중 호출이 `CODEX_QUOTA_ERROR`/`CODEX_AUTH_ERROR`로 죽으면 같은 폴백.
  이미 받은 verdict까지는 유효 — 남은 단계만 단독 진행.
- 사용자가 크로스체크 자체를 목적으로 요청한 경우(analyze/verify 모드)는 단독 진행이 무의미하므로 중단하고 묻는다.

## Phase A — 독립 교차 분석 (blind, 대조 최대 2라운드)

핵심: **둘이 같은 질문을 각자 조사한다. 서로의 결과를 보기 전까지는 blind.**

1. Claude가 스스로 분석한다 (코드 조사·grep 등). 결론을 10줄 이내로 메모.
   - blind 무결성: **과거 결론을 그대로 가져오지 않는다.** 메모리·이전 세션 요약은 가설로만 쓰고
     근거는 이번 회차에 코드에서 다시 확보한다. 재사용한 과거 결론이 있으면 최종 보고에 표시한다.
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

## 지적 수용 게이트 (Phase A·B·D 공통, 위반 금지)

codex 지적은 **검증 전에는 가설이다.** 실측 DISAGREE 비율 15/23 — 그중 룰 오독·범위 착오도 있었다.
수용해 코드를 바꾸기 전 순서대로 확인한다:

1. 인용된 `파일:라인`을 직접 읽어 주장과 일치하는지 확인.
2. 그 코드의 호출 흐름을 확인 — 실제로 그 경로가 도달 가능한지.
3. 가능하면 최소 재현(테스트·로그 한 줄)으로 결함을 눈으로 확인.

- 1~3을 통과한 지적만 수정한다. 통과 못 한 지적은 **수정하지 않고 이견으로 기록**하고 근거와 함께 반박한다.
- 지적이 프로젝트 규칙 위반을 주장하면 규칙 원문을 확인한다 — codex는 대상 repo 규칙을 오독할 수 있다.

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
   - `DISAGREE` — 수용할 지적은 계획에 반영, 반박할 것은 근거와 함께 `resume` 재질문 (지적은 `#N` 번호로 참조).
4. 3라운드 후에도 `DISAGREE`면 Claude 재량 결정 + 이견 기록.
5. `plan` 모드면 합의된 계획서 보고 후 종료.

## Phase C — 구현

합의된 계획대로 Claude가 코딩한다. 세션의 기존 코딩 규칙 전부 적용.

## Phase D — 완료 체크 (정식 리뷰 최대 2라운드)

"작업이 다 됐는가"를 codex가 판정한다.

0. **실행 방식 — 기본 background.** Phase D 호출은 Bash `run_in_background: true`로 발사한다.
   완료 체크는 수백 초가 걸려 foreground면 그 시간 동안 세션이 멈춘다.
   - 예외로 foreground: 변경이 1~2파일 소규모이거나, 사용자가 대기를 명시한 경우.
   - **회수 계약**: 발사 후 완료 알림을 기다린다. **결과를 회수하기 전에 full 모드를 종결하지 않는다.**
     회수 자체가 실패하면(알림 유실·출력 소실) foreground로 1회 재시도.
   - 회수한 결과가 `CODEX_AUTH_ERROR`/`CODEX_QUOTA_ERROR`/`CODEX_TIMEOUT`이면 재시도가 아니라 기존 폴백을 적용한다.
1. **새 세션**으로 요청 — 분석·계획 세션을 잇지 않는다 (앵커링 없는 새 시선).
   - **변경 대상 경로를 명시해 diff 범위를 고정한다** — 작업 트리의 무관한 변경이 검증을 흐리는 것 방지.
   - 요구사항은 **사용자 원 요청·리뷰 원문을 우선 인용**한다. 검증받는 쪽(Claude)이 요약을 쓰면 유리하게 프레이밍될 수 있다.
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
2. `DISAGREE` 지적은 번호로 대응 — 수용분은 수정, 반박은 근거와 함께 같은 세션 `resume`으로 재검.
   예: `"#1 반박: <파일:라인 근거>. #2 수용해 수정했다. 재검하라."`
3. 정식 리뷰 2라운드 캡. **캡 도달 시점에 직전 지적을 수정했다면 확인 전용 패스 1회**(캡 밖):
   - `CODEX_EFFORT=low`로 같은 세션 `resume` — `"직전 수정분(<파일:라인>)만 반영 여부 확인. 새 이슈 탐색 금지."`
   - 여기서 새 지적이 나와도 수정하지 않는다. 이견으로 기록하고 사용자에게 보고만 한다.
4. 잔여 이견은 기록.

## Phase E — 최종 보고 (모드별 산출물)

- `analyze`: 통합 결론 + 일치/불일치/미해소 목록.
- `plan`: 합의된 계획서 + 라운드 요약.
- `full`: 결과 요약 + VERDICT 흐름 (예: 분석 대조 1R, 계획 DISAGREE→AGREE 2R, 완료 체크 AGREE 1R).
- 공통: 수용한 지적 / 반박·기각한 지적 / 미합의 이견을 구분해 한 줄씩.
- 사용자가 "결과만" 원하면 산출물 + 한 줄 요약으로 축약.
