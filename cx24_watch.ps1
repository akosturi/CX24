# =========================
# CX-24 watch + HTTP preview - capture/stabilize fix
# =========================

# Paths
$folder = "C:\ProgramData\CX24"
$input  = Join-Path $folder "input.prn"
$output = Join-Path $folder "cx24_clean.plt"
$lpt    = "LPT1:"

# Preview / server settings
$Cx24Dir = $folder
$Cx24Port = 8765
$PreviewUrl = "http://127.0.0.1:$Cx24Port/preview.html"
$SettingsPath = Join-Path $Cx24Dir "settings.json"

# Timing settings
$AnimationDelayMs = 200

# User fine tuning. 1.0 = measured machine timing.
# 0.95 = 5% faster animation, 1.05 = 5% slower animation.
$TimingCorrectionFactor = 1.0

# HPGL/CAMM-GL unit estimate:
# CX-24 stream resolution: 1 unit = 0.025 mm = 40 units/mm.
$UnitsPerMm = 40.0
$UnitsPerCm = 400.0

# Measured machine timing model.
$DefaultVs = 30.0
$PenDownTimeMs = 45.0
$PenUpTimeMs = 45.0
$AxisAccelerationMmSec2 = 3000.0
$AxisDecelerationMmSec2 = 5000.0
$AxisMaxSpeedMmSec = 283.0
$DiagonalSyncDelayMs = 30.0
$CurveFactor = 2.0
$CurveIntensityMultiplier = 3.0
$MicroSegmentDelayMs = 3.8

New-Item -ItemType Directory -Force -Path $folder | Out-Null

