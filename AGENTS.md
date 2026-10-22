# Agent 门禁 (硬性禁令)

任何 AI agent / 自动化在本仓库工作前必须遵守。违反任何一条即为错误操作,
即使任务指令没有明确提及。

## 1. 知识库只留本地, 严禁推送

`docs/kb/`(收录快照+提炼笔记)与 `docs/upstream/`(上游完整克隆)是**本地资料库**,
绝对不允许进入 git 历史:

- **禁止** `git add docs/kb docs/upstream`(包括 `git add -A` / `git add .` 的隐式收录)
- **禁止**修改 `.gitignore` 等任何方式把它们改为跟踪
- 排除机制在 `.git/info/exclude`(仅本地生效, 不随仓库分发)——**不要删除或注释其中
  的 `docs/kb/`、`docs/upstream/` 两行**
- 提交前必须核对 `git status --short` 与 `git diff --cached --name-only`:
  出现 `docs/kb/` 或 `docs/upstream/` 任何路径即中止提交并移除
- 知识库的维护(同步/去旧)用 `bash docs/kb/update_kb.sh`, 只在本地执行, 不涉及 git

## 2. push 即发布

GitHub 仓库 `mrhorse2277-boop/v2ray-onekey` 的 main 分支就是用户侧一键命令的
raw 拉取源,**没有版本分支/tag 隔离**:

- install.sh 的任何改动必须先在测试 VPS 上验证通过才允许 push(硬约束)
- 纯文档(README/MAINTENANCE/AGENTS)改动可以直接 push
- 推送命令见 MAINTENANCE.md(本机 socks5h 代理 + 显式 credential.helper)

## 3. 其他既有硬规则 (详见 MAINTENANCE.md)

- **每次维护/更新脚本, 推送前必须完整测试已装代理的可用性**:至少覆盖
  服务 active、REALITY 握手 (Verify return code: 0)、socks5 实测连通
  (curl --proxy 204)、菜单 7 链接生成正确——只跑 bash -n / 静态检查不算测过
- 改 install.sh 必须手动递增 `SCRIPT_VERSION`(菜单 14 版本对比唯一依据)
- **改任何配置模板必须同步登记迁移补丁**(菜单 15 机制):在 MIGRATIONS 数组
  追加 "版本|函数|描述" 并实现幂等迁移函数, 保证已安装机器跑一次菜单 15 就能追平
- 在用户 VPS 上测试后必须把改动的配置恢复原样
- 链接生成一律从实际配置文件现场生成, 不信任 INFO_FILE/URL_FILE 历史值
- 五个配置模板的 freedom outbound `domainStrategy: UseIPv4` 不可丢失
- sed -i 改配置后必须补 `fix_config_perm` 属组修正
