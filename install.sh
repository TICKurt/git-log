#!/usr/bin/env bash
# =============================================================================
# install.sh — 一次性完成 git-log 的部署
#
# 用法：
#   sudo bash install.sh
#     （不带参数时逐项询问）
#
#   sudo bash install.sh \
#     --repo git@github.com:你的用户名/daily-log.git \
#     --auth ssh --branch main
#
# 参数：
#   --repo URL      仓库地址（SSH 或 HTTPS 均可）
#   --auth MODE     ssh | https   （默认 ssh）
#   --branch NAME   分支名      （默认 main）
#   --dir PATH      安装目录     （默认 /opt/git-log，多实例时自动带后缀）
#   --token TOKEN   HTTPS 方式使用的 GitHub Personal Access Token
#   --node NAME     节点名，决定记录写入 daily/<节点名>/（默认取主机名）
#   --instance NAME 实例名，同一台机器部署多个副本时用来隔离
#                   配置 / 日志 / 锁文件（默认 git-log）
#
# 多节点共用一个仓库：每台机器各自安装一次，用不同 --node 区分；
# 同一台机器跑多个副本：再加不同 --instance 避免互相覆盖。
# =============================================================================
set -uo pipefail

INSTANCE="git-log"
PREFIX=""
PREFIX_OVERRIDE=""
CONF_FILE=""
NODE_NAME=""
LOG_FILE=""
LOCK_FILE=""
REPO_URL=""
AUTH_MODE=""
BRANCH=""
TOKEN=""
SSH_KEY="$HOME/.ssh/daily_commit"
SSH_HOST_ALIAS="github-daily"

c_ok()   { printf '\033[32m%s\033[0m\n' "✓ $*"; }
c_info() { printf '\033[36m%s\033[0m\n' "→ $*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "! $*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "✗ $*" >&2; }
die()    { c_err "$*"; exit 1; }

ask() {
    # ask "提示" "默认值" -> 结果放 REPLY
    local prompt="$1" default="${2:-}" input
    if [ -n "$default" ]; then
        read -r -p "  $prompt [$default]: " input || true
        REPLY="${input:-$default}"
    else
        while [ -z "${input:-}" ]; do
            read -r -p "  $prompt: " input || true
        done
        REPLY="$input"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)   REPO_URL="${2:-}"; shift 2 ;;
        --auth)   AUTH_MODE="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --dir)    PREFIX_OVERRIDE="${2:-}"; shift 2 ;;
        --token)  TOKEN="${2:-}"; shift 2 ;;
        --node)     NODE_NAME="${2:-}"; shift 2 ;;
        --instance) INSTANCE="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done

# 实例名决定配置 / 日志 / 锁的落点：
# 默认实例保持原路径不变，其他实例加 -<实例名> 后缀，互不覆盖。
if [ -z "$PREFIX_OVERRIDE" ]; then
    if [ "$INSTANCE" = "git-log" ]; then
        PREFIX="/opt/git-log"
    else
        PREFIX="/opt/git-log-$INSTANCE"
    fi
else
    PREFIX="$PREFIX_OVERRIDE"
fi

if [ "$INSTANCE" = "git-log" ]; then
    CONF_FILE="/etc/git-log.conf"
    LOG_FILE="/var/log/git-log.log"
    LOCK_FILE="/tmp/git-log.lock"
else
    CONF_FILE="/etc/git-log-$INSTANCE.conf"
    LOG_FILE="/var/log/git-log-$INSTANCE.log"
    LOCK_FILE="/tmp/git-log-$INSTANCE.lock"
fi

# 节点名默认值先只记下主机名，
# 真正的取值放到 [2/7] 里，让用户可以在向导里自定义。
HOSTNAME_DEFAULT="$(hostname 2>/dev/null || echo unknown)"

REPO_DIR="$PREFIX/repo"
SCRIPT_DST="$PREFIX/git-log.sh"
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/git-log.sh"

