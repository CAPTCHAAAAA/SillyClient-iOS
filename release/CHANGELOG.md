# 版本记录

这里只保留已经发布版本的用户可见变化。完整实现历史以 Git 提交和各版本 Release 说明为准。

## 1.14.4 - 2026-11-14

- 恢复 iOS 端创建实例时的安全目录标识生成（`normalizeInstanceIdentity`），修复留空、中文或含空格实例名在原生存储校验失败（`An explicit valid instance identity is required`）的问题，同时保留用户设定的中文展示名。
- `UIDocumentPickerViewController` 选择回调改为在返回 UIKit 前于主线程同步获取安全作用域（`preScoped`）后再转入后台文件协调与 bookmark 持久化，避免外置 Files / iCloud 目录在选择器 XPC 会话销毁瞬间回收临时授权。
- 调整文件窗 `modalPresentationStyle = .formSheet` 与 `presentationController?.delegate = self` 的设置顺序；非安装目录类选择器不再强制固定打开沙盒 `Documents`。
- 补充 `An explicit valid instance identity is required` 中文提示，并在实例创建、启动与迁移目录选择错误路径统一接入 `humanizeNativeError`。
- 应用版本升至 `1.14.4`（Build `49`），仅更新 iOS，跳过 Windows 与 Android。

## 1.14.3 - 2026-11-14

- 修复 `UIDocumentPickerViewController` 下滑或点击外部关闭后 `pendingPickerCall` 未清理导致的后续目录/文件选择永久卡死，同时补齐正在退场过渡重试、孤立回调清理与 `PICKER_CANCELLED` 错误码。
- 修复外置目录 bookmark 使用 `.minimalBookmark` 与未协调生成导致的授权失效/陈旧拒用：改用标准 `bookmarkData(options: [])` 与 `.withoutChanges` 只读协调，并在 `select` 协调作用域内生成 bookmark；遇到 `stale == true` 且目录身份一致时自动刷新持久化 bookmark，权限丢失或目录被替换仍拒绝；本地读写能力探针补充 `NSFileCoordinator(writingItemAt:options:.forReplacing)` 协调。
- 补齐其余文件/目录选择动作（源目录、ZIP、封面、文本文件）的 `NSFileCoordinator` 读取协调与主队列回调；外置源目录授权队列支持 FIFO 上限淘汰（保留 8 个）；无扩展名封面自动回退 `.png`；`getAppSettings` 自动核验并清理已失效的预设根目录。
- 前端接入标准错误诊断翻译（含 iCloud 未下载、`ENOTSUP`/provider 读写限制、bookmark 失效、系统容器拒绝等中文提示），并在迁移路径弹窗及封面选择中停止吞咽非取消错误。
- 应用版本升至 `1.14.3`（Build `48`），CI 流水线、E2E 断言与原生契约同步更新（仅更新 iOS，跳过 Windows 与 Android）。

## 1.14.2 - 2026-11-11

- 修复 Files provider bookmark URL 与协调器 accessor URL 不同导致授权恢复后实例创建失败的问题：恢复时重新协调访问、核对目录身份，并持久化相对路径以支持后续重开。
- iCloud 目录根据下载状态判断本地可用性，仍未下载的目录会明确提示，已下载目录继续通过读写能力检查。
- 紧急修复新建实例向导目录选择与路径回填链路：向导组件完整注入 `isIOS` 状态，恢复原生文件选择指引。
- 完善 `root/exact` 目录模式判定，Documents 根预填和用户选择的新目录均按父目录安全建立实例子文件夹，手动编辑自动切换为精确路径。
- 隐藏 iOS 平台不支持的本地运行时 ZIP 安装入口，引导通过安全数据迁移。
- 保持应用版本为 1.14.2，Build 47 修复安装目录授权恢复并由官方 CI 构建交付；真实 iPhone Files provider 需用户安装后复测。

## 1.14.1 - 2026-11-10

- 全面落地 22 步隔离实战新手引导（`OnboardingSession`），视口级 SVG Mask 硬件遮罩彻底消灭 120Hz 高刷屏画面撕裂与显存频闪。
- 实例卡片未运行状态支持就地双向内联重命名（`InstanceRenameField`），新增标准化抽屉式控制台（`InstanceCardDrawer`）。
- 内置主题预设 `SC Bordeaux`（波尔多红酒）升级终态 Revision 3，高斯模糊调谐至 14。
- 实例管理面板竖屏自适应优化（`ToggleSwitch`、字号梯级、`is-stacked` 排布与软键盘动态避让）。
- 严格守护 iOS 专属终端文案与提示符：`iOS 控制台`、`ios >` 及 `SillyClient ${APP_VERSION} · iOS · NodeMobile`。
- 升级应用版本至 1.14.1 (Build 39)，CI 流水线、E2E 测试断言与平台契约测试全量通过。

## 1.11.0 - 2026-10-08