# Allow only one watcher instance. If the SYSTEM task and a manual test instance
# ran together, the same input.prn could be cut more than once.
$Cx24LockPath = Join-Path $folder "cx24_watch.lock"
try {
    $Global:Cx24LockStream = [System.IO.File]::Open(
        $Cx24LockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
}
catch {
    Write-Host "A CX-24 watcher instance is already running. Exiting to avoid duplicate cutting."
    Write-Host "Lock: $Cx24LockPath"
    exit 0
}

$JobPath = Join-Path $Cx24Dir "job.json"
$StatusPath = Join-Path $Cx24Dir "status.json"
$PreviewPath = Join-Path $Cx24Dir "preview.html"

$enc = [System.Text.Encoding]::GetEncoding(28591)

# =========================
# Preview HTML
# =========================

function Write-Cx24PreviewHtml {
    param(
        [string]$Path
    )

@'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>CX-24 Preview</title>
<style>
    html, body {
        margin: 0;
        padding: 0;
        background: #202020;
        color: #eee;
        font-family: Segoe UI, Arial, sans-serif;
        overflow: hidden;
    }

    #bar {
        height: 36px;
        line-height: 36px;
        padding: 0 12px;
        background: #111;
        border-bottom: 1px solid #444;
        font-size: 14px;
        white-space: nowrap;
    }

    #settingsBar {
        position: absolute;
        top: 37px;
        left: 0;
        right: 0;
        height: 38px;
        line-height: 38px;
        padding: 0 12px;
        background: #171717;
        border-bottom: 1px solid #444;
        box-sizing: border-box;
        font-size: 13px;
        white-space: nowrap;
    }

    #settingsBar label {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        margin-right: 10px;
    }

    #settingsBar input {
        width: 70px;
        height: 22px;
        box-sizing: border-box;
        background: #2b2b2b;
        border: 1px solid #555;
        color: #eee;
        padding: 2px 5px;
        font: inherit;
    }

    #settingsBar button {
        height: 24px;
        background: #222;
        border: 1px solid #555;
        color: #a5d6ff;
        font: inherit;
        padding: 0 10px;
        cursor: pointer;
    }

    #settingsBar button:hover {
        background: #2b2b2b;
        border-color: #777;
    }

    #settingsState {
        color: #a5d6ff;
        margin-left: 8px;
    }

    #progressWrap {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        vertical-align: middle;
    }

    #progressTrack {
        width: 140px;
        height: 8px;
        background: #2b2b2b;
        border: 1px solid #444;
        box-sizing: border-box;
        display: inline-block;
        vertical-align: middle;
    }

    #progressFill {
        display: block;
        width: 0%;
        height: 100%;
        background: #4ea1ff;
    }

    #progressPct {
        display: inline-block;
        min-width: 34px;
        color: #a5d6ff;
        text-align: right;
    }

    @media (max-width: 760px) {
        #progressTrack {
            width: 80px;
        }
    }

    @media (max-width: 620px) {
        #progressTrack {
            width: 48px;
        }
    }

    #wrap {
        position: absolute;
        top: 75px;
        left: 0;
        right: 0;
        bottom: 0;
    }

    canvas {
        display: block;
        width: 100%;
        height: 100%;
        background: #2b2b2b;
    }

    .ok { color: #7ee787; }
    .warn { color: #ffa657; }
    .done { color: #a5d6ff; }
    .err { color: #ff7b72; }
</style>
</head>
<body>
<div id="bar">
    CX-24 Preview |
    <span id="state">waiting</span> |
    segment: <span id="seg">0</span>/<span id="total">0</span> |
    progress:
    <span id="progressWrap">
        <span id="progressTrack"><span id="progressFill"></span></span>
        <span id="progressPct">0%</span>
    </span> |
    remaining: <span id="remaining">0:00</span> |
    x: <span id="x">0</span>
    y: <span id="y">0</span> |
    VS: <span id="vs">30</span>
</div>

<div id="settingsBar">
    tune:
    <label>correction <input id="setTimingCorrection" type="number" min="0.1" max="5" step="0.01"></label>
    <label>delay ms <input id="setAnimationDelay" type="number" min="0" max="600000" step="100"></label>
    <label>pen down ms <input id="setPenDown" type="number" min="0" max="2000" step="1"></label>
    <label>pen up ms <input id="setPenUp" type="number" min="0" max="2000" step="1"></label>
    <label>accel <input id="setAxisAccel" type="number" min="1" max="50000" step="1"></label>
    <label>decel <input id="setAxisDecel" type="number" min="1" max="50000" step="1"></label>
    <label>diag ms <input id="setDiagDelay" type="number" min="0" max="1000" step="1"></label>
    <label>curve <input id="setCurveFactor" type="number" min="1" max="5" step="0.05"></label>
    <label>micro ms <input id="setMicroDelay" type="number" min="0" max="20" step="0.1"></label>
    <button id="saveSettings" type="button">save</button>
    <span id="settingsState">loading</span>
</div>

<div id="wrap">
    <canvas id="c"></canvas>
</div>

<script>
const canvas = document.getElementById("c");
const ctx = canvas.getContext("2d");

let job = {
    unitsPerCm: 400,
    unitsPerMm: 40,
    defaultVs: 30,
    effectiveTimingFactor: 4.31,
    segments: []
};

let status = {
    state: "waiting",
    segment: 0,
    x: 0,
    y: 0,
    startTimeMs: 0,
    delayMs: 1000,
    totalDurationMs: 0
};

let settings = {
    timingCorrectionFactor: 1,
    animationDelayMs: 0,
    penDownTimeMs: 42,
    penUpTimeMs: 42,
    axisAccelerationMmSec2: 3000,
    axisDecelerationMmSec2: 5000,
    diagonalSyncDelayMs: 130,
    curveFactor: 2,
    microSegmentDelayMs: 3.8
};

let bounds = { minX: 0, minY: 0, maxX: 1000, maxY: 1000 };
let lastJobText = "";
let statusInFlight = false;
let jobInFlight = false;
let lastStatusOkMs = Date.now();
let timeline = [];
let totalDurationMs = 0;
let lastDrawnSegment = -1;

function resize() {
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    canvas.width = Math.max(1, Math.floor(rect.width * dpr));
    canvas.height = Math.max(1, Math.floor(rect.height * dpr));
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    draw();
}

window.addEventListener("resize", resize);

function cssWidth() { return canvas.clientWidth || 1; }
function cssHeight() { return canvas.clientHeight || 1; }

function segmentDurationMs(s) {
    if (Number.isFinite(s.durationMs)) return Math.max(0, s.durationMs);

    const dx = (s.x2 || 0) - (s.x1 || 0);
    const dy = (s.y2 || 0) - (s.y1 || 0);
    const dist = Math.sqrt(dx * dx + dy * dy);
    const unitsPerCm = job.unitsPerCm || 400;
    const speedCmSec = s.cut ? (job.cutSpeedCmSec || 30) : (job.travelSpeedCmSec || 40);
    const speedUnitsSec = speedCmSec * unitsPerCm;
    const factor = job.effectiveTimingFactor || 1;
    if (dist <= 0 || speedUnitsSec <= 0) return 0;
    return (dist / speedUnitsSec) * 1000 * factor;
}

function rebuildTimeline() {
    timeline = [];
    totalDurationMs = 0;

    if (!job.segments) return;

    for (let i = 0; i < job.segments.length; i++) {
        const s = job.segments[i];
        const d = segmentDurationMs(s);
        timeline.push({ start: totalDurationMs, end: totalDurationMs + d, duration: d });
        totalDurationMs += d;
    }
}

function calcBounds() {
    if (!job.segments || job.segments.length === 0) {
        bounds = { minX: 0, minY: 0, maxX: 1000, maxY: 1000 };
        return;
    }

    let xs = [];
    let ys = [];

    for (const s of job.segments) {
        xs.push(s.x1, s.x2);
        ys.push(s.y1, s.y2);
    }

    bounds.minX = Math.min(...xs);
    bounds.maxX = Math.max(...xs);
    bounds.minY = Math.min(...ys);
    bounds.maxY = Math.max(...ys);

    if (bounds.maxX === bounds.minX) bounds.maxX += 1;
    if (bounds.maxY === bounds.minY) bounds.maxY += 1;
}

function mapPoint(x, y) {
    const pad = 40;
    const cw = cssWidth();
    const ch = cssHeight();
    const w = Math.max(1, cw - pad * 2);
    const h = Math.max(1, ch - pad * 2);

    const bw = bounds.maxX - bounds.minX;
    const bh = bounds.maxY - bounds.minY;
    const scale = Math.min(w / bw, h / bh);
    const ox = pad + (w - bw * scale) / 2;
    const oy = pad + (h - bh * scale) / 2;

    return {
        x: ox + (x - bounds.minX) * scale,
        y: ch - (oy + (y - bounds.minY) * scale)
    };
}

function currentHead() {
    if (!job.segments || job.segments.length === 0) {
        return { x: status.x || 0, y: status.y || 0, segment: 0, state: status.state || "waiting", vs: job.defaultVs || 30 };
    }

    const st = status.state || "waiting";

    if (st === "done") {
        const last = job.segments[job.segments.length - 1];
        return { x: last.x2, y: last.y2, segment: job.segments.length, state: "done", vs: last.vs ?? job.defaultVs ?? 30 };
    }

    if (st !== "running") {
        return { x: status.x ?? job.segments[0].x1, y: status.y ?? job.segments[0].y1, segment: status.segment || 0, state: st, vs: job.defaultVs || 30 };
    }

    const startTime = status.startTimeMs || Date.now();
    const elapsed = Math.max(0, Date.now() - startTime);

    if (elapsed >= totalDurationMs) {
        const last = job.segments[job.segments.length - 1];
        return { x: last.x2, y: last.y2, segment: job.segments.length, state: "done", vs: last.vs ?? job.defaultVs ?? 30 };
    }

    // Linear search is enough for about 1500 segments at 60 FPS.
    // If jobs grow to tens of thousands of segments, switch this to binary search.
    for (let i = 0; i < timeline.length; i++) {
        const tl = timeline[i];
        if (elapsed <= tl.end) {
            const s = job.segments[i];
            const t = tl.duration <= 0 ? 1 : Math.max(0, Math.min(1, (elapsed - tl.start) / tl.duration));
            return {
                x: s.x1 + (s.x2 - s.x1) * t,
                y: s.y1 + (s.y2 - s.y1) * t,
                segment: i + 1,
                state:
                    s.motionType === "penDown" ? "pen down" :
                    s.motionType === "penUp" ? "pen up" :
                    s.cut ? "cutting" : "moving",
                vs: s.vs ?? job.defaultVs ?? 30
            };
        }
    }

    const last = job.segments[job.segments.length - 1];
    return { x: last.x2, y: last.y2, segment: job.segments.length, state: "done", vs: last.vs ?? job.defaultVs ?? 30 };
}

function progressRatio() {
    if (!job.segments || job.segments.length === 0) {
        return 0;
    }

    const st = status.state || "waiting";
    if (st === "done") {
        return 1;
    }

    if (st !== "running" || totalDurationMs <= 0) {
        return 0;
    }

    const startTime = status.startTimeMs || Date.now();
    const elapsed = Date.now() - startTime;
    return Math.max(0, Math.min(1, elapsed / totalDurationMs));
}

function remainingMs() {
    if (!job.segments || job.segments.length === 0 || totalDurationMs <= 0) {
        return 0;
    }

    const st = status.state || "waiting";
    if (st === "done") {
        return 0;
    }

    if (st !== "running") {
        return totalDurationMs;
    }

    const startTime = status.startTimeMs || Date.now();
    const elapsed = Date.now() - startTime;
    return Math.max(0, totalDurationMs - elapsed);
}

function formatDuration(ms) {
    const totalSeconds = Math.ceil(Math.max(0, ms) / 1000);
    const seconds = totalSeconds % 60;
    const totalMinutes = Math.floor(totalSeconds / 60);
    const minutes = totalMinutes % 60;
    const hours = Math.floor(totalMinutes / 60);

    if (hours > 0) {
        return hours + ":" + String(minutes).padStart(2, "0") + ":" + String(seconds).padStart(2, "0");
    }

    return minutes + ":" + String(seconds).padStart(2, "0");
}

function numberValue(id, fallback) {
    const value = Number(document.getElementById(id).value);
    return Number.isFinite(value) ? value : fallback;
}

function applySettingsToInputs() {
    document.getElementById("setTimingCorrection").value = settings.timingCorrectionFactor ?? 1;
    document.getElementById("setAnimationDelay").value = settings.animationDelayMs ?? 0;
    document.getElementById("setPenDown").value = settings.penDownTimeMs ?? 42;
    document.getElementById("setPenUp").value = settings.penUpTimeMs ?? 42;
    document.getElementById("setAxisAccel").value = settings.axisAccelerationMmSec2 ?? 3000;
    document.getElementById("setAxisDecel").value = settings.axisDecelerationMmSec2 ?? 5000;
    document.getElementById("setDiagDelay").value = settings.diagonalSyncDelayMs ?? 130;
    document.getElementById("setCurveFactor").value = settings.curveFactor ?? 2;
    document.getElementById("setMicroDelay").value = settings.microSegmentDelayMs ?? 3.8;
}

function readSettingsFromInputs() {
    return {
        timingCorrectionFactor: numberValue("setTimingCorrection", 1),
        animationDelayMs: numberValue("setAnimationDelay", 0),
        penDownTimeMs: numberValue("setPenDown", 42),
        penUpTimeMs: numberValue("setPenUp", 42),
        axisAccelerationMmSec2: numberValue("setAxisAccel", 3000),
        axisDecelerationMmSec2: numberValue("setAxisDecel", 5000),
        diagonalSyncDelayMs: numberValue("setDiagDelay", 130),
        curveFactor: numberValue("setCurveFactor", 2),
        microSegmentDelayMs: numberValue("setMicroDelay", 3.8)
    };
}

async function loadSettings() {
    try {
        const r = await fetch("/settings.json?ts=" + Date.now(), { cache: "no-store" });
        if (r.ok) {
            settings = { ...settings, ...(await r.json()) };
        }
        applySettingsToInputs();
        document.getElementById("settingsState").textContent = "loaded";
    } catch (e) {
        applySettingsToInputs();
        document.getElementById("settingsState").textContent = "defaults";
    }
}

async function saveSettings() {
    settings = readSettingsFromInputs();
    document.getElementById("settingsState").textContent = "saving";

    try {
        const r = await fetch("/settings.json", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(settings)
        });
        document.getElementById("settingsState").textContent = r.ok ? "saved for next job" : "save failed";
    } catch (e) {
        document.getElementById("settingsState").textContent = "save failed";
    }
}

function drawGrid() {
    ctx.save();
    ctx.strokeStyle = "#383838";
    ctx.lineWidth = 1;
    const step = 50;
    const cw = cssWidth();
    const ch = cssHeight();

    for (let x = 0; x < cw; x += step) {
        ctx.beginPath();
        ctx.moveTo(x, 0);
        ctx.lineTo(x, ch);
        ctx.stroke();
    }

    for (let y = 0; y < ch; y += step) {
        ctx.beginPath();
        ctx.moveTo(0, y);
        ctx.lineTo(cw, y);
        ctx.stroke();
    }

    ctx.restore();
}

function draw() {
    const cw = cssWidth();
    const ch = cssHeight();
    ctx.clearRect(0, 0, cw, ch);
    drawGrid();

    const head = currentHead();
    lastDrawnSegment = head.segment || 0;

    if (job.segments) {
        ctx.lineWidth = 1.2;

        for (let i = 0; i < job.segments.length; i++) {
            const s = job.segments[i];
            const p1 = mapPoint(s.x1, s.y1);
            const p2 = mapPoint(s.x2, s.y2);

            if (i < lastDrawnSegment - 1) {
                ctx.strokeStyle = s.cut ? "#4ea1ff" : "#777";
            } else {
                ctx.strokeStyle = s.cut ? "#aaaaaa" : "#444";
            }

            if (!s.cut) ctx.setLineDash([5, 5]); else ctx.setLineDash([]);
            ctx.beginPath();
            ctx.moveTo(p1.x, p1.y);
            ctx.lineTo(p2.x, p2.y);
            ctx.stroke();
        }
    }

    ctx.setLineDash([]);
    const hp = mapPoint(head.x || 0, head.y || 0);

    ctx.fillStyle = "#ff3030";
    ctx.beginPath();
    ctx.arc(hp.x, hp.y, 6, 0, Math.PI * 2);
    ctx.fill();

    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(hp.x, hp.y, 9, 0, Math.PI * 2);
    ctx.stroke();

    const stateEl = document.getElementById("state");
    const st = head.state || "unknown";
    stateEl.textContent = st;
    stateEl.className =
        st === "cutting" ? "ok" :
        st === "moving" ? "warn" :
        st === "done" ? "done" :
        st === "error" ? "err" :
        st === "running" ? "ok" :
        "warn";

    document.getElementById("seg").textContent = head.segment || 0;
    document.getElementById("x").textContent = Math.round(head.x || 0);
    document.getElementById("y").textContent = Math.round(head.y || 0);
    document.getElementById("vs").textContent = Math.round(head.vs || job.defaultVs || 30);

    const progress = progressRatio();
    const progressPercent = Math.round(progress * 100);
    document.getElementById("progressFill").style.width = progressPercent + "%";
    document.getElementById("progressPct").textContent = progressPercent + "%";
    document.getElementById("remaining").textContent = formatDuration(remainingMs());
}

async function loadJob() {
    if (jobInFlight) return;
    jobInFlight = true;
    try {
        const r = await fetch("/job.json?ts=" + Date.now(), { cache: "no-store" });
        if (!r.ok) return;
        const text = await r.text();

        if (text !== lastJobText) {
            lastJobText = text;
            job = JSON.parse(text);
            if (!job.segments) job.segments = [];

            calcBounds();
            rebuildTimeline();

            document.getElementById("total").textContent = job.segments.length;
            document.getElementById("vs").textContent = job.defaultVs ?? 30;
        }
    } catch (e) {
        // ignore transient read/parse errors
    } finally {
        jobInFlight = false;
    }
}

async function loadStatus() {
    if (statusInFlight) return;
    statusInFlight = true;
    try {
        const r = await fetch("/status.json?ts=" + Date.now(), { cache: "no-store" });
        if (!r.ok) return;
        status = await r.json();
        lastStatusOkMs = Date.now();
    } catch (e) {
        if ((Date.now() - lastStatusOkMs) > 5000) {
            status.state = "server disconnected";
        }
    } finally {
        statusInFlight = false;
    }
}

function animationLoop() {
    draw();
    requestAnimationFrame(animationLoop);
}

// No 10 ms polling is needed here. Head movement uses requestAnimationFrame;
// polling is only for new jobs and state changes.
setInterval(loadStatus, 500);
setInterval(loadJob, 1000);

resize();
document.getElementById("saveSettings").addEventListener("click", saveSettings);
loadSettings();
loadJob();
loadStatus();
requestAnimationFrame(animationLoop);
</script>
</body>
</html>
'@ | Set-Content -Path $Path -Encoding UTF8
}

function Write-Cx24InitialFiles {
    Write-Cx24PreviewHtml -Path $PreviewPath

    $initialJob = [ordered]@{
        unitsPerMm = $UnitsPerMm
        unitsPerCm = $UnitsPerCm
        defaultVs = $DefaultVs
        penDownTimeMs = $PenDownTimeMs
        penUpTimeMs = $PenUpTimeMs
        segments = @()
    }

    Write-Cx24JsonFile -Path $JobPath -Data $initialJob -Depth 6

    $initialStatus = [ordered]@{
        x = 0
        y = 0
        segment = 0
        state = "waiting"
    }

    Write-Cx24JsonFile -Path $StatusPath -Data $initialStatus -Compress
    Write-Cx24SettingsFile
}

# =========================
# HTTP server
# =========================

function Start-Cx24HttpServer {
    param(
        [string]$Root,
        [int]$Port
    )

    $serverScript = {
        param($Root, $Port)

        $cache = @{}

        function Read-FileBytesCached {
            param([string]$FilePath)

            $bytes = $null

            for ($try = 0; $try -lt 5; $try++) {
                try {
                    if (-not (Test-Path $FilePath)) { break }

                    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
                    $fs = [System.IO.File]::Open(
                        $FilePath,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        $share
                    )
                    try {
                        if ($fs.Length -gt 0) {
                            $bytes = New-Object byte[] $fs.Length
                            [void]$fs.Read($bytes, 0, $bytes.Length)
                            $cache[$FilePath] = $bytes
                            return $bytes
                        }
                    }
                    finally {
                        $fs.Close()
                    }
                }
                catch {
                    Start-Sleep -Milliseconds 20
                }
            }

            if ($cache.ContainsKey($FilePath)) {
                return $cache[$FilePath]
            }

            return $null
        }

        function Write-HttpResponse {
            param(
                $Stream,
                $Writer,
                [string]$Status,
                [byte[]]$Body,
                [string]$ContentType = "text/plain; charset=utf-8"
            )

            $Writer.WriteLine("HTTP/1.1 $Status")
            $Writer.WriteLine("Content-Type: $ContentType")
            $Writer.WriteLine("Cache-Control: no-store, no-cache, must-revalidate")
            $Writer.WriteLine("Access-Control-Allow-Origin: *")
            $Writer.WriteLine("Content-Length: $($Body.Length)")
            $Writer.WriteLine("Connection: close")
            $Writer.WriteLine("")
            $Stream.Write($Body, 0, $Body.Length)
        }

        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
            $listener.Start()
        }
        catch {
            return
        }

        while ($true) {
            $client = $listener.AcceptTcpClient()

            try {
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $writer = New-Object System.IO.StreamWriter($stream)
                $writer.NewLine = "`r`n"
                $writer.AutoFlush = $true

                $requestLine = $reader.ReadLine()
                $contentLength = 0

                while ($true) {
                    $line = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($line)) { break }
                    if ($line -match '^Content-Length:\s*(\d+)') {
                        $contentLength = [int]$matches[1]
                    }
                }

                if (-not $requestLine) {
                    $client.Close()
                    continue
                }

                $parts = $requestLine.Split(" ")
                if ($parts.Count -lt 2) {
                    $client.Close()
                    continue
                }

                $method = $parts[0].ToUpperInvariant()
                $urlPath = $parts[1].Split("?")[0]

                if ($urlPath -eq "/") {
                    $urlPath = "/preview.html"
                }

                $safeName = [System.IO.Path]::GetFileName($urlPath)
                $filePath = Join-Path $Root $safeName

                if ($method -eq "POST" -and $safeName -eq "settings.json") {
                    $chars = New-Object char[] $contentLength
                    $read = 0
                    while ($read -lt $contentLength) {
                        $n = $reader.Read($chars, $read, $contentLength - $read)
                        if ($n -le 0) { break }
                        $read += $n
                    }

                    $text = if ($read -gt 0) { -join $chars[0..($read - 1)] } else { "" }

                    try {
                        [void]($text | ConvertFrom-Json -ErrorAction Stop)
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                        [System.IO.File]::WriteAllBytes($filePath, $bytes)
                        $cache[$filePath] = $bytes
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                        Write-HttpResponse -Stream $stream -Writer $writer -Status "200 OK" -Body $body -ContentType "application/json; charset=utf-8"
                    }
                    catch {
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false}')
                        Write-HttpResponse -Stream $stream -Writer $writer -Status "400 Bad Request" -Body $body -ContentType "application/json; charset=utf-8"
                    }

                    $client.Close()
                    continue
                }

                if (-not (Test-Path $filePath)) {
                    $body = [System.Text.Encoding]::UTF8.GetBytes("404")
                    Write-HttpResponse -Stream $stream -Writer $writer -Status "404 Not Found" -Body $body
                    $client.Close()
                    continue
                }

                $ext = [System.IO.Path]::GetExtension($filePath).ToLowerInvariant()

                switch ($ext) {
                    ".html" { $type = "text/html; charset=utf-8" }
                    ".json" { $type = "application/json; charset=utf-8" }
                    ".js"   { $type = "application/javascript; charset=utf-8" }
                    ".css"  { $type = "text/css; charset=utf-8" }
                    default { $type = "application/octet-stream" }
                }

                $bytes = Read-FileBytesCached -FilePath $filePath

                if ($null -eq $bytes) {
                    $body = [System.Text.Encoding]::UTF8.GetBytes("503")
                    Write-HttpResponse -Stream $stream -Writer $writer -Status "503 Service Unavailable" -Body $body
                    $client.Close()
                    continue
                }

                Write-HttpResponse -Stream $stream -Writer $writer -Status "200 OK" -Body $bytes -ContentType $type
            }
            catch {
                # keep server alive
            }
            finally {
                if ($client) { $client.Close() }
            }
        }
    }

    $existing = Get-Job -Name "CX24PreviewServer" -ErrorAction SilentlyContinue
    if ($existing) {
        # Restart the job so an older server script does not stay loaded.
        # If the port is still busy, the new Start-Job would fail quietly.
        try { Stop-Job -Name "CX24PreviewServer" -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Remove-Job -Name "CX24PreviewServer" -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        Start-Sleep -Milliseconds 250
    }

    Start-Job -Name "CX24PreviewServer" -ScriptBlock $serverScript -ArgumentList $Root, $Port | Out-Null
}

