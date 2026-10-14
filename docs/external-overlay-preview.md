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
- [x] 设置页入口「APP 外悬浮窗（预览）」。
- [x] 外悬浮模式下根组件切到 `ExternalFloatShell`，复用 `AppFloatLayer`，
      所以 AI 球 / AI 对话窗 / 浏览器窗与 APP 内是同一份状态和同一套 UI。
- [x] 悬浮窗并集 bounds 上报：原生覆盖窗口只包住可见悬浮窗，
      窗口外触摸继续落到下面 APP。
- [x] 终端 / SSH 终端 / 容器日志 / 容器文件窗从页面 `OverlayEntry` 改为
      `AppFloatLayer` 常驻宿主（`FloatingTerminalHost` / `SshFloatingHostLayer`），
      内外悬浮模式共用同一份窗口状态。
- [x] 画布窗 bounds 纳入上报；终端/SSH 窗自己维护的 `Offset+Size` 通过
      `FloatBoundsRegistry` 上报。
- [x] 从桌面图标直接回 APP 时先摘掉服务侧 FlutterView，修复
      “specified child already has a parent” 崩溃。

## 架构

```
MainActivity ──provideFlutterEngine()──┐
                                      ├── SharedFlutterEngine（同一 FlutterEngine）
ExternalOverlayService ─FlutterView───┘
        │
        └── WindowManager.addView(TYPE_APPLICATION_OVERLAY)
                    │
                    └── Dart: ExternalFloatShell
                              └── AppFloatLayer（AI / 浏览器 / 悬浮球）
```

状态共享的关键点：**不创建第二个 Engine**。主 Activity 退出前
`detachFromFlutterEngine()`，服务再把同一个 Engine 挂到覆盖窗口的
`FlutterView` 上；Dart 侧所有 Provider 原封不动。

## 坐标与触摸

- Dart 用逻辑像素计算悬浮窗并集，上报前乘 `devicePixelRatio` 转物理像素；
- 原生窗口正好是并集大小，`FLAG_NOT_TOUCH_MODAL` 让窗口外触摸穿透；
- `ExternalFloatShell` 仍按全屏坐标系布局 `AppFloatLayer`，再平移到窗口位置。

## 待办（Phase 2+）

- [x] 终端悬浮窗（`FloatingTerminal` / `SshFloatingHost`）接入 `AppFloatLayer`。
- [x] 画布窗 bounds 上报；快问输入条/结果窗已有宽松包围盒。
- [ ] 悬浮编辑器（`showFloatingCodeEditor`）等瞬时 Overlay 的外部行为。
- [ ] 键盘/输入法在覆盖窗口中的焦点与 `adjustResize` 行为验证。
- [ ] 权限被拒、服务被系统回收、旋转/分屏、多显示器场景。
- [ ] 快问结果窗 bounds 精确化。
- [ ] 通知常驻与「返回 APP」交互打磨。
