#!/usr/bin/env bash
# proj-launcher setup for macOS / Linux
# Usage: bash setup.sh

set -euo pipefail

GREEN='\033[32m' RED='\033[31m' YELLOW='\033[33m' RESET='\033[0m'
ok()   { printf "${GREEN}[OK]${RESET} %s\n" "$*"; }
fail() { printf "${RED}[FAIL]${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_ZSH="$SCRIPT_DIR/proj.zsh"

# ── 의존성 체크 ──────────────────────────────────────────────
echo "의존성 확인 중..."
missing=0

for cmd in git fzf jq; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd ($(command -v "$cmd"))"
  else
    fail "$cmd 이 설치되어 있지 않습니다"
    missing=1
  fi
done

if (( missing )); then
  echo ""
  warn "누락된 도구를 먼저 설치하세요:"
  echo "  macOS:  brew install fzf jq"
  echo "  Ubuntu: sudo apt install fzf jq"
  exit 1
fi

# ── 프로젝트 루트 확인 ───────────────────────────────────────
PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/projects}"
if [[ ! -d "$PROJECTS_ROOT" ]]; then
  mkdir -p "$PROJECTS_ROOT"
  ok "프로젝트 루트 생성: $PROJECTS_ROOT"
else
  ok "프로젝트 루트: $PROJECTS_ROOT"
fi

# ── 쉘 프로필에 source 라인 추가 ─────────────────────────────
SOURCE_LINE="source \"$PROJ_ZSH\""

add_to_profile() {
  local profile="$1"
  if [[ -f "$profile" ]] && grep -qF "proj.zsh" "$profile"; then
    ok "이미 등록됨: $profile"
    return
  fi
  echo "" >> "$profile"
  echo "# proj-launcher" >> "$profile"
  echo "$SOURCE_LINE" >> "$profile"
  ok "추가 완료: $profile"
}

SHELL_NAME="$(basename "$SHELL")"
case "$SHELL_NAME" in
  zsh)
    add_to_profile "$HOME/.zshrc"
    ;;
  bash)
    if [[ -f "$HOME/.bash_profile" ]]; then
      add_to_profile "$HOME/.bash_profile"
    else
      add_to_profile "$HOME/.bashrc"
    fi
    ;;
  *)
    warn "알 수 없는 쉘: $SHELL_NAME"
    echo "  아래 라인을 쉘 프로필에 직접 추가하세요:"
    echo "  $SOURCE_LINE"
    ;;
esac

# ── 완료 ─────────────────────────────────────────────────────
echo ""
echo "설치 완료! 새 터미널을 열거나 아래 명령어를 실행하세요:"
echo "  source ~/.zshrc   # 또는 source ~/.bashrc"
echo ""
echo "사용법:"
echo "  proj              # 프로젝트 런처 시작"
