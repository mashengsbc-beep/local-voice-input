#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


APP_NAME = "本地语音输入"
APP_BUNDLE = f"{APP_NAME}.app"
APP_IDENTIFIER = "com.ms.localvoiceinput.swift"
APP_VERSION = "2.6.0"
APP_BUILD = "7"

ROOT = Path(__file__).resolve().parent
DIST_APP = ROOT / "dist" / APP_BUNDLE
APPLICATIONS_APP = Path("/Applications") / APP_BUNDLE
RELEASE_DIR = ROOT / "release"
MACOS_DIR = DIST_APP / "Contents" / "MacOS"
RESOURCES_DIR = DIST_APP / "Contents" / "Resources"

SWIFT_SOURCE = ROOT / "swift_voice_input_app.swift"
TRANSCRIBE_HELPER = ROOT / "voice_input_transcribe_cli.py"
AUDIO_HELPER = ROOT / "voice_input_audio_cli.py"
CORE_HELPER = ROOT / "voice_input_core.py"
APP_ICON_SVG = ROOT / "assets" / "app-icon.svg"

SIGNING_IDENTITY_NAME = "Local Voice Input Signer"
SIGNING_KEYCHAIN = Path.home() / "Library" / "Keychains" / "local-voice-input-signing.keychain-db"
SIGNING_KEYCHAIN_PASSWORD = "localvoiceinput"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the native macOS app bundle for Local Voice Input.")
    parser.add_argument("--install", action="store_true", help="Also copy the built app into /Applications.")
    parser.add_argument("--zip", action="store_true", help="Create a release zip in ./release after building.")
    parser.add_argument("--sign", action="store_true", help="Code sign the app if a local signing identity is available.")
    return parser.parse_args()


def resolve_backend_python() -> Path:
    env_path = os.environ.get("LOCAL_VOICE_INPUT_PYTHON")
    if env_path:
        candidate = Path(os.path.abspath(os.path.expanduser(env_path)))
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
        raise SystemExit(f"LOCAL_VOICE_INPUT_PYTHON is set but not executable: {candidate}")

    candidate_paths = [
        ROOT / ".venv" / "bin" / "python",
        ROOT.parent / ".venv" / "bin" / "python",
        ROOT.parent.parent / ".venv" / "bin" / "python",
    ]
    for raw_candidate in candidate_paths:
        candidate = Path(os.path.abspath(os.path.expanduser(str(raw_candidate))))
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate

    raise SystemExit(
        "Could not find a backend Python interpreter.\n"
        "Create a local .venv first, or set LOCAL_VOICE_INPUT_PYTHON to an executable Python path."
    )


def write_plist(backend_python: Path) -> None:
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": APP_NAME,
        "CFBundleIdentifier": APP_IDENTIFIER,
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": APP_VERSION,
        "CFBundleVersion": APP_BUILD,
        "CFBundleIconFile": "AppIcon",
        "LSUIElement": True,
        "NSPrincipalClass": "NSApplication",
        "NSMicrophoneUsageDescription": "Local Voice Input needs access to your microphone so it can record speech.",
        "NSAppleEventsUsageDescription": "Local Voice Input needs automation access so it can paste transcribed text back into the active app.",
        "BackendPythonExecutable": str(backend_python),
    }
    plist_path = DIST_APP / "Contents" / "Info.plist"
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    with plist_path.open("wb") as handle:
        plistlib.dump(info, handle)


