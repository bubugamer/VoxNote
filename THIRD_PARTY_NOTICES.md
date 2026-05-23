# Third-Party Notices

VoxNote includes or depends on third-party software and model artifacts. Each
component remains under its own license. This file is for attribution and does
not change the license of those third-party components.

## Argmax OSS Swift

- Project: https://github.com/argmaxinc/argmax-oss-swift
- Version: 1.0.0
- Used for: WhisperKit and SpeakerKit on-device speech features
- License: MIT
- Copyright: Copyright (c) 2024 argmax, inc.

Argmax OSS also includes third-party software under separate terms. See the
Argmax OSS `NOTICES` file for those attributions:

https://github.com/argmaxinc/argmax-oss-swift/blob/main/NOTICES

## Swift Argument Parser

- Project: https://github.com/apple/swift-argument-parser
- Version: 1.7.1
- Used for: transitive dependency through the model bundling toolchain
- License: Apache License 2.0
- Copyright: Apple Inc. and the Swift project authors

## WhisperKit Core ML Models

- Source model repository: https://huggingface.co/argmaxinc/whisperkit-coreml
- Bundled variant: `openai_whisper-large-v3-v20240930_626MB`
- Original model: https://huggingface.co/openai/whisper-large-v3
- Used for: speech recognition
- Original model license: Apache License 2.0

## SpeakerKit Core ML Models

- Source model repository: https://huggingface.co/argmaxinc/speakerkit-coreml
- Used for: speaker diarization

Bundled SpeakerKit model components reference the following upstream model
licenses:

- pyannote segmentation 3.0: MIT license
  https://huggingface.co/pyannote/segmentation-3.0/blob/main/LICENSE
- VBx speaker clustering: Apache License 2.0
  https://github.com/BUTSpeechFIT/VBx#license
- WeSpeaker pretrained model: follows the license of its corresponding dataset.
  Some WeSpeaker pretrained VoxCeleb models use Creative Commons Attribution
  4.0 International.
  https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md#model-license

## Notes

The GitHub source repository does not include the bundled model artifacts. The
release DMG includes the default bundled models so users can start transcription
without a first-run model download.
