# 스크린샷 촬영용 더미 프로젝트 생성
# Usage: powershell -File demo-setup.ps1
# 정리:  powershell -File demo-setup.ps1 -Clean

param([switch]$Clean)

$demoRoot = "$HOME\projects-demo"

if ($Clean) {
    if (Test-Path $demoRoot) {
        Remove-Item -Path $demoRoot -Recurse -Force
        Write-Host "정리 완료: $demoRoot 삭제됨" -ForegroundColor Green
    } else {
        Write-Host "이미 없음: $demoRoot"
    }
    return
}

New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null

# ── 더미 프로젝트 정의 ──────────────────────────────────────
$projects = @(
    @{ Name="recipe-finder";    Cat="Web";   Desc="레시피 검색 앱" }
    @{ Name="budget-tracker";   Cat="Tool";  Desc="가계부 CLI" }
    @{ Name="weather-bot";      Cat="Bot";   Desc="날씨 알림 텔레그램 봇" }
    @{ Name="ml-playground";    Cat="AI";    Desc="머신러닝 실험실" }
    @{ Name="blog-engine";      Cat="Web";   Desc="정적 블로그 생성기" }
    @{ Name="home-automation";  Cat="Infra"; Desc="홈 자동화 스크립트" }
    @{ Name="game-of-life";     Cat="Game";  Desc="Conway's Game of Life" }
    @{ Name="api-gateway";      Cat="Infra"; Desc="API 게이트웨이 프록시" }
)

foreach ($p in $projects) {
    $pdir = Join-Path $demoRoot $p.Name
    New-Item -ItemType Directory -Path $pdir -Force | Out-Null
    git -C $pdir init -b main 2>&1 | Out-Null

    Set-Content -Path (Join-Path $pdir "CLAUDE.md") -Encoding UTF8 -Value @"
# $($p.Name)

> $($p.Desc)
"@

    Set-Content -Path (Join-Path $pdir "ROADMAP.md") -Encoding UTF8 -Value @"
# $($p.Name) ROADMAP

## v1.0
- [x] 프로젝트 초기화
- [x] 기본 구조 설계
- [ ] 핵심 기능 구현
- [ ] 테스트 작성
- [ ] 배포 설정
"@

    Set-Content -Path (Join-Path $pdir ".gitignore") -Encoding UTF8 -Value @"
.claude/worktrees/
.claude/.last-opened
"@

    git -C $pdir add -A 2>&1 | Out-Null
    git -C $pdir commit -m "init" 2>&1 | Out-Null
}

# ── 메타데이터 ───────────────────────────────────────────────
$metaJson = @'
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
'@
Set-Content -Path (Join-Path $demoRoot ".proj-meta.json") -Encoding UTF8 -Value $metaJson

# ── last-opened 타임스탬프 (정렬 데모용) ─────────────────────
$now = [DateTimeOffset]::UtcNow
$offsets = @(0, 3600, 86400, 172800, 604800, 1209600, 2592000, 7776000)
$i = 0
foreach ($p in $projects) {
    if ($p.Name -eq "game-of-life") { $i++; continue }  # archive 제외
    $pdir = Join-Path $demoRoot $p.Name
    $claudeDir = Join-Path $pdir ".claude"
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    $marker = Join-Path $claudeDir ".last-opened"
    $ts = $now.AddSeconds(-$offsets[$i])
    [IO.File]::WriteAllText($marker, $ts.ToString("o"))
    (Get-Item $marker).LastWriteTime = $ts.LocalDateTime
    $i++
}

Write-Host ""
Write-Host "더미 프로젝트 생성 완료: $demoRoot" -ForegroundColor Green
Write-Host ""
Write-Host "스크린샷 촬영:" -ForegroundColor Yellow
Write-Host '  $env:PROJECTS_ROOT="' -NoNewline
Write-Host $demoRoot -NoNewline
Write-Host '"; proj'
Write-Host ""
Write-Host "정리:" -ForegroundColor Yellow
Write-Host "  powershell -File demo-setup.ps1 -Clean"
