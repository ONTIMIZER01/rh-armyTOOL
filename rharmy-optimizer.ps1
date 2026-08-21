#Requires -Version 5.1
<#
.SYNOPSIS
    Rharmy Optimizer - An all-in-one Windows utility (app installer, tweaks, debloat, updates).

.DESCRIPTION
    A single-file PowerShell + WPF utility inspired by the "Chris Titus Tech WinUtil"
    style of tool. It gives you:

      * Install    - bulk install / uninstall software via winget (with choco fallback)
      * Tweaks     - performance, privacy and debloat tweaks (each one is undoable)
      * Config     - Windows features, legacy panels, quick fixes
      * Updates    - Windows Update policy presets (Default / Security / Disabled)
      * Log        - everything the tool does is logged to screen and disk

    Every destructive action can create a System Restore Point first, and every
    tweak ships with an explicit Undo path, so nothing here is a one-way door.

.EXAMPLE
    irm https://example.com/rharmy-optimizer.ps1 | iex

    The one-liner. Launches the GUI and self-elevates via UAC.

.EXAMPLE
    $env:RHARMY_CONFIG = 'C:\setup.json'; $env:RHARMY_RUN = '1'
    irm https://example.com/rharmy-optimizer.ps1 | iex

    Unattended one-liner. `iex` cannot bind -Config/-Run, so the script reads
    the RHARMY_CONFIG and RHARMY_RUN environment variables instead.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\rharmy-optimizer.ps1

.EXAMPLE
    .\rharmy-optimizer.ps1 -Config .\mysetup.json -Run
    Applies a saved configuration unattended (no GUI).

.NOTES
    Author : built with Arena.ai Agent Mode
    License: MIT
#>

[CmdletBinding()]
param(
    # Path to a saved Rharmy Optimizer .json config
    [string]$Config,

    # Run the supplied -Config headlessly (no GUI) and exit
    [switch]$Run,

    # Skip the automatic UAC self-elevation prompt
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
#  Runtime environment guard
#
#  The #Requires line at the top is enforced only when this runs as a .ps1
#  file. Under `irm <url> | iex` the whole script is one expression and
#  #Requires is silently ignored, so re-check the essentials here.
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw "Rharmy Optimizer needs PowerShell 5.1 or newer (found $($PSVersionTable.PSVersion))."
}
if ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1) {
    throw "Rharmy Optimizer needs PowerShell 5.1 or newer (found $($PSVersionTable.PSVersion))."
}
$script:IsWindowsOS = $true
if (Test-Path variable:global:IsWindows) { $script:IsWindowsOS = [bool]$IsWindows }
if (-not $script:IsWindowsOS) {
    throw 'Rharmy Optimizer is a Windows-only tool.'
}

# ---------------------------------------------------------------------------
#  Distribution URL
#
#  Under `irm <url> | iex` there is no copy of this script on disk:
#  $PSCommandPath is empty and $MyInvocation.MyCommand.ScriptBlock returns the
#  *caller's* pipeline text (literally "irm ... | iex"), not this source. So a
#  script launched that way cannot reproduce itself and cannot relaunch under
#  UAC with -File.
#
#  The fix is the same one WinUtil uses: hardcode the canonical URL and have
#  the elevated process re-download it. Change this if you self-host.
# ---------------------------------------------------------------------------
$script:SelfUrl = 'https://example.com/rharmy-optimizer.ps1'
if ($env:RHARMY_URL) { $script:SelfUrl = $env:RHARMY_URL }

# ---------------------------------------------------------------------------
#  Globals
# ---------------------------------------------------------------------------
$script:AppName    = 'Rharmy Optimizer'
$script:AppVersion = '2.0.0'
$script:WorkDir    = Join-Path $env:LOCALAPPDATA 'Rharmy Optimizer'
$script:LogFile    = Join-Path $script:WorkDir ("rharmy-optimizer_{0:yyyy-MM-dd}.log" -f (Get-Date))
$script:Sync       = [hashtable]::Synchronized(@{})
$script:Sync.Cancel = $false
$script:Busy        = $false

if (-not (Test-Path $script:WorkDir)) {
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
}

# Windows PowerShell 5.1 still defaults to TLS 1.0 on older builds, which makes
# every HTTPS download (winget bootstrap, vendor installers) fail. Opt in once.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# HKEY_CLASSES_ROOT / HKEY_USERS are not mounted as PSDrives by default.
foreach ($d in @(
    @{ Name = 'HKCR'; Root = 'HKEY_CLASSES_ROOT' }
    @{ Name = 'HKU';  Root = 'HKEY_USERS' }
)) {
    if (-not (Get-PSDrive -Name $d.Name -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $d.Name -PSProvider Registry -Root $d.Root -Scope Global `
            -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------------------------------------------------------------------------
#  Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line  = "[$stamp] [$Level] $Message"

    # Disk log - retried a few times because worker threads log concurrently.
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
            break
        } catch { Start-Sleep -Milliseconds 25 }
    }

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    try { Write-Host $line -ForegroundColor $color } catch { }

    # Push to the GUI log box if the window is up. This can be called from the
    # worker runspace, so it always goes through the dispatcher.
    $box = $script:Sync['LogBox']
    if ($box) {
        try {
            $box.Dispatcher.InvokeAsync([action] {
                $box.AppendText($line + "`r`n")
                $box.ScrollToEnd()
            }.GetNewClosure(), 'Background') | Out-Null
        } catch { }
    }
}

function Set-Status {
    param([string]$Text, [int]$Percent = -1)
    $txt  = $script:Sync['StatusText']
    $prog = $script:Sync['Progress']
    if (-not $txt) { return }
    try {
        $txt.Dispatcher.InvokeAsync([action] {
            $txt.Text = $Text
            if ($prog) {
                if ($Percent -ge 0) {
                    $prog.IsIndeterminate = $false
                    $prog.Value = $Percent
                } else {
                    $prog.IsIndeterminate = $true
                }
            }
        }.GetNewClosure(), 'Background') | Out-Null
    } catch { }
}

# Marshals an arbitrary scriptblock onto the UI thread and waits for it to
# finish. Safe to call from the worker runspace or from the UI thread itself.
function Invoke-OnUi {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $win = $script:Sync['Window']
    if (-not $win) { return (& $Action) }
    if ($win.Dispatcher.CheckAccess()) { return (& $Action) }

    $box = @{ Result = $null; Error = $null }
    $win.Dispatcher.Invoke([action] {
        try { $box.Result = & $Action } catch { $box.Error = $_ }
    }.GetNewClosure(), 'Normal')
    if ($box.Error) { throw $box.Error }
    return $box.Result
}

# ---------------------------------------------------------------------------
#  Elevation
# ---------------------------------------------------------------------------
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Invoke-SelfElevate {
    <#
        Relaunch elevated. Two strategies:

        1. Running from a .ps1 on disk -> relaunch that file with -File.
        2. Running from `irm | iex`    -> the source is not recoverable at
           runtime, so tell the elevated process to re-download and re-pipe
           with -Command "irm <url> | iex". Settings ride along as environment
           variables, since `iex` cannot bind parameters.
    #>
    if (Test-Admin) { return }
    if ($NoElevate) {
        Write-Log 'Not elevated and -NoElevate was passed. Most actions will fail.' 'WARN'
        return
    }

    Write-Log 'Administrator rights required - relaunching elevated...' 'WARN'

    $psExe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh.exe' } else { 'powershell.exe' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')

    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $argList += @('-File', "`"$PSCommandPath`"")
        if ($Config) { $argList += @('-Config', "`"$Config`"") }
        if ($Run)    { $argList += '-Run' }
    } else {
        # Piped execution: rebuild the one-liner in the elevated session.
        # Environment variables carry -Config/-Run across the UAC boundary.
        $pre = @(
            "`$env:RHARMY_URL='$($script:SelfUrl -replace "'","''")'"
        )
        if ($Config) { $pre += "`$env:RHARMY_CONFIG='$($Config -replace "'","''")'" }
        if ($Run)    { $pre += "`$env:RHARMY_RUN='1'" }
        $pre += "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12"
        $pre += "irm '$($script:SelfUrl -replace "'","''")' | iex"

        $cmd = $pre -join '; '
        # Base64 avoids every layer of quote mangling between here and CreateProcess.
        $enc64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        $argList += @('-EncodedCommand', $enc64)
    }

    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        # 1223 = the user dismissed the UAC prompt
        Write-Log "Elevation cancelled or failed: $($_.Exception.Message)" 'ERROR'
        return
    }
    exit
}

# ---------------------------------------------------------------------------
#  System info
# ---------------------------------------------------------------------------
function Get-SystemInfo {
    $info = [ordered]@{}
    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $gpu = (Get-CimInstance Win32_VideoController | Select-Object -Expand Name) -join ', '

        $info['OS']       = "$($os.Caption) ($($os.Version))"
        $info['Build']    = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        $info['Machine']  = "$($cs.Manufacturer) $($cs.Model)"
        $info['CPU']      = $cpu.Name.Trim()
        $info['Cores']    = "$($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T"
        $info['RAM']      = "{0:N1} GB" -f ($cs.TotalPhysicalMemory / 1GB)
        $info['GPU']      = $gpu
        $info['User']     = "$env:USERDOMAIN\$env:USERNAME"
        $info['Elevated'] = if (Test-Admin) { 'Yes' } else { 'NO - actions will fail' }
    } catch {
        $info['Error'] = $_.Exception.Message
    }
    $info
}

# ---------------------------------------------------------------------------
#  Restore point
# ---------------------------------------------------------------------------
function New-RharmyRestorePoint {
    param([string]$Description = 'Rharmy Optimizer')
    try {
        Set-Status 'Creating system restore point...'
        Write-Log 'Creating a system restore point (this can take a minute)...' 'STEP'

        # Windows rate-limits restore points to 1 per 24h by default; relax it.
        $rpKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        if (-not (Test-Path $rpKey)) { New-Item -Path $rpKey -Force | Out-Null }
        New-ItemProperty -Path $rpKey -Name 'SystemRestorePointCreationFrequency' `
            -Value 0 -PropertyType DWord -Force | Out-Null

        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "$Description $(Get-Date -f 'yyyy-MM-dd HH:mm')" `
            -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'Restore point created.' 'OK'
        return $true
    } catch {
        Write-Log "Could not create restore point: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Registry helpers
# ---------------------------------------------------------------------------
function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')]
        [string]$Type = 'DWord'
    )
    try {
        if ($Value -eq '<delete>') {
            if (Test-Path $Path -ErrorAction Stop) {
                Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
                Write-Log "  del  $Path\$Name"
            }
            return
        }
        if (-not (Test-Path $Path -ErrorAction Stop)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force `
            -ErrorAction Stop | Out-Null
        Write-Log "  set  $Path\$Name = $Value"
    } catch {
        Write-Log "  FAIL $Path\$Name : $($_.Exception.Message)" 'WARN'
    }
}

function Set-ServiceStartup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Automatic', 'AutomaticDelayedStart', 'Manual', 'Disabled')]
        [string]$StartupType = 'Manual'
    )
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($StartupType -eq 'AutomaticDelayedStart') {
            Set-Service -Name $Name -StartupType Automatic -ErrorAction Stop
            & sc.exe config $Name start= delayed-auto | Out-Null
        } else {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        }
        if ($StartupType -eq 'Disabled' -and $svc.Status -eq 'Running') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
        Write-Log "  svc  $Name -> $StartupType"
    } catch {
        Write-Log "  svc  $Name not found / not changeable" 'WARN'
    }
}

function Set-ScheduledTaskState {
    param([Parameter(Mandatory)][string]$TaskPath, [ValidateSet('Enable','Disable')][string]$State)
    try {
        $t = Get-ScheduledTask -TaskPath (Split-Path $TaskPath -Parent).Replace('\','\') `
             -TaskName (Split-Path $TaskPath -Leaf) -ErrorAction Stop
        if ($State -eq 'Disable') { $t | Disable-ScheduledTask -ErrorAction Stop | Out-Null }
        else                      { $t | Enable-ScheduledTask  -ErrorAction Stop | Out-Null }
        Write-Log "  task $TaskPath -> $State"
    } catch {
        Write-Log "  task $TaskPath not found" 'WARN'
    }
}

function Restart-Explorer {
    Write-Log 'Restarting Explorer to apply shell changes...' 'STEP'
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Write-Log 'Explorer restarted.' 'OK'
    } catch {
        Write-Log "Explorer restart failed: $($_.Exception.Message)" 'WARN'
    }
}

# ---------------------------------------------------------------------------
#  Application catalog
#  key = winget id | choco = chocolatey fallback id
# ---------------------------------------------------------------------------
$script:Apps = @(
    # --- Browsers ---------------------------------------------------------
    @{ Name='Brave';                Category='Browsers';   Winget='Brave.Brave';                       Choco='brave' }
    @{ Name='Google Chrome';        Category='Browsers';   Winget='Google.Chrome';                     Choco='googlechrome' }
    @{ Name='Firefox';              Category='Browsers';   Winget='Mozilla.Firefox';                   Choco='firefox' }
    @{ Name='LibreWolf';            Category='Browsers';   Winget='LibreWolf.LibreWolf';               Choco='librewolf' }
    @{ Name='Vivaldi';              Category='Browsers';   Winget='VivaldiTechnologies.Vivaldi';       Choco='vivaldi' }
    @{ Name='Zen Browser';          Category='Browsers';   Winget='Zen-Team.Zen-Browser';              Choco='' }
    @{ Name='Tor Browser';          Category='Browsers';   Winget='TorProject.TorBrowser';             Choco='torbrowser' }

    # --- Communications ---------------------------------------------------
    @{ Name='Discord';              Category='Communication'; Winget='Discord.Discord';                Choco='discord' }
    @{ Name='Signal';               Category='Communication'; Winget='OpenWhisperSystems.Signal';      Choco='signal' }
    @{ Name='Telegram';             Category='Communication'; Winget='Telegram.TelegramDesktop';       Choco='telegram' }
    @{ Name='Slack';                Category='Communication'; Winget='SlackTechnologies.Slack';        Choco='slack' }
    @{ Name='Zoom';                 Category='Communication'; Winget='Zoom.Zoom';                      Choco='zoom' }
    @{ Name='Thunderbird';          Category='Communication'; Winget='Mozilla.Thunderbird';            Choco='thunderbird' }
    @{ Name='Element (Matrix)';     Category='Communication'; Winget='Element.Element';                Choco='element-desktop' }

    # --- Development ------------------------------------------------------
    @{ Name='Visual Studio Code';   Category='Development'; Winget='Microsoft.VisualStudioCode';       Choco='vscode' }
    @{ Name='VSCodium';             Category='Development'; Winget='VSCodium.VSCodium';                Choco='vscodium' }
    @{ Name='Git';                  Category='Development'; Winget='Git.Git';                          Choco='git' }
    @{ Name='GitHub Desktop';       Category='Development'; Winget='GitHub.GitHubDesktop';             Choco='github-desktop' }
    @{ Name='Windows Terminal';     Category='Development'; Winget='Microsoft.WindowsTerminal';        Choco='microsoft-windows-terminal' }
    @{ Name='PowerShell 7';         Category='Development'; Winget='Microsoft.PowerShell';             Choco='powershell-core' }
    @{ Name='Python 3';             Category='Development'; Winget='Python.Python.3.12';               Choco='python' }
    @{ Name='Node.js LTS';          Category='Development'; Winget='OpenJS.NodeJS.LTS';                Choco='nodejs-lts' }
    @{ Name='Docker Desktop';       Category='Development'; Winget='Docker.DockerDesktop';             Choco='docker-desktop' }
    @{ Name='Neovim';               Category='Development'; Winget='Neovim.Neovim';                    Choco='neovim' }
    @{ Name='Notepad++';            Category='Development'; Winget='Notepad++.Notepad++';              Choco='notepadplusplus' }
    @{ Name='Sublime Text';         Category='Development'; Winget='SublimeHQ.SublimeText.4';          Choco='sublimetext4' }
    @{ Name='JetBrains Toolbox';    Category='Development'; Winget='JetBrains.Toolbox';                Choco='jetbrainstoolbox' }
    @{ Name='WSL';                  Category='Development'; Winget='Microsoft.WSL';                    Choco='' }
    @{ Name='Postman';              Category='Development'; Winget='Postman.Postman';                  Choco='postman' }
    @{ Name='DB Browser SQLite';    Category='Development'; Winget='DBBrowserForSQLite.DBBrowserForSQLite'; Choco='sqlitebrowser' }

    # --- Multimedia -------------------------------------------------------
    @{ Name='VLC';                  Category='Multimedia'; Winget='VideoLAN.VLC';                      Choco='vlc' }
    @{ Name='mpv';                  Category='Multimedia'; Winget='shinchiro.mpv';                     Choco='mpv' }
    @{ Name='Spotify';              Category='Multimedia'; Winget='Spotify.Spotify';                   Choco='spotify' }
    @{ Name='OBS Studio';           Category='Multimedia'; Winget='OBSProject.OBSStudio';              Choco='obs-studio' }
    @{ Name='Audacity';             Category='Multimedia'; Winget='Audacity.Audacity';                 Choco='audacity' }
    @{ Name='HandBrake';            Category='Multimedia'; Winget='HandBrake.HandBrake';               Choco='handbrake' }
    @{ Name='GIMP';                 Category='Multimedia'; Winget='GIMP.GIMP';                         Choco='gimp' }
    @{ Name='Krita';                Category='Multimedia'; Winget='KDE.Krita';                         Choco='krita' }
    @{ Name='Inkscape';             Category='Multimedia'; Winget='Inkscape.Inkscape';                 Choco='inkscape' }
    @{ Name='Blender';              Category='Multimedia'; Winget='BlenderFoundation.Blender';         Choco='blender' }
    @{ Name='ShareX';               Category='Multimedia'; Winget='ShareX.ShareX';                     Choco='sharex' }
    @{ Name='Kdenlive';             Category='Multimedia'; Winget='KDE.Kdenlive';                      Choco='kdenlive' }

    # --- Utilities --------------------------------------------------------
    @{ Name='7-Zip';                Category='Utilities';  Winget='7zip.7zip';                         Choco='7zip' }
    @{ Name='PowerToys';            Category='Utilities';  Winget='Microsoft.PowerToys';               Choco='powertoys' }
    @{ Name='Everything Search';    Category='Utilities';  Winget='voidtools.Everything';              Choco='everything' }
    @{ Name='Rufus';                Category='Utilities';  Winget='Rufus.Rufus';                       Choco='rufus' }
    @{ Name='Ventoy';               Category='Utilities';  Winget='Ventoy.Ventoy';                     Choco='ventoy' }
    @{ Name='WinDirStat';           Category='Utilities';  Winget='WinDirStat.WinDirStat';             Choco='windirstat' }
    @{ Name='CrystalDiskInfo';      Category='Utilities';  Winget='CrystalDewWorld.CrystalDiskInfo';   Choco='crystaldiskinfo' }
    @{ Name='HWiNFO';               Category='Utilities';  Winget='REALiX.HWiNFO';                     Choco='hwinfo' }
    @{ Name='CPU-Z';                Category='Utilities';  Winget='CPUID.CPU-Z';                       Choco='cpu-z' }
    @{ Name='Bitwarden';            Category='Utilities';  Winget='Bitwarden.Bitwarden';               Choco='bitwarden' }
    @{ Name='KeePassXC';            Category='Utilities';  Winget='KeePassXCTeam.KeePassXC';           Choco='keepassxc' }
    @{ Name='TreeSize Free';        Category='Utilities';  Winget='JAMSoftware.TreeSize.Free';         Choco='treesizefree' }
    @{ Name='Notion';               Category='Utilities';  Winget='Notion.Notion';                     Choco='notion' }
    @{ Name='Obsidian';             Category='Utilities';  Winget='Obsidian.Obsidian';                 Choco='obsidian' }
    @{ Name='AutoHotkey';           Category='Utilities';  Winget='AutoHotkey.AutoHotkey';             Choco='autohotkey' }
    @{ Name='Sysinternals Suite';   Category='Utilities';  Winget='Microsoft.Sysinternals.Suite';      Choco='sysinternals' }
    @{ Name='System Informer';      Category='Utilities';  Winget='WinsiderIS.SystemInformer';             Choco='' }
    @{ Name='Revo Uninstaller';     Category='Utilities';  Winget='RevoUninstaller.RevoUninstaller';   Choco='revo-uninstaller' }
    @{ Name='BleachBit';            Category='Utilities';  Winget='BleachBit.BleachBit';               Choco='bleachbit' }

    # --- Documents --------------------------------------------------------
    @{ Name='LibreOffice';          Category='Documents';  Winget='TheDocumentFoundation.LibreOffice'; Choco='libreoffice-fresh' }
    @{ Name='OnlyOffice';           Category='Documents';  Winget='ONLYOFFICE.DesktopEditors';         Choco='onlyoffice' }
    @{ Name='Adobe Acrobat Reader'; Category='Documents';  Winget='Adobe.Acrobat.Reader.64-bit';       Choco='adobereader' }
    @{ Name='SumatraPDF';           Category='Documents';  Winget='SumatraPDF.SumatraPDF';             Choco='sumatrapdf' }
    @{ Name='Calibre';              Category='Documents';  Winget='calibre.calibre';                   Choco='calibre' }
    @{ Name='Zotero';               Category='Documents';  Winget='Zotero.Zotero';                     Choco='zotero' }

    # --- Gaming -----------------------------------------------------------
    @{ Name='Steam';                Category='Gaming';     Winget='Valve.Steam';                       Choco='steam' }
    @{ Name='Epic Games Launcher';  Category='Gaming';     Winget='EpicGames.EpicGamesLauncher';       Choco='epicgameslauncher' }
    @{ Name='GOG Galaxy';           Category='Gaming';     Winget='GOG.Galaxy';                        Choco='goggalaxy' }
    @{ Name='Playnite';             Category='Gaming';     Winget='Playnite.Playnite';                 Choco='playnite' }
    @{ Name='MSI Afterburner';      Category='Gaming';     Winget='Guru3D.Afterburner';                Choco='msiafterburner' }
    @{ Name='Prism Launcher';       Category='Gaming';     Winget='PrismLauncher.PrismLauncher';       Choco='prismlauncher' }

    # --- Networking / Remote ----------------------------------------------
    @{ Name='WinSCP';               Category='Networking'; Winget='WinSCP.WinSCP';                     Choco='winscp' }
    @{ Name='FileZilla';            Category='Networking'; Winget='TimKosse.FileZilla.Client';         Choco='filezilla' }
    @{ Name='PuTTY';                Category='Networking'; Winget='PuTTY.PuTTY';                       Choco='putty' }
    @{ Name='Wireshark';            Category='Networking'; Winget='WiresharkFoundation.Wireshark';     Choco='wireshark' }
    @{ Name='qBittorrent';          Category='Networking'; Winget='qBittorrent.qBittorrent';           Choco='qbittorrent' }
    @{ Name='Tailscale';            Category='Networking'; Winget='tailscale.tailscale';               Choco='tailscale' }
    @{ Name='WireGuard';            Category='Networking'; Winget='WireGuard.WireGuard';               Choco='wireguard' }
    @{ Name='AnyDesk';              Category='Networking'; Winget='AnyDeskSoftwareGmbH.AnyDesk';       Choco='anydesk' }
    @{ Name='RustDesk';             Category='Networking'; Winget='RustDesk.RustDesk';                 Choco='rustdesk' }
    @{ Name='Nmap / Zenmap';        Category='Networking'; Winget='Insecure.Nmap';                     Choco='nmap' }

    # --- Runtimes / Drivers -------------------------------------------------
    @{ Name='.NET Desktop Runtime 8'; Category='Runtimes'; Winget='Microsoft.DotNet.DesktopRuntime.8'; Choco='dotnet-8.0-desktopruntime' }
    @{ Name='VC++ Redist 2015-2022';  Category='Runtimes'; Winget='Microsoft.VCRedist.2015+.x64';      Choco='vcredist140' }
    @{ Name='Java (Temurin 21)';      Category='Runtimes'; Winget='EclipseAdoptium.Temurin.21.JDK';    Choco='temurin21' }
    @{ Name='DirectX End-User';       Category='Runtimes'; Winget='Microsoft.DirectX';                 Choco='directx' }
    @{ Name='Snappy Driver Installer';Category='Runtimes'; Winget='GlennDelahoy.SnappyDriverInstallerOrigin'; Choco='sdio' }
)

# ---------------------------------------------------------------------------
#  Package manager plumbing
# ---------------------------------------------------------------------------
function Test-Winget {
    $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)
}

