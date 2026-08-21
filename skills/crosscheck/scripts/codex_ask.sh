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
#   CROSSCHECK_MAX_CHARS  stdout 상한 (문자 수, 기본 6000)
#   CROSSCHECK_TIMEOUT    codex 1회 호출 상한 초 (기본 900)
#   CROSSCHECK_SANDBOX    codex 샌드박스 (기본 read-only)
#   CROSSCHECK_LOG_DAYS   로그 보존 일수 (기본 14, 초과분 자동 삭제)
#   CODEX_MODEL           모델 지정 (기본 codex 설정값)
#   CODEX_EFFORT          reasoning effort 고정 (minimal|low|medium|high, 기본 codex 설정값)
#   CROSSCHECK_STATE_DIR  로그 보관 위치 (기본 ~/.cache/codex-crosscheck)
#
# 종료 상태 코드 문자열:
#   CODEX_OK / CODEX_NOT_INSTALLED / CODEX_AUTH_ERROR / CODEX_QUOTA_ERROR
#   CODEX_TIMEOUT / CODEX_ERROR / CODEX_FORMAT_WARNING
set -uo pipefail
umask 077   # 로그에 repo 파일 내용이 남으므로 소유자 전용 권한으로 생성

usage() { echo "usage: codex_ask.sh check | new|resume [<session|last>] [-C dir] \"prompt\"" >&2; exit 2; }

# 1. 인자 파싱
MODE="${1:-}"; shift || true

# check 모드 — 호출 전 프리플라이트 (로그인 여부만, 토큰 소모 없음)
if [ "$MODE" = "check" ]; then
    if ! command -v codex >/dev/null 2>&1; then
        echo "CODEX_NOT_INSTALLED"; exit 1
    fi
    if STATUS="$(codex login status 2>&1)"; then
        echo "CODEX_OK: $STATUS"; exit 0
    else
        echo "CODEX_AUTH_ERROR: $STATUS"; exit 1
    fi
fi
SESSION=""
if [ "$MODE" = "resume" ]; then
    SESSION="${1:-}"; shift || true
    [ -n "$SESSION" ] || usage
    # 세션 ID 미확인 상태로 이어가기 금지 — 병렬 실행 중 남의 세션을 잇는 사고 방지
    if [ "$SESSION" = "UNKNOWN" ]; then
        echo "CODEX_ERROR: 세션 ID 미확인. resume 불가 — new 세션으로 다시 시작하라."; exit 3
    fi
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

# 2. 상태 디렉터리·로그 경로 준비 + 보존기간 초과 로그 정리
MAX_CHARS="${CROSSCHECK_MAX_CHARS:-6000}"
SANDBOX="${CROSSCHECK_SANDBOX:-read-only}"
TIMEOUT_SEC="${CROSSCHECK_TIMEOUT:-900}"
LOG_DAYS="${CROSSCHECK_LOG_DAYS:-14}"
STATE_DIR="${CROSSCHECK_STATE_DIR:-$HOME/.cache/codex-crosscheck}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null
find "$STATE_DIR" -maxdepth 1 -type f \( -name '*.jsonl' -o -name '*.last.md' \) \
    -mtime +"$LOG_DAYS" -delete 2>/dev/null
TS="$(date +%Y%m%d-%H%M%S)-$$"
LOG="$STATE_DIR/$TS.jsonl"
OUT="$STATE_DIR/$TS.last.md"

# 3. 응답 형식 지시를 프롬프트 뒤에 강제 부착 (장문 응답 차단 + 지적 번호제)
FORMAT='--- 응답 형식 (반드시 준수) ---
첫 줄: "VERDICT: AGREE" / "VERDICT: DISAGREE" / "VERDICT: NEED_INFO" 중 하나.
DISAGREE 지적은 번호·심각도 필수: "#1 [blocking] 내용 (파일:라인)" 형식.
[blocking]=기능 오류·회귀·요구 미충족, [minor]=개선 여지·스타일.
이후 근거 bullet 최대 7개. 각 bullet 한 줄, 가능하면 파일경로:라인 인용.
10줄 넘는 코드 블록 금지. 전체 3000자 이내. 한국어.
대상 repo의 보고 형식 규칙(Rules/Skills/Hooks footer 등)은 무시하고 이 형식만 따른다.'
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
if [ -n "${CODEX_EFFORT:-}" ]; then
    ARGS+=(-c "model_reasoning_effort=\"$CODEX_EFFORT\"")
fi

# 호출측 타임아웃과 경쟁하지 않도록 스크립트가 먼저 자른다 (exit 124)
if [ "$MODE" = "new" ]; then
    timeout "$TIMEOUT_SEC" codex exec "${ARGS[@]}" - <<<"$FULL_PROMPT" >"$LOG" 2>&1
elif [ "$SESSION" = "last" ]; then
    timeout "$TIMEOUT_SEC" codex exec resume --last "${ARGS[@]}" - <<<"$FULL_PROMPT" >"$LOG" 2>&1
