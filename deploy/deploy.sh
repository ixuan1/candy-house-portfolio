#!/usr/bin/env bash
# ============================================================
#  糖果屋 全栈部署脚本（在本机执行，非服务器）
#  作用：把项目传到京东云，并一键用 Docker Compose 起起来（含 app×2 负载均衡）
#  前置：本机有 ssh/scp；服务器已按 deploy/README.md 装好 Docker
# ============================================================
set -euo pipefail

# ===================== 按需修改 =====================
SERVER_USER="candyapp"          # ⚠️ 非 root 部署：用单独的应用用户（需先建好并加入 docker 组）
SERVER_IP="你的服务器公网IP"
REMOTE_DIR="/opt/candy-house-portfolio"
# ⚠️ 前置：服务器上需先一次性建好目录并改属主（见 deploy/DEPLOY-CANDYAPP.md 第 1 步）：
#       sudo mkdir -p /opt/candy-house-portfolio
#       sudo chown -R candyapp:candyapp /opt/candy-house-portfolio
#       否则 candyapp 无法在 /opt 下创建/写入目录。
# ===================================================
LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo ">> [1/2] 上传项目到 ${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}"
ssh "${SERVER_USER}@${SERVER_IP}" "mkdir -p ${REMOTE_DIR}"
# mkdir -p = 目录已存在时静默跳过（前提是它已被 chown 给 candyapp，否则这步会失败）
scp -r "${LOCAL_DIR}/api" "${LOCAL_DIR}/db" "${LOCAL_DIR}/nginx" "${LOCAL_DIR}/static" "${LOCAL_DIR}/docker" \
      "${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}/"
# 仅在服务器还没有 .env 时，用示例占位初始化；绝不覆盖已有配置，避免误清生产密码
ssh "${SERVER_USER}@${SERVER_IP}" "cd ${REMOTE_DIR}/api && [ -f .env ] || cp .env.example .env"

echo ">> [2/2] 服务器上启动（app×2 负载均衡）"
ssh "${SERVER_USER}@${SERVER_IP}" "cd ${REMOTE_DIR} && docker compose -f docker/docker-compose.yml up -d --scale app=2"

echo ">> 完成 🎉  浏览器访问 http://${SERVER_IP}/"
