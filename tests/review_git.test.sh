#!/usr/bin/env bash
# review_git.sh 회귀 테스트 — 임시 저장소에서 읽기 명령과 입력 차단을 검증한다.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/platforms/codex/verify/scripts/review_git.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"

git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.com
printf 'alpha\n' >"$REPO/sample.txt"
git -C "$REPO" add sample.txt
git -C "$REPO" commit -qm init
printf 'beta\n' >>"$REPO/sample.txt"
printf 'new\n' >"$REPO/untracked.txt"

FAIL=0
[ -x "$SCRIPT" ] && echo "ok   - Git helper 실행 권한" \
    || { echo "FAIL - Git helper 실행 권한 없음"; FAIL=1; }
assert_has() {
    local label="$1" expect="$2" actual="$3"
    if echo "$actual" | grep -qF -- "$expect"; then
        echo "ok   - $label"
    else
        echo "FAIL - $label (기대: '$expect')"
        FAIL=1
    fi
}

export CROSSCHECK_REVIEW_ROOT="$REPO"
OUT="$(bash "$SCRIPT" status)"
assert_has "status: 추적 변경" "sample.txt" "$OUT"
assert_has "status: 미추적 파일" "untracked.txt" "$OUT"

OUT="$(bash "$SCRIPT" head)"
assert_has "head: 현재 커밋" "$(git -C "$REPO" rev-parse HEAD)" "$OUT"

OUT="$(bash "$SCRIPT" untracked)"
assert_has "untracked: 파일 목록" "untracked.txt" "$OUT"

OUT="$(bash "$SCRIPT" diff HEAD -- sample.txt)"
assert_has "diff: 변경 내용" "+beta" "$OUT"

OUT="$(bash "$SCRIPT" diff --output=leak 2>&1)"; RC=$?
assert_has "쓰기 옵션 거부" "usage:" "$OUT"
[ "$RC" = "2" ] || { echo "FAIL - 쓰기 옵션 종료코드 2 아님 ($RC)"; FAIL=1; }
[ ! -e "$REPO/leak" ] || { echo "FAIL - 출력 파일이 생성됨"; FAIL=1; }

OUT="$(bash "$SCRIPT" diff HEAD -- ../outside 2>&1)"; RC=$?
assert_has "저장소 밖 경로 거부" "usage:" "$OUT"
[ "$RC" = "2" ] || { echo "FAIL - 경로 거부 종료코드 2 아님 ($RC)"; FAIL=1; }

OUT="$(bash "$SCRIPT" diff HEAD -- .. 2>&1)"; RC=$?
assert_has "단독 상위 경로 거부" "usage:" "$OUT"
[ "$RC" = "2" ] || { echo "FAIL - 단독 경로 거부 종료코드 2 아님 ($RC)"; FAIL=1; }

OUT="$(bash "$SCRIPT" status extra 2>&1)"; RC=$?
assert_has "status 추가 인자 거부" "usage:" "$OUT"
[ "$RC" = "2" ] || { echo "FAIL - status 인자 종료코드 2 아님 ($RC)"; FAIL=1; }

OUT="$(bash "$SCRIPT" diff HEAD~1 2>&1)"; RC=$?
assert_has "허용하지 않는 ref 거부" "usage:" "$OUT"
[ "$RC" = "2" ] || { echo "FAIL - ref 거부 종료코드 2 아님 ($RC)"; FAIL=1; }

OUT="$(bash "$SCRIPT" delete 2>&1)"; RC=$?
assert_has "미지원 모드 거부" "usage:" "$OUT"
[ "$RC" = "2" ] || { echo "FAIL - 미지원 모드 종료코드 2 아님 ($RC)"; FAIL=1; }

OUT="$(CROSSCHECK_REVIEW_ROOT= bash "$SCRIPT" status 2>&1)"; RC=$?
assert_has "검토 루트 누락" "검토 루트가 없다" "$OUT"
[ "$RC" = "3" ] || { echo "FAIL - 루트 누락 종료코드 3 아님 ($RC)"; FAIL=1; }

OUT="$(CROSSCHECK_REVIEW_ROOT="$WORK" bash "$SCRIPT" status 2>&1)"; RC=$?
assert_has "비 Git 루트 거부" "Git 저장소가 아니다" "$OUT"
[ "$RC" = "3" ] || { echo "FAIL - 비 Git 종료코드 3 아님 ($RC)"; FAIL=1; }

echo
[ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILED"
exit "$FAIL"
