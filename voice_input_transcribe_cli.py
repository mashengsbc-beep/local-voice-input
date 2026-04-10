#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Transcribe a local audio file with faster-whisper.")
    parser.add_argument("--audio", required=True, help="Path to the audio file.")
    parser.add_argument("--model", default="tiny", choices=["tiny", "base", "small"], help="Whisper model name.")
    parser.add_argument("--language", default="zh", help="Language code or 'auto'.")
    parser.add_argument(
        "--task",
        default="transcribe",
        choices=["transcribe", "translate"],
        help="Transcribe to source language text, or translate speech into English.",
    )
    parser.add_argument(
        "--english-style",
        default="literal",
        choices=["literal", "natural"],
        help="How polished the English translation should sound.",
    )
    parser.add_argument("--polish", action="store_true", help="Apply spoken-language cleanup.")
    parser.add_argument(
        "--script",
        default="original",
        choices=["original", "simplified", "traditional"],
        help="Convert Chinese output to simplified or traditional script.",
    )
    return parser


def load_transcription_dependencies():
    from voice_input_core import (
        CUSTOM_DICTIONARY_PATH,
        LocalWhisperTranscriber,
        MODELS_DIR,
        apply_custom_replacements,
        convert_chinese_script,
        ensure_custom_dictionary_file,
        polish_english_translation,
        polish_transcript,
    )

    return {
        "CUSTOM_DICTIONARY_PATH": CUSTOM_DICTIONARY_PATH,
        "LocalWhisperTranscriber": LocalWhisperTranscriber,
        "MODELS_DIR": MODELS_DIR,
        "apply_custom_replacements": apply_custom_replacements,
        "convert_chinese_script": convert_chinese_script,
        "ensure_custom_dictionary_file": ensure_custom_dictionary_file,
        "polish_english_translation": polish_english_translation,
        "polish_transcript": polish_transcript,
    }


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    audio_path = Path(args.audio).expanduser().resolve()
    if not audio_path.exists():
        print(json.dumps({"error": f"Audio file not found: {audio_path}"}, ensure_ascii=False))
        return 1

    language = None if args.language == "auto" else args.language

    try:
        deps = load_transcription_dependencies()
        deps["ensure_custom_dictionary_file"]()
        transcriber = deps["LocalWhisperTranscriber"](deps["MODELS_DIR"])
        text, detected_language, probability = transcriber.transcribe(
            audio_path=audio_path,
            model_name=args.model,
            language=language,
            task=args.task,
        )
        raw_text = text.strip()
        if args.task == "translate":
            final_text = (
                deps["polish_english_translation"](raw_text, natural=args.english_style == "natural")
                if args.polish
                else raw_text
            )
        else:
            final_text = deps["polish_transcript"](raw_text, language=detected_language) if args.polish else raw_text
            if args.script != "original":
                final_text = deps["convert_chinese_script"](final_text, args.script)
        final_text = deps["apply_custom_replacements"](final_text)
        payload = {
            "text": final_text,
            "raw_text": raw_text,
            "language": detected_language,
            "probability": probability,
            "task": args.task,
            "english_style": args.english_style,
            "custom_dictionary_path": str(deps["CUSTOM_DICTIONARY_PATH"]),
        }
        print(json.dumps(payload, ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"error": f"{exc.__class__.__name__}: {exc}"}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
