#!/usr/bin/env bash
# 실제 bubblewrap 경계 테스트 — 모델 호출 없이 저장소 읽기·외부 홈 차단·쓰기 차단을 검증한다.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/platforms/codex/verify/scripts/claude_ask.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0

mkdir -p "$WORK/bin" "$WORK/repo"
git -C "$WORK/repo" init -q
git -C "$WORK/repo" config user.name test
git -C "$WORK/repo" config user.email test@example.com
printf 'base\n' >"$WORK/repo/sample.txt"
git -C "$WORK/repo" add sample.txt
git -C "$WORK/repo" commit -qm init

cat >"$WORK/bin/claude" <<'FAKE'
#!/usr/bin/env bash
SESSION=""
PREV=""
for ARG in "$@"; do
    if [ "$PREV" = "--session-id" ]; then
        SESSION="$ARG"
    fi
    PREV="$ARG"
done

[ -r /workspace/sample.txt ] || exit 81
[ -r /evidence/status.txt ] || exit 82
[ ! -e /home ] || exit 83
if (exec 2>/dev/null; printf 'blocked\n' >/workspace/.write-probe); then
    exit 85
fi
AUTH_FD="${CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR:-}"
[ "$AUTH_FD" = "9" ] || exit 86
AUTH_TOKEN="$(cat <&9)"
[ "$AUTH_TOKEN" = "test-token" ] || exit 87
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] || exit 88

jq -n --arg result $'VERDICT: AGREE\n- 실제 샌드박스 경계 확인\n' --arg session "$SESSION" \
    '{result: $result, session_id: $session, is_error: false}'
FAKE
chmod +x "$WORK/bin/claude"

OUT="$(PATH="$WORK/bin:/usr/bin:/bin" CLAUDE_CODE_OAUTH_TOKEN=test-token \
    CROSSCHECK_STATE_DIR="$WORK/state" CROSSCHECK_TIMEOUT=30 CROSSCHECK_REMOTE_APPROVED=1 \
    bash "$SCRIPT" new -C "$WORK/repo" "샌드박스 테스트" 2>&1)"
RC=$?

if [ "$RC" = "0" ] && echo "$OUT" | grep -qF 'VERDICT: AGREE'; then
    echo "ok   - 실제 bubblewrap에서 대상 저장소와 증거 읽기 허용"
else
    echo "FAIL - 실제 bubblewrap 실행 실패 (rc=$RC)"
    echo "$OUT" | sed 's/^/       /'
    FAIL=1
fi

if [ ! -e "$WORK/repo/.write-probe" ]; then
    echo "ok   - 대상 저장소 쓰기 차단"
else
    echo "FAIL - 대상 저장소에 쓰기 발생"
    FAIL=1
fi

if echo "$OUT" | grep -qF '실제 샌드박스 경계 확인'; then
    echo "ok   - 호스트 홈·다른 저장소 미노출"
    echo "ok   - 인증 토큰은 FD 9로만 전달"
else
    echo "FAIL - 호스트 경계 확인 응답 없음"
    FAIL=1
fi

echo
[ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILED"
exit "$FAIL"
