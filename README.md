# VoxNote

VoxNote 是一款 macOS 本地语音转文字应用。它可以把音频、视频和现场录音整理成清晰的文字，适合会议记录、访谈整理、课程笔记、播客转写和视频字幕草稿。

## 为什么用 VoxNote

- 本地优先：主要识别过程在你的 Mac 上完成
- 三种输入：音频文件、视频文件、实时录音
- 长内容友好：适合会议、课程、访谈和播客这类真实素材
- 结果好用：一键复制，支持 TXT 和 Markdown 导出
- 可选增强：支持说话人识别，也可以配置 LLM 做轻量纠错

## 适合谁

- 需要快速整理会议纪要的人
- 经常处理访谈、播客或视频素材的创作者
- 想把课程、讲座、语音备忘录变成文字的学习者
- 希望语音识别尽量在本地完成的 Mac 用户

## 使用方式

1. 选择一个文件夹。
2. 从左侧文件列表中选择音频或视频。
3. 点击 `Start Transcription`。
4. 等待转录完成后复制或导出结果。

也可以点击左下角录音按钮，直接进行实时录音转写。

## 支持格式

音频：MP3、WAV、M4A、CAF、AAC、FLAC、AIFF / AIF

视频：MP4、MOV、MKV、AVI、WEBM

## 安装

需要 macOS 14 或更高版本。推荐使用 Apple Silicon Mac。

普通用户建议直接下载 DMG：

1. 打开 [VoxNote Releases](https://github.com/bubugamer/VoxNote/releases/latest)。
2. 下载最新的 `VoxNote-0.1.1-macOS.dmg`。
3. 打开 DMG，把 `VoxNote.app` 拖到 `Applications`。
4. 启动 VoxNote。

Release 版 DMG 已内置默认语音识别模型和说话人识别模型，安装后可以直接转录，不需要首次下载默认模型。如果切换到其他模型，VoxNote 仍会按需下载。

VoxNote 目前没有使用付费 Apple Developer ID 签名，也没有做 Apple notarization。如果 macOS 提示应用来自未认证开发者，请右键点击 `VoxNote.app`，选择 `Open`，再确认打开。

开发者也可以从源码构建：

```bash
git clone https://github.com/bubugamer/VoxNote.git
cd VoxNote
make install
open ~/Applications/VoxNote.app
```

源码仓库不包含模型文件。从源码构建时，如果本机还没有语音模型，VoxNote 会在首次转录时自动下载所需模型。

## 隐私

VoxNote 的主要识别流程在本机运行。文件转录不需要麦克风权限，只有实时录音需要授权麦克风。

LLM 纠错是可选功能，默认关闭。只有在你主动配置并开启后，文本才会发送到你填写的外部接口。

## 开源协议

VoxNote 使用 MIT License。第三方库和模型说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
