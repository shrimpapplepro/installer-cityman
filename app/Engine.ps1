# Install logic for the Lumia 950 XL LineageOS installer app.
# No UI code: LumiaInstaller.ps1 (and the tests) talk to it only through
# $Ctx, a synchronized hashtable:
#   in:  Root, Zip, LogFile, Cancel, PromptAnswer
#   out: Mode, Steps[name] = pending|running|done|failed|skipped,
#        Instruction, Prompt, Busy, Result (done|failed|cancelled), Error,
#        BackupDir, Log (queue of lines for the UI)
# Phone-side work is done by cityman.sh inside TWRP, the same helper the
# installer.bat / installer.sh scripts use.

$script:PhoneDir = '/tmp/cityman'

function New-InstallerContext([string]$Root) {
    $ctx = [hashtable]::Synchronized(@{})
    $ctx.Root = $Root
    $ctx.Adb = Join-Path $Root 'bin\adb.exe'
    $ctx.Fastboot = Join-Path $Root 'bin\fastboot.exe'
    $ctx.Zip = $null
    $ctx.LogFile = Join-Path $Root ('install_log_{0:yyyyMMdd-HHmm}.txt' -f (Get-Date))
    $ctx.Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $ctx.Steps = [hashtable]::Synchronized(@{})
    $ctx.Mode = 'none'
    $ctx.Busy = $false
    $ctx.Cancel = $false
    $ctx.Prompt = $null
    $ctx.PromptAnswer = $null
    $ctx.Instruction = $null
    $ctx.Result = $null
    $ctx.Error = $null
    $ctx.BackupDir = $null
    return $ctx
}

$script:StepNames = @('patch', 'twrp', 'backup', 'partition', 'firmware', 'install')

# An expected stop (failed check, cancel): the message is shown to the user.
function Stop-Install([string]$Message) { throw (New-Object System.ApplicationException $Message) }

function Write-Log($Ctx, [string]$Text) {
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -eq '') { continue }
        $Ctx.Log.Enqueue($line)
        try { Add-Content -LiteralPath $Ctx.LogFile -Value ('{0:HH:mm:ss} {1}' -f (Get-Date), $line) } catch {}
    }
}

function Set-Step($Ctx, [string]$Name, [string]$State) { $Ctx.Steps[$Name] = $State }

function Set-Instruction($Ctx, [string]$Text) {
    if ($Ctx.Instruction -eq $Text) { return }
    $Ctx.Instruction = $Text
    if ($Text) { Write-Log $Ctx "> $Text" }
}

function Test-Cancel($Ctx) {
    if ($Ctx.Cancel) { Stop-Install 'Stopped by you.' }
}

# Runs adb/fastboot without a window, with stdin closed, and returns
# Code + Out (stdout and stderr together). Kills it after $TimeoutSec.
function Invoke-Tool($Ctx, [string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 60) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        return [pscustomobject]@{ Code = -1; Out = "timed out after $TimeoutSec s" }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = ($out.Result + $err.Result).Trim() }
}

function Find-Efiesp {
    $candidates = @()
    if ($env:CITYMAN_EFIESP) {
        $candidates += $env:CITYMAN_EFIESP
    } else {
        # Drive letters first: needs no admin rights. Get-Volume also finds
        # an EFIESP that Windows mounted as a folder instead of a letter.
        $candidates += [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.VolumeLabel -eq 'EFIESP' } |
            ForEach-Object { $_.RootDirectory.FullName }
        try {
            $candidates += Get-Volume -FileSystemLabel EFIESP -ErrorAction Stop | Get-Partition |
                ForEach-Object AccessPaths | Where-Object { $_ -notlike '\\?\*' }
        } catch {}
    }
    foreach ($c in $candidates) {
        $path = $c.TrimEnd('\')
        if (Test-Path -LiteralPath (Join-Path $path 'EFI\Microsoft\BOOT\BCD')) { return $path }
    }
    return $null
}

# none | windows | mass-storage | lk2nd | lk2nd-nodriver | twrp | sideload | android | unauthorized
function Get-PhoneMode($Ctx) {
    $r = Invoke-Tool $Ctx $Ctx.Adb @('devices') 10
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match '^\S+\s+(device|recovery|sideload|unauthorized)\s*$') {
            switch ($Matches[1]) {
                'device' { return 'android' }
                'recovery' { return 'twrp' }
                'sideload' { return 'sideload' }
                'unauthorized' { return 'unauthorized' }
            }
        }
    }
    $r = Invoke-Tool $Ctx $Ctx.Fastboot @('devices') 10
    if ($r.Out -match '\sfastboot') { return 'lk2nd' }
    if (Find-Efiesp) { return 'mass-storage' }
    if (-not $env:CITYMAN_FAKE) {
        $usb = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object InstanceId)
        if ($usb -match '^USB\\VID_18D1&PID_D00D') { return 'lk2nd-nodriver' }
        if ($usb -match '^USB\\VID_045E&PID_0A00|^USB\\VID_0421&') { return 'windows' }
    }
    return 'none'
}

