# rc.3 桌面包 DevTools console 报错审计（活体捕获 + 逐条归因 + 零报错方案）

- 调研时间：2026-11-14 16:37–17:20（Asia/Shanghai），调研人：console-analyst（Team Lead 调研员）
- 被审计对象：
  - **旧包**：已安装 rc.1 `deepseek-harness-desktop-linux 0.2.2rc1-1`，`/opt/deepseek-harness-desktop/`（`@deepseek-ai/dsh-desktop 0.2.2-rc.1`，Electron 44.7.0 / Chrome 152.0.7977.130）
  - **新包**：Lead 当日构建成功的 rc.3 Linux 未打包产物 `.../p1-check2/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked/`（`@deepseek-ai/dsh-desktop 0.2.2-rc.3`，Electron 44.7.0 / Chrome 152.0.7977.130），下文简称 `$U`
- 复现骨架：`tools/console-audit/`（本报告配套 harness，无第三方依赖）
- 原始证据目录（`console.jsonl`/`summary.*`/`meta.json` 等已提交到仓库；`app-stdout.log`/`app-stderr.log`/`audit.log`/`dsh-web-*.log` 因工作区 `.gitignore` 的 `*.log` 规则不入库，仅保留在本地产物中）：
  - rc.1 fresh：`tools/console-audit/out/20261114-165438-rc1-fresh/`
  - rc.1 + 克隆用户 profile：`tools/console-audit/out/20261114-165108-profile/`（另有一次 16:47 的 75s 长跑 `20261114-164744-profile/`）
  - rc.3 fresh：`tools/console-audit/out/20261114-165202-rc3-fresh/`
  - rc.3 + 克隆用户 profile：`tools/console-audit/out/20261114-165253-rc3-profile/`
- 历史材料：`~/.config/@deepseek-ai/dsh-desktop/logs/crash-2026-11-13T13-17-02-771Z-web-boot.log`（rc.1，2026-11-13，54 行 error 级 console）

---

## 0. 结论先行

1. **新 rc.3 包在“全新默认 profile”下 console error = 0**（两次场景：欢迎页 + 应用着陆页，仅 4 条 info 事件，无 warning/error；DOM probe 证明页面完整渲染）。该结论只覆盖“未登录、无工作区”的引导路径——fresh profile 没有凭据，本次未能进入工作区。
2. **新 rc.3 包 + 复制当前用户 profile 时出现 20 条 console error，全部可归因，且不是 rc.3 新增**：
   - **19 条** `WebSocket connection to 'ws://127.0.0.1:9231/ingest' failed:` —— 官方 `experimental-inspector`（实验性 Inspector，用户 profile 主动启用了 `@deepseek-ai/dsh-experimental-inspector-profile` bundle）。根因：桌面 renderer 的 origin 是 `dsh-app://app`，而 Inspector ingest 的 `authorizedClient()` 只放行 loopback hostname 或显式 `clientOrigins`（默认空数组）→ 握手被拒，客户端 250ms→5s 无限重连并每次 `console.error`。**rc.3 未修复**（源码与 rc.1 相同，且活体复现）。
   - **1 条** `[deepseek-account] account read failed {field: profile}` —— 官方 base 客户端 `ui-settings-account` 在平台账户 profile 读取失败时打印 error（余额读取未报错）。11-13 历史日志同样出现，rc.3 复现，**rc.3 未修复**；UI 影响 benign（头像/资料降级），但级别是 error。
3. **11-13 历史崩溃日志里 54 行 error 中占比最大的 `useNode is not defined`（34 行）已确证来自用户自建插件 `@local/dsh-typewriter-terminal`**，不是官方代码：崩溃报告根因是 `@local/dsh-typewriter-terminal: import failed`；该脚手架 URL 的 V8 Code Cache（userData 内 4 个 `Code Cache/js/*`）常量池里同时含 `useNode`、`AssistantRow`、`NodeRow`、`createTerminalView`、`PlainTyped`、`MarkdownTyped`；rc.1 asar 中 9 处 `useNode` 全部是第三方库（Lezer `useNode(e,t)`、Lighthouse），rc.3 源码 0 处。当前 profile 已不含该插件 → 活体不再复现。
4. **达到“新包零 error”的最小集合**：
   - 默认/全新 profile：**已达成**（0 error）；
   - 用户现有 profile：必须修 **FIX-1（Inspector desktop origin 白名单）** + **FIX-2（account profile 读取失败降级/修复）**；或用户在 profile 侧移除 `@deepseek-ai/dsh-experimental-inspector-profile`（U-1）后只剩 FIX-2。
   - `ResizeObserver loop`（历史 14 行）是 Chromium 浏览器级 benign 通知，rc.1/rc.3 应用源码 0 命中，本轮新包未复现；不应作为门槛，也不建议在应用层“修”。