- 运行时根路径校验支持 Darwin `/private` 规范化等价性判定，解决实体机沙盒 Documents 路径报错。
- 新增有界文件访问守卫与 Worker 工作目录校验，严格拦截沙盒逃逸与非法越界访问。
- 实例管理全链路加固，全面支持同父目录物理改名、存储迁移与实例访问密码。

## 1.9.1 - 2026-09-05

- 修复 Android 与 Windows 导入壁纸图片后界面卡死的问题。

## 1.9.0 - 2026-09-04

- 顶部控制岛呈现更轻盈、通透且层次清晰的玻璃质感，竖屏自适应设备宽度，横屏保持限宽居中。
- 壁纸界面在明暗主题下均保持标题清晰，支持磨砂强度调节，屏幕边缘虚化更加自然。
- 动态、白天、黑夜三套材质预设改为独立保存，支持保存时间、历史记录以及当前或全部预设导出。
- 实例卡片展开与收回更加连贯，遮罩显示完整，移动端的雾面、饱和度和圆角表现保持一致。
- 创建本地实例时可选内置 `SC Bordeaux` 主题预设，安装完成后自动应用主题与配套 8K 壁纸；失败时会回滚未完成的预设写入。
- 新手引导更新为五步流程，使用当前界面的实际配图，并改善步骤切换和内容过渡。
- 创建实例的默认版本入口改为“内置版”，明确使用应用自带的最新本地版本。
- 升级 Windows 压缩包处理依赖，修复生产依赖安全审计问题。

## 1.8.2 - 2026-08-22

- Android 修复 SillyTavern 内导出文件无法触发系统保存的问题，并改为安全暂存后写入用户选择的位置。
- Windows 修复选择应用内窗口后仍会打开系统浏览器的问题。
- 应用更新检查改为前端自动检查并显示更新提示。
- 优化酒馆状态栏提示、实例卡片动画和整体性能。
- 共享前端源码按平台拆分：主仓库保留基线，Android/Windows 分别维护平台适配源码。

## 1.8.1 - 2026-08-15

- 修复 Windows 客户端左上角实例终端按钮无响应的问题，恢复实例级终端入口。
- 未选择实例时点击终端会正常展开面板并显示提示，不再静默失效。
- Android、Windows 与网页演示同步使用 1.8.1 共享 React 前端。

## 1.8.0 - 2026-08-13

- 重构实例管理菜单，增加启动、快照、存储、终端和关于分类，以及实例搜索与筛选。
- 实例终端改为绑定当前实例，并在对应实例目录中执行命令。
- 新增实例设置快照，改善重命名、封面更换与管理菜单动效。
- 修复 Windows 更换实例封面时卡住或丢失原封面的问题。
- Android 与 Windows 新增 SillyClient 自动及手动版本检查，并提供多来源网络回退。
- 同步更新 Android、Windows 和网页演示使用的 1.8.0 共享 React 前端。

## 1.7.0 - 2026-08-12

- 重构 APP 设置与使用引导，统一当前界面的分类、步骤、配图和交互动效。
- 取消全局 hover 位移，实例二级菜单仅保留文字高光，并修复双端实例设置面板卡住与遮罩残留。
- 改善新建实例的版本列表展开顺序与本地 ZIP 导入位置。
- 远程实例新增安全存储的 HTTP Basic Auth 配置，密码不会进入 URL、日志或前端存储。
- Android 新建实例后首次进入 SillyTavern 时显示一次顶部滑动返回提示。
- 修复 Windows 图标与 AppUserModelId，并同步更新 Android、Windows 和网页演示使用的共享 React 前端。

## 1.6.0 - 2026-07-27

- 新增首次使用引导，并支持从 APP 设置重新查看。
- 引导窗口按当前页面内容自动调整尺寸并保持居中。
- Windows 可选择在应用内窗口或系统浏览器中打开 SillyTavern。
- Windows 创建实例时自动获取当前版本，并在 GitHub 接口不可用时切换元数据来源。
- 安装失败会清理未完成目录与临时文件，实例只有通过可运行性检查后才会创建成功。
- Android、Windows 与网页演示同步使用同一套 1.6.0 控制台构建。

## 1.5.0 - 2026-07-19

- Android 与 Windows 创建实例时显示下载、安装和可运行性检查进度。
- 删除实例增加二次确认，安装失败会清理未完成目录。
- 修复实例卡片裁切、异常阴影和重启后的状态错误。
- Windows 使用内置 Node.js，并显示符合 Windows 环境的控制台提示。
- 同一套 React 控制台同步到 Android、Windows 和项目主页。

## 1.1.0 - 2026-07-06

- 完成多实例管理、运行日志和主题界面的第一轮可用版本。
- 修复 Android 上的 npm 安装与运行时路径问题。

## 1.0.1 - 2026-07-05

- 首次公开发布 Android 安装包。
- 支持创建本地实例、连接远程实例和管理 SillyTavern 进程。
