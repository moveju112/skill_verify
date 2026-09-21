#!/usr/bin/env bash
# 임시 홈과 공백이 있는 체크아웃에서 설치·이동·호환 링크를 검증한다.
set -euo pipefail
repositoryRoot="$(cd "$(dirname "$0")/.." && pwd -P)"
workDirectory="$(mktemp -d)"
trap 'rm -rf "$workDirectory"' EXIT
export HOME="$workDirectory/home"
unset CLAUDE_CONFIG_DIR CODEX_HOME
mkdir -p "$HOME" "$workDirectory/checkout one"
cp -a "$repositoryRoot/skills" "$repositoryRoot/platforms" "$repositoryRoot/scripts" "$workDirectory/checkout one/"
checkout="$workDirectory/checkout one"

# 1. 같은 설치를 반복해도 동일 원본을 가리키며 pi 중복 링크가 생기지 않는다.
bash "$checkout/scripts/install-shared.sh" >/dev/null
bash "$checkout/scripts/install-shared.sh" >/dev/null
for runtime in .agents .claude .codex; do
    [[ "$(readlink -f "$HOME/$runtime/skills/verify")" == "$checkout/skills/verify" ]]
done
[[ ! -e "$HOME/.pi/agent/skills/verify" ]]
[[ "$(readlink -f "$checkout/platforms/codex/verify/SKILL.md")" == "$checkout/skills/verify/SKILL.md" ]]
for name in claude_ask codex_ask review_git; do
    [[ -f "$checkout/skills/verify/scripts/$name.sh" && ! -L "$checkout/skills/verify/scripts/$name.sh" ]]
    [[ "$(readlink -f "$checkout/platforms/codex/verify/scripts/$name.sh")" == "$checkout/skills/verify/scripts/$name.sh" ]]
    bash -n "$checkout/skills/verify/scripts/$name.sh"
done
[[ "$(readlink -f "$checkout/skills/crosscheck/scripts/codex_ask.sh")" == "$checkout/skills/verify/scripts/codex_ask.sh" ]]
echo 'PASS: 반복 설치·단일 원본·기존 진입점 호환·스크립트 문법'

# 2. 다른 경로로 옮긴 저장소에서도 재설치만으로 연결을 복구한다.
mv "$checkout" "$workDirectory/checkout two"
checkout="$workDirectory/checkout two"
bash "$checkout/scripts/install-shared.sh" >/dev/null
[[ "$(readlink -f "$HOME/.agents/skills/verify")" == "$checkout/skills/verify" ]]
export CLAUDE_CONFIG_DIR="$HOME/custom claude" CODEX_HOME="$HOME/custom codex"
bash "$checkout/scripts/install-shared.sh" >/dev/null
[[ "$(readlink -f "$CLAUDE_CONFIG_DIR/skills/verify")" == "$checkout/skills/verify" ]]
[[ "$(readlink -f "$CODEX_HOME/skills/verify")" == "$checkout/skills/verify" ]]
echo 'PASS: 서버 경로 독립성·설정 디렉터리 재정의'

# 3. 기존 일반 디렉터리가 있으면 어떠한 링크도 만들기 전에 거부한다.
export HOME="$workDirectory/protected home"
unset CLAUDE_CONFIG_DIR CODEX_HOME
mkdir -p "$HOME/.codex/skills/verify"
printf 'keep\n' > "$HOME/.codex/skills/verify/existing.txt"
if bash "$checkout/scripts/install-shared.sh" >"$workDirectory/refusal.log" 2>&1; then
    echo 'FAIL: 기존 디렉터리를 덮어쓰는 설치가 허용됨' >&2
    exit 1
fi
[[ ! -e "$HOME/.agents/skills/verify" ]]
[[ ! -e "$HOME/.claude/skills/verify" ]]
[[ "$(<"$HOME/.codex/skills/verify/existing.txt")" == keep ]]
echo 'PASS: 기존 사용자 파일 보호·사전 검사'