5. **纪律确认**：全程未 kill/重启/attach 用户运行中的实例（PID 4821/5144，未受影响）；测试实例按 `setsid` 进程组精确结束；顺序执行、未同时开两个测试实例；`/opt`、真实 `~/.dsh` 未修改（profile 只读复制）；`/tmp` 已清理。

---

## 1. 方法、隔离与证据通道

### 1.1 为什么不是“看崩溃日志”
崩溃日志只在应用 fatal 时写出，且只保留 error 级 console 的**尾部**；要拿到当前真实 console，必须给测试实例加 CDP。

### 1.2 隔离启动（不影响运行中实例）
harness 每次启动都会：
1. `mkdtemp('/tmp/dsh-console-audit-XXXX')` 造临时根；
2. **假 HOME**（`HOME=<tmp>/home`，并重设 `XDG_CONFIG_HOME/XDG_DATA_HOME/XDG_STATE_HOME/XDG_CACHE_HOME`）：Electron 的 userData（`~/.config/@deepseek-ai/dsh-desktop`）、图标同步、原生缓存等全部落到临时目录；单实例锁天然不冲突；
3. 临时 `DSH_HOME`：fresh = 空目录；profile = 只读复制真实 `~/.dsh` 的 `profiles/ local-bundles/ sessions/ storages/ archive/ llm-deepseek/ skills/ data/` 与少量配置/凭据文件（跳过 `attachments/ dsh-runtimes/ cache/ logs/` 共约 1.35GB），复制件内指向 `~/.dsh` 的绝对软链改写回复制件；
4. 清掉从当前会话继承的 `DSH_*` 环境变量（`DSH_SHELL=1`、`DSH_PROFILE_DIR=…`、`DSH_WEB_URL=…`、`DSH_SESSION_ID=…` 若不清理会让测试实例读到真实 profile/端口，首次联调时确曾造成行为不一致）；
5. 随机空闲 CDP 端口；rc.1 通过包装器 `DSH_DESKTOP_EXTRA_FLAGS` 追加 `--remote-debugging-port/--user-data-dir`，rc.3 未打包产物直接在 argv 显式传 `--no-sandbox --ozone-platform=wayland --remote-debugging-port --user-data-dir`；
6. `spawn(..., { detached: true })` 建立独立进程组；结束时 `SIGTERM → wait → SIGKILL` 打向 `-pgid`，最后用 `ps -o pid= -g <pgid>` 兜底精确清理残留成员。**不使用 `pkill -f`**。

### 1.3 捕获通道（双通道交叉校验）
- **CDP（主通道）**：`Target.setDiscoverTargets(true)` + `Target.setAutoAttach({autoAttach:true, waitForDebuggerOnStart:true, flatten:true})`，在 renderer 首条脚本执行前接管；每个 target attach 后立即 `Runtime.enable / Log.enable / Console.enable / Page.enable` 再 `Runtime.runIfWaitingForDebugger`。记录 `Runtime.consoleAPICalled`、`Runtime.exceptionThrown`、`Log.entryAdded`，每条带 `tMs / targetUrl / targetType / sourceId:line`。
- **stderr（校验通道）**：`ELECTRON_ENABLE_LOGGING=1` 把 renderer console 同时写入 `app-stderr.log` 的 `CONSOLE` 行；与 CDP 逐条对照。
- **捕获管道自检**（先证明“能抓到”再相信“0 报错”）：在测试页面注入
  `console.error/info/warn('SYNTH-*') + setTimeout(()=>{throw new Error('SYNTH-THROW')})`，
  CDP 收到 3×consoleAPICalled + exceptionThrown（每页面各一份，重复是双页面），stderr 同样出现 `SYNTH-ERR/INFO/WARN/Uncaught Error: SYNTH-THROW` —— 证明两种通道都有效。
- **页面存活 probe**：捕获结束时对每个 page session 执行 `Runtime.evaluate` 取 `{href,title,ready,body.innerText}`，证明窗口不是被 debugger 冻结的空壳（fresh 抓到欢迎页 + 着陆页 DOM；profile 抓到“已登录 DeepSeek / main / 选择工作区”等 DOM）。

