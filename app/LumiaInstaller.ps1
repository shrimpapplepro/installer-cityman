# Window for the Lumia 950 XL LineageOS installer. Start it with
# "Install LineageOS.cmd". The install logic lives in Engine.ps1 and runs in a
# background runspace; this file only shows its state and asks questions.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Cityman -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Cityman.Dpi]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

$AppDir = $PSScriptRoot
$Root = Split-Path $AppDir -Parent
. (Join-Path $AppDir 'Engine.ps1')

$ctx = New-InstallerContext $Root
$ctx.Zip = Find-LineageZip $Root
$ctx.Closing = $false
$ctx.Started = $false
$FileProblems = @(Test-InstallerFiles $ctx)

# --- Look -------------------------------------------------------------

$Font = New-Object Drawing.Font('Segoe UI', 10)
$FontBold = New-Object Drawing.Font('Segoe UI Semibold', 10)
$FontTitle = New-Object Drawing.Font('Segoe UI Semibold', 15)
$FontMono = New-Object Drawing.Font('Consolas', 9)
$ColorMuted = [Drawing.Color]::FromArgb(96, 96, 96)
$ColorInfo = [Drawing.Color]::FromArgb(255, 244, 206)   # Windows warning bar
$ColorOk = [Drawing.Color]::FromArgb(223, 246, 221)     # Windows success bar
$ColorError = [Drawing.Color]::FromArgb(253, 231, 233)  # Windows error bar
$Glyph = @{
    pending = [string][char]0x25CB; running = [string][char]0x25D0; done = [string][char]0x2714
    failed = [string][char]0x2716; skipped = [string][char]0x2014
}
$GlyphColor = @{
    pending = $ColorMuted; running = [Drawing.Color]::FromArgb(0, 103, 192); done = [Drawing.Color]::FromArgb(16, 124, 16)
    failed = [Drawing.Color]::FromArgb(196, 43, 28); skipped = $ColorMuted
}

$ModeText = @{
    'none' = @('Not connected', $ColorMuted)
    'windows' = @('Connected, still running Windows', [Drawing.Color]::FromArgb(157, 93, 0))
    'mass-storage' = @('Mass Storage Mode', [Drawing.Color]::FromArgb(16, 124, 16))
    'lk2nd' = @('LK2ND bootloader', [Drawing.Color]::FromArgb(16, 124, 16))
    'lk2nd-nodriver' = @('LK2ND bootloader, Windows driver missing', [Drawing.Color]::FromArgb(157, 93, 0))
    'twrp' = @('TWRP recovery', [Drawing.Color]::FromArgb(16, 124, 16))
    'sideload' = @('TWRP, ADB sideload', [Drawing.Color]::FromArgb(16, 124, 16))
    'android' = @('Android (USB debugging on)', [Drawing.Color]::FromArgb(16, 124, 16))
    'unauthorized' = @('Android, waiting for you to allow USB debugging', [Drawing.Color]::FromArgb(157, 93, 0))
}

$IdleHint = @{
    'none' = 'Connect the phone with a USB cable.'
    'windows' = 'This Lumia still runs Windows. Unlock its bootloader with WPinternals, then choose "Switch to Mass Storage mode" in WPinternals. Press Install at any time: the installer waits for the phone.'
    'mass-storage' = 'Ready. Press Install.'
    'lk2nd' = 'Ready. Press Install to continue the installation.'
    'lk2nd-nodriver' = 'Windows has no driver for the phone in LK2ND. In Device Manager, update the driver of "Android" (or the device with a warning sign) to the Google USB driver, "Android Bootloader Interface".'
    'twrp' = 'Ready. Press Install to continue the installation, or to update LineageOS (apps and files are kept). Repair fixes missing sound or mobile signal.'
    'sideload' = 'The phone is in ADB sideload mode. Tap Cancel on the phone, then press Install.'
    'android' = 'LineageOS is running. To update it, choose the new LineageOS zip and press Install: your apps and files are kept. If sound or mobile signal do not work, use Repair.'
    'unauthorized' = 'Unlock the phone and tap Allow on the "Allow USB debugging?" message.'
}

$StepText = [ordered]@{
    patch = 'Make the phone boot Android instead of Windows'
    twrp = 'Start the installer on the phone (TWRP)'
    backup = 'Back up IMEI, radio calibration and MAC addresses to this PC'
    partition = 'Replace Windows with Android partitions'
    firmware = 'Write modem and audio firmware, recovery and phone settings'
    install = 'Install LineageOS'
}