# Waits until the phone is in one of $Modes, showing $Instruction meanwhile.
function Wait-Mode($Ctx, [string[]]$Modes, [string]$Instruction) {
    while ($true) {
        Test-Cancel $Ctx
        $m = Get-PhoneMode $Ctx
        $Ctx.Mode = $m
        if ($Modes -contains $m) { Set-Instruction $Ctx $null; return $m }
        if ($m -eq 'lk2nd-nodriver') {
            Set-Instruction $Ctx ('The phone is in LK2ND but Windows has no driver for it. In Device Manager, ' +
                'find "Android" (or a device with a warning sign), choose Update driver and install the Google USB ' +
                'driver (Android Bootloader Interface). The installer continues by itself.')
        } elseif ($m -eq 'unauthorized') {
            Set-Instruction $Ctx 'Unlock the phone and tap Allow on the "Allow USB debugging?" message.'
        } elseif ($m -eq 'sideload') {
            Set-Instruction $Ctx 'The phone is waiting in ADB sideload mode: tap Cancel on the phone.'
        } else {
            Set-Instruction $Ctx $Instruction
        }
        Start-Sleep -Seconds 2
    }
}

function Request-Confirm($Ctx, [string]$Title, [string]$Text) {
    $Ctx.PromptAnswer = $null
    $Ctx.Prompt = @{ Title = $Title; Text = $Text }
    Write-Log $Ctx "? $Title"
    while ($null -eq $Ctx.PromptAnswer) { Start-Sleep -Milliseconds 200 }
    $answer = [bool]$Ctx.PromptAnswer
    $Ctx.Prompt = $null
    Write-Log $Ctx ("  answered " + $(if ($answer) { 'Yes' } else { 'No' }))
    return $answer
}

# Runs cityman.sh in TWRP. Success = it printed @@OK (or @@STATE=).
function Invoke-Helper($Ctx, [string[]]$Arguments, [int]$TimeoutSec = 600) {
    $r = Invoke-Tool $Ctx $Ctx.Adb (@('shell', ("bash $script:PhoneDir/cityman.sh " + ($Arguments -join ' ')))) $TimeoutSec
    $lines = $r.Out -split "`r?`n"
    Write-Log $Ctx (($lines | Where-Object { $_ -notmatch '@@' }) -join "`n")
    $state = $lines | Where-Object { $_ -match '^@@STATE=(\w+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1
    return [pscustomobject]@{ Ok = [bool]($lines -match '@@OK' -or $state); State = $state; Out = $r.Out }
}

function Push-File($Ctx, [string]$Local, [string]$Remote) {
    $r = Invoke-Tool $Ctx $Ctx.Adb @('push', $Local, $Remote) 300
    if ($r.Code -ne 0) {
        Write-Log $Ctx $r.Out
        Stop-Install "Could not copy $(Split-Path $Local -Leaf) to the phone. Is it still connected?"
    }
}

function Test-InstallerFiles($Ctx) {
    $problems = @()
    foreach ($f in 'BCD', 'bootshim.efi', 'Stage2.efi', 'developermenu.efi', 'emmc_appsboot.mbn', 'twrp.img', 'modem.img', 'PLAT.img') {
        $p = Join-Path $Ctx.Root "DATA\$f"
        if (-not (Test-Path -LiteralPath $p)) { $problems += "DATA\$f is missing" }
        elseif ($f -match '\.img$' -and (Get-Item -LiteralPath $p).Length -lt 1MB) { $problems += "DATA\$f is incomplete" }
    }
    foreach ($f in 'cityman.sh', 'bin\adb.exe', 'bin\fastboot.exe', 'ui') {
        if (-not (Test-Path -LiteralPath (Join-Path $Ctx.Root $f))) { $problems += "$f is missing" }
    }
    return $problems
}

function Find-LineageZip([string]$Root) {
    Get-ChildItem -LiteralPath $Root -Filter 'lineage-18.1*.zip' -File -ErrorAction SilentlyContinue |
        Where-Object Length -gt 0 | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

function Copy-Verified($Ctx, [string]$From, [string]$To) {
    $dir = Split-Path $To -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $From -Destination $To -Force
    if ((Get-FileHash -LiteralPath $From).Hash -ne (Get-FileHash -LiteralPath $To).Hash) {
        Stop-Install "Copying $(Split-Path $From -Leaf) to the phone failed."
    }
    Write-Log $Ctx "  copied $(Split-Path $From -Leaf)"
}

# --- Steps -------------------------------------------------------------

function Install-EfiespPatch($Ctx) {
    $esp = Find-Efiesp
    if (-not $esp) { Stop-Install 'The phone left Mass Storage Mode before its boot files were updated.' }
    if (-not (Request-Confirm $Ctx 'Replace Windows boot files?' (
            "The phone will boot the Android bootloader (LK2ND) instead of Windows.`n`n" +
            "Windows itself is erased later, after your backup is saved. Continue?"))) {
        Stop-Install 'Cancelled. Nothing was changed.'
    }
    $data = Join-Path $Ctx.Root 'DATA'
    $boot = Join-Path $esp 'Windows\System32\BOOT'
    Copy-Verified $Ctx "$data\BCD" "$esp\EFI\Microsoft\BOOT\BCD"
    Copy-Verified $Ctx "$data\bootshim.efi" "$boot\bootshim.efi"
    Copy-Verified $Ctx "$data\developermenu.efi" "$boot\developermenu.efi"
    Copy-Verified $Ctx "$data\Stage2.efi" "$esp\Stage2.efi"
    Copy-Verified $Ctx "$data\emmc_appsboot.mbn" "$esp\emmc_appsboot.mbn"
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Ctx.Root 'ui') -File) {
        Copy-Verified $Ctx $f.FullName "$boot\ui\$($f.Name)"
    }
    Write-Log $Ctx "Boot files updated on $esp"
}