### 1.4 harness 用法（详见 `tools/console-audit/README.md`）
```bash
cd /home/Arch/工作区

# 旧 rc.1
node tools/console-audit/console-audit.mjs --tag rc1 --scenario fresh   --duration 40
node tools/console-audit/console-audit.mjs --tag rc1 --scenario profile --duration 60 --interact

# 新 rc.3 linux-unpacked（无包装器，脚本显式传 Chromium flags）
U=/home/Arch/dsh-builds/rc3-wayland/p1-check2/apps/desktop/.desktop-build/targets/linux-x64/unsigned-artifacts/linux-unpacked
node tools/console-audit/console-audit.mjs --app-root "$U" --tag rc3 --scenario fresh   --duration 45
node tools/console-audit/console-audit.mjs --app-root "$U" --tag rc3 --scenario profile --duration 60 --interact

# 重新汇总已有产物
node tools/console-audit/summarize.mjs tools/console-audit/out/20261114-165253-rc3-profile
```
关键环境变量（脚本自动设置）：`HOME=<tmp>/home`、`DSH_HOME=<tmp>/dsh-home`、`TMPDIR=<tmp>/tmp`、
`DSH_DESKTOP_EXTRA_FLAGS="--remote-debugging-port=<port> --user-data-dir=<tmp>/userdata"`（仅 rc.1 包装器路径）、`ELECTRON_ENABLE_LOGGING=1`。
清理：脚本退出前删除 `/tmp/dsh-console-audit-*`，并把 `console.jsonl / summary.json|md / app-stderr.log / dsh-web-boot.log / dsh-web-config.log / meta.json / audit.log` 落盘到 `tools/console-audit/out/<时间戳>-<tag>-<scenario>/`。
`--interact` 会在启动约 18s 后点一次侧栏 `[role="treeitem"]`（两次 profile 运行都成功点到），用于触发“打开会话”路径。
`--keep-tmp` 保留临时根便于排障（本次未使用，全部已清理）。

---

## 2. 场景 A：fresh profile（空 DSH_HOME）

### 2.1 新 rc.3 包（结论：0 error / 0 warning）
产物：`out/20261114-165202-rc3-fresh/`，捕获 45s，CDP 端口 46209。

| 级别 | 次数 | 归一化消息 | 首现 | 备注 |
| --- | --- | --- | --- | --- |
| error | **0** | — | — | — |
| warning | **0** | — | — | — |
| info | 4 | `target-attached page dsh-app://app/`；`target-attached page …/renderer/welcome.html`；2× `probe …` | 0.4s / 1.5s / 末 | 非报错，harness 自身标记 |

DOM probe（证明真的渲染完成）：
- `dsh-app://app/`：`{"ready":"complete","title":"DeepSeek Harness","body":"新会话 … 工作区 暂无会话 … 选择工作区 标准模式 选择一个工作区开始"}`
- `…/resources/app/renderer/welcome.html`：`{"ready":"complete","body":"欢迎使用 DeepSeek Harness / 组装无限可能，共探智能上限 / 登录 / 添加 API Key"}`

### 2.2 旧 rc.1 包（对照：同样 0 error / 0 warning）
产物：`out/20261114-165438-rc1-fresh/`，40s，同样只抓到 `target-attached`×2 + `probe`×2，无任何 error/warning。
→ “fresh profile 安静”不是 rc.3 修出来的，两个版本欢迎路径本来就干净；**新包默认 profile 的零 error 目标在引导路径成立**。

---

## 3. 场景 B：复制当前用户 profile（`~/.dsh` 克隆，只读来源）

### 3.1 新 rc.3 包：20 error（19 + 1，两类）
产物：`out/20261114-165253-rc3-profile/`，捕获 60s，CDP 端口 43965，进程为 `$U/deepseek-harness --no-sandbox …`。
DOM probe：`dsh-app://app/` ready=complete，body 含「已登录 DeepSeek / 工作区 main / 选择工作区」；`--interact` 点击 `[role="treeitem"]` 成功（未产生新 console 错误）。

| # | 级别 | 次数 | 首现 | 归一化消息 | source（bundle URL 尾行号） |
| --- | --- | --- | --- | --- | --- |
| 1 | error | **19** | +2893ms | `WebSocket connection to 'ws://127.0.0.1:9231/ingest' failed:` | plugins bundle（含 `@deepseek-ai/dsh-experimental-inspector/client.js`）:61 |
| 2 | error | **1** | +3126ms | `[deepseek-account] account read failed {field: profile}` | `@deepseek-ai/dsh-client-ui-settings-account/client.js`…:22 |

