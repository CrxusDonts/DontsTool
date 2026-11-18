# DontsTool Cloud Sync

基于 Cloudflare Worker + SQLite Durable Object (`SyncHub`) + R2 (`dontstool-sync`) 的个人多端增量同步服务。

## 部署步骤

1. 安装依赖并登录 Cloudflare：
   ```bash
   cd CloudSync
   npm install
   npx wrangler login
   ```
2. 创建 R2 存储桶：
   ```bash
   npx wrangler r2 bucket create dontstool-sync
   ```
3. 生成强随机同步密钥并写入 Worker Secret（同时复制该密钥备用，后续填入 DontsTool「设置 → 同步与备份」）：
   ```bash
   openssl rand -base64 32 | tr -d '\n' | pbcopy
   npx wrangler secret put SYNC_TOKEN
   ```
4. 部署 Worker：
   ```bash
   npx wrangler deploy
   ```
5. （推荐）在 Cloudflare Dashboard → **Workers & Pages → dontstool-cloud-sync → Settings → Domains & Routes** 绑定自定义域名（例如 `https://sync.你的域名.com`），然后在各台 Mac 的 DontsTool 设置中填入该域名与 `SYNC_TOKEN` 即可开启多端实时同步。
