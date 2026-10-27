#!/usr/bin/env bash
# =============================================================================
# git-log.sh — 每天把本机运行状态提交到 Git 仓库
#
# 正常执行（给 cron / 1Panel 计划任务调用）：
#   bash /opt/git-log/git-log.sh
#
# 调试（只打印内容，不写文件、不提交）：
#   DRY_RUN=1 bash /opt/git-log/git-log.sh
#
# 配置来自 /etc/git-log.conf（install.sh 会自动生成）
#
# 多节点共用一个仓库：
#   记录写在 $CONTENT_DIR/<NODE_NAME>/YYYY-MM-DD.md，
#   NODE_NAME 默认取主机名，可用配置或环境变量覆盖，
#   不同节点各写各的目录，push 冲突由内置重试处理。
# =============================================================================
set -uo pipefail

CONF_FILE="${CONF_FILE:-/etc/git-log.conf}"
if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
fi

REPO_DIR="${REPO_DIR:-/opt/git-log/repo}"
BRANCH="${BRANCH:-main}"
CONTENT_DIR="${CONTENT_DIR:-daily}"
GIT_NAME="${GIT_NAME:-git-log-bot}"
GIT_EMAIL="${GIT_EMAIL:-git-log-bot@users.noreply.github.com}"
TZ_NAME="${TZ_NAME:-Asia/Shanghai}"
LOG_FILE="${LOG_FILE:-/var/log/git-log.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/git-log.lock}"
DRY_RUN="${DRY_RUN:-0}"

# 时区务必显式指定：1Panel 容器 / cron 环境常是 UTC，
# 否则 23 点后的提交会被算到「昨天」。
export TZ="$TZ_NAME"
export HOME="${HOME:-/root}"
# 强制英文输出：系统 locale 是中文时 free 会打印「内存：」而不是「Mem:」，
# awk 里的 /^Mem:/ 匹配不到，采集结果就会变成 "-"。
export LC_ALL=C
export LANG=C

# 节点名：决定记录落在 $CONTENT_DIR/<节点名>/ 下。
# 多个节点共用同一个仓库时靠它区分，各写各的目录，互不覆盖。
# 未配置时默认用主机名。
NODE_NAME="${NODE_NAME:-}"
if [ -z "$NODE_NAME" ]; then
    NODE_NAME="$(hostname 2>/dev/null || echo unknown)"
fi
# 只清理真正危险的字符（路径分隔符、空格、控制字符），
# 中文等正常字符保留；规则需与 install.sh 保持一致。
NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '/ ' '__' | tr -d '\000-\037\177')"
case "$NODE_NAME" in
    . | .. | "") NODE_NAME="unknown" ;;
esac

# 禁止 git 弹出账号密码交互，避免计划任务卡死
export GIT_TERMINAL_PROMPT=0
if [ -n "${GIT_SSH_COMMAND:-}" ]; then
    export GIT_SSH_COMMAND
fi

# tzdata 缺失时 TZ=Asia/Shanghai 会静默失效并退回 UTC，
# 导致 commit 时间差 8 小时、被算到前一天。这里先探测，无效就退回系统时区。
if [ -n "${TZ_NAME:-}" ]; then
    if [ "$(TZ="$TZ_NAME" date '+%z' 2>/dev/null)" != "+0800" ]; then
        TZ_WARN="时区 $TZ_NAME 在该环境不可用（可能缺 tzdata），已退回系统时区"
        export TZ=""
    fi
fi

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') [git-log:$NODE_NAME] $*"
    echo "$msg"
    echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

# 统一入口。加 -c safe.directory 是为了绕开
# 「detected dubious ownership」——计划任务以 root 跑、
# 而仓库属主是别的用户时必然踩到。
g() {
    git -C "$REPO_DIR" -c safe.directory="$REPO_DIR" "$@"
}

cpu_temp() {
    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        awk '{printf "%.1f°C", $1 / 1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "-"
    else
        echo "-"
    fi
}

# 把远端最新提交 rebase 到本地。
# 远端还没有该分支时（空仓库首次运行）直接返回成功，
# 否则 git 会报 couldn't find remote ref 而失败。
sync_branch() {
    g ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 || return 0
    if g pull --rebase --autostash origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
        return 0
    fi
    g rebase --abort >>"$LOG_FILE" 2>&1 || true

    # 兜底：rebase 仍失败时（比如历史完全无关、或自动合并冲突），
    # 改用 merge 强行合并，宁可留个 merge 提交也别让当天记录丢掉。
    if g fetch -q origin "$BRANCH" >>"$LOG_FILE" 2>&1 &&
        g merge --no-edit --allow-unrelated-histories "origin/$BRANCH" >>"$LOG_FILE" 2>&1; then
        log "rebase 未成功，已改用 merge 合并远端"
        return 0
    fi
    g merge --abort >>"$LOG_FILE" 2>&1 || true
    return 1
}

