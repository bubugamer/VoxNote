# Changelog

[中文](CHANGELOG.md) · [Back to README](README.en.md)

## 0.1.4 - 2026-05-28

### Real-time Recording

- Recording now supports pause / resume; after stopping you can save the audio (M4A) or discard it.
- Recording can start immediately even before the model finishes loading; the model attaches automatically once it is ready in the background.
- The speech model is preloaded at app launch, so recording and transcription respond faster.
- Silent segments are skipped during transcription to avoid meaningless output.
- Microphone permission requests now time out after 30 seconds to avoid hanging when the prompt is unresponsive.

### Default Model Change

- The default speech model changed from large-v3 (626MB) to small (~467MB); small is now the recommended model. Existing users are migrated automatically.

### UI Fixes

- Fixed the copy button not showing the "Copied" toast (the toast was previously hidden behind other panels).
- Fixed the settings gear appearing selected / highlighted on launch.
- Top-right icons no longer disappear during recording; they stay visible but disabled.
- Discarding a recording in the live recording view now correctly clears the transcript when returning to the main view.

## 0.1.3 - 2026-05-24

### Refine and Progress Feedback

- Local transcription and Refine are now decoupled: once local transcription finishes, the result can be copied or exported as TXT or Markdown immediately.
- Refine is now manual and cancellable; failures or cancellations keep the local transcript intact.
- Refine now shows the real call progress, such as `Refining 3/18`.
- DeepSeek Refine now uses larger context planning, streaming responses, disabled thinking mode, and timeout handling.
- Copy, TXT export, and Markdown export remain available during Refine and use the current visible text.
- The large bottom number is now a real elapsed-time timer. It stops after local transcription and continues when Refine starts.
- The progress bar shows audio progress during transcription and processed character count during Refine.
- Startup progress is smoother: `loadingModel = 1%`, `preparingAudio = 2%`, and `extractingAudio = 0%`.
- Bottom button labels now use `Start`, `Cancel Refine`, and a disabled `Finished` state.