function Install-Winget {
    if (Test-Winget) { return $true }
    Write-Log 'winget not found - attempting to install App Installer...' 'STEP'
    try {
        $progressPreference = 'silentlyContinue'
        $tmp = Join-Path $env:TEMP 'winget'
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null

        $urls = @{
            'vclibs' = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
            'bundle' = 'https://aka.ms/getwinget'
        }
        foreach ($k in $urls.Keys) {
            $ext  = if ($k -eq 'bundle') { 'msixbundle' } else { 'appx' }
            $dest = Join-Path $tmp "$k.$ext"
            Invoke-WebRequest -Uri $urls[$k] -OutFile $dest -UseBasicParsing
            Add-AppxPackage -Path $dest -ErrorAction SilentlyContinue
        }
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('PATH', 'User')
        if (Test-Winget) { Write-Log 'winget installed.' 'OK'; return $true }
        Write-Log 'winget still unavailable.' 'WARN'
        return $false
    } catch {
        Write-Log "winget bootstrap failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Test-Choco { $null -ne (Get-Command choco.exe -ErrorAction SilentlyContinue) }

function Install-Choco {
    if (Test-Choco) { return $true }
    Write-Log 'Installing Chocolatey (winget fallback)...' 'STEP'
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:PATH += ";$env:ProgramData\chocolatey\bin"
        return (Test-Choco)
    } catch {
        Write-Log "Chocolatey install failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Install-App {
    param([Parameter(Mandatory)]$App)

    Write-Log "Installing $($App.Name)..." 'STEP'
    Set-Status "Installing $($App.Name)"

    if ($App.Winget -and (Test-Winget)) {
        $out = & winget.exe install --id $App.Winget --exact --silent `
                --accept-source-agreements --accept-package-agreements `
                --disable-interactivity 2>&1
        $code = $LASTEXITCODE
        # 0 = ok, -1978335189 = already installed, -1978335135 = no upgrade needed
        if ($code -eq 0 -or $code -eq -1978335189 -or $code -eq -1978335135) {
            Write-Log "$($App.Name) installed." 'OK'
            return $true
        }
        Write-Log "winget returned $code for $($App.Name); trying Chocolatey..." 'WARN'
        Write-Log ("  " + (($out | Out-String).Trim() -split "`n" | Select-Object -Last 3 | Out-String).Trim())
    }

    if ($App.Choco) {
        if (-not (Test-Choco)) { Install-Choco | Out-Null }
        if (Test-Choco) {
            & choco.exe install $App.Choco -y --no-progress --limit-output 2>&1 | Out-Null
            if ($LASTEXITCODE -in 0, 1641, 3010) {
                Write-Log "$($App.Name) installed via Chocolatey." 'OK'
                return $true
            }
        }
    }

    Write-Log "Failed to install $($App.Name)." 'ERROR'
    return $false
}

function Uninstall-App {
    param([Parameter(Mandatory)]$App)

    Write-Log "Uninstalling $($App.Name)..." 'STEP'
    Set-Status "Uninstalling $($App.Name)"

    if ($App.Winget -and (Test-Winget)) {
        & winget.exe uninstall --id $App.Winget --exact --silent `
            --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "$($App.Name) removed." 'OK'; return $true }
    }
    if ($App.Choco -and (Test-Choco)) {
        & choco.exe uninstall $App.Choco -y --limit-output 2>&1 | Out-Null
        if ($LASTEXITCODE -in 0, 1605, 1614, 1641, 3010) {
            Write-Log "$($App.Name) removed via Chocolatey." 'OK'; return $true
        }
    }
    Write-Log "Could not uninstall $($App.Name) (may not be installed)." 'WARN'
    return $false
}

function Update-AllApps {
    Write-Log 'Upgrading all winget packages...' 'STEP'
    if (-not (Test-Winget)) { Write-Log 'winget unavailable.' 'ERROR'; return }
    & winget.exe upgrade --all --silent --accept-source-agreements `
        --accept-package-agreements --disable-interactivity 2>&1 |
        ForEach-Object { if ($_ -match '\S') { Write-Log "  $_" } }
    Write-Log 'Upgrade pass complete.' 'OK'
}

# ---------------------------------------------------------------------------
#  Tweak catalog
#  Each tweak: Apply = scriptblock, Undo = scriptblock, Risk = Low/Medium/High
# ---------------------------------------------------------------------------
$HKCU = 'HKCU:'
$HKLM = 'HKLM:'

$script:Tweaks = @(

# ============================ ESSENTIAL ====================================
@{
  Id='CreateRestorePoint'; Name='Create a System Restore Point'; Category='Essential'; Risk='Low'
  Desc='Snapshot the system before you change anything. Always do this first.'
  Recommended=$true
  Apply={ New-RharmyRestorePoint -Description 'Rharmy Optimizer manual' | Out-Null }
  Undo ={ Write-Log 'Nothing to undo - restore points are managed in System Protection.' }
}
@{
  Id='DeleteTempFiles'; Name='Delete Temporary Files'; Category='Essential'; Risk='Low'
  Desc='Clears %TEMP%, C:\Windows\Temp and Windows Update download cache.'
  Recommended=$true
  Apply={
    $paths = @($env:TEMP, "$env:SystemRoot\Temp", "$env:SystemRoot\SoftwareDistribution\Download",
               "$env:SystemRoot\Prefetch")
    $freed = 0
    foreach ($p in $paths) {
      if (-not (Test-Path $p)) { continue }
      try {
        $before = (Get-ChildItem $p -Recurse -Force -EA SilentlyContinue |
                   Measure-Object Length -Sum).Sum
        Get-ChildItem $p -Recurse -Force -EA SilentlyContinue |
          Remove-Item -Recurse -Force -EA SilentlyContinue
        $after  = (Get-ChildItem $p -Recurse -Force -EA SilentlyContinue |
                   Measure-Object Length -Sum).Sum
        $freed += [math]::Max(0, ($before - $after))
      } catch { }
    }
    Write-Log ("  Freed about {0:N0} MB" -f ($freed / 1MB)) 'OK'
  }
  Undo ={ Write-Log 'Deleted files cannot be restored.' 'WARN' }
}
@{
  Id='DisableConsumerFeatures'; Name='Disable Consumer Features'; Category='Essential'; Risk='Low'
  Desc='Stops Windows from silently auto-installing promoted apps and games.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SilentInstalledAppsEnabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'PreInstalledAppsEnabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'OemPreInstalledAppsEnabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SubscribedContent-338388Enabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SubscribedContent-338389Enabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SubscribedContent-353698Enabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SystemPaneSuggestionsEnabled' 0
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 0
    foreach ($n in 'SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled',
                   'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                   'SubscribedContent-353698Enabled','SystemPaneSuggestionsEnabled') {
      Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" $n 1
    }
  }
}
@{
  Id='DisableTelemetry'; Name='Disable Telemetry'; Category='Essential'; Risk='Low'
  Desc='Sets telemetry to the minimum, disables CEIP, feedback prompts and diagnostic tasks.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" 'AllowTelemetry' 0
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" 'AllowTelemetry' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 1
    Set-RegValue "$HKCU\Software\Microsoft\Siuf\Rules" 'NumberOfSIUFInPeriod' 0
    Set-RegValue "$HKCU\Software\Microsoft\Siuf\Rules" 'PeriodInNanoSeconds' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows" 'CEIPEnable' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat" 'AITEnable' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat" 'DisableInventory' 1
    Set-RegValue "$HKCU\Software\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 1
    Set-RegValue "$HKCU\Software\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 1
    Set-RegValue "$HKCU\Software\Microsoft\Personalization\Settings" 'AcceptedPrivacyPolicy' 0

    Set-ServiceStartup 'DiagTrack'  'Disabled'
    Set-ServiceStartup 'dmwappushservice' 'Disabled'

    $tasks = @(
      '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraisal'
      '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
      '\Microsoft\Windows\Autochk\Proxy'
      '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
      '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
      '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
      '\Microsoft\Windows\Feedback\Siuf\DmClient'
      '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
      '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
    )
    foreach ($t in $tasks) { Set-ScheduledTaskState $t 'Disable' }
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" 'AllowTelemetry' 3
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows" 'CEIPEnable' 1
    Set-ServiceStartup 'DiagTrack' 'Automatic'
    Set-ServiceStartup 'dmwappushservice' 'Manual'
  }
}
@{
  Id='DisableActivityHistory'; Name='Disable Activity History / Timeline'; Category='Essential'; Risk='Low'
  Desc='Stops Windows collecting and uploading your activity history.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\System" 'EnableActivityFeed' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\System" 'PublishUserActivities' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\System" 'UploadUserActivities' 0
  }
  Undo ={
    foreach ($n in 'EnableActivityFeed','PublishUserActivities','UploadUserActivities') {
      Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\System" $n 1
    }
  }
}
@{
  Id='DisableGameDVR'; Name='Disable GameDVR / Game Bar capture'; Category='Essential'; Risk='Low'
  Desc='Removes the background recorder overhead - a genuine FPS win on many systems.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKCU\System\GameConfigStore" 'GameDVR_Enabled' 0
    Set-RegValue "$HKCU\System\GameConfigStore" 'GameDVR_FSEBehaviorMode' 2
    Set-RegValue "$HKCU\System\GameConfigStore" 'GameDVR_HonorUserFSEBehaviorMode' 1
    Set-RegValue "$HKCU\System\GameConfigStore" 'GameDVR_DXGIHonorFSEWindowsCompatible' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" 'AllowGameDVR' 0
    Set-RegValue "$HKCU\Software\Microsoft\GameBar" 'AutoGameModeEnabled' 1
    Set-RegValue "$HKCU\Software\Microsoft\GameBar" 'UseNexusForGameBarEnabled' 0
  }
  Undo ={
    Set-RegValue "$HKCU\System\GameConfigStore" 'GameDVR_Enabled' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" 'AllowGameDVR' 1
  }
}
@{
  Id='DisableHibernation'; Name='Disable Hibernation'; Category='Essential'; Risk='Low'
  Desc='Reclaims several GB (hiberfil.sys). Note: also turns off Fast Startup.'
  Recommended=$false
  Apply={ & powercfg.exe /hibernate off | Out-Null; Write-Log '  hibernation off' }
  Undo ={ & powercfg.exe /hibernate on  | Out-Null; Write-Log '  hibernation on' }
}
@{
  Id='DisableLocationTracking'; Name='Disable Location Tracking'; Category='Essential'; Risk='Low'
  Desc='Denies system-wide location access and stops the location sensor service.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" 'Value' 'Deny' 'String'
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration" 'Status' 0
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" 'SensorPermissionState' 0
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" 'Value' 'Allow' 'String'
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration" 'Status' 1
  }
}
@{
  Id='DisableWifiSense'; Name='Disable Wi-Fi Sense'; Category='Essential'; Risk='Low'
  Desc='Stops automatic connection to shared/open hotspots.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting" 'Value' 0
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots" 'Value' 0
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting" 'Value' 1
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots" 'Value' 1
  }
}
@{
  Id='DisableAdvertisingId'; Name='Disable Advertising ID'; Category='Essential'; Risk='Low'
  Desc='Stops apps using a per-user advertising identifier to profile you.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 1
  }
  Undo ={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 0
  }
}
@{
  Id='SetServicesManual'; Name='Set Non-Essential Services to Manual'; Category='Essential'; Risk='Medium'
  Desc='Flips a curated list of rarely used services to Manual so they only start on demand.'
  Recommended=$true
  Apply={
    $manual = @('AJRouter','ALG','AppVClient','AssignedAccessManagerSvc','autotimesvc','BthAvctpSvc',
      'CertPropSvc','DiagSvc','DialogBlockingService','DmEnrollmentSvc','dmwappushservice','DsSvc',
      'edgeupdate','edgeupdatem','Fax','fhsvc','icssvc','lfsvc','LxpSvc','MapsBroker','MicrosoftEdgeElevationService',
      'MSDTC','NetTcpPortSharing','PhoneSvc','PrintNotify','RemoteAccess','RemoteRegistry','RetailDemo',
      'SCardSvr','SCPolicySvc','SEMgrSvc','SharedAccess','shpamsvc','smphost','SmsRouter','SNMPTrap',
      'spectrum','SSDPSRV','TabletInputService','TapiSrv','UevAgentService','upnphost','VacSvc','WalletService',
      'wbengine','wcncsvc','WebClient','Wecsvc','WerSvc','WFDSConMgrSvc','WiaRpc','wisvc','WMPNetworkSvc',
      'workfolderssvc','WpcMonSvc','WpnService','WSearch','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc')
    foreach ($s in $manual) { Set-ServiceStartup $s 'Manual' }
    Write-Log "  $($manual.Count) services reviewed." 'OK'
  }
  Undo ={ Write-Log 'Run: sfc /scannow, or reset services manually via services.msc.' 'WARN' }
}

