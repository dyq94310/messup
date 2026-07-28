# 项目协作规范

本文档是 `messup` 仓库的项目级执行规范，适用于人工开发、自动化代理和后续接入的 MCP 工具。执行任务时应优先遵守本文档，再遵守用户当前请求和仓库现有实现。

## 1. 项目目标

`messup` 是公开的 Ansible 部署仓库，负责向 Alpine、Debian 和 Ubuntu 节点部署：

- sing-box
- SmartDNS
- nft 端口转发
- probe 监控程序

项目由两个仓库组成：

| 仓库 | 职责 |
| --- | --- |
| `messup` | Playbook、模板、脚本、GitHub Actions 和公开文档 |
| `messup-private` | inventory、节点地址和端口、版本变量、sing-box 配置、SmartDNS 配置、nft 映射和 SSH 公钥 |

`messup` 不应复制、缓存或硬编码 `messup-private` 的敏感内容。开发和 CI 通过 `private-config/` 软链或 checkout 后的目录使用私有配置。

## 2. 目录职责

- `playbooks/`：部署入口和服务 Playbook。
- `templates/`：OpenRC、systemd 和服务配置模板。
- `scripts/`：本地部署、连通性检查和变更分类脚本。
- `.github/workflows/`：CI/CD 工作流。
- `ansible.cfg`：inventory 路径、连接参数和 Ansible 默认行为。
- `private-config/`：本地或 CI 注入的私有配置目录，禁止提交真实内容。
- `README.md`：面向使用者的操作和排障说明。

修改前先阅读目标文件及其调用方，优先复用现有变量、tags、handler 和脚本，不为局部问题引入新的部署机制。

## 3. 部署与变更规则

### 3.1 触发来源

`Ansible Deploy` 由以下事件触发：

- `repository_dispatch` 类型 `private-config-updated`：响应 `messup-private` 的配置变更。
- `workflow_dispatch`：人工指定 `limit` 和 `tags` 部署。

公开仓的 `push` 和 Pull Request 只运行静态校验工作流，不触发生产部署；公开仓改动不得通过 checkout 当前 `messup-private/main` 间接覆盖节点配置。

`Notify Bark` 由 `Ansible Deploy` 的 `workflow_run.completed` 触发，负责读取摘要 artifact 并发送通知。修改 Bark 工作流本身不会触发生产部署，但仍会在相关 Ansible 运行完成后发送通知。

### 3.2 变更分类

变更分类以 `scripts/classify-deploy-change.sh` 的实际逻辑为准，不要仅依据文档猜测：

- sing-box Playbook 或模板：使用 `singbox`。
- SmartDNS Playbook 或模板：使用 `smartdns`。
- nft Playbook 或模板：使用 `nft`。
- probe Playbook：使用 `probe`。
- 文档、`LICENSE`、`.gitignore` 和部署摘要脚本：跳过节点部署。
- workflow、bootstrap、`ansible.cfg` 或未知文件：进入 `production` Environment 审批，批准后全量部署。
- 私有仓事件：按事件传入的 tags 和 limit 执行部署。
- 私有仓 dispatch 携带的提交 SHA 是部署配置版本；公开仓必须 checkout 该 SHA，不得在自动部署中无条件读取私有仓 `main`。

新增或修改分类规则时，必须同步检查脚本、工作流输出、README 和审批行为，避免出现“显示不部署但实际部署”或相反情况。

### 3.3 Ansible 行为约束

- 默认支持 Alpine 的 OpenRC，以及 Debian/Ubuntu 的 systemd。
- 目标主机默认 root 连接，不要无理由启用 `become` 或 sudo。
- 保持任务幂等；配置未变化时不应强制重启服务。
- 自动部署的依据是私有仓 Git 变更，不负责发现或修复远程手工漂移；需要修复漂移时使用人工 `workflow_dispatch`。
- 使用现有 tags 和 `--limit` 缩小影响范围。
- 新节点首次接入时遵守 SSH bootstrap、Python 安装、连通性检查和服务部署顺序。
- 不要绕过证书源节点约束，不要让多个节点同时成为 `singbox_cert_source`。
- 不要把密码、Token 或私钥写入 Playbook、模板、测试样例或日志。

