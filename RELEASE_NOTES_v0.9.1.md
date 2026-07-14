# AutoLockMyMac v0.9.1

## 中文

AutoLockMyMac v0.9.1 重点优化了能耗控制和离开判定体验。在保持自动锁定/启动屏保功能不变的前提下，这个版本增加了可配置扫描间隔，并在第一次检测到“可能不在范围内”后临时提升判断频率，以便更快完成连续样本确认，避免长间隔设置带来的确认超时。

### 新增

- 支持自定义扫描间隔，范围为 `15` 到 `600` 秒。
- 支持在界面中直接输入扫描间隔数值。
- 支持明确显示并直接输入“连续离开样本数”。

### 改进

- 优化蓝牙扫描策略，减少持续扫描带来的 CPU 和能耗影响。
- 当首次出现疑似离开样本时，会临时切换到更高频率的复检节奏，用于快速补齐连续样本数。
- 一旦重新判定为在附近，或已经确认离开并执行动作，就会恢复到用户设定的常规扫描间隔。
- 兼容旧设置：如果旧版本保存的扫描间隔低于最小值，会自动修正到合法范围。

### 测试

- 已验证项目可以正常构建。
- 已验证核心离开判定测试继续通过。
- 已重新生成最新的 `dist/AutoLockMyMac.app`。

## English

AutoLockMyMac v0.9.1 focuses on improving energy usage and away-detection responsiveness. Without changing the core auto-lock / screen-saver behavior, this release adds a configurable scan interval and introduces a temporary high-frequency recheck mode after the first possible out-of-range sample, so consecutive-away confirmation does not stall behind long user-defined intervals.

### What's New

- Added a configurable scan interval with a range of `15` to `600` seconds.
- Added direct numeric input for the scan interval in the UI.
- Added clear display and direct numeric input for consecutive away samples.

### Improvements

- Optimized the Bluetooth scanning strategy to reduce CPU and energy impact from continuous scanning.
- After the first possible away sample appears, the app temporarily switches to a faster recheck cadence to confirm consecutive away samples more quickly.
- Once the device is judged nearby again, or the away state is fully confirmed and the action is triggered, the app returns to the user-configured normal scan interval.
- Added legacy-settings normalization so previously saved intervals below the minimum are automatically corrected.

### Testing

- Verified that the project builds successfully.
- Verified that the core away-detection tests still pass.
- Rebuilt the latest `dist/AutoLockMyMac.app`.
