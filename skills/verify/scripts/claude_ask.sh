#!/usr/bin/env bash
# Claude 호출 방화벽 — 명시적인 작업별 승인 후 읽기 전용 검토만 허용하고,
# 원출력은 소유자 전용 로그에 가둔 뒤 최종 판정만 stdout에 전달한다.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_READER="$SCRIPT_DIR/review_git.sh"
DEPENDENCIES=(bwrap env git jq python3 readlink realpath timeout)

usage() {
    echo "usage: claude_ask.sh check | new|resume [<session-uuid>] [-C dir] \"prompt\"" >&2
    exit 2
}

MODE="${1:-}"
shift || true

# 1. 로컬 설치·인증 상태만 확인하고 모델 호출은 하지 않는다.
if [ "$MODE" = "check" ]; then
    if ! command -v claude >/dev/null 2>&1; then
        echo "CLAUDE_NOT_INSTALLED"
        exit 1
    fi
    for dependency in "${DEPENDENCIES[@]}"; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo "CLAUDE_ERROR: $dependency 명령이 필요하다"
            exit 1
        fi
    done
    STATUS="$(timeout 10 claude auth status 2>/dev/null || true)"
    if echo "$STATUS" | jq -e '.loggedIn == true' >/dev/null 2>&1; then
        echo "CLAUDE_OK: authenticated"
        echo "CLAUDE_BIN: $(command -v claude)"
        echo "CLAUDE_VERSION: $(timeout 10 claude --version 2>&1 | head -1)"
        exit 0
    fi
    echo "CLAUDE_AUTH_ERROR: 로그인 상태를 확인할 수 없다"
    exit 1
fi

# 2. 외부 Claude 호출은 사용자 요청에 명시된 작업 범위에서만 열린다.
if [ "${CROSSCHECK_REMOTE_APPROVED:-}" != "1" ]; then
    echo "CLAUDE_PERMISSION_REQUIRED: 명시적인 작업별 Claude 크로스체크 권한이 필요하다"
    exit 4
fi
for dependency in claude "${DEPENDENCIES[@]}"; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "CLAUDE_ERROR: $dependency 명령이 필요하다"
        exit 1
    fi
done

SESSION=""
if [ "$MODE" = "resume" ]; then
    SESSION="${1:-}"
    shift || true
    if ! echo "$SESSION" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        echo "CLAUDE_ERROR: 세션 ID가 UUID 형식이 아니다('$SESSION'). resume 불가 — new 세션으로 다시 시작하라."
        exit 3
    fi
elif [ "$MODE" != "new" ]; then
    usage
fi

WORKDIR="$PWD"
if [ "${1:-}" = "-C" ]; then
    WORKDIR="${2:?-C needs dir}"
    shift 2
fi
[ -d "$WORKDIR" ] || { echo "CLAUDE_ERROR: 작업 디렉터리가 없다('$WORKDIR')"; exit 3; }
WORKDIR="$(realpath "$WORKDIR")"

PROMPT="${1:-}"
[ -n "$PROMPT" ] || usage
if [ "$PROMPT" = "-" ]; then
    PROMPT="$(cat)"
fi

# 3. 로그를 격리하고 오래된 원문을 자동 정리한다.
MAX_CHARS="${CROSSCHECK_MAX_CHARS:-6000}"
TIMEOUT_SEC="${CROSSCHECK_TIMEOUT:-900}"
LOG_DAYS="${CROSSCHECK_LOG_DAYS:-14}"
STATE_DIR="$(realpath -m "${CROSSCHECK_STATE_DIR:-$HOME/.cache/claude-crosscheck}")"
case "$STATE_DIR" in
    /|"$HOME"|"$WORKDIR") echo "CLAUDE_ERROR: 안전하지 않은 상태 디렉터리('$STATE_DIR')"; exit 3 ;;
esac
case "$STATE_DIR/" in
    "$WORKDIR/"*) echo "CLAUDE_ERROR: 상태 디렉터리는 검토 저장소 밖이어야 한다('$STATE_DIR')"; exit 3 ;;
esac
case "$WORKDIR/" in
    "$STATE_DIR/"*) echo "CLAUDE_ERROR: 작업 디렉터리는 상태 디렉터리 밖이어야 한다('$WORKDIR')"; exit 3 ;;
esac
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null
find "$STATE_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.stderr' -o -name '*.last.md' \
    -o -name '*.status.txt' -o -name '*.head.txt' -o -name '*.diff.patch' \) \
    -mtime +"$LOG_DAYS" -delete 2>/dev/null
find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -mtime +"$LOG_DAYS" \
    -exec rm -rf -- {} + 2>/dev/null
