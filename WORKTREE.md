# SillyClient 工作树规约：iOS 主力发布加固与 NodeMobile 运行时守护 (Release Hardening iOS)

> **[LTS 核心工作树]** 本文档为该工作树的自包含边界与记录中枢。本树所有进行中改动、调试日志与设计草稿就地记录在此，严禁向中央本地目录散落碎片文档。

---

## 1. 职责与范围边界 (Scope & Boundaries)

- **所属仓库**: `SillyClient_iOS`
- **标识分支**: `lts/ios-release-hardening`
- **授权修改范围**:
  - `native-src/` 与 `ios/App/App/`：Swift 原生宿主、Capacitor 插件桥接、NodeMobile 进程监管、Documents 沙盒管理；
  - `web/capacitor-ui/`：iOS 适配前端与纯净界面布局；
  - `scripts/`：云真机探针、模拟器自动化、E2E 测试脚本；
  - iOS 编译、IPA 构建与发布打包流程。
- **严禁事项 (Forbidden Boundaries)**:
  - 严禁在 Xcode 工程与 `native-src` 之间制造代码分叉，任何原生改动必须严格双向同步；
  - 严禁引入不安全的非沙盒私有 API 或引入未授权付费模型接口；
  - 严禁擅改已冻结的原地接管（Takeover）防误删和 Keychain 凭据安全契约。

---

## 2. 核心架构契约 (Invariants & Constraints)

1. **单嵌入式 NodeMobile 进程模型**：遵循 `IOS-RUNTIME.md`，多实例共享一个宿主生命周期，单 Worker 执行；
2. **Documents 安全沙盒契约**：所有实例物理路径严格约束在合法作用域内，支持 Security-Scoped Bookmark 持久化授权；
3. **原生与 Xcode 工程 100% 镜像一致性**：`native-src` 与 `ios/App/App` 保持完全同步；
4. **全套自动化测试网全绿**：117 项 Node 测试、41 项前端单测与 `verify-ios-cloud.mjs` 全部 7 大套件 100% 通过。

---

## 3. 本树推进与改动记录 (Worktree Activity Log)