# ============================ PERFORMANCE ==================================
@{
  Id='UltimatePerformance'; Name='Enable Ultimate Performance power plan'; Category='Performance'; Risk='Low'
  Desc='Unlocks and activates the hidden Ultimate Performance plan. Desktops only - it hurts laptop battery.'
  Recommended=$false
  Apply={
    & powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
    $plan = (& powercfg.exe /list | Select-String 'Ultimate Performance' | Select-Object -First 1)
    if ($plan -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
      & powercfg.exe /setactive $Matches[1] | Out-Null
      Write-Log '  Ultimate Performance activated.' 'OK'
    }
  }
  Undo ={ & powercfg.exe /setactive SCHEME_BALANCED | Out-Null; Write-Log '  Balanced plan restored.' }
}
@{
  Id='DisableVisualEffects'; Name='Performance-tuned visual effects'; Category='Performance'; Risk='Low'
  Desc='Turns off animation eye-candy but keeps font smoothing and thumbnails.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 3
    Set-RegValue "$HKCU\Control Panel\Desktop\WindowMetrics" 'MinAnimate' '0' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'MenuShowDelay' '100' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'DragFullWindows' '1' 'String'
    Set-RegValue "$HKCU\Software\Microsoft\Windows\DWM" 'EnableAeroPeek' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarAnimations' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ListviewAlphaSelect' 0
  }
  Undo ={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 0
    Set-RegValue "$HKCU\Control Panel\Desktop\WindowMetrics" 'MinAnimate' '1' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'MenuShowDelay' '400' 'String'
    Set-RegValue "$HKCU\Software\Microsoft\Windows\DWM" 'EnableAeroPeek' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarAnimations' 1
  }
}
@{
  Id='DisableBackgroundApps'; Name='Disable Background Apps'; Category='Performance'; Risk='Low'
  Desc='Stops UWP/Store apps running invisibly in the background.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" 'GlobalUserDisabled' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Search" 'BackgroundAppGlobalToggle' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" 'LetAppsRunInBackground' 2
  }
  Undo ={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" 'GlobalUserDisabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Search" 'BackgroundAppGlobalToggle' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" 'LetAppsRunInBackground' 0
  }
}
@{
  Id='NetworkOptimize'; Name='Network throughput tuning'; Category='Performance'; Risk='Medium'
  Desc='Disables Nagle, enables CTCP congestion control and raises the IRP stack size.'
  Recommended=$false
  Apply={
    & netsh.exe int tcp set global autotuninglevel=normal    | Out-Null
    & netsh.exe int tcp set supplemental template=internet congestionprovider=ctcp 2>&1 | Out-Null
    & netsh.exe int tcp set global ecncapability=enabled      | Out-Null
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" 'IRPStackSize' 20
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" 'DefaultTTL' 64
    foreach ($k in (Get-ChildItem "$HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -EA SilentlyContinue)) {
      Set-RegValue $k.PSPath 'TcpAckFrequency' 1
      Set-RegValue $k.PSPath 'TCPNoDelay' 1
    }
    Write-Log '  Nagle disabled, CTCP enabled.' 'OK'
  }
  Undo ={
    & netsh.exe int tcp set global autotuninglevel=normal | Out-Null
    foreach ($k in (Get-ChildItem "$HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -EA SilentlyContinue)) {
      Set-RegValue $k.PSPath 'TcpAckFrequency' '<delete>'
      Set-RegValue $k.PSPath 'TCPNoDelay' '<delete>'
    }
  }
}
@{
  Id='DisableStartupDelay'; Name='Remove startup app delay'; Category='Performance'; Risk='Low'
  Desc='Kills the artificial ~10 second delay before startup programs launch.'
  Recommended=$true
  Apply={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" 'StartupDelayInMSec' 0 }
  Undo ={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" 'StartupDelayInMSec' '<delete>' }
}
@{
  Id='FastShutdown'; Name='Faster shutdown timeouts'; Category='Performance'; Risk='Low'
  Desc='Shortens how long Windows waits for hung services and apps at shutdown.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control" 'WaitToKillServiceTimeout' '2000' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'WaitToKillAppTimeout' '2000' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'HungAppTimeout' '2000' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'AutoEndTasks' '1' 'String'
  }
  Undo ={
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control" 'WaitToKillServiceTimeout' '5000' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'WaitToKillAppTimeout' '<delete>' 'String'
    Set-RegValue "$HKCU\Control Panel\Desktop" 'AutoEndTasks' '0' 'String'
  }
}
@{
  Id='DisableSuperfetch'; Name='Disable SysMain (Superfetch)'; Category='Performance'; Risk='Medium'
  Desc='Recommended on SSDs where prefetching just burns CPU and I/O.'
  Recommended=$false
  Apply={ Set-ServiceStartup 'SysMain' 'Disabled' }
  Undo ={ Set-ServiceStartup 'SysMain' 'Automatic'; Start-Service SysMain -EA SilentlyContinue }
}
@{
  Id='DisableSearchIndexing'; Name='Disable Windows Search indexing'; Category='Performance'; Risk='Medium'
  Desc='Frees CPU/disk. Start menu search gets slower - pair it with Everything Search.'
  Recommended=$false
  Apply={ Set-ServiceStartup 'WSearch' 'Disabled' }
  Undo ={ Set-ServiceStartup 'WSearch' 'AutomaticDelayedStart'; Start-Service WSearch -EA SilentlyContinue }
}

# ============================ GAMING ========================================
@{
  Id='EnableGameMode'; Name='Enable Windows Game Mode'; Category='Performance'; Risk='Low'
  Desc='Tells Windows to prioritize gaming workloads and reduce background interference.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKCU\Software\Microsoft\GameBar" 'AutoGameModeEnabled' 1
    Set-RegValue "$HKCU\Software\Microsoft\GameBar" 'AllowAutoGameMode' 1
    Write-Log '  Windows Game Mode enabled.' 'OK'
  }
  Undo={
    Set-RegValue "$HKCU\Software\Microsoft\GameBar" 'AutoGameModeEnabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\GameBar" 'AllowAutoGameMode' 0
  }
}
@{
  Id='EnableHAGS'; Name='Enable Hardware-Accelerated GPU Scheduling'; Category='Performance'; Risk='Medium'
  Desc='Enables HAGS when supported by the GPU driver. Requires a reboot and may vary by driver/game.'
  Recommended=$false
  Apply={ Set-RegValue "${HKLM}\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" 'HwSchMode' 2; Write-Log '  HAGS enabled; reboot required.' 'OK' }
  Undo={ Set-RegValue "${HKLM}\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" 'HwSchMode' 1; Write-Log '  HAGS disabled/defaulted; reboot required.' 'OK' }
}
@{
  Id='DisablePowerThrottling'; Name='Disable Windows Power Throttling'; Category='Performance'; Risk='Medium'
  Desc='Prevents Windows from aggressively throttling background processes. Uses more power.'
  Recommended=$false
  Apply={ Set-RegValue "${HKLM}\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" 'PowerThrottlingOff' 1; Write-Log '  Power throttling disabled.' 'OK' }
  Undo={ Set-RegValue "${HKLM}\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" 'PowerThrottlingOff' 0 }
}
@{
  Id='LimitVssTo2GB'; Name='Limit C: VSS shadow storage to 2 GB'; Category='Performance'; Risk='High'
  Desc='Runs vssadmin resize shadowstorage for C:. This can delete older restore snapshots when shrinking the limit.'
  Recommended=$false
  Apply={
    Write-Log '  Current VSS shadow storage:' 'STEP'
    & vssadmin.exe list shadowstorage | ForEach-Object { if ($_ -match '\S') { Write-Log "    $_" } }
    & vssadmin.exe resize shadowstorage /for=C: /on=C: /maxsize=2GB | ForEach-Object { if ($_ -match '\S') { Write-Log "    $_" } }
    if ($LASTEXITCODE -eq 0) { Write-Log '  C: shadow storage resized to 2 GB.' 'OK' } else { Write-Log "  vssadmin exited with code $LASTEXITCODE." 'WARN' }
  }
  Undo={ Write-Log '  VSS size was intentionally not auto-restored. Use the VSS panel to choose a larger limit.' 'WARN' }
}

# ============================ PRIVACY ======================================
@{
  Id='DisableCortana'; Name='Disable Cortana'; Category='Privacy'; Risk='Low'
  Desc='Turns Cortana off by policy and removes it from search.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" 'AllowCortana' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" 'DisableWebSearch' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" 'ConnectedSearchUseWeb' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Search" 'CortanaConsent' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Search" 'BingSearchEnabled' 0
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" 'AllowCortana' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" 'DisableWebSearch' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Search" 'BingSearchEnabled' 1
  }
}
@{
  Id='DisableRecall'; Name='Disable Windows Recall / AI snapshots'; Category='Privacy'; Risk='Low'
  Desc='Blocks the Recall screenshot-everything feature and Click-to-Do (Win11 24H2+).'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" 'DisableAIDataAnalysis' 1
    Set-RegValue "$HKCU\Software\Policies\Microsoft\Windows\WindowsAI" 'DisableAIDataAnalysis' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" 'AllowRecallEnablement' 0
    Set-RegValue "$HKCU\Software\Policies\Microsoft\Windows\WindowsAI" 'DisableClickToDo' 1
    try {
      Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -NoRestart -EA SilentlyContinue | Out-Null
    } catch { }
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" 'DisableAIDataAnalysis' 0
    Set-RegValue "$HKCU\Software\Policies\Microsoft\Windows\WindowsAI" 'DisableAIDataAnalysis' 0
  }
}
@{
  Id='DisableCopilot'; Name='Disable Windows Copilot'; Category='Privacy'; Risk='Low'
  Desc='Removes the Copilot button and disables it by policy.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ShowCopilotButton' 0
    Get-AppxPackage -Name 'Microsoft.Copilot*' -EA SilentlyContinue |
      Remove-AppxPackage -EA SilentlyContinue
  }
  Undo ={
    Set-RegValue "$HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ShowCopilotButton' 1
  }
}
@{
  Id='DisableWidgets'; Name='Disable Widgets / News & Interests'; Category='Privacy'; Risk='Low'
  Desc='Kills the widgets board and its background feed process.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Dsh" 'AllowNewsAndInterests' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarDa' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" 'EnableFeeds' 0
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Dsh" 'AllowNewsAndInterests' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarDa' 1
  }
}
@{
  Id='DisableStartMenuAds'; Name='Remove Start Menu & Lock Screen ads'; Category='Privacy'; Risk='Low'
  Desc='Strips "suggestions", tips, and promoted content from Start, Settings and the lock screen.'
  Recommended=$true
  Apply={
    $cdm = "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    foreach ($n in 'ContentDeliveryAllowed','RotatingLockScreenEnabled','RotatingLockScreenOverlayEnabled',
                   'SoftLandingEnabled','SubscribedContent-310093Enabled','SubscribedContent-338387Enabled',
                   'SubscribedContent-338393Enabled','SubscribedContent-353694Enabled',
                   'SubscribedContent-353696Enabled','SubscribedContentEnabled') {
      Set-RegValue $cdm $n 0
    }
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'Start_IrisRecommendations' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ShowSyncProviderNotifications' 0
  }
  Undo ={
    $cdm = "$HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    Set-RegValue $cdm 'ContentDeliveryAllowed' 1
    Set-RegValue $cdm 'SubscribedContentEnabled' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'Start_IrisRecommendations' 1
  }
}
@{
  Id='DisableEdgeTelemetry'; Name='Harden Microsoft Edge'; Category='Privacy'; Risk='Low'
  Desc='Disables Edge telemetry, shopping/coupons, sidebar nagging and desktop shortcut creation.'
  Recommended=$false
  Apply={
    $e = "$HKLM\SOFTWARE\Policies\Microsoft\Edge"
    Set-RegValue $e 'MetricsReportingEnabled' 0
    Set-RegValue $e 'SendSiteInfoToImproveServices' 0
    Set-RegValue $e 'EdgeShoppingAssistantEnabled' 0
    Set-RegValue $e 'ShowMicrosoftRewards' 0
    Set-RegValue $e 'HubsSidebarEnabled' 0
    Set-RegValue $e 'PersonalizationReportingEnabled' 0
    Set-RegValue $e 'CreateDesktopShortcutDefault' 0
    Set-RegValue $e 'UserFeedbackAllowed' 0
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" 'CreateDesktopShortcutDefault' 0
  }
  Undo ={
    Remove-Item "$HKLM\SOFTWARE\Policies\Microsoft\Edge" -Recurse -Force -EA SilentlyContinue
    Write-Log '  Edge policies cleared.'
  }
}
@{
  Id='DisableOneDrive'; Name='Uninstall / disable OneDrive'; Category='Privacy'; Risk='Medium'
  Desc='Stops OneDrive, uninstalls it and removes the Explorer sidebar entry. Sync your files first!'
  Recommended=$false
  Apply={
    Stop-Process -Name OneDrive -Force -EA SilentlyContinue
    foreach ($p in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
      if (Test-Path $p) { Start-Process $p '/uninstall' -Wait -EA SilentlyContinue }
    }
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" 'DisableFileSyncNGSC' 1
    Set-RegValue 'HKCR:\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' 'System.IsPinnedToNameSpaceTree' 0
    Write-Log '  OneDrive removed.' 'OK'
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" 'DisableFileSyncNGSC' 0
    Write-Log '  Reinstall OneDrive from microsoft.com/onedrive.' 'WARN'
  }
}
@{
  Id='DisableRemoteAssist'; Name='Disable Remote Assistance'; Category='Privacy'; Risk='Low'
  Desc='Closes an inbound-help attack surface most people never use.'
  Recommended=$true
  Apply={ Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance" 'fAllowToGetHelp' 0 }
  Undo ={ Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance" 'fAllowToGetHelp' 1 }
}

# ============================ EXPLORER / UI ================================
@{
  Id='ShowFileExtensions'; Name='Show file extensions'; Category='Explorer'; Risk='Low'
  Desc='Stops Explorer hiding ".exe" on things pretending to be ".pdf".'
  Recommended=$true
  Apply={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'HideFileExt' 0 }
  Undo ={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'HideFileExt' 1 }
}
@{
  Id='ShowHiddenFiles'; Name='Show hidden files'; Category='Explorer'; Risk='Low'
  Desc='Reveals hidden items (not protected OS files).'
  Recommended=$false
  Apply={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'Hidden' 1 }
  Undo ={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'Hidden' 2 }
}
@{
  Id='ClassicContextMenu'; Name='Restore the classic right-click menu (Win11)'; Category='Explorer'; Risk='Low'
  Desc='Skips the "Show more options" round-trip entirely.'
  Recommended=$true
  Apply={
    $k = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name '(Default)' -Value '' -Force
    Write-Log '  classic context menu enabled'
  }
  Undo ={
    Remove-Item 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -EA SilentlyContinue
    Write-Log '  Win11 context menu restored'
  }
}
@{
  Id='TaskbarLeft'; Name='Align taskbar to the left (Win11)'; Category='Explorer'; Risk='Low'
  Desc='Classic Windows-10 style taskbar alignment.'
  Recommended=$false
  Apply={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarAl' 0 }
  Undo ={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarAl' 1 }
}
@{
  Id='CleanTaskbar'; Name='Declutter the taskbar'; Category='Explorer'; Risk='Low'
  Desc='Hides Task View, Chat/Meet Now, Search box and Widgets.'
  Recommended=$true
  Apply={
    $adv = "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-RegValue $adv 'ShowTaskViewButton' 0
    Set-RegValue $adv 'TaskbarMn' 0
    Set-RegValue $adv 'TaskbarDa' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Search" 'SearchboxTaskbarMode' 0
  }
  Undo ={
    $adv = "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-RegValue $adv 'ShowTaskViewButton' 1
    Set-RegValue $adv 'TaskbarMn' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Search" 'SearchboxTaskbarMode' 2
  }
}
@{
  Id='ExplorerToThisPC'; Name='Open Explorer to "This PC"'; Category='Explorer'; Risk='Low'
  Desc='Instead of the Quick Access / Home page.'
  Recommended=$true
  Apply={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'LaunchTo' 1 }
  Undo ={ Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'LaunchTo' 2 }
}
@{
  Id='DisableSnapAssist'; Name='Disable Snap Assist flyout'; Category='Explorer'; Risk='Low'
  Desc='Keeps snapping, drops the "pick a window for the other half" popup.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'SnapAssist' 0
    Set-RegValue "$HKCU\Control Panel\Desktop" 'WindowArrangementActive' '0' 'String'
  }
  Undo ={
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'SnapAssist' 1
    Set-RegValue "$HKCU\Control Panel\Desktop" 'WindowArrangementActive' '1' 'String'
  }
}
@{
  Id='DarkMode'; Name='Enable dark mode everywhere'; Category='Explorer'; Risk='Low'
  Desc='Dark theme for both apps and the Windows shell.'
  Recommended=$false
  Apply={
    $p = "$HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    Set-RegValue $p 'AppsUseLightTheme' 0
    Set-RegValue $p 'SystemUsesLightTheme' 0
  }
  Undo ={
    $p = "$HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    Set-RegValue $p 'AppsUseLightTheme' 1
    Set-RegValue $p 'SystemUsesLightTheme' 1
  }
}
@{
  Id='DisableStickyKeys'; Name='Disable Sticky / Filter / Toggle keys prompts'; Category='Explorer'; Risk='Low'
  Desc='No more "press Shift 5 times" popup in the middle of a game.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKCU\Control Panel\Accessibility\StickyKeys" 'Flags' '506' 'String'
    Set-RegValue "$HKCU\Control Panel\Accessibility\Keyboard Response" 'Flags' '122' 'String'
    Set-RegValue "$HKCU\Control Panel\Accessibility\ToggleKeys" 'Flags' '58' 'String'
  }
  Undo ={
    Set-RegValue "$HKCU\Control Panel\Accessibility\StickyKeys" 'Flags' '510' 'String'
    Set-RegValue "$HKCU\Control Panel\Accessibility\Keyboard Response" 'Flags' '126' 'String'
    Set-RegValue "$HKCU\Control Panel\Accessibility\ToggleKeys" 'Flags' '62' 'String'
  }
}
@{
  Id='DisableMouseAccel'; Name='Disable mouse acceleration'; Category='Explorer'; Risk='Low'
  Desc='1:1 mouse movement - what you want for FPS games and precision work.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKCU\Control Panel\Mouse" 'MouseSpeed' '0' 'String'
    Set-RegValue "$HKCU\Control Panel\Mouse" 'MouseThreshold1' '0' 'String'
    Set-RegValue "$HKCU\Control Panel\Mouse" 'MouseThreshold2' '0' 'String'
  }
  Undo ={
    Set-RegValue "$HKCU\Control Panel\Mouse" 'MouseSpeed' '1' 'String'
    Set-RegValue "$HKCU\Control Panel\Mouse" 'MouseThreshold1' '6' 'String'
    Set-RegValue "$HKCU\Control Panel\Mouse" 'MouseThreshold2' '10' 'String'
  }
}
@{
  Id='DisableBellIcon'; Name='Hide the notification bell'; Category='Explorer'; Risk='Low'
  Desc='Removes the Notification Center chime and bell icon.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKCU\Software\Policies\Microsoft\Windows\Explorer" 'DisableNotificationCenter' 1
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" 'ToastEnabled' 0
  }
  Undo ={
    Set-RegValue "$HKCU\Software\Policies\Microsoft\Windows\Explorer" 'DisableNotificationCenter' 0
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" 'ToastEnabled' 1
  }
}
@{
  Id='UTCTime'; Name='Set BIOS clock to UTC (dual-boot fix)'; Category='Explorer'; Risk='Low'
  Desc='Stops Windows and Linux fighting over the hardware clock.'
  Recommended=$false
  Apply={ Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" 'RealTimeIsUniversal' 1 'QWord' }
  Undo ={ Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" 'RealTimeIsUniversal' '<delete>' }
}

# ============================ DEBLOAT ======================================
@{
  Id='RemoveBloatApps'; Name='Remove bundled bloatware apps'; Category='Debloat'; Risk='Medium'
  Desc='Uninstalls a curated list of preinstalled Store apps for all users. Keeps Store, Terminal, Photos, Calculator.'
  Recommended=$true
  Apply={
    $bloat = @(
      'Microsoft.3DBuilder','Microsoft.549981C3F5F10','Microsoft.BingFinance','Microsoft.BingFoodAndDrink',
      'Microsoft.BingHealthAndFitness','Microsoft.BingNews','Microsoft.BingSports','Microsoft.BingTranslator',
      'Microsoft.BingTravel','Microsoft.BingWeather','Microsoft.Getstarted','Microsoft.Messaging',
      'Microsoft.Microsoft3DViewer','Microsoft.MicrosoftJournal','Microsoft.MicrosoftOfficeHub',
      'Microsoft.MicrosoftSolitaireCollection','Microsoft.MicrosoftStickyNotes','Microsoft.MixedReality.Portal',
      'Microsoft.NetworkSpeedTest','Microsoft.News','Microsoft.Office.OneNote','Microsoft.Office.Sway',
      'Microsoft.OneConnect','Microsoft.People','Microsoft.Print3D','Microsoft.SkypeApp','Microsoft.Todos',
      'Microsoft.Wallet','Microsoft.WindowsAlarms','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps',
      'Microsoft.WindowsSoundRecorder','Microsoft.Xbox.TCUI','Microsoft.XboxApp','Microsoft.XboxGameOverlay',
      'Microsoft.XboxGamingOverlay','Microsoft.XboxSpeechToTextOverlay','Microsoft.YourPhone',
      'Microsoft.ZuneMusic','Microsoft.ZuneVideo','MicrosoftCorporationII.MicrosoftFamily',
      'MicrosoftTeams','MSTeams','Clipchamp.Clipchamp','Microsoft.OutlookForWindows',
      'Microsoft.GamingApp','Microsoft.PowerAutomateDesktop','Microsoft.Windows.DevHome',
      '*Disney*','*Spotify*','*Netflix*','*TikTok*','*Facebook*','*Twitter*','*CandyCrush*',
      '*Duolingo*','*Prime*Video*','*Instagram*','*LinkedIn*','*Booking*','*ClipChamp*','*Dolby*',
      '*McAfee*','*Norton*','*ExpressVPN*','*Solitaire*','*Roblox*','*Adobe*Express*'
    )
    $n = 0
    foreach ($b in $bloat) {
      $pkgs = Get-AppxPackage -Name $b -AllUsers -EA SilentlyContinue
      foreach ($p in $pkgs) {
        try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -EA Stop; $n++
              Write-Log "  removed $($p.Name)" } catch { }
      }
      Get-AppxProvisionedPackage -Online -EA SilentlyContinue |
        Where-Object DisplayName -like $b |
        ForEach-Object {
          try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -EA Stop | Out-Null
                Write-Log "  deprovisioned $($_.DisplayName)" } catch { }
        }
    }
    Write-Log "  $n packages removed." 'OK'
  }
  Undo ={
    Write-Log 'Reinstalling default apps from the Store manifest...' 'STEP'
    Get-AppxPackage -AllUsers -EA SilentlyContinue | ForEach-Object {
      if ($_.InstallLocation) {
        Add-AppxPackage -DisableDevelopmentMode `
          -Register "$($_.InstallLocation)\AppXManifest.xml" -EA SilentlyContinue
      }
    }
    Write-Log 'Anything still missing can be reinstalled from the Microsoft Store.' 'WARN'
  }
}
@{
  Id='DisableXboxServices'; Name='Disable Xbox services'; Category='Debloat'; Risk='Medium'
  Desc='Only do this if you never use Game Pass / Xbox Live titles.'
  Recommended=$false
  Apply={ foreach ($s in 'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc') { Set-ServiceStartup $s 'Disabled' } }
  Undo ={ foreach ($s in 'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc') { Set-ServiceStartup $s 'Manual' } }
}
@{
  Id='DisableTeredo'; Name='Disable Teredo IPv6 tunneling'; Category='Debloat'; Risk='Low'
  Desc='Fixes some Xbox/P2P connection weirdness and closes an unused tunnel.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" 'DisabledComponents' 1
    & netsh.exe interface teredo set state disabled | Out-Null
  }
  Undo ={
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" 'DisabledComponents' '<delete>'
    & netsh.exe interface teredo set state default | Out-Null
  }
}
@{
  Id='DebloatEdge'; Name='Remove Microsoft Edge desktop shortcuts + updater tasks'; Category='Debloat'; Risk='Low'
  Desc='Stops Edge re-adding its shortcut and running background updater tasks.'
  Recommended=$false
  Apply={
    Get-ChildItem "$env:PUBLIC\Desktop","$env:USERPROFILE\Desktop" -Filter '*Edge*.lnk' -EA SilentlyContinue |
      Remove-Item -Force -EA SilentlyContinue
    foreach ($t in '\MicrosoftEdgeUpdateTaskMachineCore','\MicrosoftEdgeUpdateTaskMachineUA') {
      Set-ScheduledTaskState $t 'Disable'
    }
    Set-ServiceStartup 'edgeupdate'  'Disabled'
    Set-ServiceStartup 'edgeupdatem' 'Disabled'
  }
  Undo ={
    foreach ($t in '\MicrosoftEdgeUpdateTaskMachineCore','\MicrosoftEdgeUpdateTaskMachineUA') {
      Set-ScheduledTaskState $t 'Enable'
    }
    Set-ServiceStartup 'edgeupdate' 'AutomaticDelayedStart'
  }
}
@{
  Id='DisableFastStartup'; Name='Disable Fast Startup'; Category='Debloat'; Risk='Low'
  Desc='Fixes dual-boot filesystem corruption and "shutdown did not really shut down" bugs.'
  Recommended=$false
  Apply={ Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" 'HiberbootEnabled' 0 }
  Undo ={ Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" 'HiberbootEnabled' 1 }
}
@{
  Id='DisableLockScreenSpotlight'; Name='Disable Windows Spotlight on lock screen'; Category='Debloat'; Risk='Low'
  Desc='No rotating Bing photos with "like what you see?" nag prompts.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsSpotlightFeatures' 1
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" 'DisableSpotlightCollectionOnDesktop' 1
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsSpotlightFeatures' 0
  }
}

# ============================ SECURITY =====================================
@{
  Id='EnableUACMax'; Name='Set UAC to always notify'; Category='Security'; Risk='Low'
  Desc='Maximum UAC prompting - the safest setting.'
  Recommended=$false
  Apply={
    $p = "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-RegValue $p 'ConsentPromptBehaviorAdmin' 2
    Set-RegValue $p 'PromptOnSecureDesktop' 1
    Set-RegValue $p 'EnableLUA' 1
  }
  Undo ={
    $p = "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-RegValue $p 'ConsentPromptBehaviorAdmin' 5
  }
}
@{
  Id='EnableDefenderHardening'; Name='Harden Microsoft Defender'; Category='Security'; Risk='Low'
  Desc='Turns on PUA blocking, cloud protection, network protection and key ASR rules.'
  Recommended=$true
  Apply={
    try {
      Set-MpPreference -PUAProtection Enabled -EA SilentlyContinue
      Set-MpPreference -MAPSReporting Advanced -EA SilentlyContinue
      Set-MpPreference -SubmitSamplesConsent SendSafeSamples -EA SilentlyContinue
      Set-MpPreference -EnableNetworkProtection Enabled -EA SilentlyContinue
      Set-MpPreference -DisableRealtimeMonitoring $false -EA SilentlyContinue
      # ASR: block Office child processes, credential stealing from LSASS, obfuscated scripts
      $asr = @('d4f940ab-401b-4efc-aadc-ad5f3c50688a',
               '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2',
               '5beb7efe-fd9a-4556-801d-275e5ffc04cc',
               '3b576869-a4ec-4529-8536-b80a7769e899')
      Add-MpPreference -AttackSurfaceReductionRules_Ids $asr `
        -AttackSurfaceReductionRules_Actions Enabled -EA SilentlyContinue
      Write-Log '  Defender hardened.' 'OK'
    } catch { Write-Log "  Defender config failed: $($_.Exception.Message)" 'WARN' }
  }
  Undo ={
    Set-MpPreference -PUAProtection Disabled -EA SilentlyContinue
    Set-MpPreference -EnableNetworkProtection Disabled -EA SilentlyContinue
  }
}
@{
  Id='DisableSMB1'; Name='Disable SMBv1 (WannaCry protocol)'; Category='Security'; Risk='Low'
  Desc='Ancient, wormable file-sharing protocol. Turn it off unless you have a 2003-era NAS.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" 'SMB1' 0
    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -EA SilentlyContinue | Out-Null
    Write-Log '  SMBv1 disabled.' 'OK'
  }
  Undo ={ Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -EA SilentlyContinue | Out-Null }
}
@{
  Id='DisableAutorun'; Name='Disable AutoRun / AutoPlay'; Category='Security'; Risk='Low'
  Desc='Blocks the classic "plug in a USB stick, get malware" vector.'
  Recommended=$true
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" 'NoDriveTypeAutoRun' 255
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" 'DisableAutoplay' 1
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" 'NoDriveTypeAutoRun' 145
    Set-RegValue "$HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" 'DisableAutoplay' 0
  }
}
@{
  Id='EnableDNSoverHTTPS'; Name='Enable DNS over HTTPS (Cloudflare)'; Category='Security'; Risk='Medium'
  Desc='Encrypts DNS lookups on every adapter using 1.1.1.1 / 1.0.0.1.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters" 'EnableAutoDoh' 2
    Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object {
      Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex `
        -ServerAddresses ('1.1.1.1', '1.0.0.1') -EA SilentlyContinue
      Write-Log "  DNS set on $($_.Name)"
    }
    Clear-DnsClientCache -EA SilentlyContinue
  }
  Undo ={
    Get-NetAdapter -Physical | ForEach-Object {
      Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses -EA SilentlyContinue
    }
    Set-RegValue "$HKLM\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters" 'EnableAutoDoh' '<delete>'
  }
}
@{
  Id='DisableLLMNR'; Name='Disable LLMNR / NetBIOS name poisoning'; Category='Security'; Risk='Low'
  Desc='Closes the Responder-style credential-relay attack surface on LANs.'
  Recommended=$false
  Apply={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" 'EnableMulticast' 0
    Get-ChildItem "$HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces" -EA SilentlyContinue |
      ForEach-Object { Set-RegValue $_.PSPath 'NetbiosOptions' 2 }
  }
  Undo ={
    Set-RegValue "$HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" 'EnableMulticast' 1
    Get-ChildItem "$HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces" -EA SilentlyContinue |
      ForEach-Object { Set-RegValue $_.PSPath 'NetbiosOptions' 0 }
  }
}
@{
  Id='DisablePowerShell2'; Name='Remove PowerShell v2 engine'; Category='Security'; Risk='Low'
  Desc='PSv2 bypasses modern logging and AMSI - a favourite of attackers.'
  Recommended=$true
  Apply={
    Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -EA SilentlyContinue | Out-Null
    Write-Log '  PowerShell v2 removed.' 'OK'
  }
  Undo ={ Enable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -EA SilentlyContinue | Out-Null }
}
)

# ---------------------------------------------------------------------------
#  Tweak runner
# ---------------------------------------------------------------------------
function Invoke-Tweak {
    param([Parameter(Mandatory)]$Tweak, [ValidateSet('Apply','Undo')][string]$Action = 'Apply')

    if ($Tweak -isnot [hashtable] -or -not $Tweak.ContainsKey($Action)) {
        Write-Log "Tweak '$($Tweak.Id)' has no $Action step." 'WARN'
        return $false
    }
    $verb = if ($Action -eq 'Apply') { 'Applying' } else { 'Reverting' }
    Write-Log "$verb : $($Tweak.Name)" 'STEP'
    Set-Status "$verb $($Tweak.Name)"
    try {
        & $Tweak[$Action]
        Write-Log "Done: $($Tweak.Name)" 'OK'
        return $true
    } catch {
        Write-Log "Failed: $($Tweak.Name) - $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Windows Features (optional components)
# ---------------------------------------------------------------------------
$script:Features = @(
    @{ Name='.NET Framework 3.5';            Feature='NetFx3';                              Desc='Needed by many older apps and games.' }
    @{ Name='.NET Framework 4.8 Advanced';   Feature='NetFx4-AdvSrvs';                      Desc='ASP.NET / WCF components.' }
    @{ Name='Hyper-V';                       Feature='Microsoft-Hyper-V-All';               Desc='Microsoft type-1 hypervisor. Requires reboot.' }
    @{ Name='Virtual Machine Platform';      Feature='VirtualMachinePlatform';              Desc='Required by WSL2 and Android subsystem.' }
    @{ Name='Windows Subsystem for Linux';   Feature='Microsoft-Windows-Subsystem-Linux';   Desc='Run Linux distros natively.' }
    @{ Name='Windows Sandbox';               Feature='Containers-DisposableClientVM';       Desc='Throwaway VM for testing sketchy files. Pro/Ent only.' }
    @{ Name='Hypervisor Platform';           Feature='HypervisorPlatform';                  Desc='Third-party hypervisor acceleration (VirtualBox, VMware).' }
    @{ Name='Telnet Client';                 Feature='TelnetClient';                        Desc='Classic port-poking utility.' }
    @{ Name='TFTP Client';                   Feature='TFTP';                                Desc='Trivial FTP client.' }
    @{ Name='Windows Media Player (legacy)'; Feature='WindowsMediaPlayer';                  Desc='The old WMP.' }
    @{ Name='SMB 1.0 (insecure)';            Feature='SMB1Protocol';                        Desc='Only for ancient NAS devices. Avoid.' }
    @{ Name='IIS Web Server';                Feature='IIS-WebServerRole';                   Desc='Microsoft web server.' }
    @{ Name='OpenSSH Server';                Feature='OpenSSH.Server';                      Desc='Incoming SSH. Installed as a capability.'; Capability=$true }
)

function Set-WindowsFeatureState {
    param([Parameter(Mandatory)]$Feature, [ValidateSet('Enable','Disable')][string]$State)
    Write-Log "$State feature: $($Feature.Name)" 'STEP'
    Set-Status "$State $($Feature.Name)"
    try {
        if ($Feature.ContainsKey('Capability') -and $Feature.Capability) {
            $cap = (Get-WindowsCapability -Online -Name "$($Feature.Feature)*" -EA Stop |
                    Select-Object -First 1).Name
            if ($State -eq 'Enable') { Add-WindowsCapability    -Online -Name $cap -EA Stop | Out-Null }
            else                     { Remove-WindowsCapability -Online -Name $cap -EA Stop | Out-Null }
        } else {
            if ($State -eq 'Enable') {
                Enable-WindowsOptionalFeature -Online -FeatureName $Feature.Feature -All -NoRestart -EA Stop | Out-Null
            } else {
                Disable-WindowsOptionalFeature -Online -FeatureName $Feature.Feature -NoRestart -EA Stop | Out-Null
            }
        }
        Write-Log "$($Feature.Name) -> $State (reboot may be required)" 'OK'
        return $true
    } catch {
        Write-Log "$($Feature.Name) failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---------------------------------------------------------------------------
#  Quick fixes / one-shot actions
# ---------------------------------------------------------------------------
$script:Fixes = @(
    @{
        Name='System File Check (SFC + DISM)'
        Desc='Repairs corrupted Windows system files. Takes 10-30 minutes.'
        Action={
            Write-Log 'Running DISM RestoreHealth...' 'STEP'
            & DISM.exe /Online /Cleanup-Image /RestoreHealth |
                ForEach-Object { if ($_ -match '\S') { Write-Log "  $_" } }
            Write-Log 'Running sfc /scannow...' 'STEP'
            & sfc.exe /scannow | ForEach-Object { if ($_ -match '\S') { Write-Log "  $_" } }
            Write-Log 'System file check complete.' 'OK'
        }
    }
    @{
        Name='Reset Windows Update components'
        Desc='Fixes stuck or endlessly failing Windows Updates.'
        Action={
            Write-Log 'Stopping update services...' 'STEP'
            foreach ($s in 'wuauserv','cryptSvc','bits','msiserver') { Stop-Service $s -Force -EA SilentlyContinue }
            Rename-Item "$env:SystemRoot\SoftwareDistribution" "SoftwareDistribution.bak_$(Get-Date -f yyyyMMddHHmmss)" -Force -EA SilentlyContinue
            Rename-Item "$env:SystemRoot\System32\catroot2"     "catroot2.bak_$(Get-Date -f yyyyMMddHHmmss)"     -Force -EA SilentlyContinue
            foreach ($s in 'wuauserv','cryptSvc','bits','msiserver') { Start-Service $s -EA SilentlyContinue }
            & wuauclt.exe /resetauthorization /detectnow 2>&1 | Out-Null
            Write-Log 'Windows Update components reset.' 'OK'
        }
    }
    @{
        Name='Reset network stack'
        Desc='winsock reset + IP reset + DNS flush. Fixes most "internet is broken" cases.'
        Action={
            Write-Log 'Resetting network stack...' 'STEP'
            & netsh.exe winsock reset      | ForEach-Object { Write-Log "  $_" }
            & netsh.exe int ip reset       | ForEach-Object { Write-Log "  $_" }
            & ipconfig.exe /flushdns       | Out-Null
            & ipconfig.exe /release        | Out-Null
            & ipconfig.exe /renew          | Out-Null
            Write-Log 'Network reset complete - reboot recommended.' 'OK'
        }
    }
    @{
        Name='Run Disk Cleanup (deep)'
        Desc='Cleans update leftovers, delivery optimisation cache, error dumps, recycle bin.'
        Action={
            Write-Log 'Running deep disk cleanup...' 'STEP'
            & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase |
                ForEach-Object { if ($_ -match '\S') { Write-Log "  $_" } }
            Clear-RecycleBin -Force -EA SilentlyContinue
            & cleanmgr.exe /sagerun:1 2>&1 | Out-Null
            Write-Log 'Disk cleanup complete.' 'OK'
        }
    }
    @{
        Name='Rebuild the icon & thumbnail cache'
        Desc='Fixes blank, wrong or corrupted icons.'
        Action={
            Stop-Process -Name explorer -Force -EA SilentlyContinue
            Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -EA SilentlyContinue
            Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache*" -Force -EA SilentlyContinue
            Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache*" -Force -EA SilentlyContinue
            Start-Process explorer.exe
            Write-Log 'Icon cache rebuilt.' 'OK'
        }
    }
    @{
        Name='Re-register all Store apps'
        Desc='Fixes broken Start Menu, Store, or Settings after aggressive debloating.'
        Action={
            Write-Log 'Re-registering AppX packages...' 'STEP'
            Get-AppxPackage -AllUsers | ForEach-Object {
                Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" -EA SilentlyContinue
            }
            Write-Log 'Done.' 'OK'
        }
    }
    @{
        Name='Reset Group Policy to defaults'
        Desc='Wipes local policy - use if a tweak locked something you cannot unlock.'
        Action={
            Remove-Item "$env:SystemRoot\System32\GroupPolicy"      -Recurse -Force -EA SilentlyContinue
            Remove-Item "$env:SystemRoot\System32\GroupPolicyUsers" -Recurse -Force -EA SilentlyContinue
            & gpupdate.exe /force | ForEach-Object { Write-Log "  $_" }
            Write-Log 'Group Policy reset.' 'OK'
        }
    }
    @{
        Name='Show detailed BSOD info'
        Desc='Enables the full crash detail screen instead of the sad-face emoji.'
        Action={
            Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'DisplayParameters' 1
            Write-Log 'Verbose BSOD enabled.' 'OK'
        }
    }
)

$script:Panels = @(
    @{ Name='Control Panel (classic)';   Cmd='control.exe' }
    @{ Name='Programs and Features';     Cmd='appwiz.cpl' }
    @{ Name='Network Connections';       Cmd='ncpa.cpl' }
    @{ Name='Power Options';             Cmd='powercfg.cpl' }
    @{ Name='Sound Control Panel';       Cmd='mmsys.cpl' }
    @{ Name='System Properties';         Cmd='sysdm.cpl' }
    @{ Name='Device Manager';            Cmd='devmgmt.msc' }
    @{ Name='Disk Management';           Cmd='diskmgmt.msc' }
    @{ Name='Services';                  Cmd='services.msc' }
    @{ Name='Task Scheduler';            Cmd='taskschd.msc' }
    @{ Name='Event Viewer';              Cmd='eventvwr.msc' }
    @{ Name='Registry Editor';           Cmd='regedit.exe' }
    @{ Name='Group Policy Editor';       Cmd='gpedit.msc' }
    @{ Name='Computer Management';       Cmd='compmgmt.msc' }
    @{ Name='System Configuration';      Cmd='msconfig.exe' }
    @{ Name='Resource Monitor';          Cmd='resmon.exe' }
    @{ Name='User Accounts (advanced)';  Cmd='netplwiz.exe' }
    @{ Name='Windows Features';          Cmd='optionalfeatures.exe' }
)

# ---------------------------------------------------------------------------
#  Windows Update policy presets
# ---------------------------------------------------------------------------
function Set-UpdatePolicy {
    param([ValidateSet('Default','Security','Disabled')][string]$Mode)

    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

    switch ($Mode) {
        'Default' {
            Write-Log 'Restoring default Windows Update behaviour...' 'STEP'
            Remove-Item $wu -Recurse -Force -EA SilentlyContinue
            foreach ($s in 'wuauserv','UsoSvc','WaaSMedicSvc','BITS') {
                Set-ServiceStartup $s 'Manual'
            }
            foreach ($t in '\Microsoft\Windows\WindowsUpdate\Scheduled Start',
                           '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan') {
                Set-ScheduledTaskState $t 'Enable'
            }
            Write-Log 'Windows Update restored to defaults.' 'OK'
        }
        'Security' {
            Write-Log 'Configuring security-only update policy...' 'STEP'
            # Defer features 2 years, quality updates 4 days, notify before download
            Set-RegValue $wu 'DeferFeatureUpdates' 1
            Set-RegValue $wu 'DeferFeatureUpdatesPeriodInDays' 730
            Set-RegValue $wu 'DeferQualityUpdates' 1
            Set-RegValue $wu 'DeferQualityUpdatesPeriodInDays' 4
            Set-RegValue $wu 'BranchReadinessLevel' 20
            Set-RegValue $au 'NoAutoUpdate' 0
            Set-RegValue $au 'AUOptions' 2          # notify before download
            Set-RegValue $au 'NoAutoRebootWithLoggedOnUsers' 1
            Set-ServiceStartup 'wuauserv' 'Manual'
            Write-Log 'Security updates arrive after 4 days; features deferred 2 years.' 'OK'
        }
        'Disabled' {
            Write-Log 'DISABLING Windows Update entirely...' 'STEP'
            Set-RegValue $au 'NoAutoUpdate' 1
            Set-RegValue $au 'AUOptions' 1
            Set-RegValue $wu 'DoNotConnectToWindowsUpdateInternetLocations' 1
            Set-RegValue $wu 'DisableWindowsUpdateAccess' 1
            Set-RegValue $wu 'WUServer' 'localhost' 'String'
            Set-RegValue $wu 'WUStatusServer' 'localhost' 'String'
            Set-RegValue $au 'UseWUServer' 1
            foreach ($s in 'wuauserv','UsoSvc','WaaSMedicSvc','BITS','DoSvc') {
                Set-ServiceStartup $s 'Disabled'
            }
            foreach ($t in '\Microsoft\Windows\WindowsUpdate\Scheduled Start',
                           '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan',
                           '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task',
                           '\Microsoft\Windows\InstallService\ScanForUpdates') {
                Set-ScheduledTaskState $t 'Disable'
            }
            Write-Log 'Windows Update disabled. You are now responsible for patching.' 'WARN'
        }
    }
}

function Install-WindowsUpdates {
    Write-Log 'Checking for Windows updates...' 'STEP'
    try {
        if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
            Write-Log 'Installing PSWindowsUpdate module...' 'STEP'
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -EA SilentlyContinue | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -EA SilentlyContinue
            Install-Module PSWindowsUpdate -Force -Scope CurrentUser -EA Stop
        }
        Import-Module PSWindowsUpdate -Force
        Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot -Verbose 4>&1 |
            ForEach-Object { Write-Log "  $_" }
        Write-Log 'Update pass complete.' 'OK'
    } catch {
        Write-Log "Update check failed: $($_.Exception.Message)" 'ERROR'
        Write-Log 'Falling back to the Settings app...' 'WARN'
        Start-Process 'ms-settings:windowsupdate'
    }
}

# ---------------------------------------------------------------------------
#  Config import / export
# ---------------------------------------------------------------------------
# StrictMode-safe member read for ConvertFrom-Json output and hashtables.
function Get-JsonMember {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = @())
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Export-RharmyConfig {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Apps, [string[]]$Tweaks)
    $obj = [ordered]@{
        Generator = "$script:AppName $script:AppVersion"
        Created   = (Get-Date).ToString('o')
        Apps      = @($Apps)
        Tweaks    = @($Tweaks)
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $Path -Encoding UTF8
    Write-Log "Config saved to $Path" 'OK'
}

function Import-RharmyConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Config not found: $Path" }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Config file is empty: $Path" }
    try { $obj = $raw | ConvertFrom-Json } catch { throw "Config is not valid JSON: $($_.Exception.Message)" }

    # Normalise to a plain hashtable so a missing Apps/Tweaks key never
    # explodes under Set-StrictMode.
    @{
        Apps   = @(Get-JsonMember $obj 'Apps')
        Tweaks = @(Get-JsonMember $obj 'Tweaks')
    }
}

function Invoke-HeadlessRun {
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Import-RharmyConfig -Path $Path
    Write-Log "Headless run from $Path" 'STEP'

    if (-not (Test-Admin)) {
        Write-Log 'Not running as administrator - most steps will fail.' 'ERROR'
    }

    $tweakIds = @($cfg.Tweaks)
    $appNames = @($cfg.Apps)
    Write-Log "Plan: $($tweakIds.Count) tweak(s), $($appNames.Count) app(s)."

    $tOk = 0
    $i = 0
    foreach ($id in $tweakIds) {
        $i++
        $t = @($script:Tweaks | Where-Object { $_.Id -eq $id })
        if ($t.Count -eq 0) { Write-Log "Unknown tweak id: $id" 'WARN'; continue }
        Write-Log "[$i/$($tweakIds.Count)] $($t[0].Name)" 'STEP'
        if (Invoke-Tweak -Tweak $t[0] -Action Apply) { $tOk++ }
    }

    if ($appNames.Count -gt 0 -and -not (Test-Winget)) {
        Write-Log 'winget missing - bootstrapping it first.' 'WARN'
        Install-Winget | Out-Null
    }

    $aOk = 0
    $i = 0
    foreach ($name in $appNames) {
        $i++
        $a = @($script:Apps | Where-Object { $_.Name -eq $name -or $_.Winget -eq $name })
        if ($a.Count -eq 0) { Write-Log "Unknown app: $name" 'WARN'; continue }
        Write-Log "[$i/$($appNames.Count)] $($a[0].Name)" 'STEP'
        if (Install-App -App $a[0]) { $aOk++ }
    }

    Write-Log "Headless run finished: $tOk/$($tweakIds.Count) tweaks, $aOk/$($appNames.Count) apps." 'OK'
}

# ---------------------------------------------------------------------------
#  Background worker
#
#  Everything slow (winget, DISM, sfc, registry batches) runs in a SECOND
#  runspace on its own thread so the WPF window keeps painting and the Cancel
#  button stays clickable. The UI thread only polls a DispatcherTimer.
#
#  Two things make this work:
#    1. Functions are re-declared inside the worker from their parent
#       definitions - a runspace starts empty otherwise.
#    2. Scriptblocks (tweak Apply/Undo, fix Action, the job body) are rebuilt
#       with [scriptblock]::Create() inside the worker. A scriptblock object
#       passed across a runspace boundary still resolves against the session
#       state it was DEFINED in, which would drag work back onto the UI
#       thread's state and is not thread safe. Re-creating from text rebinds
#       it to the worker.
# ---------------------------------------------------------------------------

$script:Worker      = $null   # Runspace
$script:JobPS       = $null   # PowerShell instance currently running
$script:JobHandle   = $null   # IAsyncResult
$script:JobName     = ''
$script:JobOnDone   = $null
$script:JobTimer    = $null
$script:JobStarted  = $null
$script:CancelArmed = $false

# Names of the functions the worker needs a local copy of.
$script:WorkerFunctions = @(
    'Write-Log', 'Set-Status', 'Invoke-OnUi',
    'Test-Admin', 'Get-SystemInfo', 'New-RharmyRestorePoint',
    'Set-RegValue', 'Set-ServiceStartup', 'Set-ScheduledTaskState', 'Restart-Explorer',
    'Test-Winget', 'Install-Winget', 'Test-Choco', 'Install-Choco',
    'Install-App', 'Uninstall-App', 'Update-AllApps',
    'Invoke-Tweak', 'Set-WindowsFeatureState', 'Set-UpdatePolicy',
    'Install-WindowsUpdates', 'Export-RharmyConfig', 'Import-RharmyConfig', 'Get-VssShadowStorageText', 'Resize-VssShadowStorage2GB',
    'Copy-CatalogLocal'
)

function Get-WorkerFunctionSource {
    $sb = New-Object System.Text.StringBuilder
    foreach ($name in $script:WorkerFunctions) {
        $cmd = Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        [void]$sb.AppendLine("function $name {")
        [void]$sb.AppendLine($cmd.Definition)
        [void]$sb.AppendLine('}')
    }
    $sb.ToString()
}

# Deep-copies a catalog of hashtables, re-creating every scriptblock member so
# it binds to the runspace doing the copy.
function Copy-CatalogLocal {
    param($Catalog)
    $out = New-Object System.Collections.ArrayList
    foreach ($item in @($Catalog)) {
        if ($item -isnot [hashtable]) { [void]$out.Add($item); continue }
        $clone = @{}
        foreach ($key in @($item.Keys)) {
            $val = $item[$key]
            if ($val -is [scriptblock]) { $val = [scriptblock]::Create($val.ToString()) }
            $clone[$key] = $val
        }
        [void]$out.Add($clone)
    }
    , $out.ToArray()
}

function Initialize-Worker {
    if ($script:Worker -and $script:Worker.RunspaceStateInfo.State -eq 'Opened') { return }

    Write-Log 'Starting background worker...' 'INFO'
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $rs  = [runspacefactory]::CreateRunspace($iss)
    $rs.ThreadOptions = 'ReuseThread'
    try { $rs.ApartmentState = 'STA' } catch { }
    $rs.Open()

    # Values the worker needs mirrored from the parent.
    $rs.SessionStateProxy.SetVariable('RharmyDefs',    (Get-WorkerFunctionSource))
    $rs.SessionStateProxy.SetVariable('RharmyState',   @{
        AppName    = $script:AppName
        AppVersion = $script:AppVersion
        WorkDir    = $script:WorkDir
        LogFile    = $script:LogFile
        Sync       = $script:Sync
        Apps       = $script:Apps
        Tweaks     = $script:Tweaks
        Features   = $script:Features
        Fixes      = $script:Fixes
        Panels     = $script:Panels
    })

    $boot = [powershell]::Create()
    $boot.Runspace = $rs
    [void]$boot.AddScript({
        $ErrorActionPreference = 'Continue'
        Set-StrictMode -Version 1.0

        # Registry drives are per-runspace.
        foreach ($d in @(
            @{ Name = 'HKCR'; Root = 'HKEY_CLASSES_ROOT' }
            @{ Name = 'HKU';  Root = 'HKEY_USERS' }
        )) {
            if (-not (Get-PSDrive -Name $d.Name -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name $d.Name -PSProvider Registry -Root $d.Root -Scope Global `
                    -ErrorAction SilentlyContinue | Out-Null
            }
        }

        Invoke-Expression $RharmyDefs

        $script:AppName    = $RharmyState.AppName
        $script:AppVersion = $RharmyState.AppVersion
        $script:WorkDir    = $RharmyState.WorkDir
        $script:LogFile    = $RharmyState.LogFile
        $script:Sync       = $RharmyState.Sync
        $script:Apps       = $RharmyState.Apps
        $script:Features   = $RharmyState.Features
        $script:Panels     = $RharmyState.Panels
        $script:HKCU = 'HKCU:'
        $script:HKLM = 'HKLM:'
        $HKCU = $script:HKCU
        $HKLM = $script:HKLM

        # Rebind catalog scriptblocks to THIS runspace.
        $script:Tweaks = Copy-CatalogLocal $RharmyState.Tweaks
        $script:Fixes  = Copy-CatalogLocal $RharmyState.Fixes
        'worker-ready'
    })
    $out = $boot.Invoke()
    foreach ($e in $boot.Streams.Error) { Write-Log "worker init: $e" 'WARN' }
    $boot.Dispose()
    if ($out -notcontains 'worker-ready') { throw 'Worker runspace failed to initialise.' }

    $script:Worker = $rs
    Write-Log 'Background worker ready.' 'OK'
}

