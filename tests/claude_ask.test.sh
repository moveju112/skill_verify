#!/usr/bin/env bash
# claude_ask.sh 회귀 테스트 — 가짜 Claude CLI로 승인·격리·형식 계약을 검증한다.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/platforms/codex/verify/scripts/claude_ask.sh"
GIT_READER="$(dirname "$SCRIPT")/review_git.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
[ -x "$SCRIPT" ] && echo "ok   - Claude 래퍼 실행 권한" \
    || { echo "FAIL - Claude 래퍼 실행 권한 없음"; FAIL=1; }
[ -x "$GIT_READER" ] && echo "ok   - Git helper 실행 권한" \
    || { echo "FAIL - Git helper 실행 권한 없음"; FAIL=1; }
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

mkdir -p "$WORK/bin" "$WORK/repo"
git -C "$WORK/repo" init -q
git -C "$WORK/repo" config user.name test
git -C "$WORK/repo" config user.email test@example.com
printf 'base\n' >"$WORK/repo/sample.txt"
git -C "$WORK/repo" add sample.txt
git -C "$WORK/repo" commit -qm init
printf 'change\n' >>"$WORK/repo/sample.txt"
cat >"$WORK/bin/claude" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >>"$FAKE_ARGS"
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
    echo "${FAKE_AUTH_JSON:-{\"loggedIn\":true}}"
    exit "${FAKE_AUTH_RC:-0}"
fi
if [ "${1:-}" = "--version" ]; then
    echo "2.99.0 (Claude Code fake)"
    exit 0
fi
SESSION_ARG=""
PREV=""
for ARG in "$@"; do
    if [ "$PREV" = "--session-id" ] || [ "$PREV" = "--resume" ]; then
        SESSION_ARG="$ARG"
    fi
    PREV="$ARG"
done
if [ "${FAKE_KEEP_SESSION:-}" = "1" ]; then
    cat "$FAKE_REPLY"
else
    jq --arg session "$SESSION_ARG" '.session_id = $session' "$FAKE_REPLY"
fi
echo "$FAKE_STDERR" >&2
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$WORK/bin/claude"

cat >"$WORK/bin/timeout" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >>"$FAKE_TIMEOUT_ARGS"
[ "${1:-}" = "-k" ] && shift 2
shift
exec "$@"
FAKE
chmod +x "$WORK/bin/timeout"

cat >"$WORK/bin/bwrap" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >>"$FAKE_BWRAP_ARGS"
CLAUDE_SOURCE=""
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    if [ "$1" = "--ro-bind" ] && [ "${3:-}" = "/claude" ]; then
        CLAUDE_SOURCE="$2"
    fi
    shift
done
[ "${1:-}" = "--" ] && shift
[ "${1:-}" = "/claude" ] && shift
exec "$CLAUDE_SOURCE" "$@"
FAKE
chmod +x "$WORK/bin/bwrap"

# 실제 래퍼의 env -i 경계를 기록하되, 가짜 CLI 제어 변수는 테스트 프로세스에 유지한다.
cat >"$WORK/bin/env" <<'FAKE'
#!/usr/bin/env bash
echo "$@" >>"$FAKE_ENV_ARGS"
[ "${1:-}" = "-i" ] && shift
while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
    export "$1"
    shift
done
exec "$@"
FAKE
chmod +x "$WORK/bin/env"

export PATH="$WORK/bin:$PATH"
export CROSSCHECK_STATE_DIR="$WORK/state"
export FAKE_ARGS="$WORK/claude-args.txt"
export FAKE_TIMEOUT_ARGS="$WORK/timeout-args.txt"
export FAKE_BWRAP_ARGS="$WORK/bwrap-args.txt"
export FAKE_ENV_ARGS="$WORK/env-args.txt"
export FAKE_REPLY="$WORK/reply.json"
export FAKE_STDERR=""
export CLAUDE_CODE_OAUTH_TOKEN="test-token"
UUID="11111111-2222-3333-4444-555555555555"

# 1. 프리플라이트는 원격 승인 없이 인증 상태만 확인한다.
OUT="$(bash "$SCRIPT" check 2>&1)"
assert_has "check: 인증 확인" "CLAUDE_OK" "$(echo "$OUT" | head -1)"
assert_has "check: 버전 확인" "Claude Code fake" "$OUT"