function Open-Cx24Preview {
    param(
        [string]$Url
    )

    Start-Process $Url
}

function Write-Cx24TextFileSafe {
    param(
        [string]$Path,
        [string]$Text,
        [int]$Retries = 100,
        [int]$DelayMs = 15
    )

    $dir = Split-Path -Parent $Path
    if ($dir) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    # Important:
    # This used to write a temp file and then Move-Item/File.Replace it. On Windows
    # that often failed for status.json while the browser/HTTP server was reading.
    # Rewrite the same file with FileMode.Create and allow other processes to read
    # it at the same time. This avoids rename races.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete

    for ($i = 0; $i -lt $Retries; $i++) {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                $share
            )

            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            return $true
        }
        catch {
            if ($i -eq ($Retries - 1)) {
                Write-Host "Warning: failed to write: $Path ($($_.Exception.Message))"
            }
            Start-Sleep -Milliseconds $DelayMs
        }
        finally {
            if ($fs) {
                try { $fs.Close() } catch {}
            }
        }
    }

    return $false
}

function Write-Cx24JsonFile {
    param(
        [string]$Path,
        [object]$Data,
        [int]$Depth = 6,
        [switch]$Compress
    )

    if ($Compress) {
        $json = $Data | ConvertTo-Json -Depth $Depth -Compress
    }
    else {
        $json = $Data | ConvertTo-Json -Depth $Depth
    }

    [void](Write-Cx24TextFileSafe -Path $Path -Text $json)
}