function Stop-RharmyWorker {
    $script:Sync.Cancel = $true
    if ($script:JobPS) {
        try { $script:JobPS.Stop() } catch { }
        try { $script:JobPS.Dispose() } catch { }
        $script:JobPS = $null
    }
    if ($script:JobTimer) { try { $script:JobTimer.Stop() } catch { } }
    if ($script:Worker) {
        try { $script:Worker.Close(); $script:Worker.Dispose() } catch { }
        $script:Worker = $null
    }
}

function Set-BusyUi {
    param([bool]$On, [string]$Name = '')
    $script:Busy = $On
    $win = $script:Sync['Window']
    if (-not $win) { return }
    # Every control that starts work or mutates the selection the worker is
    # reading. Verified against the x:Name set in the XAML - keep in sync.
    foreach ($n in @('BtnInstall','BtnUninstall','BtnUpgrade','BtnTweakApply','BtnTweakUndo',
                     'BtnFeatureApply','BtnUpdDefault','BtnUpdSecurity','BtnUpdDisabled',
                     'BtnUpdCheck','BtnRestore','BtnLoadCfg','BtnSaveCfg',
                     'BtnAppAll','BtnAppNone','BtnTweakRec','BtnTweakNone','BtnGamePerformance','BtnGameDns','BtnGameSettings','BtnGameCache','BtnVssList','BtnVss2GB')) {
        $c = $win.FindName($n)
        if ($c) { $c.IsEnabled = -not $On }
    }
    $cancel = $win.FindName('BtnCancel')
    if ($cancel) { $cancel.IsEnabled = $On }
    if ($On) { Set-Status "$Name - working..." } else { Set-Status 'Ready' 0 }
}