重连节奏（证据：`console.jsonl` 的 tMs）：`2.9, 3.2, 3.5, 4.0, 6.0, 8.9, 13.4, 17.8, 21.9, 26.8, 31.5, 36.4, 40.6, 44.4, 47.1, 51.5, 55.9, 60.1, 64.6 …` —— 前密后疏（≈250ms→5s 封顶），**永不成功、永不停止**，与“握手被拒也不降级”一致。

### 3.2 旧 rc.1 包：17～22 error（同类两类，端口号随当前环境变化）
产物：`out/20261114-165108-profile/`（45s，端口 9232）：16× ingest + 1× account = **17 error**；
另一次 75s 长跑 `out/20261114-164744-profile/`：21× ingest + 1× account = **22 error**（时长更长、重试更多）。
`--interact` 同样点到 `[role="treeitem"]`，未触发新的 console 错误。

### 3.3 端口号 9231/9232 的由来（多实例环境变量，不是根因）
- 用户运行中的 rc.1 实例（Host PID 5144）监听 `127.0.0.1:9230`（Inspector 默认端口）。
- rc.1 那次 run 时 9231 还被另一测试实例占用（`ss -ltnp` 抓到），Inspector worker 从 9230 起“占用就 +1” → 落到 **9232**；
- rc.3 那次 run 时 9231 空闲 → 落到 **9231**。
- 两个端口上的握手都被同一原因拒绝（见 §5 归因），说明**不是端口冲突本身**；端口冲突只影响“哪个端口失败”。

---

## 4. 历史材料：rc.1 崩溃日志（2026-11-13，54 行 error console）

文件：`~/.config/@deepseek-ai/dsh-desktop/logs/crash-2026-11-13T13-17-02-771Z-web-boot.log`
应用：`@deepseek-ai/dsh-desktop 0.2.2-rc.1`，source=`web-boot`，shell pid 96810。

崩溃主错误（第 11–16 行）：
```
Error: web boot: 1 entry did not activate
@local/dsh-typewriter-terminal: import failed: client-modules: could not load "@local/dsh-typewriter-terminal": plugins/??…（官方插件 bundle 列表）…
    at file:///opt/deepseek-harness-desktop/resources/app.asar/lib/main.js:21287:15
```

`--- renderer console (error level, oldest first) ---` 段（第 19–72 行，54 行）分解：

| # | 消息（归一化） | 次数 | 首次行号 | 归因 |
| --- | --- | --- | --- | --- |
| 1 | `…slot entry crashed in 'conversation.view': ReferenceError: useNode is not defined`（来源为 plugins bundle URL，含 `@local/dsh-typewriter-terminal/client.js`） | 17 | 20 | 用户插件 |
| 2 | `dsh-app://app/assets/index-BgUyXZcc.js:59 ReferenceError: useNode is not defined`（同上成对输出） | 17 | 19 | 用户插件 |
| 3 | `ResizeObserver loop completed with undelivered notifications.` | 14 | 53 | Chromium benign |
| 4 | `Sidebar Session opening failed: Error: Session reference "session-f5afecd4-…" is released` | 2 | 60 | 官方竞态（未修） |
| 5 | `[deepseek-account] account read failed [object Object]` | 2 | 67 | 官方错误路径（未修） |
| 6 | `dsh-app://app/assets/index-BgUyXZcc.js:196 Error: web boot: 1 entry did not activate` | 1 | 12 段内 | 官方上报（触发=用户插件坏） |

辅助证据：同一日志的 plugin operation history 里 `@local/dsh-typewriter-terminal` 被反复 enable/disable（含 6.9.0）；崩溃日志的 console 行 URL 里出现 `@local/dsh-typewriter-terminal/client.js` 6 次、`@local/dsh-live-expand/client.js` 2 次；当前 profile（`~/.dsh/profiles/desktop/package.json`，18 个 bundle）与 `~/.dsh/local-bundles/` 均已不含这两个 `@local` 插件（仅 linux-pkg-maintainer/media-pipeline/paper-radar/yolo），残留物只有 `~/.dsh/live-expand.json` 和 `~/.cache/dsh-live-expand/report.json`（后者记录 `plugin:@local/dsh-live-expand v2.0.1`）。

---

## 5. 逐条归因表（事实 / 推断 已标注）

