# 乘风版部署指南（Docker 单域名部署）

本文提供两种可落地的 Docker 部署方案，最终统一通过**单域名 + Nginx 反向代理**对外提供服务：

- 默认访问前台站点；
- 以 `/admin` 路径前缀访问后台管理（例如 `https://wiki.example.com/admin`）；
- API、分享、静态文件统一经 Nginx 转发到对应容器。

1. 手动安装环境 + 服务器源码构建部署（Build 模式）
2. 方案 B：预构建镜像部署（Image 模式，推荐生产）

> 原设计中的 Caddy（用于按知识库动态下发访问规则）已在企业单域名部署中移除，改由 Nginx 一个入口统一路由，不再需要多域名、多端口、多证书。

## 1. 方式对比

| 方式 | 适用场景 | 优点 | 注意事项 |
| --- | --- | --- | --- |
| 手动安装环境 + Build 模式 | 开发、联调、快速验证 | 改完代码即可在服务器本地构建 | 首次配置步骤较多；构建耗时较长 |
| 方案 B（预构建镜像） | 生产环境、稳定交付 | 发布快、可回滚、服务器负载低 | 需要先在 CI 产出镜像 |

## 2. 环境清单与推荐版本

### 2.1 服务器资源建议

- 最低配置：`4 vCPU / 8 GB RAM / 80 GB SSD`
- 推荐配置：`8 vCPU / 16 GB RAM / 160 GB SSD`
- 操作系统：`Debian 12` 或 `Ubuntu 22.04+`

### 2.2 组件版本

| 组件 | 推荐版本 | 说明 |
| --- | --- | --- |
| Docker Engine | `24.x+` | 两种部署方式都需要 |
| Docker Compose Plugin | `v2.24+` | 使用 `docker compose` 命令 |
| Nginx | `1.24+` | 对外唯一入口（反向代理 + TLS） |
| Git | `2.30+` | 拉取代码 |
| Node.js | `22.x` | 仅 Build 模式需要 |
| pnpm | `10.x` | 仅 Build 模式需要 |
| PostgreSQL | `16-alpine`（容器） | 主数据库 |
| Redis | `7-alpine`（容器） | 缓存/限流 |
| NATS | `2.10-alpine`（容器） | 消息队列 |
| MinIO | `latest`（容器） | 对象存储 |
| Qdrant | `v1.14.1`（容器） | 向量检索 |
| Raglite | `v2.14.1`（容器） | RAG 服务 |

## 3. 通用准备

### 3.1 拉取代码

```bash
git clone https://github.com/MaydayV/PandaWiki.git
cd PandaWiki
```

### 3.2 准备部署变量

```bash
cd docs/deploy
cp .env.example .env
```

修改 `.env` 至少包含以下值：

- `POSTGRES_PASSWORD`
- `REDIS_PASSWORD`
- `S3_SECRET_KEY`
- `NATS_PASSWORD`
- `QDRANT_API_KEY`
- `JWT_SECRET`
- `ADMIN_PASSWORD`
- `DEV_KB_ID`
- `KB_BASE_URL`（可选）：站点对外域名。用于拼接分享链接、sitemap、OAuth 等绝对 URL。单域名 Nginx 部署下可留空（前台自动用浏览器当前域名兜底）；如需全局指定，填完整地址如 `https://wiki.example.com`，作用于所有未单独配置 `base_url` 的知识库。详见下方「3.5」。

仅 Image 模式额外需要：

- `PANDAWIKI_IMAGE_REPO`
- `PANDAWIKI_IMAGE_TAG`

### 3.3 首次部署初始化数据库（仅首次）

> 当前项目使用完整部署 SQL：`backend/store/pg/migration/full_fresh_deploy.sql`

先启动 PostgreSQL：

```bash
docker compose -f docker-compose.build.yml up -d panda-wiki-postgres
```

导入完整 SQL：

```bash
cat ../../backend/store/pg/migration/full_fresh_deploy.sql | \
docker compose -f docker-compose.build.yml exec -T panda-wiki-postgres \
psql -U panda-wiki -d panda-wiki
```

如果使用 Image 模式，可将命令中的 `docker-compose.build.yml` 替换为 `docker-compose.image.yml`。