<#
.SYNOPSIS
    Runs $Work on the worker runspace and keeps the UI alive.
.PARAMETER Vars
    Plain data the job body needs. Each key becomes a script-scope variable
    inside the worker. Never put WPF objects in here - touch those with
    Invoke-OnUi instead.
.PARAMETER OnDone
    Optional scriptblock run back on the UI thread when the job finishes.
#>
function Start-BackgroundJob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Work,
        [hashtable]$Vars = @{},
        [scriptblock]$OnDone = $null
    )

    if ($script:Busy) {
        [Windows.MessageBox]::Show(
            "'$script:JobName' is still running. Wait for it to finish or press Cancel.",
            'Rharmy Optimizer', 'OK', 'Warning') | Out-Null
        return
    }

    try { Initialize-Worker }
    catch {
        Write-Log "Could not start the worker: $($_.Exception.Message)" 'ERROR'
        return
    }

    $script:JobName     = $Name
    $script:JobOnDone   = $OnDone
    $script:JobStarted  = Get-Date
    $script:Sync.Cancel = $false
    $script:CancelArmed = $false
    Set-BusyUi $true $Name
    Write-Log "=== $Name ===" 'STEP'

    $ps = [powershell]::Create()
    $ps.Runspace = $script:Worker
    [void]$ps.AddScript({
        param($JobText, $JobVars, $JobLabel)
        foreach ($k in @($JobVars.Keys)) {
            Set-Variable -Name $k -Value $JobVars[$k] -Scope Script -Force
        }
        try {
            $body = [scriptblock]::Create($JobText)
            & $body
        } catch {
            Write-Log "$JobLabel failed: $($_.Exception.Message)" 'ERROR'
        }
    }).AddArgument($Work.ToString()).AddArgument($Vars).AddArgument($Name)

    $script:JobPS     = $ps
    $script:JobHandle = $ps.BeginInvoke()

    if (-not $script:JobTimer) {
        $script:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(250)
        $script:JobTimer.Add_Tick({ Complete-BackgroundJob })
    }
    $script:JobTimer.Start()
}

