# TempBarApp

macOS 菜单栏温度监控工具，适用于 Apple Silicon Mac。

## 功能

- 菜单栏实时显示 CPU 最高温度
- 点击查看 CPU / GPU 详细温度信息
- 显示实时充电功率
- 显示热压力状态
- 每 5 秒自动刷新
- Universal Binary（支持 arm64）

## 截图

菜单栏会显示当前 CPU 最高温度，点击展开查看详情：

- CPU 最高温度 / 平均温度
- GPU 最高温度 / 平均温度
- 热压力状态
- 实时充电功率
- 更新时间

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
- Apple Silicon 

## 致谢

温度传感器读取代码基于 [macos-temp-tool](https://github.com/Cliffback/macos-temp-tool)，原始代码来自 [freedomtan/sensors](https://github.com/freedomtan/sensors)。

## 友情链接

[Linux do](https://linux.do))。

## 许可证

BSD 3-Clause License