# Gets the phone from LK2ND or Android into TWRP and copies the helper over.
function Start-Twrp($Ctx) {
    $boots = 0
    while ($true) {
        $m = Wait-Mode $Ctx @('twrp', 'lk2nd', 'android') (
            'Restart the phone: hold the Power button about 10 seconds until it vibrates. Keep the USB cable connected.')
        if ($m -eq 'twrp') { break }
        if ($m -eq 'android') {
            Write-Log $Ctx 'Android is running, restarting into LK2ND'
            Invoke-Tool $Ctx $Ctx.Adb @('reboot', 'bootloader') 30 | Out-Null
            Start-Sleep -Seconds 10
            continue
        }
        $boots++
        if ($boots -gt 3) { Stop-Install 'TWRP did not start after 3 tries. Unplug the phone, plug it back in and press Continue.' }
        Write-Log $Ctx 'LK2ND found, starting TWRP'
        $r = Invoke-Tool $Ctx $Ctx.Fastboot @('boot', (Join-Path $Ctx.Root 'DATA\twrp.img')) 120
        Write-Log $Ctx $r.Out
        # TWRP takes about 20 s to come up.
        for ($i = 0; $i -lt 30 -and (Get-PhoneMode $Ctx) -ne 'twrp'; $i++) { Test-Cancel $Ctx; Start-Sleep -Seconds 2 }
    }
    Write-Log $Ctx 'TWRP is running'
    Invoke-Tool $Ctx $Ctx.Adb @('shell', "mkdir -p $script:PhoneDir") 30 | Out-Null
    Push-File $Ctx (Join-Path $Ctx.Root 'cityman.sh') "$script:PhoneDir/cityman.sh"
    Push-File $Ctx (Join-Path $Ctx.Root 'DATA\emmc_appsboot.mbn') "$script:PhoneDir/emmc_appsboot.mbn"
}

function Backup-Phone($Ctx) {
    if (-not (Invoke-Helper $Ctx @('backup')).Ok) { Stop-Install 'The backup failed. Nothing was changed on the phone.' }
    $tmp = Join-Path $Ctx.Root 'cityman-backup'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    $r = Invoke-Tool $Ctx $Ctx.Adb @('pull', '/tmp/cityman-backup', $tmp) 300
    Write-Log $Ctx $r.Out
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'DPP.bin'))) {
        Stop-Install 'Could not copy the backup to this PC. Nothing was changed on the phone.'
    }
    $dest = Join-Path $Ctx.Root ('backup-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    Move-Item -LiteralPath $tmp -Destination $dest
    $Ctx.BackupDir = $dest
    Write-Log $Ctx "Backup saved to $dest"
}

