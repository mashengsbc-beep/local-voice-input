#!/usr/bin/env python3
from __future__ import annotations

import os
import platform
import re
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import imageio_ffmpeg
from opencc import OpenCC


ROOT = Path(__file__).resolve().parent
APP_SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "local-voice-input"
LEGACY_MODELS_DIR = ROOT / ".cache" / "faster-whisper"
LOG_PATH = Path("/tmp/local-voice-input.log")
AUDIO_DEVICE_RE = re.compile(r"\[(\d+)\]\s+(.+)$")
CUSTOM_DICTIONARY_PATH = APP_SUPPORT_DIR / "custom_dictionary.txt"
SCRIPT_CONVERTERS = {
    "simplified": OpenCC("t2s"),
    "traditional": OpenCC("s2t"),
}


def resolve_models_dir() -> Path:
    try:
        if LEGACY_MODELS_DIR.is_dir():
            return LEGACY_MODELS_DIR
    except OSError:
        pass
    return APP_SUPPORT_DIR / "models"


MODELS_DIR = resolve_models_dir()


def write_log(text: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(text.rstrip("\n") + "\n")


def format_exception(exc: BaseException) -> str:
    return f"{exc.__class__.__name__}: {exc}"


def ensure_custom_dictionary_file() -> Path:
    APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    if not CUSTOM_DICTIONARY_PATH.exists():
        CUSTOM_DICTIONARY_PATH.write_text(
            "# 自定义词库 / 错别字纠正\n"
            "# 每行一条，格式：识别结果 => 你想要的文字\n"
            "# 例子：\n"
            "# 閃電說 => 闪电说\n"
            "# open ai => OpenAI\n",
            encoding="utf-8",
        )
    return CUSTOM_DICTIONARY_PATH


def load_custom_replacements() -> list[tuple[str, str]]:
    path = ensure_custom_dictionary_file()
    replacements: list[tuple[str, str]] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=>" not in line:
            continue
        wrong, correct = [part.strip() for part in line.split("=>", 1)]
        if wrong and correct:
            replacements.append((wrong, correct))
    return replacements


def apply_custom_replacements(text: str) -> str:
    if not text.strip():
        return text
    for wrong, correct in load_custom_replacements():
        text = text.replace(wrong, correct)
    return text


def convert_chinese_script(text: str, script: str) -> str:
    if not text.strip():
        return text
    if script not in SCRIPT_CONVERTERS:
        return text
    return SCRIPT_CONVERTERS[script].convert(text)


def polish_transcript(text: str, language: str | None = None) -> str:
    polished = text.strip()
    if not polished:
        return polished

    normalized_language = (language or "").lower()
    if normalized_language.startswith("zh"):
        polished = re.sub(
            r"(?:(?<=^)|(?<=[\s，。！？、,.!?]))(?:嗯+|呃+|额+|啊+|那个)(?=(?:[\s，。！？、,.!?]|$))",
            " ",
            polished,
        )
        polished = re.sub(r"\s+", " ", polished)
        polished = re.sub(r"\s*([，。！？；：,.!?;:])\s*", r"\1", polished)
        polished = re.sub(r"([，,]){2,}", "，", polished)
        polished = re.sub(r"([。\.]){2,}", "。", polished)
        polished = re.sub(r"([！？!?]){2,}", r"\1", polished)
        polished = polished.strip()
        return polished or text.strip()

    polished = re.sub(r"\s+", " ", polished)
    polished = re.sub(r"\s+([,.!?;:])", r"\1", polished)
    polished = re.sub(r"([,.!?;:])(?=[A-Za-z0-9])", r"\1 ", polished)
    polished = re.sub(r"\s+", " ", polished)
    polished = polished.strip()
    return polished or text.strip()


def polish_english_translation(text: str, natural: bool = False) -> str:
    polished = polish_transcript(text, language="en")
    if not natural or not polished:
        return polished

    polished = polished.replace("’", "'")
    polished = re.sub(r"\b([A-Za-z]+)(\s+\1\b)+", r"\1", polished, flags=re.IGNORECASE)
    polished = re.sub(r"(?i)\b(?:um+|uh+|er+|ah+|you know|like)\b", " ", polished)

    contractions: list[tuple[str, str | None]] = [
        (r"\b(i)\s+m\b", None),
        (r"\b(you|we|they)\s+re\b", "'re"),
        (r"\b(i|you|we|they)\s+ve\b", "'ve"),
        (r"\b(i|you|we|they|he|she|it)\s+ll\b", "'ll"),
        (r"\b(i|you|we|they|he|she|it)\s+d\b", "'d"),
        (r"\b(he|she|it|that|there|here|what|who|where|how)\s+s\b", "'s"),
    ]

    def _merge_contraction(match: re.Match[str], suffix: str | None) -> str:
        base = match.group(1)
        lowered = base.lower()
        if lowered == "i":
            base = "I"
        if suffix is None:
            return f"{base}'m"
        return f"{base}{suffix}"

    for pattern, suffix in contractions:
        polished = re.sub(pattern, lambda m, s=suffix: _merge_contraction(m, s), polished, flags=re.IGNORECASE)

    polished = re.sub(r"\bcan\s+not\b", "cannot", polished, flags=re.IGNORECASE)
    polished = re.sub(r"\bi\b", "I", polished)
    polished = re.sub(r"\s+", " ", polished)
    polished = re.sub(r"\s+([,.!?;:])", r"\1", polished)
    polished = re.sub(r"([,.!?;:])(?=[A-Za-z])", r"\1 ", polished)
    polished = re.sub(r"\s+", " ", polished).strip(" ,")
    polished = re.sub(r"(^|(?<=[.!?]\s))([a-z])", lambda m: m.group(1) + m.group(2).upper(), polished)

    if polished and polished[-1].isalnum() and len(polished.split()) >= 4:
        polished += "."

    return polished or text.strip()


@dataclass
class AudioDevice:
    index: int
    name: str

    @property
    def label(self) -> str:
        return f"[{self.index}] {self.name}"


class MicrophoneRecorder:
    def __init__(self) -> None:
        self.ffmpeg_path = imageio_ffmpeg.get_ffmpeg_exe()
        self.process: subprocess.Popen[str] | None = None
        self.stderr_thread: threading.Thread | None = None
        self.stderr_lines: list[str] = []
        self.output_path: Path | None = None

    def list_audio_devices(self) -> list[AudioDevice]:
        if platform.system() != "Darwin":
            raise RuntimeError("当前版本先支持 macOS。")

        command = [
            self.ffmpeg_path,
            "-hide_banner",
            "-f",
            "avfoundation",
            "-list_devices",
            "true",
            "-i",
            "",
        ]
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

        devices: list[AudioDevice] = []
        collecting_audio = False
        for line in result.stdout.splitlines():
            if "AVFoundation audio devices" in line:
                collecting_audio = True
                continue
            if "AVFoundation video devices" in line:
                collecting_audio = False
                continue
            if not collecting_audio:
                continue
            match = AUDIO_DEVICE_RE.search(line)
            if not match:
                continue
            devices.append(AudioDevice(index=int(match.group(1)), name=match.group(2).strip()))

        if devices:
            return devices

        raise RuntimeError(
            "没有读到可用麦克风。请确认系统允许当前启动它的应用访问麦克风。\n\n"
            + (result.stdout.strip() or "ffmpeg 没有返回可解析的设备列表。")
        )

    def start(self, device_index: int, output_path: Path | None = None) -> Path:
        if self.process and self.process.poll() is None:
            raise RuntimeError("当前已经在录音中了。")

        timestamp = time.strftime("%Y%m%d-%H%M%S")
        self.output_path = output_path or (Path(tempfile.gettempdir()) / f"local-voice-input-{timestamp}.wav")
        self.stderr_lines = []

        command = [
            self.ffmpeg_path,
            "-hide_banner",
            "-loglevel",
            "warning",
            "-y",
            "-f",
            "avfoundation",
            "-i",
            f":{device_index}",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            str(self.output_path),
        ]

        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        self.stderr_thread = threading.Thread(target=self._consume_stderr, daemon=True)
        self.stderr_thread.start()

        time.sleep(0.25)
        if self.process.poll() is not None:
            raise RuntimeError(self._build_ffmpeg_error("录音启动失败"))

        return self.output_path

    def stop(self) -> Path:
        process = self.process
        output_path = self.output_path
        if process is None or output_path is None:
            raise RuntimeError("当前没有正在进行的录音。")

        try:
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.write("q\n")
                process.stdin.flush()
        except BrokenPipeError:
            pass

        try:
            exit_code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            exit_code = process.wait(timeout=3)

        if self.stderr_thread:
            self.stderr_thread.join(timeout=1)

        self.process = None
        self.stderr_thread = None
        self.output_path = None

        if exit_code != 0:
            raise RuntimeError(self._build_ffmpeg_error(f"录音结束失败，退出码 {exit_code}"))

        if not output_path.exists() or output_path.stat().st_size < 512:
            raise RuntimeError(self._build_ffmpeg_error("没有拿到有效录音文件"))

        return output_path

    def _consume_stderr(self) -> None:
        if self.process is None or self.process.stderr is None:
            return
        for raw_line in self.process.stderr:
            line = raw_line.rstrip()
            if not line:
                continue
            self.stderr_lines.append(line)
            if len(self.stderr_lines) > 40:
                self.stderr_lines = self.stderr_lines[-40:]
            write_log("[ffmpeg] " + line)

    def _build_ffmpeg_error(self, prefix: str) -> str:
        detail = "\n".join(self.stderr_lines[-12:]).strip()
        hint = (
            "请确认系统设置 -> 隐私与安全性 -> 麦克风 中，已经允许当前启动它的应用访问麦克风。"
        )
        if detail:
            return f"{prefix}。\n\n{detail}\n\n{hint}"
        return f"{prefix}。\n\n{hint}"


class LocalWhisperTranscriber:
    def __init__(self, models_dir: Path) -> None:
        self.models_dir = models_dir
        self.models_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._model_name = ""
        self._model = None

    def transcribe(
        self,
        audio_path: Path,
        model_name: str,
        language: str | None,
        task: str = "transcribe",
    ) -> tuple[str, str, float]:
        with self._lock:
            model = self._ensure_model(model_name)
            beam_size = 5 if model_name in {"base", "small"} else 3
            segments, info = model.transcribe(
                str(audio_path),
                language=language,
                task=task,
                beam_size=beam_size,
                best_of=beam_size,
                temperature=0.0,
                condition_on_previous_text=False,
                vad_filter=False,
            )
            text = "".join(segment.text for segment in segments).strip()
            detected_language = getattr(info, "language", language or "unknown")
            probability = float(getattr(info, "language_probability", 0.0) or 0.0)
            return text, detected_language, probability

    def _ensure_model(self, model_name: str):
        if self._model is not None and self._model_name == model_name:
            return self._model

        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise RuntimeError(
                "缺少 faster-whisper 依赖。请先运行 `.venv/bin/pip install -r requirements.txt`。"
            ) from exc

        cpu_threads = max(4, os.cpu_count() or 4)
        self._model = WhisperModel(
            model_name,
            device="cpu",
            compute_type="int8",
            cpu_threads=cpu_threads,
            download_root=str(self.models_dir),
        )
        self._model_name = model_name
        return self._model
