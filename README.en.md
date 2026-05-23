# VoxNote

[中文](README.md)

VoxNote is a local speech-to-text app for macOS. It transcribes audio, video, and live recordings into clean text — useful for meeting notes, interview writeups, lecture notes, podcast transcripts, and video subtitle drafts.

## Why VoxNote

- **Local-first**: The core transcription runs entirely on-device, no cloud API or token cost required
- **Three input modes**: Audio files, video files, and live microphone recording (live recording still has a few rough edges)
- **Long-form friendly**: Built for real-world material like meetings, lectures, interviews, and podcasts — handles 120-minute recordings without breaking a sweat
- **Three output options**: One-click copy, TXT export, and Markdown export
- **Optional enhancements**: Speaker diarization and configurable LLM post-correction

## Who It's For

- Anyone who needs to turn meeting recordings into written notes quickly
- Creators who regularly work with interview, podcast, or video material
- Students who want to convert lectures, talks, or voice memos into text
- Mac users who want speech recognition to stay on-device as much as possible

## How to Use

1. Select a folder.
2. Pick an audio or video file from the left sidebar.
3. Click **Start Transcription**.
4. Copy or export the result once transcription completes.

You can also click the record button in the bottom-left corner to transcribe live microphone input.

## Supported Formats

Audio: MP3, WAV, M4A, CAF, AAC, FLAC, AIFF / AIF

Video: MP4, MOV, MKV, AVI, WEBM

## Installation

Requires macOS 14 or later. An Apple Silicon Mac is recommended.

**Download the DMG (recommended):**

1. Open [VoxNote Releases](https://github.com/bubugamer/VoxNote/releases/latest).
2. Download the latest `VoxNote-0.1.2-macOS.dmg`.
3. Open the DMG and drag `VoxNote.app` to `Applications`.
4. Launch VoxNote.

The release DMG includes the default speech recognition and speaker diarization models — no first-run download required. Switching to a different model will trigger an on-demand download.

VoxNote is not signed with a paid Apple Developer ID and has not gone through Apple notarization. If macOS warns that the app is from an unidentified developer, right-click `VoxNote.app`, choose **Open**, and confirm.

**Build from source:**

```bash
git clone https://github.com/bubugamer/VoxNote.git
cd VoxNote
make install
open ~/Applications/VoxNote.app
```

The source repository does not include model files. When building from source, VoxNote will automatically download the required model on the first transcription run.

## Privacy

The core transcription pipeline runs entirely on-device. File transcription requires no microphone permission; only live recording asks for microphone access.

LLM post-correction is an optional feature and is disabled by default. Text is only sent to the external endpoint you configure after you explicitly enable it.

## License

VoxNote is released under the MIT License. For third-party library and model attributions, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) ([中文版](THIRD_PARTY_NOTICES.zh.md)).
