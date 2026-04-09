#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from voice_input_core import MicrophoneRecorder


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="List audio input devices or record from a specific macOS AVFoundation device.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list-devices", help="List available audio input devices.")

    record_parser = subparsers.add_parser("record", help="Record from a specific audio input device until stdin receives 'q'.")
    record_parser.add_argument("--device-index", required=True, type=int, help="AVFoundation audio device index.")
    record_parser.add_argument("--output", required=True, help="Output WAV file path.")
    return parser


def list_devices() -> int:
    recorder = MicrophoneRecorder()
    devices = recorder.list_audio_devices()
    payload = {
        "devices": [
            {"index": device.index, "name": device.name, "label": device.label}
            for device in devices
        ]
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def record(device_index: int, output_path: str) -> int:
    recorder = MicrophoneRecorder()
    output = Path(output_path).expanduser().resolve()

    try:
        recorder.start(device_index=device_index, output_path=output)
    except Exception as exc:
        print(json.dumps({"error": f"{exc.__class__.__name__}: {exc}"}, ensure_ascii=False), file=sys.stderr)
        return 1

    print(json.dumps({"status": "recording", "audio_path": str(output)}, ensure_ascii=False), flush=True)

    try:
        while True:
            chunk = sys.stdin.read(1)
            if not chunk:
                break
            if chunk.lower() == "q":
                break
    finally:
        try:
            recorder.stop()
        except Exception as exc:
            print(json.dumps({"error": f"{exc.__class__.__name__}: {exc}"}, ensure_ascii=False), file=sys.stderr)
            return 1

    print(json.dumps({"status": "finished", "audio_path": str(output)}, ensure_ascii=False), flush=True)
    return 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "list-devices":
        return list_devices()
    if args.command == "record":
        return record(device_index=args.device_index, output_path=args.output)
    parser.error("Unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
