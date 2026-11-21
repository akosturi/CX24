# CX-24

A compatibility wrapper and cut visualizer that lets you use an older **Roland CX-24** vinyl cutter on newer versions of Windows.

The CX-24 has no driver for current Windows, but the Roland **GX-24** driver works if you set it up to print to a file. Its output, though, has extra PJL headers and trailers that the CX-24 can't handle. These scripts watch for that file, strip it down to plain CAMM-GL, and send it to the cutter on the parallel port.

## How it works

1. The GX-24 printer driver prints to `C:\ProgramData\CX24\input.prn`.
2. The watcher picks up the file and waits until it has been fully written.
3. It cuts everything before `IN;` and after the first `ESC`, removes control characters, and appends a safe ending (`PA;PU0,0;`).
4. The cleaned file (`cx24_clean.plt`) is sent to `LPT1:` with `copy /b`.
5. If a job fails, its file is renamed to `input_<timestamp>.error.prn` and kept.

## Files

| File | What it does |
|---|---|
| `cx24_watch.ps1` | Full version: the wrapper plus a live browser preview at `http://127.0.0.1:8765/preview.html`. The preview animates the cut path with an estimated timeline, based on measured machine timings. |
| `cx24_wrapper.bat` | Wrapper only. It converts and sends jobs, with no preview or HTTP server. Double-click it to run. |

Both scripts use the same lock file (`cx24_watch.lock`), so only one of them can run at a time. This prevents a job from being cut twice.

## Usage

- **With preview:** `powershell -ExecutionPolicy Bypass -File cx24_watch.ps1`
- **Without preview:** run `cx24_wrapper.bat`

Press `Ctrl+C` to stop. Paths, the port (`LPT1:`) and timing settings are set at the top of each script.

## License

MIT. See [LICENSE](LICENSE).
