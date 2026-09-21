#!/usr/bin/env bash
# Claude 검토용 Git 읽기 전용 게이트 — 변경·훅·외부 diff 실행 없이 필요한 조회만 제공한다.
set -uo pipefail

usage() {
    echo "usage: review_git.sh status | head | untracked | diff [HEAD|commit] [-- paths...]" >&2
    exit 2
}

ROOT="${CROSSCHECK_REVIEW_ROOT:-}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "REVIEW_GIT_ERROR: 검토 루트가 없다" >&2; exit 3; }
ROOT="$(realpath "$ROOT")"

# 1. 저장소 훅·fsmonitor를 끄고 조회 명령만 실행한다.
gitRead() {
    GIT_OPTIONAL_LOCKS=0 command git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$ROOT" "$@"
}

gitRead rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "REVIEW_GIT_ERROR: Git 저장소가 아니다('$ROOT')" >&2; exit 3; }

MODE="${1:-}"
shift || true

case "$MODE" in
    status)
        [ $# -eq 0 ] || usage
        gitRead status --short --untracked-files=all --ignore-submodules=all
        ;;
    head)
        [ $# -eq 0 ] || usage
        gitRead rev-parse HEAD
        ;;
    untracked)
        [ $# -eq 0 ] || usage
        gitRead ls-files --others --exclude-standard
        ;;
    diff)
        BASE=""
        if [ $# -gt 0 ] && [ "$1" != "--" ]; then
            BASE="$1"
            shift
            echo "$BASE" | grep -qE '^(HEAD|[0-9a-fA-F]{7,40})$' || usage
            gitRead cat-file -e "${BASE}^{commit}" 2>/dev/null \
                || { echo "REVIEW_GIT_ERROR: 기준 커밋이 없다('$BASE')" >&2; exit 3; }
        fi
        if [ "${1:-}" = "--" ]; then
            shift
        fi
        for path in "$@"; do
            case "$path" in
                ..|/*|../*|*/../*|*/..) usage ;;
            esac
        done
        if [ -n "$BASE" ]; then
            gitRead diff --no-ext-diff --no-textconv --ignore-submodules=all "$BASE" -- "$@"
        else
            gitRead diff --no-ext-diff --no-textconv --ignore-submodules=all -- "$@"
        fi
        ;;
    *)
        usage
        ;;
esac