main() {
    log "===== 开始 ====="
    [ -n "${TZ_WARN:-}" ] && log "WARN: $TZ_WARN"

    command -v git >/dev/null 2>&1 || die "找不到 git，请先安装：sudo apt install -y git"
    [ -d "$REPO_DIR/.git" ] || die "目录不存在或不是 git 仓库：$REPO_DIR"

    if [ "$DRY_RUN" != "1" ] && [ -n "$LOCK_FILE" ]; then
        exec 9>"$LOCK_FILE" 2>/dev/null || true
        if command -v flock >/dev/null 2>&1; then
            flock -n 9 || die "上一次任务还在运行，本次跳过"
        fi
    fi

    # rebase / pull 需要持久化的 committer 身份，
    # 只靠 commit 时的 -c 参数不够（会报 Committer identity unknown）。
    # 系统没配全局身份时补一份仓库级配置，不动用户的全局设置。
    if [ -z "$(g config user.email 2>/dev/null || true)" ]; then
        g config user.name "$GIT_NAME"
        g config user.email "$GIT_EMAIL"
        log "仓库缺少 git 身份，已补上：$GIT_NAME <$GIT_EMAIL>"
    fi

    if [ -z "$BRANCH" ] || [ "$BRANCH" = "auto" ]; then
        BRANCH="$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    fi

    local today now host up load mem disk temp row file
    today="$(date '+%Y-%m-%d')"
    now="$(date '+%H:%M:%S')"
    host="$(hostname 2>/dev/null || echo unknown)"
    up="$(uptime -p 2>/dev/null | sed 's/^up //' || true)"
    [ -n "$up" ] || up="-"
    load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '-')"
    mem="$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%dMB", $3, $2}' || true)"
    [ -n "$mem" ] || mem="-"
    disk="$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || true)"
    [ -n "$disk" ] || disk="-"
    temp="$(cpu_temp)"

    row="| $now | $host | $up | $load | $mem | $disk | $temp |"

    # 节点名作为子目录：daily/<节点名>/2026-10-27.md
    file="$REPO_DIR/$CONTENT_DIR/$NODE_NAME/$today.md"

    if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN：本应追加到 $file"
        echo "$row"
        log "===== 结束（DRY_RUN）====="
        exit 0
    fi

    local node_dir="$REPO_DIR/$CONTENT_DIR/$NODE_NAME"
    mkdir -p "$node_dir" || die "无法创建目录：$node_dir"

    # 每个节点目录里放一份说明，多节点共用仓库时一眼能看出目录对应哪台机器
    if [ ! -f "$node_dir/README.md" ]; then
        local hw_model os_pretty
        hw_model="$(awk -F': ' '/^Model/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
        [ -n "$hw_model" ] || hw_model="-"
        os_pretty="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" || echo "-")"
        cat >"$node_dir/README.md" <<EOF
# $NODE_NAME

| 项目 | 值 |
| --- | --- |
| 节点名 | $NODE_NAME |
| 主机名 | $host |
| 硬件 | $hw_model |
| 系统 | $os_pretty |
| 首次记录 | $today |

每日记录见本目录的 \`YYYY-MM-DD.md\`，同一天多次运行会追加多行。
EOF
        log "新建节点说明：$node_dir/README.md"
    fi

    # 空仓库 clone 下来默认分支可能是 master，这里对齐到配置的分支
    local cur
    cur="$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [ "$cur" != "$BRANCH" ]; then
        if g show-ref --verify --quiet "refs/heads/$BRANCH"; then
            g checkout "$BRANCH" >>"$LOG_FILE" 2>&1 || die "切换到分支 $BRANCH 失败"
        else
            g checkout -q -b "$BRANCH" >>"$LOG_FILE" 2>&1 || die "创建分支 $BRANCH 失败"
        fi
        log "已切换到分支 $BRANCH（原为 $cur）"
    fi

    if [ ! -f "$file" ]; then
        cat >"$file" <<EOF
# $today

| 时间 | 主机 | 运行时长 | 负载(1/5/15) | 内存 | 根分区 | CPU 温度 |
| --- | --- | --- | --- | --- | --- | --- |
EOF
        log "新建当日记录文件：$file"
    fi

    printf '%s\n' "$row" >>"$file" || die "写入失败：$file"
    log "已写入：$row"

    # add -A 会把仓库里所有改动一起提交，
    # 所以你往这个仓库里随手放的文件（笔记、配置）也会被自动存档。
    g add -A || die "git add 失败"

    if g diff --cached --quiet; then
        log "没有需要提交的变更，跳过"
        log "===== 结束 ====="
        exit 0
    fi

    local changed
    changed="$(g diff --cached --name-only | tr '\n' ' ')"
    g -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
        commit -m "chore(daily): $NODE_NAME $today 运行记录" >/dev/null 2>&1 \
        || die "git commit 失败"

    local sha
    sha="$(g rev-parse --short HEAD)"
    log "已提交 $sha（变更文件：$changed）"

    # 多个节点共用一个仓库时，push 很容易因为别的节点刚推过而被拒，
    # 所以失败就 rebase 远端再试，最多 3 轮。
    local attempt=1
    while [ "$attempt" -le 3 ]; do
        if g push origin "HEAD:$BRANCH" >>"$LOG_FILE" 2>&1; then
            log "已推送到 origin/$BRANCH"
            break
        fi
        if [ "$attempt" -ge 3 ]; then
            die "git push 连续 3 次失败，请检查认证配置与网络（详细日志：$LOG_FILE）"
        fi
        log "第 $attempt 次推送失败，rebase 远端后重试"
        sleep $((attempt * 2))
        sync_branch || die "git pull --rebase 失败（可能存在内容冲突），请手动处理 $REPO_DIR"
        attempt=$((attempt + 1))
    done

    log "===== 结束 ====="
}

main "$@"