echo "=============================================="
echo " git-log 安装向导"
echo "=============================================="

# ---------------------------------------------------------------- 1 环境检查
c_info "[1/7] 检查环境"
[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"
command -v git >/dev/null 2>&1 || {
    c_warn "未安装 git，尝试自动安装..."
    apt-get update -qq && apt-get install -y -qq git || die "git 安装失败，请手动安装"
}
c_ok "环境检查通过（$(git --version)）"

# ---------------------------------------------------------------- 2 收集配置
c_info "[2/7] 收集配置"
[ -f "$SCRIPT_SRC" ] || die "同目录下缺少 git-log.sh，请把两个脚本一起上传"

if [ -z "$REPO_URL" ]; then
    echo "  请先在 GitHub 上建一个仓库（建议空仓库、Private 也可以），然后填地址"
    echo "  例：git@github.com:yourname/daily-log.git"
    echo "      https://github.com/yourname/daily-log.git"
    ask "仓库地址"
    REPO_URL="$REPLY"
fi

if [ -z "$AUTH_MODE" ]; then
    echo "  认证方式："
    echo "    1) SSH Deploy Key（推荐，密钥只对这个仓库有写权限）"
    echo "    2) HTTPS + Personal Access Token（没有 SSH 环境时用）"
    ask "选择 [1/2]" "1"
    case "$REPLY" in
        2) AUTH_MODE="https" ;;
        *) AUTH_MODE="ssh" ;;
    esac
fi

if [ -z "$BRANCH" ]; then
    ask "分支名" "main"
    BRANCH="$REPLY"
fi

# 节点名：自定义这个名字，决定记录落在 daily/<节点名>/ 下，
# 也是 commit 信息和节点 README 的标题。
# 多台设备共用一个仓库时，靠它区分各自的文件夹。
if [ -z "$NODE_NAME" ]; then
    echo "  节点名：决定记录写入 daily/<节点名>/，多台设备共用一个仓库时用来区分"
    if [ -t 0 ]; then
        ask "节点名（回车用主机名 $HOSTNAME_DEFAULT）" "$HOSTNAME_DEFAULT"
        NODE_NAME="$REPLY"
    else
        NODE_NAME="$HOSTNAME_DEFAULT"
    fi
fi

# 规范化：只替换真正危险的字符（路径分隔符、空格、控制字符），
# 中文等正常字符保留，避免用户输中文名时被整体抹成 unknown。
node_raw="$NODE_NAME"
NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '/ ' '__' | tr -d '\000-\037\177')"
case "$NODE_NAME" in
    . | .. | "") NODE_NAME="unknown" ;;
esac
if [ "$NODE_NAME" != "$node_raw" ]; then
    c_warn "节点名「$node_raw」含空格或斜杠，已替换成：$NODE_NAME"
fi
if printf '%s' "$NODE_NAME" | grep -q '[^A-Za-z0-9._-]'; then
    c_warn "节点名含非 ASCII 字符，建议改用英文（如 aliyun-ecs），部分工具下中文目录会显示异常"
elif printf '%s' "$NODE_NAME" | grep -q '[A-Z]'; then
    c_warn "节点名含大写字母，建议用小写（如 aliyun-ecs）"
fi