| # | 错误（归一化） | 出现场景 | 级别×次数 | 归属 | 证据 | rc.3 是否已修 |
| --- | --- | --- | --- | --- | --- | --- |
| E1 | `WebSocket connection to 'ws://127.0.0.1:<9230+>/ingest' failed:` | rc.1 profile 16/21；rc.3 profile 19；fresh 0 | error | **官方 bug**（实验性 Inspector）+ 用户 profile 启用该实验 bundle | 事实①：两版 Inspector 配置默认 `port:9230`、`clientOrigins:[]`（rc.1 asar `…/dsh-experimental-inspector/lib/index.js` `port: z.natural().max(65535).default(9230)`；rc.3 `packages/experimental/inspector/src/index.ts` 同默认）；事实②：worker `authorizedClient()` 只放行“protocol token + origin 为 loopback hostname 或 clientOrigins 成员”（rc.1 `lib/worker.js`，rc.3 `src/worker/bridge/endpoint.ts:219`）；事实③：desktop renderer 页面 origin 实测为 `dsh-app://app`（probe `location.href=dsh-app://app/`），hostname=`app` 既非 loopback 也不在白名单；事实④：rc.1/rc.3 桌面主进程均无 `clientOrigins`/desktop origin 注入（rc.1 `lib/main.js` 全文无 inspector 字样；rc.3 `apps/desktop/src` 无 clientOrigins 配置）；事实⑤：端口已成功避让（9232/9231）仍持续失败。**推断**：握手被 403 拒绝，浏览器只报 "connection failed"，故无 error detail。 | **否**（rc.3 源码同构，活体复现） |
| E2 | `[deepseek-account] account read failed {field: profile}` | rc.1 profile ×1；rc.3 profile ×1；历史 ×2 | error | **官方 base 客户端**；触发条件=平台 profile API 读取失败（余额读取未报错） | 事实①：rc.3 `packages/client/ui-settings-account/src/client/index.ts:72-78` `if (value?.status === 'failed') console.error('[deepseek-account] account read failed', { field })`（rc.1 同）；事实②：host 侧 `packages/credentials/deepseek-account/src/index.ts:228 getProfile()` → `getDetail('profile')` 失败时返回 `{status:'failed'}`（余额走 `getBalance`，未失败）；事实③：11-13 历史日志同样有 2 条，说明不是本次测试独有。**未完全定因**：平台 HTTP 失败状态未在 host 侧留证（见 §8）。 | **否** |
| E3 | `ReferenceError: useNode is not defined`（含 `slot entry crashed in 'conversation.view'`） | 仅历史 11-13（17 对/34 行） | error | **用户自建插件 `@local/dsh-typewriter-terminal`**（另有 `@local/dsh-live-expand` 同批启用） | 事实①：崩溃根因 `@local/dsh-typewriter-terminal: import failed`；事实②：console 来源 URL 含 `@local/dsh-typewriter-terminal/client.js`；事实③：userData `Code Cache/js/` 有 4 个 V8 Code Cache 文件，其源 URL 为 `dsh-app://app/plugins/??@local/dsh-typewriter-terminal/client.js&rev=…`，常量池含 `useNode / AssistantRow / NodeRow / createTerminalView / PlainTyped / MarkdownTyped / userText / assistantParts / toolLine`；事实④：rc.1 asar 的 9 处 `useNode` 命中全部为第三方库（Lezer 的 `useNode(e,t)` 方法、Lighthouse DevTools 的 `__lighthouseNodesDontTouchOrAllVarianceGoesAway`），rc.3 官方源码 0 命中；事实⑤：当前 profile 已无该插件 → 活体复现 0 次。**推断**：插件内 `useNode(...)` 为未定义/未导入的裸标识符（或引用被拆到未成功加载的 chunk），且插件本身 import 失败。 | 不适用（用户插件） |
| E4 | `ResizeObserver loop completed with undelivered notifications.` | 仅历史 11-13（14×） | error | **Chromium 浏览器 benign** | 事实：rc.1 asar 检索 `ResizeObserver loop` = 0 命中，rc.3 源码 = 0 命中；该文案由 Blink ResizeObserver 机制在“同一帧内二次布局”时发出；本轮 rc.1/rc.3 两个场景均未复现。 | 不适用（非应用代码） |
| E5 | `Sidebar Session opening failed: Error: Session reference "…" is released` | 仅历史 11-13（2×） | error | **官方客户端竞态**（未修） | 事实①：rc.3 `packages/client/ui-sidebar-right/src/client/session-view.ts:34` `void this.reference.ready.catch(error => console.error('Sidebar Session opening failed:', error))`；事实②：rejection 文案来自 rc.3 `packages/api/session-controller/src/client/sessions/service.ts:213/235`（`throw new Error('Session reference "…" is released')`）；事实③：rc.3 仍保留该 console.error 点；本轮 `--interact` 点击侧栏未复现（旧会话状态已不存在）。 | **否**（预防性修复见 FIX-3） |
| E6 | `web boot: 1 entry did not activate`（error 级） | 仅历史 11-13（1） | error | 官方 boot 上报 + **触发源=用户插件 import 失败** | 事实：rc.3 `packages/client/web/src/boot-client.ts:130` 在 required entries 未激活时 `throw new Error('web boot: … did not activate')`（error 级；optional 失败仅 warn，见 :133）。当 profile 里存在坏插件时 error 级上报是设计内行为。 | 不适用（用户插件） |

