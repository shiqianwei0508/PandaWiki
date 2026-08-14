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

# 运行阶段：放弃 standalone，改用官方 next start，依赖在容器内 pnpm install 真实安装
# （避免 pnpm 软链 + standalone tracing 在容器内断链导致 require('next') 失败）。
FROM harbor.gbim.vip/dockerio/node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production

# 国内 npm/pnpm 镜像源（同 builder，@ctzhian/* 等均为公共包，无需私有源）
ENV PNPM_HOME=/pnpm
ENV npm_config_registry=https://registry.npmmirror.com
ENV PNPM_CONFIG_REGISTRY=https://registry.npmmirror.com

RUN corepack enable && corepack prepare pnpm@10.12.1 --activate

# 必须监听 3010：Caddy 反代目标为 app:3010，且后端 knowledge_base.go 写死站点地址为 :3010
ENV PORT=3010

# 复制 workspace 清单与 app 配置/源码（仅用于 pnpm install --prod 安装真实依赖，
# 以及 next start 读取 next.config.ts / tsconfig.json）。
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json* tsconfig.base.json ./
COPY app/package.json ./app/package.json
COPY app/next.config.ts ./app/next.config.ts
COPY app/tsconfig.json ./app/tsconfig.json

# 仅安装 app 生产依赖（--prod 跳过 devDeps；--filter 只解析 panda-wiki-app 及其传递依赖，
# 不会把 admin 等其它 workspace 包拉进 /app/node_modules）。
# --ignore-scripts：跳过根 package.json 的 prepare（husky 装 git hooks），镜像里不需要且 husky 为 devDep 会导致 husky: not found。
# 显式 --no-frozen-lockfile：根 package.json 直接依赖 @tiptap/extension-drag-handle@3.27.1
# （满足 @ctzhian/tiptap 的 peer，详见 builder 阶段注释）。
RUN pnpm install --prod --no-frozen-lockfile --ignore-scripts --filter panda-wiki-app... --registry=https://registry.npmmirror.com

# 复制 Next 构建产物与静态资源（用 next start 而非 standalone server.js）。
# next.config 中 distDir: 'dist'，故构建产物复制到 /app/dist（与 distDir 一致）。
COPY --from=builder /src/app/dist ./dist
COPY --from=builder /src/app/public ./public

EXPOSE 3010
# next start 会自动读取 next.config.ts 中的 distDir（dist），在 cwd /app 下启动 SSR。
CMD ["node_modules/.bin/next", "start", "-p", "3010"]