find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -name 'session-*' -mtime +"$LOG_DAYS" \
    -exec rm -rf -- {} + 2>/dev/null
TS="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$STATE_DIR/run-$TS"
mkdir -m 700 "$RUN_DIR"
EVIDENCE_DIR="$RUN_DIR/evidence"
mkdir -m 700 "$EVIDENCE_DIR"
LOG="$RUN_DIR/result.json"
ERR="$RUN_DIR/stderr.log"
OUT="$RUN_DIR/final.md"
STATUS_FILE="$EVIDENCE_DIR/status.txt"
HEAD_FILE="$EVIDENCE_DIR/head.txt"
DIFF_FILE="$EVIDENCE_DIR/diff.patch"
UNTRACKED_FILE="$EVIDENCE_DIR/untracked.txt"

# 검토 세션마다 별도 홈을 사용해 다른 세션의 기록을 노출하지 않는다.
if [ "$MODE" = "new" ]; then
    SESSION="$(python3 -c 'import uuid; print(uuid.uuid4())')"
fi
SESSION_HOME="$STATE_DIR/session-$SESSION"
if [ "$MODE" = "resume" ] && [ ! -d "$SESSION_HOME" ]; then
    echo "CLAUDE_ERROR: 저장된 세션을 찾을 수 없다('$SESSION'). new 세션으로 다시 시작하라."
    exit 3
fi
if [ "$MODE" = "new" ]; then
    mkdir -m 700 "$SESSION_HOME"
fi
touch "$SESSION_HOME"

# 호스트 Claude의 모델 선택만 리뷰어에 이어 준다 (hooks·권한·env·플러그인은 계속 격리)
# 새 세션마다 다시 읽어 /model 변경과 새 모델 별칭을 스크립트 수정 없이 따라간다.
HOST_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ "$MODE" = "new" ] && [ -r "$HOST_SETTINGS" ]; then
    mkdir -p -m 700 "$SESSION_HOME/.claude"
    if ! jq '{model, effortLevel, modelSettings} | with_entries(select(.value != null))' \
        "$HOST_SETTINGS" >"$SESSION_HOME/.claude/settings.json" 2>/dev/null; then
        # 설정이 깨져 있으면 CLI 기본값으로 진행한다.
        rm -f "$SESSION_HOME/.claude/settings.json"
    fi
fi

# 4. Claude에 Bash를 주지 않고, 로컬에서 검증된 Git 조회 결과만 준비한다.
BASE_SHA="${CROSSCHECK_BASE_SHA:-HEAD}"
echo "$BASE_SHA" | grep -qE '^(HEAD|[0-9a-fA-F]{7,40})$' \
    || { echo "CLAUDE_ERROR: 기준 커밋 형식이 잘못됐다('$BASE_SHA')"; exit 3; }
if ! CROSSCHECK_REVIEW_ROOT="$WORKDIR" "$GIT_READER" status >"$STATUS_FILE" \
    || ! CROSSCHECK_REVIEW_ROOT="$WORKDIR" "$GIT_READER" head >"$HEAD_FILE" \
    || ! CROSSCHECK_REVIEW_ROOT="$WORKDIR" "$GIT_READER" diff "$BASE_SHA" >"$DIFF_FILE" \
    || ! CROSSCHECK_REVIEW_ROOT="$WORKDIR" "$GIT_READER" untracked >"$UNTRACKED_FILE"; then
    echo "CLAUDE_ERROR: 읽기 전용 Git 검토 자료를 만들지 못했다"
    exit 3
fi

FORMAT='--- 응답 형식 (반드시 준수) ---
첫 줄: "VERDICT: AGREE" / "VERDICT: DISAGREE" / "VERDICT: NEED_INFO" 중 하나.
DISAGREE 지적은 "#1 [blocking] 내용 (파일:라인)" 형식으로 1부터 연속 번호를 붙인다.
이후 근거 bullet 최대 7개, 전체 3000자 이내. 응답 언어는 요청 언어를 따른다.
코드를 수정하거나 다른 에이전트·스킬을 호출하지 않는다.'
FORMAT="$FORMAT
Git 상태·HEAD·$BASE_SHA 기준 diff는 다음 읽기 전용 자료를 사용한다:
- status: /evidence/status.txt
- HEAD: /evidence/head.txt
- diff: /evidence/diff.patch
- untracked files: /evidence/untracked.txt
대상 저장소는 /workspace에 읽기 전용으로 마운트되어 있다.
diff에는 미추적 파일 내용이 없으므로 untracked 목록의 각 파일을 /workspace에서 직접 Read한 뒤 판정한다."
FULL_PROMPT="$PROMPT

