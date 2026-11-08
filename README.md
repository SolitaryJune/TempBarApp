# TempBarApp

macOS 菜单栏温度监控工具，适用于 Apple Silicon Mac。

## 功能

- 菜单栏实时显示 CPU 最高温度
- 点击查看 CPU / GPU 详细温度信息
- 显示实时充电功率
- 显示热压力状态
- **MagSafe 充电灯控制**（v1.2 新增，见下文）
- 每 5 秒自动刷新
- Universal Binary（支持 arm64）

## 截图

菜单栏会显示当前 CPU 最高温度，点击展开查看详情：

- CPU 最高温度 / 平均温度
- GPU 最高温度 / 平均温度
- 热压力状态
- 实时充电功率
- MagSafe 灯控制
- 更新时间

## MagSafe 灯控制（v1.2）

通过 SMC 键 `ACLC` 控制 MagSafe 3 充电头的 LED（该机制由开源项目
[MagHue](https://github.com/kamenlevi/MagHue) 公开）。支持：

- **系统默认** / **关闭** / **呼吸模式**
- 呼吸颜色：自动（充电时橙色 / 充满变绿）、绿色、橙色
- 呼吸速度：慢（6 秒）/ 中（4 秒）/ 快（2.5 秒）/ 自定义（1–6 秒）
- 波形：正弦 / 线性（三角）
- 插拔充电线、重启后自动恢复所选效果

LED 状态由一个无界面的后台辅助工具（launchd 守护进程）负责——因为写
SMC 键需要 root 权限。**app 启动时会自动请求授权**：首次使用（或辅助
工具被移除后）启动 app 会直接弹出一次管理员授权框，输入密码即完成安
装，之后启动不再提示。辅助工具就是 app 自身的二进制以 `--led-helper`
参数运行，不含任何额外组件。不想用了在菜单里点「卸载辅助工具…」即可
一键清除（LED 恢复系统默认，守护进程与配置全部移除）。

呼吸效果由软件 PWM 实现（LED 本身不支持亮度调节）：以约 67 Hz 在
亮灭之间切换，占空比按波形包络变化。

## 安装

### 方式一：直接下载

从 [Releases](../../releases) 下载 `TempBarApp.app`，拖入 `/Applications` 即可使用。

### 方式二：从源码编译

需要 Xcode 15+。

```bash
git clone https://github.com/SolitaryJune/TempBarApp.git
cd TempBarApp
xcodebuild -project TempBarApp.xcodeproj -scheme TempBarApp -configuration Release
```

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- Apple Silicon（MagSafe 3 充电口机型才能使用灯控功能）
- 搭载 Intel 处理器的 Mac 不适用

## 致谢

温度传感器读取代码基于 [macos-temp-tool](https://github.com/Cliffback/macos-temp-tool)，原始代码来自 [freedomtan/sensors](https://github.com/freedomtan/sensors)。

## 友情链接

[Linux do](https://linux.do))。

## 许可证

BSD 3-Clause License
