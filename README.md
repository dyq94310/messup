# messup

公开 Ansible 仓库：向多台 **Alpine LXC** 二进制部署 **sing-box** 与 **SmartDNS**（OpenRC 托管）。

敏感配置（`config.json`、节点信息、`smartdns.conf`）存放在私有仓库 **messup-private**，由 CI / 本地流程注入。

| 仓库 | 可见性 | 内容 |
|------|--------|------|
| [messup](https://github.com/dyq94310/messup) | Public | Playbook、inventory、OpenRC 模板、CI |
| [messup-private](https://github.com/dyq94310/messup-private) | Private | 各节点配置 |

---

## 架构

```
┌─────────────────┐     push      ┌──────────────────────┐
│  messup         │ ───────────►  │  GitHub Actions      │
│  (public)       │               │  1. checkout messup  │
│  playbooks/     │               │  2. checkout private │
│  inventory/     │               │  3. ansible-playbook │
└─────────────────┘               └──────────┬───────────┘
                                             │ SSH
┌─────────────────┐     push      ┌──────────▼───────────┐
│  messup-private │ ──repository_ │  Alpine LXC nodes    │
│  (private)      │   _dispatch──►│  sing-box + smartdns │
│  singbox/<env>/ │               └──────────────────────┘
│  smartdns/<env>/│
└─────────────────┘
```

**多节点映射**

| inventory | 私有配置 |
|-----------|----------|
| `deployment_env=rear` | `singbox/rear/config.json` + `smartdns/rear/smartdns.conf` |
| `deployment_env=node-b` | `singbox/node-b/config.json` + `smartdns/node-b/smartdns.conf` |

- 架构自动识别：`x86_64→amd64` / `aarch64→arm64`（sing-box）；SmartDNS 使用 `x86_64` / `aarch64` 官方包名
- 仅配置变更时只重启服务；版本号变化时才重新下载二进制

---

## 仓库结构

```
messup/
├── ansible.cfg
├── group_vars/all.yml              # singbox_version / smartdns_version / 路径
├── inventory/inventory.ini         # 主机 + deployment_env
├── playbooks/
│   ├── site.yml                    # 入口：bootstrap → smartdns → singbox
│   ├── 00-bootstrap-python.yml
│   ├── 01-deploy-singbox.yml
│   └── 02-deploy-smartdns.yml
├── templates/
│   ├── singbox.openrc.j2
│   └── smartdns.openrc.j2
├── scripts/
│   ├── setup-local.sh              # 软链 private-config
│   └── deploy.sh                   # 本地一键部署
├── .github/workflows/
│   └── ansible-deploy.yml
└── README.md
```

---

## 初始化与鉴权（一次性）

为简单起见，**全部复用同一对密钥** `~/.ssh/id_ed25519_github`：

| 用途 | 使用方式 |
|------|----------|
| SSH 登录 LXC | 公钥 → 各节点 `authorized_keys`；私钥 → CI / 本地 Ansible |
| 拉取 messup-private | 公钥 → private 仓 **Deploy keys**；私钥同上（CI 中的 `ANSIBLE_SSH_KEY`） |
| 本地 git / ansible | `IdentityFile ~/.ssh/id_ed25519_github` |

私有仓路径固定为 `dyq94310/messup-private`（workflow 内写死，无需 `PRIVATE_REPO` Secret）。

### 1. 生成密钥（若还没有）

```bash
ssh-keygen -t ed25519 -C "id_ed25519_github" -f ~/.ssh/id_ed25519_github -N ""
```

### 2. 公钥装到 LXC + private Deploy Key

```bash
# 登录目标机
ssh-copy-id -i ~/.ssh/id_ed25519_github.pub -p 22292 root@172.245.220.230
# 或: cat ~/.ssh/id_ed25519_github.pub >> /root/.ssh/authorized_keys
```

GitHub → **messup-private** → Settings → Deploy keys → Add deploy key：

- Title: `id_ed25519_github`
- Key: `~/.ssh/id_ed25519_github.pub` 全文
- **不要**勾选 Allow write access（只读即可）

确认 inventory 中 `ansible_port` 与 `sshd` 一致。

### 3. messup 仓库 Secrets（仅 1 个密钥 Secret）

| Secret | 必填 | 说明 |
|--------|------|------|
| `ANSIBLE_SSH_KEY` | ✅ | `~/.ssh/id_ed25519_github` **私钥**全文（同时用于拉 private + SSH LXC） |

```bash
# 把私钥粘贴到 messup → Settings → Secrets → Actions → ANSIBLE_SSH_KEY
cat ~/.ssh/id_ed25519_github
```

> 不再需要 `PRIVATE_REPO_DEPLOY_KEY` / `PRIVATE_REPO`。

### 4. 私有仓变更也能触发部署（仍需 PAT，不是 SSH 密钥）

`repository_dispatch` 走 GitHub API，不能用 ed25519，需一个 PAT：

1. 创建 PAT：classic `repo`，或 fine-grained 对 **messup** 的 `Contents: Read` + `Actions: Write`
2. **messup-private** Secrets：
   - `PUBLIC_REPO_DISPATCH_TOKEN` = 该 PAT
   - `PUBLIC_REPO`（可选）= `dyq94310/messup`

### 5. 关系一览

```
~/.ssh/id_ed25519_github.pub  →  各 LXC authorized_keys
                              →  messup-private Deploy keys（只读）

~/.ssh/id_ed25519_github      →  messup Secret: ANSIBLE_SSH_KEY
                              →  本地 ansible_ssh_private_key_file

PAT PUBLIC_REPO_DISPATCH_TOKEN → messup-private Secret（仅 dispatch，非 SSH）
```

---

## 本地日常操作

### 首次准备

```bash
mkdir -p ~/code/ansible && cd ~/code/ansible
git clone git@github.com:dyq94310/messup.git
git clone git@github.com:dyq94310/messup-private.git

cd messup
./scripts/setup-local.sh          # 软链 ../messup-private → private-config
# private-config 已在 .gitignore，不会进公开仓
```

安装控制机依赖：`ansible`（包管理器或 pip）。

### 改配置并部署

```bash
# 1) 改私有配置
vim ../messup-private/singbox/rear/config.json
vim ../messup-private/smartdns/rear/smartdns.conf

# 2A) 推送私有仓 → 自动 CI 部署（对应服务）
cd ../messup-private
git add -A && git commit -m "update rear configs" && git push

# 2B) 或本地立即部署
cd ../messup
./scripts/deploy.sh
./scripts/deploy.sh --tags singbox
./scripts/deploy.sh --tags smartdns
./scripts/deploy.sh --limit 172.245.220.230
```

### 改 Playbook / 版本号

```bash
# group_vars/all.yml → singbox_version / smartdns_version
cd messup
vim group_vars/all.yml
git add -A && git commit -m "bump sing-box" && git push
# → 自动触发 GitHub Actions 全量/对应部署
```

### 新增节点

1. **messup-private**

```bash
mkdir -p singbox/node-b smartdns/node-b
cp singbox/rear/config.json singbox/node-b/
cp smartdns/rear/smartdns.conf smartdns/node-b/
# 编辑后 commit + push
```

2. **messup** `inventory/inventory.ini`

```ini
10.0.0.30 ansible_port=22 deployment_env=node-b
```

3. 公钥写入新节点 `authorized_keys`，推送 messup（或本地 `./scripts/deploy.sh --limit 10.0.0.30`）。

---

## CI/CD 行为

| 事件 | 结果 |
|------|------|
| push `messup` → `main` | 拉 private → 按变更路径推断 tags → `site.yml` |
| push `messup-private` → `main` | 推断 tags → `repository_dispatch` → messup 再部署 |
| Actions 手动 Run workflow | 可填 `limit` / `tags` |

**对应服务推断示例**

| 变更路径 | 部署 tags |
|----------|-----------|
| `messup-private/singbox/**` | `singbox`（含 bootstrap） |
| `messup-private/smartdns/**` | `smartdns` |
| 两仓同时改 / 公共文件 | 全量（bootstrap + 两服务） |
| `playbooks/01-deploy-singbox.yml` | `singbox` |
| `group_vars/all.yml` / `inventory/*` | 全量 |

> 使用 `--tags singbox` 时 bootstrap 带 `always` 标签仍会执行，保证 Python 就绪。

---

## OpenRC（目标机）

```bash
rc-service smartdns status|restart|stop
rc-service singbox status|restart|stop
rc-update show default

sing-box version
sing-box check -c /etc/s-box/config.json
smartdns -v
```

安装路径：

| 组件 | 二进制 | 配置 | 服务名 |
|------|--------|------|--------|
| sing-box | `/etc/s-box/sing-box` | `/etc/s-box/config.json` | `singbox` |
| SmartDNS | `/usr/sbin/smartdns` | `/etc/smartdns/smartdns.conf` | `smartdns` |

---

## 故障排查

| 现象 | 处理 |
|------|------|
| `找不到节点配置` | `deployment_env` 与 private 目录名；CI `private-config` checkout |
| SSH permission denied | `ANSIBLE_SSH_KEY`(=id_ed25519_github) 与 `authorized_keys`；端口 |
| private checkout 失败 | 同一公钥是否已加到 **messup-private** Deploy keys；Secret 是否私钥全文 |
| `repository_dispatch` 失败 | PAT 权限 / `PUBLIC_REPO` 写对 |
| sing-box check failed | 本地 `sing-box check -c config.json` |
| 下载 404 | `singbox_version` / `smartdns_version` 与 release 是否一致 |
| sudo 相关错误 | 本方案 root 直连 `ansible_become=false`；勿强行 sudo |
| 预检不用 `ping` 模块 | 裸 Alpine 无 Python；CI/本地用 `scripts/check-connectivity.sh`（`raw`） |
| 某台 IP 不通 | 只 **警告并跳过**，其余主机继续部署；仅**全部**不可达才失败 |

---

## 安全建议

- 公开仓 **禁止** 提交 `private-config/`、节点密码、Token
- 本方案为省事复用一把 `id_ed25519_github`；若泄露需同时轮换 LXC 与 private Deploy Key
- 定期轮换 PAT 与 SSH 密钥
- inventory 若含敏感信息，可改为 Secret 动态生成 inventory
- 配置文件权限：sing-box `0600`，smartdns `0644`
