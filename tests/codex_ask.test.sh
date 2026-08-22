#!/usr/bin/env bash
# codex_ask.sh 회귀 테스트 — PATH에 가짜 codex·timeout을 끼워 실제 API 호출 없이 분기를 검증한다.
# 실행: bash tests/codex_ask.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/skills/crosscheck/scripts/codex_ask.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
# 1. 단언 헬퍼 — 출력에 기대 문자열이 있는지만 본다
assert_has() {
    local label="$1" expect="$2" actual="$3"
    if echo "$actual" | grep -qF -- "$expect"; then
        echo "ok   - $label"
    else
        echo "FAIL - $label (기대: '$expect')"
        echo "$actual" | sed 's/^/       /'
        FAIL=1
    fi
}
assert_not_has() {
    local label="$1" unexpect="$2" actual="$3"
    if echo "$actual" | grep -qF -- "$unexpect"; then
        echo "FAIL - $label ('$unexpect'가 나오면 안 된다)"
        FAIL=1
    else
        echo "ok   - $label"
    fi
}

# 2. 가짜 codex — 인자를 기록하고, -o 로 지정된 파일에 준비된 응답을 쓴다
mkdir -p "$WORK/bin"
cat >"$WORK/bin/codex" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >>"$FAKE_ARGS"
case "${1:-}" in
    "login") echo "Logged in using ChatGPT"; exit 0 ;;
    "--version") echo "codex-cli 99.0.0-fake"; exit 0 ;;
esac
cat >/dev/null   # stdin 프롬프트 소비
OUTFILE=""
while [ $# -gt 0 ]; do
    [ "$1" = "-o" ] && OUTFILE="$2"
    shift
done
[ -n "$OUTFILE" ] && cp "$FAKE_REPLY" "$OUTFILE"
echo '{"type":"thread.started","thread_id":"11111111-2222-3333-4444-555555555555"}'
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$WORK/bin/codex"

# 3. 가짜 timeout — 전달 인자를 기록하고 나머지를 그대로 실행한다
cat >"$WORK/bin/timeout" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >>"$FAKE_TIMEOUT_ARGS"
[ "${1:-}" = "-k" ] && shift 2
shift    # 초 단위 인자 버리기
exec "$@"
FAKE
chmod +x "$WORK/bin/timeout"

export PATH="$WORK/bin:$PATH"
export CROSSCHECK_STATE_DIR="$WORK/state"
export FAKE_ARGS="$WORK/codex-args.txt"
export FAKE_TIMEOUT_ARGS="$WORK/timeout-args.txt"
export FAKE_REPLY="$WORK/reply.md"
UUID="11111111-2222-3333-4444-555555555555"

# 4. check 모드 — 첫 줄 CODEX_OK 유지 + 경로·버전 진단 줄
OUT="$(bash "$SCRIPT" check 2>&1)"
assert_has "check: 첫 줄 CODEX_OK 유지" "CODEX_OK" "$(echo "$OUT" | head -1)"
assert_has "check: 바이너리 경로 출력" "CODEX_BIN: $WORK/bin/codex" "$OUT"
assert_has "check: 버전 출력" "CODEX_VERSION: codex-cli 99.0.0-fake" "$OUT"

# 5. resume 세션 ID 검증 — UUID 아닌 값은 실행 전 차단
for BAD in last UNKNOWN "; rm -rf /"; do
    OUT="$(bash "$SCRIPT" resume "$BAD" "질문" 2>&1)"; RC=$?
    assert_has "resume '$BAD' 거부" "CODEX_ERROR" "$OUT"
    [ "$RC" = "3" ] || { echo "FAIL - resume '$BAD' 종료코드 3 아님 ($RC)"; FAIL=1; }
done

# 6. 정상 응답 — 형식 경고 없이 통과
printf 'VERDICT: AGREE\n- 근거 하나\n' >"$FAKE_REPLY"
: >"$FAKE_TIMEOUT_ARGS"
OUT="$(bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
assert_not_has "정상 응답: 형식 경고 없음" "CODEX_FORMAT_WARNING" "$OUT"
assert_has "정상 응답: 본문 전달" "근거 하나" "$OUT"
assert_has "timeout에 -k 10 전달" "-k 10" "$(cat "$FAKE_TIMEOUT_ARGS")"
assert_not_has "resume에 --last 미사용" "--last" "$(cat "$FAKE_ARGS")"

# 7. 형식 위반 — 첫 줄 VERDICT 아님
printf '분석 결과입니다\n- 근거\n' >"$FAKE_REPLY"
OUT="$(bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
assert_has "첫 줄 VERDICT 아님 경고" "첫 줄이 VERDICT 형식 아님" "$OUT"

# 8. 형식 위반 — DISAGREE인데 심각도 표기 없음
printf 'VERDICT: DISAGREE\n#1 심각도 없는 지적\n' >"$FAKE_REPLY"
OUT="$(bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
assert_has "심각도 누락 경고" "#1 [blocking|minor]" "$OUT"

# 9. 분량 계약 — 3000자 초과
{ echo "VERDICT: AGREE"; python3 -c 'print("가"*3100)'; } >"$FAKE_REPLY"
OUT="$(bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
assert_has "3000자 초과 경고" "3000자 초과" "$OUT"

# 10. 분량 계약 — bullet 7개 초과
{ echo "VERDICT: AGREE"; for i in $(seq 8); do echo "- 근거 $i"; done; } >"$FAKE_REPLY"
OUT="$(bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
assert_has "bullet 8개 경고" "bullet 8개" "$OUT"

# 10-1. bullet 마커는 `-` 외에 `*`·`+`도 센다 (마커를 바꿔 계약을 우회하는 것 방지)
for MARK in '*' '+'; do
    { echo "VERDICT: AGREE"; for i in $(seq 8); do echo "$MARK 근거 $i"; done; } >"$FAKE_REPLY"
    OUT="$(bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
    assert_has "bullet '$MARK' 8개 경고" "bullet 8개" "$OUT"
done

# 11. 실패 분류 — codex 종료코드 124는 타임아웃
printf 'VERDICT: AGREE\n' >"$FAKE_REPLY"
OUT="$(FAKE_RC=124 bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
assert_has "exit 124 → CODEX_TIMEOUT" "CODEX_TIMEOUT" "$OUT"

# 12. 실패 시 원로그 본문이 stdout으로 새지 않는지
printf 'VERDICT: AGREE\n' >"$FAKE_REPLY"
OUT="$(FAKE_RC=1 bash "$SCRIPT" resume "$UUID" "질문" 2>&1)"
assert_not_has "실패 시 원로그 누수 없음" "thread.started" "$OUT"

echo
[ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILED"
exit "$FAIL"
