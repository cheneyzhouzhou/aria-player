import Foundation

// MARK: - Language

/// The two languages Aria ships with. The raw value is a BCP-47 identifier so it
/// doubles as a `Locale` identifier for SwiftUI's own localized formatting.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    /// What the picker shows for this language — always in the language itself
    /// so the option is recognisable even before it is selected.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

// MARK: - Settings

/// Single source of truth for the chosen language. A singleton so every view
/// (and the model helpers that build dynamic strings) can read the current
/// language without threading it through every call site, while SwiftUI still
/// observes changes through `@StateObject` / `@EnvironmentObject`. The language is
/// only ever written from the main thread (the picker), so the plain property
/// can be read from anywhere — including detached scanning tasks — without
/// actor isolation getting in the way of the localization helpers.
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    private static let key = "appLanguage"

    /// Persisting in `didSet` is the whole point: the settings Picker binds
    /// straight to `$lang.language`, so the old explicit `set()` helper was
    /// never called — the choice lived only in memory and was lost as soon as
    /// the app was force-quit. Any write path now survives a relaunch.
    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
            #if os(macOS)
            AppKitLanguage.sync()
            #endif
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        language = AppLanguage(rawValue: raw ?? "") ?? .english
        #if os(macOS)
        AppKitLanguage.sync()
        #endif
    }

    /// Kept for callers that prefer an explicit setter; `didSet` owns saving.
    func set(_ next: AppLanguage) {
        language = next
    }

    var isChinese: Bool { language == .chineseSimplified }
}

// MARK: - Translation table

