# GimbalPaw

GimbalPaw 是一套面向 Apple Silicon Mac 的本地人物跟踪与云台联调工具。当前原生应用仍显示为 **OM3 Lab**：它通过 Bluetooth Low Energy（BLE）控制 DJI Osmo Mobile 3（OM3），通过 AVFoundation 读取用户选择的 iPhone 连续互通相机或外置 UVC 摄像头，并使用 Apple Vision 在 Mac 本机检测和跟踪人物。

```text
Mac mini ── BLE 无线 ──> OM3
Mac mini <── 无线 / USB ─ iPhone Camera 或外置摄像头
充电器  ── USB-C 线 ──> OM3（可选，仅供电）
```

OM3 的 USB 接口只用于供电，不承担电脑控制或视频传输。摄像头画面不会经过 OM3，也不会由本项目上传。

## 主要能力

- 记忆并自动重连已经完整验证的 OM3 BLE 设备。
- 显示所有可用摄像头供用户选择，记住最后一次成功运行的设备；自动恢复时不会擅自回退到其他设备。
- 显示画面中的人物候选，默认锁定“人物 1”，也可手动切换目标。
- 人物跟踪同时修正 Pan 和 Tilt；目标出框后按最后可信方向惯性寻找，并在安全包络内执行上下左右二维扫描。
- 提供平稳、标准、连续极速三档连续追踪；三档都使用 0.1 秒动作首尾衔接、没有应用层额外等待，只通过修正角速度区分快慢，并保留 STOP、安全确认和运动预算。
- 自动执行可信的左、右、上、下四方向安装态标定；未标定时使用回中点起左右各 120°、上下各 60° 的保守包络，标定后可按当前安装扩大范围。
- 日常控制界面只保留设备连接、运动安全、人物选择和跟踪；固定点动、全向安全验证及诊断日志统一收进“高级与帮助”，云台 STOP 始终固定可见。

> 这是实验性硬件控制软件。OM3 没有向应用提供可靠姿态回读，BLE 无响应写入也没有设备 ACK。DJI 公布的结构活动范围不是从 App 回中点起的对称可控边界。第一次运行必须在周围净空、设备调平和载荷配平后低速验证，给摄像头软线留足余量，并始终保留物理断电手段。

## OM3 官方资料

- [DJI Osmo Mobile 3 中文用户手册](https://dl.djicdn.com/downloads/Osmo_Mobile_3/Osmo_Mobile_3_User_Manual_v1.0_cn.pdf)
- [DJI Osmo Mobile 3 支持与规格页](https://www.dji.com/support/product/osmo-mobile-3)
- [DJI 云台俯仰角度范围说明](https://repair.dji.com/help/content?customId=01700006553&documentType=&lang=zh-CN&paperDocType=ARTICLE&re=CN&spaceId=17)
- [DJI Osmo Mobile 3 免责声明和安全操作指引](https://dl.djicdn.com/downloads/Osmo_Mobile_3/Osmo_Mobile_3_Disclaimer_and_Safety_Guidelines.pdf)

## 仓库结构

- `macOS/OM3Lab/`：主要的 macOS 14+ 原生 SwiftUI 应用、测试和打包脚本。
- `app/`、`worker/`、`tests/`：早期 Web Bluetooth 联调原型。
- `outputs/`：本地打包结果；属于可再生成文件，不纳入 Git。

原生应用的完整操作说明、安全边界和跟踪行为见 [`macOS/OM3Lab/README.md`](macOS/OM3Lab/README.md)。

## 构建原生 macOS 应用

要求 Apple Silicon Mac、macOS 14 或更高版本，以及可用的 macOS SDK。

```bash
cd macOS/OM3Lab
./scripts/build-app.sh
```

脚本会运行协议黄金帧自检，构建纯 `arm64` 应用并进行 ad-hoc 签名，结果写入仓库根目录的 `outputs/`：

- `OM3 Lab.app`
- `OM3-Lab-macOS-arm64.zip`

如需运行 SwiftPM 测试，请安装编译器与 SDK 版本匹配的完整 Xcode，然后执行：

```bash
cd macOS/OM3Lab
swift test
```

## 运行 Web BLE 原型

Web 原型需要 Node.js 22.13 或更高版本，以及支持 Web Bluetooth 的 macOS Chrome。

```bash
npm install
npm run dev
```

## BLE 协议与归属

OM3 没有公开的 macOS 控制 SDK。本项目仅使用社区逆向验证的 FFF0 / FFF4 / FFF5 GATT 特征和 DJI DUML 控制帧，不尝试固件操作。协议研究参考 [`alkersan/om-research`](https://github.com/alkersan/om-research)。

本项目不是 DJI 官方软件，与 DJI 无关联。DJI、Osmo 和 OM3 是其各自权利人的商标。

## 许可证

本项目使用 [MIT License](LICENSE)。
