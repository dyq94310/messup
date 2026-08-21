# messup

公开 Ansible 仓库：向多台 **Alpine / Debian LXC 或 KVM** 部署 **sing-box**、**SmartDNS** 与 **nft 端口转发**。

- **Alpine**：OpenRC；sing-box 使用 **musl** 二进制  
- **Debian/Ubuntu**：systemd；sing-box 使用 **glibc** 二进制  
- nft 私有映射按 inventory 主机名写在 `nft/forwards.yml`，**不按 OS 或环境 tag 拆分**

敏感配置（inventory、`config.json`、`smartdns.conf`、`nft/forwards.yml`）存放在私有仓库 **messup-private**，由 CI / 本地流程注入。

| 仓库 | 可见性 | 内容 |
|------|--------|------|
| [messup](https://github.com/dyq94310/messup) | Public | Playbook、OpenRC/systemd 模板、CI |
| [messup-private](https://github.com/dyq94310/messup-private) | Private | inventory、sing-box / SmartDNS / nft mappings |

---

## 架构

```
┌─────────────────┐     push      ┌──────────────────────┐
│  messup         │ ───────────►  │  GitHub Actions      │
│  (public)       │               │  1. checkout messup  │
│  playbooks/     │               │  2. checkout private │
│  templates/     │               │  3. ansible-playbook │
└─────────────────┘               └──────────┬───────────┘
                                             │ SSH
┌─────────────────┐     push      ┌──────────▼───────────┐
│  messup-private │ ──repository_ │  Alpine/Debian LXC/KVM │
│  (private)      │   _dispatch──►│  sing-box/smartdns/nft│
│  inventory/     │               └──────────────────────┘
│  singbox/       │
│  smartdns/      │
│  nft/forwards.yml│
└─────────────────┘
```

**多节点映射**

| inventory | 私有配置 |
|-----------|----------|
| （任意） | `singbox/config.json.j2` + `singbox/port_profiles.yml` |
| `nft_nodes` 主机名 | `nft/forwards.yml` 中同名键 |
| SmartDNS（全局） | 所有节点共用 `smartdns/smartdns.conf`，不分 env |

- 架构自动识别：`x86_64→amd64` / `aarch64→arm64`（sing-box）；SmartDNS 使用 `x86_64` / `aarch64` 官方包名
- OS 自动识别：Alpine → OpenRC + musl；Debian/Ubuntu → systemd + glibc（facts，无需 inventory 手写）
- sing-box 证书目录默认 `/etc/cert`；inventory 必须用 `singbox_cert_source=true` 指定唯一证书源节点，新节点缺证书时由 Ansible 从源节点镜像同步
- 仅配置变更时只重启服务；版本号变化时才重新下载二进制
- 所有 `all_nodes` 默认配置为 `Asia/Shanghai`（UTC+08:00），可单独运行 `--tags timezone`
- inventory 第一列节点别名同时作为目标机系统 hostname；每台机器的 `/etc/hosts` 只维护自己的 `127.0.1.1 <节点别名>` 映射，不建立节点间互访记录，可单独运行 `--tags hostname,hosts`
- 每台节点的 probe 安装命令保存在私有仓 `inventory/host_vars/<节点名>.yml`，节点还需加入私有 inventory 的 `probe_nodes`；可单独运行 `--tags probe --limit <节点名>`。命令 hash 保存在目标机本地，未变化时跳过执行

---

## 仓库结构

```
messup/                              # 公开仓（无主机清单）
├── ansible.cfg                      # inventory → private-config/inventory/
├── playbooks/
│   ├── site.yml                     # ssh bootstrap → python → system → hostname/hosts → services
│   ├── services.yml                 # 仅业务服务，用于自动服务级计划
│   ├── 00-bootstrap-ssh.yml         # 密钥优先；bootstrap_password 密码装钥
│   ├── 00-bootstrap-python.yml
│   ├── 00-configure-system.yml      # 统一系统时区（Asia/Shanghai）
│   ├── 00-configure-hostname.yml    # inventory 别名、hostname、本机 /etc/hosts
│   ├── 01-deploy-singbox.yml
│   ├── 02-deploy-smartdns.yml
│   ├── 03-deploy-nft.yml
│   ├── 04-deploy-probe.yml        # 按节点私有命令、hash 幂等部署 probe
│   └── 05-deploy-realm.yml        # 可选 Realm DDNS TCP relay
├── templates/
│   ├── singbox.openrc.j2 / singbox.service.j2
│   ├── smartdns.openrc.j2 / smartdns.service.j2
│   ├── messup-nft.openrc.j2 / messup-nft.service.j2
│   └── messup-nft.nft.j2
├── scripts/
│   ├── setup-local.sh               # 软链 private-config
│   └── deploy.sh                    # 本地一键部署
├── .github/workflows/
│   └── ansible-deploy.yml
└── README.md

messup-private/                      # 私有仓（本地/CI 注入为 private-config）
├── inventory/
│   ├── inventory.ini
│   └── group_vars/all.yml           # 版本号 + nft 默认参数
├── singbox/config.json.j2               # 统一模板，端口引用 singbox_ports
├── singbox/port_profiles.yml            # 默认及特殊 NAT 端口映射
├── realm/vars.yml                       # Realm 版本 / 路径 / DNS 默认值
├── realm/endpoints.yml                  # 按节点管理 Realm relay 规则
├── realm/config.json.j2                 # 可选 Realm relay 配置
├── ssh/public_keys/*.pub             # 额外个人电脑 SSH 公钥，下发到所有 all_nodes
├── smartdns/smartdns.conf           # 全局共用
└── nft/forwards.yml                 # 运行参数 + 按主机名的 DNAT
```

Realm 仅部署到私有 inventory 的 `realm_nodes`。节点从 `realm_nodes` 移除但仍保留在
`all_nodes` 时，自动部署会停止、禁用并移除 Realm service unit，保留二进制、配置和数据；
重新加入 `realm_nodes` 后可恢复部署。`realm/endpoints.yml` 按节点名
管理 relay 规则，`remote` 可以使用 DDNS 域名；配置的 DNS cache 最大 TTL 为
300 秒，已建立的连接不会迁移，新连接会在缓存过期后重新解析。

Sing-box 同理：从 `singbox_nodes` 移除但仍保留在 `all_nodes` 时，会停止、禁用并移除
Sing-box service unit，但保留 `/etc/s-box/` 和证书目录；重新加入服务组后会重新下发
unit 并启动。

---

## 初始化与鉴权（一次性）

为简单起见，**全部复用同一对密钥** `~/.ssh/id_ed25519_github`：

| 用途 | 使用方式 |
|------|----------|
| SSH 登录节点 | 公钥 → 各节点 `authorized_keys`；私钥 → CI / 本地 Ansible |
| 拉取 messup-private | 公钥 → private 仓 **Deploy keys**；私钥同上（CI 中的 `ANSIBLE_SSH_KEY`） |
| 本地 git / ansible | `IdentityFile ~/.ssh/id_ed25519_github` |

额外个人电脑登录只提交公钥到 `messup-private/ssh/public_keys/*.pub`。`00-bootstrap-ssh.yml` 会把这些公钥同步到所有 `all_nodes` 的 `/root/.ssh/authorized_keys`，不要提交私钥。

私有仓路径固定为 `dyq94310/messup-private`（workflow 内写死，无需 `PRIVATE_REPO` Secret）。

### 1. 生成密钥（若还没有）

```bash
ssh-keygen -t ed25519 -C "id_ed25519_github" -f ~/.ssh/id_ed25519_github -N ""
```

### 2. 公钥装到节点 + private Deploy Key

**推荐（新机）**：在 **messup-private** `inventory.ini` 写临时密码，由 Ansible 自动装钥：

```ini
hosts.ini 放连接信息；nft.ini 放 `nft_nodes`
```

push 后 CI / 本地 `deploy.sh` 会：先试密钥 → 失败则用密码装公钥 → 关 sshd 密码登录 → 密钥复核 → 业务部署。  
成功后**立刻**从 inventory 删掉 `bootstrap_password=...` 再 commit。控制机需 `sshpass`。

**手动（可选）**：

```bash
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
| `ANSIBLE_SSH_KEY` | ✅ | `~/.ssh/id_ed25519_github` **私钥**全文（同时用于拉 private + SSH managed nodes） |

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
~/.ssh/id_ed25519_github.pub  →  各 managed nodes authorized_keys
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

安装控制机依赖：`ansible`、`sshpass`（新机 `bootstrap_password` 装钥需要）。

### 改配置并部署

```bash
# 1) 改私有配置
vim ../messup-private/singbox/config.json.j2
vim ../messup-private/smartdns/smartdns.conf

# 2A) 推送私有仓 → 自动 CI 部署（对应服务）
cd ../messup-private
git add -A && git commit -m "update rear configs" && git push

# 2B) 或本地立即部署
cd ../messup
./scripts/deploy.sh
./scripts/deploy.sh --tags singbox
./scripts/deploy.sh --tags smartdns
./scripts/deploy.sh --limit test
```

### 改版本号 / inventory

```bash
# 均在 messup-private
cd messup-private
vim inventory/group_vars/all.yml   # singbox_version / smartdns_version
vim inventory/hosts.ini            # 节点别名 / ansible_host / 端口
git add -A && git commit -m "bump sing-box / update inventory" && git push
# → repository_dispatch → messup Ansible Deploy
```

### 新增节点

全部在 **messup-private**：

```bash
mkdir -p nft/node-b
# singbox/config.json.j2 全部节点共用；在 port_profiles.yml 增加 node-b 的端口 profile
# smartdns 全局共用 smartdns/smartdns.conf，无需按节点复制
# inventory/hosts.ini 增加一行（新机带临时密码即可自动装钥）:
# inventory/hosts.ini：加入基础连接信息；inventory/singbox.ini：加入 singbox_nodes 和端口 profile
# 确保已有且仅有一台节点标记 singbox_cert_source=true，供新节点同步 /etc/cert
git add -A && git commit -m "add node-b" && git push
# CI: 00-bootstrap-ssh → 连通性 → site（密钥优先，密码仅作首次回退）
# 成功后再 commit：删除 bootstrap_password=...
```

本地：`./scripts/deploy.sh --limit node-name`（需 `sshpass` + `~/.ssh/id_ed25519_github`）。

---

## CI/CD 行为

| 事件 | 结果 |
|------|------|
| push `messup` → `main` | 仅运行公开仓 `CI` 静态校验，不连接节点 |
| push `messup-private` → `main` | 推断服务级计划 → `repository_dispatch` → messup 分服务部署 |
| Actions 手动 Run workflow | 可填 `limit` / `tags` |

**自动部署顺序**（`repository_dispatch` / 部分手动）：`00-bootstrap-ssh`（密钥 / `bootstrap_password`）→ `check-connectivity` → 有 `deploy_plan` 时先 **`00-bootstrap-python`（计划主机一次）** 再 `services.yml` 分服务；全量或未带 plan 时用 `site.yml`（自带 Python bootstrap 等）。密码任务 `no_log`。

**私有仓服务推断示例**（权威实现：`messup-private` 的 `detect-deploy-scope.py`）

| 变更路径 | 部署范围 |
|----------|----------|
| `messup-private/singbox/**` | `singbox` + 全部 `singbox_nodes` |
| `messup-private/singbox/` 根目录共享文件 | 全部 `singbox_nodes` |
| `messup-private/smartdns/**` | 全部 `smartdns_nodes` |
| `messup-private/nft/**` | 全部 `nft_nodes` |
| `messup-private/inventory/hosts.ini` / `group_vars/all.yml` / `.deployignore` | 全量，等待 `production` 审批 |
| `messup-private/inventory/<service>.ini` | 比较该服务成员，新增/移除节点仅执行该服务；移除成员需审批 |
| `messup-private/inventory/host_vars/<节点>.yml` | 根据 `<service>_` 前缀部署该节点对应服务 |
| 删除 host_vars、未知路径 | 全量，等待 `production` 审批 |
| 仅文档 / `tests/**` / `Makefile` / `ssh/public_keys/**` 等忽略项 | 不 dispatch |

### 公开仓校验与生产部署隔离

公开仓 `messup` 的 push 和 Pull Request **只**运行 `CI`（YAML / shell / workflow 形状校验），不 checkout 私有配置、不配置生产 SSH、不连接节点。`Ansible Deploy` **不**响应本仓 `push`。

生产自动部署 **只**由 `messup-private/main` 的 `repository_dispatch` 触发；手工修复用公开仓 `workflow_dispatch`。私有仓按一次 push 的完整 `before..after` 推断范围；dispatch 携带最终 **sha**，公开仓固定 checkout 该版本。

| 公开仓改动 | 实际行为 |
|------------|----------|
| 任意 push / PR | 仅 `CI` 静态校验 |
| 业务 playbook / 模板要上生产 | 合并后：等 **private 配置变更** 触发 dispatch，或本仓 **`workflow_dispatch` 手动部署** |
| 文档、摘要脚本等 | 不部署 |

高风险 private 变更（如 inventory / `.deployignore`）的 `production` Environment 审批发生在 checkout 私有配置、写入 SSH 私钥和连接节点之前（若仓库已配置 Required reviewers）。

> 自动路径：SSH bootstrap → 连通性 → Python bootstrap → `services.yml`。全量/`site.yml` 仍自带 Python bootstrap。`scripts/classify-deploy-change.sh` 的 git-diff 规则仅供本地说明，不因本仓 push 触发部署。

---

## 重启服务

| 目的 | 做法 |
|------|------|
| 改配置并生效 | 改 private 配置 → push（或本地 `deploy.sh`）→ 对应 tags 部署；**文件内容有变更** 时 handler 会 restart |
| 只重启、不改配置 | SSH 用 OpenRC / systemctl，或本机 Ansible ad-hoc（见下） |
| 只动一台 | SSH 该机，或 `--limit <节点名>` |

> 配置未变时再跑 playbook **通常不会**强制重启（只保证 `started`）。**没有**单独的「强制 restart」CI；纯重启用节点上的 init 命令 / ad-hoc 即可。

### 改配置触发（推荐日常变更）

```bash
# messup-private
vim singbox/config.json.j2         # → tags=singbox，配置变了会 Restart singbox
vim smartdns/smartdns.conf         # → tags=smartdns（全局共用）
vim nft/forwards.yml              # → tags=nft（每次成功部署都会 re-apply）
git add -A && git commit -m "update rear" && git push
# 或本地: cd messup && ./scripts/deploy.sh --tags singbox --limit <节点名>
```

### 纯重启（最快）

SSH 到目标机：

```bash
# Alpine (OpenRC)
rc-service singbox restart|status|stop
rc-service smartdns restart|status|stop
rc-service messup-nft restart|status   # oneshot：restart = nft -f rules.nft
rc-update show default

# Debian/Ubuntu (systemd)
systemctl restart|status|stop singbox
systemctl restart|status|stop smartdns
systemctl restart|status messup-nft    # oneshot：restart = nft -f rules.nft
systemctl is-enabled singbox smartdns messup-nft
```

本机（控制机，inventory 已就绪；两种 OS 通用）：

```bash
ansible singbox_nodes -m service -a "name=singbox state=restarted"
ansible smartdns_nodes -m service -a "name=smartdns state=restarted"
ansible nft_nodes -m service -a "name=messup-nft state=restarted"
# 单机
ansible singbox_nodes -m service -a "name=singbox state=restarted" --limit test
```

### 状态 / 校验

```bash
sing-box version
sing-box check -c /etc/s-box/config.json
smartdns -v
nft list table ip forward
# 手动 apply：rc-service messup-nft restart  或  systemctl restart messup-nft
# nft -f /etc/messup-nft/rules.nft
```

安装路径：

| 组件 | 二进制 / 规则 | 配置 | 服务名 |
|------|---------------|------|--------|
| sing-box | `/etc/s-box/sing-box` | `/etc/s-box/config.json` | `singbox`（OpenRC 或 systemd） |
| SmartDNS | `/usr/sbin/smartdns` | `/etc/smartdns/smartdns.conf` | `smartdns` |
| nft | `nft -f /etc/messup-nft/rules.nft` | `/etc/messup-nft/rules.nft` | `messup-nft`（oneshot，开机自恢复） |

### sing-box 证书同步

默认维护一个证书目录 `singbox_cert_dir=/etc/cert`。多节点部署时，必须在
`inventory/singbox.ini` 的 `singbox_nodes` 中标记且只标记一台证书源节点：

```ini
node-a singbox_name=node-a singbox_cert_source=true
node-b singbox_name=node-b
```

部署 sing-box 时，每台目标机会先检查本机 `/etc/cert` 是否同时包含证书文件与私钥文件；本机已有则不动，本机缺失时由 Ansible 控制机从源节点打包并镜像恢复整个目录。源节点目录不存在或没有有效证书/私钥时，playbook 会直接失败，避免新节点启动 sing-box 后反复触发 ACME 申请。

---

## 故障排查

| 现象 | 处理 |
|------|------|
| `找不到节点配置` | 检查对应服务文件和 private `inventory/` 目录；CI `private-config` checkout |
| SSH permission denied | `ANSIBLE_SSH_KEY`(=id_ed25519_github) 与 `authorized_keys`；端口；新机可设 `bootstrap_password` |
| bootstrap 密码登录失败 | 控制机安装 `sshpass`；密码/端口正确；inventory 未把密码写进 `ansible_password` 长期字段 |
| private checkout 失败 | 同一公钥是否已加到 **messup-private** Deploy keys；Secret 是否私钥全文 |
| `repository_dispatch` 失败 | PAT 权限 / `PUBLIC_REPO` 写对 |
| sing-box check failed | 本地 `sing-box check -c config.json` |
| 新节点缺 sing-box 证书 | 确认 inventory 只有一台 `singbox_cert_source=true`，且该节点 `/etc/cert` 内已有证书与私钥 |
| 下载 404 | `singbox_version` / `smartdns_version` 与 release 是否一致 |
| sudo 相关错误 | 本方案 root 直连 `ansible_become=false`；勿强行 sudo |
| 预检不用 `ping` 模块 | 裸 Alpine/最小 Debian 可能无 Python；CI/本地用 `scripts/check-connectivity.sh`（`raw`） |
| 某台 IP 不通 | 只 **警告并跳过**，其余主机继续部署；仅**全部**不可达才失败 |
| `nft` Operation not permitted / soft-skip | 无 `CAP_NET_ADMIN` 时 playbook **soft-skip**（流水线可仍成功）；有权限但下发/apply/校验失败会 **hard-fail**。Proxmox 勿 drop `net_admin` |
| Debian 服务未起来 | 查 `systemctl status singbox` / `journalctl -u singbox -n 50`；确认 unit 在 `/etc/systemd/system/` |
| sing-box 下载 404 / 无法执行 | Alpine 应用 musl 包、Debian 用 glibc；确认 `singbox_version` 与 release 资产名一致 |

---

## 安全建议

- 公开仓 **禁止** 提交 `private-config/`、inventory、节点密码、Token
- 主机清单（IP/端口）与版本变量均在 **messup-private/inventory/**
- 本方案为省事复用一把 `id_ed25519_github`；若泄露需同时轮换各节点与 private Deploy Key
- 定期轮换 PAT 与 SSH 密钥
- 注意：旧公开提交历史中仍可能含曾泄露的 inventory，必要时轮换 SSH 端口
- 配置文件权限：sing-box `0600`，smartdns `0644`