OUT="$(FAKE_AUTH_JSON='{"loggedIn":false}' bash "$SCRIPT" check 2>&1)"; RC=$?
assert_has "check: 미인증 분류" "CLAUDE_AUTH_ERROR" "$OUT"
[ "$RC" = "1" ] || { echo "FAIL - 미인증 종료코드 1 아님 ($RC)"; FAIL=1; }

# 2. 실제 호출은 명시적인 작업별 승인 없이는 실행되지 않는다.
: >"$FAKE_ARGS"
OUT="$(bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"; RC=$?
assert_has "승인 게이트" "CLAUDE_PERMISSION_REQUIRED" "$OUT"
[ "$RC" = "4" ] || { echo "FAIL - 승인 거부 종료코드 4 아님 ($RC)"; FAIL=1; }
assert_not_has "승인 전 Claude 미호출" "-p" "$(cat "$FAKE_ARGS")"

# 3. resume은 명시적인 UUID만 허용한다.
for BAD in last UNKNOWN "; rm -rf /"; do
    OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" resume "$BAD" "질문" 2>&1)"; RC=$?
    assert_has "resume '$BAD' 거부" "CLAUDE_ERROR" "$OUT"
    [ "$RC" = "3" ] || { echo "FAIL - resume '$BAD' 종료코드 3 아님 ($RC)"; FAIL=1; }
done

# 4. 정상 호출은 읽기 전용·안전 모드와 명시 세션을 사용한다.
jq -n --arg result $'VERDICT: AGREE\n- 근거 하나\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
: >"$FAKE_ARGS"
: >"$FAKE_TIMEOUT_ARGS"
: >"$FAKE_BWRAP_ARGS"
: >"$FAKE_ENV_ARGS"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
ARGS="$(cat "$FAKE_ARGS")"
NEW_UUID="$(echo "$OUT" | sed -n 's/^SESSION: //p' | head -1)"
assert_has "정상 응답" "VERDICT: AGREE" "$OUT"
assert_has "세션 ID" "SESSION: $NEW_UUID" "$OUT"
assert_has "명시적인 새 세션" "--session-id $NEW_UUID" "$ARGS"
assert_has "안전 모드" "--safe-mode" "$ARGS"
assert_has "비대화형 거부 모드" "--permission-mode dontAsk" "$ARGS"
assert_has "편집 도구 차단" "Edit,Write" "$ARGS"
assert_has "도구 자체를 읽기 전용으로 제한" "--tools Read,Glob,Grep" "$ARGS"
assert_has "Bash·워크플로·서브에이전트 차단" "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task,Workflow,ToolSearch" "$ARGS"
assert_not_has "Bash 허용 없음" "Bash(" "$ARGS"
assert_has "status 자료 전달" "/evidence/status.txt" "$ARGS"
assert_has "diff 자료 전달" "/evidence/diff.patch" "$ARGS"
assert_has "미추적 목록 전달" "/evidence/untracked.txt" "$ARGS"
assert_has "증거 디렉터리만 도구에 추가" "--add-dir /evidence" "$ARGS"
assert_has "timeout -k 10" "-k 10" "$(cat "$FAKE_TIMEOUT_ARGS")"
assert_has "환경 초기화" "-i PATH=/usr/bin:/bin" "$(cat "$FAKE_ENV_ARGS")"
BWRAP_ARGS="$(cat "$FAKE_BWRAP_ARGS")"
assert_has "사용자·마운트 격리" "--unshare-all --share-net" "$BWRAP_ARGS"
assert_has "저장소 읽기 전용 마운트" "--ro-bind $WORK/repo /workspace" "$BWRAP_ARGS"
assert_has "현재 증거 읽기 전용 마운트" "/evidence" "$BWRAP_ARGS"
assert_has "세션별 홈 마운트" "session-$NEW_UUID /reviewer-home" "$BWRAP_ARGS"
assert_not_has "호스트 홈 미노출" "--ro-bind /home/ubuntu /home/ubuntu" "$BWRAP_ARGS"