### 3.4 端口职责与流量路径（单域名模式）

> **部署形态说明**：Nginx 与运行 docker-compose 的宿主机是**两台不同的服务器**。
> 因此各容器端口在 compose 中绑定 `0.0.0.0`（对所有网卡开放），由部署在独立服务器上的
> Nginx 通过**容器宿主机的内网/可达 IP** 反代过来。注意：请用**宿主防火墙仅放行 Nginx
> 服务器 IP**，避免这些端口直接暴露公网。

| 容器端口 | 绑定地址 | 用途 |
| --- | --- | --- |
| `3010` | `0.0.0.0:3010` | 前台站点（app） |
| `2443` | `0.0.0.0:2443` | 后台管理（admin，纯静态 HTTP） |
| `8000` | `0.0.0.0:8000` | API 容器 |
| `9000` | `0.0.0.0:9000` | MinIO 对象存储（供静态文件 `/static-file`） |
| `5432/6379/4222/9001` | 容器网络内 | 数据库与中间件，不对宿主机暴露 |

流量路径（单域名 `wiki.example.com`，Nginx 在独立服务器）：

- `wiki.example.com/`            → Nginx `location /`     → app（`<宿主机IP>:3010`）——前台默认站点
- `wiki.example.com/admin`       → Nginx `location /admin/`→ admin（`<宿主机IP>:2443`，剥离 `/admin` 前缀）
- `wiki.example.com/admin/api/*` → Nginx `location /admin/api/` → api（`<宿主机IP>:8000`，剥离 `/admin` 前缀）
- `wiki.example.com/api/*`       → Nginx `location /api/`    → api（`<宿主机IP>:8000`）
- `wiki.example.com/share/*`     → Nginx `location /share/`   → api（`<宿主机IP>:8000`）
- `wiki.example.com/static-file/*`→ Nginx `location /static-file/`→ MinIO（`<宿主机IP>:9000`）

> `<宿主机IP>` = 运行 docker-compose 那台机器的内网/可达 IP（不是 `127.0.0.1`，因为 Nginx 在另一台机器）。

说明：

- 后台 `admin` 容器内置的是纯 HTTP 静态服务器（`web/admin/server.cjs`，只托管 `dist`，**不代理 `/api`**）。所有接口请求（`/admin/api/*`、`/admin/share/*`）都以「同源 + `/admin` 前缀」发给 Nginx，由 Nginx 转发到 API 容器；直接访问 `http://<ip>:2443` 因无 `/api` 处理能力而无法登录，必须经 Nginx。
- 后台前端 `Vite base` 已设为 `/admin/`，构建产物默认带 `/admin` 前缀；Nginx 把 `/admin` 前缀剥离后转发给 admin 容器即可命中 `dist` 下的资源。

> **⚠️ 必须配置知识库 ID（否则前台"啥也没有"）**
> 前台 app 与 `/share` 接口都通过 `X-KB-ID` 头定位当前知识库。代码实证：
> - `web/app/src/utils/getServerHeader.ts:5`：`kb_id = headers('x-kb-id') || process.env.DEV_KB_ID || ''`
> - `web/app/src/proxy.ts:98`：`kb_id = request.headers.get('x-kb-id') || process.env.DEV_KB_ID || ''`，
>   并在 `proxy.ts:107` 把 `kb_id` 写入转发后端的 `x-kb-id` 头。
> 原 Caddy 会在转发时动态注入 `X-KB-ID` 头，去 Caddy 后**必须由 Nginx 注入**。
>
> **⚠️ 不要依赖 `.env` 的 `DEV_KB_ID`**：app 是 Next.js 应用，`proxy.ts`/`getServerHeader.ts` 里
> `process.env.DEV_KB_ID` 是**点号直接访问**，Next.js 在 `next build`（镜像构建阶段）会把它**内联**成
> 编译时字面量；而 `DEV_KB_ID` 只在 compose **运行期**（`DEV_KB_ID: ${DEV_KB_ID}`）注入 `next start`
> 进程，构建期 Dockerfile 未设置该变量 → 编译产物里已是空串，运行期容器设了也读不到。
> （`web/app/Dockerfile` 中确认无任何 `DEV_KB_ID` 的 ARG/ENV。）
>
> **✅ 正确做法（唯一可靠）：Nginx 注入 `X-KB-ID` 头**
> 在 `nginx.conf` 中 `set $kb_id "真实知识库ID";`，并在 `location /` 与 `location /share/` 加
> `proxy_set_header X-KB-ID $kb_id;`（见 6.2）。`.env` 的 `DEV_KB_ID` 可保留但**不生效**，无需依赖。
> 若未注入，app 拿到空 `kb_id`，前端页面因无知识库上下文而渲染为空。
- 容器统一使用 `172.29.0.0/24` 网段，各服务固定 IP（见 `docker-compose.*.yml` 的 `ipv4_address`）。服务间通过容器名互访，不受该固定 IP 影响。
- 持久化目录全部使用 `docker-compose.yml` 同级目录的 `./data/<服务>`，**不使用 Docker named volume**，便于直接备份与迁移。

