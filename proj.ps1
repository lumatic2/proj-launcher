# proj: 프로젝트 폴더 인터랙티브 선택 + worktree 지원
# Requires: fzf, jq, git
# Source this file from your PowerShell profile:
#   . ~/projects/proj-launcher/proj.ps1
# Or add to $PROFILE via setup.ps1

function proj {
    $projectsRoot = "$HOME\projects"
    $metaFile = Join-Path $projectsRoot ".proj-meta.json"

    # ── 메타데이터 로드/저장 ──────────────────────────────────
    function Load-Meta {
        if (Test-Path $metaFile) {
            return (Get-Content $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        return [PSCustomObject]@{}
    }

    function Save-Meta($obj) {
        $obj | ConvertTo-Json -Depth 3 | Set-Content $metaFile -Encoding UTF8
    }

    function Get-Meta([string]$name, $meta) {
        if ($meta.PSObject.Properties[$name]) {
            return $meta.$name
        }
        return $null
    }

    # ── 공통 헬퍼 ─────────────────────────────────────────────
    function Format-Ago([long]$ts) {
        $diff = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ts
        if ($diff -lt  86400) { return "오늘" }
        if ($diff -lt 172800) { return "어제" }
        $d = [math]::Floor($diff / 86400)
        if ($d -lt  7) { return "${d}일 전" }
        $w = [math]::Floor($d / 7)
        if ($w -lt  5) { return "${w}주 전" }
        $m = [math]::Floor($d / 30)
        if ($m -lt 12) { return "${m}개월 전" }
        return "$([math]::Floor($d / 365))년 전"
    }

    function Ensure-WorktreeIgnore([string]$projPath) {
        $gi = Join-Path $projPath ".gitignore"
        $pattern = ".claude/worktrees/"
        if (Test-Path $gi) {
            $content = Get-Content $gi -Raw -ErrorAction SilentlyContinue
            if ($content -and $content.Contains($pattern)) { return }
        }
        Add-Content -Path $gi -Value "`n# Claude Code worktrees`n$pattern"
    }

    function Touch-ProjectMarker([string]$path) {
        $marker = Join-Path $path ".claude\.last-opened"
        $dir = Split-Path $marker -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($marker, (Get-Date -Format "o"))
    }

    # ── worktree 메타 헬퍼 ────────────────────────────────────
    function Save-WtDesc([string]$name, [string]$desc) {
        $pm = Get-Meta $projName $meta
        if (-not $pm) {
            $pm = [PSCustomObject]@{ cat="Etc"; desc=""; wt=[PSCustomObject]@{} }
            $meta | Add-Member -NotePropertyName $projName -NotePropertyValue $pm -Force
        }
        if (-not $pm.PSObject.Properties["wt"]) {
            $pm | Add-Member -NotePropertyName "wt" -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $pm.wt | Add-Member -NotePropertyName $name -NotePropertyValue ([PSCustomObject]@{ desc=$desc }) -Force
        Save-Meta $meta
    }

    function Remove-WtMeta([string]$name) {
        $pm = Get-Meta $projName $meta
        if ($pm -and $pm.PSObject.Properties["wt"] -and $pm.wt.PSObject.Properties[$name]) {
            $pm.wt.PSObject.Properties.Remove($name)
            Save-Meta $meta
        }
    }

    function Rename-WtMeta([string]$oldName, [string]$newName) {
        $pm = Get-Meta $projName $meta
        if ($pm -and $pm.PSObject.Properties["wt"] -and $pm.wt.PSObject.Properties[$oldName]) {
            $oldVal = $pm.wt.$oldName
            $pm.wt.PSObject.Properties.Remove($oldName)
            $pm.wt | Add-Member -NotePropertyName $newName -NotePropertyValue $oldVal -Force
            Save-Meta $meta
        }
    }

    # ── 에이전트 런칭 메뉴 ────────────────────────────────────
    function Launch-Agent([string]$targetDir) {
        $agentMenu = "claude    Claude Code`n"
        if (Get-Command codex  -ErrorAction SilentlyContinue) { $agentMenu += "codex     Codex CLI`n" }
        if (Get-Command gemini -ErrorAction SilentlyContinue) { $agentMenu += "gemini    Gemini CLI`n" }
        $agentMenu += "shell     셸만 이동`n"
        $pick = $agentMenu.TrimEnd("`n") | fzf --layout=reverse --prompt='agent> ' --height=40% --border --no-sort --header="$targetDir"
        if (-not $pick) { return $false }
        $cmd = ($pick -split '\s+')[0]
        switch ($cmd) {
            "claude" { Start-Process claude -NoNewWindow -Wait }
            "codex"  { Start-Process codex  -NoNewWindow -Wait }
            "gemini" { Start-Process gemini -NoNewWindow -Wait }
            default  { }
        }
    }

    # ══════════════════════════════════════════════════════════
    # Step 1: 프로젝트 선택 (루프)
    # ══════════════════════════════════════════════════════════
    $projName = $null
    $projPath = $null

    :outer while ($true) {  # 외부 루프 (worktree Esc → 여기로 복귀)

    while ($true) {  # 프로젝트 선택 루프
        $meta = Load-Meta

        $allProjects = Get-ChildItem -Path $projectsRoot -Directory | ForEach-Object {
            $name = $_.Name
            $path = $_.FullName
            $marker = Join-Path $path ".claude\.last-opened"
            if (Test-Path $marker) {
                $sortKey = [long]((Get-Item $marker).LastWriteTime.ToUniversalTime() - [datetime]"1970-01-01").TotalSeconds
            } else {
                $gitLog = git -C $path log -1 --format="%ct" 2>$null
                $sortKey = if ($gitLog -and $gitLog -match '^\d+$') { [long]$gitLog }
                           else { [long]($_.LastWriteTime.ToUniversalTime() - [datetime]"1970-01-01").TotalSeconds }
            }
            $m = Get-Meta $name $meta
            $isPin = if ($m -and $m.PSObject.Properties["pin"]) { $m.pin -eq $true } else { $false }
            $isArc = if ($m -and $m.PSObject.Properties["archive"]) { $m.archive -eq $true } else { $false }
            [PSCustomObject]@{
                Name    = $name
                Path    = $path
                SortKey = $sortKey
                Cat     = if ($m) { $m.cat } else { "" }
                Desc    = if ($m) { $m.desc } else { "" }
                Pin     = $isPin
                Archive = $isArc
            }
        } | Sort-Object SortKey -Descending

        $pinnedProjects  = $allProjects | Where-Object { $_.Pin -and -not $_.Archive }
        $normalProjects  = $allProjects | Where-Object { -not $_.Pin -and -not $_.Archive }

        # fzf 입력: 핀 → 일반
        $fzfLines = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $pinnedProjects) {
            $ago = Format-Ago $p.SortKey
            $catStr = if ($p.Cat) { $p.Cat.PadRight(6) } else { "      " }
            $descStr = if ($p.Desc) { $p.Desc } else { "" }
            $fzfLines.Add("* $($p.Name.PadRight(25))$($ago.PadRight(8))$catStr$descStr")
        }
        foreach ($p in $normalProjects) {
            $ago = Format-Ago $p.SortKey
            $catStr = if ($p.Cat) { $p.Cat.PadRight(6) } else { "      " }
            $descStr = if ($p.Desc) { $p.Desc } else { "" }
            $fzfLines.Add("$($p.Name.PadRight(28))$($ago.PadRight(8))$catStr$descStr")
        }

        $fzfHeader = "  ctrl+N 새 프로젝트  ctrl+E 설명수정  ctrl+R 이름변경  ctrl+D 삭제`n  ctrl+P 핀  ctrl+X 아카이브  ctrl+A 아카이브목록  ctrl+S 상태  |  Esc 종료`n────────────────────────────────────────────────────────────────────────────"

        $fzfOut = ($fzfLines -join "`n") | fzf --layout=reverse --prompt='proj> ' --height=40% --border --no-sort --header="$fzfHeader" --expect='ctrl-n,ctrl-e,ctrl-r,ctrl-d,ctrl-p,ctrl-x,ctrl-a,ctrl-s'
        if (-not $fzfOut) { return }
        $fzfOutLines = $fzfOut -split "`n"
        $key = $fzfOutLines[0]
        $sel = if ($fzfOutLines.Count -gt 1) { $fzfOutLines[1] } else { "" }

        # 선택된 프로젝트 이름 추출 (핀 마커 제거)
        $selName = ""
        if ($sel) {
            if ($sel -match '^\*\s+(\S+)') {
                $selName = $Matches[1]
            } else {
                $selName = ($sel -split '\s+')[0]
            }
        }

        # 관리 액션 판별
        $action = ""
        if ($key -eq "ctrl-n") { $action = "new" }
        if ($key -eq "ctrl-e") { $action = "edit" }
        if ($key -eq "ctrl-r") { $action = "rename" }
        if ($key -eq "ctrl-d") { $action = "delete" }
        if ($key -eq "ctrl-p") { $action = "pin" }
        if ($key -eq "ctrl-x") { $action = "archive" }
        if ($key -eq "ctrl-a") { $action = "archive-view" }
        if ($key -eq "ctrl-s") { $action = "status" }

        # ── ctrl+S: 프로젝트 상태 ───────────────────────
        if ($action -eq "status") {
            if (-not $selName) { continue }
            $sp = Join-Path $projectsRoot $selName
            if (-not (Test-Path $sp)) { Write-Host "경로 없음: $sp" -ForegroundColor Red; continue }

            $statusLines = [System.Collections.Generic.List[string]]::new()

            # 프로젝트명 + 설명
            $sm = Get-Meta $selName $meta
            $sDesc = if ($sm -and $sm.desc) { $sm.desc } else { "" }
            $sCat = if ($sm -and $sm.cat) { $sm.cat } else { "" }
            $titleLine = "  $selName"
            if ($sCat) { $titleLine += "  [$sCat]" }
            if ($sDesc) { $titleLine += "  $sDesc" }
            $statusLines.Add($titleLine)

            # git 정보
            $isGit = (git -C $sp rev-parse --git-dir 2>$null) -ne $null
            if ($isGit) {
                $sBranch = git -C $sp branch --show-current 2>$null
                if (-not $sBranch) { $sBranch = "HEAD" }
                $sMod = (git -C $sp status --porcelain 2>$null | Measure-Object -Line).Lines
                $sStatus = if ($sMod -gt 0) { "$sMod modified" } else { "clean" }
                $sAhead = 0; $sBehind = 0
                try {
                    $sAhead = [int](git -C $sp rev-list --count "@{u}..HEAD" 2>$null)
                    $sBehind = [int](git -C $sp rev-list --count "HEAD..@{u}" 2>$null)
                } catch {}
                $sPush = ""
                if ($sAhead -gt 0) { $sPush += " ${sAhead} ahead" }
                if ($sBehind -gt 0) { $sPush += " ${sBehind} behind" }

                $statusLines.Add("──────────────────────────────────────────────")
                $statusLines.Add("  branch:  $sBranch")
                $statusLines.Add("  status:  $sStatus$sPush")

                # worktree 목록
                $sWtList = git -C $sp worktree list --porcelain 2>$null
                $sWtCount = 0
                $sWtLines = [System.Collections.Generic.List[string]]::new()
                $sWtPath = $null
                foreach ($wline in $sWtList) {
                    if ($wline -match '^worktree (.+)$') { $sWtPath = $Matches[1] }
                    if ($wline -match '^branch refs/heads/(.+)$' -and $sWtPath) {
                        $sNormWt = (Resolve-Path $sWtPath -ErrorAction SilentlyContinue).Path
                        $sNormSp = (Resolve-Path $sp -ErrorAction SilentlyContinue).Path
                        if ($sNormWt -ne $sNormSp) {
                            $sWtName = Split-Path $sWtPath -Leaf
                            $sWtBranch = $Matches[1]
                            $sWtMod = (git -C $sWtPath status --porcelain 2>$null | Measure-Object -Line).Lines
                            $sWtSt = if ($sWtMod -gt 0) { "$sWtMod mod" } else { "clean" }
                            $sWtDesc = ""
                            $sWtMeta = if ($sm -and $sm.PSObject.Properties["wt"]) { $sm.wt } else { $null }
                            if ($sWtMeta -and $sWtMeta.PSObject.Properties[$sWtName]) { $sWtDesc = $sWtMeta.$sWtName.desc }
                            $wtLine = "    $sWtName ($sWtBranch) [$sWtSt]"
                            if ($sWtDesc) { $wtLine += "  $sWtDesc" }
                            $sWtLines.Add($wtLine)
                            $sWtCount++
                        }
                        $sWtPath = $null
                    }
                }
                $statusLines.Add("  worktree: ${sWtCount}개")
                foreach ($wl in $sWtLines) { $statusLines.Add($wl) }
            } else {
                $statusLines.Add("──────────────────────────────────────────────")
                $statusLines.Add("  (git 저장소 아님)")
            }

            # ROADMAP 진행률
            $roadmapPath = Join-Path $sp "ROADMAP.md"
            if (Test-Path $roadmapPath) {
                $roadmapContent = Get-Content $roadmapPath -Encoding UTF8
                $rTotal = ($roadmapContent | Select-String '^\s*- \[[ x]\]').Count
                $rDone = ($roadmapContent | Select-String '^\s*- \[x\]').Count
                if ($rTotal -gt 0) {
                    $rPct = [math]::Floor($rDone * 100 / $rTotal)
                    $rBarDone = [math]::Floor($rPct / 5)
                    $rBarLeft = 20 - $rBarDone
                    $rBar = ("█" * $rBarDone) + ("░" * $rBarLeft)
                    $statusLines.Add("──────────────────────────────────────────────")
                    $statusLines.Add("  ROADMAP:  $rBar ${rDone}/${rTotal} (${rPct}%)")
                    $rCount = 0
                    foreach ($rl in $roadmapContent) {
                        if ($rl -match '^\s*- \[ \]') {
                            if ($rCount -ge 8) { $statusLines.Add("    ..."); break }
                            $statusLines.Add("  $($rl.Trim())")
                            $rCount++
                        }
                    }
                }
            }

            $statusLines.Add("──────────────────────────────────────────────")

            ($statusLines -join "`n") | fzf --layout=reverse --prompt='' --height=40% --border --no-sort --header="  $selName 상태  |  Esc 뒤로" --disabled
            continue
        }

        # ── ctrl+A: 아카이브 화면 ───────────────────────
        if ($action -eq "archive-view") {
            while ($true) {
                $meta = Load-Meta
                $arcProjects = Get-ChildItem -Path $projectsRoot -Directory | ForEach-Object {
                    $name = $_.Name
                    $m = Get-Meta $name $meta
                    $isArc = if ($m -and $m.PSObject.Properties["archive"]) { $m.archive -eq $true } else { $false }
                    if (-not $isArc) { return }
                    $path = $_.FullName
                    $marker = Join-Path $path ".claude\.last-opened"
                    if (Test-Path $marker) {
                        $sortKey = [long]((Get-Item $marker).LastWriteTime.ToUniversalTime() - [datetime]"1970-01-01").TotalSeconds
                    } else {
                        $gitLog = git -C $path log -1 --format="%ct" 2>$null
                        $sortKey = if ($gitLog -and $gitLog -match '^\d+$') { [long]$gitLog }
                                   else { [long]($_.LastWriteTime.ToUniversalTime() - [datetime]"1970-01-01").TotalSeconds }
                    }
                    [PSCustomObject]@{
                        Name = $name; Path = $path; SortKey = $sortKey
                        Cat = if ($m) { $m.cat } else { "" }
                        Desc = if ($m) { $m.desc } else { "" }
                    }
                } | Sort-Object SortKey -Descending

                if (-not $arcProjects -or $arcProjects.Count -eq 0) {
                    Write-Host "  아카이브가 비어 있습니다." -ForegroundColor DarkGray
                    break
                }

                $arcLines = [System.Collections.Generic.List[string]]::new()
                foreach ($p in $arcProjects) {
                    $ago = Format-Ago $p.SortKey
                    $catStr = if ($p.Cat) { $p.Cat.PadRight(6) } else { "      " }
                    $descStr = if ($p.Desc) { $p.Desc } else { "" }
                    $arcLines.Add("$($p.Name.PadRight(28))$($ago.PadRight(8))$catStr$descStr")
                }

                $arcHeader = "  ctrl+R 복구  ctrl+D 영구삭제  |  Esc 뒤로`n────────────────────────────────────────────────────────────────────────────"
                $arcOut = ($arcLines -join "`n") | fzf --layout=reverse --prompt='archive> ' --height=40% --border --no-sort --header="$arcHeader" --expect='ctrl-r,ctrl-d'
                if (-not $arcOut) { break }  # Esc → 메인 목록으로
                $arcOutLines = $arcOut -split "`n"
                $arcKey = $arcOutLines[0]
                $arcSel = if ($arcOutLines.Count -gt 1) { $arcOutLines[1] } else { "" }
                $arcName = ($arcSel -split '\s+')[0]
                if (-not $arcName) { continue }

                if ($arcKey -eq "ctrl-r") {
                    $pm = Get-Meta $arcName $meta
                    if ($pm) {
                        $pm | Add-Member -NotePropertyName "archive" -NotePropertyValue $false -Force
                        Save-Meta $meta
                        Write-Host "  복구: $arcName" -ForegroundColor Green
                    }
                    continue
                }

                if ($arcKey -eq "ctrl-d") {
                    Write-Host -NoNewline "  '$arcName' 영구삭제? 복구 불가 (y/N): " -ForegroundColor Red
                    $confirm = Read-Host
                    if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                        $curDir = (Get-Location).Path
                        $targetPath = Join-Path $projectsRoot $arcName
                        if ($curDir.StartsWith($targetPath)) { Set-Location $projectsRoot }
                        Remove-Item -Path $targetPath -Recurse -Force
                        if ($meta.PSObject.Properties[$arcName]) {
                            $meta.PSObject.Properties.Remove($arcName)
                            Save-Meta $meta
                        }
                        Write-Host "  영구삭제 완료: $arcName" -ForegroundColor Green
                    } else {
                        Write-Host "  취소됨."
                    }
                    continue
                }

                # Enter로 선택 시 해당 프로젝트 열기
                if (-not $arcKey -and $arcName) {
                    $targetPath = Join-Path $projectsRoot $arcName
                    if (Test-Path $targetPath) {
                        Touch-ProjectMarker $targetPath
                        Set-Location $targetPath
                        Write-Host "-> $targetPath" -ForegroundColor Green
                        $agentResult = Launch-Agent $targetPath
                        if ($agentResult -eq $false) { continue }
                        return
                    }
                }
            }
            continue
        }

        # ── ctrl+P: 핀 토글 ─────────────────────────────
        if ($action -eq "pin") {
            if (-not $selName) { continue }
            $pm = Get-Meta $selName $meta
            if (-not $pm) {
                $pm = [PSCustomObject]@{ cat="Etc"; desc="" }
                $meta | Add-Member -NotePropertyName $selName -NotePropertyValue $pm -Force
            }
            $curPin = if ($pm.PSObject.Properties["pin"]) { $pm.pin -eq $true } else { $false }
            if ($curPin) {
                $pm | Add-Member -NotePropertyName "pin" -NotePropertyValue $false -Force
                Write-Host "  핀 해제: $selName" -ForegroundColor DarkGray
            } else {
                $pm | Add-Member -NotePropertyName "pin" -NotePropertyValue $true -Force
                $pm | Add-Member -NotePropertyName "archive" -NotePropertyValue $false -Force
                Write-Host "  * 핀 고정: $selName" -ForegroundColor Green
            }
            Save-Meta $meta
            continue
        }

        # ── ctrl+X: 아카이브에 넣기 ─────────────────────
        if ($action -eq "archive") {
            if (-not $selName) { continue }
            $pm = Get-Meta $selName $meta
            if (-not $pm) {
                $pm = [PSCustomObject]@{ cat="Etc"; desc="" }
                $meta | Add-Member -NotePropertyName $selName -NotePropertyValue $pm -Force
            }
            $pm | Add-Member -NotePropertyName "archive" -NotePropertyValue $true -Force
            $pm | Add-Member -NotePropertyName "pin" -NotePropertyValue $false -Force
            Save-Meta $meta
            Write-Host "  아카이브: $selName" -ForegroundColor DarkGray
            continue
        }

        # ── [+new] ───────────────────────────────────────
        if ($action -eq "new") {
            Write-Host -NoNewline "  프로젝트 이름: " -ForegroundColor Yellow
            $newProjName = Read-Host
            if (-not $newProjName) { Write-Host "  취소됨."; continue }

            $newProjPath = Join-Path $projectsRoot $newProjName
            if (Test-Path $newProjPath) {
                Write-Host "  이미 존재: $newProjPath" -ForegroundColor Red
                continue
            }

            Write-Host -NoNewline "  설명 (한글 OK): " -ForegroundColor Yellow
            $newDesc = Read-Host
            Write-Host -NoNewline "  카테고리 (AI/Web/MCP/Bot/Game/Tool/Infra/Etc): " -ForegroundColor Yellow
            $newCat = Read-Host
            if (-not $newCat) { $newCat = "Etc" }

            New-Item -ItemType Directory -Path $newProjPath -Force | Out-Null
            git -C $newProjPath init --initial-branch=main 2>&1 | Out-Null

            $claudeContent = @"
# $newProjName

> $newDesc

## Tech Stack
<!-- 사용 기술 스택 -->

## Structure
<!-- 주요 디렉토리/파일 구조 -->

## Conventions
<!-- 코딩 컨벤션, 네이밍 규칙 등 -->
"@
            Set-Content -Path (Join-Path $newProjPath "CLAUDE.md") -Value $claudeContent -Encoding UTF8

            $giContent = @"
# Claude Code
.claude/worktrees/
.claude/.last-opened
"@
            Set-Content -Path (Join-Path $newProjPath ".gitignore") -Value $giContent -Encoding UTF8

            $meta | Add-Member -NotePropertyName $newProjName -NotePropertyValue ([PSCustomObject]@{ cat=$newCat; desc=$newDesc }) -Force
            Save-Meta $meta

            Touch-ProjectMarker $newProjPath
            Write-Host "  생성 완료: $newProjPath" -ForegroundColor Green
            continue
        }

        # ── [edit] ───────────────────────────────────────
        if ($action -eq "edit") {
            if (-not $selName) { continue }
            $curMeta = Get-Meta $selName $meta
            $curDesc = if ($curMeta -and $curMeta.desc) { $curMeta.desc } else { "" }
            $curCat  = if ($curMeta -and $curMeta.cat)  { $curMeta.cat  } else { "" }

            Write-Host "  [$selName] 현재: [$curCat] $curDesc" -ForegroundColor DarkGray
            Write-Host -NoNewline "  설명 (Enter=유지): " -ForegroundColor Yellow
            $newDesc = Read-Host
            if (-not $newDesc) { $newDesc = $curDesc }
            Write-Host -NoNewline "  카테고리 (Enter=유지, 현재=$curCat): " -ForegroundColor Yellow
            $newCat = Read-Host
            if (-not $newCat) { $newCat = $curCat }

            $em = Get-Meta $selName $meta
            if ($em) {
                $em | Add-Member -NotePropertyName "cat" -NotePropertyValue $newCat -Force
                $em | Add-Member -NotePropertyName "desc" -NotePropertyValue $newDesc -Force
            } else {
                $meta | Add-Member -NotePropertyName $selName -NotePropertyValue ([PSCustomObject]@{ cat=$newCat; desc=$newDesc }) -Force
            }
            Save-Meta $meta
            Write-Host "  저장 완료: [$newCat] $newDesc" -ForegroundColor Green
            continue
        }

        # ── [ren] ────────────────────────────────────────
        if ($action -eq "rename") {
            if (-not $selName) { continue }
            $targetPath = Join-Path $projectsRoot $selName
            Write-Host -NoNewline "  새 이름 ($selName): " -ForegroundColor Yellow
            $newName = Read-Host
            if (-not $newName) { Write-Host "  취소됨."; continue }

            $newPath = Join-Path $projectsRoot $newName
            if (Test-Path $newPath) {
                Write-Host "  이미 존재: $newPath" -ForegroundColor Red
                continue
            }

            $curDir = (Get-Location).Path
            if ($curDir.StartsWith($targetPath)) {
                Set-Location $projectsRoot
            }

            Rename-Item -Path $targetPath -NewName $newName
            if ($?) {
                $oldMeta = Get-Meta $selName $meta
                if ($oldMeta) {
                    $meta.PSObject.Properties.Remove($selName)
                    $meta | Add-Member -NotePropertyName $newName -NotePropertyValue $oldMeta -Force
                    Save-Meta $meta
                }
                Write-Host "  변경 완료: $selName -> $newName" -ForegroundColor Green
            } else {
                Write-Host "  이름변경 실패. 다른 프로세스가 폴더를 사용 중일 수 있음" -ForegroundColor Red
            }
            continue
        }

        # ── [del] ────────────────────────────────────────
        if ($action -eq "delete") {
            if (-not $selName) { continue }
            $targetPath = Join-Path $projectsRoot $selName
            Write-Host -NoNewline "  '$selName' 을 정말 삭제? 복구 불가 (y/N): " -ForegroundColor Red
            $confirm = Read-Host
            if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                $curDir = (Get-Location).Path
                if ($curDir.StartsWith($targetPath)) {
                    Set-Location $projectsRoot
                }
                Remove-Item -Path $targetPath -Recurse -Force
                if ($?) {
                    if ($meta.PSObject.Properties[$selName]) {
                        $meta.PSObject.Properties.Remove($selName)
                        Save-Meta $meta
                    }
                    Write-Host "  삭제 완료: $selName" -ForegroundColor Green
                } else {
                    Write-Host "  삭제 실패." -ForegroundColor Red
                }
            } else {
                Write-Host "  취소됨."
            }
            continue
        }

        # ── 프로젝트 선택됨 → 루프 탈출 ─────────────────
        if (-not $selName) { continue }
        $projName = $selName
        $projPath = Join-Path $projectsRoot $projName
        if (-not (Test-Path $projPath)) {
            Write-Host "경로 없음: $projPath" -ForegroundColor Red
            continue
        }
        break
    }

    # ── 비git 프로젝트 ───────────────────────────────────────
    $isGit = (git -C $projPath rev-parse --git-dir 2>$null) -ne $null
    if (-not $isGit) {
        Touch-ProjectMarker $projPath
        Set-Location $projPath
        Write-Host "-> $projPath" -ForegroundColor Green
        $agentResult = Launch-Agent $projPath
        if ($agentResult -eq $false) { continue }  # agent Esc → 프로젝트 목록
        return
    }

    # ══════════════════════════════════════════════════════════
    # Step 2: worktree 선택 (루프)
    # ══════════════════════════════════════════════════════════
    while ($true) {
        $meta = Load-Meta
        $projMeta = Get-Meta $projName $meta
        $wtMeta = if ($projMeta -and $projMeta.PSObject.Properties["wt"]) { $projMeta.wt } else { $null }

        $branch = git -C $projPath branch --show-current 2>$null
        if (-not $branch) { $branch = "HEAD" }

        # worktree 목록 파싱
        $wtList = git -C $projPath worktree list --porcelain 2>$null
        $wtEntries = @()
        $wtPath = $null
        foreach ($line in $wtList) {
            if ($line -match '^worktree (.+)$') {
                $wtPath = $Matches[1]
            }
            if ($line -match '^branch refs/heads/(.+)$' -and $wtPath) {
                $normWt = (Resolve-Path $wtPath -ErrorAction SilentlyContinue).Path
                $normProj = (Resolve-Path $projPath -ErrorAction SilentlyContinue).Path
                if ($normWt -ne $normProj) {
                    $wtName = Split-Path $wtPath -Leaf
                    $wtBranch = $Matches[1]

                    $wtGitLog = git -C $wtPath log -1 --format="%ct" 2>$null
                    if ($wtGitLog -and $wtGitLog -match '^\d+$') {
                        $wtSortKey = [long]$wtGitLog
                    } else {
                        $wtSortKey = [long]((Get-Item $wtPath).LastWriteTime.ToUniversalTime() - [datetime]"1970-01-01").TotalSeconds
                    }

                    $wtEntries += [PSCustomObject]@{ Name=$wtName; Branch=$wtBranch; Path=$wtPath; SortKey=$wtSortKey }
                }
                $wtPath = $null
            }
        }

        # fzf 입력: 루트/worktree 목록만
        $wtFzfLines = [System.Collections.Generic.List[string]]::new()
        $wtFzfLines.Add("[main]  프로젝트 루트  ($branch)")

        foreach ($wt in $wtEntries) {
            $wtAgo = Format-Ago $wt.SortKey
            $wtDesc = ""
            if ($wtMeta -and $wtMeta.PSObject.Properties[$wt.Name]) {
                $wtDesc = $wtMeta.($wt.Name).desc
            }
            $descSuffix = if ($wtDesc) { "  $wtDesc" } else { "" }
            $wtFzfLines.Add("[wt]    $($wt.Name.PadRight(20))$($wtAgo.PadRight(8))$descSuffix")
        }

        $wtExpect = "ctrl-n"
        if ($wtEntries.Count -gt 0) { $wtExpect = "ctrl-n,ctrl-e,ctrl-r,ctrl-d" }

        $wtHeader = "  ctrl+N 새 worktree"
        if ($wtEntries.Count -gt 0) { $wtHeader += "  ctrl+E 설명수정  ctrl+R 이름변경  ctrl+D 삭제" }
        $wtHeader += "  |  Esc 뒤로"
        $wtHeader += "`n────────────────────────────────────────────────────────────────────────────"

        $wtFzfOut = ($wtFzfLines -join "`n") | fzf --layout=reverse --prompt="${projName}> " --height=40% --border --no-sort --header="$wtHeader" --expect="$wtExpect"
        if (-not $wtFzfOut) { break }  # Esc → 프로젝트 목록으로
        $wtFzfOutLines = $wtFzfOut -split "`n"
        $wkey = $wtFzfOutLines[0]
        $wsel = if ($wtFzfOutLines.Count -gt 1) { $wtFzfOutLines[1] } else { "" }

        # 관리 액션 판별
        $waction = ""
        if ($wkey -eq "ctrl-n") { $waction = "new" }
        if ($wkey -eq "ctrl-e") { $waction = "edit" }
        if ($wkey -eq "ctrl-r") { $waction = "rename" }
        if ($wkey -eq "ctrl-d") { $waction = "delete" }

        # ── [main] / [wt] 선택 → 탈출 ───────────────────
        if (-not $waction) {
            if ($wsel.StartsWith("[main]")) {
                Touch-ProjectMarker $projPath
                Set-Location $projPath
                Write-Host "-> $projPath" -ForegroundColor Green
                $agentResult = Launch-Agent $projPath
                if ($agentResult -eq $false) { continue }  # agent Esc → worktree 목록
                return
            }
            if ($wsel.StartsWith("[wt]")) {
                $wtSelName = ($wsel -split '\s+')[1]
                $wtTarget = ($wtEntries | Where-Object { $_.Name -eq $wtSelName } | Select-Object -First 1).Path
                if ($wtTarget -and (Test-Path $wtTarget)) {
                    Touch-ProjectMarker $projPath
                    Set-Location $wtTarget
                    Write-Host "-> $wtTarget" -ForegroundColor Magenta
                    $agentResult = Launch-Agent $wtTarget
                    if ($agentResult -eq $false) { continue }  # agent Esc → worktree 목록
                } else {
                    Write-Host "경로 없음: $wtSelName" -ForegroundColor Red
                    continue
                }
                return
            }
            continue
        }

        # ── wt [+new] ───────────────────────────────────
        if ($waction -eq "new") {
            Write-Host -NoNewline "  Worktree 이름 (예: auth-refactor): " -ForegroundColor Yellow
            $wtName = Read-Host
            if (-not $wtName) { Write-Host "취소됨."; continue }

            Write-Host -NoNewline "  설명 (Enter=생략): " -ForegroundColor Yellow
            $wtDesc = Read-Host

            Ensure-WorktreeIgnore $projPath

            $wtDir = Join-Path $projPath ".claude\worktrees\$wtName"
            $parentDir = Split-Path $wtDir -Parent
            if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }

            $result = git -C $projPath worktree add $wtDir -b $wtName 2>&1
            if ($LASTEXITCODE -eq 0) {
                $includeFile = Join-Path $projPath ".worktreeinclude"
                if (Test-Path $includeFile) {
                    Get-Content $includeFile | ForEach-Object {
                        $f = $_.Trim()
                        if ($f -and -not $f.StartsWith("#")) {
                            $src = Join-Path $projPath $f
                            if (Test-Path $src) {
                                $dst = Join-Path $wtDir $f
                                $dstDir = Split-Path $dst -Parent
                                if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
                                Copy-Item $src $dst
                            }
                        }
                    }
                }

                if ($wtDesc) { Save-WtDesc $wtName $wtDesc }

                Touch-ProjectMarker $projPath
                Write-Host "  생성 완료: Worktree '$wtName'" -ForegroundColor Magenta
                Write-Host "  경로: $wtDir" -ForegroundColor DarkGray
            } else {
                Write-Host "Worktree 생성 실패:" -ForegroundColor Red
                Write-Host $result -ForegroundColor Red
            }
            continue
        }

        # ── wt [edit] ───────────────────────────────────
        if ($waction -eq "edit") {
            $editWtLines = $wtEntries | ForEach-Object {
                $d = ""
                if ($wtMeta -and $wtMeta.PSObject.Properties[$_.Name]) { $d = $wtMeta.($_.Name).desc }
                "$($_.Name.PadRight(24))$d"
            }
            $editWtSel = ($editWtLines -join "`n") | fzf --layout=reverse --prompt='edit wt> ' --height=40% --border --no-sort --header='설명 수정할 worktree 선택'
            if (-not $editWtSel) { continue }

            $wen = ($editWtSel -split '\s+')[0]
            $wcur = ""
            if ($wtMeta -and $wtMeta.PSObject.Properties[$wen]) {
                $wcur = $wtMeta.$wen.desc
            }

            if ($wcur) { Write-Host "  현재: $wcur" -ForegroundColor DarkGray }
            Write-Host -NoNewline "  새 설명 (Enter=유지): " -ForegroundColor Yellow
            $wnew = Read-Host
            if (-not $wnew) { $wnew = $wcur }

            if ($wnew) {
                Save-WtDesc $wen $wnew
                Write-Host "  저장 완료: $wen -> $wnew" -ForegroundColor Green
            }
            continue
        }

        # ── wt [ren] ────────────────────────────────────
        if ($waction -eq "rename") {
            $renWtLines = $wtEntries | ForEach-Object { "$($_.Name.PadRight(24))($($_.Branch))" }
            $renWtSel = ($renWtLines -join "`n") | fzf --layout=reverse --prompt='rename wt> ' --height=40% --border --no-sort --header='이름변경할 worktree 선택'
            if (-not $renWtSel) { continue }

            $wrname = ($renWtSel -split '\s+')[0]
            $renTarget = $wtEntries | Where-Object { $_.Name -eq $wrname } | Select-Object -First 1
            Write-Host -NoNewline "  새 이름: " -ForegroundColor Yellow
            $wrnew = Read-Host
            if (-not $wrnew) { Write-Host "  취소됨."; continue }

            $oldDir = $renTarget.Path
            $newDir = Join-Path (Split-Path $oldDir -Parent) $wrnew

            $savedDir = (Get-Location).Path
            if ($savedDir.StartsWith($oldDir)) {
                Set-Location $projPath
            }

            git -C $projPath worktree move $oldDir $newDir 2>&1
            if ($LASTEXITCODE -eq 0) {
                git -C $projPath branch -m $renTarget.Branch $wrnew 2>&1
                Rename-WtMeta $wrname $wrnew
                Write-Host "  변경 완료: $wrname -> $wrnew" -ForegroundColor Green
            } else {
                Write-Host "  이름변경 실패. 다른 터미널이 해당 폴더에 있을 수 있음" -ForegroundColor Red
            }
            continue
        }

        # ── wt [del] ────────────────────────────────────
        if ($waction -eq "delete") {
            $delWtLines = $wtEntries | ForEach-Object { "$($_.Name.PadRight(24))($($_.Branch))" }
            $delWtSel = ($delWtLines -join "`n") | fzf --layout=reverse --prompt='delete wt> ' --height=40% --border --no-sort --header='삭제할 worktree 선택'
            if (-not $delWtSel) { continue }

            $wdname = ($delWtSel -split '\s+')[0]
            $delTarget = $wtEntries | Where-Object { $_.Name -eq $wdname } | Select-Object -First 1
            Write-Host -NoNewline "  '$wdname' 삭제? 브랜치는 유지됩니다. (y/N): " -ForegroundColor Yellow
            $confirm = Read-Host
            if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                $curDir = (Get-Location).Path
                if ($curDir.StartsWith($delTarget.Path)) {
                    Set-Location $projPath
                }
                git -C $projPath worktree remove $delTarget.Path 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Remove-WtMeta $wdname
                    Write-Host "  삭제 완료: $wdname" -ForegroundColor Green
                } else {
                    Write-Host "  삭제 실패. --force 필요할 수 있음" -ForegroundColor Red
                }
            } else {
                Write-Host "  취소됨."
            }
            continue
        }
    }
    # worktree Esc → 외부 루프 continue → 프로젝트 목록으로

    }  # 외부 루프 끝
}
