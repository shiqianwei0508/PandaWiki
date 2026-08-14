#!/usr/bin/env bash
# 一键构建并推送 PandaWiki 自有镜像（排除 postgres/redis/minio/nats/qdrant/raglite/caddy 等第三方镜像）。
# 前端(admin/app)在容器内完成 pnpm install + build，无需宿主机预编译。
#
# 用法:
#   ./build.sh                 # 构建并推送全部，tag 默认为当前最新 commit 前 8 位短哈希
#   ./build.sh v1.2.3          # 构建并推送全部，指定 tag
#   ./build.sh app             # 只构建 app（其余镜像跳过），tag 默认短哈希
#   ./build.sh app admin       # 只构建 app + admin
#   ./build.sh app v1.2.3      # 只构建 app，指定 tag
#   TAG=v1.2.3 PUSH=0 ./build.sh app   # 只构建 app，不推送
#
# 位置参数规则:
#   - 命中已知镜像名（api/consumer/app/admin）的参数 => 仅构建这些镜像（不传则全部）
#   - 其余位置参数 => 当作 tag（取最后一个非镜像名参数；也可通过 TAG= 环境变量指定，优先级更高）
#
# 全部依赖（含 @ctzhian/*）均为公共包，Dockerfile 内已统一走国内镜像 registry.npmmirror.com，无需私有源凭证。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

REPO="harbor.gbim.vip/freedo"
DEFAULT_TAG="$(git -C "${ROOT}" rev-parse --short=8 HEAD)"

# 已知镜像名（短名 -> 镜像后缀），用于筛选参数识别
declare -A KNOWN_IMAGES=(
  [api]="pandawiki-api"
  [consumer]="pandawiki-consumer"
  [app]="pandawiki-app"
  [admin]="pandawiki-admin"
)

# 解析位置参数：分离「筛选镜像」与「tag」
SELECTED=()
CLI_TAG=""
for arg in "$@"; do
  if [ -n "${KNOWN_IMAGES[$arg]+x}" ]; then
    SELECTED+=("$arg")
  else
    CLI_TAG="$arg"
  fi
done
# TAG 环境变量优先；其次 CLI 位置参数；最后默认短哈希
TAG="${TAG:-${CLI_TAG:-${DEFAULT_TAG}}}"
PUSH="${PUSH:-1}"

# 自有镜像: <dockerfile目录相对web根> <镜像后缀>
# 镜像名与 docker-compose.image.yml 保持一致: pandawiki-api / pandawiki-consumer / pandawiki-app / pandawiki-admin
# 注意: web 前端为 pnpm workspace，必须在 web/ 根联合 install，故 context 统一为 web/，dockerfile 用绝对路径。
BUILD_TARGETS=(
  "backend:Dockerfile.api:pandawiki-api:api"
  "backend:Dockerfile.consumer:pandawiki-consumer:consumer"
  "web:app/Dockerfile:pandawiki-app:app"
  "web:admin/Dockerfile:pandawiki-admin:admin"
)

echo "==> Target images: ${SELECTED[*]:-ALL} | tag=${TAG} | push=${PUSH}"

for entry in "${BUILD_TARGETS[@]}"; do
  IFS=':' read -r ctx dockerfile image short <<< "$entry"
  # 若指定了筛选，且当前镜像不在筛选列表中则跳过
  if [ "${#SELECTED[@]}" -gt 0 ]; then
    skip=1
    for s in "${SELECTED[@]}"; do
      if [ "$s" = "$short" ]; then skip=0; break; fi
    done
    [ "$skip" = "1" ] && continue
  fi
  full_image="${REPO}/${image}:${TAG}"
  dockerfile_path="${ROOT}/${ctx}/${dockerfile}"
  context_path="${ROOT}/${ctx}"
  echo "==> Building ${full_image} (context=${context_path}, dockerfile=${dockerfile_path})"
  docker build \
    -f "${dockerfile_path}" \
    -t "${full_image}" \
    "${context_path}"
  if [ "${PUSH}" = "1" ]; then
    echo "==> Pushing ${full_image}"
    docker push "${full_image}"
  fi
done

echo "Done. Built images under ${REPO} with tag ${TAG}."