function Get-Layout($Ctx) {
    $r = Invoke-Helper $Ctx @('state')
    if (-not $r.State) { Stop-Install "Could not read the phone's partition table." }
    Write-Log $Ctx "Partition layout: $($r.State)"
    return $r.State
}

function Invoke-Repartition($Ctx) {
    if (-not (Request-Confirm $Ctx 'Erase Windows?' (
            "Windows and everything stored in it will be deleted and replaced with Android partitions.`n`n" +
            "Your phone's backup is saved in:`n$($Ctx.BackupDir)`n`nErase Windows now?"))) {
        Stop-Install 'Cancelled before erasing Windows. The phone still has Windows on it.'
    }
    $plat = Join-Path $Ctx.Root 'DATA\PLAT.img'
    if (Test-Path -LiteralPath $plat) {
        Push-File $Ctx $plat "$script:PhoneDir/PLAT.img"
        Invoke-Helper $Ctx @('flash', 'PLAT', "$script:PhoneDir/PLAT.img") | Out-Null
    }
    Write-Log $Ctx 'Repartitioning, about a minute'
    if (-not (Invoke-Helper $Ctx @('partition') 900).Ok) { Stop-Install 'Repartitioning failed. The details are in the log.' }
}

function Test-Aboot($Ctx) {
    if ((Invoke-Helper $Ctx @('verify-aboot')).Ok) { return }
    Write-Log $Ctx 'The bootloader copy on aboot is damaged, rewriting it'
    if (-not (Invoke-Helper $Ctx @('repair-aboot')).Ok) { Stop-Install 'Could not repair the aboot partition.' }
}

function Write-Firmware($Ctx) {
    foreach ($item in @(@('twrp.img', 'recovery'), @('modem.img', 'modem'))) {
        Push-File $Ctx (Join-Path $Ctx.Root "DATA\$($item[0])") "$script:PhoneDir/$($item[0])"
        if (-not (Invoke-Helper $Ctx @('flash', $item[1], "$script:PhoneDir/$($item[0])")).Ok) {
            Stop-Install "Writing $($item[1]) failed. The details are in the log."
        }
    }
    Invoke-Tool $Ctx $Ctx.Adb @('shell', "rm -f $script:PhoneDir/twrp.img $script:PhoneDir/modem.img") 30 | Out-Null
    if (-not (Invoke-Helper $Ctx @('provision')).Ok) { Stop-Install 'Provisioning failed. The details are in the log.' }
}

function Install-Lineage($Ctx) {
    if (-not $Ctx.Zip -or -not (Test-Path -LiteralPath $Ctx.Zip)) { Stop-Install 'Choose the LineageOS zip first.' }
    Invoke-Tool $Ctx $Ctx.Adb @('shell', 'twrp sideload') 30 | Out-Null
    $waited = 0
    while ((Get-PhoneMode $Ctx) -ne 'sideload') {
        Test-Cancel $Ctx
        $waited++
        if ($waited -eq 5) { Set-Instruction $Ctx 'On the phone, tap Advanced, then ADB Sideload, and swipe to start.' }
        Start-Sleep -Seconds 2
    }
    Set-Instruction $Ctx $null
    Write-Log $Ctx "Sending $(Split-Path $Ctx.Zip -Leaf), a few minutes"
    # adb sideload often exits non-zero ("failed to read command") even on
    # success, so the result is checked on the phone instead.
    $r = Invoke-Tool $Ctx $Ctx.Adb @('sideload', $Ctx.Zip) 1800
    Write-Log $Ctx $r.Out
    $waited = 0
    while ((Get-PhoneMode $Ctx) -ne 'twrp') {
        $waited++
        if ($waited -gt 60) { Stop-Install 'TWRP did not come back after the install. Look at the phone screen.' }
        Start-Sleep -Seconds 2
    }
    if (-not (Invoke-Helper $Ctx @('verify-system')).Ok) {
        Stop-Install 'LineageOS is not on the phone. The TWRP screen shows why (often a damaged download).'
    }
    Invoke-Tool $Ctx $Ctx.Adb @('reboot') 30 | Out-Null
}

# --- Flows -------------------------------------------------------------

