#!/usr/bin/env bash
# codex 호출 방화벽 — codex 원출력은 로그 파일에 가두고,
# 최종 메시지만 상한(기본 6000자)으로 잘라 stdout에 낸다 (토큰 누수 방지)
#
# 사용법:
#   codex_ask.sh check                                  # 프리플라이트 (로그인 상태, 토큰 소모 없음)
#   codex_ask.sh new    [-C 작업디렉터리] "프롬프트"
#   codex_ask.sh resume <세션ID|last> [-C 작업디렉터리] "프롬프트"
#   프롬프트가 '-' 이면 stdin에서 읽는다 (긴 프롬프트용)
#
# 환경변수:
#   CROSSCHECK_MAX_CHARS  stdout 상한 (기본 6000)
#   CROSSCHECK_SANDBOX    codex 샌드박스 (기본 read-only)
#   CODEX_MODEL           모델 지정 (기본 codex 설정값)
#   CROSSCHECK_STATE_DIR  로그 보관 위치 (기본 ~/.cache/codex-crosscheck)
set -uo pipefail

usage() { echo "usage: codex_ask.sh check | new|resume [<session|last>] [-C dir] \"prompt\"" >&2; exit 2; }

# 1. 인자 파싱
MODE="${1:-}"; shift || true

# check 모드 — 호출 전 프리플라이트 (로그인 여부만, 토큰 소모 없음)
if [ "$MODE" = "check" ]; then
    if ! command -v codex >/dev/null 2>&1; then
        echo "CODEX_NOT_INSTALLED"; exit 1
    fi
    STATUS="$(codex login status 2>&1)"
    if [ $? -eq 0 ]; then
        echo "CODEX_OK: $STATUS"; exit 0
    else
        echo "CODEX_AUTH_ERROR: $STATUS"; exit 1
    fi
fi
SESSION=""
if [ "$MODE" = "resume" ]; then
    SESSION="${1:-}"; shift || true
    [ -n "$SESSION" ] || usage
elif [ "$MODE" != "new" ]; then
    usage
fi

WORKDIR="$PWD"
if [ "${1:-}" = "-C" ]; then
    WORKDIR="${2:?-C needs dir}"; shift 2
fi

PROMPT="${1:-}"
[ -n "$PROMPT" ] || usage
if [ "$PROMPT" = "-" ]; then
    PROMPT="$(cat)"
fi

# 2. 상태 디렉터리·로그 경로 준비
MAX_CHARS="${CROSSCHECK_MAX_CHARS:-6000}"
SANDBOX="${CROSSCHECK_SANDBOX:-read-only}"
STATE_DIR="${CROSSCHECK_STATE_DIR:-$HOME/.cache/codex-crosscheck}"
mkdir -p "$STATE_DIR"
TS="$(date +%Y%m%d-%H%M%S)-$$"
LOG="$STATE_DIR/$TS.jsonl"
OUT="$STATE_DIR/$TS.last.md"

# 3. 응답 형식 지시를 프롬프트 뒤에 강제 부착 (장문 응답 차단)
FORMAT='--- 응답 형식 (반드시 준수) ---
첫 줄: "VERDICT: AGREE" / "VERDICT: DISAGREE" / "VERDICT: NEED_INFO" 중 하나.
이후 근거 bullet 최대 7개. 각 bullet 한 줄, 가능하면 파일경로:라인 인용.
10줄 넘는 코드 블록 금지. 전체 3000자 이내. 한국어.'
FULL_PROMPT="$PROMPT

$FORMAT"

# 4. codex 실행 — 원출력 전부 로그 파일로, 최종 메시지는 OUT 파일로
# resume은 -s/-C 미지원 (샌드박스·cwd는 원 세션 설정을 따라감)
ARGS=(--json --skip-git-repo-check -o "$OUT")
if [ "$MODE" = "new" ]; then
    ARGS+=(-s "$SANDBOX" -C "$WORKDIR")
fi
if [ -n "${CODEX_MODEL:-}" ]; then
    ARGS+=(-m "$CODEX_MODEL")
fi

if [ "$MODE" = "new" ]; then
    codex exec "${ARGS[@]}" - <<<"$FULL_PROMPT" >"$LOG" 2>&1
elif [ "$SESSION" = "last" ]; then
    codex exec resume --last "${ARGS[@]}" - <<<"$FULL_PROMPT" >"$LOG" 2>&1
else
    codex exec resume "$SESSION" "${ARGS[@]}" - <<<"$FULL_PROMPT" >"$LOG" 2>&1
fi
RC=$?

# 5. 실패 시 원인 분류 후 로그 꼬리만 잘라 보고
#    CODEX_AUTH_ERROR = 로그인 풀림 / CODEX_QUOTA_ERROR = 사용량 한도 / CODEX_ERROR = 기타
if [ $RC -ne 0 ]; then
    if grep -qiE 'not logged in|unauthorized|401|login required|token .*(expired|invalid)' "$LOG" 2>/dev/null; then
        echo "CODEX_AUTH_ERROR: exit $RC (log: $LOG)"
    elif grep -qiE 'usage limit|rate limit|quota|429|too many requests' "$LOG" 2>/dev/null; then
        echo "CODEX_QUOTA_ERROR: exit $RC (log: $LOG)"
    else
        echo "CODEX_ERROR: exit $RC (log: $LOG)"
    fi
    tail -c 1500 "$LOG" 2>/dev/null
    exit $RC
fi

# 6. 세션 ID 추출 (없으면 'last'로 대체 — resume --last 사용)
SID="$(grep -oE '"(thread_id|session_id|conversation_id)":"[0-9a-f]{8}-[0-9a-f-]{27}"' "$LOG" \
    | head -1 | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27}')"
echo "SESSION: ${SID:-last}"
echo "---"

# 7. 최종 메시지만 상한 잘라 출력 — 이 stdout만 Claude 컨텍스트에 들어간다
if [ -s "$OUT" ]; then
    head -c "$MAX_CHARS" "$OUT"
    echo
    if [ "$(wc -c <"$OUT")" -gt "$MAX_CHARS" ]; then
        echo "...[잘림 — 전문: $OUT]"
    fi
else
    echo "NO_OUTPUT (log: $LOG)"
fi
