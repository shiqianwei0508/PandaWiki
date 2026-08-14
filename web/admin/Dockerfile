# syntax=docker/dockerfile:1.7
# 多阶段构建：在容器内完成 pnpm install + build，无需宿主机预编译。
# 基础镜像走内网 harbor，依赖安装走国内镜像（registry.npmmirror.com，@ctzhian/* 等均为公共包，无需私有源）。
FROM harbor.gbim.vip/dockerio/node:22-alpine AS builder
WORKDIR /src

# 国内 npm/pnpm 镜像源（@ctzhian/* 等均为公共包，npmmirror 可同步，无需私有源凭证）
ENV PNPM_HOME=/pnpm
ENV npm_config_registry=https://registry.npmmirror.com
ENV PNPM_CONFIG_REGISTRY=https://registry.npmmirror.com

RUN corepack enable && corepack prepare pnpm@10.12.1 --activate

# 仅复制需要的 workspace 文件与源码（利用层缓存）
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json* tsconfig.base.json ./
COPY packages ./packages
COPY admin ./admin
COPY app ./app

# 安装依赖。显式 --no-frozen-lockfile：让 workspace overrides（tiptap 3.27.1）写入并生效，
# 避免解析到 3.10.1 导致 normalizeNestedOptions 缺失（pnpm 10 默认 install 为 frozen 模式）。
RUN pnpm install --no-frozen-lockfile --registry=https://registry.npmmirror.com

# 构建 admin（Vite 输出纯静态文件到 admin/dist）
RUN NODE_OPTIONS=--max-old-space-size=4096 pnpm --filter panda-wiki-admin build

# 运行阶段：内置极简静态服务器（node，无 nginx），监听 2443 提供 dist 静态文件。
# 外部纯反向代理（Nginx B）将 2443 转给本容器即可独立访问。
FROM harbor.gbim.vip/dockerio/node:22-alpine AS runner
WORKDIR /opt/frontend
ENV PORT=2443
COPY --from=builder /src/admin/dist /opt/frontend/dist
# 构建上下文为 web/ 根，server.cjs 位于 web/admin 下
COPY admin/server.cjs /opt/frontend/server.cjs
EXPOSE 2443
CMD ["node", "server.cjs"]