function Invoke-Flow($Ctx, [scriptblock]$Body) {
    $Ctx.Busy = $true
    $Ctx.Cancel = $false
    $Ctx.Result = $null
    $Ctx.Error = $null
    try {
        & $Body
        $Ctx.Result = 'done'
    } catch [System.ApplicationException] {
        $Ctx.Error = $_.Exception.Message
        $Ctx.Result = $(if ($Ctx.Cancel) { 'cancelled' } else { 'failed' })
    } catch {
        $Ctx.Error = "Unexpected error: $($_.Exception.Message)"
        $Ctx.Result = 'failed'
    } finally {
        foreach ($s in $script:StepNames) { if ($Ctx.Steps[$s] -eq 'running') { $Ctx.Steps[$s] = 'failed' } }
        if ($Ctx.Error) { Write-Log $Ctx "STOPPED: $($Ctx.Error)" }
        Set-Instruction $Ctx $null
        $Ctx.Busy = $false
    }
}

function Start-Install($Ctx) {
    Invoke-Flow $Ctx {
        foreach ($s in $script:StepNames) { Set-Step $Ctx $s 'pending' }
        Write-Log $Ctx "Install started, zip: $($Ctx.Zip)"
        $m = Wait-Mode $Ctx @('mass-storage', 'lk2nd', 'twrp', 'android', 'sideload') (
            'Connect the phone. If it still runs Windows: unlock the bootloader with WPinternals, ' +
            'then choose "Switch to Mass Storage mode" in WPinternals. The installer continues by itself.')
        if ($m -eq 'mass-storage') {
            Set-Step $Ctx 'patch' 'running'
            Install-EfiespPatch $Ctx
            Set-Step $Ctx 'patch' 'done'
        } else {
            Set-Step $Ctx 'patch' 'skipped'
        }
        Set-Step $Ctx 'twrp' 'running'; Start-Twrp $Ctx; Set-Step $Ctx 'twrp' 'done'
        Set-Step $Ctx 'backup' 'running'; Backup-Phone $Ctx; Set-Step $Ctx 'backup' 'done'
        Set-Step $Ctx 'partition' 'running'
        switch (Get-Layout $Ctx) {
            'windows' { Invoke-Repartition $Ctx; Set-Step $Ctx 'partition' 'done' }
            'partitioned' { Test-Aboot $Ctx; Set-Step $Ctx 'partition' 'skipped' }
            default { Stop-Install 'The phone has neither the Windows nor the Android partition layout. Stop here and ask for help.' }
        }
        Set-Step $Ctx 'firmware' 'running'; Write-Firmware $Ctx; Set-Step $Ctx 'firmware' 'done'
        Set-Step $Ctx 'install' 'running'; Install-Lineage $Ctx; Set-Step $Ctx 'install' 'done'
        Write-Log $Ctx 'Install finished, the phone is starting LineageOS'
    }
}

function Start-Repair($Ctx) {
    Invoke-Flow $Ctx {
        foreach ($s in $script:StepNames) { Set-Step $Ctx $s $(if ($s -in 'twrp', 'firmware') { 'pending' } else { 'skipped' }) }
        Write-Log $Ctx 'Repair started'
        Set-Step $Ctx 'twrp' 'running'; Start-Twrp $Ctx; Set-Step $Ctx 'twrp' 'done'
        if ((Get-Layout $Ctx) -ne 'partitioned') { Stop-Install 'The phone is not set up for Android yet. Use Install instead.' }
        Test-Aboot $Ctx
        Set-Step $Ctx 'firmware' 'running'; Write-Firmware $Ctx; Set-Step $Ctx 'firmware' 'done'
        Invoke-Tool $Ctx $Ctx.Adb @('reboot') 30 | Out-Null
        Write-Log $Ctx 'Repair finished, the phone is restarting'
    }
}

function Start-Rescue($Ctx) {
    Invoke-Flow $Ctx {
        foreach ($s in $script:StepNames) { Set-Step $Ctx $s $(if ($s -eq 'patch') { 'pending' } else { 'skipped' }) }
        Write-Log $Ctx 'Rescue started'
        Wait-Mode $Ctx @('mass-storage') (
            'Put the phone in Mass Storage Mode: hold Power + Volume Down about 10 seconds until it vibrates, ' +
            'then hold the Camera button and choose Mass Storage Mode in the menu.') | Out-Null
        Set-Step $Ctx 'patch' 'running'
        $esp = Find-Efiesp
        $data = Join-Path $Ctx.Root 'DATA'
        Copy-Verified $Ctx "$data\emmc_appsboot.mbn" "$esp\emmc_appsboot.mbn"
        if (-not (Test-Path -LiteralPath "$esp\Stage2.efi")) { Copy-Verified $Ctx "$data\Stage2.efi" "$esp\Stage2.efi" }
        Set-Step $Ctx 'patch' 'done'
        Write-Log $Ctx 'Bootloader restored. Hold Power about 10 seconds to restart the phone.'
    }
}
