# 第三方声明

[English](THIRD_PARTY_NOTICES.md)

VoxNote 包含或依赖以下第三方软件及模型文件。各组件均遵循其自身许可证。本文件仅用于署名说明，不改变上述第三方组件的许可条款。

## Argmax OSS Swift

- 项目地址：https://github.com/argmaxinc/argmax-oss-swift
- 版本：1.0.0
- 用途：WhisperKit 和 SpeakerKit 本地语音功能
- 许可证：MIT
- 版权：Copyright (c) 2024 argmax, inc.

Argmax OSS 本身也包含遵循其他条款的第三方软件，详见 Argmax OSS 的 `NOTICES` 文件：

https://github.com/argmaxinc/argmax-oss-swift/blob/main/NOTICES

## Swift Argument Parser

- 项目地址：https://github.com/apple/swift-argument-parser
- 版本：1.7.1
- 用途：模型打包工具链的间接依赖
- 许可证：Apache License 2.0
- 版权：Apple Inc. 及 Swift 项目作者

## WhisperKit Core ML 模型

- 模型来源：https://huggingface.co/argmaxinc/whisperkit-coreml
- 内置变体：`openai_whisper-large-v3-v20240930_626MB`
- 原始模型：https://huggingface.co/openai/whisper-large-v3
- 用途：语音识别
- 原始模型许可证：Apache License 2.0

## SpeakerKit Core ML 模型

- 模型来源：https://huggingface.co/argmaxinc/speakerkit-coreml
- 用途：说话人识别

SpeakerKit 内置模型组件涉及以下上游模型的许可证：

- pyannote segmentation 3.0：MIT 许可证
  https://huggingface.co/pyannote/segmentation-3.0/blob/main/LICENSE
- VBx 说话人聚类：Apache License 2.0
  https://github.com/BUTSpeechFIT/VBx#license
- WeSpeaker 预训练模型：遵循对应数据集的许可证。
  部分基于 VoxCeleb 数据集的 WeSpeaker 模型使用 Creative Commons Attribution 4.0 International。
  https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md#model-license

## 说明

GitHub 源码仓库不包含内置模型文件。Release DMG 中已预置默认模型，用户安装后可直接开始转录，无需首次下载。