# 统一成可用的 remote 地址
case "$AUTH_MODE" in
    ssh)
        # 无论用户给的是 SSH 还是 HTTPS 地址，都改写成走专属 Host 别名
        if [[ "$REPO_URL" =~ ^git@github\.com:(.+)$ ]]; then
            REPO_REMOTE="git@${SSH_HOST_ALIAS}:${BASH_REMATCH[1]}"
        elif [[ "$REPO_URL" =~ ^https?://github\.com/(.+)$ ]]; then
            REPO_REMOTE="git@${SSH_HOST_ALIAS}:${BASH_REMATCH[1]}"
        else
            REPO_REMOTE="$REPO_URL"
        fi
        ;;
    https)
        REPO_REMOTE="$REPO_URL"
        [[ "$REPO_REMOTE" == https://* ]] || die "HTTPS 方式的地址必须以 https:// 开头"
        ;;
    *) die "--auth 只支持 ssh 或 https" ;;
esac
c_ok "仓库：$REPO_REMOTE（分支 $BRANCH，认证 $AUTH_MODE）"
c_ok "节点名：$NODE_NAME  →  记录写入 daily/$NODE_NAME/"

# ---------------------------------------------------------------- 3 认证配置
# 必须放在克隆之前：SSH 方式依赖这里写入的 Host 别名，
# 否则 git clone 会直接报 Could not resolve hostname。
c_info "[3/7] 配置认证"
if [ "$AUTH_MODE" = "ssh" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    if [ ! -f "$SSH_KEY" ]; then
        c_info "生成专用密钥：$SSH_KEY"
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "git-log@$(hostname)" >/dev/null \
            || die "ssh-keygen 失败"
    else
        c_ok "密钥已存在，直接复用"
    fi
    chmod 600 "$SSH_KEY"; chmod 644 "$SSH_KEY.pub"

    # 用 Host 别名隔离，不污染已有的 GitHub 配置
    touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
    if ! grep -q "^Host $SSH_HOST_ALIAS$" "$HOME/.ssh/config"; then
        cat >>"$HOME/.ssh/config" <<EOF

Host $SSH_HOST_ALIAS
    HostName github.com
    User git
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
EOF
    fi
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com >>"$HOME/.ssh/known_hosts" 2>/dev/null || true

    echo
    echo "  ============ 请把下面这一整行公钥加到 GitHub ============"
    echo "  仓库 → Settings → Deploy keys → Add deploy key"
    echo "  标题随意，Key 粘贴下面内容，务必勾选 [Allow write access]"
    echo
    cat "$SSH_KEY.pub"
    echo "  =========================================================="
    echo
    # 非交互执行（远程批量部署）时不阻塞等待
    if [ -t 0 ]; then
        read -r -p "  添加完成后按回车继续..." _ || true
    else
        c_warn "非交互模式，跳过等待"
    fi

    c_info "测试 SSH 连接..."
    # 注意：GitHub 认证成功时 ssh -T 也会返回退出码 1（不提供 shell 访问），
    # 所以不能靠退出码判断，必须看输出里的关键字。
    ssh_out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T "git@$SSH_HOST_ALIAS" 2>&1 || true)"
    if printf '%s' "$ssh_out" | grep -q "successfully authenticated"; then
        c_ok "SSH 认证成功：$(printf '%s' "$ssh_out" | head -1)"
    else
        c_warn "认证未通过，输出如下："
        printf '%s\n' "$ssh_out" | sed 's/^/    /'
        c_warn "请确认 Deploy key 已添加且勾选了 Allow write access，之后可重跑本脚本"
    fi
else
    if [ -z "$TOKEN" ]; then
        echo "  需要一个有 repo 写权限的 Personal Access Token"
        echo "  GitHub → Settings → Developer settings → Personal access tokens"
        read -r -s -p "  粘贴 Token（输入时不回显）: " TOKEN || true
        echo
    fi
    [ -n "$TOKEN" ] || die "Token 不能为空"

    # 存到 root 专属凭据文件，权限 600，不写进 remote URL（避免泄漏到 .git/config）
    cred_host="$(echo "$REPO_REMOTE" | awk -F/ '{print $3}')"
    cred_user="$(echo "$REPO_REMOTE" | awk -F/ '{print $4}')"
    printf 'https://%s:%s@%s\n' "$cred_user" "$TOKEN" "$cred_host" >"$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
    git config --global credential.helper store
    c_ok "凭据已写入 $HOME/.git-credentials"
fi

# ---------------------------------------------------------------- 4 准备目录
c_info "[4/7] 准备目录与仓库"
mkdir -p "$PREFIX" || die "无法创建 $PREFIX"

if [ -d "$REPO_DIR/.git" ]; then
    c_warn "目录已存在，复用现有仓库"
    git -C "$REPO_DIR" remote set-url origin "$REPO_REMOTE" || die "修改 remote 失败"
else
    [ -d "$REPO_DIR" ] && rm -rf "$REPO_DIR"
    git clone "$REPO_REMOTE" "$REPO_DIR" 2>/dev/null || {
        c_warn "clone 失败，改为初始化本地仓库（确认公钥已加好后可重跑本脚本）"
        mkdir -p "$REPO_DIR" && git -C "$REPO_DIR" init -q
        git -C "$REPO_DIR" remote add origin "$REPO_REMOTE"
        git -C "$REPO_DIR" checkout -q -b "$BRANCH" 2>/dev/null || true
    }
fi
git -C "$REPO_DIR" config --add safe.directory "$REPO_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 5 写配置
c_info "[5/7] 写入配置文件"
cat >"$CONF_FILE" <<EOF
# git-log 配置（由 install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')）
# NODE_NAME 决定记录写入 \$CONTENT_DIR/<节点名>/，多节点共用仓库时靠它区分
NODE_NAME="$NODE_NAME"
REPO_DIR="$REPO_DIR"
BRANCH="$BRANCH"
CONTENT_DIR="daily"
GIT_NAME="git-log-bot"
GIT_EMAIL="git-log-bot@users.noreply.github.com"
TZ_NAME="Asia/Shanghai"
LOG_FILE="$LOG_FILE"
LOCK_FILE="$LOCK_FILE"
EOF
chmod 644 "$CONF_FILE"
c_ok "已写入 $CONF_FILE"

# ---------------------------------------------------------------- 6 装脚本
c_info "[6/7] 安装主脚本"
# 用户可能直接把脚本放在安装目录里执行，这时源和目标指向同一个文件，
# install 会报 "... are the same file" 并失败，这里直接跳过复制。
src_real="$(readlink -f "$SCRIPT_SRC" 2>/dev/null || echo "$SCRIPT_SRC")"
dst_real="$(readlink -f "$SCRIPT_DST" 2>/dev/null || echo "$SCRIPT_DST")"
if [ "$src_real" = "$dst_real" ]; then
    chmod 755 "$SCRIPT_DST" 2>/dev/null || true
    c_ok "脚本已在安装目录中，跳过复制"
else
    install -m 755 "$SCRIPT_SRC" "$SCRIPT_DST" || die "复制脚本失败"
    c_ok "已安装 $SCRIPT_DST"
fi

# ---------------------------------------------------------------- 7 试运行
c_info "[7/7] 试运行"
echo
bash "$SCRIPT_DST"
rc=$?
echo
if [ $rc -eq 0 ]; then
    c_ok "试运行成功，去 GitHub 仓库看看有没有新提交"
else
    c_warn "试运行返回 $rc，查看日志：tail -n 30 $LOG_FILE"
fi

cat <<EOF

==============================================
 接下来：在 1Panel 里配置定时任务
==============================================
1. 打开 1Panel → 计划任务 → 创建计划任务
2. 任务类型：Shell 脚本
3. 任务名称建议：$INSTANCE
4. 执行周期：自定义  ->  0 9 * * *
5. 脚本内容：$SCRIPT_DST
    （用「服务器脚本文件」选项填这个绝对路径最省事；
      面板里提示找不到 git 的话，改勾「在容器中运行」选一个带 git 的容器，
      或者直接用系统 crontab，见 README 的备选方案）
6. 打开「保留份数」= 7，方便回看每次执行日志

同一台机器再部署一个副本时，换 --instance 和 --node 各跑一次即可：
    bash install.sh --repo 同一仓库 --instance 第二个名字 --node 第二个节点名

手动跑一次验证：
    bash $SCRIPT_DST

日志：
    tail -f $LOG_FILE
EOF
