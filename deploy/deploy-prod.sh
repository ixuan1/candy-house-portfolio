#!/usr/bin/env bash
# ============================================================
#  糖果屋 · 【生产环境】一键部署脚本（在京东云服务器上跑）
#
#  ⚠️ 这是生产脚本，比测试脚本多了三道保险：
#    1. 部署前【自动备份数据库】
#    2. 部署前【强制二次确认】（必须手输 y）
#    3. 健康检查失败【自动回滚】到部署前的版本
#
#  用法：
#    ./deploy/deploy-prod.sh                 # 拉 main 分支
#    ./deploy/deploy-prod.sh v1.0.0          # 拉指定 tag（推荐，版本可追溯）
#    FORCE=1 ./deploy/deploy-prod.sh         # 跳过确认（仅供自动化调用，手敲时别用）
#
#  ============================================================
#  🚨 红线（脚本已规避，但你心里要有数）：
#     - 本脚本【绝不会】执行 docker compose down -v（那会删掉数据卷 = 删库）
#     - .env 是 gitignore 的，git 操作不会覆盖生产密码
#     - 生产不直接改代码，一切走 git
#  ============================================================
# ============================================================

set -euo pipefail
# set -e        = errexit：任一命令失败就立即退出，防止错误继续扩散
# set -u        = nounset：引用未定义变量时报错（防变量名拼错导致误操作）
# set -o pipefail = 管道任一环节失败，整条管道算失败

# ============================ 可调参数 ============================

PROJECT_DIR="/opt/candy-house-portfolio"
# 生产路径，与测试环境保持一致（消除配置漂移）

REF="${1:-main}"
# REF = 要部署的"引用"，可以是分支名（main）或标签（v1.0.0）
# ${1:-main} = 没传参数就默认 main

COMPOSE_CMD="docker compose -f docker/docker-compose.yml"

HEALTH_URLS=(
    "http://127.0.0.1:8000/api/health"
    "http://127.0.0.1:8001/api/health"
)

BACKUP_DIR="$PROJECT_DIR/backups"
# 备份文件存放目录

MAX_RETRY=30
RETRY_INTERVAL=2
# 健康检查：最多等 30 × 2 = 60 秒

# ============================ 工具函数 ============================

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

check_health() {
    local url
    for url in "${HEALTH_URLS[@]}"; do
        if ! curl -fsS "$url" 2>/dev/null | grep -q '"db":true'; then
            return 1
        fi
    done
    return 0
}

backup_database() {
    # 部署前备份数据库。这是生产的生命线：代码能回滚，数据不能重来
    log "📦 备份数据库 ..."

    mkdir -p "$BACKUP_DIR"
    # -p = parents，目录不存在就创建，已存在也不报错

    local backup_file="$BACKUP_DIR/candy_house_$(date +%F_%H%M%S).sql"
    # $(date +%F_%H%M%S) = 插入当前时间，格式 2026-08-29_014233
    #   %F = 完整日期 YYYY-MM-DD；%H = 时；%M = 分；%S = 秒
    #   精确到秒，保证同一天多次部署备份不互相覆盖

    local mysql_root_password
    mysql_root_password=$(grep '^MYSQL_ROOT_PASSWORD=' api/.env | cut -d= -f2-)
    # grep '^MYSQL_ROOT_PASSWORD=' = 从 .env 里找出以这个开头的那一行
    # | cut -d= -f2- = 用 = 作为分隔符（-d=），取第 2 个字段【到行尾】（-f2-）
    #   注意是 -f2- 而不是 -f2：万一密码里含 = 号，-f2 会截断，-f2- 不会
    # 这样读取密码，避免手敲密码进命令历史（history 会泄露）

    $COMPOSE_CMD exec -T db \
        mysqldump -uroot -p"$mysql_root_password" candy_house > "$backup_file"
    # exec -T    = 在容器里执行命令；-T = 不分配伪终端
    #               （配合 > 重定向时必须加，否则输出会混入终端控制字符）
    # mysqldump  = MySQL 官方导出工具
    # -uroot     = 用 root 用户连接
    # -p"..."    = 密码（-p 与密码之间【不能】有空格）
    # candy_house = 要导出的【数据库名】
    # >          = 重定向，把输出写进备份文件
    # \          = 续行符，表示下一行还是同一条命令（纯换行方便阅读）

    log "✅ 已备份：$backup_file"
}

