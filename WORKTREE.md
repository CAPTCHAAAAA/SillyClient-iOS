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
| 2026-10-17 | Agent | 同步通用前端 `3f1c112`（差量 `55edc3b..3f1c112`）：新手引导 12 张当前界面图、顶栏小图按高度适配；终端去掉缩放柄并删除 `CornerResizeCurve`，顶栏与日志同一深色；动态壁纸拨杆收成 `52×32` / 拨杆 `24×24`，开态保留绿色自发光，缓存键 `toggle-glow1`。iOS 引导保留设置密码与存储权限步骤，迁移文案不写默认路径。Build 35 | 已推送（CI Run `38938203177` 模拟器 E2E 探针超时失败，构建本身 BUILD SUCCEEDED，属已知 VM 抖动） |
| 2026-10-17 | Agent | 同步通用前端 `bd45fb2`（差量 `3f1c112..bd45fb2`）：缩放手柄归位——新增重写版 `CornerResizeCurve`（`OUTSET 12`、静息 48°/热态 78°、四层弧线），终端回到 `ios-task-surface` 毛玻璃壳 + 内嵌日志井并挂回手柄，管理菜单改为外层全屏居中壳 + 内层设计帧 `zoom` 缩放并挂手柄，`styles.css` 补 `animate-manage-panel` 弹跳动画，`routes/index.tsx` 给终端补 `LayerBackdrop`。仅改前端，原生/Swift 未动；iOS 终端文案仍走 `iOS 控制台` / `ios >` / `iOS 进程内环境` 分支，无 Android shell 字样。版本 1.13.1（Build 36）。前端 build、42 项前端单测、118 通过 / 2 跳过运行时测试、verify-ios-cloud 7 套件全绿 | 已推送 `05fa50b`，CI Run `38976627615` 18m30s 全绿 |
| 2026-10-17 | Agent | 修终端提示符平台串台（`4d5e4e4`）：`terminalDisplayPrompt` 原先只在未选中实例时区分平台，选中 iOS 实例后会落回安卓那套 `~ $`；现统一走 `isWindows ? 路径提示符 : (isIOS ? "ios >" : "~ $")`。`tests/ios-runtime.test.mjs` 加静态断言守住。仅前端，原生未动；build、42 项前端单测、118 通过 / 2 跳过运行时测试、verify-ios-cloud 7 套件全绿 | 已推送，CI Run `38978480577` 出最终 1.13.1（Build 36）IPA |
| 2026-11-02 | Agent | 修复 iOS 用户反馈“只能浏览文件夹无法选择文件夹”缺陷（原生 `UIDocumentPickerViewController` 明确指定 `[.folder]` UTType、预建 Documents/instances 根、前端配置 `pathMode: "root"` 明确引导）；全面升级 CI/CD 流水线适配 macOS 15 与 Xcode 16.4 CoreSimulator（编译 `@rpath/libswiftWebKit.dylib` 消除 iOS 18 缺失符号崩溃、Ruby 动态修复 App 目标至 iOS 15、消除 `simctl launch` 120s 阻塞挂起）；已推送至远端 `lts/ios-release-hardening`（commit `6b91884`）；GitHub Actions Run `41339411594` 9m10s 100% 全绿（全部 18 步骤通过、22 阶段 E2E、45 组原生测试通过）；产出正规免签 IPA（SHA-256: `5d356a74242b41909a79f4aaccf045daf5ca1b0ec7aada3a1d2981532aa82729`，大小 194,041,253 字节），完整证据归档于 `Local/evidence/ios-run-41339411594`，正式 IPA 归档于 `Local/artifacts/v1.13.1/` | 已推送并100%绿通过 |
| 2026-11-02 | Agent | 同步变色龙沉浸式取色策略与点击光效自选设置：①前端控制台对齐 Android 交互（支持沉浸式取色开关、全时/单次取色模式切换与点击光效联动，取色关闭时禁用并联动关闭光效）；②原生端扩展 TarvenEnvPlugin（getRenderEngineSettings / setRenderEngineSettings）及 UserDefaults 持久化；③TavernViewController 实现低占用取色控制与单次取色防抖（单次取色首帧后 500ms 校准并停止探针，常态完全 0 采样；轻触光效联动 TopScrimBarView.sweepGloss）；④前端与原生三端对齐契约通过 verify-ios-cloud 7 大套件、46 项前端单测 + 118 项运行时测试 100% 全绿 | 已推送 |
| 2026-11-04 | Agent (3c4fb81) | 同步通用前端 v1.14.0 新基线（commit ff3ec42）：①彻底拔除 WhatsNewModal 弹窗及其全局逻辑；②引入 SegmentedSwitch、TerminalWell、frozenCoverPlate 冻结盖板体系；③升级 MapleMono Variable 字体与新版封面资产；④完美保留 iOS 平台独有接线与沙盒契约（保持 iOS 控制台/ios > 提示符、文件夹选择沙盒引导、实例密码作废时序与移动宿主局域网说明）；⑤版本升级至 1.14.0（Build 38）；46 项前端单测 + 118 项运行时测试 + verify-ios-cloud 7 套件 100% 全绿；产出免签 IPA（SHA-256: `56acd43f4c51b21a826f4ecc2ceb905db3d501c08a1bba92624a081dc67e2dca`，大小 194,799,830 字节）归档于 `Local/artifacts/v1.14.0/` | 已推送 |
| 2026-11-07 | Agent | 同步通用前端新手教程图集全面重构（v4 25张卡片式教程）与实例就地内联重命名（InstanceRenameField / InstanceCardDrawer / console-card 体系）：①彻底替换淘汰的旧引导图集，接入新版 25 张 v4 引导图；②实例卡片重构引入抽屉展开与就地重命名体系，保留 iOS 双击编辑与密码锁安全契约；③保留 iOS 平台独有接线与沙盒契约（保持 iOS 控制台/ios > 提示符、文件夹选择沙盒引导、移动宿主局域网说明）；④46 项前端单测 + 118 项运行时测试 + verify-ios-cloud 7 套件 100% 全绿；产出免签 IPA（SHA-256: `db116a3046ad79fdcb8c4fd3f570ff338d067009ec661bc0bc320402d977c979`，大小 194,903,882 字节）归档于 `Local/artifacts/v1.14.0/` | 已推送 |
| 2026-11-07 | Agent | 升版至 1.14.1（Build 39）：①对齐通用前端 1.14.1 基线；②原生 Info.plist（native-src 与 ios/App/App 逐字节镜像一致）版本号对齐 1.14.1，Build 号递增至 39；③前端单测 46/46、运行时测试 118 pass (2 skip)、verify-ios-cloud 7 大套件 100% 全绿；产出免签 IPA（SHA-256: `86682692683f807bebe38199d2bb8fde72d1a10617b3b9b953fbe25270921231`，大小 194,903,863 字节）归档于 `Local/artifacts/v1.14.1/` | 待推送 |

---

## 4. 交付与推送门禁 (Milestone & Delivery Gate)

- **本地门禁**:
  1. `node scripts/verify-ios-cloud.mjs --mock-mode` 7 大套件 100% PASS；
  2. `node --test tests/*.test.mjs` 117 项全量通过（115 pass, 2 optional skip, 0 fail）；
  3. `node --test web/capacitor-ui/tests/*.test.cjs` 41 项单测 100% PASS。
- **中央登记协议**:
  - 本树过程记录就地沉淀在上方第 3 节；
  - **当且仅当向远端分支执行 `git push` 或产出正式 IPA 时**，才向 `Local/docs/CURRENT_STATE.md` 与 `.worktrees/README.md` 登记事实索引。