function Get-Cx24SettingsObject {
    return [ordered]@{
        timingCorrectionFactor = $TimingCorrectionFactor
        animationDelayMs = $AnimationDelayMs
        penDownTimeMs = $PenDownTimeMs
        penUpTimeMs = $PenUpTimeMs
        axisAccelerationMmSec2 = $AxisAccelerationMmSec2
        axisDecelerationMmSec2 = $AxisDecelerationMmSec2
        diagonalSyncDelayMs = $DiagonalSyncDelayMs
        curveFactor = $CurveFactor
        microSegmentDelayMs = $MicroSegmentDelayMs
    }
}

function Write-Cx24SettingsFile {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        Write-Cx24JsonFile -Path $SettingsPath -Data (Get-Cx24SettingsObject) -Depth 4 -Compress
    }
}

function Get-Cx24NumericSetting {
    param(
        [object]$Settings,
        [string]$Name,
        [double]$Current,
        [double]$Min,
        [double]$Max
    )

    if ($null -eq $Settings.$Name) {
        return $Current
    }

    try {
        $value = [double]$Settings.$Name
        if ($value -lt $Min) { return $Min }
        if ($value -gt $Max) { return $Max }
        return $value
    }
    catch {
        return $Current
    }
}

function Update-Cx24SettingsFromFile {
    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        Write-Cx24SettingsFile
        return
    }

    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json

        $script:TimingCorrectionFactor = Get-Cx24NumericSetting -Settings $settings -Name "timingCorrectionFactor" -Current $TimingCorrectionFactor -Min 0.1 -Max 5.0
        $script:AnimationDelayMs = Get-Cx24NumericSetting -Settings $settings -Name "animationDelayMs" -Current $AnimationDelayMs -Min 0 -Max 600000
        $script:PenDownTimeMs = Get-Cx24NumericSetting -Settings $settings -Name "penDownTimeMs" -Current $PenDownTimeMs -Min 0 -Max 2000
        $script:PenUpTimeMs = Get-Cx24NumericSetting -Settings $settings -Name "penUpTimeMs" -Current $PenUpTimeMs -Min 0 -Max 2000
        $script:AxisAccelerationMmSec2 = Get-Cx24NumericSetting -Settings $settings -Name "axisAccelerationMmSec2" -Current $AxisAccelerationMmSec2 -Min 1 -Max 50000
        $script:AxisDecelerationMmSec2 = Get-Cx24NumericSetting -Settings $settings -Name "axisDecelerationMmSec2" -Current $AxisDecelerationMmSec2 -Min 1 -Max 50000
        $script:DiagonalSyncDelayMs = Get-Cx24NumericSetting -Settings $settings -Name "diagonalSyncDelayMs" -Current $DiagonalSyncDelayMs -Min 0 -Max 1000
        $script:CurveFactor = Get-Cx24NumericSetting -Settings $settings -Name "curveFactor" -Current $CurveFactor -Min 1.0 -Max 5.0
        $script:MicroSegmentDelayMs = Get-Cx24NumericSetting -Settings $settings -Name "microSegmentDelayMs" -Current $MicroSegmentDelayMs -Min 0 -Max 20.0
    }
    catch {
        Write-Host "Warning: failed to load settings: $($_.Exception.Message)"
    }
}

