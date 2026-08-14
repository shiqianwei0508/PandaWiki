# syntax=docker/dockerfile:1.7
# 单阶段构建：在容器内完成 pnpm install（真实依赖，避免 standalone 软链断链）+ build + next start。
# 基础镜像走内网 harbor，依赖安装走国内镜像（registry.npmmirror.com，@ctzhian/* 等均为公共包，无需私有源）。
FROM harbor.gbim.vip/dockerio/node:22-alpine
WORKDIR /app

# 国内 npm/pnpm 镜像源（@ctzhian/* 等均为公共包，npmmirror 可同步，无需私有源凭证）
ENV PNPM_HOME=/pnpm
ENV npm_config_registry=https://registry.npmmirror.com
ENV PNPM_CONFIG_REGISTRY=https://registry.npmmirror.com
# 抑制 Sentry 在构建时上传 source map（避免容器内挂起/失败）
ENV CI=true
# 必须监听 3010：Caddy 反代目标为 app:3010，且后端 knowledge_base.go 写死站点地址为 :3010
ENV PORT=3010
ENV NODE_ENV=production

RUN corepack enable && corepack prepare pnpm@10.12.1 --activate

# 复制整个 workspace 清单与源码（利用层缓存；packages/* 是 app 的 workspace 依赖，必须一并复制）
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json* tsconfig.base.json ./
COPY packages ./packages
COPY admin ./admin
COPY app ./app

# 安装全部依赖（显式 --no-frozen-lockfile：根 package.json 直接依赖 @tiptap/extension-drag-handle@3.27.1，
# 用于满足 @ctzhian/tiptap 经 drag-handle-react 引入的 peer，3.10.1 缺 normalizeNestedOptions）。
# 不写 --prod：build 阶段本身也需要 devDependencies（next、typescript 等）。
RUN pnpm install --no-frozen-lockfile --registry=https://registry.npmmirror.com

# 构建 app（next.config 已去掉 output:'standalone'，distDir:'dist'，产物输出到 app/dist）
RUN NODE_OPTIONS=--max-old-space-size=4096 pnpm --filter panda-wiki-app build

# 用 --prod 再扫一遍，剔除 devDependencies，缩减最终镜像体积（next start 只需运行期依赖）。
# --ignore-scripts：跳过根 package.json 的 prepare（husky 装 git hooks），镜像里不需要且 husky 为 devDep 会导致 husky: not found。
RUN pnpm install --prod --no-frozen-lockfile --ignore-scripts --registry=https://registry.npmmirror.com

# === 构建期断言：把常见低级错误在 docker build 阶段就暴露，而非等到容器启动才报 ===
# 1) next 可执行文件必须存在（之前曾因 --filter 缺 packages/ 导致 .bin/next 缺失）
RUN test -x /app/node_modules/.bin/next || (echo "ERROR: next binary missing at /app/node_modules/.bin/next" && exit 1)
# 2) 构建产物 dist 必须存在（next build 失败或 distDir 配置错位会导致缺失）
RUN test -d /app/app/dist && test -f /app/app/dist/BUILD_ID \
  || (echo "ERROR: app/dist missing or incomplete (next build may have failed)" && exit 1)
# 3) next.config.ts 必须存在（next start 启动时要读取，缺失会静默用默认配置）
RUN test -f /app/app/next.config.ts || (echo "ERROR: next.config.ts missing in /app/app" && exit 1)

WORKDIR /app/app
EXPOSE 3010
# next start 读取 /app/app 下的 next.config.ts（cwd）与 dist/（distDir:'dist'）启动 SSR。
# node_modules 在 workspace 根 /app/node_modules，用绝对路径指向 .bin/next。
CMD ["/app/node_modules/.bin/next", "start", "-p", "3010"]
