#!/usr/bin/env python3
"""UNITTEST 보고서의 단위 케이스 집계와 외부 검증 혼입을 검사한다."""

from __future__ import annotations

from collections import Counter
from pathlib import Path
import re
import sys


COUNT_PATTERN = re.compile(
    r"<!--\s*UNIT_COUNTS\s+PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)\s*-->"
)
FORBIDDEN_TYPES = {"INTEGRATION", "RUNTIME", "PERFORMANCE"}
VERDICTS = {"PASS", "FAIL", "SKIP"}
UNEXECUTED_VALUES = {"not run", "not executed", "pending", "unavailable", "미실행", "미확인"}


# 오류 메시지 출력 (검증 실패 -> 비정상 종료).
def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


# 보고서 내용 검사 (집계 -> 케이스 근거 -> 일치 확인).
def validate_text(text: str) -> None:
    declared = Counter({"PASS": 0, "FAIL": 0, "SKIP": 0})
    markers = COUNT_PATTERN.findall(text)
    if not markers:
        fail("UNIT_COUNTS 메타데이터가 없습니다")

    for passed, failed, skipped in markers:
        declared.update(PASS=int(passed), FAIL=int(failed), SKIP=int(skipped))

    actual = Counter({"PASS": 0, "FAIL": 0, "SKIP": 0})
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not cells:
            continue
        check_type = cells[0].upper()
        if check_type in FORBIDDEN_TYPES:
            fail(f"{line_number}행에 외부 검증 종류 {check_type}가 포함됐습니다")
        if check_type != "UNIT":
            continue
        if len(cells) < 7:
            fail(f"{line_number}행 UNIT 케이스 열이 부족합니다")
        if any(not cell for cell in cells[1:6]):
            fail(f"{line_number}행 UNIT 케이스 근거가 비어 있습니다")
        verdict = cells[-1].upper()
        if verdict not in VERDICTS:
            fail(f"{line_number}행 판정이 PASS/FAIL/SKIP이 아닙니다: {verdict}")
        if verdict != "SKIP" and cells[5].casefold() in UNEXECUTED_VALUES:
            fail(f"{line_number}행 미실행 케이스를 {verdict}로 판정했습니다")
        actual[verdict] += 1

    if declared != actual:
        fail(f"집계 불일치: declared={dict(declared)}, actual={dict(actual)}")

    print(
        "PASS: unit-test report "
        f"PASS={actual['PASS']} FAIL={actual['FAIL']} SKIP={actual['SKIP']}"
    )


# 파일 읽기 (보고서 경로 -> 내용 검증).
def validate(path: Path) -> None:
    validate_text(path.read_text(encoding="utf-8"))


# 인자 확인 (보고서 파일 -> 검증 실행).
def main() -> None:
    if len(sys.argv) != 2:
        fail("사용법: validate_report.py <UNITTEST_report.md>")
    path = Path(sys.argv[1])
    if not path.is_file():
        fail(f"보고서 파일이 없습니다: {path}")
    validate(path)


if __name__ == "__main__":
    main()