function Set-Cx24Status {
    param(
        [double]$X,
        [double]$Y,
        [int]$Segment,
        [string]$State = "cutting"
    )

    $obj = [ordered]@{
        x = [math]::Round($X, 3)
        y = [math]::Round($Y, 3)
        segment = $Segment
        state = $State
    }

    Write-Cx24JsonFile -Path $StatusPath -Data $obj -Compress
}

function Set-Cx24Job {
    param(
        [array]$Segments
    )

    $obj = [ordered]@{
        unitsPerMm = $UnitsPerMm
        unitsPerCm = $UnitsPerCm
        defaultVs = $DefaultVs
        penDownTimeMs = $PenDownTimeMs
        penUpTimeMs = $PenUpTimeMs
        axisAccelerationMmSec2 = $AxisAccelerationMmSec2
        axisDecelerationMmSec2 = $AxisDecelerationMmSec2
        axisMaxSpeedMmSec = $AxisMaxSpeedMmSec
        curveFactor = $CurveFactor
        microSegmentDelayMs = $MicroSegmentDelayMs
        timingCorrectionFactor = $TimingCorrectionFactor
        segments = $Segments
    }

    Write-Cx24JsonFile -Path $JobPath -Data $obj -Depth 8 -Compress
}

# =========================
# File wait + GX/CX cleanup
# =========================

function Wait-AndCaptureInput {
    param(
        [string]$SourcePath,
        [string]$Folder
    )

    # Capture input.prn first by moving it to a unique .processing.prn name, then
    # wait for a stable size on that file. This keeps the watcher from picking up
    # the same job again while the spooler is still touching the original name.

    $deadline = (Get-Date).AddSeconds(20)
    $processing = $null

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            Start-Sleep -Milliseconds 100
            continue
        }

        $processing = Join-Path $Folder ("input_" + (Get-Date -Format "yyyyMMdd_HHmmss_fff") + "_" + ([guid]::NewGuid().ToString("N").Substring(0, 6)) + ".processing.prn")

        try {
            Move-Item -LiteralPath $SourcePath -Destination $processing -Force -ErrorAction Stop
            break
        }
        catch {
            # The driver/spooler is probably still writing. Wait and retry.
            $processing = $null
            Start-Sleep -Milliseconds 150
        }
    }

    if (-not $processing -or -not (Test-Path -LiteralPath $processing)) {
        return $null
    }

    # It is no longer named input.prn, so the watcher will not start it again.
    # Wait until the file size is stable.
    $lastLen = -1
    $stableCount = 0
    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $processing)) {
            return $null
        }

        try {
            $len = (Get-Item -LiteralPath $processing -ErrorAction Stop).Length

            if ($len -gt 0 -and $len -eq $lastLen) {
                $stableCount++
            }
            else {
                $stableCount = 0
            }

            $lastLen = $len

            # Two consecutive matching sizes are enough, about 300 ms of stability.
            if ($stableCount -ge 2) {
                return $processing
            }
        }
        catch {
            # If the file is busy, just wait and try again.
        }

        Start-Sleep -Milliseconds 150
    }

    return $processing
}

function Convert-GX24-To-CX24($inFile, $outFile) {
    $bytes = [System.IO.File]::ReadAllBytes($inFile)
    $s = $enc.GetString($bytes)

    # Start of the CAMM-GL section.
    $start = $s.IndexOf("IN;")
    if ($start -lt 0) {
        throw "Could not find an IN; command in the file."
    }

    $s = $s.Substring($start)

    # PJL trailer starts after the first ESC; trim it off.
    $esc = $s.IndexOf([char]27)
    if ($esc -ge 0) {
        $s = $s.Substring(0, $esc)
    }

    # Remove optional control characters.
    $s = $s.Replace([string][char]3, "")

    # Safe trailer: absolute mode + tool up + return to 0,0.
    $s = $s.Trim() + "`r`nPA;PU0,0;`r`n"

    [System.IO.File]::WriteAllBytes($outFile, $enc.GetBytes($s))
}

# =========================
# HPGL -> preview segments
# =========================

function Get-NumberList {
    param([string]$Text)

    $nums = New-Object System.Collections.Generic.List[double]

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $nums
    }

    $matches = [regex]::Matches($Text, '[-+]?\d+(\.\d+)?')
    foreach ($m in $matches) {
        $nums.Add([double]$m.Value)
    }

    return $nums
}

function Get-Cx24AxisCruiseSpeedMmSec {
    param(
        [double]$Vs
    )

    if ($Vs -le 2) { return 25.0 }
    if ($Vs -le 6) { return [math]::Max(25.0, $Vs * 10.0) }
    if ($Vs -le 20) { return 60.0 + (($Vs - 6.0) * (120.0 / 14.0)) }
    if ($Vs -le 30) { return 180.0 + (($Vs - 20.0) * 6.6) }
    if ($Vs -le 40) { return 246.0 + (($Vs - 30.0) * 2.9) }

    return $AxisMaxSpeedMmSec
}

function Get-Cx24PathCruiseSpeedMmSec {
    param(
        [double]$DxMm,
        [double]$DyMm,
        [double]$AxisXSpeedMmSec,
        [double]$AxisYSpeedMmSec
    )

    $distanceMm = [math]::Sqrt(($DxMm * $DxMm) + ($DyMm * $DyMm))
    if ($distanceMm -le 0) { return 0.0 }

    $cos = [math]::Abs($DxMm / $distanceMm)
    $sin = [math]::Abs($DyMm / $distanceMm)
    $limits = New-Object System.Collections.Generic.List[double]

    if ($cos -gt 0.000001) { $limits.Add($AxisXSpeedMmSec / $cos) }
    if ($sin -gt 0.000001) { $limits.Add($AxisYSpeedMmSec / $sin) }

    if ($limits.Count -eq 0) { return 0.0 }
    return ($limits | Measure-Object -Minimum).Minimum
}

