# 录音剪辑

iPhone 与 Mac 上的录音编辑应用。可以录音、导入音频、按选区裁剪，并对较稳定的底噪做离线去噪。

界面语言为中文，显示名是「录音剪辑」。不依赖第三方库。

## 功能

- 录音：48 kHz、单声道、16-bit WAV，显示计时和输入电平
- 导入 WAV、M4A、CAF；立体声会保留，去噪时逐声道处理
- 波形预览、播放、拖动定位
- 保留选区，或删除选区并让后面的音频前移
- 撤销与重做，各保留最近 8 步
- 去噪强度 0–100，可处理整段或仅选区；也可以把选区当作噪声样本
- 保存写回当前录音；导出 WAV（iPhone 走系统分享，Mac 走存储面板）

去噪适合风扇、底噪、嘶声、交流声这类比较稳定的噪声。突发噪声和嘈杂人声的效果有限。

## 环境

- Xcode 15.4 或更新版本
- iOS 17 及以上，仅 iPhone
- macOS 14 及以上

用 Xcode 打开 `RadioTool.xcodeproj`，选择 scheme **RadioTool**，运行目标选「我的 Mac」或 iPhone 模拟器。真机录音需要允许麦克风权限。

## 去噪算法

离线处理，模型是加性噪声。实现在 `RadioTool/Audio/Denoise/SpectralDenoiser.swift`，FFT 使用 Accelerate。

1. 对音频做短时傅里叶变换：Hann 窗，FFT 长度 2048，hop 512
2. 估计噪声功率：把频谱按大约 1 秒分块取平均，再对每个频点取这些块里的最小值。安静的那一秒会把噪声底和人声分开
3. 用 decision-directed 平滑先验信噪比，计算维纳增益 `G = ξ / (ξ + 1)`，并限制增益下限。强度为 0 时直接返回原音频
4. 保留带噪相位，重叠相加还原。处理区间两端做约 10 毫秒交叉淡化，避免拼接咔嗒声

若选区被标成噪声样本，则用该选区的平均功率谱作为噪声轮廓，不再走自动最小统计。

## 测试

逻辑测试在 Mac 上运行，不依赖麦克风：

```bash
xcodebuild test -project RadioTool.xcodeproj -scheme RadioTool -destination 'platform=macOS'
```

覆盖三件事：STFT 往返误差低于约 -60 dB、440 Hz 正弦加白噪声后信噪比提高、裁剪和删除后的样本长度正确。

## 目录

```text
RadioTool/                 SwiftUI 应用
  Features/Library/        录音列表与导入
  Features/Recorder/       麦克风采集
  Features/Editor/         波形、选区、保存与导出
  Audio/Denoise/           STFT 与维纳去噪
  Audio/                   读写、播放
RadioToolTests/            单元测试
```

录音文件保存在应用文档目录的 `Recordings/` 下，旁边的 `index.json` 记录标题、日期、采样率和声道数。