/// English strings are used as keys so the app is unchanged when running in
/// English. The Chinese column mirrors the conventions Apple uses in its own
/// macOS / iOS Simplified-Chinese localization (资料库, 播放列表, 均衡器 …) and the
/// wording common to mainstream Chinese music players, so nothing reads as a
/// machine coinage. Missing entries fall back to the English key.
enum L10n {
    static let zh: [String: String] = [
        // Navigation rail & library tabs
        "Library": "资料库",
        "Search": "搜索",
        "Settings": "设置",
        "Songs": "歌曲",
        "Albums": "专辑",
        "Artists": "艺人",
        "Playlists": "播放列表",
        "Recent": "最近添加",

        // Empty / search / scanning
        "Nothing here yet": "这里还什么都没有",
        "Songs, albums, artists": "歌曲、专辑、艺人",
        "Add folder": "添加文件夹",
        "Add a folder": "添加文件夹",
        "Rescan": "重新扫描",
        "Find something to play": "找点音乐来播放",
        "Scanning your music folders…": "正在扫描你的音乐文件夹…",
        "No matches for “X”": "没有与“X”匹配的结果",
        "No music files in your music folders yet. Add the folder they live in — On My iPhone, iCloud Drive, or anywhere the Files app can reach. Aria reads FLAC, ALAC, MP3, AAC, WAV or AIFF.": "你的音乐文件夹里还没有音乐文件。请把它们所在的文件夹添加进来——可以是“我的 iPhone”、iCloud 云盘，或“文件”App 能够访问的任何位置。Aria 支持读取 FLAC、ALAC、MP3、AAC、WAV 或 AIFF。",

        // Settings — appearance
        "Appearance": "外观",
        "Language": "语言",
        "Theme colour": "主题颜色",
        "Glass transparency": "毛玻璃透明度",
        "Tints the library. The player takes its colour from the artwork instead.": "为音乐库着色。播放器则会从封面中提取颜色。",

        // Settings — appearance / theme
        "Theme": "主题",
        "Solid": "纯色",
        "Morandi": "莫兰迪",
        "Pick one of the muted Morandi accents. The player still takes its colour from the artwork.": "从莫兰迪灰调主色中选择一种，播放页仍取自专辑封面。",
        "Frosted glass": "毛玻璃",
        "Light / dark": "深浅模式",
        "System": "跟随系统",
        "Light": "浅色",
        "Dark": "深色",
        "Solid keeps Aria's current colour and surfaces. Frosted glass blurs the view behind each panel for a softer, layered look.": "“纯色”沿用 Aria 当前的配色与表面；“毛玻璃”会令每个面板背后的内容产生模糊，呈现更柔和、更具层次感的效果。",

        // Settings — music folders
        "Show song title in menu bar": "在菜单栏显示歌名",
        "Music folders": "音乐文件夹",
        "Add folder…": "添加文件夹…",
        "Scanning…": "正在扫描…",
        "Add Apple Music Library": "添加Apple Music音乐库",
        "Add a custom folder or songs from Apple Music. DRM-protected songs will be skipped.": "添加自定义文件夹或Apple Music内的歌曲，受版权保护的歌曲将被跳过。",
        "Apple Music library": "Apple Music 音乐库",
        "Media access denied. Enable Music in iOS Settings to use this.": "媒体库访问被拒绝。请在 iOS 设置中允许访问「音乐」后重试。",
        "%d playable · %d DRM-protected skipped": "%d 首可播放 · %d 首受保护已跳过",
        "Music app": "音乐 App",
        "Unknown title": "未知曲目",
        "Unknown artist": "未知艺人",
        "Unknown album": "未知专辑",

        // Settings — output
        "Output": "输出",
        "Capabilities detected on each device": "各设备已检测到的能力",
        "Refresh": "刷新",
        "No output devices found.": "未找到输出设备。",
        "Output mode": "输出模式",
        "Exclusive mode changes the device's clock rate for the whole system and mutes other apps using it. Aria releases the device when you switch back to Shared or quit. If the device refuses the rate or exclusive access, playback falls back to Shared automatically.": "独占模式会改变整个系统的设备时钟频率，并静音其他正在使用它的应用。当你切回“共享”或退出 Aria 时，设备会被释放。如果设备拒绝该频率或独占访问，播放会自动回退到“共享”模式。",
        "Playing through": "正在通过",
        "Bluetooth re-encodes audio before it reaches your headphones, so lossless files stop being lossless at that point. Wired headphones or a USB-C DAC keep the full quality.": "蓝牙会在声音到达耳机前重新编码，因此无损文件到这一步便不再是无损。有线耳机或 USB-C DAC 能保留完整音质。",
        "Aria tells the hardware to run at the music file's own sample rate.": "Aria会通知硬件以音乐文件自身的采样率运行。",

        // Settings — library
        "Last scanned": "上次扫描",
        "Rescan library": "重新扫描资料库",
        "In use": "使用中",

        // Settings — volume
        "Volume": "音量",
        "Volume inside Aria, on top of the system volume — down to −50 dB when iOS's lowest step is still too loud.": "Aria 内部的音量叠加在系统音量之上——当 iOS 最低档位仍然太响时，可低至 −50 dB。",
        "mute": "静音",

        // Settings — alerts
        "No music files in that folder": "该文件夹中没有音乐文件",
        "Aria can't open that folder": "Aria 无法打开该文件夹",
        "Choose another": "选择其他",
        "Add anyway": "仍然添加",
        "Cancel": "取消",
        "Aria reads FLAC, ALAC, MP3, AAC, WAV or AIFF, so this folder would show up with nothing in it. The path above is what was picked — if your music lives somewhere else, pick that folder instead.": "Aria 支持读取 FLAC、ALAC、MP3、AAC、WAV 或 AIFF，因此这个文件夹显示出来时会是空的。上方是该文件夹的路径——如果你的音乐在别处，请改选那个文件夹。",
        "iOS only lets an app read a folder it was handed permission for, and a SideStore-signed build sometimes never receives that permission. Copying the music into On My iPhone → Aria from the Files app and adding that folder here works around it.": "iOS 只允许应用读取已授予权限的文件夹，而 SideStore 签名的版本有时始终收不到该权限。从“文件”App 把音乐拷贝到“我的 iPhone → Aria”中，再在此处添加该文件夹即可绕过此问题。",

        // Player — now playing
        "Now Playing": "正在播放",
        "Back to library": "返回资料库",
        "Hide lyrics": "隐藏歌词",
        "Show lyrics": "显示歌词",
        "Open equalizer": "打开均衡器",
        "Hide queue": "隐藏播放队列",
        "Show queue": "显示播放队列",
        "Turn shuffle off": "关闭随机播放",
        "Turn shuffle on": "打开随机播放",
        "Previous track": "上一首",
        "Pause": "暂停",
        "Play": "播放",
        "Next track": "下一首",
        "Repeat all": "列表循环",
        "Repeat this track": "单曲循环",
        "Turn repeat off": "关闭循环",
        "Audio chain": "音频链路",
        "No lyrics": "暂无歌词",
        "Add a .lrc file with the same name beside the audio file, or embed lyrics in the file's tags.": "请在该音频文件旁放置一个同名的 .lrc 文件，或将歌词嵌入到文件的标签中。",
        "Up next": "接下来播放",
        "Nothing queued": "队列为空",
        "LOCAL": "本地",

        // Playlists
        "New playlist": "新建播放列表",
        "Import folders": "导入文件夹",
        "No playlists yet": "还没有播放列表",
        "“Import folders” makes one playlist per top-level folder in your library.": "“导入文件夹”会为音乐库中每个顶层文件夹各创建一个播放列表。",
        "Name": "名称",
        "Create": "创建",
        "Delete": "删除",
        "Remove from playlist": "从播放列表移除",
        "Rename playlist": "重命名播放列表",
        "Save": "保存",
        "Play album": "播放专辑",
        "Reveal in Finder": "在访达中显示",
        "Copy title": "复制标题",
        "Add to playlist": "添加到播放列表",

        // Equalizer
        "Equalizer": "均衡器",
        "Custom": "自定",
        "PRESETS": "预设",
        "BANDS": "频段",
        "Reset": "重置",
        "PREAMP": "前置放大",
        "Heavy boosts can clip. Pull the preamp down if loud passages distort.": "过大的增益会导致削波。如果大音量段落出现失真，请调低前置放大。",

        // Equalizer preset names (Winamp's 18 standard presets)
        "Flat": "平直",
        "Rock": "摇滚",
        "Pop": "流行",
        "Dance": "舞曲",
        "Techno": "电子",
        "Club": "俱乐部",
        "Party": "派对",
        "Live": "现场",
        "Ska": "斯卡",
        "Reggae": "雷鬼",
        "Soft": "柔和",
        "Soft Rock": "软摇滚",
        "Classical": "古典",
        "Large Hall": "大厅",
        "Full Bass": "重低音",
        "Bass & Treble": "高低音",
        "Full Treble": "重高音",
        "Laptop / Headphones": "笔记本 / 耳机",

        // Audio chain
        "NO SIGNAL": "无信号",
        "BIT-PERFECT": "无损直通",
        "UNVERIFIED": "未确认",
        "STANDARD": "标准",
        "PROCESSED": "已处理",
        "LOSSY LINK": "有损连接",
        "Nothing playing": "当前没有播放",
        "Maximum quality": "最高音质",
        "Exclusive not confirmed": "独占模式未确认",
        "Shared output": "共享输出",
        "Software processed": "软件处理",
        "Re-encoded": "已重新编码",
        "Source → processing → output": "音源 → 处理 → 输出",
        "Source": "音源",
        "Processing": "处理",
        "Profile": "配置",
        "TO REACH BIT-PERFECT": "如何达到无损直通",
        "Start playback to inspect the signal path.": "开始播放以查看信号路径。",
        "Exclusive access confirmed, and the device runs at the file's own rate and depth. No gain, EQ, resampling, mixing or re-encoding in the path.": "已确认独占访问，且设备以文件自身的采样率和位深运行。信号路径中没有任何增益、均衡器、重采样、混音或重新编码。",
        "The device is running at the track's sample rate, but Aria could not confirm exclusive (hog) access. If another app plays, the macOS mixer will mix it in, so bit-perfect output is not guaranteed.": "设备正以曲目的采样率运行，但 Aria 无法确认独占（hog）访问。如果其他应用同时播放，macOS 混音器会将其混入，因此无法保证无损直通输出。",
        "Audio goes through the system mixer alongside other apps. Even with a matching sample rate, shared output cannot be guaranteed bit-perfect — the mixer may resample or mix in other audio.": "音频会与其他应用一起经过系统混音器。即使采样率一致，共享输出也无法保证无损直通——混音器可能会进行重采样或混入其他音频。",
        "Something in the path is changing the samples. See the checklist below for exactly what to fix.": "信号路径中的某些环节正在改变采样。请参阅下方的清单，了解具体需要修正的地方。",
        "Bluetooth or AirPlay re-encodes the stream before it reaches your headphones. Wired headphones or a USB-C DAC keep the full quality.": "蓝牙或 AirPlay 会在声音到达耳机前重新编码音频流。有线耳机或 USB-C DAC 能保留完整音质。",
        "No track loaded": "尚未载入曲目",
        "Play a file to see its format here.": "播放一个文件以在此查看其格式。",
        "No audio is running through the engine.": "当前没有音频经过引擎。",
        "Idle": "空闲",
        "Attenuated X": "已衰减 X",
        "Equalizer active": "均衡器已启用",
        "Resampling": "重采样",
        "Untouched": "未处理",
        "Software volume X": "软件音量 X",
        "EQ on (X)": "均衡器开启（X）",
        "EQ off": "均衡器关闭",
        "Sample rate matched": "采样率已匹配",
        "Mono": "单声道",
        "Stereo": "立体声",
        "channels": "声道",
        "ch": "声道",
        "lossless": "无损",
        "lossy": "有损",
        "Bluetooth/AirPlay re-encode": "蓝牙/AirPlay 重新编码",
        "CoreAudio": "Core Audio",
        "Exclusive (hog)": "独占（hog）",
        "Exclusive unverified": "独占未确认",
        "Shared mixer": "共享混音",

        // Audio chain — fragment-level strings
        "bit": "位",
        "Software volume": "软件音量",
        "EQ on": "均衡器开启",
        "Resampled": "重采样",
        "Mode": "模式",
        "Use wired headphones or a USB-C DAC — Bluetooth/AirPlay re-encodes the stream.": "使用有线耳机或 USB-C DAC——蓝牙/AirPlay 会重新编码音频流。",
        "Turn the equalizer off (and reset the preamp to 0 dB).": "关闭均衡器（并将前置放大重置为 0 dB）。",
        "Use a lossless file (FLAC/ALAC/WAV); this source is not lossless integer PCM.": "请使用无损文件（FLAC/ALAC/WAV）；此音源并非无损整数 PCM。",
        "Enable Exclusive output mode and confirm macOS grants hog access.": "开启独占输出模式，并确认 macOS 已授予 hog 访问权限。",
        "iOS always routes audio through the system mixer; bit-perfect output isn't available on this platform.": "iOS 始终通过系统混音器路由音频；此平台无法做到无损直通输出。",

        // Output mode
        "Shared": "共享",
        "Exclusive": "独占",
        "Exclusive · bit-perfect": "独占 · 无损直通",
        "Audio goes through the macOS mixer alongside other apps. The system may resample it. Best for everyday use.": "音频会与其他应用一起经过 macOS 混音器，系统可能会对其进行重采样。适合日常使用。",
        "Aria takes exclusive access to the device (hog mode) and switches it to each track's own sample rate, so no resampling or mixing happens.": "Aria 会独占访问该设备（hog 模式），并将其切换到每首曲目自身的采样率，因此不会发生重采样或混音。",

        // Output device capability badge
        "CD quality": "CD 音质",
        "Hi-Res": "高清",
        "Ultra Hi-Res": "超高清",

        // iOS output route names
        "Bluetooth": "蓝牙",
        "Wired headphones": "有线耳机",
        "Phone speaker": "手机扬声器",
        "AirPlay": "AirPlay",
        "USB audio": "USB 音频",
        "Unknown": "未知",

        // macOS exclusive status sentences
        "Shared — the macOS mixer stays in charge; other apps can play at the same time.": "共享——macOS 混音器仍主导输出，其他应用可以同时播放。",
        "Fell back to Shared — X": "已回退到共享模式——X",
        "Output: X. Shared mode — the macOS mixer is still in the path.": "输出：X。共享模式——macOS 混音器仍在信号路径中。",
        "Exclusive will engage when you start playing a track.": "当你开始播放曲目时，独占模式将会启用。",
        "The output device keeps resetting the audio engine — pick another device or switch to Shared.": "输出设备持续重置音频引擎——请选择其他设备，或切换到共享模式。",
        "macOS refused to route audio to X — playing through the system default instead. Try another device, or toggle Exclusive mode.": "macOS 拒绝将音频路由到 X——改为通过系统默认设备播放。请尝试其他设备，或切换独占模式。",
        "the chosen device": "所选设备",
        "system default": "系统默认",

        // App menu (macOS)
        "Playback": "播放",
        "Next Track": "下一首",
        "Previous Track": "上一首",
        "Skip Forward 15s": "快进 15 秒",
        "Skip Back 15s": "快退 15 秒",
        "Shuffle": "随机播放",
        "Repeat": "循环",
        "Off": "关闭",
        "All": "列表循环",
        "One": "单曲循环",

        // Menu-bar player (macOS)
        "Menu bar": "菜单栏",
        "Show the song and controls in the menu bar": "在菜单栏显示歌曲与控制",
        "Aria keeps the current song in the system menu bar, with play, pause and track skipping one click away.": "在系统菜单栏常驻当前歌曲，点一下即可播放、暂停与切歌。",
        "Show Aria": "显示 Aria",
        "Quit Aria": "退出 Aria",

        // Misc
        "no music here": "这里没有音乐",
        "Never": "从未",
        "Just now": "刚刚",

        // Folder browser (iOS)
        "Folders Aria can read on this phone": "Aria 可读取的本机文件夹",
        "No folders inside this one.": "这个文件夹里没有子文件夹。",
        "No music files here or below.": "这里及其子文件夹中没有音乐文件。",
        "Use this folder": "使用此文件夹",
        "Use Folder": "使用此文件夹",
        "Empty": "空",
        "Can't read this folder": "无法读取该文件夹",
        "app container": "应用容器",
        "The folder Files shows for LiveContainer is listed here — copy music into it and Aria can read it without the system picker.": "这里列出了 LiveContainer 在“文件”中显示的文件夹——把音乐拷贝进去，Aria 无需系统选择器即可读取。",
        "These are the folders this build can already open. Copy music into Aria's Documents from the Files app and it shows up here.": "这些是此版本已经能够打开的文件夹。从“文件”App 把音乐拷贝到 Aria 的“文稿”中，它就会显示在这里。",
        "Aria's folder": "Aria 的文件夹",
        "Aria's own folder": "Aria 的文件夹",
        "Where anything you share into Aria lands": "你分享到 Aria 的内容都会存放在这里",
        "Aria's Documents": "Aria 的文稿",
        "Documents": "文稿",
        "Documents above Aria": "Aria 上方的文稿",
        "Running inside LiveContainer": "正在 LiveContainer 内运行",
        "Running as a normal install": "正在以正常安装方式运行",
        "Copy": "复制",
        "Copied": "已复制",
        "LiveContainer's system picker cannot always hand a folder back to a guest app. Long-press Aria → Settings → enable Fix File Picker, or use Browse phone…, which stays inside Aria.": "LiveContainer 的系统选择器并非总能将一个文件夹交还给访客应用。长按 Aria → 设置 → 开启“修复文件选择器”，或使用“浏览手机…”，它始终在 Aria 内部运行。",
    ]
}