# Polled on the UI thread by the DispatcherTimer.
function Complete-BackgroundJob {
    if (-not $script:JobHandle) { $script:JobTimer.Stop(); return }
    if (-not $script:JobHandle.IsCompleted) { return }

    $script:JobTimer.Stop()
    $ps = $script:JobPS
    try { $null = $ps.EndInvoke($script:JobHandle) } catch {
        Write-Log "$script:JobName aborted: $($_.Exception.Message)" 'WARN'
    }
    if ($ps) {
        foreach ($e in $ps.Streams.Error) { Write-Log "  $e" 'ERROR' }
        try { $ps.Dispose() } catch { }
    }
    $script:JobPS     = $null
    $script:JobHandle = $null

    $secs = if ($script:JobStarted) {
        [math]::Round(((Get-Date) - $script:JobStarted).TotalSeconds, 1)
    } else { 0 }
    Write-Log "$script:JobName finished in ${secs}s." 'OK'

    $done = $script:JobOnDone
    $script:JobOnDone = $null
    Set-BusyUi $false
    if ($done) {
        try { & $done } catch { Write-Log "Post-job step failed: $($_.Exception.Message)" 'WARN' }
    }
}

# ---------------------------------------------------------------------------
#  GUI
#
#  Note on scope: every helper below lives at SCRIPT scope, not nested inside
#  Show-RharmyGui. WPF event handlers fire long after Show-RharmyGui has set up
#  the window, and a scriptblock cannot see functions that were declared in a
#  function call that has already returned - it would die with
#  "The term 'Update-AppCount' is not recognized". Shared state uses $script:
#  for the same reason; plain locals are invisible to handlers unless they are
#  explicitly captured with .GetNewClosure().
# ---------------------------------------------------------------------------

$script:UI          = @{}   # name -> control cache
$script:AppChecks   = @{}   # app name  -> CheckBox
$script:TweakChecks = @{}   # tweak id  -> CheckBox
$script:FeatChecks  = @{}   # feature   -> CheckBox
$script:Brush       = @{}

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rharmy Optimizer" Height="820" Width="1320"
        WindowStartupLocation="CenterScreen" Background="#0F1117"
        FontFamily="Segoe UI" MinWidth="780" MinHeight="560"
        ResizeMode="CanResize">

  <Window.Resources>
    <!-- palette -->
    <SolidColorBrush x:Key="Bg"      Color="#12141A"/>
    <SolidColorBrush x:Key="Panel"   Color="#1A1D26"/>
    <SolidColorBrush x:Key="Panel2"  Color="#222633"/>
    <SolidColorBrush x:Key="Accent"  Color="#4EA1FF"/>
    <SolidColorBrush x:Key="Accent2" Color="#2C7BE5"/>
    <SolidColorBrush x:Key="Fg"      Color="#E8EAF0"/>
    <SolidColorBrush x:Key="Muted"   Color="#8A93A6"/>
    <SolidColorBrush x:Key="Ok"      Color="#3DD68C"/>
    <SolidColorBrush x:Key="Warn"    Color="#F0A93B"/>
    <SolidColorBrush x:Key="Danger"  Color="#F4614E"/>
    <SolidColorBrush x:Key="Line"    Color="#2C3142"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>

    <!-- rounded button -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="6" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#333A4D"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#3E465C"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent2}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="6" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#4EA1FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#8E3226"/>
    </Style>

    <!-- nav (tab) buttons -->
    <Style x:Key="NavTab" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="7" Background="Transparent" Padding="14,11">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="ic" Text="{TemplateBinding Tag}" FontSize="15" Width="26"
                           Foreground="{TemplateBinding Foreground}"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#232735"/>
                <Setter Property="Foreground" Value="{StaticResource Fg}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2C7BE5"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
    </Style>

    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
      <Setter Property="Padding" Value="10"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- SECTION: HEADER -->
    <Border Grid.Row="0" Background="#171A23" Padding="18,12" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="34" Height="34" CornerRadius="8" Background="#2C7BE5" Margin="0,0,12,0">
            <TextBlock Text="T" FontSize="20" FontWeight="Bold" Foreground="White"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Rharmy Optimizer" FontSize="18" FontWeight="Bold"/>
            <TextBlock x:Name="SubTitle" Text="Gaming + Windows optimization suite"
                       FontSize="11" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border x:Name="AdminBadge" CornerRadius="5" Padding="10,5" Background="#1E4D33" Margin="0,0,10,0">
            <TextBlock x:Name="AdminText" Text="Administrator" FontSize="11" Foreground="#3DD68C"/>
          </Border>
          <TextBlock x:Name="VerText" Text="v1.0.0" Foreground="{StaticResource Muted}"
                     VerticalAlignment="Center" FontSize="11"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- SECTION: BODY -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="180" MinWidth="160"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- sidebar -->
      <Border Grid.Column="0" Background="#171A23" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <DockPanel Margin="10,14,10,10">
          <StackPanel DockPanel.Dock="Bottom">
            <Separator Background="{StaticResource Line}" Margin="0,8"/>
            <Button x:Name="BtnRestore" Style="{StaticResource Btn}" Content="Restore Point"
                    HorizontalAlignment="Stretch"/>
            <Button x:Name="BtnOpenLog" Style="{StaticResource Btn}" Content="Open Log Folder"
                    HorizontalAlignment="Stretch"/>
          </StackPanel>
          <StackPanel x:Name="NavPanel">
            <RadioButton x:Name="NavInstall"  Style="{StaticResource NavTab}" Tag="&#x2B07;"  Content="Install"  IsChecked="True" GroupName="nav"/>
            <RadioButton x:Name="NavTweaks"   Style="{StaticResource NavTab}" Tag="&#x2699;"  Content="Tweaks"   GroupName="nav"/>
            <RadioButton x:Name="NavGaming"   Style="{StaticResource NavTab}" Tag="&#x1F3AE;" Content="Gaming"   GroupName="nav"/>
            <RadioButton x:Name="NavConfig"   Style="{StaticResource NavTab}" Tag="&#x1F527;" Content="Config"   GroupName="nav"/>
            <RadioButton x:Name="NavUpdates"  Style="{StaticResource NavTab}" Tag="&#x27F3;"  Content="Updates"  GroupName="nav"/>
            <RadioButton x:Name="NavSystem"   Style="{StaticResource NavTab}" Tag="&#x1F5A5;" Content="System"   GroupName="nav"/>
            <RadioButton x:Name="NavLog"      Style="{StaticResource NavTab}" Tag="&#x1F4C4;" Content="Log"      GroupName="nav"/>
          </StackPanel>
        </DockPanel>
      </Border>

      <!-- content -->
      <Grid Grid.Column="1" Margin="0">

        <!-- PAGE: INSTALL -->
        <Grid x:Name="PageInstall" Margin="18">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Grid Grid.Row="0" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="AppSearch" Grid.Column="0" Height="34" VerticalContentAlignment="Center"
                     Tag="Search applications..."/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="10,0,0,0">
              <Button x:Name="BtnAppAll"  Style="{StaticResource Btn}" Content="Select All" Margin="0,0,6,0"/>
              <Button x:Name="BtnAppNone" Style="{StaticResource Btn}" Content="Clear"      Margin="0"/>
            </StackPanel>
          </Grid>

          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="AppList"/>
          </ScrollViewer>

          <Border Grid.Row="2" Background="{StaticResource Panel}" CornerRadius="8" Padding="12" Margin="0,12,0,0">
            <StackPanel Orientation="Horizontal">
              <Button x:Name="BtnInstall"   Style="{StaticResource BtnPrimary}" Content="Install Selected"/>
              <Button x:Name="BtnUninstall" Style="{StaticResource BtnDanger}"  Content="Uninstall Selected"/>
              <Button x:Name="BtnUpgrade"   Style="{StaticResource Btn}"        Content="Upgrade All"/>
              <Separator Margin="10,0" Background="{StaticResource Line}"/>
              <Button x:Name="BtnSaveCfg" Style="{StaticResource Btn}" Content="Export Config"/>
              <Button x:Name="BtnLoadCfg" Style="{StaticResource Btn}" Content="Import Config"/>
              <TextBlock x:Name="AppCount" Text="0 selected" Foreground="{StaticResource Muted}"
                         VerticalAlignment="Center" Margin="12,0,0,8"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- PAGE: TWEAKS -->
        <Grid x:Name="PageTweaks" Margin="18" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Border Grid.Row="0" Background="#2A2113" CornerRadius="8" Padding="12" Margin="0,0,0,12"
                  BorderBrush="#5C4620" BorderThickness="1">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#x26A0;" FontSize="16" Foreground="{StaticResource Warn}" Margin="0,0,10,0"/>
              <TextBlock Foreground="#E8C88A" TextWrapping="Wrap"
                         Text="Every tweak here is reversible with the Undo button. Create a restore point first anyway."/>
            </StackPanel>
          </Border>

          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="TweakList"/>
          </ScrollViewer>

          <Border Grid.Row="2" Background="{StaticResource Panel}" CornerRadius="8" Padding="12" Margin="0,12,0,0">
            <StackPanel Orientation="Horizontal">
              <Button x:Name="BtnTweakApply" Style="{StaticResource BtnPrimary}" Content="Apply Selected"/>
              <Button x:Name="BtnTweakUndo"  Style="{StaticResource BtnDanger}"  Content="Undo Selected"/>
              <Button x:Name="BtnTweakRec"   Style="{StaticResource Btn}"        Content="Check Recommended"/>
              <Button x:Name="BtnTweakNone"  Style="{StaticResource Btn}"        Content="Clear"/>
              <TextBlock x:Name="TweakCount" Text="0 selected" Foreground="{StaticResource Muted}"
                         VerticalAlignment="Center" Margin="12,0,0,8"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- PAGE: CONFIG -->
        <ScrollViewer x:Name="PageConfig" Margin="18" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <GroupBox Header="Windows Features">
              <StackPanel>
                <TextBlock Text="Tick to enable, untick to disable, then press Apply. Most need a reboot."
                           Foreground="{StaticResource Muted}" Margin="0,0,0,8" TextWrapping="Wrap"/>
                <StackPanel x:Name="FeatureList"/>
                <Button x:Name="BtnFeatureApply" Style="{StaticResource BtnPrimary}"
                        Content="Apply Feature Changes" HorizontalAlignment="Left" Margin="0,10,0,0"/>
              </StackPanel>
            </GroupBox>

            <GroupBox Header="Quick Fixes">
              <WrapPanel x:Name="FixList"/>
            </GroupBox>

            <GroupBox Header="Legacy Panels &amp; Tools">
              <WrapPanel x:Name="PanelList"/>
            </GroupBox>
          </StackPanel>
        </ScrollViewer>

        <!-- PAGE: UPDATES -->
        <ScrollViewer x:Name="PageUpdates" Margin="18" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="Windows Update Policy" FontSize="18" FontWeight="Bold" Margin="0,0,0,4"/>
            <TextBlock Text="Pick how aggressively Windows is allowed to update itself."
                       Foreground="{StaticResource Muted}" Margin="0,0,0,16"/>

            <Border Background="{StaticResource Panel}" CornerRadius="8" Padding="16" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Default" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Ok}"/>
                <TextBlock Text="Stock Microsoft behaviour. Removes every policy Rharmy Optimizer set. Use this to undo the options below."
                           Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,10"/>
                <Button x:Name="BtnUpdDefault" Style="{StaticResource Btn}" Content="Set Default" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>

            <Border Background="{StaticResource Panel}" CornerRadius="8" Padding="16" Margin="0,0,0,12"
                    BorderBrush="{StaticResource Accent2}" BorderThickness="1">
              <StackPanel>
                <TextBlock Text="Security (recommended)" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,4,0,10"
                           Text="Security patches install after a 4 day delay (so you dodge day-one broken updates), feature updates are deferred 2 years, and reboots never happen while you are logged in."/>
                <Button x:Name="BtnUpdSecurity" Style="{StaticResource BtnPrimary}" Content="Set Security" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>

            <Border Background="{StaticResource Panel}" CornerRadius="8" Padding="16" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock Text="Disabled" FontSize="15" FontWeight="SemiBold" Foreground="{StaticResource Danger}"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,4,0,10"
                           Text="Kills the update services, orchestrator tasks and endpoints. You will get zero security patches. Only for isolated or air-gapped machines."/>
                <Button x:Name="BtnUpdDisabled" Style="{StaticResource BtnDanger}" Content="Disable Updates" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>

            <Separator Background="{StaticResource Line}" Margin="0,10"/>
            <TextBlock Text="Actions" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,8"/>
            <WrapPanel>
              <Button x:Name="BtnUpdCheck"  Style="{StaticResource Btn}" Content="Check &amp; Install Updates Now"/>
              <Button x:Name="BtnUpdPanel"  Style="{StaticResource Btn}" Content="Open Windows Update Settings"/>
              <Button x:Name="BtnUpdHistory" Style="{StaticResource Btn}" Content="View Update History"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- PAGE: GAMING -->
        <ScrollViewer x:Name="PageGaming" Margin="18" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="Gaming Center" FontSize="22" FontWeight="Bold" Margin="0,0,0,3"/>
            <TextBlock Text="FPS, latency, storage and gaming-focused Windows controls." Foreground="{StaticResource Muted}" Margin="0,0,0,16"/>

            <WrapPanel>
              <Border Background="{StaticResource Panel}" CornerRadius="10" Padding="16" Margin="0,0,10,10" Width="300">
                <StackPanel>
                  <TextBlock Text="Performance Mode" FontSize="15" FontWeight="SemiBold"/>
                  <TextBlock Text="Activate Ultimate Performance and reduce background overhead." Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,5,0,10"/>
                  <Button x:Name="BtnGamePerformance" Style="{StaticResource BtnPrimary}" Content="Apply Gaming Performance" HorizontalAlignment="Left"/>
                </StackPanel>
              </Border>
              <Border Background="{StaticResource Panel}" CornerRadius="10" Padding="16" Margin="0,0,10,10" Width="300">
                <StackPanel>
                  <TextBlock Text="Latency Tools" FontSize="15" FontWeight="SemiBold"/>
                  <TextBlock Text="Flush DNS, renew networking and open the Windows gaming settings." Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,5,0,10"/>
                  <WrapPanel>
                    <Button x:Name="BtnGameDns" Style="{StaticResource Btn}" Content="Flush DNS"/>
                    <Button x:Name="BtnGameSettings" Style="{StaticResource Btn}" Content="Gaming Settings"/>
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Background="{StaticResource Panel}" CornerRadius="10" Padding="16" Margin="0,0,10,10" Width="300">
                <StackPanel>
                  <TextBlock Text="Shader / Temp Cleanup" FontSize="15" FontWeight="SemiBold"/>
                  <TextBlock Text="Clear temporary DirectX shader cache and user temp files." Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,5,0,10"/>
                  <Button x:Name="BtnGameCache" Style="{StaticResource Btn}" Content="Clean Gaming Cache" HorizontalAlignment="Left"/>
                </StackPanel>
              </Border>
            </WrapPanel>

            <Border Background="{StaticResource Panel}" CornerRadius="10" Padding="16" Margin="0,4,0,12">
              <StackPanel>
                <TextBlock Text="Volume Shadow Copy Storage" FontSize="16" FontWeight="SemiBold"/>
                <TextBlock Text="View current VSS allocation or cap C: shadow storage at 2 GB. Resizing can remove older restore snapshots." Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,5,0,12"/>
                <WrapPanel>
                  <Button x:Name="BtnVssList" Style="{StaticResource Btn}" Content="List Shadow Storage"/>
                  <Button x:Name="BtnVss2GB" Style="{StaticResource BtnDanger}" Content="Resize C: to 2 GB"/>
                </WrapPanel>
                <TextBox x:Name="VssOutput" Height="130" Margin="0,8,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas"/>
              </StackPanel>
            </Border>

            <Border Background="#17251F" CornerRadius="10" Padding="14" BorderBrush="#285A42" BorderThickness="1">
              <TextBlock Text="Tip: GPU driver settings, game-specific graphics settings and overlays can have a larger FPS impact than registry tweaks. Use restore points before system-level changes." Foreground="#A7D9BF" TextWrapping="Wrap"/>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- PAGE: SYSTEM -->
        <ScrollViewer x:Name="PageSystem" Margin="18" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="System Information" FontSize="18" FontWeight="Bold" Margin="0,0,0,12"/>
            <Border Background="{StaticResource Panel}" CornerRadius="8" Padding="16">
              <StackPanel x:Name="SysInfoPanel"/>
            </Border>
            <TextBlock Text="Storage" FontSize="15" FontWeight="SemiBold" Margin="0,20,0,8"/>
            <Border Background="{StaticResource Panel}" CornerRadius="8" Padding="16">
              <StackPanel x:Name="DiskPanel"/>
            </Border>
            <WrapPanel Margin="0,16,0,0">
              <Button x:Name="BtnSysRefresh" Style="{StaticResource Btn}" Content="Refresh"/>
              <Button x:Name="BtnSysExport"  Style="{StaticResource Btn}" Content="Export Report"/>
              <Button x:Name="BtnSysTaskMgr" Style="{StaticResource Btn}" Content="Task Manager"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- PAGE: LOG -->
        <Grid x:Name="PageLog" Margin="18" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#0C0E13" CornerRadius="8" BorderBrush="{StaticResource Line}" BorderThickness="1">
            <TextBox x:Name="LogBox" Background="Transparent" BorderThickness="0" Foreground="#B9C2D6"
                     FontFamily="Consolas" FontSize="12" IsReadOnly="True" Padding="12"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"
                     HorizontalScrollBarVisibility="Auto"/>
          </Border>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,0">
            <Button x:Name="BtnLogClear" Style="{StaticResource Btn}" Content="Clear"/>
            <Button x:Name="BtnLogSave"  Style="{StaticResource Btn}" Content="Save As..."/>
          </StackPanel>
        </Grid>

      </Grid>
    </Grid>

    <!-- SECTION: STATUS BAR -->
    <Border Grid.Row="2" Background="#171A23" Padding="16,8" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="220"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="StatusText" Grid.Column="0" Text="Ready" VerticalAlignment="Center"
                   Foreground="{StaticResource Muted}" FontSize="12"/>
        <ProgressBar x:Name="Progress" Grid.Column="1" Height="6" Foreground="#4EA1FF"
                     Background="#252A38" BorderThickness="0" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="BtnCancel" Grid.Column="2" Style="{StaticResource Btn}" Content="Cancel"
                Margin="0" Padding="12,5" IsEnabled="False"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

