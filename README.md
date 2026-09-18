# 跳舞闹钟 · iOS 版

必须跳满设定秒数舞蹈才能关闭的闹钟。用前置摄像头做实时姿态识别，判定你确实在动身体而不是晃手机。

与安卓版共用同一套判定引擎（阈值完全一致），但**闹钟机制是按 iOS 的能力重写的** —— 两个平台的闹钟模型差别极大，直接照搬会得到一个静音就不响的废品。

---

## ⚠️ 先看这一条：iOS 应用必须有 macOS 才能编译

这是苹果的硬性限制，没有绕过的办法。你的 Windows 机器**出不了 `.ipa`**。

但有三条路可以走通，按推荐顺序：

### 路子 A：用 GitHub Actions 云端编译（Windows 上就能完成）

本仓库已经带好了工作流 `.github/workflows/build-ios.yml`：

1. 把 `D:\DanceAlarm-iOS` 推到一个 GitHub 仓库（私有仓库也行，Actions 对私有仓库免费额度足够）
2. 打开仓库的 **Actions** 标签页 → 选「构建 iOS 应用（未签名 ipa）」→ **Run workflow**
3. 等约 5 分钟，在运行结果页最下方下载 `DanceAlarm-unsigned-ipa` 这个 artifact
4. 解压得到 `DanceAlarm-unsigned.ipa`，用下面的「侧载」步骤装进 iPhone

> 免费的 GitHub 账号每个月有 2000 分钟 macOS runner 额度，编译这一个 App 用不到 10 分钟。

### 路子 B：借一台 Mac

装 Xcode 26（App Store 免费）→ 双击 `DanceAlarm.xcodeproj` → 选你的 iPhone → 按 ⌘R。
Xcode 会自动处理签名，比侧载省事得多，而且 App 有效期更长。

### 路子 C：租云 Mac

MacinCloud、MacStadium 之类，按小时计费。适合只想试一次的情况。

---

## 装进 iPhone（侧载）