---

## 6. 零报错修复清单

### 6.1 新包（rc.3 → 后续版本）应修的官方问题

**FIX-1（必须，解决 19 条/会话 E1）：让桌面 renderer 能连上 Inspector ingest**
- 位置：
  - `packages/experimental/inspector/src/index.ts`（`Config.clientOrigins` 默认 `[]`）
  - `packages/experimental/inspector/src/worker/bridge/endpoint.ts:219 authorizedClient()`（origin 白名单）
  - 桌面侧注入点：`apps/desktop/src/main.ts` / `apps/desktop/src/web-document.ts`（rc.3 均无 clientOrigins 注入）
- 最小补丁思路（三选一，推荐 A）：
  - **A. 桌面场景注入 `clientOrigins: ['dsh-app://app']`**：在 desktop 启动 Host 前把桌面 origin 传给 Host（`DSH_DESKTOP_…` 环境变量），或在 desktop 加载 `dsh-experimental-inspector-profile` 时用 profile patch/overlay 覆盖 `experimental-inspector.config.clientOrigins=[dsh-app://app]`；同时保留 loopback 白名单给浏览器 DevTools 使用。
  - B. 桌面端不启动 in-app Inspector client（保留 9230 的 CDP HTTP 端点给外部 DevTools），即 desktop profile 默认不启用 `experimental-inspector` 的 client 注入。
  - C. 客户端重连降级：`packages/experimental/inspector/src/client/…` 连续握手失败（如 ≥3 次）后停止重连并把日志降到 `console.debug/warn`；这只能“消音”，不解决功能。
- 预期：E1 的 19 条 error 归零，`http://127.0.0.1:9230` 的 Inspector/CDP 能力对 `dsh-app://` 页面恢复正常。

**FIX-2（必须，解决 1 条 E2）：account profile 读取失败不应是 error 级**
- 位置：`packages/client/ui-settings-account/src/client/index.ts:72-78`。
- 最小补丁：`read('profile', …)` 的失败日志从 `console.error` 降为 `console.warn`（或加一次静默重试/退避后再决定级别），UI 继续走“资料不可用”降级；同时另立 issue 追根因——`packages/credentials/deepseek-account/src/index.ts:228 getProfile()` 对平台 `/profile` 的调用为何失败（需 host 侧记录 HTTP 状态/错误码，rc.3 桌面 Host 未写 `DSH_HOME/logs`，本次拿不到）。
- 预期：E2 不再以 error 形式出现（若根因修复则彻底消失）。

**FIX-3（预防，E5）：released 引用不应打成 error**
- 位置：`packages/client/ui-sidebar-right/src/client/session-view.ts:34`（catch 回调）。
- 最小补丁：识别“session reference released”（错误文案/错误码，或订阅 reference 生命周期），视为正常 teardown 直接返回；其余错误仍 `console.error`。或由 `session-controller` 对已释放 reference 的 `ready` 返回可被调用方区分的 benign rejection。
- 预期：E5 类竞态不再污染 console error；功能不受影响。

**FIX-4（可选，E6）**：`packages/client/web/src/boot-client.ts:130` 对“第三方插件导致的 required entry 失败”是否要 error 级，可讨论；语义上 required 失败确实应突出，不建议屏蔽，建议由用户侧修插件（U-2）。

**明确不修（benign）**：E4 `ResizeObserver loop…` 由 Blink 发出，应用无法可靠消除；保持过滤/忽略即可，不应计入零-error 门槛。

### 6.2 用户 profile 侧修复建议（与“新包必须修”分开）

- **U-1（可立即把用户 profile 的 error 从 20 降到 1）**：在 `~/.dsh/profiles/desktop/package.json` 的 `dsh.profile.bundles` 中移除 `@deepseek-ai/dsh-experimental-inspector-profile`（它引入 experimental-inspector / session-inspector / client-ui-stats；当前 profile 18 个 bundle 中含它），并在插件管理/`cordis.patch.yml` 里禁用残留条目；代价是失去 in-app Inspector + 会话检查器面板。若仍需要 CDP，可继续用 `http://127.0.0.1:9230`（Host CDP 端点，不依赖该 client ingest）。
- **U-2（历史 useNode 根因）**：不要重新启用旧版 `@local/dsh-typewriter-terminal` / `@local/dsh-live-expand`（`useNode` 未定义 + import 失败）；如需要该功能，先修插件的 import/标识符（或重写为官方 client 插件导出形式）再安装。当前 `~/.dsh/local-bundles/` 已无这两个目录，残留 `~/.dsh/live-expand.json`、`~/.cache/dsh-live-expand/report.json` 可清理（不影响 console）。
- **U-3（无法用户侧修复）**：E2 account read failed 属官方 base bundle，用户无法卸载；只能等 FIX-2。E5 同理。

