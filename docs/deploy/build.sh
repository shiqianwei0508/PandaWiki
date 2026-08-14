#!/usr/bin/env bash
# 一键构建并推送 PandaWiki 自有镜像（排除 postgres/redis/minio/nats/qdrant/raglite/caddy 等第三方镜像）。
# 前端(admin/app)在容器内完成 pnpm install + build，无需宿主机预编译。
#
# 用法:
#   ./build.sh                 # 构建并推送，tag 默认为 latest
#   ./build.sh v1.2.3          # 指定 tag
#   TAG=v1.2.3 PUSH=0 ./build.sh   # 仅本地构建不推送
#
# 全部依赖（含 @ctzhian/*）均为公共包，Dockerfile 内已统一走国内镜像 registry.npmmirror.com，无需私有源凭证。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

REPO="harbor.gbim.vip/freedo"
# 默认 tag 为当前最新 commit 前 8 位（短哈希），可传参或环境变量覆盖
DEFAULT_TAG="$(git -C "${ROOT}" rev-parse --short=8 HEAD)"
TAG="${1:-${TAG:-${DEFAULT_TAG}}}"
PUSH="${PUSH:-1}"

# 自有镜像: <dockerfile目录相对web根> <镜像后缀>
# 镜像名与 docker-compose.image.yml 保持一致: pandawiki-api / pandawiki-consumer / pandawiki-app / pandawiki-admin
# 注意: web 前端为 pnpm workspace，必须在 web/ 根联合 install，故 context 统一为 web/，dockerfile 用绝对路径。
BUILD_TARGETS=(
  "backend:Dockerfile.api:pandawiki-api"
  "backend:Dockerfile.consumer:pandawiki-consumer"
  "web:app/Dockerfile:pandawiki-app"
  "web:admin/Dockerfile:pandawiki-admin"
)

for entry in "${BUILD_TARGETS[@]}"; do
  IFS=':' read -r ctx dockerfile image <<< "$entry"
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