function Get-Cx24MotionProfileDurationMs {
    param(
        [double]$DistanceMm,
        [double]$CruiseSpeedMmSec,
        [double]$AccelerationMmSec2,
        [double]$DecelerationMmSec2
    )

    if ($DistanceMm -le 0 -or $CruiseSpeedMmSec -le 0 -or $AccelerationMmSec2 -le 0 -or $DecelerationMmSec2 -le 0) {
        return 0.0
    }

    $accelDistanceMm = ($CruiseSpeedMmSec * $CruiseSpeedMmSec) / (2.0 * $AccelerationMmSec2)
    $decelDistanceMm = ($CruiseSpeedMmSec * $CruiseSpeedMmSec) / (2.0 * $DecelerationMmSec2)
    $fullRampDistanceMm = $accelDistanceMm + $decelDistanceMm

    if ($DistanceMm -lt $fullRampDistanceMm) {
        $peakSpeed = [math]::Sqrt((2.0 * $DistanceMm * $AccelerationMmSec2 * $DecelerationMmSec2) / ($AccelerationMmSec2 + $DecelerationMmSec2))
        return (($peakSpeed / $AccelerationMmSec2) + ($peakSpeed / $DecelerationMmSec2)) * 1000.0
    }

    $cruiseDistanceMm = $DistanceMm - $fullRampDistanceMm
    return (($CruiseSpeedMmSec / $AccelerationMmSec2) + ($cruiseDistanceMm / $CruiseSpeedMmSec) + ($CruiseSpeedMmSec / $DecelerationMmSec2)) * 1000.0
}

function Get-Cx24DiagonalSyncDelayMs {
    param(
        [double]$DxMm,
        [double]$DyMm,
        [double]$DistanceMm
    )

    $ax = [math]::Abs($DxMm)
    $ay = [math]::Abs($DyMm)
    $dominant = [math]::Max($ax, $ay)
    $minor = [math]::Min($ax, $ay)

    if ($dominant -le 0 -or $minor -le 0) {
        return 0.0
    }

    $balance = $minor / $dominant
    $distanceScale = [math]::Min(1.0, $DistanceMm / 200.0)
    return $DiagonalSyncDelayMs * [math]::Pow($balance, 8.0) * $distanceScale
}

function Get-Cx24MoveDurationMs {
    param(
        [double]$DxUnits,
        [double]$DyUnits,
        [double]$Vs
    )

    $dxMm = $DxUnits / $UnitsPerMm
    $dyMm = $DyUnits / $UnitsPerMm
    $distanceMm = [math]::Sqrt(($dxMm * $dxMm) + ($dyMm * $dyMm))

    if ($distanceMm -le 0) {
        return 0.0
    }

    $axisSpeed = [math]::Min((Get-Cx24AxisCruiseSpeedMmSec -Vs $Vs), $AxisMaxSpeedMmSec)
    $pathSpeed = Get-Cx24PathCruiseSpeedMmSec -DxMm $dxMm -DyMm $dyMm -AxisXSpeedMmSec $axisSpeed -AxisYSpeedMmSec $axisSpeed
    $durationMs = Get-Cx24MotionProfileDurationMs -DistanceMm $distanceMm -CruiseSpeedMmSec $pathSpeed -AccelerationMmSec2 $AxisAccelerationMmSec2 -DecelerationMmSec2 $AxisDecelerationMmSec2
    $durationMs += Get-Cx24DiagonalSyncDelayMs -DxMm $dxMm -DyMm $dyMm -DistanceMm $distanceMm

    return $durationMs * $TimingCorrectionFactor
}

function Get-Cx24CruiseMoveDurationMs {
    param(
        [double]$DxUnits,
        [double]$DyUnits,
        [double]$Vs
    )

    $dxMm = $DxUnits / $UnitsPerMm
    $dyMm = $DyUnits / $UnitsPerMm
    $distanceMm = [math]::Sqrt(($dxMm * $dxMm) + ($dyMm * $dyMm))

    if ($distanceMm -le 0) {
        return 0.0
    }

    $axisSpeed = [math]::Min((Get-Cx24AxisCruiseSpeedMmSec -Vs $Vs), $AxisMaxSpeedMmSec)
    $pathSpeed = Get-Cx24PathCruiseSpeedMmSec -DxMm $dxMm -DyMm $dyMm -AxisXSpeedMmSec $axisSpeed -AxisYSpeedMmSec $axisSpeed

    if ($pathSpeed -le 0) {
        return 0.0
    }

    return ($distanceMm / $pathSpeed) * 1000.0 * $TimingCorrectionFactor
}

function Get-Cx24LineDistanceMm {
    param([object]$Segment)

    $dxMm = ([double]$Segment.x2 - [double]$Segment.x1) / $UnitsPerMm
    $dyMm = ([double]$Segment.y2 - [double]$Segment.y1) / $UnitsPerMm
    return [math]::Sqrt(($dxMm * $dxMm) + ($dyMm * $dyMm))
}

function Get-Cx24CurveIntensity {
    param(
        [array]$Segments,
        [int]$StartIndex,
        [int]$EndIndex,
        [double]$TotalDistanceMm
    )

    if ($EndIndex -le $StartIndex -or $TotalDistanceMm -le 0) {
        return 0.0
    }

    $weightedTurn = 0.0
    $shortSegmentReferenceMm = 20.0
    $fullCurveTurnDensity = 0.02

    for ($i = $StartIndex + 1; $i -le $EndIndex; $i++) {
        $a = $Segments[$i - 1]
        $b = $Segments[$i]

        $ax = ([double]$a.x2 - [double]$a.x1) / $UnitsPerMm
        $ay = ([double]$a.y2 - [double]$a.y1) / $UnitsPerMm
        $bx = ([double]$b.x2 - [double]$b.x1) / $UnitsPerMm
        $by = ([double]$b.y2 - [double]$b.y1) / $UnitsPerMm

        $alen = [math]::Sqrt(($ax * $ax) + ($ay * $ay))
        $blen = [math]::Sqrt(($bx * $bx) + ($by * $by))

        if ($alen -le 0.000001 -or $blen -le 0.000001) {
            continue
        }

        $dot = (($ax * $bx) + ($ay * $by)) / ($alen * $blen)
        if ($dot -gt 1.0) { $dot = 1.0 }
        if ($dot -lt -1.0) { $dot = -1.0 }

        $angle = [math]::Acos($dot)
        $shortLen = [math]::Min($alen, $blen)
        $shortWeight = 1.0 / (1.0 + [math]::Pow($shortLen / $shortSegmentReferenceMm, 2.0))
        $weightedTurn += $angle * $shortWeight
    }

    $turnDensity = $weightedTurn / $TotalDistanceMm
    return [math]::Max(0.0, [math]::Min(1.0, $turnDensity / $fullCurveTurnDensity))
}