### 6.3 “新包零 error”验收口径建议
| 场景 | 当前实测 | 达标所需 |
| --- | --- | --- |
| rc.3 默认/全新 profile（未登录，引导路径） | **0 error / 0 warning** ✅ | 保持即可；发布前 CI 可用本 harness 跑 `--scenario fresh` 做 gate |
| rc.3 + 用户现有 profile（登录态） | 20 error（E1×19 + E2×1） | FIX-1 + FIX-2；或 U-1（去 inspector）+ FIX-2 |
| rc.3 + 任意 profile（历史遗留坏插件） | 若用户装坏插件仍会有 E3/E6 | 归用户侧（U-2）；新包不背此锅 |

---

## 7. 未解决项 / 复现限制（事实与推断分开）

1. **E2 根因未闭环**：只确证“平台 profile 读取失败 → 官方客户端打 error”，未拿到 host 侧 HTTP 状态/错误体。rc.3 桌面 Host 在测试实例的 `DSH_HOME/logs/` 下没有写日志（artifacts 无 `host-log-*`）；要闭环需在 Host 侧临时打点或抓包——本次未做（避免修改 /opt 与真实环境）。
2. **E5 未活体复现**：`Session reference released` 依赖特定会话生命周期（旧 session-f5afecd4 已释放并归档），本轮 `--interact` 点击侧栏未触发；FIX-3 是源码级修复建议，未做补丁验证。
3. **E3 无法做“修好插件后验证”**：旧插件源码已从磁盘删除（`~/.dsh/local-bundles`、会话/缓存均无源码），只能凭崩溃日志 + V8 Code Cache 归因；“useNode 具体缺哪个 import”无法还原。
4. **fresh 场景覆盖面**：空 DSH_HOME 无凭据 → 只到欢迎页/“选择工作区”，未进入工作区；因此“全新默认 profile 零 error”仅覆盖引导路径。要覆盖登录后默认工作区，需要官方默认 profile + 有效凭据（本次用“复制用户 profile”替代，而用户 profile 自带实验 bundle，噪声不同源）。
5. **单实例首启时 Inspector ingest 是否也失败**：无法在“真实实例占用 9230”的前提下验证真正首启；但 E1 在 9231/9232 两个不同端口都失败，且源码显示 origin 校验与端口无关，因此“与多实例无关、属 origin 白名单问题”是**高置信推断**而非握手级实证（缺 403 响应抓包）。
6. **CDP 早期消息**：auto-attach 于 renderer 首条脚本前接管（waitForDebuggerOnStart）并 probe 验证页面存活；stderr 通道与 CDP 计数一致（E2 1:1；fresh 0:0），未发现漏抓迹象；但“窗口创建最初数十毫秒”的主进程日志不在 renderer console 范畴，未纳入本表。
7. **ResizeObserver**：本轮 rc.1/rc.3 均未出现，无法判断新包是否仍会偶发；作为 Chromium benign 记录，不做门槛。

---

## 8. 证据附录（命令 + 输出摘要）

### 8.1 环境与版本
```bash
$ cat /opt/deepseek-harness-desktop/resources/app/package.json | head -4   # @deepseek-ai/dsh-desktop 0.2.2-rc.1
$ cat $U/resources/app/package.json | head -4                             # @deepseek-ai/dsh-desktop 0.2.2-rc.3
$ ss -ltnp | grep -E ':(92[0-9][0-9]|3719[0-9])'                          # 真实实例: 127.0.0.1:9230(Host 5144), :37191
$ curl -s http://127.0.0.1:<cdp>/json/version                             # Chrome/152.0.7977.130, Protocol 1.3
```
测试实例 cmdline（证明隔离生效）：
```
/usr/bin/deepseek-harness → /opt/…/deepseek-harness --disable-features=Vulkan --enable-features=WaylandLinuxDrmSyncobj \
  --remote-debugging-port=<rand> --user-data-dir=/tmp/dsh-console-audit-*/userdata
$U/deepseek-harness --no-sandbox --ozone-platform=wayland --remote-debugging-port=<rand> --user-data-dir=/tmp/dsh-console-audit-*/userdata
```
隔离断言：`ps -eo pid,args | grep dsh-console-audit` 的 `DSH_HOME`/`userData` 全部在 `/tmp/dsh-console-audit-*`；真实实例 PID 4821/5144 全程未变（启动前后 `ps` 一致）。

