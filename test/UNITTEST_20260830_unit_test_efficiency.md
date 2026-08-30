# unit-test 효율 고도화 단위 테스트

## 요약

중복 전체 테스트 방지, 외부 검증 분리, 기준선 실패 분류, 보고서 집계 검증 계약이 모두 통과했습니다.

<!-- UNIT_COUNTS PASS=7 FAIL=0 SKIP=0 -->

## 대상

- `skills/unit-test/SKILL.md`: 집중 테스트와 단일 full-suite owner 실행 규칙.
- `skills/unit-test/scripts/validate_report.py`: UNIT 집계와 외부 검증 혼입 검사.
- `tests/unit_test_skill.test.sh`: 스킬 계약과 검증기 행동 회귀 테스트.
- `README.md`: 사용자용 효율·범위 설명.

## 케이스 표

| type | # | 관점 | 입력 | 기대 | 실제 | 판정 |
|---|---:|---|---|---|---|---|
| UNIT | 1 | 정상 | 공통 스킬 frontmatter | 양쪽 런타임 계약 유지 | 계약 유지 | PASS |
| UNIT | 2 | 승인·범위 | 로컬 승인과 외부 DB·네트워크 | 로컬만 실행 | 외부 검증 분리 | PASS |
| UNIT | 3 | 다각도 | 기존 7개 테스트 관점 | 전부 유지 | 전부 유지 | PASS |
| UNIT | 4 | 중복 방지 | 전체 suite와 release wrapper | full-suite owner 한 번 | 중복 금지 계약 확인 | PASS |
| UNIT | 5 | 정상 보고서 | PASS 1·SKIP 1 표 | 집계 일치 허용 | 종료 코드 0 | PASS |
| UNIT | 6 | 집계 오류 | 선언 PASS 2·표 PASS 1 | 거부 | 종료 코드 비정상 | PASS |
| UNIT | 7 | 범위 오류 | RUNTIME 행 포함 | 거부 | 종료 코드 비정상 | PASS |

## 실패 상세

변경 범위 실패는 없습니다.

## 미커버 위험

실제 프로젝트에서 다음 unit-test 실행 시 새 보고서 형식과 full-suite owner 선택이 처음 적용됩니다.

외부 DB·네트워크·런타임 검증은 스킬 범위에서 제외해 실행하지 않았습니다.

## 환경

- 날짜: 2026-08-30 KST.
- Python: 시스템 `python3`.
- 집중 테스트: `bash tests/unit_test_skill.test.sh`.
- 스킬 검사: `python3 /home/ubuntu/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/unit-test`.
- full-suite owner: `tests/*.test.sh` 전체를 한 번 실행.
- 보조 검사: `git diff --check`.
