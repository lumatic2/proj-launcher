# proj: 프로젝트 폴더 인터랙티브 선택 + worktree 지원
# Requires: fzf, jq, git
# Source this file from ~/.zshrc:
#   source ~/projects/agent-orchestration/config/proj.zsh

proj() {
  local root="${PROJECTS_ROOT:-$HOME/projects}"
  local meta_file="$root/.proj-meta.json"

  # ── helpers ─────────────────────────────────────────────
  local meta
  meta=$( [[ -f $meta_file ]] && cat "$meta_file" || echo '{}' )

  _pm_save() { printf '%s\n' "$1" > "$meta_file"; }

  _pm_ago() {
    local diff=$(( $(date +%s) - ${1:-0} ))
    (( diff < 86400   )) && { printf '오늘';             return; }
    (( diff < 172800  )) && { printf '어제';             return; }
    local d=$(( diff / 86400 ))
    (( d < 7   )) && { printf '%d일 전'    $d;           return; }
    (( d < 35  )) && { printf '%d주 전'   $(( d / 7 ));  return; }
    (( d < 365 )) && { printf '%d개월 전' $(( d / 30 )); return; }
    printf '%d년 전' $(( d / 365 ))
  }

  _pm_sortkey() {
    local pdir=$1
    local marker="$pdir/.claude/.last-opened"
    if [[ -f $marker ]]; then
      stat -f '%m' "$marker" 2>/dev/null || echo 0
    else
      local gl; gl=$(git -C "$pdir" log -1 --format='%ct' 2>/dev/null)
      [[ $gl =~ ^[0-9]+$ ]] && echo "$gl" \
        || { stat -f '%m' "$pdir" 2>/dev/null || echo 0; }
    fi
  }

  _pm_touch() {
    mkdir -p "$1/.claude"
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$1/.claude/.last-opened"
  }

  _pm_ensure_wt_ignore() {
    local gi="$1/.gitignore"
    grep -qs '.claude/worktrees/' "$gi" && return
    printf '\n# Claude Code worktrees\n.claude/worktrees/\n' >> "$gi"
  }

  # ── worktree 메타 헬퍼 (jq 기반) ──────────────────────
  _pm_save_wt_desc() {
    local proj=$1 name=$2 desc=$3
    meta=$(jq --arg p "$proj" --arg n "$name" --arg d "$desc" \
              'if .[$p] == null then .[$p] = {} else . end
               | if .[$p].wt == null then .[$p].wt = {} else . end
               | .[$p].wt[$n] = {desc:$d}' <<<"$meta")
    _pm_save "$meta"
  }

  _pm_remove_wt_meta() {
    local proj=$1 name=$2
    meta=$(jq --arg p "$proj" --arg n "$name" 'del(.[$p].wt[$n])' <<<"$meta")
    _pm_save "$meta"
  }

  _pm_rename_wt_meta() {
    local proj=$1 old=$2 new=$3
    local old_val
    old_val=$(jq --arg p "$proj" --arg n "$old" '.[$p].wt[$n] // {}' <<<"$meta")
    meta=$(jq --arg p "$proj" --arg o "$old" --arg nn "$new" \
              --argjson v "$old_val" \
              'del(.[$p].wt[$o]) | .[$p].wt[$nn] = $v' <<<"$meta")
    _pm_save "$meta"
  }

  # ── 에이전트 런칭 메뉴 ─────────────────────────────────
  _pm_launch_agent() {
    local target_dir=$1
    local agent_menu="claude    Claude Code"$'\n'
    command -v codex  &>/dev/null && agent_menu+="codex     Codex CLI"$'\n'
    command -v gemini &>/dev/null && agent_menu+="gemini    Gemini CLI"$'\n'
    agent_menu+="shell     셸만 이동"$'\n'
    local pick
    pick=$(printf '%s' "$agent_menu" | fzf --layout=reverse --prompt='agent> ' --height=40% --border --no-sort \
               --header="$target_dir") || return 1
    local cmd; cmd=$(awk '{print $1}' <<<"$pick")
    case $cmd in
      claude) claude ;;
      codex)  codex   ;;
      gemini) gemini  ;;
      *)      ;;  # shell — cd만 하고 끝
    esac
  }

  # ── 색상 헬퍼 ──────────────────────────────────────────
  _pm_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
  _pm_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
  _pm_yellow() { printf '\033[33m%s\033[0m' "$*"; }
  _pm_gray()   { printf '\033[90m%s\033[0m\n' "$*"; }
  _pm_mag()    { printf '\033[35m%s\033[0m\n' "$*"; }

  # ══════════════════════════════════════════════════════════
  # 메인 루프: 프로젝트 → worktree → 에이전트
  # Esc는 한 단계 뒤로, 프로젝트 선택에서 Esc만 완전 종료
  # ══════════════════════════════════════════════════════════
  while true; do  # ── 외부 루프 (worktree Esc → 여기로 복귀)

  while true; do  # ── 프로젝트 선택 루프
    # 메타 리로드 (관리 액션 후 반영)
    meta=$( [[ -f $meta_file ]] && cat "$meta_file" || echo '{}' )

    # pin/archive 분류
    local pinned=() normal=()
    local name pdir sk ago pcat pdesc ppin parc line
    for d in "$root"/*/; do
      [[ -d $d ]] || continue
      name="${${d%/}##*/}"
      pdir="$root/$name"
      ppin=$(jq -r --arg n "$name" '.[$n].pin // false' <<<"$meta")
      parc=$(jq -r --arg n "$name" '.[$n].archive // false' <<<"$meta")
      [[ $parc == "true" ]] && continue  # 아카이브는 메인 목록에서 제외

      sk=$(_pm_sortkey "$pdir")
      ago=$(_pm_ago "$sk")
      pcat=$(jq -r --arg n "$name" '.[$n].cat // ""' <<<"$meta")
      pdesc=$(jq -r --arg n "$name" '.[$n].desc // ""' <<<"$meta")

      local row="${sk}"$'\t'"${name}"$'\t'"${ago}"$'\t'"${pcat}"$'\t'"${pdesc}"
      if [[ $ppin == "true" ]]; then
        pinned+=("$row")
      else
        normal+=("$row")
      fi
    done

    local sorted_pin sorted_normal
    sorted_pin=$(printf '%s\n' "${pinned[@]}" | sort -t$'\t' -k1 -rn)
    sorted_normal=$(printf '%s\n' "${normal[@]}" | sort -t$'\t' -k1 -rn)

    # fzf 입력: 핀 → 일반
    local fzf_input=""
    while IFS=$'\t' read -r sk name ago pcat pdesc _; do
      [[ -z $name ]] && continue
      printf -v line '* %-25s %-8s %-6s %s' "$name" "$ago" "$pcat" "$pdesc"
      fzf_input+="$line"$'\n'
    done <<<"$sorted_pin"

    while IFS=$'\t' read -r sk name ago pcat pdesc _; do
      [[ -z $name ]] && continue
      printf -v line '%-28s %-8s %-6s %s' "$name" "$ago" "$pcat" "$pdesc"
      fzf_input+="$line"$'\n'
    done <<<"$sorted_normal"

    local fzf_header
    fzf_header="  ctrl+N 새 프로젝트  ctrl+E 설명수정  ctrl+R 이름변경  ctrl+D 삭제"
    fzf_header+=$'\n'"  ctrl+P 핀  ctrl+X 아카이브  ctrl+A 아카이브목록  ctrl+S 상태  |  Esc 종료"
    fzf_header+=$'\n────────────────────────────────────────────────────────────────────────────'

    local fzf_out key sel
    fzf_out=$(printf '%s' "$fzf_input" | fzf --layout=reverse --prompt='proj> ' --height=40% --border --no-sort \
              --header="$fzf_header" \
              --expect='ctrl-n,ctrl-e,ctrl-r,ctrl-d,ctrl-p,ctrl-a,ctrl-x,ctrl-s') || return 0
    key=$(head -1 <<<"$fzf_out")
    sel=$(sed -n '2p' <<<"$fzf_out")

    # 선택된 프로젝트 이름 추출 (핀 마커 제거)
    local sel_name=""
    if [[ -n $sel ]]; then
      sel_name=$(awk '{print $1}' <<<"$sel")
      [[ $sel == '* '* ]] && sel_name=$(awk '{print $2}' <<<"$sel")
    fi

    # 관리 액션 판별
    local action=""
    [[ $key == 'ctrl-n' ]] && action="new"
    [[ $key == 'ctrl-e' ]] && action="edit"
    [[ $key == 'ctrl-r' ]] && action="rename"
    [[ $key == 'ctrl-d' ]] && action="delete"
    [[ $key == 'ctrl-p' ]] && action="pin"
    [[ $key == 'ctrl-x' ]] && action="archive"
    [[ $key == 'ctrl-a' ]] && action="archive-view"
    [[ $key == 'ctrl-s' ]] && action="status"

    # ── ctrl+S: 프로젝트 상태 ────────────────────────────
    if [[ $action == "status" ]]; then
      [[ -z $sel_name ]] && continue
      local sp="$root/$sel_name"
      [[ -d $sp ]] || { _pm_red "경로 없음: $sp"; continue; }

      local status_lines=""

      # 프로젝트명 + 설명
      local sd; sd=$(jq -r --arg n "$sel_name" '.[$n].desc // ""' <<<"$meta")
      local sc; sc=$(jq -r --arg n "$sel_name" '.[$n].cat // ""' <<<"$meta")
      status_lines+="  $sel_name"
      [[ -n $sc ]] && status_lines+="  [$sc]"
      [[ -n $sd ]] && status_lines+="  $sd"
      status_lines+=$'\n'

      # git 정보
      if git -C "$sp" rev-parse --git-dir &>/dev/null; then
        local sbranch; sbranch=$(git -C "$sp" branch --show-current 2>/dev/null || echo 'HEAD')
        local smod; smod=$(git -C "$sp" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        local sstatus="clean"
        (( smod > 0 )) && sstatus="${smod} modified"
        local sahead="" sbehind=""
        sahead=$(git -C "$sp" rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
        sbehind=$(git -C "$sp" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
        local spush=""
        (( sahead > 0 )) && spush+=" ${sahead} ahead"
        (( sbehind > 0 )) && spush+=" ${sbehind} behind"

        status_lines+="──────────────────────────────────────────────"$'\n'
        status_lines+="  branch:  $sbranch"$'\n'
        status_lines+="  status:  $sstatus${spush}"$'\n'

        # worktree 목록
        local swt_count=0 swt_lines=""
        while IFS= read -r wline; do
          if [[ $wline =~ ^worktree\ (.+)$ ]]; then
            local swt_path="${match[1]}"
          elif [[ $wline =~ ^branch\ refs/heads/(.+)$ && -n $swt_path ]]; then
            local swt_real; swt_real=$(realpath "$swt_path" 2>/dev/null || echo "$swt_path")
            local sp_real; sp_real=$(realpath "$sp" 2>/dev/null || echo "$sp")
            if [[ $swt_real != $sp_real ]]; then
              local swt_name="${swt_path##*/}"
              local swt_branch="${match[1]}"
              local swt_mod; swt_mod=$(git -C "$swt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
              local swt_st="clean"; (( swt_mod > 0 )) && swt_st="${swt_mod} mod"
              local swt_desc; swt_desc=$(jq -r --arg n "$swt_name" '.[$n].desc // ""' \
                    <<<"$(jq -r --arg p "$sel_name" '.[$p].wt // {}' <<<"$meta")")
              swt_lines+="    $swt_name ($swt_branch) [$swt_st]"
              [[ -n $swt_desc ]] && swt_lines+="  $swt_desc"
              swt_lines+=$'\n'
              (( swt_count++ ))
            fi
            swt_path=""
          fi
        done < <(git -C "$sp" worktree list --porcelain 2>/dev/null)

        status_lines+="  worktree: ${swt_count}개"$'\n'
        [[ -n $swt_lines ]] && status_lines+="$swt_lines"
      else
        status_lines+="──────────────────────────────────────────────"$'\n'
        status_lines+="  (git 저장소 아님)"$'\n'
      fi

      # ROADMAP 진행률
      local roadmap="$sp/ROADMAP.md"
      if [[ -f $roadmap ]]; then
        local rtotal rdone rpct
        rtotal=$(grep -cE '^\s*- \[[ x]\]' "$roadmap" 2>/dev/null || echo 0)
        rdone=$(grep -cE '^\s*- \[x\]' "$roadmap" 2>/dev/null || echo 0)
        if (( rtotal > 0 )); then
          rpct=$(( rdone * 100 / rtotal ))
          local rbar_done=$(( rpct / 5 )) rbar_left=$(( 20 - rpct / 5 ))
          local rbar=""
          for ((ri=0; ri<rbar_done; ri++)); do rbar+="█"; done
          for ((ri=0; ri<rbar_left; ri++)); do rbar+="░"; done
          status_lines+="──────────────────────────────────────────────"$'\n'
          status_lines+="  ROADMAP:  ${rbar} ${rdone}/${rtotal} (${rpct}%)"$'\n'
          # 미완료 항목 (최대 8개)
          local rcount=0
          while IFS= read -r rline; do
            (( rcount >= 8 )) && { status_lines+="    ..."$'\n'; break; }
            status_lines+="  $rline"$'\n'
            (( rcount++ ))
          done < <(grep -E '^\s*- \[ \]' "$roadmap" 2>/dev/null)
        fi
      fi

      status_lines+="──────────────────────────────────────────────"$'\n'

      printf '%s' "$status_lines" | fzf --layout=reverse --prompt='' --height=40% --border --no-sort \
            --header="  $sel_name 상태  |  Esc 뒤로" --disabled
      continue
    fi

    # ── ctrl+A: 아카이브 화면 ────────────────────────────
    if [[ $action == "archive-view" ]]; then
      while true; do
        meta=$( [[ -f $meta_file ]] && cat "$meta_file" || echo '{}' )
        local arc_input="" arc_count=0
        for d in "$root"/*/; do
          [[ -d $d ]] || continue
          name="${${d%/}##*/}"
          parc=$(jq -r --arg n "$name" '.[$n].archive // false' <<<"$meta")
          [[ $parc != "true" ]] && continue
          sk=$(_pm_sortkey "$root/$name")
          ago=$(_pm_ago "$sk")
          pcat=$(jq -r --arg n "$name" '.[$n].cat // ""' <<<"$meta")
          pdesc=$(jq -r --arg n "$name" '.[$n].desc // ""' <<<"$meta")
          printf -v line '%-28s %-8s %-6s %s' "$name" "$ago" "$pcat" "$pdesc"
          arc_input+="$line"$'\n'
          (( arc_count++ ))
        done

        if (( arc_count == 0 )); then
          _pm_gray "  아카이브가 비어 있습니다."
          break
        fi

        local arc_header
        arc_header="  ctrl+R 복구  ctrl+D 영구삭제  |  Esc 뒤로"
        arc_header+=$'\n────────────────────────────────────────────────────────────────────────────'

        local arc_out arc_key arc_sel arc_name
        arc_out=$(printf '%s' "$arc_input" | fzf --layout=reverse --prompt='archive> ' --height=40% --border --no-sort \
                  --header="$arc_header" \
                  --expect='ctrl-r,ctrl-d') || break  # Esc → 메인 목록으로
        arc_key=$(head -1 <<<"$arc_out")
        arc_sel=$(sed -n '2p' <<<"$arc_out")
        arc_name=$(awk '{print $1}' <<<"$arc_sel")
        [[ -z $arc_name ]] && continue

        if [[ $arc_key == 'ctrl-r' ]]; then
          meta=$(jq --arg n "$arc_name" '.[$n].archive = false' <<<"$meta")
          _pm_save "$meta"
          _pm_green "  복구: $arc_name"
          continue
        fi

        if [[ $arc_key == 'ctrl-d' ]]; then
          _pm_red "  '$arc_name' 영구삭제? 복구 불가 (y/N): "; read -r confirm
          if [[ $confirm == [yY] ]]; then
            [[ $PWD == "$root/$arc_name"* ]] && cd "$root"
            rm -rf "$root/$arc_name"
            meta=$(jq --arg n "$arc_name" 'del(.[$n])' <<<"$meta")
            _pm_save "$meta"
            _pm_green "  영구삭제 완료: $arc_name"
          else
            echo '  취소됨.'
          fi
          continue
        fi

        # Enter로 선택 시 해당 프로젝트 열기 (아카이브 상태 유지)
        if [[ -z $arc_key && -n $arc_name && -d "$root/$arc_name" ]]; then
          _pm_touch "$root/$arc_name"
          cd "$root/$arc_name" && _pm_green "-> $root/$arc_name"
          _pm_launch_agent "$root/$arc_name" || continue
          return
        fi
      done
      continue
    fi

    # ── ctrl+P: 핀 토글 ─────────────────────────────────
    if [[ $action == "pin" ]]; then
      [[ -z $sel_name ]] && continue
      local cur_pin; cur_pin=$(jq -r --arg n "$sel_name" '.[$n].pin // false' <<<"$meta")
      if [[ $cur_pin == "true" ]]; then
        meta=$(jq --arg n "$sel_name" '.[$n].pin = false' <<<"$meta")
        _pm_gray "  핀 해제: $sel_name"
      else
        meta=$(jq --arg n "$sel_name" '.[$n].pin = true | .[$n].archive = false' <<<"$meta")
        _pm_green "  * 핀 고정: $sel_name"
      fi
      _pm_save "$meta"
      continue
    fi

    # ── ctrl+X: 아카이브에 넣기 ──────────────────────────
    if [[ $action == "archive" ]]; then
      [[ -z $sel_name ]] && continue
      meta=$(jq --arg n "$sel_name" '.[$n].archive = true | .[$n].pin = false' <<<"$meta")
      _pm_save "$meta"
      _pm_gray "  아카이브: $sel_name"
      continue
    fi

    # ── [+new] ───────────────────────────────────────────
    if [[ $action == "new" ]]; then
      _pm_yellow '  프로젝트 이름: '; read -r pname
      [[ -z $pname ]] && { echo '  취소됨.'; continue; }
      local ppath="$root/$pname"
      [[ -d $ppath ]] && { _pm_red "  이미 존재: $ppath"; continue; }

      _pm_yellow '  설명 (한글 OK): '; read -r pdesc
      _pm_yellow '  카테고리 (AI/Web/MCP/Bot/Game/Tool/Infra/Etc): '; read -r pcat
      [[ -z $pcat ]] && pcat='Etc'

      mkdir -p "$ppath"
      git -C "$ppath" init -b main &>/dev/null

      cat > "$ppath/CLAUDE.md" <<EOF
# $pname

> $pdesc

## Tech Stack
<!-- 사용 기술 스택 -->

## Structure
<!-- 주요 디렉토리/파일 구조 -->

## Conventions
<!-- 코딩 컨벤션, 네이밍 규칙 등 -->
EOF

      cat > "$ppath/.gitignore" <<EOF
# Claude Code
.claude/worktrees/
.claude/.last-opened
EOF

      meta=$(jq --arg n "$pname" --arg c "$pcat" --arg d "$pdesc" \
                '.[$n] = {cat:$c, desc:$d}' <<<"$meta")
      _pm_save "$meta"
      _pm_touch "$ppath"
      _pm_green "  생성 완료: $ppath"
      continue
    fi

    # ── [edit] ───────────────────────────────────────────
    if [[ $action == "edit" ]]; then
      [[ -z $sel_name ]] && continue
      local cur_cat; cur_cat=$(jq -r --arg n "$sel_name" '.[$n].cat // ""' <<<"$meta")
      local cur_desc; cur_desc=$(jq -r --arg n "$sel_name" '.[$n].desc // ""' <<<"$meta")
      _pm_gray "  [$sel_name] 현재: [$cur_cat] $cur_desc"
      _pm_yellow "  설명 (Enter=유지): "; read -r new_desc
      [[ -z $new_desc ]] && new_desc="$cur_desc"
      _pm_yellow "  카테고리 (Enter=유지, 현재=$cur_cat): "; read -r new_cat
      [[ -z $new_cat ]] && new_cat="$cur_cat"
      meta=$(jq --arg n "$sel_name" --arg c "$new_cat" --arg d "$new_desc" \
                '.[$n].cat = $c | .[$n].desc = $d' <<<"$meta")
      _pm_save "$meta"
      _pm_green "  저장 완료: [$new_cat] $new_desc"
      continue
    fi

    # ── [ren] ────────────────────────────────────────────
    if [[ $action == "rename" ]]; then
      [[ -z $sel_name ]] && continue
      _pm_yellow "  새 이름 ($sel_name): "; read -r new_name
      [[ -z $new_name ]] && { echo '  취소됨.'; continue; }
      local new_path="$root/$new_name"
      [[ -d $new_path ]] && { _pm_red "  이미 존재: $new_path"; continue; }
      [[ $PWD == "$root/$sel_name"* ]] && cd "$root"
      if mv "$root/$sel_name" "$new_path"; then
        local old_val; old_val=$(jq --arg n "$sel_name" '.[$n] // {}' <<<"$meta")
        meta=$(jq --arg o "$sel_name" --arg nn "$new_name" --argjson v "$old_val" \
                  'del(.[$o]) | .[$nn] = $v' <<<"$meta")
        _pm_save "$meta"
        _pm_green "  변경 완료: $sel_name -> $new_name"
      else
        _pm_red '  이름변경 실패'
      fi
      continue
    fi

    # ── [del] ────────────────────────────────────────────
    if [[ $action == "delete" ]]; then
      [[ -z $sel_name ]] && continue
      _pm_red "  '$sel_name' 을 정말 삭제? 복구 불가 (y/N): "; read -r confirm
      if [[ $confirm == [yY] ]]; then
        [[ $PWD == "$root/$sel_name"* ]] && cd "$root"
        rm -rf "$root/$sel_name"
        meta=$(jq --arg n "$sel_name" 'del(.[$n])' <<<"$meta")
        _pm_save "$meta"
        _pm_green "  삭제 완료: $sel_name"
      else
        echo '  취소됨.'
      fi
      continue
    fi

    # ── 프로젝트 선택됨 → 루프 탈출 ─────────────────────
    [[ -z $sel_name ]] && continue
    local proj_name="$sel_name"
    local proj_path="$root/$proj_name"
    [[ -d $proj_path ]] || { _pm_red "경로 없음: $proj_path"; continue; }
    break
  done

  # ── 비git 프로젝트 ─────────────────────────────────────
  if ! git -C "$proj_path" rev-parse --git-dir &>/dev/null; then
    _pm_touch "$proj_path"
    cd "$proj_path" && _pm_green "-> $proj_path"
    _pm_launch_agent "$proj_path" || continue  # agent Esc → 프로젝트 목록
    return
  fi

  # ══════════════════════════════════════════════════════════
  # Step 2: worktree 선택 (루프)
  # ══════════════════════════════════════════════════════════
  while true; do
    meta=$( [[ -f $meta_file ]] && cat "$meta_file" || echo '{}' )

    local branch; branch=$(git -C "$proj_path" branch --show-current 2>/dev/null || echo 'HEAD')
    local wt_meta; wt_meta=$(jq -r --arg n "$proj_name" '.[$n].wt // {}' <<<"$meta")

    # worktree 목록 파싱
    local -a wt_paths=() wt_names=()
    local cur_wt="" real_wt real_proj
    while IFS= read -r line; do
      if [[ $line =~ ^worktree\ (.+)$ ]]; then
        cur_wt="${match[1]}"
      elif [[ $line =~ ^branch\ refs/heads/ && -n $cur_wt ]]; then
        real_wt=$(realpath "$cur_wt" 2>/dev/null || echo "$cur_wt")
        real_proj=$(realpath "$proj_path" 2>/dev/null || echo "$proj_path")
        if [[ $real_wt != $real_proj ]]; then
          wt_paths+=("$cur_wt")
          wt_names+=("${cur_wt##*/}")
        fi
        cur_wt=""
      fi
    done < <(git -C "$proj_path" worktree list --porcelain 2>/dev/null)

    # fzf 입력: 루트/worktree 목록만
    local wt_fzf="" wn wp wsk wago wdesc wline
    wt_fzf+="[main]  프로젝트 루트  ($branch)"$'\n'
    for ((i=1; i<=${#wt_paths[@]}; i++)); do
      wn="${wt_names[$i]}"
      wp="${wt_paths[$i]}"
      wsk=$(_pm_sortkey "$wp")
      wago=$(_pm_ago "$wsk")
      wdesc=$(jq -r --arg n "$wn" '.[$n].desc // ""' <<<"$wt_meta")
      printf -v wline '[wt]    %-20s %-8s %s' "$wn" "$wago" "$wdesc"
      wt_fzf+="$wline"$'\n'
    done

    local wt_expect='ctrl-n'
    (( ${#wt_paths[@]} > 0 )) && wt_expect='ctrl-n,ctrl-e,ctrl-r,ctrl-d'

    local wt_header="  ctrl+N 새 worktree"
    (( ${#wt_paths[@]} > 0 )) && wt_header+="  ctrl+E 설명수정  ctrl+R 이름변경  ctrl+D 삭제"
    wt_header+="  |  Esc 뒤로"
    wt_header+=$'\n────────────────────────────────────────────────────────────────────────────'

    local wfzf_out wkey wsel
    wfzf_out=$(printf '%s' "$wt_fzf" | fzf --layout=reverse --prompt="${proj_name}> " --height=40% --border --no-sort \
               --header="$wt_header" \
               --expect="$wt_expect") || break  # Esc → 프로젝트 목록으로
    wkey=$(head -1 <<<"$wfzf_out")
    wsel=$(sed -n '2p' <<<"$wfzf_out")

    # 관리 액션 판별
    local waction=""
    [[ $wkey == 'ctrl-n' ]] && waction="new"
    [[ $wkey == 'ctrl-e' ]] && waction="edit"
    [[ $wkey == 'ctrl-r' ]] && waction="rename"
    [[ $wkey == 'ctrl-d' ]] && waction="delete"

    # ── [main] / [wt] 선택 → 탈출 ───────────────────────
    if [[ -z $waction ]]; then
      if [[ $wsel == '[main]'* ]]; then
        _pm_touch "$proj_path"
        cd "$proj_path" && _pm_green "-> $proj_path"
        _pm_launch_agent "$proj_path" || continue  # agent Esc → worktree 목록
        return
      fi
      if [[ $wsel == '[wt]'* ]]; then
        local wt_sel_name; wt_sel_name=$(awk '{print $2}' <<<"$wsel")
        local wt_target=""
        for ((i=1; i<=${#wt_names[@]}; i++)); do
          [[ ${wt_names[$i]} == "$wt_sel_name" ]] && { wt_target="${wt_paths[$i]}"; break; }
        done
        if [[ -d $wt_target ]]; then
          _pm_touch "$proj_path"
          cd "$wt_target" && _pm_mag "-> $wt_target"
          _pm_launch_agent "$wt_target" || continue  # agent Esc → worktree 목록
        else
          _pm_red "경로 없음: $wt_sel_name"
          continue
        fi
        return
      fi
      continue
    fi

    # ── wt [+new] ────────────────────────────────────────
    if [[ $waction == "new" ]]; then
      _pm_yellow '  Worktree 이름 (예: auth-refactor): '; read -r wt_name
      [[ -z $wt_name ]] && { echo '취소됨.'; continue; }
      _pm_yellow '  설명 (Enter=생략): '; read -r wt_desc

      _pm_ensure_wt_ignore "$proj_path"
      local wt_dir="$proj_path/.claude/worktrees/$wt_name"
      mkdir -p "$(dirname "$wt_dir")"

      if git -C "$proj_path" worktree add "$wt_dir" -b "$wt_name"; then
        local inc="$proj_path/.worktreeinclude"
        if [[ -f $inc ]]; then
          while IFS= read -r f; do
            f="${f## }"; f="${f%% }"
            [[ -z $f || $f == '#'* ]] && continue
            local src="$proj_path/$f"
            [[ -f $src ]] && cp -p "$src" "$wt_dir/$f"
          done < "$inc"
        fi
        if [[ -n $wt_desc ]]; then
          _pm_save_wt_desc "$proj_name" "$wt_name" "$wt_desc"
        fi
        _pm_touch "$proj_path"
        _pm_mag "  생성 완료: Worktree '$wt_name'"
        _pm_gray "  경로: $wt_dir"
      else
        _pm_red 'Worktree 생성 실패'
      fi
      continue
    fi

    # ── wt [edit] ────────────────────────────────────────
    if [[ $waction == "edit" ]]; then
      local wedit_input="" wd
      for ((i=1; i<=${#wt_names[@]}; i++)); do
        wn="${wt_names[$i]}"
        wd=$(jq -r --arg n "$wn" '.[$n].desc // ""' <<<"$wt_meta")
        printf -v wline '%-24s %s' "$wn" "$wd"
        wedit_input+="$wline"$'\n'
      done
      local wesel
      wesel=$(printf '%s' "$wedit_input" | fzf --layout=reverse --prompt='edit wt> ' --height=40% --border --no-sort \
                  --header='설명 수정할 worktree 선택') || continue
      local wen; wen=$(awk '{print $1}' <<<"$wesel")
      local wcur; wcur=$(jq -r --arg n "$wen" '.[$n].desc // ""' <<<"$wt_meta")
      [[ -n $wcur ]] && _pm_gray "  현재: $wcur"
      _pm_yellow '  새 설명 (Enter=유지): '; read -r wnew
      [[ -z $wnew ]] && wnew="$wcur"
      if [[ -n $wnew ]]; then
        _pm_save_wt_desc "$proj_name" "$wen" "$wnew"
        _pm_green "  저장 완료: $wen -> $wnew"
      fi
      continue
    fi

    # ── wt [ren] ─────────────────────────────────────────
    if [[ $waction == "rename" ]]; then
      local wren_input=""
      for ((i=1; i<=${#wt_names[@]}; i++)); do
        wren_input+="${wt_names[$i]}"$'\n'
      done
      local wrsel
      wrsel=$(printf '%s' "$wren_input" | fzf --layout=reverse --prompt='rename wt> ' --height=40% --border --no-sort \
                  --header='이름변경할 worktree 선택') || continue
      local wrname="${wrsel%% *}"
      _pm_yellow '  새 이름: '; read -r wrnew
      [[ -z $wrnew ]] && { echo '  취소됨.'; continue; }
      local wold_dir="$proj_path/.claude/worktrees/$wrname"
      local wnew_dir="$proj_path/.claude/worktrees/$wrnew"
      [[ $PWD == "$wold_dir"* ]] && cd "$proj_path"
      if git -C "$proj_path" worktree move "$wold_dir" "$wnew_dir"; then
        git -C "$proj_path" branch -m "$wrname" "$wrnew" 2>/dev/null
        _pm_rename_wt_meta "$proj_name" "$wrname" "$wrnew"
        _pm_green "  변경 완료: $wrname -> $wrnew"
      else
        _pm_red '  이름변경 실패 (다른 터미널이 해당 폴더에 있을 수 있음)'
      fi
      continue
    fi

    # ── wt [del] ─────────────────────────────────────────
    if [[ $waction == "delete" ]]; then
      local wdel_input=""
      for ((i=1; i<=${#wt_names[@]}; i++)); do wdel_input+="${wt_names[$i]}"$'\n'; done
      local wdsel
      wdsel=$(printf '%s' "$wdel_input" | fzf --layout=reverse --prompt='delete wt> ' --height=40% --border --no-sort \
                  --header='삭제할 worktree 선택') || continue
      local wdname="${wdsel%% *}"
      _pm_yellow "  '$wdname' 삭제? 브랜치는 유지됩니다. (y/N): "; read -r wdconfirm
      if [[ $wdconfirm == [yY] ]]; then
        local wdpath="$proj_path/.claude/worktrees/$wdname"
        [[ $PWD == "$wdpath"* ]] && cd "$proj_path"
        if git -C "$proj_path" worktree remove "$wdpath"; then
          _pm_remove_wt_meta "$proj_name" "$wdname"
          _pm_green "  삭제 완료: $wdname"
        else
          _pm_red '  삭제 실패 (--force 필요할 수 있음)'
        fi
      else
        echo '  취소됨.'
      fi
      continue
    fi
  done
  # worktree Esc → 외부 루프 continue → 프로젝트 목록으로

  done  # 외부 루프 끝
}