$FORMAT"

# 5. 사용자 커스터마이징을 끄고 읽기 전용 내장 도구만 노출한다.
ALLOWED_TOOLS='Read,Glob,Grep'
DISALLOWED_TOOLS='Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task,Workflow,ToolSearch,SendMessage,RemoteTrigger,CronCreate,PushNotification,EnterWorktree,Skill'
ARGS=(-p --output-format json --safe-mode --permission-mode dontAsk --tools "$ALLOWED_TOOLS" \
    --allowedTools "$ALLOWED_TOOLS" --disallowedTools "$DISALLOWED_TOOLS" \
    --add-dir /evidence --prompt-suggestions false)
if [ "$MODE" = "resume" ]; then
    ARGS+=(--resume "$SESSION")
else
    ARGS+=(--session-id "$SESSION")
fi
if [ -n "${CLAUDE_MODEL:-}" ]; then
    ARGS+=(--model "$CLAUDE_MODEL")
fi
if [ -n "${CLAUDE_EFFORT:-}" ]; then
    ARGS+=(--effort "$CLAUDE_EFFORT")
fi

# 인증 비밀은 파일이나 환경이 아니라 일회성 파이프로만 샌드박스에 전달한다.
AUTH_SECRET="${CLAUDE_CODE_OAUTH_TOKEN:-}"
AUTH_FD_VAR='CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR'
if [ -z "$AUTH_SECRET" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    AUTH_SECRET="$ANTHROPIC_API_KEY"
    AUTH_FD_VAR='CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR'
fi
if [ -z "$AUTH_SECRET" ] && [ -r "$HOME/.claude/.credentials.json" ]; then
    AUTH_SECRET="$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json")"
fi
if [ -z "$AUTH_SECRET" ]; then
    echo "CLAUDE_AUTH_ERROR: 샌드박스에 전달할 Claude 인증 토큰이 없다"
    exit 1
fi
exec 9< <(printf '%s' "$AUTH_SECRET")
unset AUTH_SECRET CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY

CLAUDE_BIN="$(readlink -f "$(command -v claude)")"
BWRAP_BIN="$(command -v bwrap)"
ENV_BIN="$(command -v env)"
TIMEOUT_BIN="$(command -v timeout)"
RESOLV_TARGET="$(readlink -f /etc/resolv.conf)"
[ -r "$RESOLV_TARGET" ] || { echo "CLAUDE_ERROR: DNS 설정을 읽을 수 없다"; exit 1; }
ETC_ARGS=(--dir /etc --ro-bind "$RESOLV_TARGET" /etc/resolv.conf)
for system_path in /etc/ssl /etc/hosts /etc/nsswitch.conf /etc/passwd /etc/group /etc/localtime; do
    if [ -e "$system_path" ]; then
        ETC_ARGS+=(--ro-bind "$system_path" "$system_path")
    fi
done

# 대상 저장소·현재 증거·현재 세션 홈만 노출하고 사용자 홈과 다른 저장소는 숨긴다.
"$ENV_BIN" -i PATH=/usr/bin:/bin HOME=/reviewer-home CLAUDE_CONFIG_DIR=/reviewer-home/.claude \
    "$AUTH_FD_VAR=9" "$TIMEOUT_BIN" -k 10 "$TIMEOUT_SEC" \
    "$BWRAP_BIN" --die-with-parent --unshare-all --share-net \
    --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
    "${ETC_ARGS[@]}" --dev /dev --proc /proc --tmpfs /tmp \
    --dir /workspace --ro-bind "$WORKDIR" /workspace \
    --dir /evidence --ro-bind "$EVIDENCE_DIR" /evidence \
    --dir /reviewer-home --bind "$SESSION_HOME" /reviewer-home \
    --ro-bind "$CLAUDE_BIN" /claude --chdir /workspace \
    -- /claude "${ARGS[@]}" "$FULL_PROMPT" >"$LOG" 2>"$ERR"
RC=$?
exec 9<&-

# 6. 원로그를 노출하지 않고 실패 유형만 분류한다.
if [ $RC -ne 0 ]; then
    ERRTXT="$(tail -20 "$ERR" 2>/dev/null)"
    RESULT_STATUS="$(jq -r 'if type == "object" then (.result // "") else "" end' "$LOG" 2>/dev/null || true)"
    if [ $RC -eq 124 ]; then
        echo "CLAUDE_TIMEOUT: ${TIMEOUT_SEC}s 초과 (log: $LOG)"
    elif echo "$RESULT_STATUS" | grep -qiE 'request timed out|timed out'; then
        echo "CLAUDE_TIMEOUT: Claude 내부 요청 시간 초과 (log: $LOG)"
    elif echo "$ERRTXT" | grep -qiE 'not logged in|unauthorized|401|login required|token .*(expired|invalid)'; then
        echo "CLAUDE_AUTH_ERROR: exit $RC (log: $LOG)"
    elif echo "$ERRTXT" | grep -qiE 'usage limit|rate limit|quota|429|too many requests'; then
        echo "CLAUDE_QUOTA_ERROR: exit $RC (log: $LOG)"
    else
        echo "CLAUDE_ERROR: exit $RC (log: $LOG)"
    fi
    exit $RC