def build_app_icon(output_dir: Path) -> Path | None:
    if not APP_ICON_SVG.exists():
        return None

    with tempfile.TemporaryDirectory(prefix="local-voice-input-icon-") as temp_dir_raw:
        temp_dir = Path(temp_dir_raw)
        png_path = temp_dir / "app-icon.png"
        iconset_dir = temp_dir / "AppIcon.iconset"
        iconset_dir.mkdir(parents=True, exist_ok=True)

        subprocess.run(
            ["qlmanage", "-t", "-s", "1024", "-o", str(temp_dir), str(APP_ICON_SVG)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        ql_png = temp_dir / f"{APP_ICON_SVG.name}.png"
        if ql_png.exists():
            ql_png.rename(png_path)

        if not png_path.exists():
            raise SystemExit(f"Failed to render app icon PNG from {APP_ICON_SVG}")

        sizes = [16, 32, 128, 256, 512]
        for size in sizes:
            base = iconset_dir / f"icon_{size}x{size}.png"
            retina = iconset_dir / f"icon_{size}x{size}@2x.png"
            subprocess.run(
                ["sips", "-z", str(size), str(size), str(png_path), "--out", str(base)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["sips", "-z", str(size * 2), str(size * 2), str(png_path), "--out", str(retina)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        icon_path = output_dir / "AppIcon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icon_path)], check=True)
        return icon_path


def resolve_signing_identity() -> str:
    if not SIGNING_KEYCHAIN.exists():
        return "-"

    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning", str(SIGNING_KEYCHAIN)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    for line in result.stdout.splitlines():
        if SIGNING_IDENTITY_NAME in line:
            return SIGNING_IDENTITY_NAME
    return "-"


def sign_app(app_path: Path) -> None:
    identity = resolve_signing_identity()
    if identity == "-":
        print("warning: local signing identity not found, building without code signing", file=sys.stderr)
        return

    subprocess.run(
        ["security", "unlock-keychain", "-p", SIGNING_KEYCHAIN_PASSWORD, str(SIGNING_KEYCHAIN)],
        check=False,
    )
    subprocess.run(
        [
            "security",
            "set-key-partition-list",
            "-S",
            "apple-tool:,apple:,codesign:",
            "-s",
            "-k",
            SIGNING_KEYCHAIN_PASSWORD,
            str(SIGNING_KEYCHAIN),
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "codesign",
            "--force",
            "--deep",
            "--sign",
            identity,
            "--keychain",
            str(SIGNING_KEYCHAIN),
            str(app_path),
        ],
        check=True,
    )


def build_dist(backend_python: Path) -> None:
    subprocess.run(["pkill", "-f", str(DIST_APP / "Contents" / "MacOS" / APP_NAME)], check=False)
    subprocess.run(["pkill", "-f", str(APPLICATIONS_APP / "Contents" / "MacOS" / APP_NAME)], check=False)
    subprocess.run(["pkill", "-f", "local-voice-input-"], check=False)

    if DIST_APP.exists():
        shutil.rmtree(DIST_APP)

    MACOS_DIR.mkdir(parents=True, exist_ok=True)
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    built_icon = build_app_icon(RESOURCES_DIR)
    write_plist(backend_python)

    subprocess.run(
        [
            "swiftc",
            "-framework",
            "Cocoa",
            "-framework",
            "AVFoundation",
            "-framework",
            "ApplicationServices",
            str(SWIFT_SOURCE),
            "-o",
            str(MACOS_DIR / APP_NAME),
        ],
        check=True,
        cwd=ROOT,
    )

    for helper in (TRANSCRIBE_HELPER, AUDIO_HELPER, CORE_HELPER):
        shutil.copy2(helper, RESOURCES_DIR / helper.name)
    if built_icon is not None and not built_icon.exists():
        raise SystemExit("App icon build finished without producing AppIcon.icns")
    subprocess.run(["chmod", "+x", str(MACOS_DIR / APP_NAME)], check=True)


def install_app() -> None:
    if APPLICATIONS_APP.exists():
        shutil.rmtree(APPLICATIONS_APP)
    subprocess.run(["ditto", str(DIST_APP), str(APPLICATIONS_APP)], check=True)


def create_release_zip() -> Path:
    RELEASE_DIR.mkdir(parents=True, exist_ok=True)
    zip_path = RELEASE_DIR / f"local-voice-input-macos-v{APP_VERSION}.zip"
    if zip_path.exists():
        zip_path.unlink()
    subprocess.run(
        ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(DIST_APP), str(zip_path)],
        check=True,
    )
    return zip_path


def main() -> int:
    args = parse_args()
    backend_python = resolve_backend_python()
    build_dist(backend_python)

    if args.sign:
        sign_app(DIST_APP)

    print(f"Built app: {DIST_APP}")

    if args.install:
        install_app()
        print(f"Installed app: {APPLICATIONS_APP}")

    if args.zip:
        zip_path = create_release_zip()
        print(f"Release zip: {zip_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
