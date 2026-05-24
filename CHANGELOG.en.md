# Changelog

[中文](CHANGELOG.md) · [Back to README](README.en.md)

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

