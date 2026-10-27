# git-log

[![Shell](https://img.shields.io/badge/shell-bash-4EAA25)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-linux-blue)](https://www.kernel.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
<p align="center">
    <a href="https://linux.do" alt="LINUX DO"><img src="https://shorturl.at/ggSqS" /></a>
</p>



**Automated daily status commits from your Linux machines to a Git repository.**

Every scheduled run appends a one-line snapshot of the machine — uptime, load average, memory, disk usage, CPU temperature — to `daily/<node>/YYYY-MM-DD.md`, then commits and pushes it. Multiple machines can share a single repository, each writing to its own folder.

**让服务器每天自动向 Git 仓库提交一条真实的运行状态记录。**

每次运行采集当前机器的开机时长、负载、内存、磁盘占用和 CPU 温度，追加到 `daily/<节点名>/YYYY-MM-DD.md` 后自动提交推送。多台设备可以共用一个仓库，各写各的文件夹，互不干扰。

**[English](#english) | [简体中文](#简体中文)**

---

## English

### Why

A record of how your machines actually behaved, not empty commits to keep a contribution graph green. One line a day, readable as a plain Markdown table, diffable in Git.

Useful for:

- Tracking a Raspberry Pi's thermals and load over months
- Keeping a low-cost trail of disk usage creeping up
- A repository that stays active without meaningless noise
- Anything else: the script uses `git add -A`, so whatever you drop into the repo gets archived on the next run

### Features

- **No dependencies** beyond `git` and coreutils
- **One folder per node** — many machines, one repo, no file conflicts
- **Conflict-safe** — rejected pushes are rebased and retried, up to 3 rounds
- **Scheduler agnostic** — cron, systemd timer, or 1Panel scheduled task
- **Two auth modes** — SSH deploy key (recommended) or HTTPS token
- **Forgiving in odd environments** — handles missing tzdata, non-English locales, absent global git identity, and concurrent runs
- **Dry run mode** for debugging without writing anything

### Requirements

| Item | Notes |
| --- | --- |
| Linux | Tested on Raspberry Pi OS / Debian 13, `x86_64` and `aarch64` |
| bash | 4.0+ |
| git | 2.x |
| Remote | Any Git host you can push to (GitHub, GitLab, Gitea, ...) |

### Quick start

```bash
git clone https://github.com/TICKurt/git-log.git
cd git-log
sudo bash install.sh
```

The wizard asks for:

1. **Repository URL** — HTTPS or SSH form both accepted
2. **Auth method** — SSH deploy key (recommended) or HTTPS token
3. **Branch** — defaults to `main`
4. **Node name** — the folder under `daily/`; pressing Enter uses the hostname

Then it clones the repo to `/opt/git-log/repo`, configures auth, writes `/etc/git-log.conf`, installs `/opt/git-log/git-log.sh`, and runs once to verify end to end.

Non-interactive:

```bash
sudo bash install.sh \
  --repo https://github.com/yourname/daily-log.git \
  --auth ssh \
  --node pi-office
```

**SSH mode:** the script prints a public key. Add it at *Repository → Settings → Deploy keys → Add deploy key*, and **tick "Allow write access"** — without it pushes fail with `Permission denied (publickey)`.

### What gets committed

```
daily/
├── pi-office/
│   ├── README.md
│   └── 2026-10-27.md
└── aliyun-ecs/
    ├── README.md
    └── 2026-10-27.md
```

`2026-10-27.md`, one row per run:

```markdown
# 2026-10-27

| Time | Host | Uptime | Load (1/5/15) | Memory | Disk | CPU Temp |
| --- | --- | --- | --- | --- | --- | --- |
| 09:30:02 | raspberrypi | 3 days, 4 hours | 0.08 0.12 0.09 | 412/3906MB | 43% | 48.3°C |
```

The `README.md` inside each node folder is generated on first run and records the node name, hostname, hardware model, OS version and first seen date, so a multi-node repo explains itself.

### Multiple machines, one repository

Each machine installs once with its own node name:

```bash
# machine A
sudo bash install.sh --repo <same-repo> --auth ssh --node pi-office

# machine B
sudo bash install.sh --repo <same-repo> --auth ssh --node pi-home
```

They write to `daily/pi-office/` and `daily/pi-home/` respectively. If two nodes push at the same moment, the later one is rejected once, then rebases and retries automatically.

Name guidelines: lowercase ASCII, digits and hyphens (`pi-office`, `aliyun-ecs`). Cloud instance hostnames are often long IDs — set a short name explicitly. Non-ASCII names work but may render poorly in some tooling.

### Multiple instances on one machine

Use `--instance` to isolate install dir, config, log and lock:

```bash
sudo bash install.sh --repo <same-repo> --auth ssh --instance job-a --node job-a
```

| | default | `--instance job-a` |
| --- | --- | --- |
| Install dir | `/opt/git-log` | `/opt/git-log-job-a` |
| Config | `/etc/git-log.conf` | `/etc/git-log-job-a.conf` |
| Log | `/var/log/git-log.log` | `/var/log/git-log-job-a.log` |
| Lock | `/tmp/git-log.lock` | `/tmp/git-log-job-a.lock` |

### Scheduling

**cron**

```cron
0 9 * * * /bin/bash /opt/git-log/git-log.sh >> /var/log/git-log-cron.log 2>&1
```

**systemd timer**

`/etc/systemd/system/git-log.service`

```ini
[Unit]
Description=git-log daily status commit

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/git-log/git-log.sh
```

`/etc/systemd/system/git-log.timer`

```ini
[Unit]
Description=Run git-log daily at 09:00

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now git-log.timer
```

**1Panel**

Cron Jobs → Create task → type *Shell Script* → schedule `0 9 * * *` → script file `/opt/git-log/git-log.sh`.

> Pick exactly one scheduler. The script uses `flock`, so a second concurrent run exits instead of duplicating writes.

### Configuration

`/etc/git-log.conf`:

| Key | Default | Description |
| --- | --- | --- |
| `NODE_NAME` | hostname | Folder name under `daily/` |
| `REPO_DIR` | `/opt/git-log/repo` | Local clone |
| `BRANCH` | `main` | Target branch |
| `CONTENT_DIR` | `daily` | Top-level folder for records |
| `GIT_NAME` | `git-log-bot` | Committer name |
| `GIT_EMAIL` | `git-log-bot@users.noreply.github.com` | Committer email |
| `TZ_NAME` | `Asia/Shanghai` | Timezone for timestamps |
| `LOG_FILE` | `/var/log/git-log.log` | Run log |
| `LOCK_FILE` | `/tmp/git-log.lock` | `flock` file |

Preview without writing or committing:

```bash
DRY_RUN=1 bash /opt/git-log/git-log.sh
```

Check the log:

```bash
tail -f /var/log/git-log.log
```

### Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Permission denied (publickey)` | Deploy key not added, or "Allow write access" not ticked |
| `Authentication failed` (HTTPS) | Token expired or missing `repo` scope; delete `/root/.git-credentials` and reinstall |
| `detected dubious ownership` | Scheduler runs as root while the clone belongs to another user; the script passes `-c safe.directory` already, otherwise run `git config --global --add safe.directory /opt/git-log/repo` |
| Memory column shows `-` | Non-English locale makes `free` print localized labels; the script forces `LC_ALL=C` |
| Commit timestamps off by hours | Missing tzdata — the script detects it, warns, and falls back to the system timezone |
| `Committer identity unknown` | `rebase` needs a persistent identity; the script sets a repo-local one on first run |
| Scheduled time ignores a timezone change | The scheduler caches it in-process — restart it (`systemctl restart 1panel-core` for 1Panel) |
| Task succeeds but repo unchanged | Check the log; usually auth or network. Full git output is captured there |

### Upgrading from `daily-commit`

This project was previously named `daily-commit`. To move an existing install:

```bash
sudo mv /opt/daily-commit /opt/git-log
sudo mv /etc/daily-commit.conf /etc/git-log.conf
sudo sed -i 's#/opt/daily-commit#/opt/git-log#g; s#/var/log/daily-commit#/var/log/git-log#g; s#/tmp/daily-commit#/tmp/git-log#g' /etc/git-log.conf
sudo rm -f /var/log/daily-commit.log /tmp/daily-commit.lock
```

Then point your scheduler at `/opt/git-log/git-log.sh`.

### Uninstall

```bash
sudo rm -rf /opt/git-log
sudo rm -f /etc/git-log.conf /var/log/git-log.log /tmp/git-log.lock
sudo rm -f /root/.ssh/git-log /root/.ssh/git-log.pub
```

Also revoke the deploy key on the repository and delete the scheduled task.

### License

[MIT](LICENSE)

---

## 简体中文

### 为什么做这个

它记录的是机器真实的运行轨迹，不是为刷贡献图而产生的空提交。每天一行，纯 Markdown 表格，能直接看趋势，也能用 `git diff` 对比。

适用场景：

- 长期观察树莓派的温度和负载变化
- 给磁盘占用留一份低成本的可追溯记录
- 让仓库保持活跃，又不产生无意义的噪音
- 任意用途：脚本用 `git add -A`，你随手丢进仓库的笔记、配置也会在下次运行时一起存档

### 特性

- **零依赖** —— 只需要 `git` 和 coreutils
- **按节点分目录** —— 多台设备共用一个仓库，文件互不覆盖
- **推送冲突自动处理** —— 被拒绝时自动 rebase 重试，最多 3 轮
- **调度器无关** —— cron、systemd timer、1Panel 计划任务都能用
- **两种认证方式** —— SSH Deploy Key（推荐）或 HTTPS Token
- **适应各种环境** —— 处理 tzdata 缺失、中文 locale、无全局 git 身份、并发运行
- **Dry run** —— 调试时只打印不写入

### 环境要求

| 项目 | 说明 |
| --- | --- |
| 系统 | Linux，已在 Raspberry Pi OS / Debian 13 的 `x86_64` 与 `aarch64` 上验证 |
| bash | 4.0+ |
| git | 2.x |
| 远端 | 任何可推送的 Git 服务（GitHub、GitLab、Gitea 等） |

### 快速开始

```bash
git clone https://github.com/TICKurt/git-log.git
cd git-log
sudo bash install.sh
```

向导会依次询问：

1. **仓库地址** —— HTTPS 或 SSH 形式都接受
2. **认证方式** —— SSH Deploy Key（推荐）或 HTTPS Token
3. **分支名** —— 默认 `main`
4. **节点名** —— 记录写进 `daily/<节点名>/`，直接回车则用主机名

随后自动完成：克隆仓库到 `/opt/git-log/repo`、配置认证、写入 `/etc/git-log.conf`、安装 `/opt/git-log/git-log.sh`、试运行一次验证全链路。

非交互方式：

```bash
sudo bash install.sh \
  --repo https://github.com/yourname/daily-log.git \
  --auth ssh \
  --node pi-office
```

**SSH 方式**会打印一段公钥，需要你加到 *仓库 → Settings → Deploy keys → Add deploy key*，并**务必勾选 "Allow write access"**，否则推送会报 `Permission denied (publickey)`。

### 提交的内容

```
daily/
├── pi-office/
│   ├── README.md
│   └── 2026-10-27.md
└── aliyun-ecs/
    ├── README.md
    └── 2026-10-27.md
```

`2026-10-27.md`，每次运行追加一行：

```markdown
# 2026-10-27

| 时间 | 主机 | 运行时长 | 负载(1/5/15) | 内存 | 根分区 | CPU 温度 |
| --- | --- | --- | --- | --- | --- | --- |
| 09:30:02 | raspberrypi | 3 days, 4 hours | 0.08 0.12 0.09 | 412/3906MB | 43% | 48.3°C |
```

每个节点目录下的 `README.md` 在首次运行时生成，记录节点名、主机名、硬件型号、系统版本和首次记录日期，多节点仓库一眼就能分清。

### 多台设备共用一个仓库

每台机器各自安装一次，指定不同的节点名：

```bash
# 机器 A
sudo bash install.sh --repo <同一个仓库> --auth ssh --node pi-office

# 机器 B
sudo bash install.sh --repo <同一个仓库> --auth ssh --node pi-home
```

两台分别写入 `daily/pi-office/` 和 `daily/pi-home/`。如果两台同时推送，后推的那台会被拒绝一次，脚本自动 rebase 后重试，不会丢记录。

命名建议：小写英文、数字和连字符（`pi-office`、`aliyun-ecs`）。云服务器主机名常是一长串实例 ID，建议显式指定短名。中文名也能用，但部分工具下显示会异常。

### 同一台机器跑多个实例

用 `--instance` 把安装目录、配置、日志和锁全部隔开：

```bash
sudo bash install.sh --repo <同一个仓库> --auth ssh --instance job-a --node job-a
```

| | 默认实例 | `--instance job-a` |
| --- | --- | --- |
| 安装目录 | `/opt/git-log` | `/opt/git-log-job-a` |
| 配置文件 | `/etc/git-log.conf` | `/etc/git-log-job-a.conf` |
| 日志 | `/var/log/git-log.log` | `/var/log/git-log-job-a.log` |
| 锁文件 | `/tmp/git-log.lock` | `/tmp/git-log-job-a.lock` |

### 定时调度

**cron**

```cron
0 9 * * * /bin/bash /opt/git-log/git-log.sh >> /var/log/git-log-cron.log 2>&1
```

**systemd timer**

`/etc/systemd/system/git-log.service`

```ini
[Unit]
Description=git-log daily status commit

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/git-log/git-log.sh
```

`/etc/systemd/system/git-log.timer`

```ini
[Unit]
Description=Run git-log daily at 09:00

[Timer]
OnCalendar=*-*-* 09:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now git-log.timer
```

**1Panel**

计划任务 → 创建计划任务 → 类型选 *Shell 脚本* → 周期填 `0 9 * * *` → 脚本文件填 `/opt/git-log/git-log.sh`。

> 只启用一种调度方式。脚本内部有 `flock`，同时触发时第二个会直接退出，不会重复写入。

### 配置项

`/etc/git-log.conf`：

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `NODE_NAME` | 主机名 | `daily/` 下的文件夹名 |
| `REPO_DIR` | `/opt/git-log/repo` | 本地克隆目录 |
| `BRANCH` | `main` | 目标分支 |
| `CONTENT_DIR` | `daily` | 记录存放的顶层目录 |
| `GIT_NAME` | `git-log-bot` | 提交者名称 |
| `GIT_EMAIL` | `git-log-bot@users.noreply.github.com` | 提交者邮箱 |
| `TZ_NAME` | `Asia/Shanghai` | 时间戳时区 |
| `LOG_FILE` | `/var/log/git-log.log` | 运行日志 |
| `LOCK_FILE` | `/tmp/git-log.lock` | `flock` 锁文件 |

只预览不写入、不提交：

```bash
DRY_RUN=1 bash /opt/git-log/git-log.sh
```

查看日志：

```bash
tail -f /var/log/git-log.log
```

### 排错

| 现象 | 原因与处理 |
| --- | --- |
| `Permission denied (publickey)` | Deploy Key 没添加，或没勾 "Allow write access" |
| `Authentication failed`（HTTPS） | Token 过期或缺 `repo` 权限；删掉 `/root/.git-credentials` 重装 |
| `detected dubious ownership` | 计划任务以 root 跑、仓库属主是别的用户。脚本已用 `-c safe.directory` 规避；仍有问题就 `git config --global --add safe.directory /opt/git-log/repo` |
| 内存列显示 `-` | 中文 locale 让 `free` 输出「内存：」，解析失败。脚本已强制 `LC_ALL=C` |
| 提交时间差几个小时 | 缺 tzdata，脚本会探测、告警并退回系统时区 |
| `Committer identity unknown` | `rebase` 需要持久化的提交者身份，脚本首次运行会自动补一份仓库级配置 |
| 改了系统时区但任务时间没变 | 调度器进程内缓存了时区，重启它（1Panel 是 `systemctl restart 1panel-core`） |
| 任务显示成功但仓库没变化 | 看日志，通常是认证或网络问题，完整的 git 输出都记录在里面 |

### 从 `daily-commit` 升级

本项目原名 `daily-commit`，已部署过的按下面迁移：

```bash
sudo mv /opt/daily-commit /opt/git-log
sudo mv /etc/daily-commit.conf /etc/git-log.conf
sudo sed -i 's#/opt/daily-commit#/opt/git-log#g; s#/var/log/daily-commit#/var/log/git-log#g; s#/tmp/daily-commit#/tmp/git-log#g' /etc/git-log.conf
sudo rm -f /var/log/daily-commit.log /tmp/daily-commit.lock
```

然后把计划任务里的脚本路径改为 `/opt/git-log/git-log.sh`。

### 卸载

```bash
sudo rm -rf /opt/git-log
sudo rm -f /etc/git-log.conf /var/log/git-log.log /tmp/git-log.lock
sudo rm -f /root/.ssh/git-log /root/.ssh/git-log.pub
```

还要到仓库里撤销那把 Deploy Key，并删除计划任务。

### 许可证

[MIT](LICENSE)

