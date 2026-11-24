param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$ReadyFile,
    [ValidatePattern('^\d+$')][string]$RoomId
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class SimpleLiveResizeProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr other, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
}
'@

function Send-WindowMessage($Window, [uint32]$Message) {
    $result = [IntPtr]::Zero
    return [SimpleLiveResizeProbe]::SendMessageTimeout(
        $Window, $Message, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$result
    ) -ne [IntPtr]::Zero
}

function Measure-Frame($Window, [string]$Stage) {
    $client = [SimpleLiveResizeProbe+Rect]::new()
    $flutter = [SimpleLiveResizeProbe+Rect]::new()
    $child = [SimpleLiveResizeProbe]::GetWindow($Window, 5) # GW_CHILD
    [void][SimpleLiveResizeProbe]::GetClientRect($Window, [ref]$client)
    [void][SimpleLiveResizeProbe]::GetClientRect($child, [ref]$flutter)
    $responsive = Send-WindowMessage $Window 0 # WM_NULL
    $captured = $false
    $colors = [System.Collections.Generic.HashSet[int]]::new()
    if ($client.Right -gt 0 -and $client.Bottom -gt 0) {
        $frame = [Drawing.Bitmap]::new($client.Right, $client.Bottom)
        try {
            $graphics = [Drawing.Graphics]::FromImage($frame)
            $dc = $graphics.GetHdc()
            try {
                $captured = [SimpleLiveResizeProbe]::PrintWindow($Window, $dc, 3)
            } finally {
                $graphics.ReleaseHdc($dc)
                $graphics.Dispose()
            }
            if ($captured) {
                for ($row = 1; $row -lt 12; $row++) {
                    for ($column = 1; $column -lt 16; $column++) {
                        [void]$colors.Add($frame.GetPixel(
                            [int]($column * $client.Right / 16),
                            [int]($row * $client.Bottom / 12)
                        ).ToArgb())
                    }
                }
            }
        } finally {
            $frame.Dispose()
        }
    }
    [pscustomobject]@{
        stage = $Stage
        dpi = [SimpleLiveResizeProbe]::GetDpiForWindow($Window)
        client = "$($client.Right)x$($client.Bottom)"
        child = "$($flutter.Right)x$($flutter.Bottom)"
        responsive = $responsive
        captured = $captured
        colors = $colors.Count
    }
}

$exe = (Resolve-Path -LiteralPath $Executable).Path
if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue) {
    throw 'Close the running Simple Live instance before starting this test.'
}
$launch = @{
    FilePath = $exe
    WorkingDirectory = Split-Path $exe
    WindowStyle = 'Hidden'
    PassThru = $true
}
if ($ReadyFile) {
    if (!$RoomId -or (Test-Path -LiteralPath $ReadyFile)) {
        throw 'Supply a public Douyin room ID and a new readiness file path.'
    }
    $ReadyFile = [IO.Path]::GetFullPath($ReadyFile)
    $launch.Environment = @{
        SIMPLE_LIVE_RESIZE_READY = $ReadyFile
        SIMPLE_LIVE_RESIZE_ROOM = $RoomId
    }
}
$process = Start-Process @launch
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(70)
    do {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        if ($process.HasExited) { throw "App exited during startup ($($process.ExitCode))." }
        $ready = $process.MainWindowHandle -ne [IntPtr]::Zero -and
            (!$ReadyFile -or (Test-Path -LiteralPath $ReadyFile))
    } until ($ready -or [DateTime]::UtcNow -ge $deadline)
    if (!$ready) { throw 'The app did not provide a ready window.' }

    Start-Sleep -Milliseconds 1500
    $window = $process.MainWindowHandle
    $frames = @(& {
        Measure-Frame $window 'startup'
        [void](Send-WindowMessage $window 0x0231) # WM_ENTERSIZEMOVE
        foreach ($size in @(@(602, 470), @(683, 525), @(741, 608), @(796, 562))) {
            if (![SimpleLiveResizeProbe]::SetWindowPos(
                $window, [IntPtr]::Zero, 0, 0, $size[0], $size[1], 0x16
            )) { throw 'Could not resize the test window.' }
            Start-Sleep -Milliseconds 500
            Measure-Frame $window 'resize'
        }
        [void](Send-WindowMessage $window 0x0232) # WM_EXITSIZEMOVE
        foreach ($transition in @(@(3, 'maximize'), @(9, 'restore'), @(6, 'minimize'), @(9, 'restore after minimize'))) {
            [void][SimpleLiveResizeProbe]::ShowWindowAsync($window, $transition[0])
            $expectedZoomed = $transition[0] -eq 3
            $expectedIconic = $transition[0] -eq 6
            $transitionDeadline = [DateTime]::UtcNow.AddSeconds(3)
            do {
                Start-Sleep -Milliseconds 100
                $settled = [SimpleLiveResizeProbe]::IsZoomed($window) -eq $expectedZoomed -and
                    [SimpleLiveResizeProbe]::IsIconic($window) -eq $expectedIconic
            } until ($settled -or [DateTime]::UtcNow -ge $transitionDeadline)
            if (!$settled) { throw "The window did not reach $($transition[1])." }
            Start-Sleep -Milliseconds 650
            if ($transition[0] -ne 6) { Measure-Frame $window $transition[1] }
        }
    })
    foreach ($frame in $frames) { $frame | ConvertTo-Json -Compress }
    if (@($frames | Where-Object stage -eq 'resize' | Select-Object -ExpandProperty client -Unique).Count -ne 4) {
        throw 'The four requested sizes did not reach the Windows client area.'
    }
    if ($frames | Where-Object {
        !$_.responsive -or !$_.captured -or $_.client -ne $_.child -or $_.colors -lt 5
    }) { throw 'The client failed to render after a window transition.' }
    if ($ReadyFile) {
        $reportPath = "$ReadyFile.json"
        $report = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 250
            try { $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json } catch {}
        } until ($report.chatAfterEnabling -or $report.dartErrors -or [DateTime]::UtcNow -ge $deadline)
        $report | ConvertTo-Json -Compress
        if ($report.dartErrors -or !$report.playing -or !$report.playbackAdvanced -or
            !$report.sameChatPainted -or !$report.chatWhileHidden -or !$report.chatAfterEnabling) {
            throw 'The live player or chat did not complete the Release smoke test.'
        }
    }
} finally {
    if (!$process.HasExited) { [void]$process.CloseMainWindow() }
    $process.Dispose()
}