### 8.2 四个场景的关键原始行
- rc.1 fresh（`out/20261114-165438-rc1-fresh/console.jsonl`）：4 行，全 `info`（2×target-attached + 2×probe）。
- rc.1 profile（`out/20261114-165108-profile/console.jsonl`）：
  - `{"tMs":2946,"kind":"log","level":"error","text":"WebSocket connection to 'ws://127.0.0.1:9232/ingest' failed: "…}`
  - `{"tMs":3120,"kind":"console","level":"error","text":"[deepseek-account] account read failed {field: profile}"…}`
- rc.3 fresh（`out/20261114-165202-rc3-fresh/console.jsonl`）：4 行 info；probe body 见 §2.1。
- rc.3 profile（`out/20261114-165253-rc3-profile/console.jsonl`）：19× ingest(9231) + 1× account；probe body 见 §3.1。
- 历史崩溃日志：`grep -n 'slot entry crashed\|index-BgUyXZcc.js:59\|ResizeObserver loop\|Sidebar Session opening failed\|account read failed\|web boot'` →
  `19/20` useNode 成对行、`53` ResizeObserver、`60` Sidebar、`67` account、`12` web boot；段内合计 54 行。
- useNode 溯源：
```bash
$ grep -a -c 'useNode' /opt/…/resources/app.asar        # 9（全部 Lezer/Lighthouse，见上下文）
$ grep -rn 'useNode' --include='*.ts' --include='*.tsx' $RC3_SRC | wc -l   # 0
$ python3: 4 个 Code Cache/js 文件的源 URL = dsh-app://app/plugins/??@local/dsh-typewriter-terminal/client.js&rev=…
  常量池含 useNode/AssistantRow/NodeRow/createTerminalView/PlainTyped/MarkdownTyped
```

### 8.3 关键源码定位（rc.3 源码树 `/home/Arch/dsh-builds/rc3-wayland/src`）
| 主题 | 文件:行 |
| --- | --- |
| Inspector 默认端口 9230 / clientOrigins 空 | `packages/experimental/inspector/src/index.ts:76-77`（`port: z.natural().max(65_535).default(9_230)`、`clientOrigins: z.array(z.string()).default([])`） |
| ingest 鉴权/来源校验 | `packages/experimental/inspector/src/worker/bridge/endpoint.ts:219 authorizedClient()`（token + origin ∈ clientOrigins 或 loopback hostname） |
| account 失败日志 | `packages/client/ui-settings-account/src/client/index.ts:72-78` |
| account host getProfile | `packages/credentials/deepseek-account/src/index.ts:228` |
| Sidebar released 日志点 | `packages/client/ui-sidebar-right/src/client/session-view.ts:34` |
| released 异常抛出 | `packages/api/session-controller/src/client/sessions/service.ts:213,235` |
| web boot 未激活上报 | `packages/client/web/src/boot-client.ts:130`（required 失败 throw）/:133（optional 失败 warn） |
| 桌面 shell 无 Inspector origin 注入 | `apps/desktop/src/main.ts`、`apps/desktop/src/web-document.ts`（grep `inspector|clientOrigins` 无命中） |

### 8.4 harness 自检（证明“0 报错”不是抓不到）
- 对测试页面执行 `console.error('SYNTH-ERR'); console.info('SYNTH-INFO'); console.warn('SYNTH-WARN'); setTimeout(()=>{throw new Error('SYNTH-THROW')},100)`：
  CDP 收到 `SYNTH-ERR/SYNTH-INFO/SYNTH-WARN/Error: SYNTH-THROW`（两页面各一份）；stderr 同步出现 `INFO:CONSOLE:1] "SYNTH-ERR"…` 与 `Uncaught Error: SYNTH-THROW`。

---

## 9. 给 Lead 的一句话总结

**新 rc.3 包 fresh profile 已 console 零 error；复制用户 profile 的 20 条 error 全部来自两个官方缺陷（实验 Inspector 的 `dsh-app://app` origin 被拒 ×19、account profile 读取失败上报 ×1），rc.3 均未修复；11-13 历史 54 行里的 useNode 已确证为用户插件 `@local/dsh-typewriter-terminal`，当前 profile 不含、不再复现。**
