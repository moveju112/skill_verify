#!/usr/bin/env bash
# 공용 verify 원본을 세 런타임에 연결한다. 모델 호출·패키지 설치는 하지 않는다.
set -euo pipefail

repositoryRoot="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
sharedSkill="$HOME/.agents/skills/verify"
claudeSkill="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/verify"
codexSkill="${CODEX_HOME:-$HOME/.codex}/skills/verify"

# 1. 사용자 소유의 일반 파일·디렉터리는 덮어쓰지 않고 전체 작업 전에 중단한다.
for target in "$sharedSkill" "$claudeSkill" "$codexSkill"; do
    if [[ -e "$target" && ! -L "$target" ]]; then
        printf '설치 중단: 기존 일반 파일/디렉터리를 먼저 이동하세요: %s\n' "$target" >&2
        exit 1
    fi
done

# 2. 서버마다 다른 체크아웃 경로를 현재 위치에서 계산한다.
mkdir -p "$(dirname "$sharedSkill")" "$(dirname "$claudeSkill")" "$(dirname "$codexSkill")"
ln -sfnT "$repositoryRoot/skills/verify" "$sharedSkill"
ln -sfnT "$sharedSkill" "$claudeSkill"
ln -sfnT "$sharedSkill" "$codexSkill"

# 3. pi는 ~/.agents/skills를 직접 탐색하므로 중복 링크를 만들지 않는다.
printf '공용 verify 설치 완료: %s\n' "$sharedSkill"
printf 'pi: /reload 후 /skill:verify; Claude·Codex: 새 세션에서 사용하세요.\n'