function Update-Cx24LineGroupDurations {
    param(
        [array]$Segments,
        [int]$StartIndex,
        [int]$EndIndex
    )

    if ($EndIndex -lt $StartIndex) {
        return
    }

    if ($StartIndex -eq $EndIndex) {
        $s = $Segments[$StartIndex]
        $s.durationMs = [math]::Round((Get-Cx24MoveDurationMs -DxUnits ([double]$s.x2 - [double]$s.x1) -DyUnits ([double]$s.y2 - [double]$s.y1) -Vs ([double]$s.vs)), 3)
        return
    }

    $sumCruiseMs = 0.0
    $sumDistanceMm = 0.0
    $weightedAxisSpeed = 0.0
    $first = $Segments[$StartIndex]
    $last = $Segments[$EndIndex]
    $netDxMm = ([double]$last.x2 - [double]$first.x1) / $UnitsPerMm
    $netDyMm = ([double]$last.y2 - [double]$first.y1) / $UnitsPerMm
    $netDistanceMm = [math]::Sqrt(($netDxMm * $netDxMm) + ($netDyMm * $netDyMm))

    for ($i = $StartIndex; $i -le $EndIndex; $i++) {
        $s = $Segments[$i]
        $distanceMm = Get-Cx24LineDistanceMm -Segment $s
        $cruiseMs = Get-Cx24CruiseMoveDurationMs -DxUnits ([double]$s.x2 - [double]$s.x1) -DyUnits ([double]$s.y2 - [double]$s.y1) -Vs ([double]$s.vs)

        $s.durationMs = $cruiseMs
        $sumCruiseMs += $cruiseMs
        $sumDistanceMm += $distanceMm
        $weightedAxisSpeed += (Get-Cx24AxisCruiseSpeedMmSec -Vs ([double]$s.vs)) * $distanceMm
    }

    if ($sumCruiseMs -le 0 -or $sumDistanceMm -le 0) {
        return
    }

    $avgAxisSpeed = [math]::Min(($weightedAxisSpeed / $sumDistanceMm), $AxisMaxSpeedMmSec)
    $accelOverheadMs = (($avgAxisSpeed / $AxisAccelerationMmSec2) + ($avgAxisSpeed / $AxisDecelerationMmSec2)) * 1000.0 * $TimingCorrectionFactor
    $straightness = if ($sumDistanceMm -gt 0) { [math]::Min(1.0, $netDistanceMm / $sumDistanceMm) } else { 0.0 }
    $segmentCount = ($EndIndex - $StartIndex + 1)
    $avgSegmentMm = if ($segmentCount -gt 0) { $sumDistanceMm / $segmentCount } else { $sumDistanceMm }
    $detailScale = 1.0 / (1.0 + [math]::Pow($avgSegmentMm / 1.4, 4.0))
    $curveIntensity = Get-Cx24CurveIntensity -Segments $Segments -StartIndex $StartIndex -EndIndex $EndIndex -TotalDistanceMm $sumDistanceMm
    $curveScale = 1.0 + (([math]::Max(1.0, $CurveFactor) - 1.0) * $CurveIntensityMultiplier * $curveIntensity * $detailScale)
    $diagonalOverheadMs = (Get-Cx24DiagonalSyncDelayMs -DxMm $netDxMm -DyMm $netDyMm -DistanceMm $netDistanceMm) * [math]::Pow($straightness, 4.0) * $TimingCorrectionFactor
    $overheadMs = $accelOverheadMs + $diagonalOverheadMs

    for ($i = $StartIndex; $i -le $EndIndex; $i++) {
        $s = $Segments[$i]
        $share = [double]$s.durationMs / $sumCruiseMs
        $segmentMm = Get-Cx24LineDistanceMm -Segment $s
        $microDelayMs = 0.0
        if ($s.cut) {
            $microWeight = 1.0 / (1.0 + [math]::Pow($segmentMm / 2.0, 4.0))
            $microDelayMs = $MicroSegmentDelayMs * $microWeight * $TimingCorrectionFactor
        }
        $s.durationMs = [math]::Round((([double]$s.durationMs * $curveScale) + ($overheadMs * $share) + $microDelayMs), 3)
    }
}

function Update-Cx24ContinuousDurations {
    param([array]$Segments)

    $groupStart = -1

    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $s = $Segments[$i]
        $isLine = $s.motionType -eq "line"

        if ($isLine) {
            if ($groupStart -lt 0) {
                $groupStart = $i
            }
            continue
        }

        if ($groupStart -ge 0) {
            Update-Cx24LineGroupDurations -Segments $Segments -StartIndex $groupStart -EndIndex ($i - 1)
            $groupStart = -1
        }
    }

    if ($groupStart -ge 0) {
        Update-Cx24LineGroupDurations -Segments $Segments -StartIndex $groupStart -EndIndex ($Segments.Count - 1)
    }
}

function Add-Cx24PenEventSegment {
    param(
        [System.Collections.Generic.List[object]]$Segments,
        [double]$X,
        [double]$Y,
        [string]$MotionType,
        [bool]$Cut,
        [double]$DurationMs,
        [double]$Vs
    )

    if ($DurationMs -le 0) {
        return
    }

    [void]$Segments.Add([ordered]@{
        x1 = $X
        y1 = $Y
        x2 = $X
        y2 = $Y
        cut = $Cut
        vs = $Vs
        motionType = $MotionType
        durationMs = [math]::Round($DurationMs, 3)
    })
}

function Add-Cx24MoveSegments {
    param(
        [System.Collections.Generic.List[object]]$Segments,
        [System.Collections.Generic.List[double]]$Numbers,
        [ref]$X,
        [ref]$Y,
        [bool]$Absolute,
        [bool]$Cut,
        [double]$Vs
    )

    if ($Numbers.Count -lt 2) {
        return
    }

    for ($i = 0; $i -lt ($Numbers.Count - 1); $i += 2) {
        $a = [double]$Numbers[$i]
        $b = [double]$Numbers[$i + 1]

        if ($Absolute) {
            $nx = $a
            $ny = $b
        }
        else {
            $nx = [double]$X.Value + $a
            $ny = [double]$Y.Value + $b
        }

        if (([math]::Abs($nx - [double]$X.Value) -gt 0.0001) -or ([math]::Abs($ny - [double]$Y.Value) -gt 0.0001)) {
            [void]$Segments.Add([ordered]@{
                x1 = [double]$X.Value
                y1 = [double]$Y.Value
                x2 = $nx
                y2 = $ny
                cut = $Cut
                vs = $Vs
                motionType = "line"
                durationMs = 0.0
            })
        }

        $X.Value = $nx
        $Y.Value = $ny
    }
}