# --- Layout -----------------------------------------------------------

function New-Label([string]$Text, $Font = $script:Font) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font; $l.AutoSize = $true
    $l.Margin = New-Object Windows.Forms.Padding(0, 3, 0, 3)
    return $l
}

$form = New-Object Windows.Forms.Form
$form.Text = 'LineageOS installer - Lumia 950 XL'
$form.Font = $Font
$form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object Drawing.Size(640, 560)
$form.MinimumSize = New-Object Drawing.Size(560, 520)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [Drawing.Color]::White
$form.AllowDrop = $true

$main = New-Object Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'; $main.ColumnCount = 1; $main.Padding = New-Object Windows.Forms.Padding(20, 16, 20, 16)
$main.AutoScroll = $true
$form.Controls.Add($main)
function Add-Row($Control, [string]$SizeType = 'AutoSize') {
    [void]$main.RowStyles.Add((New-Object Windows.Forms.RowStyle($SizeType)))
    $Control.Dock = 'Fill'
    $main.Controls.Add($Control)
}

$title = New-Label 'LineageOS for the Lumia 950 XL' $FontTitle
Add-Row $title
$subtitle = New-Label 'Connect the phone, choose the LineageOS zip and press Install. The installer tells you when it needs you.'
$subtitle.ForeColor = $ColorMuted; $subtitle.MaximumSize = New-Object Drawing.Size(600, 0)
$subtitle.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
Add-Row $subtitle

# Phone + zip rows
$grid = New-Object Windows.Forms.TableLayoutPanel
$grid.ColumnCount = 3; $grid.AutoSize = $true
[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$grid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
$grid.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
$grid.Controls.Add((New-Label 'Phone' $FontBold), 0, 0)
$phoneLabel = New-Label ''
$phoneLabel.Margin = New-Object Windows.Forms.Padding(12, 3, 0, 3)
$grid.Controls.Add($phoneLabel, 1, 0)
$grid.Controls.Add((New-Label 'LineageOS zip' $FontBold), 0, 1)
$zipLabel = New-Label ''
$zipLabel.AutoSize = $false; $zipLabel.AutoEllipsis = $true; $zipLabel.Dock = 'Fill'; $zipLabel.TextAlign = 'MiddleLeft'
$zipLabel.Margin = New-Object Windows.Forms.Padding(12, 3, 8, 3)
$grid.Controls.Add($zipLabel, 1, 1)
$zipButton = New-Object Windows.Forms.Button
$zipButton.Text = 'Choose...'; $zipButton.AutoSize = $true; $zipButton.FlatStyle = 'System'
$grid.Controls.Add($zipButton, 2, 1)
Add-Row $grid

# Steps
$stepsBox = New-Object Windows.Forms.TableLayoutPanel
$stepsBox.ColumnCount = 2; $stepsBox.AutoSize = $true
[void]$stepsBox.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 28)))
[void]$stepsBox.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
$stepGlyphs = @{}; $stepLabels = @{}
$row = 0
foreach ($name in $StepText.Keys) {
    $g = New-Label $Glyph.pending (New-Object Drawing.Font('Segoe UI Symbol', 11))
    $g.ForeColor = $ColorMuted
    $t = New-Label $StepText[$name]
    $stepsBox.Controls.Add($g, 0, $row); $stepsBox.Controls.Add($t, 1, $row)
    $stepGlyphs[$name] = $g; $stepLabels[$name] = $t
    $row++
}
$stepsBox.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
Add-Row $stepsBox

# "What to do now" banner
$banner = New-Object Windows.Forms.Label
$banner.AutoSize = $true; $banner.MaximumSize = New-Object Drawing.Size(600, 0); $banner.MinimumSize = New-Object Drawing.Size(600, 0)
$banner.Padding = New-Object Windows.Forms.Padding(12, 10, 12, 10)
$banner.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
$banner.Font = $FontBold
Add-Row $banner

$progress = New-Object Windows.Forms.ProgressBar
$progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30; $progress.Height = 6; $progress.Visible = $false
$progress.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
Add-Row $progress

# Buttons
$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.AutoSize = $true; $buttons.WrapContents = $true
function New-Button([string]$Text, [int]$Width = 0) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.AutoSize = $true; $b.FlatStyle = 'System'
    $b.Padding = New-Object Windows.Forms.Padding(10, 2, 10, 2)
    $b.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    return $b
}
$installButton = New-Button 'Install'
$installButton.Font = $FontBold
$stopButton = New-Button 'Stop'
$repairButton = New-Button 'Repair sound / signal'
$rescueButton = New-Button 'Phone won''t start'
$buttons.Controls.AddRange(@($installButton, $stopButton, $repairButton, $rescueButton))
$buttons.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
Add-Row $buttons

