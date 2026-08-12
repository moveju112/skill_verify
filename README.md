# codex-crosscheck

Claude↔Codex 핑퐁 교차검증 스킬 플러그인.

- Claude가 설계·코딩, Codex가 검증. 합의될 때까지 핑퐁, 합의 후 Claude가 구현.
- 토큰 누수 차단: 모든 Codex 호출은 `codex_ask.sh` 래퍼 경유 — 최종 메시지만 상한(6,000자) 잘라 반환.
- Codex는 read-only 샌드박스에서 repo를 직접 읽는다. 파일 내용·diff를 프롬프트에 싣지 않는다.

## 설치

```bash
claude plugin marketplace add ~/project/skills/codex-crosscheck
claude plugin install codex-crosscheck@codex-crosscheck
```

## 사용

세션에서 "크로스체크", "codex 교차검증", `/codex-crosscheck:crosscheck` 등으로 트리거.

## 요구사항

- codex CLI (`npm i -g @openai/codex`), 로그인 상태.