// MARK: - Helpers

/// Localized string for a static English key. Returns the key unchanged when the
/// current language is English or no translation exists, so the UI never blanks.
func L(_ englishKey: String) -> String {
    guard LanguageSettings.shared.isChinese else { return englishKey }
    return L10n.zh[englishKey] ?? englishKey
}

/// Localized phrasing for a count + noun, including the Chinese measure word.
/// English: "1 song" / "2 songs". Chinese: "1 首歌曲" / "2 首歌曲".
func Lplural(_ count: Int, _ singular: String, many: String? = nil) -> String {
    guard LanguageSettings.shared.isChinese else {
        let word = count == 1 ? singular : (many ?? singular + "s")
        return "\(count) \(word)"
    }
    // Chinese pairs every noun with a measure word; group the common ones here.
    let measure: String
    let noun: String
    switch singular {
    case "song", "track": (measure, noun) = ("首", "歌曲")
    case "album": (measure, noun) = ("张", "专辑")
    case "artist": (measure, noun) = ("位", "艺人")
    case "playlist": (measure, noun) = ("个", "播放列表")
    case "folder": (measure, noun) = ("个", "文件夹")
    default: (measure, noun) = ("", L(singular))
    }
    return "\(count) \(measure)\(noun)"
}

/// Localized "no matches for …" template that keeps the user's query.
func Lmatch(_ query: String) -> String {
    guard LanguageSettings.shared.isChinese else {
        return "No matches for “\(query)”"
    }
    return "没有与“\(query)”匹配的结果"
}

/// Localized long duration: "1 hr 2 min" → "1 小时 2 分钟".
func Lduration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    if LanguageSettings.shared.isChinese {
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(m) 分钟"
    }
    return h > 0 ? "\(h) hr \(m) min" : "\(m) min"
}
