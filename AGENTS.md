# messup 代理规范

公开 Ansible 仓。执行任务时：本文件 > 用户请求 > README；**与代码/workflow 冲突时以代码为准**。

## 目标

向 Alpine / Debian / Ubuntu 节点部署：sing-box、SmartDNS、nft 端口转发、Realm relay、probe。

敏感配置只在 `messup-private`，经 `private-config/` 软链或 CI checkout 注入。禁止复制、缓存或硬编码私有内容。

## 目录

| 路径 | 职责 |
| --- | --- |
| `playbooks/` | `site.yml`（全量/手动）、`services.yml`（自动服务计划）、bootstrap 与各服务；Realm 为可选服务 |
| `templates/` | OpenRC / systemd / 服务模板 |
| `scripts/` | 本地部署、连通性、变更分类、摘要 |
| `.github/workflows/` | `ci.yml` 静态校验；`ansible-deploy.yml` 生产部署；`bark-notify.yml` 通知；`clean-history.yml` 非部署 |
| `ansible.cfg` | inventory 目录 → `private-config/inventory/` |
| `private-config/` | 注入目录，禁止提交真实内容 |

改前读目标文件及调用方；复用现有变量、tags、handler、脚本。

## 部署触发

| 事件 | 行为 |
| --- | --- |
| `repository_dispatch`（`private-config-updated`） | 私有仓变更；按 payload 的 tags/limit/`deploy_plan` 部署；checkout 私有仓 **必须 pin `client_payload.sha`** |
| `workflow_dispatch` | 人工 limit/tags；私有仓 ref 可用 `main` |
| 本仓 `push` / PR | **仅** `ci.yml`，不连节点、不 checkout 私有仓 |
| `Notify Bark` | `workflow_run` 于 Ansible Deploy 完成后；不触发部署 |

## 部署范围从哪来

**生产自动范围以 private 为准**：`messup-private` 的 `detect-deploy-scope.py` 生成 `deploy_plan` / tags / limit / `approval_required`，经 `repository_dispatch` 传入；本仓 **透传并执行**，不根据本仓 git diff 自动部署。

本仓 `scripts/classify-deploy-change.sh` 在 Deploy 中只处理：

| `EVENT_NAME` | 行为 |
| --- | --- |
| `repository_dispatch` | 使用 payload 的 tags/limit/`approval_required`（及 workflow 侧的 `deploy_plan`） |
| `workflow_dispatch` | 使用人工输入的 tags/limit |
| `push`（默认本地） | 可对 git diff 做**说明性**分类；**当前 Deploy 无 push 触发，CI 不会因此连节点** |

有 `deploy_plan` 时用 `services.yml` 分服务；否则/手动全量用 `site.yml`。

公开仓 playbook/模板要上生产：合并后靠 **private 配置变更触发 dispatch**，或本仓 **`workflow_dispatch` 手动部署**。改 private 范围规则时同步 private 文档；改本仓 classify 透传字段时同步本文件与 README。

## Ansible 硬约束

- Alpine=OpenRC；Debian/Ubuntu=systemd；root 直连，无故勿 `become`
- 幂等：配置未变不强制重启；版本变才重下二进制
- 自动部署跟 Git 变更，不修远程手工漂移；漂移用 `workflow_dispatch`
- 用现有 tags 与 `--limit`；新机：SSH bootstrap → 连通性 → Python → 服务
- 自动 `deploy_plan`：SSH → 连通性 → **一次** `00-bootstrap-python` → `services.yml`；全量/`site.yml` 仍自带 Python bootstrap。Realm/sing-box playbook 对仍在 `all_nodes` 但已移出服务组的节点执行 stop、disable 和 unit 删除，保留二进制及配置。服务 inventory 成员变化只传入对应服务和变更节点
- 仅一台 `singbox_cert_source=true`；禁止多源
- nft：无 CAP/无网卡/装包失败 soft-skip；主机名未对齐或 preflight 后 apply 失败 hard-fail（见 `03-deploy-nft.yml`）。规则来自 `nft/forwards.yml`，禁止 tc。
- 密码/Token/私钥不进 playbook、模板、样例、日志

## 安全

禁止写入公开仓、任务输出、聊天或 MCP：

- SSH 私钥、PAT、Actions Secret、`BARK_WEBHOOK_URL`
- private inventory、节点 IP/端口、密码、完整配置
- sing-box 密钥/证书、SmartDNS 私参、完整 nft 映射、原始 Actions 日志 dump

排障只留：仓库、workflow、run id、job/step、错误类型、脱敏主机、退出码、时间。敏感值用 `<redacted>`。

疑似泄露：停传播 → 记位置（不复述秘密）→ 建议轮换 → 未经授权不删历史/不改远程安全配置。

## Git

- 改前 `git status`；最小 diff；勿覆盖用户未提交改动
- Conventional Commits：`type(scope): description`
- **未经明确要求**：不 commit、不 push、不 PR、不改远程 workflow 状态
- 用户要求推送时说明范围与目标分支

## 验证（按改动选最小集）

```bash
git diff --check
bash -n scripts/<changed>.sh
# 本地可选（有 private-config / mock inventory 时）:
# ansible-playbook --syntax-check -i <inventory> -e private_config_temp=<dir> playbooks/<changed>.yml
```

连真实节点须说明目标、tags、limit、影响；优先 `--check`（raw/服务/下载/nft 可能不完全支持）。

Bark：区分 URL 解析错误与 HTTP/API 错误；勿把真实 Secret 写进命令行或日志。

勿声称执行了未跑的检查。

## 写操作与 MCP

默认只读诊断。禁止自动：读 Secret/private 原文、重跑/批准 Environment、SSH/Ansible 生产、改 Secret。

写操作先列出并等确认：对象、动作、影响、风险、回滚、已做预检。一次确认只覆盖一个动作。

生产回滚：最小提交；凭据泄露必须轮换，不能只靠 Git 回滚。禁止未经确认的 force-push、批量节点回滚。

## 排障结论模板

现象 / 根因（假设须标明）/ 证据 / 影响 / 修复 / 验证 / 后续（审批、重跑、轮换）。细节见 `README.md`。

## 文档维护

workflow 触发器、审批、Secret/artifact 名、分类路径、新服务或 OS 变更时，同步本文件与 README。发现文档与实现不一致时先指出差异再改。