### 3.5 站点对外域名（KB_BASE_URL）

前台/后台在拼接**完整对外绝对 URL** 时会用到域名，典型场景：

- 分享链接、sitemap、robots
- OAuth / 微信 / 飞书 / 钉钉等第三方登录的回调地址
- SSE 文档来源、富媒体资源绝对地址

#### 配置位置

在 `docker-compose.*.yml` 的 **`panda-wiki-api` 服务**的 `environment` 中（已预留占位）：

```yaml
panda-wiki-api:
  environment:
    # 站点对外域名，作用于所有未单独配置 base_url 的知识库
    KB_BASE_URL: ""          # 留空 或 https://wiki.example.com
```

同时也可在 `.env` 中存放同名变量（`KB_BASE_URL=...`），compose 会读取。

#### 取值优先级与兜底逻辑

| 来源 | 优先级 | 说明 |
| --- | --- | --- |
| 后台「知识库设置」中填写的 `base_url` | 最高 | 每个知识库可单独指定 |
| `KB_BASE_URL`（docker-compose 注入） | 中 | 作为未单独配置知识库的全局兜底 |
| 浏览器当前域名（请求 origin） | 兜底 | **单域名 Nginx 部署推荐留空**，前台自动用 `Host`/`X-Forwarded-Proto` 推导 |

> 单域名 Nginx 部署（本文档默认架构）下，`KB_BASE_URL` **可以留空**：前台会在运行时用访问它的实际域名兜底，后台接口走同源 `/admin` 前缀也不需要此值。仅当你需要让所有知识库统一使用某个固定对外域名（例如生成 canonical/sitemap 时）时，才显式填写。

> 注意：`KB_BASE_URL` 是给「全局未单独配置的知识库」兜底用的。它**不会覆盖**你在后台「知识库设置」里已明确填写的 `base_url`。

### 3.6 从旧编排升级（执行一次）

如果你之前使用过旧版本编排（含 Caddy、旧网段、named volume），升级时建议先完整重建：

```bash
docker compose -f docker-compose.build.yml down --remove-orphans
docker compose -f docker-compose.build.yml up -d --build
```

Image 模式同理：

```bash
docker compose -f docker-compose.image.yml down --remove-orphans
docker compose -f docker-compose.image.yml pull
docker compose -f docker-compose.image.yml up -d
```

> 注意：网络从 `172.19.0.0/16` 改为 `172.29.0.0/24`、且持久化从 named volume 改为 `./data/*` 后，旧数据不会自动迁移。升级前请先备份旧 volume（PostgreSQL / MinIO 数据）。

## 4. 方式一：手动安装环境 + 服务器源码构建部署（Build 模式）

### 4.1 安装基础环境（Debian/Ubuntu）

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release git
```

安装 Docker：

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable docker
sudo systemctl start docker
```