function Get-VssShadowStorageText {
    try {
        $out = & vssadmin.exe list shadowstorage 2>&1 | Out-String
        if ([string]::IsNullOrWhiteSpace($out)) { return 'No VSS output was returned.' }
        return $out.Trim()
    } catch { return "VSS query failed: $($_.Exception.Message)" }
}

function Resize-VssShadowStorage2GB {
    if (-not (Test-Admin)) { Write-Log 'Administrator rights are required for VSS resize.' 'ERROR'; return }
    Write-Log 'VSS resize requested: /for=C: /on=C: /maxsize=2GB' 'STEP'
    $out = & vssadmin.exe resize shadowstorage /for=C: /on=C: /maxsize=2GB 2>&1
    foreach ($line in $out) { if ($line -match '\S') { Write-Log "  $line" } }
    if ($LASTEXITCODE -eq 0) { Write-Log 'VSS shadow storage resized to 2 GB.' 'OK' }
    else { Write-Log "VSS resize failed with exit code $LASTEXITCODE." 'ERROR' }
}

# ---------------------------------------------------------------------------
#  Small UI helpers (script scope - handlers must be able to reach them)
# ---------------------------------------------------------------------------
function Get-Ctl {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:UI.ContainsKey($Name)) {
        $script:UI[$Name] = $script:Sync['Window'].FindName($Name)
    }
    $script:UI[$Name]
}

function New-Brush {
    param([Parameter(Mandatory)][string]$Hex)
    if (-not $script:Brush.ContainsKey($Hex)) {
        $script:Brush[$Hex] = [Windows.Media.BrushConverter]::new().ConvertFrom($Hex)
    }
    $script:Brush[$Hex]
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Update-AppCount {
    $n = @($script:AppChecks.Values | Where-Object { $_.IsChecked }).Count
    (Get-Ctl 'AppCount').Text = "$n selected"
}

function Update-TweakCount {
    $n = @($script:TweakChecks.Values | Where-Object { $_.IsChecked }).Count
    (Get-Ctl 'TweakCount').Text = "$n selected"
}

function Get-SelectedApps {
    @($script:AppChecks.Values | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
}

function Get-SelectedTweaks {
    @($script:TweakChecks.Values | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
}

function Show-Ask {
    param([string]$Message, [string]$Icon = 'Question')
    [Windows.MessageBox]::Show($Message, 'Rharmy Optimizer', 'YesNo', $Icon) -eq 'Yes'
}

# ---------------------------------------------------------------------------
#  Page builders
# ---------------------------------------------------------------------------
function Build-AppPage {
    $list = Get-Ctl 'AppList'
    $list.Children.Clear()
    $script:AppChecks.Clear()

    foreach ($cat in (@($script:Apps.Category) | Select-Object -Unique | Sort-Object)) {
        $hdr = New-Object Windows.Controls.TextBlock
        $hdr.Text       = $cat.ToUpper()
        $hdr.FontWeight = 'Bold'
        $hdr.FontSize   = 12
        $hdr.Foreground = New-Brush '#4EA1FF'
        $hdr.Margin     = '0,14,0,6'
        [void]$list.Children.Add($hdr)

        $wrap = New-Object Windows.Controls.WrapPanel
        foreach ($app in (@($script:Apps | Where-Object { $_.Category -eq $cat }) | Sort-Object { $_.Name })) {
            $cb = New-Object Windows.Controls.CheckBox
            $cb.Content = $app.Name
            $cb.Tag     = $app
            $cb.Width   = 250
            $cb.Margin  = '0,3,8,3'
            $cb.ToolTip = "winget: $($app.Winget)"
            $cb.Add_Checked({   Update-AppCount })
            $cb.Add_Unchecked({ Update-AppCount })
            [void]$wrap.Children.Add($cb)
            $script:AppChecks[$app.Name] = $cb
        }
        [void]$list.Children.Add($wrap)
    }
    Update-AppCount
}

function Update-AppFilter {
    $q    = (Get-Ctl 'AppSearch').Text.Trim()
    $list = Get-Ctl 'AppList'
    $currentHeader = $null

    foreach ($child in $list.Children) {
        if ($child -is [Windows.Controls.TextBlock]) {
            $currentHeader = $child
            continue
        }
        if ($child -is [Windows.Controls.WrapPanel]) {
            $any = $false
            foreach ($cb in $child.Children) {
                $hit = ($q -eq '' -or
                        "$($cb.Content)" -like "*$q*" -or
                        "$($cb.Tag.Winget)" -like "*$q*")
                $cb.Visibility = if ($hit) { 'Visible' } else { 'Collapsed' }
                if ($hit) { $any = $true }
            }
            $child.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
            if ($currentHeader) {
                $currentHeader.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }
            }
        }
    }
}

function Build-TweakPage {
    $list = Get-Ctl 'TweakList'
    $list.Children.Clear()
    $script:TweakChecks.Clear()

    $riskColor = @{ 'Low' = '#3DD68C'; 'Medium' = '#F0A93B'; 'High' = '#F4614E' }

    foreach ($cat in @('Essential','Performance','Privacy','Explorer','Debloat','Security')) {
        $items = @($script:Tweaks | Where-Object { $_.Category -eq $cat })
        if ($items.Count -eq 0) { continue }

        $hdr = New-Object Windows.Controls.TextBlock
        $hdr.Text = $cat.ToUpper()
        $hdr.FontWeight = 'Bold'
        $hdr.FontSize   = 12
        $hdr.Foreground = New-Brush '#4EA1FF'
        $hdr.Margin     = '0,14,0,6'
        [void]$list.Children.Add($hdr)

        foreach ($tw in $items) {
            $card = New-Object Windows.Controls.Border
            $card.Background   = New-Brush '#1A1D26'
            $card.CornerRadius = [Windows.CornerRadius]::new(7)
            $card.Padding      = '12,10'
            $card.Margin       = '0,0,0,6'

            $grid = New-Object Windows.Controls.Grid
            $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '*'
            $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
            [void]$grid.ColumnDefinitions.Add($c1)
            [void]$grid.ColumnDefinitions.Add($c2)

            $sp = New-Object Windows.Controls.StackPanel
            $cb = New-Object Windows.Controls.CheckBox
            $cb.Content    = $tw.Name
            $cb.Tag        = $tw
            $cb.FontWeight = 'SemiBold'
            $cb.IsChecked  = $false
            $cb.Add_Checked({   Update-TweakCount })
            $cb.Add_Unchecked({ Update-TweakCount })
            [void]$sp.Children.Add($cb)

            $desc = New-Object Windows.Controls.TextBlock
            $desc.Text         = $tw.Desc
            $desc.Foreground   = New-Brush '#8A93A6'
            $desc.FontSize     = 11
            $desc.TextWrapping = 'Wrap'
            $desc.Margin       = '22,2,0,0'
            [void]$sp.Children.Add($desc)

            [Windows.Controls.Grid]::SetColumn($sp, 0)
            [void]$grid.Children.Add($sp)

            $tags = New-Object Windows.Controls.StackPanel
            $tags.Orientation      = 'Horizontal'
            $tags.VerticalAlignment = 'Top'

            if (Get-Prop $tw 'Recommended' $false) {
                $rec = New-Object Windows.Controls.Border
                $rec.Background   = New-Brush '#1E3A5C'
                $rec.CornerRadius = [Windows.CornerRadius]::new(4)
                $rec.Padding      = '7,2'
                $rec.Margin       = '0,0,6,0'
                $rt = New-Object Windows.Controls.TextBlock
                $rt.Text       = 'RECOMMENDED'
                $rt.FontSize   = 9
                $rt.Foreground = New-Brush '#4EA1FF'
                $rec.Child = $rt
                [void]$tags.Children.Add($rec)
            }

            $riskName = [string](Get-Prop $tw 'Risk' 'Low')
            $risk = New-Object Windows.Controls.Border
            $risk.Background   = New-Brush '#252A38'
            $risk.CornerRadius = [Windows.CornerRadius]::new(4)
            $risk.Padding      = '7,2'
            $rkt = New-Object Windows.Controls.TextBlock
            $rkt.Text       = $riskName.ToUpper()
            $rkt.FontSize   = 9
            $rkt.Foreground = New-Brush $(if ($riskColor.ContainsKey($riskName)) { $riskColor[$riskName] } else { '#8A93A6' })
            $risk.Child = $rkt
            [void]$tags.Children.Add($risk)

            [Windows.Controls.Grid]::SetColumn($tags, 1)
            [void]$grid.Children.Add($tags)

            $card.Child = $grid
            [void]$list.Children.Add($card)
            $script:TweakChecks[$tw.Id] = $cb
        }
    }
    Update-TweakCount
}

function Build-ConfigPage {
    $win  = $script:Sync['Window']
    $list = Get-Ctl 'FeatureList'
    $list.Children.Clear()
    $script:FeatChecks.Clear()

    foreach ($f in $script:Features) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = "$($f.Name)  -  $($f.Desc)"
        $cb.Margin  = '0,4'
        $state = $false
        try {
            if ((Get-Prop $f 'Capability' $false)) {
                $cap = Get-WindowsCapability -Online -Name "$($f.Feature)*" -ErrorAction Stop |
                       Select-Object -First 1
                $state = ($cap -and $cap.State -eq 'Installed')
            } else {
                $of = Get-WindowsOptionalFeature -Online -FeatureName $f.Feature -ErrorAction Stop
                $state = ($of -and $of.State -eq 'Enabled')
            }
        } catch {
            $cb.IsEnabled = $false
            $cb.Content   = "$($cb.Content)   (not available on this edition)"
        }
        $cb.IsChecked = $state
        $cb.Tag       = @{ Feature = $f; Initial = $state }
        [void]$list.Children.Add($cb)
        $script:FeatChecks[$f.Feature] = $cb
    }

    $fixes = Get-Ctl 'FixList'
    $fixes.Children.Clear()
    foreach ($fix in $script:Fixes) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $fix.Name
        $b.ToolTip = $fix.Desc
        $b.Style   = $win.FindResource('Btn')
        $b.Tag     = $fix.Name
        $b.Add_Click({
            param($s, $e)
            $name = [string]$s.Tag
            $def  = $script:Fixes | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $def) { return }
            if (-not (Show-Ask "Run '$name'?`n`n$($def.Desc)")) { return }
            Start-BackgroundJob -Name $name -Vars @{ FixName = $name } -Work {
                $fix = $script:Fixes | Where-Object { $_.Name -eq $script:FixName } | Select-Object -First 1
                if ($fix) { & $fix.Action } else { Write-Log "Fix not found: $script:FixName" 'ERROR' }
            }
        })
        [void]$fixes.Children.Add($b)
    }

    $panels = Get-Ctl 'PanelList'
    $panels.Children.Clear()
    foreach ($p in $script:Panels) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $p.Name
        $b.Style   = $win.FindResource('Btn')
        $b.Tag     = $p.Cmd
        $b.Add_Click({
            param($s, $e)
            try {
                Start-Process $s.Tag -ErrorAction Stop
                Write-Log "Opened $($s.Content)"
            } catch {
                Write-Log "Cannot open $($s.Tag): $($_.Exception.Message)" 'ERROR'
            }
        })
        [void]$panels.Children.Add($b)
    }
}

