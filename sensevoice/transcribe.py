#!/usr/bin/env python3
"""SenseVoice 音频转文字 CLI

用法:
    transcribe.exe <audio_file>  # Win
    transcribe <audio_file>      # Mac/Linux

输入:任何 ffmpeg 能读的格式(wav/mp3/ogg/m4a/flac/...)
输出:识别文字,打印到 stdout

依赖:
    - sherpa_onnx (PyPI)
    - 系统 PATH 里有 ffmpeg(Win 学生通常装了 OpenClaw 同时装了 ffmpeg)
"""
import os
import sys
import shutil
import subprocess
import tempfile
import wave

# 强制 stdout/stderr UTF-8(Win 控制台默认 GBK,中文识别结果会乱码)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import numpy as np
import sherpa_onnx


def read_wav_16k_mono(wav_path: str):
    """读 16kHz mono PCM s16le wav,返回 (np.float32 array, sample_rate)"""
    with wave.open(wav_path, "rb") as f:
        sample_rate = f.getframerate()
        n_channels = f.getnchannels()
        sampwidth = f.getsampwidth()
        n_frames = f.getnframes()
        raw = f.readframes(n_frames)
    if sampwidth != 2:
        raise RuntimeError(f"只支持 16-bit PCM wav,实际 {sampwidth*8}-bit")
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if n_channels > 1:
        samples = samples.reshape(-1, n_channels).mean(axis=1)
    return samples, sample_rate


def get_base_dir() -> str:
    """打包后 exe 同目录,开发时脚本同目录"""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def transcode_to_wav(src: str) -> str:
    """用系统 ffmpeg 转成 16kHz mono pcm_s16le wav"""
    if not shutil.which("ffmpeg"):
        sys.stderr.write("ERROR: ffmpeg 未在系统 PATH 里。请装 ffmpeg 后重试。\n")
        sys.exit(2)

    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", src, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", tmp.name],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"ERROR: ffmpeg 转码失败: {e}\n")
        os.unlink(tmp.name)
        sys.exit(3)
    return tmp.name


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: transcribe <audio_file>\n")
        return 1

    audio_in = sys.argv[1]
    if not os.path.isfile(audio_in):
        sys.stderr.write(f"ERROR: 音频文件不存在: {audio_in}\n")
        return 1

    base = get_base_dir()
    model_path = os.path.join(base, "model.int8.onnx")
    tokens_path = os.path.join(base, "tokens.txt")

    if not os.path.isfile(model_path) or not os.path.isfile(tokens_path):
        sys.stderr.write(f"ERROR: 找不到 model 或 tokens(应在 {base})\n")
        return 1

    # 1. 转码到 16kHz wav(sherpa-onnx 要求)
    wav_path = audio_in
    cleanup = False
    if not audio_in.lower().endswith(".wav"):
        wav_path = transcode_to_wav(audio_in)
        cleanup = True

    try:
        # 2. 加载模型 + 识别
        recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=model_path,
            tokens=tokens_path,
            num_threads=1,
            use_itn=True,
            language="auto",
            debug=False,
        )
        stream = recognizer.create_stream()
        samples, sample_rate = read_wav_16k_mono(wav_path)
        stream.accept_waveform(sample_rate, samples)
        recognizer.decode_stream(stream)
        print(stream.result.text)
        return 0
    finally:
        if cleanup:
            try:
                os.unlink(wav_path)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