# 호스트 설정에서 모델 선택 키만 리뷰어 홈으로 옮기고 hooks·env 등은 버린다.
mkdir -p "$WORK/host-config"
jq -n '{model: "opus[1m]", effortLevel: "low", modelSettings: {"claude-opus-5": {effortLevel: "medium"}, "claude-opus-5-5": {effortLevel: "high"}},
    hooks: {Stop: []}, env: {SECRET_FLAG: "1"}, permissions: {allow: ["Bash"]}}' >"$WORK/host-config/settings.json"
OUT="$(CLAUDE_CONFIG_DIR="$WORK/host-config" CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
MODEL_UUID="$(echo "$OUT" | sed -n 's/^SESSION: //p' | head -1)"
REVIEWER_SETTINGS="$(jq -c . "$WORK/state/session-$MODEL_UUID/.claude/settings.json" 2>&1)"
assert_has "모델 설정 전달" '"model":"opus[1m]","effortLevel":"low"' "$REVIEWER_SETTINGS"
assert_has "모델별 effort 전달" '"claude-opus-5-5":{"effortLevel":"high"}' "$REVIEWER_SETTINGS"
assert_not_has "hooks 미전달" "hooks" "$REVIEWER_SETTINGS"
assert_not_has "env 미전달" "SECRET_FLAG" "$REVIEWER_SETTINGS"
assert_not_has "권한 미전달" "permissions" "$REVIEWER_SETTINGS"

OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" resume "$NEW_UUID" "후속" 2>&1)"
assert_has "명시 세션 resume" "--resume $NEW_UUID" "$(cat "$FAKE_ARGS")"
assert_not_has "암시적 최신 세션 미사용" "--continue" "$(cat "$FAKE_ARGS")"

OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" resume "$UUID" "후속" 2>&1)"; RC=$?
assert_has "저장되지 않은 세션 거부" "저장된 세션을 찾을 수 없다" "$OUT"
[ "$RC" = "3" ] || { echo "FAIL - 미저장 세션 종료코드 3 아님 ($RC)"; FAIL=1; }

# 5. 형식 위반과 실패 로그는 판정만 노출한다.
jq -n --arg result $'분석 결과\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "형식 경고" "첫 줄이 VERDICT 형식 아님" "$OUT"

# 6. DISAGREE 계약과 문자·bullet 상한을 실제 검사한다.
jq -n --arg result $'VERDICT: DISAGREE\n#1 심각도 없음\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "심각도 누락 경고" "#1 [blocking|minor]" "$OUT"

jq -n --arg result $'VERDICT: DISAGREE\n#1 [blocking] 첫째\n#3 [minor] 셋째\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "지적 번호 연속성" "번호가 1부터 연속" "$OUT"

LONG="$(python3 -c 'print("가" * 3001)')"
jq -n --arg result "VERDICT: AGREE
$LONG" --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(LC_ALL=C CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "로케일 독립 문자 상한" "3000자 초과" "$OUT"

RESULT='VERDICT: AGREE'
for i in $(seq 8); do RESULT="$RESULT
- 근거 $i"; done
jq -n --arg result "$RESULT" --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "bullet 상한" "bullet 8개" "$OUT"

# 7. 빈 결과·비JSON·Claude 오류 결과는 성공으로 처리하지 않는다.
jq -n --arg session "$UUID" '{result: "", session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"; RC=$?
assert_has "빈 결과 경고" "최종 응답이 비었다" "$OUT"
[ "$RC" = "5" ] || { echo "FAIL - 빈 결과 종료코드 5 아님 ($RC)"; FAIL=1; }

printf 'not-json\n' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"; RC=$?
assert_has "비JSON 경고" "JSON 응답을 해석할 수 없다" "$OUT"
[ "$RC" = "5" ] || { echo "FAIL - 비JSON 종료코드 5 아님 ($RC)"; FAIL=1; }

jq -n --arg result '모델 오류' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: true}' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"; RC=$?
assert_has "Claude 오류 결과" "CLAUDE_ERROR" "$OUT"
[ "$RC" = "1" ] || { echo "FAIL - Claude 오류 종료코드 1 아님 ($RC)"; FAIL=1; }

