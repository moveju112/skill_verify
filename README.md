# skill_verify

코드 검증 스킬 번들 플러그인 (`verify`).

| 스킬 | 역할 |
|---|---|
| `verify:crosscheck` | Claude↔Codex 핑퐁 교차검증 — Claude가 설계·코딩, Codex가 검증. 합의 후 구현 |
| `verify:unit-test` | 코드 수정 직후 승인형 다각도 단위 테스트 — 결과 문서를 `<project>/test/`에 정리 |

## crosscheck

- 토큰 누수 차단: 모든 Codex 호출은 `codex_ask.sh` 래퍼 경유 — 최종 메시지만 상한(6,000자) 잘라 반환.
- Codex는 read-only 샌드박스에서 repo를 직접 읽는다. 파일 내용·diff를 프롬프트에 싣지 않는다.
- 지적은 `#N [blocking|minor]` 번호제, 라운드 캡 + 확인 전용 패스. 수용 전 `파일:라인` 재검증 게이트 통과 필수.
- 호출은 Bash `timeout: 930000` 필수 (스크립트 내부 상한 900초). 로그는 소유자 전용 권한 + 14일 자동 정리.
- resume은 명시 세션 UUID만 허용 — 전역 최신 세션(`--last`) 이어가기는 지원하지 않는다.
- Phase D(완료 체크)는 기본 background 실행. 결과 회수 전에는 종결하지 않는다.

### 테스트

```bash
bash tests/codex_ask.test.sh   # 가짜 codex·timeout 주입, 실제 API 호출 없음
```

## unit-test

- Claude 단독 동작 (외부 LLM 미사용).
- 수정 완료 시 "단위 테스트를 진행할까요?" 선질문 — 승인 시에만 실행.
- 7각도 케이스: 정상 / 경계 / 빈값 / 에러 / 순서 / 전후 동등성 / 부작용.
- 스크립트 경로는 3단계 탐색(룰 문서 → 기존 디렉토리 감지 → `test/scripts/` 생성), 결과 문서는 `<project>/test/UNITTEST_<날짜>_<주제>.md`.

## 설치

```bash
claude plugin marketplace add moveju112/skill_verify
claude plugin install verify@verify
```

Claude Code 세션 안에서는 슬래시 명령으로도 된다.

```
/plugin marketplace add moveju112/skill_verify
/plugin install verify@verify
```

## 사용

- "크로스체크", "codex 교차검증", `/verify:crosscheck`
- "단위 테스트", "테스트 돌려", `/verify:unit-test`

## 요구사항

- crosscheck만: codex CLI (`npm i -g @openai/codex`), 로그인 상태.
