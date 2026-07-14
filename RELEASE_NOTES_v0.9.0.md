# AutoLockMyMac v0.9.0

## 中文

AutoLockMyMac v0.9.0 是首个可用预览版本。这个版本已经可以作为 macOS 菜单栏应用运行，根据已配对蓝牙设备的 RSSI 变化判断设备是否远离 Mac，并在满足条件时自动触发锁定相关动作。

### 新增

- 支持常驻菜单栏运行，关闭主窗口后仍可继续监控。
- 支持选择蓝牙设备作为距离判断对象。
- 支持实时查看当前 RSSI、监控状态和触发状态。
- 提供灵敏度预设：
  - 近距离
  - 均衡
  - 宽松
  - 自定义 RSSI 门限与连续离开样本数
- 支持两种离开动作：
  - 关闭屏幕并锁定
  - 启动屏幕保护程序
- 唤醒后会自动恢复检测；在屏保模式下，如果设备重新回到附近，会尝试退出 `ScreenSaverEngine`。
- 提供可直接双击运行的 `.app` 打包产物。

### 改进

- 修复了监控状态切换和设备选择后的监控刷新逻辑。
- 优化了离开判定流程，减少过早触发和重复触发的情况。
- 改进了设置持久化和旧版本设置兼容逻辑。
- 优化了打包脚本、签名校验和应用图标生成流程。
- 完成项目重命名，统一为 `AutoLockMyMac`。

### 测试

- 增加并保留了核心判定逻辑的自动化测试。
- 已验证项目可以正常构建，并可生成 `dist/AutoLockMyMac.app`。

### 已知限制

- macOS 真正的登录锁屏界面不能由普通第三方应用自动解锁。
- 如果系统设置为“睡眠或屏保后立即需要密码”，最终解锁仍然由 macOS 自己处理。
- RSSI 判断效果会受到设备类型和环境干扰影响，当前更推荐配合 Apple Watch 使用。

## English

AutoLockMyMac v0.9.0 is the first usable preview release. It runs as a macOS menu bar app, monitors the RSSI of a paired Bluetooth device, and automatically triggers lock-related actions when the device moves away from the Mac.

### What's New

- Runs as a persistent menu bar app even after the main window is closed.
- Lets you choose a Bluetooth device as the proximity target.
- Shows current RSSI, monitoring status, and trigger status in the app UI.
- Includes sensitivity presets:
  - Near
  - Balanced
  - Relaxed
  - Custom RSSI threshold and consecutive-away sample count
- Supports two away actions:
  - Turn off display and lock
  - Start screen saver
- Automatically resumes detection after wake, and attempts to quit `ScreenSaverEngine` if the device is detected nearby again while screen saver mode is active.
- Includes a ready-to-run `.app` bundle for direct use.

### Improvements

- Fixed monitoring refresh behavior after device selection and monitoring state changes.
- Improved away-detection logic to reduce premature and repeated triggers.
- Improved settings persistence and compatibility with legacy settings.
- Improved packaging, signing verification, and app icon generation.
- Renamed the project consistently to `AutoLockMyMac`.

### Testing

- Added and kept automated tests for the core proximity evaluation behavior.
- Verified that the project builds successfully and produces `dist/AutoLockMyMac.app`.

### Known Limitations

- The real macOS login lock screen cannot be automatically unlocked by a normal third-party app.
- If macOS is configured to require a password immediately after sleep or screen saver, unlocking is still handled by macOS itself.
- RSSI-based detection depends on device type and surrounding conditions; Apple Watch is currently the recommended device for the best experience.
