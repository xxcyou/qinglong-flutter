# APP 外系统悬浮窗预览（preview-system-overlay）

> 这是独立预览分支，不是正式版。正式版 `restore-28b8319` 不受影响。

## 目标

把 APP 内的悬浮窗能力搬到 Android 系统层（`TYPE_APPLICATION_OVERLAY`），
让用户在其它 APP 上层也能继续使用悬浮球、AI 对话窗、浏览器等。

## 当前进度（Phase 1）

- [x] Android 共享 `FlutterEngine`：主 Activity 与悬浮窗服务共用一个引擎、
      同一个 Dart isolate、同一份 Riverpod/ChangeNotifier 状态。
- [x] `ExternalOverlayService` 前台服务：用 `WindowManager` 承载一个
      `FlutterView`，窗口大小/位置跟随 Dart 上报的悬浮窗并集。
- [x] `SYSTEM_ALERT_WINDOW` 权限申请、Android 14 `specialUse` 前台服务类型。
- [x] AI 悬浮球开关 = APP 外悬浮总开关（已取消独立的外悬浮开关）。
- [x] **准备态服务 + 生命周期换窗**：AI 悬浮球开关只起准备态前台服务，
      不挂 view、不 `finish()`、不强制 APP 退后台；用户自己按 Home /
      切换 APP 时，`MainActivity.onStop` 才把 Activity 的 `FlutterView`
      摘下来，服务把**同一个 engine** 挂到覆盖窗口上；回前台 `onStart`
      再摘覆盖窗口、把 Activity 的 view 挂回去。
- [x] 因为始终是同一个 Dart isolate / 同一棵 Provider 树，悬浮窗内容、
      会话、任务状态、拖拽后的归一化位置都原样保留，桌面显示不跳位。
- [x] 外悬浮模式下根组件切到 `ExternalFloatShell`，复用 `AppFloatLayer`，
      所以 AI 球 / AI 对话窗 / 浏览器窗与 APP 内是同一份状态和同一套 UI。
- [x] 悬浮窗并集 bounds 上报：原生覆盖窗口只包住可见悬浮窗，
      窗口外触摸继续落到下面 APP；拖动只扩张/缩进粘性包络，避免窗口
      每帧移动导致的“悬浮球跟着抖”。
- [x] 终端 / SSH 终端 / 容器日志 / 容器文件窗从页面 `OverlayEntry` 改为
      `AppFloatLayer` 常驻宿主（`FloatingTerminalHost` / `SshFloatingHostLayer`），
      内外悬浮模式共用同一份窗口状态。
- [x] 画布窗 bounds 纳入上报；终端/SSH 窗自己维护的 `Offset+Size` 通过
      `FloatBoundsRegistry` 上报。
- [x] 从桌面图标直接回 APP 时先摘掉服务侧 FlutterView，修复
      “specified child already has a parent” 崩溃。
- [x] 修复“arm 时 APP 还在前台就提前挂覆盖窗口”的启动竞态：`arm` 只
      起准备态服务，真正 attach 只发生在 `onStop`。
- [x] 修复部分 ROM 上覆盖窗口 `SurfaceView` 首帧不上屏：服务在挂载后
      于窗口透明留白角落发一个合成触摸，踢一下引擎的帧调度。

## 架构

```
AI 悬浮球开关（设置页）
        │ method channel: arm
        ▼
ExternalOverlayService（前台服务 · 准备态，不挂 view）
        │
        │ APP 退后台：MainActivity.onStop
        │   ① Activity FlutterView.detachFromFlutterEngine()
        │   ② service.attachOverlay()
        ▼
WindowManager.addView(TYPE_APPLICATION_OVERLAY)
        │
        └── Dart: ExternalFloatShell
                  └── AppFloatLayer（AI / 浏览器 / 悬浮球 / 终端 / SSH / 附件）
        │
        │ APP 回前台：MainActivity.onStart
        │   ① service.detachOverlay()
        │   ② Activity FlutterView.attachToFlutterEngine()
        ▼
主 APP 页面 + APP 内 AppFloatLayer
```

