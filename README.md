# Game Emulator

基于 Flutter 与 libretro 核心的多系统模拟器，当前支持 **GBA / GB / GBC**（[mGBA](https://mgba.io/)）与 **FC / NES**（[FCEUmm](https://github.com/libretro/libretro-fceumm)），具备本地游戏库、自动存档、变速游玩与局域网联机骨架。

**仓库地址：** https://github.com/bobotouo/game-emulator

---

## 平台支持

| 平台 | 状态 | 说明 |
|------|------|------|
| **Android** | ✅ 已验证 | 当前主要开发与测试平台，真机可正常游玩 |
| **iOS** | 即将支持 | 待实机验证 |
| **macOS** | 📋 计划中 | Flutter 桌面端适配 |
| **Windows** | 📋 计划中 | Flutter 桌面端适配 |

> **验证说明：** 截至当前版本，功能仅在 **Android 真机** 上完成完整测试（ROM 加载、画面、音频、存档、变速等）。其他平台代码可编译，但尚未完成系统级验证。

---

## 当前进度

### 已完成

| 模块 | 说明 |
|------|------|
| **模拟器核心** | 按 ROM 后缀自动选择核心：`.gba`/`.gb`/`.gbc` → mGBA；`.nes`/`.fds` 等 → FCEUmm |
| **支持格式** | `.gba` `.gb` `.gbc` `.nes` `.fds` `.unf` `.unif` |
| **画面渲染** | Impeller 片元着色器（`FragmentProgram`）+ 同步像素解码，GPU 直绘 |
| **音频** | `flutter_soloud` 低延迟 PCM 流输出，支持倍速同步播放 |
| **虚拟手柄** | 触控按键映射，支持触觉反馈与 libretro 震动回调 |
| **自动存档** | 退出自动保存、进入自动读取；Android 公共目录 / iOS Documents |
| **游戏库** | ROM 导入、缩略图生成、搜索分类、**MD5 去重** |
| **变速齿轮** | 1x ~ 5x 快进，音画同步加速 |
| **设置** | 画面比例、亮度、触觉反馈、存档路径展示、网络端口 |
| **UI** | 游戏库、模拟器、设置、联机大厅与对战房间页面骨架 |

### 进行中 / 部分完成

| 模块 | 说明 |
|------|------|
| **局域网联机** | mDNS 发现、房间 UI 已有，核心同步逻辑待完善 |
| **性能优化** | 持续调优渲染与音频缓冲，降低发热 |
| **NES 实机验证** | FCEUmm 核心集成完成，待 Android 真机测试 |

### 尚未实现

- 蓝牙 / MFi 外接手柄
- 金手指（Cheats）
- 手动多档位存档槽
- 联机输入与状态同步
- GB / GBC 专属 UI 与调色板选项
- 画面滤镜（扫描线、CRT、像素平滑等 Shader 扩展）
- 街机（Arcade）与其他 libretro 核心

---

## 未来计划

1. **联机对战** — 完善 UDP/TCP 帧同步与延迟补偿
2. **外设支持** — 蓝牙手柄、键盘映射
3. **增强体验** — 金手指、作弊码、ROM 信息展示
4. **画面增强** — Shader 滤镜链（HQ2X / Scanlines / Color correction）
5. **跨平台发布** — 跨平台自动构建 CI
6. **云存档**（可选）— 自定义配置云存档存放位置
7. **更多平台** — 街机与其他 libretro 核心扩展

---

## 项目结构

```
lib/
├── core/
│   ├── audio/           # PCM 音频输出
│   ├── haptics/         # 触觉反馈
│   ├── libretro/        # FFI 核心、渲染、存档
│   ├── network/         # 局域网联机
│   ├── settings/        # 应用设置
│   └── storage/         # 存档路径
├── features/
│   └── game_library/    # 游戏库
├── presentation/
│   ├── screens/         # 各页面
│   ├── widgets/         # 虚拟手柄、游戏卡片
│   └── theme/           # 主题
shaders/
└── gba_display.frag     # 画面片元着色器
scripts/
├── build_mgba_libretro.sh    # 编译 mGBA 核心
├── build_fceumm_libretro.sh  # 编译 FCEUmm 核心
└── build_all_cores.sh        # 一键编译全部核心
```

### 编译 libretro 核心

```bash
chmod +x scripts/*.sh

# 全部核心（推荐）
./scripts/build_all_cores.sh android

# 或单独编译
./scripts/build_mgba_libretro.sh android
./scripts/build_fceumm_libretro.sh android
```

产物输出至各平台原生目录（**不会**进入 Flutter assets）：

| 平台 | 输出路径 |
|------|----------|
| Android | `android/app/src/main/jniLibs/arm64-v8a/`（仅 arm64） |
| iOS | `ios/Runner/Frameworks/` |
| macOS（本地调试） | `build/libretro/macos/` |

| 核心 | Android 库名 | iOS 库名 |
|------|----------------|----------|
| mGBA | `libmgba_libretro.so` | `mgba_libretro_ios.dylib` |
| FCEUmm | `libfceumm_libretro.so` | `fceumm_libretro_ios.dylib` |

iOS 需在 Xcode 中将 `Frameworks` 下的 dylib 设为 **Embed & Sign**。

---

## 技术栈

- **UI 框架：** Flutter 3.x（Impeller）
- **状态管理：** Riverpod
- **模拟核心：** [mGBA](https://github.com/mgba-emu/mgba)（GBA/GB/GBC）、[FCEUmm](https://github.com/libretro/libretro-fceumm)（NES/FC）
- **音频：** [flutter_soloud](https://pub.dev/packages/flutter_soloud)
- **网络：** multicast_dns、network_info_plus

---

## 快速开始

```bash
flutter pub get
chmod +x scripts/*.sh
./scripts/build_all_cores.sh android   # 首次需编译核心
flutter run
```

环境要求：Flutter SDK ≥ 3.12、Android SDK + NDK（编译核心时）。

---

## 鸣谢

本项目站在巨人的肩膀上，特别感谢：

- **[mGBA](https://mgba.io/)** — GBA / GB / GBC 模拟核心（MPL 2.0）
- **[FCEUmm](https://github.com/libretro/libretro-fceumm)** — FC / NES 模拟核心（GPL-2.0）
- **[libretro](https://www.libretro.com/)** — 统一的模拟器 API 规范
- **[Flutter](https://flutter.dev/)** — 跨平台 UI 与 Impeller 渲染引擎
- 以及其他开源依赖的作者与社区贡献者

---

## License

本项目应用层代码采用 **MIT** 许可证。

mGBA 核心遵循 **[MPL 2.0](https://github.com/mgba-emu/mgba/blob/master/LICENSE)**；FCEUmm 核心遵循 **[GPL-2.0](https://github.com/libretro/libretro-fceumm/blob/master/COPYING)**。分发包含上述核心的构建产物时，请遵守相应开源协议。
