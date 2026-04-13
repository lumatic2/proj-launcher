# proj-launcher setup for Windows (PowerShell)
# Usage: powershell -ExecutionPolicy Bypass -File setup.ps1

$ErrorActionPreference = "Stop"

function Write-OK($msg)   { Write-Host "[OK]  " -NoNewline -ForegroundColor Green;  Write-Host $msg }
function Write-Fail($msg)  { Write-Host "[FAIL]" -NoNewline -ForegroundColor Red;    Write-Host " $msg" }
function Write-Warn($msg)  { Write-Host "[WARN]" -NoNewline -ForegroundColor Yellow; Write-Host " $msg" }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$projPs1 = Join-Path $scriptDir "proj.ps1"

# ── 의존성 체크 ──────────────────────────────────────────────
Write-Host "의존성 확인 중..."
$missing = 0

foreach ($cmd in @("git", "fzf", "jq")) {
    $found = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($found) {
        Write-OK "$cmd ($($found.Source))"
    } else {
        Write-Fail "$cmd 이 설치되어 있지 않습니다"
        $missing++
    }
}

if ($missing -gt 0) {
    Write-Host ""
    Write-Warn "누락된 도구를 먼저 설치하세요:"
    Write-Host "  winget install junegunn.fzf"
    Write-Host "  winget install jqlang.jq"
    exit 1
}

# ── 프로젝트 루트 확인 ───────────────────────────────────────
$projectsRoot = "$HOME\projects"
if (-not (Test-Path $projectsRoot)) {
    New-Item -ItemType Directory -Path $projectsRoot -Force | Out-Null
    Write-OK "프로젝트 루트 생성: $projectsRoot"
} else {
    Write-OK "프로젝트 루트: $projectsRoot"
}

# ── PowerShell 프로필에 dot-source 라인 추가 ─────────────────
$sourceLine = ". `"$projPs1`""

if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    Write-OK "프로필 생성: $PROFILE"
}

$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if ($profileContent -and $profileContent.Contains("proj.ps1")) {
    Write-OK "이미 등록됨: $PROFILE"
} else {
    Add-Content -Path $PROFILE -Value "`n# proj-launcher`n$sourceLine"
    Write-OK "추가 완료: $PROFILE"
}

# ── Windows Terminal 프로필 제안 ─────────────────────────────
$wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path $wtSettingsPath) {
    Write-Host ""
    Write-Warn "Windows Terminal 프로필에 proj 전용 항목을 추가하려면:"
    Write-Host '  settings.json > profiles > list 에 아래를 추가하세요:'
    Write-Host ''
    Write-Host '  {' -ForegroundColor DarkGray
    Write-Host '    "name": "proj",' -ForegroundColor DarkGray
    Write-Host '    "commandline": "pwsh -NoExit -Command proj",' -ForegroundColor DarkGray
    Write-Host '    "icon": "\uD83D\uDCC2"' -ForegroundColor DarkGray
    Write-Host '  }' -ForegroundColor DarkGray
}

# ── 완료 ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "설치 완료! 새 터미널을 열거나 아래 명령어를 실행하세요:" -ForegroundColor Green
Write-Host "  . `$PROFILE"
Write-Host ""
Write-Host "사용법:"
Write-Host "  proj              # 프로젝트 런처 시작"