rollback() {
    log "⏪ 回滚到 $1 ..."
    git checkout "$1"
    $COMPOSE_CMD up -d --build --scale app=2
}

# ============================ 主流程 ============================

log "=== 生产环境部署（引用：$REF）==="

cd "$PROJECT_DIR"

# ---------- 前置检查 ----------
if [[ ! -f api/.env ]]; then
    log "❌ 找不到 api/.env，生产环境必须配好才能部署"
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    log "❌ 工作区有未提交的改动。生产环境不允许有本地改动："
    git status --short
    exit 1
fi

# ---------- 二次确认（防止手滑）----------
if [[ "${FORCE:-0}" != "1" ]]; then
    # ${FORCE:-0} = 取环境变量 FORCE；没设置就用 0
    # 想跳过确认就写 FORCE=1 ./deploy/deploy-prod.sh

    log "⚠️  即将部署到【生产环境】"
    log "    目标：$REF"

    read -r -p "    确认请输入 y（直接回车=取消）：" answer
    # read    = 读取用户输入
    # -r      = raw，不把反斜杠当转义符处理（原样保存输入）
    # -p      = prompt，后面跟提示文字（在同一个提示行显示，不用另起一行 echo）

    if [[ "$answer" != "y" ]]; then
        log "已取消，未做任何改动"
        exit 0
    fi
fi

# ---------- 记录回滚点 ----------
PREV_COMMIT=$(git rev-parse HEAD)
# git rev-parse HEAD = 当前所在提交的完整 hash
# 必须在拉取新代码【之前】记录，这才是"上一个能跑的版本"

log "回滚点已记录：$PREV_COMMIT"

# ---------- 拉取代码 ----------
git fetch origin --tags
# fetch   = 下载远程最新内容但不合并
# --tags  = 同时下载所有标签（标签默认不会跟着分支一起 fetch，必须显式加）

if git rev-parse -q --verify "refs/tags/$REF" >/dev/null; then
    # git rev-parse --verify = 验证某个引用是否存在
    # -q              = quiet，不输出（--verify 配合 -q，失败时不报错只返回非 0）
    # refs/tags/$REF  = 标签的引用路径
    # >/dev/null      = 输出丢进黑洞，只看返回值

    log "检测到 $REF 是【标签】，直接切换（标签是不可变的，不需要 pull）"
    git checkout "$REF"

elif git rev-parse -q --verify "refs/heads/$REF" >/dev/null; then
    # refs/heads/$REF = 本地分支的引用路径
    log "切换到分支 $REF"
    git checkout "$REF"
    git pull --ff-only origin "$REF"
    # --ff-only = 只快进合并，拒绝产生意外的合并提交，保持历史干净
else
    git checkout -b "$REF" "origin/$REF"
    # -b = 新建分支并以远程同名分支为起点（第一次部署某个分支时）
fi

# ---------- 备份数据库（在重启容器之前）----------
backup_database

# ---------- 构建并启动 ----------
log "重新构建镜像并启动容器 ..."
$COMPOSE_CMD up -d --build --scale app=2
# --build = 重新构建镜像（改了代码必加）
# 注意：这里【没有】 -v，数据卷完好无损

# ---------- 健康检查 ----------
log "健康检查（最多等 $((MAX_RETRY * RETRY_INTERVAL)) 秒）..."
for i in $(seq 1 "$MAX_RETRY"); do
    if check_health; then
        log "✅ 生产部署成功（第 $i 次检查通过）"
        log "   建议再验证：curl -I http://localhost  和浏览器访问首页"
        exit 0
    fi
    sleep "$RETRY_INTERVAL"
done

# ---------- 失败处理 ----------
log "❌ 健康检查失败"

log "--- 最近的 app 日志（回滚前先留证）---"
$COMPOSE_CMD logs --tail=50 app
# 先打印日志再回滚：一旦回滚，新版本的容器就没了，日志也跟着消失

rollback "$PREV_COMMIT"

log "已回滚到 $PREV_COMMIT（代码已回退）"
log "⚠️ 注意：数据库【没有】跟着回滚。如果本次改动涉及表结构，"
log "   请手动处理。备份文件在：$BACKUP_DIR"
exit 1
