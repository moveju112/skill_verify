#!/usr/bin/env bash
# 공통 unit-test 스킬의 런타임 중립성과 안전 계약을 검증한다.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/skills/unit-test/SKILL.md"
VALIDATOR="$ROOT/skills/unit-test/scripts/validate_report.py"

python3 - "$SKILL" "$VALIDATOR" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
validator = Path(sys.argv[2])
text = path.read_text(encoding="utf-8")

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")

require(text.startswith("---\n"), "frontmatter가 없습니다")
frontmatter = text.split("---\n", 2)[1]
require(re.search(r"^name:\s*unit-test\s*$", frontmatter, re.MULTILINE) is not None,
        "skill 이름이 unit-test가 아닙니다")
require("Codex or Claude" in frontmatter, "설명이 양쪽 런타임을 포함하지 않습니다")

for forbidden in ("Claude-only", "Claude designs", "never codex"):
    require(forbidden not in text, f"런타임 전용 문구가 남았습니다: {forbidden}")

require("The active host designs, runs, and documents" in text,
        "실행 주체가 현재 호스트로 정의되지 않았습니다")
require("never call the counterpart" in text,
        "상대 모델을 호출하지 않는 경계가 없습니다")
require("explicitly asks for unit testing" in text and "does not trigger this skill" in text,
        "명시적 요청 전용 호출 규칙이 없습니다")
require("Do not offer unit tests merely because code changed" in text,
        "코드 수정 직후 테스트 제안 금지 규칙이 없습니다")
require("direct request to run unit tests IS the approval" in text,
        "직접 요청의 로컬 테스트 승인 규칙이 없습니다")
require("Never access an external DB, network" in text,
        "외부 DB/네트워크를 단위 테스트에서 분리하는 규칙이 없습니다")

angles = (
    "happy path",
    "boundary",
    "empty·null·missing",
    "error path",
    "ordering·determinism",
    "before/after equivalence",
    "side effects",
)
for angle in angles:
    require(f"| {angle} |" in text, f"테스트 관점이 빠졌습니다: {angle}")

require("Prefer the project's existing test framework" in text,
        "기존 테스트 프레임워크 재사용 규칙이 없습니다")
require("full-suite owner" in text and "Never run a full suite" in text,
        "중복 전체 테스트 방지 규칙이 없습니다")
require("BASELINE_FAIL" in text,
        "기존 실패를 분리하는 규칙이 없습니다")
require("<project>/test/UNITTEST_<YYYYMMDD>_<topic>.md" in text,
        "결과 보고서 경로 계약이 없습니다")
require("UNIT_COUNTS" in text and "validate_report.py" in text,
        "보고서 집계 검증 계약이 없습니다")
require("at or below 300 lines" in text and "true EOF" in text,
        "보고서 롤오버·EOF append 규칙이 없습니다")
require("Delete task-only test scripts" in text,
        "테스트 전용 파일 정리 규칙이 없습니다")
require(validator.is_file(), "보고서 검증 스크립트가 없습니다")

print("PASS: shared unit-test skill contract")
PY

# 기존 계약과 미실행 결과의 오판 방지를 임시 파일 없이 확인한다.
python3 -B -m unittest discover -s "$ROOT/tests" -p test_unit_report.py -v