## 4. 安全与敏感信息

以下内容禁止提交到公开仓库、写入任务输出、发送到聊天或传递给 MCP：

- SSH 私钥、PAT、GitHub Token、Actions Secret 和环境变量中的凭据。
- `BARK_WEBHOOK_URL`、BARK device key 和其他通知凭据。
- `messup-private` 的 inventory、节点 IP、端口、密码和私有配置原文。
- sing-box 密钥、证书、私钥、SmartDNS 私有参数和完整 nft 映射。
- 包含上述内容的完整 GitHub Actions 原始日志或环境变量 dump。

排障时只保留必要证据：仓库名、工作流名、运行 ID、Job/Step 名、错误类型、脱敏后的 URL 主机、退出码和时间。节点地址、Token、密钥和配置值必须替换为 `<redacted>`。

发现疑似密钥泄露时：

1. 立即停止复制和传播该内容。
2. 记录泄露位置和影响范围，但不要在报告中复述秘密本身。
3. 建议轮换对应 Secret、Token、SSH key、Webhook 或证书。
4. 未经用户明确授权，不执行删除历史、轮换凭据或修改远程安全配置。

## 5. 修改与 Git 规则

- 修改前检查 `git status`，不要覆盖或回滚用户已有改动。
- 保持改动最小，只修改完成任务所需的文件。
- 手工修改必须使用补丁方式，避免重写无关格式或行尾。
- 提交前检查 `git diff`、`git diff --check` 和目标文件状态。
- 提交信息使用 Conventional Commits，格式为 `type(scope): description`，例如 `fix(ci): handle invalid Bark webhook URL`。
- 未经用户明确要求，不创建 commit、不 push、不创建 PR、不修改远程 workflow 运行状态。
- 只有用户明确要求提交并推送时，才执行对应 Git 操作；推送前说明提交范围和目标分支。

## 6. 验证要求

根据改动范围执行最小充分验证，不要声称执行了未执行的检查。

### 6.1 GitHub Actions

优先执行：

```bash
actionlint
git diff --check
```

检查以下内容：

- `on` 事件、Job 条件、`needs` 和 `workflow_run` 上下文是否匹配。
- Secret、环境变量和 GitHub expression 是否在正确层级使用。
- artifact 的上传名称、下载 pattern、权限和 run ID 是否一致。
- Action 主版本是否支持当前运行器 Node.js 版本。
- `set -euo pipefail` 下变量是否有默认值，命令失败是否会被错误吞掉。

### 6.2 Shell 与 Ansible

修改 Shell 脚本时执行：

```bash
bash -n scripts/<changed-script>.sh
```

修改 Playbook 或模板时，在私有 inventory 可用且不连接生产节点的前提下执行：

```bash
ansible-playbook --syntax-check playbooks/<changed-playbook>.yml
```

涉及真实节点的验证必须明确说明目标、tags、limit 和潜在影响。优先使用 `--check`，但要注意某些 raw、服务、下载和 nft 任务不完全支持 check mode。

### 6.3 Bark 通知

验证通知工作流时区分两类问题：

- URL 解析错误：通常在网络请求前发生，优先检查 Secret 的 scheme、主机、端口、路径和隐藏空白。
- HTTP 或 Bark API 错误：检查响应状态、请求 JSON 字段和服务端返回，但不得输出完整 webhook 或 device key。

不要为了验证 Bark 而把真实 Secret 写入命令行、脚本、artifact 或调试日志。

## 7. CI 故障排查流程

按以下顺序排查，先只读收集证据，再提出修复：

