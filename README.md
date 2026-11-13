# Aria

**English** · [简体中文](#简体中文)

[![Latest release](https://img.shields.io/github/v/release/cheneyzhouzhou/aria-player?color=8a7ff0)](https://github.com/cheneyzhouzhou/aria-player/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-lightgrey)

A local music player for macOS and iOS that puts lossless files first. One SwiftUI codebase,
no account, no streaming, and not one line of networking. Point it at a folder and it plays
what's in it, without moving a single file.

![Aria library](docs/screenshots/macos-library.png)

---

## English

### Why another player?

Apple's Music app won't touch FLAC, and most of the alternatives either transcode your
library, make you sign in, or phone home. Aria does none of that. It walks a folder, reads
the tags itself, and plays the files as they are.

### What makes it different

**Sound you can actually check**

- **The signal path is laid out, not implied.** Source → Processing → Output shows whether
  the sample rate matched, whether anything got resampled, what the software gain is, where
  the EQ sits, and how the channels are mapped. Then it gives you a straight answer —
  BIT-PERFECT, UNVERIFIED, STANDARD, PROCESSED, or LOSSY LINK — and tells you what's
  dragging the sound down.
- **Aria can take over your Mac's output device.** Hog mode holds it exclusively and clocks
  it to each track's own sample rate, so nothing gets resampled on the way out. Switch
  between Shared and Exclusive whenever you like, and pick a device from a list that says
  what each one can do (CD, Hi-Res, Ultra Hi-Res).
- **10-band EQ, with Winamp's 18 presets as they were written.** The band centers are
  Winamp's own 70 Hz–16 kHz, and the gains are converted from its 0–63 scale, so the curves
  land where they were designed to.
- **Volume that goes down to −50 dB.** A software fader underneath the system volume, for
  the nights when even the lowest hardware step is too loud with IEMs.

**Your library, read correctly**

- **FLAC, ALAC, WAV, AIFF, CAF, MP3, and AAC — played in place.** No copying, no transcoding,
  no import step. Your folders stay where they are.
- **Aria reads FLAC tags itself.** AVFoundation will decode the audio but won't hand over the
  Vorbis comments, so Aria parses the metadata blocks directly for title, artist, album,
  track number, and embedded cover art. MP3 (ID3) and M4A (iTunes atoms) come from
  AVFoundation — which also lets Aria tell ALAC from AAC, so a lossy file never gets labeled
  lossless.
- **Duplicates get merged. Namesakes don't.** It matches on title, artist, album, *and*
  duration: enough to kill the second copy your downloader left behind, not enough to eat
  two different songs that happen to share a title.
- **Playlists that still work on the other device.** Members are stored by relative path and
  by the tags inside each file, so a playlist built on the Mac still resolves on the phone
  after the paths change.

**It looks like your music**

- **Three themes: Solid, Morandi, and Frosted glass.** Solid takes its color from the cover,
  Morandi is a quiet, dusty palette, and frosted glass blurs whatever sits behind it.
- **A transparency slider that goes all the way.** In the glass theme, Settings › Appearance
  gives you 0–100%. At 0% panels are solid; at 100% the frost, blur, rim, border, and shadow
  are gone. It applies to every surface — rail, page, player bar, nav bar, and the EQ, audio
  chain, and queue popups.
- **The whole window picks up the album's color.** Each cover gets sampled and a
  Material-style tonal palette is built from its dominant hue, so the player recolors itself
  record by record.
- **The mascot is the scrubber.** He walks the progress bar, bops on the beat, and falls
  asleep when you pause. Drag him to seek.

**At home on both platforms**

- **Mac**: a menu bar player built from two fixed-width items, so the controls don't jump
  when the track changes (the title can be hidden). Output device picker, plus one build
  that runs on Apple silicon and Intel alike.
- **iPhone**: plays songs you imported, synced, or bought through the Music app — DRM-free
  only, protected tracks are skipped and never copied. A folder browser that lives inside
  the app, so it keeps working under LiveContainer and SideStore installs. Background audio,
  lock screen, Control Center, and headphone controls.
- **Synced lyrics**: drop a `.lrc` file next to the track or embed lyrics in its tags. They
  scroll beside the cover — and on the Mac there's a full-screen view with the artwork
  blurred behind them.

**Private, and bilingual**

- **No network code. None.** No account, no telemetry, no analytics, not even an update
  check. Your library exists on your machine and nowhere else.
- **English and 简体中文.** Switch in Settings and the choice sticks. On the Mac, the app's
  menus, folder panels, and dialog buttons follow that same choice.

### Screenshots

| macOS — library | macOS — now playing |
|---|---|
| ![Library](docs/screenshots/macos-library.png) | ![Now playing](docs/screenshots/macos-now-playing.png) |

| macOS — appearance | macOS — output & exclusive mode |
|---|---|
| ![Settings](docs/screenshots/macos-settings.png) | ![Output](docs/screenshots/macos-output.png) |

| iOS — library | iOS — now playing | iOS — equalizer |
|---|---|---|
| ![Library](docs/screenshots/ios-library.png) | ![Now playing](docs/screenshots/ios-now-playing.png) | ![Equalizer](docs/screenshots/ios-equalizer.png) |

*Shot in the frosted-glass theme with the interface in Simplified Chinese. Covers are
blurred, so no album art is reproduced here.*

### Download

Everything ships from **[Releases](https://github.com/cheneyzhouzhou/aria-player/releases/latest)**:

| Asset | What it is |
|---|---|
| iOS `.ipa` | iOS 17+, unsigned — re-sign with Sideloadly or AltStore |
| `…-macOS.zip` | macOS 14+, Apple silicon |
| `…-macOS-universal.zip` | macOS 14+, Apple silicon and Intel |

- **iPhone**: sideload the IPA. A free Apple ID signature lasts seven days; re-sign when it
  runs out.
- **Mac**: unzip it and drag `Aria.app` into Applications. If Gatekeeper blocks the first
  launch, right-click the app and choose Open.

### Build it yourself

On a Mac, with Xcode or the Command Line Tools installed:

```bash
./build.sh --run          # builds build/Aria.app and opens it
./build-ipa.sh            # unsigned iOS IPA, numbered from ./VERSION
./build-ios-sim.sh --run  # installs onto a booted simulator
```

For a real iPhone, open `Aria.xcodeproj`, pick your Team under *Signing & Capabilities*, and
hit ⌘R. [docs/BUILDING.md](docs/BUILDING.md) covers signing, Developer Mode, and getting
music onto the phone.

Need something to listen to? `python3 Tools/make-demo-library.py ~/Music/AriaDemo` builds 12
synthetic tracks with real tags and cover art.

### Requirements

| | |
|---|---|
| macOS | 14 Sonoma or later |
| iOS | 17 or later |
| To build | Xcode 16+ for iOS; Command Line Tools are enough for the Mac |
| Dependencies | none — Foundation, AVFoundation, SwiftUI, CoreGraphics |

### Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the metadata parsers, palette extraction,
  the audio graph, and the parts that are easy to get wrong.
- [docs/BUILDING.md](docs/BUILDING.md) — signing and installing on a real device.
- [release-notes/](release-notes) — what changed in each release.

`Platform.swift` is the whole platform layer. Everything else is shared between macOS and
iOS.

### Credits and license

Aria began as a fork of **[aaryann123/aria-player](https://github.com/aaryann123/aria-player)**,
an MIT-licensed local player for macOS and iOS. Everything above was built on top of it.

MIT — see [LICENSE](LICENSE). The interface follows **Material 3 Expressive**; the SwiftUI
here is written from scratch, with no Material code included. The EQ presets are Winamp's
original 18, taken from
[schollz/Winamp-Original-Presets](https://github.com/schollz/Winamp-Original-Presets).

---

## 简体中文

### 为什么还要再做一款播放器？

苹果「音乐」打不开 FLAC，而市面上的替代品，要么转码你的曲库，要么让你先登录，要么在后台
偷偷联网。Aria 一样都不沾：给它一个文件夹，它自己读标签，然后把文件原样放出来。

### 它不一样在哪

**音质，看得见**

- **信号路径不用猜，一段段摊开给你看。** 「音源 → 处理 → 输出」逐段列清楚：采样率对上没有、
  有没有被重采样、软件增益多少、EQ 开在哪一档、声道怎么排。最后给一句干脆的结论——
  无损直通 / 未确认 / 标准 / 已处理 / 有损连接，并说明到底是什么在拖后腿。
- **Mac 上可以把输出设备整个接管。** 用 hog 模式独占设备，时钟跟着每首歌自己的采样率走，
  输出这一步不再重采样。共享 / 独占随时切，设备列表里直接标出各自的档位
  （CD 音质、高清、超高清）。
- **10 段 EQ，配 Winamp 原版 18 个预设。** 频点就是 Winamp 那套 70 Hz–16 kHz，增益由它的
  0–63 刻度换算成分贝，曲线落在当初设计的位置上。
- **音量能压到 −50 dB。** 系统音量之下再加一层细调——有些晚上，耳机在最低那一格还是吵。

**曲库，读得准**

- **FLAC / ALAC / WAV / AIFF / CAF / MP3 / AAC，原地播放。** 不复制、不转码，也没有「导入」
  这一步，文件夹原来在哪就还在哪。
- **FLAC 标签自己读。** AVFoundation 能解码，却不会把 Vorbis 注释交出来，所以标题、艺人、
  专辑、音轨号和内嵌封面都由 Aria 直接解析元数据块；MP3（ID3）和 M4A（iTunes atoms）交给
  AVFoundation，顺便靠它分清 ALAC 和 AAC——有损文件不会被当成无损。
- **重复的合并，同名的留着。** 标题、艺人、专辑、时长四项一起比对：下载器留下的副本会被
  收掉，两首确实不同、只是重名的歌不会被误删。
- **歌单换个设备也认得。** 成员同时记相对路径和文件里的标签，在 Mac 上建的歌单，拷到手机上
  路径变了照样对得上。

**界面跟着唱片走**

- **三套主题：纯色、莫兰迪、毛玻璃。** 纯色从封面取色相，莫兰迪是一片低饱和的灰调，毛玻璃
  把面板背后的内容虚化。
- **透明度滑动条，两端都到头。** 毛玻璃主题下，设置 › 外观 里可以从 0 拉到 100%：0% 面板
  完全实心，100% 霜层、模糊、高光、描边、阴影全部撤掉。侧栏、页面、播放条、导航条，以及
  均衡器、音频链、播放列表三个弹窗，一个都不例外。
- **换张唱片，整个窗口跟着换色。** 每张封面都会取主色，再按 Material 的色调阶梯铺开。
- **吉祥物就是进度条。** 他在进度条上走、跟着节拍晃，一暂停就睡着——想快进，直接拖他。

**Mac 和 iPhone 上都像原生应用**

- **Mac**：菜单栏播放器由两个固定宽度的小块拼成（歌名可以隐藏），切歌时按钮不会乱跳；
  能选输出设备；一个包同时跑在 Apple 芯片和 Intel 上。
- **iPhone**：能播「音乐」里你自己导入、同步或买过的无 DRM 曲目——受保护的直接跳过，绝不
  复制。内置文件夹浏览器，用 LiveContainer、SideStore 签名安装也照样能用。后台播放、锁屏、
  控制中心、耳机线控都支持。
- **同步歌词**：把同名 `.lrc` 放在歌旁边，或者把歌词写进标签，封面旁会跟着滚；Mac 上还有
  整页播放界面，封面虚化垫在歌词后面。

**不联网，也双语**

- **没有一行联网代码。** 不登录、不埋点、不统计，连更新检查都没有。曲库只待在你自己的
  机器上。
- **English 和简体中文。** 设置里点一下立刻生效，下次打开还是它；Mac 上连系统菜单、
  选择文件夹的面板、对话框按钮都跟着走。

### 界面截图

| macOS — 资料库 | macOS — 播放页 |
|---|---|
| ![资料库](docs/screenshots/macos-library.png) | ![播放页](docs/screenshots/macos-now-playing.png) |

| macOS — 外观 | macOS — 输出与独占模式 |
|---|---|
| ![设置](docs/screenshots/macos-settings.png) | ![输出](docs/screenshots/macos-output.png) |

| iOS — 资料库 | iOS — 播放页 | iOS — 均衡器 |
|---|---|---|
| ![资料库](docs/screenshots/ios-library.png) | ![播放页](docs/screenshots/ios-now-playing.png) | ![均衡器](docs/screenshots/ios-equalizer.png) |

*截图为毛玻璃主题、简体中文界面；封面已模糊处理，不展示专辑美术。*

### 下载与安装

都在 **[Releases](https://github.com/cheneyzhouzhou/aria-player/releases/latest)** 里：

| 文件 | 说明 |
|---|---|
| iOS `.ipa` | iOS 17+，未签名，用 Sideloadly 或 AltStore 重签 |
| `…-macOS.zip` | macOS 14+，Apple 芯片 |
| `…-macOS-universal.zip` | macOS 14+，Apple 芯片与 Intel 通用 |

- **iPhone**：侧载 IPA。免费 Apple ID 签名七天有效，到期重签就行。
- **Mac**：解压，把 `Aria.app` 拖进「应用程序」。首次打开被 Gatekeeper 拦下，右键点开它，
  选「打开」。

### 自己编译

在 Mac 上，装好 Xcode 或 Command Line Tools：

```bash
./build.sh --run          # 编译 build/Aria.app 并打开
./build-ipa.sh            # 生成未签名 iOS IPA，版本号取自 ./VERSION
./build-ios-sim.sh --run  # 装到已启动的模拟器
```

要装到真机：打开 `Aria.xcodeproj`，在 *Signing & Capabilities* 里选自己的 Team，按 ⌘R。
签名、开发者模式、怎么把音乐放进手机，都写在 [docs/BUILDING.md](docs/BUILDING.md)。

手头没有曲库？`python3 Tools/make-demo-library.py ~/Music/AriaDemo` 会生成 12 首带标签和
封面的合成音频。

### 环境要求

| | |
|---|---|
| macOS | 14 Sonoma 及以上 |
| iOS | 17 及以上 |
| 编译 | iOS 要 Xcode 16+；Mac 只装 Command Line Tools 也够 |
| 依赖 | 无第三方库，只用 Foundation / AVFoundation / SwiftUI / CoreGraphics |

### 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：元数据解析、取色、音频图，以及容易踩坑的
  地方。
- [docs/BUILDING.md](docs/BUILDING.md)：签名与真机安装全流程。
- [release-notes/](release-notes)：每个版本改了什么。

`Platform.swift` 就是全部的平台层，剩下的代码 macOS 与 iOS 共用。

### 来源与许可

Aria 是从 **[aaryann123/aria-player](https://github.com/aaryann123/aria-player)** 这个 MIT
许可的项目改出来的——一个跑在 macOS 和 iOS 上的本地播放器。上面这些功能，都是在它基础上
做的。

MIT 许可，见 [LICENSE](LICENSE)。界面遵循 **Material 3 Expressive**，SwiftUI 部分是重写的，
没有包含任何 Material 代码。EQ 预设是 Winamp 原版 18 组，来自
[schollz/Winamp-Original-Presets](https://github.com/schollz/Winamp-Original-Presets)。