安装 Node.js 22 与 pnpm：

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
corepack enable
corepack prepare pnpm@10.12.1 --activate
```

### 4.2 构建前端产物（必须）

> `web/admin` 与 `web/app` 的 Dockerfile 会复制构建产物，因此先构建前端。

```bash
cd ../../web
pnpm install --frozen-lockfile
NODE_OPTIONS=--max-old-space-size=4096 pnpm --filter panda-wiki-admin build
pnpm --filter panda-wiki-app build
cd ../docs/deploy
```

如果遇到 `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`：

```bash
pnpm install --no-frozen-lockfile
```

然后继续构建流程。

### 4.3 启动全部服务（Build）

```bash
docker compose -f docker-compose.build.yml up -d --build
```

### 4.4 验证

```bash
docker compose -f docker-compose.build.yml ps
curl -sS --retry 10 --retry-delay 2 --retry-connrefused http://127.0.0.1:8000/health
curl -I http://127.0.0.1:2443 | head -n 5
curl -I http://127.0.0.1:3010 | head -n 5
```

### 4.5 日常更新

```bash
cd ../..
git pull origin main
cd web
pnpm install --frozen-lockfile
NODE_OPTIONS=--max-old-space-size=4096 pnpm --filter panda-wiki-admin build
pnpm --filter panda-wiki-app build
cd ../docs/deploy
docker compose -f docker-compose.build.yml up -d --build
```

## 5. 方式二：方案 B（预构建镜像部署，推荐生产）

方案 B 使用 `docs/deploy/docker-compose.image.yml`，仅拉取镜像，不在服务器编译。

### 5.1 准备镜像变量

编辑 `docs/deploy/.env`：

- `PANDAWIKI_IMAGE_REPO=docker.io/caodanv`
- `PANDAWIKI_IMAGE_TAG=<发布标签>`

例如：

```env
PANDAWIKI_IMAGE_REPO=docker.io/caodanv
PANDAWIKI_IMAGE_TAG=FV2.6.14.2111
```

如镜像仓库为私有，先登录：

```bash
docker login
```

### 5.2 启动

```bash
docker compose -f docker-compose.image.yml pull
docker compose -f docker-compose.image.yml up -d
```

### 5.3 升级发布

1. 修改 `.env` 中 `PANDAWIKI_IMAGE_TAG` 为新版本。
2. 执行：

```bash
docker compose -f docker-compose.image.yml pull
docker compose -f docker-compose.image.yml up -d
```

### 5.4 回滚

1. 将 `PANDAWIKI_IMAGE_TAG` 改回上一版本。
2. 执行：

```bash
docker compose -f docker-compose.image.yml pull
docker compose -f docker-compose.image.yml up -d
```

### 5.5 CI 自动发布到 Docker Hub（推荐）

当前仓库已配置 GitHub Actions 自动推送四个镜像（`api/consumer/app/admin`）到 Docker Hub。

先在 GitHub 仓库设置 Secrets：

- `DOCKERHUB_USERNAME`：Docker Hub 用户名（例如 `caodanv`）
- `DOCKERHUB_TOKEN`：Docker Hub Access Token（不要用明文密码）

发布步骤：

```bash
git checkout main
git pull origin main
git tag v2.6.2
git push origin v2.6.2
```

推送完成后会自动发布：

- `docker.io/caodanv/pandawiki-api:v2.6.2`
- `docker.io/caodanv/pandawiki-consumer:v2.6.2`
- `docker.io/caodanv/pandawiki-app:v2.6.2`
- `docker.io/caodanv/pandawiki-admin:v2.6.2`

## 6. 单域名 Nginx 反向代理（对外唯一入口，推荐生产）

适用场景：统一 `80/443` 出口、复用现有 Nginx 证书与网关策略；一个域名同时承载前台与后台，后台以 `/admin` 路径访问。

### 6.1 核心原则

- 后台（`admin`）经 Nginx 以 `/admin` 子路径发布，无需独立域名与证书。
- 前台默认访问；`/admin` 前缀访问后台。
- `admin` 容器是纯静态服务器、不代理接口，因此 `/admin/api`、`/admin/share` 由 Nginx 转发到 API（宿主 `8000`）；`/admin/static-file` 转发到 MinIO（宿主 `9000`）。
- 其余 `/api`、`/share`、`/static-file` 为前台 app 使用，同样转发到对应容器。

### 6.2 Nginx 参考配置

完整示例见 `docs/deploy/nginx.conf.example`，核心如下：

```nginx
# upstream 指向"运行 docker-compose 的那台宿主机"的内网/可达 IP（Nginx 在独立服务器，不能是 127.0.0.1）
# 完整版见 docs/deploy/nginx.conf.example（含 ssl、反代头等），此处为核心摘录
upstream pw_api   { server 容器宿主机IP:8000; }
upstream pw_app   { server 容器宿主机IP:3010; }
upstream pw_admin { server 容器宿主机IP:2443; }
upstream pw_minio { server 容器宿主机IP:9000; }