1. 确认仓库、分支、提交 SHA、事件类型、运行 ID、结论和是否被取消。
2. 确认失败的 Job、Step、失败时间和是否是主部署或 `Notify Bark`。
3. 检查 workflow 条件、`needs`、审批 Environment、Secret 是否缺失，以及 artifact 是否成功上传/下载。
4. 如果是私有配置触发，检查 `repository_dispatch` 类型、payload 中的 tags/limit 和 PAT 权限，不读取 PAT 内容。
5. 如果涉及 checkout，检查仓库、ref、Deploy Key/Token 权限和路径，不输出私钥或完整错误上下文中的凭据。
6. 如果涉及 SSH/bootstrap，检查目标是否可达、端口、用户名、Python、`bootstrap_password` 临时使用状态和失败主机。
7. 如果涉及 Ansible，定位第一个失败任务、目标主机、模块、返回码和 handler 行为；区分 `unreachable`、模块失败、配置校验失败和服务启动失败。
8. 如果涉及 Bark，检查摘要文件、artifact 下载、最终 URL 的脱敏结构、JSON 构造和 HTTP 状态。
9. 对照最近一次成功运行和最近一次相关提交，判断是代码、配置、凭据、节点状态还是外部服务变化。
10. 输出根因和最小修复方案，修复后重新执行对应静态检查；需要重跑或生产部署时等待人工确认。

排障结论必须包含：

- 现象：用户看到的错误和失败位置。
- 根因：已证实的原因；未证实时标记为假设。
- 证据：运行 ID、Job/Step、错误行和必要的脱敏上下文。
- 影响：是否触及生产节点、artifact、通知或凭据。
- 修复：文件、行号或配置项，以及变更理由。
- 验证：已执行的命令及结果。
- 后续动作：是否需要人工审批、重跑、轮换凭据或回滚。

## 8. MCP 使用边界

后续接入 MCP 时，默认采用“只读诊断，写操作人工确认”策略。

### 8.1 默认允许

- 读取 GitHub Actions 工作流元数据、运行状态、Job/Step 状态和失败摘要。
- 读取脱敏后的 Actions 日志片段和 artifact 元数据。
- 读取公开仓库的提交、差异、workflow、脚本和 README。
- 对日志进行错误归类、时间线整理、最近成功运行对比和根因分析。
- 生成修复建议、补丁草案、验证命令和回滚方案，但不自动应用。

### 8.2 默认禁止

- 读取、猜测、回显或导出 Secret、Token、私钥、Webhook、inventory 和私有配置原文。
- 自动重跑、取消、批准或修改工作流、Environment 和部署状态。
- 修改仓库文件、创建提交、推送分支、创建 PR 或 issue。
- 修改 Actions Secret、变量、Deploy Key、PAT、SSH 配置或生产节点配置。
- 自动 SSH 到节点、执行 Ansible、重启服务、修改 nft 规则或轮换凭据。

### 8.3 人工确认格式

任何写操作都必须先展示以下信息并等待明确确认：

- 操作对象：仓库、分支、工作流、运行 ID、节点或 Secret 类型。
- 操作内容：具体命令或 API 动作。
- 影响范围：可能触及的节点、服务和通知。
- 风险：失败后果和不可逆部分。
- 回滚：可执行的回滚步骤及其限制。
- 预检查：已完成的只读验证。

只有用户明确确认对应动作后，MCP 才可执行该单一动作。确认不自动扩大到其他工作流、节点、Secret 或后续操作。

## 9. 回滚原则

- 优先回滚最近一个明确引入问题的最小提交，不使用破坏性 Git 命令覆盖用户改动。
- 生产服务回滚前确认目标节点、服务、版本和配置来源。
- 凭据泄露不能通过 Git 回滚视为解决，必须轮换凭据并检查历史暴露范围。
- workflow 修改的回滚需要重新运行静态检查，并确认不会因回滚再次引入旧 Node.js Action 或权限问题。
- 未经用户确认，不执行 `git push --force`、删除历史、生产重启、批量部署或批量节点回滚。

## 10. 文档维护

当以下内容变化时，必须同步更新本文档或 README：

- 工作流触发器、审批流程、Secret 名称或 artifact 约定。
- 变更分类脚本中的路径规则、部署 tags 或 limit 逻辑。
- 新增服务、操作系统、节点初始化步骤或回滚方式。
- MCP 的工具权限、脱敏策略或人工确认边界。

文档描述必须以代码和工作流实际行为为准；发现二者不一致时，先指出差异，再修改文档或实现，不要掩盖不一致。
