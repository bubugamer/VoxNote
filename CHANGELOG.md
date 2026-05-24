# 更新日志

[English](CHANGELOG.en.md) · [返回 README](README.md)

## 0.1.3 - 2026-05-24

### Refine 与进度反馈

- 本地转录和 Refine 已解耦：本地转录完成后即可复制、导出 TXT 或 Markdown。
- Refine 改为手动触发，可取消；失败或取消时保留本地转录文本。
- Refine 过程中显示真实调用进度，例如 `Refining 3/18`。
- DeepSeek Refine 使用更大的上下文规划、流式返回、关闭思考模式，并增加超时处理。
- Refine 过程中复制、TXT 和 Markdown 导出保持可用，导出当前界面文本。
- 底部大数字改为真实耗时计时器，本地转录完成后停止，Refine 时继续累计。
- 进度条在转录阶段显示音频进度，在 Refine 阶段显示已处理字数。
- 启动阶段进度更稳定：`loadingModel = 1%`，`preparingAudio = 2%`，`extractingAudio = 0%`。
- 底部按钮文案更新为 `Start`、`Cancel Refine` 和不可点击的 `Finished`。

