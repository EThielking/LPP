"""Transcribe one WAV or a folder of probe*.wav files using local Whisper

Examples using the Python interpreter in existing Whisper environment:
  python transcribe_FREE.py --check
  python transcribe_FREE.py /path/to/probe_001.wav
  python transcribe_FREE.py /path/to/ERIC
  python transcribe_FREE.py /path/to/NAT_DAT --recursive

The first transcription downloads the model if it is not already cached
Speech recognition runs on local computer; --check does not load a model
Each run writes to a new folder and preserves earlier results and original WAVs
"""

import argparse
from contextlib import redirect_stdout
import csv
from datetime import datetime
import importlib
from importlib.metadata import PackageNotFoundError, version
import json
from pathlib import Path
import platform
import sys


def package_version(distribution, module):
    try:
        return version(distribution)
    except PackageNotFoundError:
        return str(getattr(module, "__version__", "unknown"))


def environment_check():
    report = dict(python_executable=sys.executable,
                  python_version=platform.python_version(),
                  platform=platform.platform(), device="cpu")
    modules = {}
    errors = []
    for name, distribution in [("faster_whisper", "faster-whisper"),
                               ("ctranslate2", "ctranslate2"), ("av", "av")]:
        try:
            modules[name] = importlib.import_module(name)
        except Exception as error:
            errors.append(f"{distribution}: {type(error).__name__}: {error}")
    if errors:
        report.update(ok=False, error=(
            "The selected Python environment cannot load its transcription dependencies. "
            f"Interpreter: {sys.executable}. " + " | ".join(errors) +
            ". Select or repair the existing faster-whisper environment; "
            "this script does not install packages."))
        return report, None
    try:
        supported = sorted(modules["ctranslate2"].get_supported_compute_types("cpu"))
        if "int8" in supported:
            compute_type = "int8"
        elif "float32" in supported:
            compute_type = "float32"
        else:
            raise RuntimeError(f"Neither int8 nor float32 is supported on this CPU: {supported}")
        model_class = modules["faster_whisper"].WhisperModel
    except Exception as error:
        report.update(ok=False, error=f"Could not verify CPU transcription support: {error}")
        return report, None
    report.update(ok=True, compute_type=compute_type, supported_cpu_compute_types=supported,
                  faster_whisper_version=package_version("faster-whisper", modules["faster_whisper"]),
                  ctranslate2_version=package_version("ctranslate2", modules["ctranslate2"]),
                  pyav_version=package_version("av", modules["av"]))
    return report, model_class


def transcribe(args, parser):
    source = args.source.expanduser().resolve()
    if source.is_file():
        files = [source]
        root = source.parent
    elif source.is_dir():
        root = source
        matches = root.rglob(args.pattern) if args.recursive else root.glob(args.pattern)
        files = sorted(p for p in matches if p.is_file())
    else:
        parser.error(f"Source does not exist: {source}")
    if not files:
        parser.error(f"No files matched {args.pattern!r} in {source}")

    run_name = "run_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    output = (args.output_dir or root / "transcripts" / run_name).expanduser().resolve()
    # MATLAB supplies a new path and lets Python create the output folder
    if output.exists():
        parser.error(f"Output folder already exists; choose a new one: {output}")

    with redirect_stdout(sys.stderr):
        report, model_class = environment_check()
    if not report["ok"]:
        raise RuntimeError(report["error"])
    compute_type = report["compute_type"]
    if compute_type == "float32":
        print("This CPU does not support int8; using its supported float32 mode.", file=sys.stderr)
    print(f"Loading {args.model} on CPU ({compute_type}); an uncached model requires a download...", flush=True)
    try:
        model = model_class(args.model, device="cpu", compute_type=compute_type, cpu_threads=4)
    except Exception as error:
        raise RuntimeError(
            f"Could not download or load model {args.model!r}: {error}. "
            "Check the model name, model cache and internet access for the first download. "
            "No transcript output folder was created; original WAVs are unchanged."
        ) from error
    options = dict(language="en", task="transcribe", beam_size=5,
                   temperature=0.0, vad_filter=True, condition_on_previous_text=False)
    # Never overwrite a prior run, including an empty folder or reviewed CSV
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError as error:
        raise RuntimeError(f"Output folder now exists; choose a new one: {output}") from error
    metadata = dict(model=args.model, device="cpu", compute_type=compute_type,
                    faster_whisper_version=report["faster_whisper_version"],
                    source=str(source), options=options, environment=report)
    with (output / "settings.json").open("x", encoding="utf-8") as handle:
        json.dump(metadata, handle, ensure_ascii=False, indent=2)

    # Keep the existing CSV columns so MATLAB and reviewed transcripts remain compatible
    columns = ["subject", "filename", "relative_path", "duration_seconds",
               "raw_transcript", "reviewed_transcript", "reviewed", "model"]
    csv_path = output / "transcripts.csv"
    with csv_path.open("x", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        handle.flush()
        for index, wav in enumerate(files, start=1):
            print(f"[{index}/{len(files)}] {wav.name}", flush=True)
            try:
                segments, info = model.transcribe(str(wav), **options)
                # Recognition runs when the returned segment generator is consumed
                segments = list(segments)
                transcript = " ".join(segment.text.strip() for segment in segments).strip()
                relative = wav.relative_to(root)
                stem = output / relative.with_suffix("")
                stem.parent.mkdir(parents=True, exist_ok=True)
                with Path(str(stem) + ".txt").open("x", encoding="utf-8") as text_file:
                    text_file.write(transcript + "\n")
                result = dict(filename=wav.name, source=str(wav), model=args.model,
                              duration_seconds=info.duration, text=transcript,
                              segments=[dict(start=segment.start, end=segment.end, text=segment.text.strip())
                                        for segment in segments])
                with Path(str(stem) + ".json").open("x", encoding="utf-8") as json_file:
                    json.dump(result, json_file, ensure_ascii=False, indent=2)
                writer.writerow(dict(subject=wav.parent.name, filename=wav.name,
                                     relative_path=str(relative), duration_seconds=info.duration,
                                     raw_transcript=transcript, reviewed_transcript="",
                                     reviewed=0, model=args.model))
                handle.flush()
            except Exception as error:
                raise RuntimeError(
                    f"Transcription failed for {wav}: {error}. "
                    f"Completed results remain in {output}; original WAVs are unchanged. "
                    "Use a new output folder to retry."
                ) from error
            print(transcript or "[No speech recognized; check the WAV.]", flush=True)
    print(f"Saved: {csv_path}", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, help="One WAV file or a folder")
    parser.add_argument("--model", default="small.en", help="Default: small.en")
    parser.add_argument("--pattern", default="probe*.wav", help="Folder file filter")
    parser.add_argument("--recursive", action="store_true", help="Include subfolders")
    parser.add_argument("--output-dir", type=Path, help="A NEW output folder")
    parser.add_argument("--check", action="store_true", help="Check dependencies and CPU support without loading a model")
    args = parser.parse_args(argv)
    if args.check:
        with redirect_stdout(sys.stderr):
            report, _ = environment_check()
        print(json.dumps(report, ensure_ascii=False), flush=True)
        return 0 if report["ok"] else 1
    if args.source is None:
        parser.error("source is required unless --check is used")
    try:
        transcribe(args, parser)
        return 0
    except KeyboardInterrupt:
        print("Transcription cancelled. Original WAVs and completed output files are retained.", file=sys.stderr)
        return 130
    except Exception as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