server {
    listen 80;
    server_name wiki.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name wiki.example.com;
    ssl_certificate     /etc/nginx/certs/wiki.example.com.crt;
    ssl_certificate_key /etc/nginx/certs/wiki.example.com.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # 知识库 ID：单域名=一个知识库，前台 app 与 /share 靠 X-KB-ID 头定位（原 Caddy 注入，现改 Nginx）
    set $kb_id "在此填写知识库ID";

    # 通用反代头
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # ---------- 后台管理（/admin 前缀） ----------
    # Nginx 在独立服务器，upstream 指向"运行 docker-compose 的宿主机 IP"，不可用 127.0.0.1
    location /admin/api/      { proxy_pass http://pw_api/api/; }
    location /admin/share/    { proxy_pass http://pw_api/share/; }
    location /admin/static-file/ { proxy_pass http://pw_minio/static-file/; }
    location /admin/          { proxy_pass http://pw_admin/; }
    location = /admin         { return 301 /admin/; }

    # ---------- 前台 app 的 API / 分享 / 静态文件 ----------
    location /api/         { proxy_pass http://pw_api; }
    location /share/       { proxy_set_header X-KB-ID $kb_id; proxy_pass http://pw_api; }
    location /static-file/ { proxy_pass http://pw_minio; }

    # ---------- 默认：前台站点 ----------
    location / { proxy_set_header X-KB-ID $kb_id; proxy_pass http://pw_app; }
}
```

要点：

- `/admin/api/`、`/admin/share/`、`/admin/static-file/` 用**最长前缀**优先命中，剥离 `/admin` 前缀后转发到对应容器；`/admin/`（页面/资源）剥离 `/admin` 后转发到 admin 容器（SPA 由 `server.cjs` 回退）。
- `location = /admin` 处理不带尾斜杠的根路径，避免资源相对路径错误。
- 后台前端资源（图片、JS/CSS）均带 `/admin` 前缀，因此 Nginx 只需把 `/admin/...` 转发给 admin 容器即可，无需为每个资源单独写规则。

## 7. 访问说明

单域名模式（推荐，Nginx 已配置）：

- 前台站点：`https://wiki.example.com`
- 后台管理：`https://wiki.example.com/admin`
- API 健康检查：在**运行 docker-compose 的宿主机**上执行 `curl http://127.0.0.1:8000/health`

> 容器端口已绑定 `0.0.0.0` 以便独立服务器上的 Nginx 跨机访问；请勿在公网直接暴露
> `2443/8000/3010/9000`，应通过**宿主防火墙仅放行 Nginx 服务器 IP**，统一经 Nginx 对外。

## 8. 安全建议（生产必做）

1. `.env` 中全部密码改为高强度随机值，禁止使用示例密码。
2. 对外仅开放 Nginx 的 `80/443`；容器端口绑定 `0.0.0.0` 是为了让独立服务器上的 Nginx 跨机访问，请用**宿主防火墙仅放行 Nginx 服务器 IP**，避免 `8000/2443/3010/9000` 直接暴露公网。
3. 为对外域名配置真实 TLS 证书，不使用自签证书直接暴露公网。
4. 定期备份：`./data/postgres`、`./data/minio`、`docs/deploy/.env`。
5. 按 AGPL-3.0 要求提供当前运行版本对应源码链接。

## 9. 相关文件

- Build 模式编排：`docs/deploy/docker-compose.build.yml`
- Image 模式编排：`docs/deploy/docker-compose.image.yml`
- Nginx 单域名示例：`docs/deploy/nginx.conf.example`
- 部署变量模板：`docs/deploy/.env.example`
- 首次完整 SQL：`backend/store/pg/migration/full_fresh_deploy.sql`