fi

if ! jq -e 'type == "object"' "$LOG" >/dev/null 2>&1; then
    echo "SESSION: UNKNOWN"
    echo "CLAUDE_FORMAT_WARNING: JSON 응답을 해석할 수 없다"
    exit 5
fi

SID="$(jq -r '.session_id // empty' "$LOG")"
jq -r 'select((.result // "") != "") | .result' "$LOG" >"$OUT"
echo "SESSION: ${SID:-UNKNOWN}"

if [ -z "$SID" ]; then
    echo "CLAUDE_FORMAT_WARNING: 세션 ID가 비었다"
    exit 5
fi

if [ "$SID" != "$SESSION" ]; then
    echo "CLAUDE_FORMAT_WARNING: 요청 세션과 응답 세션이 다르다"
    exit 5
fi

if jq -e '.is_error == true' "$LOG" >/dev/null 2>&1; then
    echo "CLAUDE_ERROR: Claude가 오류 결과를 반환했다 (log: $LOG)"
    exit 1
fi

# 7. 판정 계약을 검사하고 최종 메시지만 제한된 길이로 출력한다.
if [ ! -s "$OUT" ]; then
    echo "CLAUDE_FORMAT_WARNING: 최종 응답이 비었다"
    exit 5
else
    FIRST_LINE="$(head -1 "$OUT")"
    case "$FIRST_LINE" in
        "VERDICT: AGREE"|"VERDICT: DISAGREE"|"VERDICT: NEED_INFO") ;;
        *) echo "CLAUDE_FORMAT_WARNING: 첫 줄이 VERDICT 형식 아님" ;;
    esac
    if [ "$FIRST_LINE" = "VERDICT: DISAGREE" ]; then
        if ! grep -qE '^#1 \[(blocking|minor)\] ' "$OUT"; then
            echo "CLAUDE_FORMAT_WARNING: DISAGREE인데 '#1 [blocking|minor]' 지적 없음"
        fi
        BAD="$(grep -cE '^#[0-9]+ ' "$OUT")"
        GOOD="$(grep -cE '^#[0-9]+ \[(blocking|minor)\] ' "$OUT")"
        if [ "$BAD" -ne "$GOOD" ]; then
            echo "CLAUDE_FORMAT_WARNING: 심각도 표기 없는 지적 $((BAD - GOOD))건"
        fi
        if [ "$(grep -oE '^#[0-9]+' "$OUT" | tr -d '#' \
                | awk '{n++; if ($1 != n) bad=1} END{print bad+0}')" = "1" ]; then
            echo "CLAUDE_FORMAT_WARNING: 지적 번호가 1부터 연속이 아니다(중복·건너뜀)"
        fi
    fi
    CHARS="$(OUT="$OUT" python3 -c 'import io,os; print(len(io.open(os.environ["OUT"], encoding="utf-8", errors="replace").read()))')"
    [ "$CHARS" -le 3000 ] || echo "CLAUDE_FORMAT_WARNING: 응답 ${CHARS}자 — 3000자 초과"
    BULLETS="$(grep -cE '^[[:space:]]*[-*+] ' "$OUT")"
    [ "$BULLETS" -le 7 ] || echo "CLAUDE_FORMAT_WARNING: 근거 bullet ${BULLETS}개 — 7개 초과"
fi
echo "---"

if [ -s "$OUT" ]; then
    MAX_CHARS="$MAX_CHARS" OUT="$OUT" python3 - <<'PY'
import io
import os
import signal
import sys

signal.signal(signal.SIGPIPE, signal.SIG_DFL)
path = os.environ["OUT"]
limit = int(os.environ["MAX_CHARS"])
text = io.open(path, encoding="utf-8", errors="replace").read()
shown = text[:limit]
sys.stdout.write(shown)
if not shown.endswith("\n"):
    sys.stdout.write("\n")
if len(text) > limit:
    sys.stdout.write(f"...[잘림 — 전문: {path}]\n")
PY
else
    echo "NO_OUTPUT (log: $LOG)"
fi
