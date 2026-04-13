#!/usr/bin/env bash
# 스크린샷 촬영용 더미 프로젝트 생성
# Usage: bash demo-setup.sh
# 촬영 후: bash demo-setup.sh --clean

set -euo pipefail

DEMO_ROOT="$HOME/projects-demo"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$DEMO_ROOT"
  echo "정리 완료: $DEMO_ROOT 삭제됨"
  exit 0
fi

mkdir -p "$DEMO_ROOT"

# ── 더미 프로젝트 생성 ──────────────────────────────────────
projects=(
  "recipe-finder:Web:레시피 검색 앱"
  "budget-tracker:Tool:가계부 CLI"
  "weather-bot:Bot:날씨 알림 텔레그램 봇"
  "ml-playground:AI:머신러닝 실험실"
  "blog-engine:Web:정적 블로그 생성기"
  "home-automation:Infra:홈 자동화 스크립트"
  "game-of-life:Game:Conway's Game of Life"
  "api-gateway:Infra:API 게이트웨이 프록시"
)

for entry in "${projects[@]}"; do
  IFS=':' read -r name cat desc <<< "$entry"
  pdir="$DEMO_ROOT/$name"
  mkdir -p "$pdir"
  git -C "$pdir" init -b main &>/dev/null

  cat > "$pdir/CLAUDE.md" << EOF
# $name

> $desc
EOF

  cat > "$pdir/ROADMAP.md" << EOF
# $name ROADMAP

## v1.0
- [x] 프로젝트 초기화
- [x] 기본 구조 설계
- [ ] 핵심 기능 구현
- [ ] 테스트 작성
- [ ] 배포 설정
EOF

  cat > "$pdir/.gitignore" << 'EOF'
.claude/worktrees/
.claude/.last-opened
EOF

  git -C "$pdir" add -A &>/dev/null
  git -C "$pdir" commit -m "init" &>/dev/null
done

# ── 메타데이터 (pin/archive 데모용) ─────────────────────────
cat > "$DEMO_ROOT/.proj-meta.json" << 'EOF'
{
  "recipe-finder": { "cat": "Web", "desc": "레시피 검색 앱", "pin": true },
  "budget-tracker": { "cat": "Tool", "desc": "가계부 CLI", "pin": true },
  "weather-bot": { "cat": "Bot", "desc": "날씨 알림 텔레그램 봇" },
  "ml-playground": { "cat": "AI", "desc": "머신러닝 실험실" },
  "blog-engine": { "cat": "Web", "desc": "정적 블로그 생성기" },
  "home-automation": { "cat": "Infra", "desc": "홈 자동화 스크립트" },
  "game-of-life": { "cat": "Game", "desc": "Conway's Game of Life", "archive": true },
  "api-gateway": { "cat": "Infra", "desc": "API 게이트웨이 프록시" }
}
EOF

# ── last-opened 타임스탬프 (정렬 데모용) ─────────────────────
now=$(date +%s)
offsets=(0 3600 86400 172800 604800 1209600 2592000 7776000)
i=0
for entry in "${projects[@]}"; do
  name="${entry%%:*}"
  [[ "$name" == "game-of-life" ]] && { ((i++)); continue; }  # archive 제외
  pdir="$DEMO_ROOT/$name"
  mkdir -p "$pdir/.claude"
  offset=${offsets[$i]:-0}
  ts=$(( now - offset ))
  if [[ "$(uname)" == "Darwin" ]]; then
    date -r "$ts" -u +'%Y-%m-%dT%H:%M:%SZ' > "$pdir/.claude/.last-opened"
  else
    date -u -d "@$ts" +'%Y-%m-%dT%H:%M:%SZ' > "$pdir/.claude/.last-opened"
  fi
  # macOS: touch로 mtime 설정
  if [[ "$(uname)" == "Darwin" ]]; then
    touch -t "$(date -r "$ts" +'%Y%m%d%H%M.%S')" "$pdir/.claude/.last-opened"
  fi
  ((i++))
done

echo "더미 프로젝트 생성 완료: $DEMO_ROOT"
echo ""
echo "스크린샷 촬영:"
echo "  PROJECTS_ROOT=$DEMO_ROOT proj"
echo ""
echo "정리:"
echo "  bash demo-setup.sh --clean"