$links = New-Object Windows.Forms.FlowLayoutPanel
$links.AutoSize = $true
function New-Link([string]$Text) {
    $l = New-Object Windows.Forms.LinkLabel
    $l.Text = $Text; $l.AutoSize = $true; $l.Margin = New-Object Windows.Forms.Padding(0, 0, 16, 0)
    return $l
}
$detailsLink = New-Link 'Show details'
$backupLink = New-Link 'Open backup folder'
$logLink = New-Link 'Open log'
$helpLink = New-Link 'Help'
$links.Controls.AddRange(@($detailsLink, $backupLink, $logLink, $helpLink))
Add-Row $links

$details = New-Object Windows.Forms.TextBox
$details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
$details.Font = $FontMono; $details.Height = 170; $details.Visible = $false; $details.BackColor = [Drawing.Color]::FromArgb(250, 250, 250)
$details.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 0)
Add-Row $details

# --- Behaviour ----------------------------------------------------------

function Set-Zip([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path) -and $Path -like '*.zip') { $ctx.Zip = $Path }
}

$zipButton.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = 'LineageOS zip (lineage-*.zip)|lineage-*.zip|All zip files (*.zip)|*.zip'
    $dlg.InitialDirectory = $(if ($ctx.Zip) { Split-Path $ctx.Zip -Parent } else { [Environment]::GetFolderPath('UserProfile') + '\Downloads' })
    if ($dlg.ShowDialog($form) -eq 'OK') { Set-Zip $dlg.FileName }
})
$form.Add_DragEnter({ if ($_.Data.GetDataPresent('FileDrop')) { $_.Effect = 'Copy' } })
$form.Add_DragDrop({ Set-Zip (@($_.Data.GetData('FileDrop')) | Select-Object -First 1) })

