#!/usr/bin/env bash
# ============================================================
#  糖果屋 · 【测试环境】一键部署脚本（在 VM ubuntu-dev 上跑）
#
#  用法（任意目录都可以，脚本会自己 cd 到项目目录）：
#    ./deploy/deploy-dev.sh                  # 拉默认分支 develop
#    ./deploy/deploy-dev.sh feature/xxx      # 拉指定分支（测新功能时这么用）
#
#  它依次做 5 件事：
#    1. 前置检查：.env 在不在、工作区干不干净、分支存不存在
#    2. 拉取代码（只允许 fast-forward，不会产生意外的合并提交）
#    3. 重新构建镜像并重启容器
#    4. 健康检查：轮询所有 app 实例，最多等 60 秒
#    5. 失败自动回滚到上一个提交
# ============================================================

set -euo pipefail
# set -e        = errexit：任何命令返回非 0（失败）就立刻退出脚本
#                 避免"第一步错了还继续跑下去"造成连锁破坏
# set -u        = nounset：引用未定义的变量时报错退出
#                 防变量名拼错（比如把 PROJECT_DIR 写成 PROJECT_DOR 导致 cd 到错误目录）
# set -o pipefail = 管道里【任一】命令失败，整条管道就算失败
#                 默认 bash 只看管道最后一条的返回值，会漏掉前面的错误

# ============================ 可调参数 ============================

PROJECT_DIR="/opt/candy-house-portfolio"
# 项目绝对路径。测试环境和生产保持一致，好处是 nginx 配置两份环境通用

BRANCH="${1:-develop}"
# ${1:-develop} = 取第 1 个命令行参数；没传参数（$1 为空）就用默认值 develop
# $0 = 脚本名，$1 = 第 1 个参数，$2 = 第 2 个参数，以此类推

COMPOSE_CMD="docker compose -f docker/docker-compose.yml"
# 把这条又长又常用的命令存进变量，后面复用，少打字也少出错
# -f = file，指定 compose 文件位置

HEALTH_URLS=(
    "http://127.0.0.1:8000/api/health"
    "http://127.0.0.1:8001/api/health"
)
# Bash 数组，两个 app 实例各自映射的端口
# 8000 = app 实例 1，8001 = app 实例 2（由 --scale app=2 扩出来的）

MAX_RETRY=30
# 健康检查最多重试次数

RETRY_INTERVAL=2
# 每次重试间隔秒数。30 × 2 = 最多等 60 秒

# ============================ 工具函数 ============================

log() {
    echo "[$(date '+%H:%M:%S')] $*"
    # date '+%H:%M:%S' = 按 时:分:秒 格式输出当前时间
    # $* = 传给这个函数的【所有】参数，拼成一个字符串
    # 作用：每条日志前面带时间戳，方便事后看"卡在哪一步、花了多久"
}

check_health() {
    # 检查所有 app 实例是否都健康。全部通过返回 0，任一不通返回 1
    local url
    # local = 声明局部变量，只在函数内有效，不污染全局

    for url in "${HEALTH_URLS[@]}"; do
        # "${HEALTH_URLS[@]}" = 展开数组的所有元素（加引号保证含空格的元素不被拆开）

        if ! curl -fsS "$url" 2>/dev/null | grep -q '"db":true'; then
            # curl -f = fail，HTTP 错误码时不输出内容并返回非 0
            # curl -s = silent，静默，不显示进度条
            # curl -S = show-error，配合 -s：出错时才显示错误
            # 2>/dev/null = 把标准错误输出丢掉（2 是 stderr 的文件描述符，/dev/null 是黑洞设备）
            # | grep -q = 在响应里找 "db":true
            #   -q = quiet，找到就返回 0，不打印任何内容（只关心"有没有"，不关心"是什么"）
            # ! = 取反：curl 或 grep 失败 → 整个条件成立 → 返回 1
            return 1
        fi
    done
    return 0
}

rollback() {
    # 回滚到部署前的那个提交，并重建
    log "⏪ 正在回滚到 $1 ..."
    # $1 = 传给 rollback 函数的第 1 个参数（这里是一个 git 提交 hash）

    git checkout "$1"
    # checkout + 提交 hash = 让工作区回到那次提交的状态

    $COMPOSE_CMD up -d --build --scale app=2
    # 用旧代码重新构建并启动
    # --build 必须加，否则容器跑的还是新代码构建的镜像
}

# ============================ 主流程 ============================

