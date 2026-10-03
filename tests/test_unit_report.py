"""보고서 검증기가 실행하지 않은 케이스를 통과시키지 않는지 확인한다."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import unittest


VALIDATOR_PATH = Path(__file__).resolve().parents[1] / "skills/unit-test/scripts/validate_report.py"
SPEC = importlib.util.spec_from_file_location("unit_report_validator", VALIDATOR_PATH)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class ReportEvidenceTests(unittest.TestCase):
    # 집계와 케이스 조합 (판정 -> 검사할 보고서).
    def report(self, verdict="PASS", actual="[]", expected="[]"):
        counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
        counts[verdict] = 1
        return (
            f"<!-- UNIT_COUNTS PASS={counts['PASS']} FAIL={counts['FAIL']} SKIP={counts['SKIP']} -->\n"
            f"| UNIT | 1 | empty | [] | {expected} | {actual} | {verdict} |\n"
        )

    # 관측값과 미실행 사유 확인 (유효 보고서 -> 성공).
    def test_observed_empty_and_skipped_cases_pass(self):
        for report in (self.report(), self.report("SKIP", "dependency unavailable"),
                       self.report("FAIL", "ValueError", "[]")):
            with self.subTest(report=report), redirect_stdout(io.StringIO()):
                VALIDATOR.validate_text(report)

    # 누락된 근거 확인 (빈 expected/actual -> 거절).
    def test_missing_expected_or_actual_is_rejected(self):
        for report in (self.report(actual=""), self.report(expected="")):
            with self.subTest(report=report), self.assertRaisesRegex(SystemExit, "근거가 비어"):
                VALIDATOR.validate_text(report)

    # 실행되지 않은 케이스 확인 (미실행 PASS/FAIL -> 거절).
    def test_unexecuted_results_cannot_pass_or_fail(self):
        for verdict in ("PASS", "FAIL"):
            for actual in ("not run", "UNAVAILABLE", "미실행"):
                with self.subTest(verdict=verdict, actual=actual), self.assertRaisesRegex(SystemExit, "미실행"):
                    VALIDATOR.validate_text(self.report(verdict, actual))

    # 기존 오류 계약 확인 (집계 불일치/외부 검증 -> 거절).
    def test_count_mismatch_and_external_checks_are_rejected(self):
        invalid = (self.report().replace("PASS=1", "PASS=2"),
                   self.report().replace("| UNIT |", "| RUNTIME |"))
        for report in invalid:
            with self.subTest(report=report), self.assertRaises(SystemExit):
                VALIDATOR.validate_text(report)


if __name__ == "__main__":
    unittest.main()