状态共享的关键点：**不创建第二个 Engine**。主 Activity 退后台前
`detachFromFlutterEngine()`，服务再把同一个 Engine 挂到覆盖窗口的
`FlutterView` 上；Dart 侧所有 Provider 原封不动。回前台再反向挂回。

## 单渲染 surface 限制

当前 Flutter Android embedding（本项目版本）的 `FlutterRenderer` 只有
一份渲染 surface。同一个 Engine 同时挂两个 `FlutterView` 时后挂的会抢走
渲染，主页面会黑屏。因此这里采用 **同一时刻只挂一个 view** 的生命周期
换窗方案：

- APP 前台：Activity view 挂着，悬浮球/悬浮窗画在 APP 内（和原正式版体验
  一致，不额外弹系统窗口）；
- APP 退后台：Activity view 摘掉，覆盖窗口 view 挂上，同一棵 `AppFloatLayer`
  原位画在桌面上；
- APP 回前台：覆盖窗口摘掉，Activity view 挂回，状态/位置不变。

如果将来要“APP 前台也同时在桌面显示系统悬浮窗”，需要升级到支持多
`FlutterView` 的 embedding/多 Engine + 状态桥，那是另一个阶段的工作。

## 覆盖窗口首帧

部分 ROM/设备上，覆盖窗口里的 `FlutterSurfaceView` 虽然 `surface` 已创建、
engine 也已 attach，但第一帧不会主动提交到 `SurfaceFlinger`，表现是桌面
上看不到悬浮球，必须手动点一下才出现。服务在 `addView` 后约 250ms/900ms
向 view 的透明留白角落（物理 `(2,2)`，窗口并集有 48 逻辑像素内边距）发送
一对合成 `ACTION_DOWN/ACTION_UP`，触发 Flutter 的帧调度；该坐标不会命中
任何悬浮窗，不会产生可见点击。

## 坐标与触摸

- Dart 用逻辑像素计算悬浮窗并集，上报前乘 `devicePixelRatio` 转物理像素；
- 原生窗口正好是并集大小 + 10 逻辑像素阴影余量（之前外扩 48+36，
  透明区域会吃掉桌面触摸，已收紧）；
- 原生窗口是矩形的：窗口矩形内都会接收触摸，因此只保留悬浮窗并集本身，
  不额外加更大的空白包络；`FLAG_NOT_TOUCH_MODAL` 让窗口外触摸穿透；
- 所有悬浮窗都关掉时，Dart 上报空矩形，原生窗口收成 1x1 并加
  `FLAG_NOT_TOUCHABLE`，桌面触摸完全不受影响；
- 窗口缩小保留 16 逻辑像素回差，避免拖动时每帧抖动；关闭悬浮窗时
  并集缩小远超回差，窗口会立即收缩；
- `ExternalFloatShell` 仍按全屏坐标系布局 `AppFloatLayer`，再平移到窗口位置。

> 局限：多个悬浮窗相距较远时，单窗口方案的并集矩形会覆盖它们之间的
> 桌面区域；彻底解决需要“每个悬浮窗一个原生窗口”的多窗口方案，列入
> Phase 2。

## 待办（Phase 2+）

- [x] 终端悬浮窗（`FloatingTerminal` / `SshFloatingHost`）接入 `AppFloatLayer`。
- [x] 画布窗 bounds 上报；快问输入条/结果窗已有宽松包围盒。
- [x] AI 悬浮球开关不再强制 APP 退后台/重启；退后台后原位续显。
- [ ] 多窗口方案：每个悬浮窗一个原生窗口，彻底避免并集矩形挡住
      悬浮窗之间的桌面区域（当前单窗口方案已收紧到 10px 阴影余量）。
- [ ] 悬浮编辑器（`showFloatingCodeEditor`）等瞬时 Overlay 的外部行为。
- [ ] 键盘/输入法在覆盖窗口中的焦点与 `adjustResize` 行为验证。
- [ ] 权限被拒、服务被系统回收、旋转/分屏、多显示器场景。
- [ ] 快问结果窗 bounds 精确化。
- [ ] 通知常驻与「返回 APP」交互打磨。
- [ ] 预览自动化 hook（`qinglong_preview_enter_external`）在正式发布前删除。