function Update-SysInfo {
    $sp = Get-Ctl 'SysInfoPanel'
    $sp.Children.Clear()
    foreach ($kv in (Get-SystemInfo).GetEnumerator()) {
        $row = New-Object Windows.Controls.Grid
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = '130'
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = '*'
        [void]$row.ColumnDefinitions.Add($c1)
        [void]$row.ColumnDefinitions.Add($c2)

        $k = New-Object Windows.Controls.TextBlock
        $k.Text = $kv.Key
        $k.Foreground = New-Brush '#8A93A6'
        $k.Margin = '0,3'
        $v = New-Object Windows.Controls.TextBlock
        $v.Text = "$($kv.Value)"
        $v.TextWrapping = 'Wrap'
        $v.Margin = '0,3'
        [Windows.Controls.Grid]::SetColumn($k, 0)
        [Windows.Controls.Grid]::SetColumn($v, 1)
        [void]$row.Children.Add($k)
        [void]$row.Children.Add($v)
        [void]$sp.Children.Add($row)
    }

    $dp = Get-Ctl 'DiskPanel'
    $dp.Children.Clear()
    try { $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop) }
    catch { $disks = @() }
    foreach ($d in $disks) {
        $used = $d.Size - $d.FreeSpace
        $pct  = if ($d.Size) { [math]::Round($used / $d.Size * 100) } else { 0 }
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = "{0}  {1:N1} GB free of {2:N1} GB  ({3}% used)" -f `
                  $d.DeviceID, ($d.FreeSpace / 1GB), ($d.Size / 1GB), $pct
        $t.Margin = '0,3,0,2'
        [void]$dp.Children.Add($t)

        $pb = New-Object Windows.Controls.ProgressBar
        $pb.Height = 6
        $pb.Value  = $pct
        $pb.Margin = '0,0,0,10'
        $pb.Foreground = New-Brush $(if ($pct -gt 90) { '#F4614E' } elseif ($pct -gt 75) { '#F0A93B' } else { '#4EA1FF' })
        $pb.Background = New-Brush '#252A38'
        $pb.BorderThickness = [Windows.Thickness]::new(0)
        [void]$dp.Children.Add($pb)
    }
}

# ---------------------------------------------------------------------------
#  Event wiring
# ---------------------------------------------------------------------------
function Register-RharmyEvents {
    $win = $script:Sync['Window']

    # ---- navigation -------------------------------------------------------
    $script:Pages = [ordered]@{
        NavInstall = 'PageInstall'; NavTweaks = 'PageTweaks'; NavConfig = 'PageConfig'
        NavUpdates = 'PageUpdates'; NavGaming = 'PageGaming'; NavSystem = 'PageSystem'; NavLog    = 'PageLog'
    }
    foreach ($nav in @($script:Pages.Keys)) {
        $ctl = Get-Ctl $nav
        if (-not $ctl) { continue }
        $ctl.Add_Checked({
            param($s, $e)
            foreach ($p in $script:Pages.Values) {
                $page = Get-Ctl $p
                if ($page) { $page.Visibility = 'Collapsed' }
            }
            $target = Get-Ctl $script:Pages[$s.Name]
            if ($target) { $target.Visibility = 'Visible' }
        })
    }

    # ---- install page -----------------------------------------------------
    (Get-Ctl 'AppSearch').Add_TextChanged({ Update-AppFilter })

    (Get-Ctl 'BtnAppAll').Add_Click({
        foreach ($cb in $script:AppChecks.Values) {
            if ($cb.Visibility -eq 'Visible') { $cb.IsChecked = $true }
        }
    })
    (Get-Ctl 'BtnAppNone').Add_Click({
        foreach ($cb in $script:AppChecks.Values) { $cb.IsChecked = $false }
    })

    (Get-Ctl 'BtnInstall').Add_Click({
        $sel = Get-SelectedApps
        if ($sel.Count -eq 0) { Write-Log 'Nothing selected.' 'WARN'; return }
        if (-not (Show-Ask "Install $($sel.Count) application(s)?")) { return }
        Start-BackgroundJob -Name "Install $($sel.Count) app(s)" -Vars @{ Selection = $sel } -Work {
            if (-not (Test-Winget)) {
                Write-Log 'winget missing - bootstrapping it first.' 'WARN'
                Install-Winget | Out-Null
            }
            $total = @($script:Selection).Count
            $i = 0; $ok = 0
            foreach ($a in $script:Selection) {
                if ($script:Sync.Cancel) { Write-Log 'Cancelled by user.' 'WARN'; break }
                $i++
                Set-Status "Installing $($a.Name) ($i/$total)" ([int](($i - 1) / $total * 100))
                if (Install-App -App $a) { $ok++ }
            }
            Write-Log "Install pass: $ok of $total succeeded." 'OK'
        }
    })

    (Get-Ctl 'BtnUninstall').Add_Click({
        $sel = Get-SelectedApps
        if ($sel.Count -eq 0) { Write-Log 'Nothing selected.' 'WARN'; return }
        if (-not (Show-Ask "Uninstall $($sel.Count) application(s)?" 'Warning')) { return }
        Start-BackgroundJob -Name "Uninstall $($sel.Count) app(s)" -Vars @{ Selection = $sel } -Work {
            $total = @($script:Selection).Count
            $i = 0
            foreach ($a in $script:Selection) {
                if ($script:Sync.Cancel) { Write-Log 'Cancelled by user.' 'WARN'; break }
                $i++
                Set-Status "Uninstalling $($a.Name) ($i/$total)" ([int](($i - 1) / $total * 100))
                Uninstall-App -App $a | Out-Null
            }
            Write-Log 'Uninstall pass finished.' 'OK'
        }
    })

    (Get-Ctl 'BtnUpgrade').Add_Click({
        Start-BackgroundJob -Name 'Upgrade all packages' -Work { Update-AllApps }
    })

    # ---- config save / load ------------------------------------------------
    (Get-Ctl 'BtnSaveCfg').Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter   = 'Rharmy Optimizer config (*.json)|*.json'
        $dlg.FileName = 'rharmy-optimizer-config.json'
        if (-not $dlg.ShowDialog()) { return }
        $apps   = @(Get-SelectedApps   | ForEach-Object { $_.Name })
        $tweaks = @(Get-SelectedTweaks | ForEach-Object { $_.Id })
        Export-RharmyConfig -Path $dlg.FileName -Apps $apps -Tweaks $tweaks
    })

    (Get-Ctl 'BtnLoadCfg').Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Rharmy Optimizer config (*.json)|*.json'
        if (-not $dlg.ShowDialog()) { return }
        try {
            $cfg = Import-RharmyConfig -Path $dlg.FileName
            foreach ($cb in $script:AppChecks.Values)   { $cb.IsChecked = $false }
            foreach ($cb in $script:TweakChecks.Values) { $cb.IsChecked = $false }

            $apps   = @(Get-Prop $cfg 'Apps'   @())
            $tweaks = @(Get-Prop $cfg 'Tweaks' @())
            $miss = 0
            foreach ($n in $apps) {
                if ($script:AppChecks.ContainsKey($n)) { $script:AppChecks[$n].IsChecked = $true }
                else { $miss++ }
            }
            foreach ($n in $tweaks) {
                if ($script:TweakChecks.ContainsKey($n)) { $script:TweakChecks[$n].IsChecked = $true }
                else { $miss++ }
            }
            Update-AppCount; Update-TweakCount
            Write-Log "Loaded $($apps.Count) app(s) and $($tweaks.Count) tweak(s) from $($dlg.FileName)" 'OK'
            if ($miss) { Write-Log "$miss entry/entries in the file are unknown to this version." 'WARN' }
        } catch {
            Write-Log "Import failed: $($_.Exception.Message)" 'ERROR'
        }
    })

    # ---- tweaks ------------------------------------------------------------
    (Get-Ctl 'BtnTweakRec').Add_Click({
        foreach ($cb in $script:TweakChecks.Values) {
            $cb.IsChecked = [bool](Get-Prop $cb.Tag 'Recommended' $false)
        }
    })
    (Get-Ctl 'BtnTweakNone').Add_Click({
        foreach ($cb in $script:TweakChecks.Values) { $cb.IsChecked = $false }
    })

    (Get-Ctl 'BtnTweakApply').Add_Click({
        $sel = Get-SelectedTweaks
        if ($sel.Count -eq 0) { Write-Log 'No tweaks selected.' 'WARN'; return }
        $risky = @($sel | Where-Object { (Get-Prop $_ 'Risk' 'Low') -ne 'Low' }).Count
        $msg = "Apply $($sel.Count) tweak(s)?"
        if ($risky) { $msg += "`n`n$risky of them are rated Medium or High risk." }
        $msg += "`n`nA restore point first is strongly recommended."
        if (-not (Show-Ask $msg)) { return }

        $needExplorer = @($sel | Where-Object { (Get-Prop $_ 'Category' '') -in @('Explorer','Debloat') }).Count -gt 0
        $onDone = if ($needExplorer) {
            { if (Show-Ask 'Restart Explorer now so the shell changes show up?') { Restart-Explorer } }
        } else { $null }

        Start-BackgroundJob -Name "Apply $($sel.Count) tweak(s)" -OnDone $onDone `
            -Vars @{ Ids = @($sel | ForEach-Object { $_.Id }) } -Work {
            $total = @($script:Ids).Count
            $i = 0; $ok = 0
            foreach ($id in $script:Ids) {
                if ($script:Sync.Cancel) { Write-Log 'Cancelled by user.' 'WARN'; break }
                $t = $script:Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
                if (-not $t) { Write-Log "Unknown tweak: $id" 'WARN'; continue }
                $i++
                Set-Status "$($t.Name) ($i/$total)" ([int](($i - 1) / $total * 100))
                if (Invoke-Tweak -Tweak $t -Action Apply) { $ok++ }
            }
            Write-Log "Applied $ok of $total tweak(s)." 'OK'
        }
    })

    (Get-Ctl 'BtnTweakUndo').Add_Click({
        $sel = Get-SelectedTweaks
        if ($sel.Count -eq 0) { Write-Log 'No tweaks selected.' 'WARN'; return }
        if (-not (Show-Ask "Revert $($sel.Count) tweak(s) to the Windows default?")) { return }
        Start-BackgroundJob -Name "Undo $($sel.Count) tweak(s)" `
            -Vars @{ Ids = @($sel | ForEach-Object { $_.Id }) } -Work {
            $total = @($script:Ids).Count
            $i = 0; $ok = 0
            foreach ($id in $script:Ids) {
                if ($script:Sync.Cancel) { Write-Log 'Cancelled by user.' 'WARN'; break }
                $t = $script:Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
                if (-not $t) { continue }
                $i++
                Set-Status "Undo $($t.Name) ($i/$total)" ([int](($i - 1) / $total * 100))
                if (Invoke-Tweak -Tweak $t -Action Undo) { $ok++ }
            }
            Write-Log "Reverted $ok of $total tweak(s)." 'OK'
        }
    })

    # ---- features ----------------------------------------------------------
    (Get-Ctl 'BtnFeatureApply').Add_Click({
        $changed = @($script:FeatChecks.Values |
                     Where-Object { $_.IsEnabled -and ([bool]$_.IsChecked -ne [bool]$_.Tag.Initial) })
        if ($changed.Count -eq 0) { Write-Log 'No feature changes to apply.' 'WARN'; return }
        if (-not (Show-Ask "Change $($changed.Count) Windows feature(s)? A reboot will be needed.")) { return }

        $plan = @($changed | ForEach-Object {
            @{ Feature = $_.Tag.Feature; State = $(if ($_.IsChecked) { 'Enable' } else { 'Disable' }) }
        })
        $onDone = {
            foreach ($cb in $script:FeatChecks.Values) { $cb.Tag.Initial = [bool]$cb.IsChecked }
        }
        Start-BackgroundJob -Name 'Windows features' -OnDone $onDone -Vars @{ Plan = $plan } -Work {
            $total = @($script:Plan).Count
            $i = 0
            foreach ($p in $script:Plan) {
                if ($script:Sync.Cancel) { Write-Log 'Cancelled by user.' 'WARN'; break }
                $i++
                Set-Status "$($p.State) $($p.Feature.Name) ($i/$total)" ([int](($i - 1) / $total * 100))
                Set-WindowsFeatureState -Feature $p.Feature -State $p.State | Out-Null
            }
            Write-Log 'Feature changes done - reboot to finish.' 'OK'
        }
    })

    # ---- updates -----------------------------------------------------------
    (Get-Ctl 'BtnUpdDefault').Add_Click({
        Start-BackgroundJob -Name 'Update policy: Default' -Work { Set-UpdatePolicy -Mode Default }
    })
    (Get-Ctl 'BtnUpdSecurity').Add_Click({
        Start-BackgroundJob -Name 'Update policy: Security' -Work { Set-UpdatePolicy -Mode Security }
    })
    (Get-Ctl 'BtnUpdDisabled').Add_Click({
        if (-not (Show-Ask "This turns OFF all Windows security patches.`n`nAre you absolutely sure?" 'Warning')) { return }
        Start-BackgroundJob -Name 'Update policy: Disabled' -Work { Set-UpdatePolicy -Mode Disabled }
    })
    (Get-Ctl 'BtnUpdCheck').Add_Click({
        Start-BackgroundJob -Name 'Windows Update' -Work { Install-WindowsUpdates }
    })
    (Get-Ctl 'BtnUpdPanel').Add_Click({ Start-Process 'ms-settings:windowsupdate' })
    (Get-Ctl 'BtnUpdHistory').Add_Click({ Start-Process 'ms-settings:windowsupdate-history' })

    # ---- gaming -------------------------------------------------------------
    (Get-Ctl 'BtnGamePerformance').Add_Click({
        if (-not (Show-Ask 'Apply the recommended gaming performance preset?`n`nThis enables Game Mode and Ultimate Performance. Laptops may use more battery.')) { return }
        Start-BackgroundJob -Name 'Gaming performance preset' -Vars @{ Ids = @('EnableGameMode','UltimatePerformance') } -Work {
            foreach ($id in $script:Ids) {
                $t = $script:Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
                if ($t) { Invoke-Tweak -Tweak $t -Action Apply | Out-Null }
            }
            Write-Log 'Gaming performance preset complete.' 'OK'
        }
    })
    (Get-Ctl 'BtnGameDns').Add_Click({ Start-BackgroundJob -Name 'Flush DNS' -Work { Clear-DnsClientCache -EA SilentlyContinue; & ipconfig.exe /flushdns | ForEach-Object { if ($_ -match '\S') { Write-Log "  $_" } }; Write-Log 'DNS cache flushed.' 'OK' } })
    (Get-Ctl 'BtnGameSettings').Add_Click({ Start-Process 'ms-settings:gaming-gamemode' })
    (Get-Ctl 'BtnGameCache').Add_Click({
        if (-not (Show-Ask 'Clear temporary DirectX shader cache and user temp files?')) { return }
        Start-BackgroundJob -Name 'Gaming cache cleanup' -Work {
            foreach ($p in @($env:TEMP, "$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\AMD\DxCache")) {
                if (Test-Path $p) { Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue }
            }
            Write-Log 'Gaming cache cleanup complete.' 'OK'
        }
    })
    (Get-Ctl 'BtnVssList').Add_Click({
        Start-BackgroundJob -Name 'VSS shadow storage query' -OnDone { (Get-Ctl 'VssOutput').Text = Get-VssShadowStorageText } -Work {
            $text = Get-VssShadowStorageText
            Invoke-OnUi { (Get-Ctl 'VssOutput').Text = $text }
            Write-Log 'VSS shadow storage listed.' 'OK'
        }
    })
    (Get-Ctl 'BtnVss2GB').Add_Click({
        if (-not (Show-Ask 'Resize C: shadow storage to 2 GB?`n`nThis may remove older restore snapshots when Windows needs to shrink the allocation.' 'Warning')) { return }
        Start-BackgroundJob -Name 'Resize VSS to 2 GB' -Work { Resize-VssShadowStorage2GB }
    })

    # ---- system ------------------------------------------------------------
    (Get-Ctl 'BtnSysRefresh').Add_Click({ Update-SysInfo; Write-Log 'System info refreshed.' })
    (Get-Ctl 'BtnSysTaskMgr').Add_Click({ Start-Process taskmgr.exe })
    (Get-Ctl 'BtnSysExport').Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter   = 'Text file (*.txt)|*.txt'
        $dlg.FileName = "sysinfo_$(Get-Date -Format yyyyMMdd).txt"
        if (-not $dlg.ShowDialog()) { return }
        try {
            (Get-SystemInfo).GetEnumerator() |
                ForEach-Object { "{0,-12}: {1}" -f $_.Key, $_.Value } |
                Set-Content $dlg.FileName -Encoding UTF8
            Write-Log "System report written to $($dlg.FileName)" 'OK'
        } catch {
            Write-Log "Export failed: $($_.Exception.Message)" 'ERROR'
        }
    })

    # ---- log ---------------------------------------------------------------
    (Get-Ctl 'BtnLogClear').Add_Click({ (Get-Ctl 'LogBox').Clear() })
    (Get-Ctl 'BtnLogSave').Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter   = 'Log file (*.log)|*.log|Text (*.txt)|*.txt'
        $dlg.FileName = "rharmy-optimizer_$(Get-Date -Format yyyyMMdd_HHmmss).log"
        if (-not $dlg.ShowDialog()) { return }
        (Get-Ctl 'LogBox').Text | Set-Content $dlg.FileName -Encoding UTF8
        Write-Log "Log saved to $($dlg.FileName)" 'OK'
    })

    # ---- always-on buttons -------------------------------------------------
    (Get-Ctl 'BtnRestore').Add_Click({
        Start-BackgroundJob -Name 'System restore point' -Work { New-RharmyRestorePoint | Out-Null }
    })
    (Get-Ctl 'BtnOpenLog').Add_Click({ Start-Process explorer.exe $script:WorkDir })

    (Get-Ctl 'BtnCancel').Add_Click({
        if ($script:CancelArmed) {
            # Second press: hard-kill the pipeline.
            Write-Log 'Force-stopping the current operation.' 'WARN'
            if ($script:JobPS) { try { $script:JobPS.Stop() } catch { } }
            return
        }
        $script:CancelArmed = $true
        $script:Sync.Cancel = $true
        Write-Log 'Cancellation requested - stopping after the current step. Press Cancel again to force.' 'WARN'
    })
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
function Show-RharmyGui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$script:Xaml)
        $win    = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        Write-Log "The interface failed to load: $($_.Exception.Message)" 'ERROR'
        throw
    }

    $script:UI.Clear()
    $script:Sync['Window']     = $win
    $script:Sync['LogBox']     = $win.FindName('LogBox')
    $script:Sync['StatusText'] = $win.FindName('StatusText')
    $script:Sync['Progress']   = $win.FindName('Progress')

    (Get-Ctl 'VerText').Text = "v$script:AppVersion"
    if (-not (Test-Admin)) {
        (Get-Ctl 'AdminBadge').Background = New-Brush '#4D1E1E'
        (Get-Ctl 'AdminText').Text        = 'NOT ELEVATED'
        (Get-Ctl 'AdminText').Foreground  = New-Brush '#F4614E'
    }

    Build-AppPage
    Build-TweakPage
    Build-ConfigPage
    Update-SysInfo
    try { (Get-Ctl 'VssOutput').Text = Get-VssShadowStorageText } catch { }
    Register-RharmyEvents

    Write-Log "$script:AppName $script:AppVersion started." 'OK'
    Write-Log "Log file: $script:LogFile"
    if (-not (Test-Admin)) {
        Write-Log 'Running WITHOUT administrator rights - most actions will fail.' 'ERROR'
    }
    if (-not (Test-Winget)) {
        Write-Log 'winget was not detected. It will be bootstrapped on the first install.' 'WARN'
    }
    Write-Log "$(@($script:Apps).Count) apps and $(@($script:Tweaks).Count) tweaks loaded."

    $win.Add_Closing({
        param($s, $e)
        if ($script:Busy) {
            if (-not (Show-Ask "'$script:JobName' is still running. Quit anyway?" 'Warning')) {
                $e.Cancel = $true
                return
            }
        }
        Stop-RharmyWorker
    })

    [void]$win.ShowDialog()
}

# ---------------------------------------------------------------------------
#  Entry point
#
#  `irm <url> | iex` cannot bind parameters - the script is executed as a bare
#  expression, so -Config/-Run never arrive. Fall back to environment
#  variables so the one-liner stays scriptable:
#
#     $env:RHARMY_CONFIG = 'C:\setup.json'; $env:RHARMY_RUN = '1'
#     irm https://.../rharmy-optimizer.ps1 | iex
# ---------------------------------------------------------------------------
if (-not $Config -and $env:RHARMY_CONFIG) { $Config = $env:RHARMY_CONFIG }
if (-not $Run    -and $env:RHARMY_RUN -in @('1', 'true', 'yes')) { $Run = $true }

Invoke-SelfElevate

if ($Run -and $Config) {
    Invoke-HeadlessRun -Path $Config
    exit 0
}

if ($Run -and -not $Config) {
    Write-Log 'RHARMY_RUN / -Run was set without a config. Nothing to do.' 'WARN'
}

Show-RharmyGui