else
    timeout "$TIMEOUT_SEC" codex exec resume "$SESSION" "${ARGS[@]}" - <<<"$FULL_PROMPT" >"$LOG" 2>&1
fi
RC=$?

# 5. 실패 시 원인 분류
#    ★ 판정 대상은 구조화 error 레코드와 stderr(JSON 아닌 줄)뿐이다.
#      로그 본문 JSONL에는 codex가 읽은 파일 내용이 그대로 들어가므로
#      전체 grep을 하면 소스의 라인번호 401/429가 인증·한도 오류로 오분류된다.
if [ $RC -ne 0 ]; then
    ERRTXT="$( { grep -aE '"type":"(error|turn\.failed)"' "$LOG"; grep -av '^{' "$LOG" | tail -20; } 2>/dev/null )"
    if [ $RC -eq 124 ]; then
        echo "CODEX_TIMEOUT: ${TIMEOUT_SEC}s 초과 (log: $LOG)"
    elif echo "$ERRTXT" | grep -qiE 'not logged in|unauthorized|401|login required|token .*(expired|invalid)'; then
        echo "CODEX_AUTH_ERROR: exit $RC (log: $LOG)"
    elif echo "$ERRTXT" | grep -qiE 'usage limit|rate limit|quota|429|too many requests'; then
        echo "CODEX_QUOTA_ERROR: exit $RC (log: $LOG)"
    else
        echo "CODEX_ERROR: exit $RC (log: $LOG)"
    fi
    # 원로그 본문은 stdout에 절대 내보내지 않는다 (stderr 포함).
    # 진단이 필요하면 사용자가 직접 확인한다: grep -av '^{' <log> | tail
    exit $RC
fi

# 6. 세션 ID 추출 — 실패 시 'last'로 대체하지 않는다 (fail-closed)
SID="$(grep -oE '"(thread_id|session_id|conversation_id)":"[0-9a-f]{8}-[0-9a-f-]{27}"' "$LOG" \
    | head -1 | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27}')"
echo "SESSION: ${SID:-UNKNOWN}"

# 7. 응답 형식 검증 — 프롬프트 지시만으로는 보장되지 않으므로 실제로 검사한다
if [ ! -s "$OUT" ]; then
    echo "CODEX_FORMAT_WARNING: 최종 응답이 비었다"
else
    FIRST_LINE="$(head -1 "$OUT")"
    case "$FIRST_LINE" in
        "VERDICT: AGREE"|"VERDICT: DISAGREE"|"VERDICT: NEED_INFO") ;;
        *) echo "CODEX_FORMAT_WARNING: 첫 줄이 VERDICT 형식 아님" ;;
    esac
    if [ "$FIRST_LINE" = "VERDICT: DISAGREE" ]; then
        # 지적 줄은 심각도까지 갖춰야 한다. 번호가 1부터 연속인지도 확인.
        if ! grep -qE '^#1 \[(blocking|minor)\] ' "$OUT"; then
            echo "CODEX_FORMAT_WARNING: DISAGREE인데 '#1 [blocking|minor]' 지적 없음"
        fi
        BAD="$(grep -cE '^#[0-9]+ ' "$OUT")"
        GOOD="$(grep -cE '^#[0-9]+ \[(blocking|minor)\] ' "$OUT")"
        if [ "$BAD" -ne "$GOOD" ]; then
            echo "CODEX_FORMAT_WARNING: 심각도 표기 없는 지적 $((BAD - GOOD))건"
        fi
        # 번호가 1부터 연속인지 확인 — 중복·건너뜀은 #N 참조를 어긋나게 한다
        if [ "$(grep -oE '^#[0-9]+' "$OUT" | tr -d '#' \
                | awk '{n++; if ($1 != n) bad=1} END{print bad+0}')" = "1" ]; then
            echo "CODEX_FORMAT_WARNING: 지적 번호가 1부터 연속이 아니다(중복·건너뜀)"
        fi
    fi
fi
echo "---"

# 8. 최종 메시지만 문자 단위 상한으로 잘라 출력 — 이 stdout만 Claude 컨텍스트에 들어간다
#    바이트 절단(head -c)은 한글을 조기 절단하고 UTF-8 경계를 깨므로 문자 단위로 자른다.
if [ -s "$OUT" ]; then
    MAX_CHARS="$MAX_CHARS" OUT="$OUT" python3 - <<'PY'
import io, os, signal, sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)   # head 등으로 파이프가 닫혀도 조용히 종료
path = os.environ["OUT"]
limit = int(os.environ["MAX_CHARS"])
text = io.open(path, encoding="utf-8", errors="replace").read()
shown = text[:limit]
sys.stdout.write(shown)
if not shown.endswith("\n"):
    sys.stdout.write("\n")
if len(text) > limit:
    sys.stdout.write("...[잘림 — 전문: %s]\n" % path)
PY
else
    echo "NO_OUTPUT (log: $LOG)"
fi