| 日期 | 操作人 / 提交 | 改动摘要与内部验证结果 | 状态 |
| :--- | :--- | :--- | :---: |
| 2026-10-09 | Agent (4ae7b82) | 预设扩展多镜像源加速与重试机制、config.yaml 默认开启服务端插件、全面清洗 Xcode 镜像分叉与测试后门、拔除悬空占位符 | 已提交 |
| 2026-10-11 | Agent | 严格遵循 LTS 规约设立独立工作树 `release-hardening-ios`，分支对齐至 `lts/ios-release-hardening`，完成依赖 Junction 挂载与全量测试验证 | 长期加固 |
| 2026-10-11 | Agent | 跨端通用前端 1.12.0 基准对齐（竖版 687×843 锁定缩放、连体沟槽轨、向导溶变遮罩、密码状态作废）、版本号升级至 1.12.0（Build 30）、41 项前端单测 + 116 项运行时测试 + verify-ios-cloud 7 大套件 100% 全绿 | 已提交 |
| 2026-10-12 | Agent | 跨端通用前端 1.12.1 基准同步（3张透明镂空封面资产引入、管理菜单卡片取消毛边遮罩改由容器 overflow 裁圆角、引入动态透明度感知 ManageInstanceCard 与背景色衬底）、版本号升级至 1.12.1（Build 31）、41 项前端单测 + 116 项运行时测试 + verify-ios-cloud 7 大套件 100% 全绿 | 待合流发布 |
| 2026-10-12 | Agent | 同步双端 1.13.0 契约：①安装源=创建意图铁律（createIntent 全链路：前端卡片剥离一次性安装源 + doLaunch 闸门 + 原生 prepare 拒静默重装顶替）；②迁移向导逐项容错（onFailure 不阻断）与标记语义修正（空结果写标记/异常与稍后再试不写）；③向导预填已登记存储根 + 安装目录必选拦截 + 创建成功登记存储根；④打通导出实例 ZIP 链路（存储路径页签新增导出行 + 原生运行态守卫）；⑤无默认路径契约对齐 Windows（getAppSettings 精简、AppSettingsDrawer 去默认档）；⑥拔除死代码：migrateLegacyInstances 四端全移除、3 份零引用 ios-loader.js 拷贝、IOSDebugHarness 白名单同步；版本升级 1.13.0（Build 32）、42 项前端单测 + 116 项运行时测试 + verify-ios-cloud 7 大套件 100% 全绿 | 待推送 |
| 2026-10-13 | Agent | 同步主仓通用前端新基线 `f0be259`（差量 667b83a..f0be259）：coverTone.ts 底板体系（白天 #fbfafc/黑夜墨色渐变/动态紫酒红中段）、InstanceCard/Carousel/StoppedCard 的 isDynamic 透传、ManageInstanceModal 大重构（ManageTabTrack、ManageItem isPortrait 化、motion-slot 保存键、封面底板接入）上回贴 iOS 增量（onPasswordMutationStart、isWindows 路径显示、导入/导出行、移动宿主文案）并恢复 Main 存储迁移行（修复 iOS 上搬迁入口不可达的断链）、switchThemeMode 双参 is-shedding 逻辑、黑夜玻璃底对齐 #1a1625/80、向导创建按钮验收色号；Build 33；42 前端单测 + 118 运行时测试 + verify-ios-cloud 7 套件全绿 | 待推送 |
| 2026-10-16 | Agent | 同步主仓通用前端 `55edc3b` 基线（差量 4f72f1b..04e695d，v1.13.0 发布版）：flat-capsule 按钮体系全端归一（16 个文件：8 个逐字节一致直拷 + CornerResizeCurve 新组件 + AppSettingsDrawer/ManageInstanceModal git-apply 直贴 + 9 个含平台逻辑文件手工移植）、遮罩关闭同步淡出（POPOVER_EXIT_MS 300）、删除进度条（DeleteConfirmDialog 新结构 + Web 演示 1.4s 模拟延迟）、设置行悬停（setting-row/label）、时钟胶囊 group 悬停；保留 iOS 全部平台接线（IME isComposing 守卫、InstanceAccessScope、迁移容错、存储三入口）；前端调色板静态断言同步更新；Build 34；42 前端单测 + 118 运行时测试 + verify-ios-cloud 7 套件全绿 | 已推送 |
| 2026-10-17 | Agent | 同步通用前端 `3f1c112`（差量 `55edc3b..3f1c112`）：新手引导 12 张当前界面图、顶栏小图按高度适配；终端去掉缩放柄并删除 `CornerResizeCurve`，顶栏与日志同一深色；动态壁纸拨杆收成 `52×32` / 拨杆 `24×24`，开态保留绿色自发光，缓存键 `toggle-glow1`。iOS 引导保留设置密码与存储权限步骤，迁移文案不写默认路径。Build 35。前端 build、42 项前端单测、118 通过 / 2 跳过运行时测试、verify-ios-cloud 7 套件全绿 | 待推送 |

---

## 4. 交付与推送门禁 (Milestone & Delivery Gate)

- **本地门禁**:
  1. `node scripts/verify-ios-cloud.mjs --mock-mode` 7 大套件 100% PASS；
  2. `node --test tests/*.test.mjs` 117 项全量通过（115 pass, 2 optional skip, 0 fail）；
  3. `node --test web/capacitor-ui/tests/*.test.cjs` 41 项单测 100% PASS。
- **中央登记协议**:
  - 本树过程记录就地沉淀在上方第 3 节；
  - **当且仅当向远端分支执行 `git push` 或产出正式 IPA 时**，才向 `Local/docs/CURRENT_STATE.md` 与 `.worktrees/README.md` 登记事实索引。
