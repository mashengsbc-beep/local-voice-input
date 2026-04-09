# Local Voice Input / 本地语音输入

A small macOS menu bar voice input tool that records speech locally, transcribes it with Whisper, and pastes the result back into the active app.

一款 macOS 菜单栏本地语音输入小工具：本地录音、本地 Whisper 转写，并尽量自动把结果填回当前输入框。

## English

### What it does

- Runs as a lightweight macOS menu bar app
- Hold a hotkey to talk, release to transcribe
- Uses local Whisper models: `tiny`, `base`, `small`
- Supports original transcription, English translation, and more natural English output
- Supports Simplified Chinese and Traditional Chinese output
- Lets you switch audio input devices
- Includes a custom replacement dictionary for names, brands, and common corrections

### Requirements

- macOS
- Python 3.9+ recommended
- A local virtual environment in `.venv`, or `LOCAL_VOICE_INPUT_PYTHON` pointing to an executable Python
- Microphone permission
- Accessibility permission for hotkeys and auto-paste

### Install dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Build the app

Build to `dist/` only:

```bash
python build_voice_input_swift_app.py
```

Build and install into `/Applications`:

```bash
python build_voice_input_swift_app.py --install
```

Build, install, and create a zip release:

```bash
python build_voice_input_swift_app.py --install --zip
```

If you have your own local code-signing identity and want to sign the app bundle:

```bash
python build_voice_input_swift_app.py --install --zip --sign
```

If your Python environment is not stored in `.venv`, you can override it:

```bash
LOCAL_VOICE_INPUT_PYTHON=/path/to/python python build_voice_input_swift_app.py --install
```

### Run

- Open `dist/本地语音输入.app`, or
- Open `/Applications/本地语音输入.app` if you used `--install`

### Permissions

For the best experience, enable these in macOS:

- `Privacy & Security -> Microphone`
- `Privacy & Security -> Accessibility`
- `Privacy & Security -> Input Monitoring` if your hotkey setup needs it

### How to use

1. Open the app.
2. Click the target text field in the app where you want text to go.
3. Hold the configured hotkey to start recording.
4. Release the hotkey to stop and transcribe.
5. The result is copied to the clipboard and the app will try to paste it back automatically.

You can also left-click the menu bar icon to start and stop recording manually.

### Output modes

- `Original transcription`: outputs what you said
- `Translate to English`: translates Chinese speech into English
- `Natural English polish`: English output with extra local cleanup for punctuation, casing, and contractions

### Audio input sources

Use the menu bar app's `Audio Input Source` menu to switch between:

- Built-in microphone
- Earbuds / headset microphone
- Third-party USB microphone
- iPhone microphone
- Virtual audio devices such as BlackHole or Loopback

### Custom dictionary

Use the menu bar app's `Open Custom Dictionary` action.

It edits:

```text
~/Library/Application Support/local-voice-input/custom_dictionary.txt
```

Format:

```text
wrong text => desired text
```

Examples:

```text
open ai => OpenAI
閃電說 => 闪电说
```

### Repository layout

- `swift_voice_input_app.swift`: native macOS menu bar app
- `voice_input_core.py`: audio device handling and local Whisper backend
- `voice_input_audio_cli.py`: device listing and recording helper
- `voice_input_transcribe_cli.py`: transcription / translation CLI
- `build_voice_input_swift_app.py`: build, install, and zip script

### Notes

- This repository is source-first. The app bundle records the Python path used at build time, so it is best to build the app locally on the target Mac.
- By default the build is unsigned, which makes the project easier to reproduce on another Mac. Use `--sign` only if you already have a local macOS signing identity set up.
- Whisper translation here uses the local `translate` task built into Whisper.
- The project currently focuses on macOS only.

## 中文

### 这是做什么的

- 一个轻量的 macOS 菜单栏语音输入工具
- 长按热键开始说话，松开后自动转写
- 使用本地 Whisper 模型：`tiny`、`base`、`small`
- 支持原文转写、翻译成英文、自然英文润色
- 支持简体中文和繁體中文输出
- 支持切换语音输入源
- 支持自定义词库，方便修正人名、品牌名和常见错别字

### 环境要求

- macOS
- 建议 Python 3.9 及以上
- 项目根目录下有 `.venv`，或者通过 `LOCAL_VOICE_INPUT_PYTHON` 指定 Python 路径
- 需要麦克风权限
- 需要辅助功能权限来支持热键和自动回填

### 安装依赖

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 构建 App

只生成到 `dist/`：

```bash
python build_voice_input_swift_app.py
```

生成并安装到 `/Applications`：

```bash
python build_voice_input_swift_app.py --install
```

生成、安装并打一个 zip 发布包：

```bash
python build_voice_input_swift_app.py --install --zip
```

如果你本机已经配置好了本地签名证书，也可以这样签名：

```bash
python build_voice_input_swift_app.py --install --zip --sign
```

如果你的 Python 不在 `.venv`，可以这样指定：

```bash
LOCAL_VOICE_INPUT_PYTHON=/path/to/python python build_voice_input_swift_app.py --install
```

### 运行方式

- 直接打开 `dist/本地语音输入.app`
- 如果用了 `--install`，也可以直接打开 `/Applications/本地语音输入.app`

### 权限设置

建议在 macOS 中打开这些权限：

- `隐私与安全性 -> 麦克风`
- `隐私与安全性 -> 辅助功能`
- 如果你的热键配置还需要，也可以打开 `隐私与安全性 -> 输入监控`

### 使用方法

1. 打开 app。
2. 先点一下你要输入文字的输入框。
3. 长按你设置的热键开始说话。
4. 松开热键后会结束录音并开始转写。
5. 结果会先写入剪贴板，并尽量自动粘贴回刚才的输入框。

你也可以直接左键点菜单栏图标，手动开始 / 结束录音。

### 输出模式

- `原文转写`：你说什么，就输出什么
- `翻译成英文`：说中文，直接输出英文
- `自然英文润色`：也是英文输出，但会额外做一层本地英文整理，让句子更自然

### 输入源

在菜单栏 app 的 `语音输入源` 菜单里可以切换：

- 内置麦克风
- 耳机 / 蓝牙耳机麦克风
- 第三方 USB 麦克风
- iPhone 麦克风
- BlackHole、Loopback 之类的虚拟音频设备

### 自定义词库

在菜单栏 app 里点 `打开自定义词库`，会编辑这个文件：

```text
~/Library/Application Support/local-voice-input/custom_dictionary.txt
```

格式：

```text
识别结果 => 你想要的文字
```

例如：

```text
open ai => OpenAI
閃電說 => 闪电说
```

### 仓库结构

- `swift_voice_input_app.swift`：原生 macOS 菜单栏程序
- `voice_input_core.py`：录音设备、Whisper 转写和文本整理
- `voice_input_audio_cli.py`：输入源枚举和录音 helper
- `voice_input_transcribe_cli.py`：转写 / 翻译 CLI
- `build_voice_input_swift_app.py`：构建、安装和打包脚本

### 说明

- 这个仓库是源码优先的项目。构建时会把当时使用的 Python 路径写进 app，所以最稳的方式是在目标 Mac 上本地构建。
- 默认构建不会签名，这样更适合公开仓库复现；只有你自己机器上已经配置好了本地签名证书时，再使用 `--sign`。
- 现在的“翻译成英文”功能，用的是 Whisper 自带的本地 `translate` 任务。
- 当前主要面向 macOS。
