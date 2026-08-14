# syntax=docker/dockerfile:1.7
# 多阶段构建：在容器内完成 pnpm install + build，无需宿主机预编译。
# 基础镜像走内网 harbor，依赖安装走国内镜像（registry.npmmirror.com，@ctzhian/* 等均为公共包，无需私有源）。
FROM harbor.gbim.vip/dockerio/node:22-alpine AS builder
WORKDIR /src

# 国内 npm/pnpm 镜像源（@ctzhian/* 等均为公共包，npmmirror 可同步，无需私有源凭证）
ENV PNPM_HOME=/pnpm
ENV npm_config_registry=https://registry.npmmirror.com
ENV PNPM_CONFIG_REGISTRY=https://registry.npmmirror.com
# 抑制 Sentry 在构建时上传 source map（避免容器内挂起/失败）
ENV CI=true

RUN corepack enable && corepack prepare pnpm@10.12.1 --activate

# 仅复制需要的 workspace 文件与源码（利用层缓存）
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json* tsconfig.base.json ./
COPY packages ./packages
COPY admin ./admin
COPY app ./app

# 安装依赖。显式 --no-frozen-lockfile：pnpm 10 默认 install 为 frozen 模式，
# 而根 package.json 直接依赖 @tiptap/extension-drag-handle@3.27.1（用于满足
# @ctzhian/tiptap 经 drag-handle-react 引入的 peer，3.10.1 缺 normalizeNestedOptions）。
RUN pnpm install --no-frozen-lockfile --registry=https://registry.npmmirror.com

# 构建 app（Next.js standalone 输出到 dist/）
RUN NODE_OPTIONS=--max-old-space-size=4096 pnpm --filter panda-wiki-app build

# 运行阶段
FROM harbor.gbim.vip/dockerio/node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
# 必须监听 3010：Caddy 反代目标为 app:3010，且后端 knowledge_base.go 写死站点地址为 :3010
ENV PORT=3010
COPY --from=builder /src/app/dist/standalone ./
COPY --from=builder /src/app/dist/static ./.next/static
COPY --from=builder /src/app/public ./public
EXPOSE 3010
CMD ["node", "server.js"]