log "=== 测试环境部署开始（分支：$BRANCH）==="

cd "$PROJECT_DIR"
# cd = change directory，切到项目根目录
# compose 文件里 ../api/.env 是相对路径，进错目录会报 env file not found

# ---------- 前置检查 1：.env 必须存在 ----------
if [[ ! -f api/.env ]]; then
    # [[ ]] = bash 的增强测试语法（比 [ ] 更安全，支持 && || 和正则）
    # ! = 取反，-f = file，判断文件是否存在且是普通文件
    log "❌ 找不到 api/.env。先执行：cp api/.env.example api/.env 并改密码"
    exit 1
    # exit 1 = 以状态码 1 退出，表示失败（0 表示成功）
    # CI/脚本里靠这个值判断成功失败
fi

# ---------- 前置检查 2：工作区必须干净 ----------
if [[ -n "$(git status --porcelain)" ]]; then
    # git status --porcelain = 以紧凑格式输出改动（每个文件一行，便于脚本解析）
    #                          没改动时输出为空字符串
    # -n = 判断字符串【非空】。非空说明有未提交的改动
    log "❌ 工作区有未提交的改动，先 commit 或 stash 再部署："
    git status --short
    # --short = 简略格式显示哪些文件被改了
    exit 1
fi

# ---------- 记录回滚点 ----------
PREV_COMMIT=$(git rev-parse HEAD)
# $(...)  = 命令替换，把命令的执行结果赋值给变量
# git rev-parse HEAD = 输出当前所在提交的完整 hash（HEAD 就是"当前位置"）
# 这个 hash 是回滚的锚点，必须【在拉取新代码之前】记录

log "回滚点已记录：$PREV_COMMIT"

# ---------- 拉取代码 ----------
log "拉取代码 ..."
git fetch origin
# fetch = 把远程仓库的最新内容下载到本地，但【不自动合并】
#         比 pull 安全，因为你可以先看再决定要不要合并
# origin = 远程仓库的默认别名

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    # git show-ref --verify = 检查某个引用是否存在
    # --quiet = 不输出内容，只用返回值表示结果（0=存在，非0=不存在）
    # refs/heads/$BRANCH = 本地分支的引用路径
    git checkout "$BRANCH"
    # 本地已有这个分支 → 直接切过去
else
    git checkout -b "$BRANCH" "origin/$BRANCH"
    # -b = branch，新建分支；origin/$BRANCH = 以远程同名分支为起点
    # 场景：第一次部署某个 feature 分支时，本地还没有它
fi

git pull --ff-only origin "$BRANCH"
# pull       = fetch + merge，拉取并合并
# --ff-only  = fast-forward only，【只允许快进合并】
#              如果本地和远程有分叉（比如本地多提交了），就拒绝合并并报错
#              好处：绝不会悄悄产生一个"合并提交"，历史保持干净、可追溯

# ---------- 构建并启动 ----------
log "重新构建镜像并启动容器 ..."
$COMPOSE_CMD up -d --build --scale app=2
# up            = 创建并启动容器
# -d            = detached，后台运行
# --build       = 先重新构建镜像（改了 .py 代码必须加，否则跑的还是旧镜像）
# --scale app=2 = 把 app 扩到 2 个实例

# ---------- 健康检查 ----------
log "健康检查（最多等 $((MAX_RETRY * RETRY_INTERVAL)) 秒）..."
# $(( )) = 算术运算，这里算出 30 × 2 = 60

for i in $(seq 1 "$MAX_RETRY"); do
    # seq 1 30 = 生成 1 到 30 的数字序列，用来控制循环次数

    if check_health; then
        log "✅ 部署成功（第 $i 次检查通过）"
        log "   记得再验证一次 Nginx 层：curl -I http://localhost"
        exit 0
        # exit 0 = 成功退出
    fi

    sleep "$RETRY_INTERVAL"
    # sleep = 暂停执行指定秒数，给应用留出启动时间
done

# ---------- 走到这里说明超时了 ----------
log "❌ 健康检查失败，部署有问题"

log "--- 最近的 app 日志（找原因）---"
$COMPOSE_CMD logs --tail=50 app
# --tail=50 = 只显示最后 50 行日志（不实时跟随）
# 这一步很关键：回滚前先把证据打出来，否则回滚后日志就没了

rollback "$PREV_COMMIT"
log "已回滚。请根据上面的日志排查后再重试。"
exit 1