function Convert-HpglToSegments {
    param(
        [string]$HpglText
    )

    $segments = New-Object System.Collections.Generic.List[object]

    $x = 0.0
    $y = 0.0
    $absolute = $true
    $penDown = $false
    $vs = $DefaultVs

    $tokens = $HpglText -split ';'

    foreach ($rawToken in $tokens) {
        $token = $rawToken.Trim()

        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        $m = [regex]::Match($token, '^([A-Za-z!]{2,})(.*)$')

        if (-not $m.Success) {
            continue
        }

        $cmd = $m.Groups[1].Value.ToUpperInvariant()
        $arg = $m.Groups[2].Value.Trim()

        switch ($cmd) {
            "IN" {
                $x = 0.0
                $y = 0.0
                $absolute = $true
                $penDown = $false
                $vs = $DefaultVs
            }

            "VS" {
                $nums = Get-NumberList -Text $arg
                if ($nums.Count -ge 1) {
                    $vs = [double]$nums[0]
                }
            }

            "PA" {
                $absolute = $true
                $nums = Get-NumberList -Text $arg
                Add-Cx24MoveSegments -Segments $segments -Numbers $nums -X ([ref]$x) -Y ([ref]$y) -Absolute $true -Cut $penDown -Vs $vs
            }

            "PR" {
                $absolute = $false
                $nums = Get-NumberList -Text $arg
                Add-Cx24MoveSegments -Segments $segments -Numbers $nums -X ([ref]$x) -Y ([ref]$y) -Absolute $false -Cut $penDown -Vs $vs
            }

            "PU" {
                if ($penDown) {
                    Add-Cx24PenEventSegment -Segments $segments -X $x -Y $y -MotionType "penUp" -Cut $false -DurationMs $PenUpTimeMs -Vs $vs
                }
                $penDown = $false
                $nums = Get-NumberList -Text $arg
                Add-Cx24MoveSegments -Segments $segments -Numbers $nums -X ([ref]$x) -Y ([ref]$y) -Absolute $absolute -Cut $false -Vs $vs
            }

            "PD" {
                if (-not $penDown) {
                    Add-Cx24PenEventSegment -Segments $segments -X $x -Y $y -MotionType "penDown" -Cut $true -DurationMs $PenDownTimeMs -Vs $vs
                }
                $penDown = $true
                $nums = Get-NumberList -Text $arg
                Add-Cx24MoveSegments -Segments $segments -Numbers $nums -X ([ref]$x) -Y ([ref]$y) -Absolute $absolute -Cut $true -Vs $vs
            }
        }
    }

    $result = $segments.ToArray()
    Update-Cx24ContinuousDurations -Segments $result
    return $result
}

function Get-SegmentDurationMs {
    param(
        [object]$Segment
    )

    if ($null -ne $Segment.durationMs) {
        return [math]::Max(0.0, [double]$Segment.durationMs)
    }

    $dx = [double]$Segment.x2 - [double]$Segment.x1
    $dy = [double]$Segment.y2 - [double]$Segment.y1
    $vs = if ($null -ne $Segment.vs) { [double]$Segment.vs } else { $DefaultVs }

    return Get-Cx24MoveDurationMs -DxUnits $dx -DyUnits $dy -Vs $vs
}

function Start-Cx24Animation {
    param(
        [array]$Segments
    )

    if (-not $Segments -or $Segments.Count -eq 0) {
        Set-Cx24Status -X 0 -Y 0 -Segment 0 -State "done"
        return
    }

    $durations = New-Object System.Collections.Generic.List[double]
    $totalMs = 0.0

    foreach ($s in $Segments) {
        $d = [double](Get-SegmentDurationMs -Segment $s)
        $durations.Add($d)
        $totalMs += $d
    }

    Write-Host ("Estimated animation time: {0:n2} s + startup delay: {1:n2} s" -f ($totalMs / 1000.0), ($AnimationDelayMs / 1000.0))

    # PowerShell no longer writes the head position every 10-150 ms.
    # It only writes the start time; the browser interpolates the head with
    # requestAnimationFrame. This keeps motion smooth and avoids status.json IO noise.
    $startTimeMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() + [int64]$AnimationDelayMs

    $obj = [ordered]@{
        x = [math]::Round([double]$Segments[0].x1, 3)
        y = [math]::Round([double]$Segments[0].y1, 3)
        segment = 0
        state = "running"
        startTimeMs = $startTimeMs
        delayMs = $AnimationDelayMs
        totalDurationMs = [math]::Round($totalMs, 3)
    }

    Write-Cx24JsonFile -Path $StatusPath -Data $obj -Compress

    # PowerShell only writes the final state so the status is clean before the next job.
    $waitMs = [int][math]::Ceiling($AnimationDelayMs + $totalMs)
    if ($waitMs -gt 0) {
        Start-Sleep -Milliseconds $waitMs
    }

    $last = $Segments[-1]
    Set-Cx24Status -X $last.x2 -Y $last.y2 -Segment $Segments.Count -State "done"
}

function Move-Cx24FailedJob {
    param(
        [string]$ProcessingPath,
        [string]$InputPath,
        [string]$Folder
    )

    $errName = Join-Path $Folder ("input_" + (Get-Date -Format "yyyyMMdd_HHmmss_fff") + ".error.prn")
    $errFileName = [System.IO.Path]::GetFileName($errName)

    if ($ProcessingPath -and (Test-Path -LiteralPath $ProcessingPath)) {
        Rename-Item -LiteralPath $ProcessingPath -NewName $errFileName -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path -LiteralPath $InputPath) {
        Rename-Item -LiteralPath $InputPath -NewName $errFileName -Force -ErrorAction SilentlyContinue
    }

    return $errName
}

function Invoke-Cx24Job {
    param(
        [string]$InputPath,
        [string]$Folder,
        [string]$OutputPath,
        [string]$LptPort
    )

    $processing = $null

    try {
        Write-Host "New job received..."

        $processing = Wait-AndCaptureInput -SourcePath $InputPath -Folder $Folder
        if (-not $processing) {
            Write-Host "Input was not stable or disappeared; skipping."
            Start-Sleep -Milliseconds 300
            return
        }

        Update-Cx24SettingsFromFile
        Convert-GX24-To-CX24 $processing $OutputPath

        $hpglText = $enc.GetString([System.IO.File]::ReadAllBytes($OutputPath))
        $segments = Convert-HpglToSegments -HpglText $hpglText

        if ($null -eq $segments) {
            $segments = @()
        }

        Write-Host "Preview update: $($segments.Count) segments"
        Set-Cx24Job -Segments $segments

        Write-Host "Sending to $LptPort..."

        $copyArgs = "/c copy /b `"$OutputPath`" `"$LptPort`""
        $copyProcess = Start-Process -FilePath "cmd.exe" -ArgumentList $copyArgs -WindowStyle Hidden -PassThru

        Start-Cx24Animation -Segments $segments

        if ($copyProcess -and -not $copyProcess.HasExited) {
            $copyProcess.WaitForExit()
        }

        if ($processing -and (Test-Path -LiteralPath $processing)) {
            Remove-Item -LiteralPath $processing -Force
        }

        Write-Host "Done."
        Write-Host ""
    }
    catch {
        try { Set-Cx24Status -X 0 -Y 0 -Segment 0 -State "error" } catch {}

        Write-Host "Error: $($_.Exception.Message)"
        Write-Host "Line: $($_.InvocationInfo.ScriptLineNumber)"
        Write-Host "Command: $($_.InvocationInfo.Line)"

        $errName = Move-Cx24FailedJob -ProcessingPath $processing -InputPath $InputPath -Folder $Folder
        Write-Host "Failed job moved aside: $errName"
        Write-Host ""
    }
}

# =========================
# Start preview
# =========================

Write-Cx24InitialFiles
Update-Cx24SettingsFromFile
Start-Cx24HttpServer -Root $Cx24Dir -Port $Cx24Port
Start-Sleep -Milliseconds 250
Open-Cx24Preview -Url $PreviewUrl

Write-Host "CX-24 filter is running. Watched file: $input"
Write-Host "Output: $lpt"
Write-Host "Preview: $PreviewUrl"
Write-Host "Timing model: units/mm=$UnitsPerMm, default VS=$DefaultVs, accel=$AxisAccelerationMmSec2 mm/s^2, decel=$AxisDecelerationMmSec2 mm/s^2, correction=$TimingCorrectionFactor"
Write-Host "Stop: Ctrl+C"
Write-Host ""

# =========================
# Watch loop
# =========================

while ($true) {
    if (Test-Path -LiteralPath $input) {
        Invoke-Cx24Job -InputPath $input -Folder $folder -OutputPath $output -LptPort $lpt
    }

    Start-Sleep -Milliseconds 500
}
