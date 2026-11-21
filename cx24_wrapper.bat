<# : batch launcher - the PowerShell part below is run by this header
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = [System.IO.File]::ReadAllText('%~f0'); Invoke-Expression $s"
exit /b %errorlevel%
#>

# =========================
# CX-24 compatibility wrapper (no preview)
# Watches input.prn, converts the GX-24 driver output to plain CAMM-GL
# for the CX-24 and sends it to the parallel port.
# =========================

$folder    = "C:\ProgramData\CX24"
$inputPath = Join-Path $folder "input.prn"
$output    = Join-Path $folder "cx24_clean.plt"
$lpt       = "LPT1:"

New-Item -ItemType Directory -Force -Path $folder | Out-Null

# Same lock file as cx24_watch.ps1, so the two can never run at the same time
# and cut the same job twice.
$lockPath = Join-Path $folder "cx24_watch.lock"
try {
    $Global:Cx24LockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
}
catch {
    Write-Host "A CX-24 watcher instance is already running. Exiting to avoid duplicate cutting."
    Write-Host "Lock: $lockPath"
    exit 0
}

$enc = [System.Text.Encoding]::GetEncoding(28591)

function Wait-AndCaptureInput {
    param([string]$SourcePath, [string]$Folder)

    # Move input.prn to a unique name first, then wait until its size is stable.
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
            $processing = $null
            Start-Sleep -Milliseconds 150
        }
    }

    if (-not $processing -or -not (Test-Path -LiteralPath $processing)) {
        return $null
    }

    $lastLen = -1
    $stableCount = 0
    $deadline = (Get-Date).AddSeconds(30)

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $processing)) {
            return $null
        }

        try {
            $len = (Get-Item -LiteralPath $processing -ErrorAction Stop).Length
            if ($len -gt 0 -and $len -eq $lastLen) { $stableCount++ } else { $stableCount = 0 }
            $lastLen = $len
            if ($stableCount -ge 2) { return $processing }
        }
        catch { }

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

function Invoke-Cx24Job {
    $processing = $null

    try {
        Write-Host "New job received..."

        $processing = Wait-AndCaptureInput -SourcePath $inputPath -Folder $folder
        if (-not $processing) {
            Write-Host "Input was not stable or disappeared; skipping."
            Start-Sleep -Milliseconds 300
            return
        }

        Convert-GX24-To-CX24 $processing $output

        Write-Host "Sending to $lpt..."
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c copy /b `"$output`" `"$lpt`"" -WindowStyle Hidden -PassThru -Wait
        if ($p.ExitCode -ne 0) {
            throw "copy to $lpt failed (exit code $($p.ExitCode))."
        }

        Remove-Item -LiteralPath $processing -Force -ErrorAction SilentlyContinue
        Write-Host "Done."
        Write-Host ""
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)"

        $errFileName = "input_" + (Get-Date -Format "yyyyMMdd_HHmmss_fff") + ".error.prn"
        if ($processing -and (Test-Path -LiteralPath $processing)) {
            Rename-Item -LiteralPath $processing -NewName $errFileName -Force -ErrorAction SilentlyContinue
        }
        elseif (Test-Path -LiteralPath $inputPath) {
            Rename-Item -LiteralPath $inputPath -NewName $errFileName -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Failed job moved aside: $(Join-Path $folder $errFileName)"
        Write-Host ""
    }
}

Write-Host "CX-24 wrapper is running (no preview). Watched file: $inputPath"
Write-Host "Output: $lpt"
Write-Host "Stop: Ctrl+C"
Write-Host ""

while ($true) {
    if (Test-Path -LiteralPath $inputPath) {
        Invoke-Cx24Job
    }
    Start-Sleep -Milliseconds 500
}