jq -n --arg result $'VERDICT: AGREE\n- 긴 근거\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(CROSSCHECK_MAX_CHARS=10 CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "응답 절단 마커" "...[잘림" "$OUT"

jq -n --arg result $'VERDICT: AGREE\n' '{result: $result, session_id: "", is_error: false}' >"$FAKE_REPLY"
OUT="$(FAKE_KEEP_SESSION=1 CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"; RC=$?
assert_has "빈 세션 ID 경고" "세션 ID가 비었다" "$OUT"
[ "$RC" = "5" ] || { echo "FAIL - 빈 세션 ID 종료코드 5 아님 ($RC)"; FAIL=1; }

OUT="$(CROSSCHECK_BASE_SHA='HEAD~1' CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"; RC=$?
assert_has "잘못된 기준 커밋 거부" "기준 커밋 형식" "$OUT"
[ "$RC" = "3" ] || { echo "FAIL - 기준 커밋 거부 종료코드 3 아님 ($RC)"; FAIL=1; }

# 8. stdin과 잘못된 모드, 로그 권한을 확인한다.
jq -n --arg result $'VERDICT: AGREE\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
: >"$FAKE_ARGS"
printf 'stdin 고유 질문' | CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" - >/dev/null
assert_has "stdin 프롬프트" "stdin 고유 질문" "$(cat "$FAKE_ARGS")"

OUT="$(CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" invalid "질문" 2>&1)"; RC=$?
assert_has "잘못된 모드 usage" "usage:" "$OUT"
[ "$RC" = "2" ] || { echo "FAIL - 잘못된 모드 종료코드 2 아님 ($RC)"; FAIL=1; }

assert_has "상태 디렉터리 700" "700" "$(stat -c '%a' "$CROSSCHECK_STATE_DIR")"
BAD_DIR="$(find "$CROSSCHECK_STATE_DIR" -mindepth 1 -maxdepth 1 -type d ! -perm 700 -print -quit)"
[ -z "$BAD_DIR" ] || { echo "FAIL - 실행 디렉터리 권한 700 아님: $BAD_DIR"; FAIL=1; }
BAD_MODE="$(find "$CROSSCHECK_STATE_DIR" -mindepth 2 -type f ! -perm 600 -print -quit)"
[ -z "$BAD_MODE" ] || { echo "FAIL - 로그 권한 600 아님: $BAD_MODE"; FAIL=1; }

OUT="$(CROSSCHECK_STATE_DIR=/ CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"; RC=$?
assert_has "위험한 상태 디렉터리 거부" "안전하지 않은 상태 디렉터리" "$OUT"
[ "$RC" = "3" ] || { echo "FAIL - 상태 디렉터리 거부 종료코드 3 아님 ($RC)"; FAIL=1; }

jq -n --arg result $'VERDICT: AGREE\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(FAKE_RC=124 FAKE_STDERR='secret raw failure' CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "타임아웃 분류" "CLAUDE_TIMEOUT" "$OUT"
assert_not_has "실패 원문 미노출" "secret raw failure" "$OUT"

jq -n --arg result 'Request timed out' '{result: $result, session_id: "", is_error: true}' >"$FAKE_REPLY"
OUT="$(FAKE_KEEP_SESSION=1 FAKE_RC=1 CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "Claude JSON 타임아웃 분류" "CLAUDE_TIMEOUT" "$OUT"
assert_has "Claude JSON 내부 타임아웃 설명" "내부 요청 시간 초과" "$OUT"

jq -n --arg result $'VERDICT: AGREE\n' --arg session "$UUID" \
    '{result: $result, session_id: $session, is_error: false}' >"$FAKE_REPLY"
OUT="$(FAKE_RC=1 FAKE_STDERR='401 unauthorized' CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "인증 오류 분류" "CLAUDE_AUTH_ERROR" "$OUT"

OUT="$(FAKE_RC=1 FAKE_STDERR='429 quota exceeded' CROSSCHECK_REMOTE_APPROVED=1 bash "$SCRIPT" new -C "$WORK/repo" "질문" 2>&1)"
assert_has "한도 오류 분류" "CLAUDE_QUOTA_ERROR" "$OUT"

echo
[ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILED"
exit "$FAIL"