未签名的 ipa 需要本机重新签名才能安装。Windows 上可用 **[Sideloadly](https://sideloadly.io/)**：

1. 电脑装 iTunes（或 Apple Devices 应用）以保证驱动可用
2. iPhone 用数据线连电脑，首次连接要在手机上点「信任此电脑」
3. 打开 Sideloadly，把 `DanceAlarm-unsigned.ipa` 拖进去
4. 填你的 Apple ID（免费账号即可），点 Start
5. 手机会要求去 **设置 → 通用 → VPN与设备管理** 里信任该开发者证书

**免费 Apple ID 的两个限制，心里有数就好：**

| 限制 | 说明 |
|---|---|
| App **7 天后失效** | 到期需要重新侧载一次，闹钟配置不会丢 |
| 同时最多 3 个自签 App | 超了要删掉一个 |

想要一年有效期，需要 99 美元/年的苹果开发者账号。**本 App 不使用任何需要付费账号的特殊权限**，免费账号装出来功能是完整的。

---

## iOS 版和安卓版的差异（诚实清单）

闹钟这件事上，iOS 比安卓严格得多。有些能力是苹果从系统层面禁止的，任何 App 都做不到：

| 能力 | 安卓版 | iOS 版 |
|---|---|---|
| 静音状态仍能响 | ✅ 可以 | ⚠️ **看系统版本**：iOS 26+ 用 AlarmKit 可以（无需苹果审批），iOS 16~25 走通知则**不会响** |
| 穿透专注模式 | ✅ | ⚠️ 同上，AlarmKit 可以 |
| 锁屏直接弹出跳舞界面 | ✅ 全屏 Intent | ⚠️ 系统闹钟会在锁屏显示，点「停止」后打开 App 进跳舞页 |
| 屏蔽音量键静音 | ✅ 拦截按键 | ❌ 系统禁止，做不到 |
| 按 Home 后自动顶回界面 | ✅ 服务 1.5 秒重拉 | ❌ 系统禁止，做不到 |
| 后台访问摄像头 | ✅ | ❌ 系统禁止 |
| 卸载/强杀 App 后仍响 | ✅ | ❌ 通知与 AlarmKit 都会随之失效 |

**结论**：iOS 版是「早上被系统闹钟叫醒 → 点停止 → 被要求跳完 30 秒」，而不是安卓那种「物理上关不掉」。用户可以长按强制退出 App 绕过 —— 这是 iOS 的平台设计，没有 App 能突破。

已经尽力补齐的部分：
- 进跳舞界面后，音频用 `.playback` 类别播放，**无视静音开关**持续响铃并震动
- 通知方案下，闹钟时刻后会补发 +1 分钟、+3 分钟的催促通知，防止忽略第一条就睡过去
- AlarmKit 模式下屏幕常亮、锁屏和灵动岛都会显示

---

## 技术实现

### 姿态识别：Vision 框架，零依赖

安卓版用 ML Kit 姿态模型，得往 APK 里塞 37MB 原生库。iOS 直接用系统内置的
`VNDetectHumanBodyPoseRequest`（iOS 14+）—— **不增加任何体积，完全离线，也不会向 Google 发请求**。

坐标约定上有一处必须注意：Vision 的输出原点在**左下角、y 轴向上**，而界面绘制是左上角原点、y 向下。
`CameraPoseController` 统一做了一次 y 翻转，同时输出两套坐标：
像素坐标喂给判定引擎，归一化坐标喂给骨骼叠加绘制。

旋转问题也比安卓简单：安卓要自己猜 ML Kit 返回的是旋转前还是旋转后的画幅（那套启发式写在
`PoseAnalyzer.kt` 里），iOS 只要把采集连接的旋转角固定成竖屏，Vision 按 `.up` 处理即可。

### 判定引擎：与安卓版逐字段对齐

`Dance/DanceJudge.swift` 是 `DanceJudge.kt` 的逐行移植，连关键点编号都沿用了 ML Kit 的（0 与 11~22），
这样两端源码可以对照着读。核心是**躯干坐标系归一化**：

> 把所有关键点换算到「以髋部中心为原点、躯干长度为 1」的坐标系里再比较。
> 晃动手机只会让整个人在画面里平移，躯干坐标系里的相对位置几乎不变 —— 作弊天然无效。

三层闸门：全身入镜 → 8 大关节中至少 2 个摆幅超躯干长 30% → 运动量波峰频率 ≥0.6Hz。
只有判定为「在跳」的帧才累计计时，停下即暂停。

### 闹钟后端：双实现自动选路

| 后端 | 适用 | 特点 |
|---|---|---|
| `AlarmKitBackend` | iOS 26+ | 系统级闹钟，**穿透静音与专注模式**，锁屏 / 灵动岛 / Apple Watch 都能显示，无需苹果审批 |
| `NotificationBackend` | iOS 16~25 | 本地通知兜底，静音时不响 |

两者都实现 `AlarmBackend` 协议，`AlarmScheduler` 在初始化时按系统版本选一个。
闹钟时刻之后再补发两条催促通知（+1、+3 分钟）；每天都响的闹钟只占 1 条排程，
指定星期几的按天展开 —— 因为 iOS 对单个 App 只保留 64 条待发通知，条数得省着用。

---

## 打开工程

```
D:\DanceAlarm-iOS\
├── DanceAlarm.xcodeproj          双击打开
├── DanceAlarm\
│   ├── DanceAlarmApp.swift       入口 + 根视图 + 全屏响铃
│   ├── Models\                   Alarm 数据模型、UserDefaults 存储
│   ├── Alarm\                    调度、AlarmKit / 通知双后端、音频、响铃协调
│   ├── Dance\                    DanceJudge 判定引擎、CameraPoseController
│   ├── Views\                    首页、编辑页、响铃页、骨骼叠加、主题
│   ├── Resources\alarm.wav       闹铃音效（脚本生成）
│   └── Assets.xcassets\          图标与主题色
├── .github\workflows\            云编译工作流
└── tools\                        两个脚本（见下）
```

工程用的是 Xcode 16+ 的**文件系统同步分组**，目录里的文件会被自动纳入编译 ——
以后往 `DanceAlarm\` 里加新的 .swift 文件，不用手动往工程里拖。

**系统要求**：Xcode 16 以上（要用 AlarmKit 穿透静音则需 **Xcode 26**）、iOS 16.0 以上。

---

## 排错

### AlarmKit 部分编译不过怎么办

AlarmKit 是 iOS 26 才有的新框架，我是照着官方文档和 WWDC 示例写的，但没有实机验证过。
万一你的 Xcode 报 AlarmKit 相关错误，**不用改任何代码**：

> Xcode → 选中 DanceAlarm target → **Build Settings** → 搜 `Other Swift Flags`
> → 加一项 `-DDISABLE_ALARMKIT`

工程会自动退回纯通知方案，其余功能完全不受影响（只是手机静音时闹钟不响）。
完整操作：`-DDISABLE_ALARMKIT` 这个编译条件同时控制了 `AlarmKitBackend.swift` 和
`AlarmScheduler` 里的选路逻辑，所以加上它之后 AlarmKit 的代码根本不会被编译。

### 闹钟不响的排查顺序

1. **权限**：首页的检查卡片会列出缺哪项，逐条点「去开启」授权。AlarmKit 和通知是两套独立权限。
2. **静音开关 / 专注模式**：iOS 16~25 上通知会跟着静音走，这是平台限制。检查「专注模式」里是否允许了本应用通知。
3. **自己强杀了 App**：iOS 会连带取消 App 的待发通知和闹钟，重新打开一次 App 即可恢复。
4. **时区变化或系统重启**：App 每次回到前台都会自动重排全部闹钟，打开一次就好。

### 音效没响

确认 `DanceAlarm/Resources/alarm.wav` 在编译后位于 App 包根目录（Xcode 的 Copy Bundle Resources
会把子目录里的文件平铺到包根）。若缺失，代码会退回系统提示音，仍能响。

---

## tools 目录

在没有 Mac 的机器上尽量做一点质量兜底：

```bash
# 生成闹铃音效（880Hz + 1760Hz 泛音三连蜂鸣，6 秒，44.1kHz 单声道 16bit）
python tools/make_alarm_sound.py

# 生成 App 图标（1024x1024，无透明通道）
python tools/make_app_icon.py

# Swift 源码粗检：括号配对、字符串闭合、重复定义、中文标点误入代码
python tools/lint_swift_balance.py
```

三个脚本都只用 Python 标准库，不需要装任何包。

**注意**：`lint_swift_balance.py` 只是粗检，能拦住括号不配对之类的低级错误，
**真正的类型检查必须在 macOS 上用 Xcode 编译**。我没法在 Windows 上验证语法正确性。

---

## 需要你在真机上验证的地方

我这边没有 iPhone，也没有 Mac，以下四处只能你装上后看一眼：

1. **AlarmKit 是否真的穿透静音** —— 把手机静音，等闹钟响。这是苹果文档承诺的行为，但值得实测确认。
2. **AlarmKit「停止」按钮是否真的会打开 App** —— 我在 `stopIntent` 上设了 `openAppWhenRun = true`，
   希望按停止后直接进跳舞界面。如果只是响完就结束、不进 App，说明这个 App Intent 需要换个协议类型。
3. **骨骼叠加是否与摄像头画面对齐** —— 前置摄像头做了镜像，叠加层也跟着做了水平翻转。
   如果骨骼线左右反了，改 `RingingView.swift` 里 `SkeletonOverlay(snapshot:mirror:)` 的 `mirror` 参数即可。
4. **判定阈值是否合身** —— 响铃界面底部有「摆幅 / 活跃关节 / 节拍」三个实时数值。
   觉得太松或太紧，把数值发我，我调 `DanceJudge.swift` 里的阈值常量。

有任何异常把现象和机型发我。