$script:Worker = $null
function Start-Worker([string]$Flow, [string]$Label) {
    $ctx.Started = $true
    $ctx.FlowLabel = $Label
    $ctx.Busy = $true
    $details.Clear()
    $ps = [powershell]::Create()
    $ps.Runspace = [runspacefactory]::CreateRunspace()
    $ps.Runspace.ApartmentState = 'STA'
    $ps.Runspace.Open()
    [void]$ps.AddScript(". '$AppDir\Engine.ps1'; $Flow `$args[0]").AddArgument($ctx)
    $script:Worker = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

$installButton.Add_Click({ Start-Worker 'Start-Install' $installButton.Text })
$repairButton.Add_Click({ Start-Worker 'Start-Repair' $repairButton.Text })
$rescueButton.Add_Click({ Start-Worker 'Start-Rescue' $rescueButton.Text })
$stopButton.Add_Click({
    $ctx.Cancel = $true
    $stopButton.Enabled = $false
    $ctx.Log.Enqueue('Stopping after the current step...')
})
$detailsLink.Add_LinkClicked({
    $details.Visible = -not $details.Visible
    $grow = $details.Height + $details.Margin.Vertical
    $form.Height += $(if ($details.Visible) { $grow } else { -$grow })
    $detailsLink.Text = $(if ($details.Visible) { 'Hide details' } else { 'Show details' })
})
$backupLink.Add_LinkClicked({
    $latest = Get-ChildItem -LiteralPath $Root -Directory -Filter 'backup-*' | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($latest) { Start-Process explorer.exe $latest.FullName }
    else { [void][Windows.Forms.MessageBox]::Show($form, 'There is no backup yet. It is made during the install.', $form.Text) }
})
$logLink.Add_LinkClicked({ if (Test-Path -LiteralPath $ctx.LogFile) { Start-Process notepad.exe $ctx.LogFile } })
$helpLink.Add_LinkClicked({ Start-Process 'https://github.com/shrimpapplepro/installer-cityman#readme' })

# Phone detection while idle (the worker updates Mode itself while busy).
$monitor = [powershell]::Create()
$monitor.Runspace = [runspacefactory]::CreateRunspace()
$monitor.Runspace.Open()
[void]$monitor.AddScript({
    param($ctx, $engine)
    . $engine
    while (-not $ctx.Closing) {
        if (-not $ctx.Busy) { try { $ctx.Mode = Get-PhoneMode $ctx } catch {} }
        Start-Sleep -Milliseconds 1500
    }
}).AddArgument($ctx).AddArgument((Join-Path $AppDir 'Engine.ps1'))
$monitorHandle = $monitor.BeginInvoke()

function Set-Banner([string]$Text, $Color) {
    $banner.Visible = [bool]$Text
    if ($banner.Text -ne $Text) { $banner.Text = $Text }
    $banner.BackColor = $Color
}

$script:Prompting = $false
function Update-Ui {
    $line = $null
    while ($ctx.Log.TryDequeue([ref]$line)) { $details.AppendText($line + "`r`n") }

    $m = $ModeText[$ctx.Mode]
    $phoneLabel.Text = [char]0x25CF + '  ' + $m[0]
    $phoneLabel.ForeColor = $m[1]
    $zipLabel.Text = $(if ($ctx.Zip) { Split-Path $ctx.Zip -Leaf } else { 'Not chosen. Download it from the Releases page, then choose it here.' })
    $zipLabel.ForeColor = $(if ($ctx.Zip) { [Drawing.Color]::Black } else { $ColorMuted })

    foreach ($name in $StepText.Keys) {
        $state = $ctx.Steps[$name]
        if (-not $state) { $state = 'pending' }
        $stepGlyphs[$name].Text = $Glyph[$state]
        $stepGlyphs[$name].ForeColor = $GlyphColor[$state]
        $stepLabels[$name].ForeColor = $(if ($state -in 'skipped') { $ColorMuted } else { [Drawing.Color]::Black })
        $stepLabels[$name].Font = $(if ($state -eq 'running') { $FontBold } else { $Font })
    }

    $busy = [bool]$ctx.Busy
    if ($FileProblems.Count) {
        Set-Banner ("Some installer files are missing or incomplete; download the installer again.`n" + ($FileProblems -join "`n")) $ColorError
    } elseif ($busy) {
        $text = $ctx.Instruction
        if (-not $text) { $text = $(if ($ctx.Cancel) { 'Stopping after the current step...' } else { 'Working. Keep the phone connected.' }) }
        Set-Banner $text $ColorInfo
    } elseif ($ctx.Result -eq 'done') {
        $msg = 'Done. The phone is starting LineageOS; the first start takes a few minutes.'
        if ($ctx.BackupDir) { $msg += "`nKeep the backup folder, it cannot be downloaded again:`n$($ctx.BackupDir)" }
        Set-Banner $msg $ColorOk
    } elseif ($ctx.Result -in 'failed', 'cancelled') {
        Set-Banner ("Stopped: $($ctx.Error)`nWhen ready, press $($ctx.FlowLabel) again; it continues where it stopped.") $ColorError
    } else {
        Set-Banner $IdleHint[$ctx.Mode] $ColorInfo
    }

    $progress.Visible = $busy -and -not $ctx.Instruction
    $installButton.Enabled = -not $busy -and -not $FileProblems.Count -and [bool]$ctx.Zip
    $repairButton.Enabled = -not $FileProblems.Count
    $rescueButton.Enabled = -not $FileProblems.Count
    $repairButton.Visible = -not $busy
    $rescueButton.Visible = -not $busy
    $stopButton.Visible = $busy
    if (-not $busy) { $stopButton.Enabled = $true }
    $zipButton.Enabled = -not $busy

    if ($ctx.Prompt -and $null -eq $ctx.PromptAnswer -and -not $script:Prompting) {
        $script:Prompting = $true
        $timer.Stop()
        $answer = [Windows.Forms.MessageBox]::Show($form, $ctx.Prompt.Text, $ctx.Prompt.Title, 'YesNo', 'Warning', 'Button2')
        $ctx.PromptAnswer = ($answer -eq 'Yes')
        $script:Prompting = $false
        $timer.Start()
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({ Update-Ui })

$form.Add_FormClosing({
    if ($ctx.Busy) {
        $r = [Windows.Forms.MessageBox]::Show($form,
            "The installer is still working. Closing now can leave the phone unable to start.`n`nClose anyway?",
            $form.Text, 'YesNo', 'Warning', 'Button2')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
        $ctx.Cancel = $true
    }
    $ctx.Closing = $true
    $timer.Stop()
})

Update-Ui
if ($env:CITYMAN_UI_SNAPSHOT) { return }   # tests render the form themselves
$timer.Start()
[void]$form.ShowDialog()
$ctx.Closing = $true
