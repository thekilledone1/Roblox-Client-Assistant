# ================================================================
#  RobloxFileModWatcher.ps1  -  Roblox Client Assistant
# ================================================================

param([switch]$Hidden)

$script:AppVersion = "0.0.0"
$script:VersionGistFile = "RCA_version.txt"
$script:VersionGistApiUrl = "https://api.github.com/gists/29f4e5c814f6290251fc4d9936dacd47"
$script:VersionGistRawUrl = "https://gist.githubusercontent.com/thekilledone1/29f4e5c814f6290251fc4d9936dacd47/raw/RCA_version.txt"
$script:DownloadRepoUrl = "https://github.com/thekilledone1/Roblox-Client-Assistant"

function ConvertTo-VersionNumber([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text.Trim(), 'v?(\d+(?:\.\d+){1,3})', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    try { return [System.Version]$match.Groups[1].Value } catch { return $null }
}

function Show-UpdatePrompt([System.Version]$LatestVersion) {
    $msg = "A new version of Roblox Client Assistant is available.`n`nInstalled version: $($script:AppVersion)`nLatest version: $LatestVersion`n`nOpen the GitHub repository to download it?"
    $result = [System.Windows.Forms.MessageBox]::Show(
        $msg,
        "Roblox Client Assistant Update",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information)

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process $script:DownloadRepoUrl
        Write-Log "User opened update download page for version $LatestVersion."
    } else {
        Write-Log "User dismissed update prompt for version $LatestVersion."
    }
}

function Get-VersionFromGistResponse([string]$ResponseText) {
    try {
        $gist = $ResponseText | ConvertFrom-Json
        $file = $gist.files.($script:VersionGistFile)
        if ($file -and $file.content) { return $file.content.Trim() }
    } catch {}

    return $ResponseText.Trim()
}

function Invoke-UpdateCheck {
    try {
        $client = New-Object System.Net.WebClient
        $client.Headers["User-Agent"] = "RobloxClientAssistant/$($script:AppVersion)"
        $client.Headers["Cache-Control"] = "no-cache"
        $script:UpdateCheckClient = $client
        $script:UpdateCheckTimedOut = $false

        $client.Add_DownloadStringCompleted({
            param($sender, $e)
            try {
                if ($script:UpdateCheckTimeoutTimer) {
                    $script:UpdateCheckTimeoutTimer.Stop()
                    $script:UpdateCheckTimeoutTimer.Dispose()
                    $script:UpdateCheckTimeoutTimer = $null
                }

                if ($e.Cancelled) {
                    if ($script:UpdateCheckTimedOut) { Write-Log "Update check timed out." "WARN" }
                    return
                }
                if ($e.Error) {
                    Write-Log "Update check failed: $($e.Error.Message)" "WARN"
                    return
                }

                $remote = Get-VersionFromGistResponse $e.Result
                $local  = ConvertTo-VersionNumber $script:AppVersion
                $latest = ConvertTo-VersionNumber $remote

                if (-not $local -or -not $latest) {
                    Write-Log "Update check returned an invalid version string: '$remote'." "WARN"
                    return
                }

                if ($latest -gt $local) {
                    Write-Log "Update available. Installed: $local; Latest: $latest."
                    Show-UpdatePrompt $latest
                } else {
                    Write-Log "Update check complete. Installed: $local; Latest: $latest."
                }
            } catch {
                Write-Log "Update check failed: $_" "WARN"
            } finally {
                try { $sender.Dispose() } catch {}
                $script:UpdateCheckClient = $null
            }
        })

        $script:UpdateCheckTimeoutTimer = New-Object System.Windows.Forms.Timer
        $script:UpdateCheckTimeoutTimer.Interval = 5000
        $script:UpdateCheckTimeoutTimer.Add_Tick({
            $this.Stop()
            $this.Dispose()
            $script:UpdateCheckTimeoutTimer = $null
            $script:UpdateCheckTimedOut = $true
            try {
                if ($script:UpdateCheckClient -and $script:UpdateCheckClient.IsBusy) {
                    $script:UpdateCheckClient.CancelAsync()
                }
            } catch {
                Write-Log "Failed to cancel update check: $_" "WARN"
            }
        })
        $script:UpdateCheckTimeoutTimer.Start()
        $client.DownloadStringAsync([Uri]$script:VersionGistApiUrl)
    } catch {
        if ($script:UpdateCheckTimeoutTimer) {
            $script:UpdateCheckTimeoutTimer.Stop()
            $script:UpdateCheckTimeoutTimer.Dispose()
            $script:UpdateCheckTimeoutTimer = $null
        }
        if ($script:UpdateCheckClient) {
            try { $script:UpdateCheckClient.Dispose() } catch {}
            $script:UpdateCheckClient = $null
        }
        Write-Log "Update check failed: $_" "WARN"
    }
}

function Start-UpdateCheckTimer {
    $script:UpdateCheckTimer = New-Object System.Windows.Forms.Timer
    $script:UpdateCheckTimer.Interval = 1500
    $script:UpdateCheckTimer.Add_Tick({
        $this.Stop()
        $this.Dispose()
        Invoke-UpdateCheck
    })
    $script:UpdateCheckTimer.Start()
}

# -- SELF-UNBLOCK -------------------------------------------------
# Removes the Windows "Mark of the Web" from both files so the
# security warning stops appearing after the first run.
Unblock-File -Path $PSCommandPath -ErrorAction SilentlyContinue
Unblock-File -Path (Join-Path $PSScriptRoot "RobloxClientAssistant.bat") -ErrorAction SilentlyContinue

# -- WIN32 HELPERS (needed for single-instance + icon) -----------
Add-Type -Name Win32 -Namespace Native -MemberDefinition '
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]   public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]   public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]   public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]   public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
' -ErrorAction SilentlyContinue
try { [Native.Win32]::ShowWindow([Native.Win32]::GetConsoleWindow(), 0) | Out-Null } catch {}

# -- SINGLE INSTANCE ----------------------------------------------
# Use a named mutex to ensure only one copy runs at a time.
# If another instance is already running, restore its window and exit.
$script:AppMutex = $null
$mutexName       = "Global\RobloxClientAssistant_SingleInstance"
$createdNew      = $false
try {
    $script:AppMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
} catch {
    $createdNew = $false
}

if (-not $createdNew) {
    # Another instance is running â€” find its window and bring it to the front.
    Add-Type -AssemblyName System.Windows.Forms
    try {
        $hWnd = [Native.Win32]::FindWindow($null, "Roblox Client Assistant")
        if ($hWnd -ne [IntPtr]::Zero) {
            # SW_RESTORE = 9  (unminimizes if minimized, otherwise just shows)
            [Native.Win32]::ShowWindow($hWnd, 9)      | Out-Null
            [Native.Win32]::SetForegroundWindow($hWnd) | Out-Null
        }
    } catch {}
    exit
}

# -- SUPPRESS CMD WINDOW ------------------------------------------
# If launched without -Hidden (e.g. double-clicked), relaunch hidden and exit
if (-not $Hidden -and $Host.Name -eq 'ConsoleHost') {
    $argList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -Hidden"
    Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden
    if ($script:AppMutex) { $script:AppMutex.ReleaseMutex(); $script:AppMutex.Dispose() }
    exit
}

# -- ASSEMBLIES ---------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# -- PATHS --------------------------------------------------------
$AppDataDir = Join-Path $env:APPDATA "RobloxClientAssistant"
$BackupDir  = Join-Path $AppDataDir  "backups"
$PrefsFile  = Join-Path $AppDataDir  "prefs.json"
$LogFile    = Join-Path $AppDataDir  "debug.log"
$RegKey     = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$RegName    = "RobloxClientAssistant"
$ScriptPath = $MyInvocation.MyCommand.Path

foreach ($d in @($AppDataDir, $BackupDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# -- LOGGING ------------------------------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg" -ErrorAction SilentlyContinue
}

# -- BACKUP HELPERS -----------------------------------------------
function Import-ToBackup([string]$SrcPath) {
    $dest = Join-Path $BackupDir (Split-Path $SrcPath -Leaf)
    $srcR = (Resolve-Path $SrcPath -ErrorAction SilentlyContinue).Path
    $dstR = (Resolve-Path $dest    -ErrorAction SilentlyContinue).Path
    if ($srcR -and $srcR -eq $dstR) { return $dest }
    try {
        Copy-Item -Path $SrcPath -Destination $dest -Force -ErrorAction Stop
        Write-Log "Imported backup: $(Split-Path $SrcPath -Leaf)"
        return $dest
    } catch { Write-Log "Failed to import backup for $SrcPath : $_" "ERROR"; return $SrcPath }
}

# -- PREFS --------------------------------------------------------
$DefaultPrefs = @{ UseBloxstrap=$false; Activated=$true; RunOnStartup=$false; SoundFiles=@(); CrosshairFiles=@(); ParticleFiles=@(); SkyFiles=@() }

function Load-Prefs {
    try {
        if (Test-Path $PrefsFile) {
            $obj = Get-Content $PrefsFile -Raw | ConvertFrom-Json
            $p   = @{}
            foreach ($k in $DefaultPrefs.Keys) {
                $val = $obj.$k
                $p[$k] = if ($null -ne $val) { $val } else { $DefaultPrefs[$k] }
            }
            foreach ($k in @("SoundFiles","CrosshairFiles","ParticleFiles","SkyFiles")) {
                $p[$k] = if ($null -eq $p[$k]) { @() } else { @($p[$k] | ForEach-Object { "$_" }) }
            }
            foreach ($k in @("UseBloxstrap","Activated","RunOnStartup")) { $p[$k] = [bool]$p[$k] }
            return $p
        }
    } catch { Write-Log "Failed to load prefs: $_" "ERROR" }
    return $DefaultPrefs.Clone()
}

function Save-Prefs([hashtable]$Prefs) {
    try { $Prefs | ConvertTo-Json -Depth 5 | Set-Content -Path $PrefsFile -Encoding UTF8 }
    catch { Write-Log "Failed to save prefs: $_" "ERROR" }
}

# -- STARTUP REGISTRY ---------------------------------------------
function Get-StartupEnabled {
    try { $null -ne (Get-ItemProperty $RegKey -Name $RegName -ErrorAction Stop).$RegName } catch { $false }
}
function Set-StartupEnabled([bool]$On) {
    if ($On) {
        Set-ItemProperty $RegKey -Name $RegName -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Hidden"
    } else { Remove-ItemProperty $RegKey -Name $RegName -ErrorAction SilentlyContinue }
}

# -- ROBLOX PATH HELPERS ------------------------------------------
function Get-VersionsRoot([bool]$Bloxstrap) {
    if ($Bloxstrap) { "$env:LOCALAPPDATA\Bloxstrap\Versions" } else { "$env:LOCALAPPDATA\Roblox\Versions" }
}

function Get-NewestVersionFolder([string]$Root) {
    if (-not (Test-Path $Root)) { return $null }
    $dirs = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^version-[a-fA-F0-9]+$' } |
            Sort-Object CreationTime -Descending
    if ($dirs) { return $dirs[0].FullName }
    return $null
}

function Get-SubPaths([string]$Ver) {
    @{
        Sounds     = Join-Path $Ver "content\sounds"
        Crosshairs = Join-Path $Ver "content\textures\Cursors\KeyboardMouse"
        Particles  = Join-Path $Ver "content\textures\particles"
        Sky        = Join-Path $Ver "PlatformContent\pc\textures\sky"
    }
}

function Get-CategoryFolder([string]$Cat) {
    $useBlox = if ($null -ne $script:chkBloxstrap) { $script:chkBloxstrap.Checked } else { $false }
    $ver = Get-NewestVersionFolder (Get-VersionsRoot $useBlox)
    if (-not $ver) { return $null }
    return (Get-SubPaths $ver)[$Cat]
}

# -- FILE APPLY ---------------------------------------------------
function Invoke-ApplyFiles([string]$VersionFolder, [hashtable]$Prefs) {
    $paths = Get-SubPaths $VersionFolder
    $map   = @{ SoundFiles=$paths.Sounds; CrosshairFiles=$paths.Crosshairs; ParticleFiles=$paths.Particles; SkyFiles=$paths.Sky }
    foreach ($key in $map.Keys) {
        foreach ($srcPath in $Prefs[$key]) {
            if (-not (Test-Path $srcPath)) { Write-Log "Backup missing: $srcPath" "WARN"; continue }
            $dest    = Join-Path $map[$key] (Split-Path $srcPath -Leaf)
            $srcR    = (Resolve-Path $srcPath -ErrorAction SilentlyContinue).Path
            $dstR    = (Resolve-Path $dest    -ErrorAction SilentlyContinue).Path
            if ($srcR -and $srcR -eq $dstR) { Write-Log "Skipping self-copy: $(Split-Path $srcPath -Leaf)" "WARN"; continue }
            try { Copy-Item -Path $srcPath -Destination $dest -Force -ErrorAction Stop; Write-Log "Applied: $(Split-Path $srcPath -Leaf)" }
            catch { Write-Log "Failed to apply $(Split-Path $srcPath -Leaf): $_" "ERROR" }
        }
    }
}

# -- CHECK-PROOF WHITELIST ----------------------------------------
# These files bypass validation - they are allowed even if not currently
# present in the folder (e.g. accidentally deleted by the user).
$script:CheckProofFiles = @(
    # Sounds (.ogg)
    "action_falling.ogg","action_footsteps_plastic.ogg","action_get_up.ogg",
    "action_jump.ogg","action_jump_land.ogg","action_swim.ogg",
    "impact_explosion_03.ogg","impact_water.ogg","oof.ogg","ouch.ogg","volume_slider.ogg",
    # Crosshairs (.png)
    "IBeamCursor.png","ArrowFarCursor.png","ArrowCursor.png",
    # Particles (.dds)
    "common_alpha.dds","explosion_alpha.dds","explosion_color.dds",
    "explosion01_core_alpha.png","explosion01_core_main.dds",
    "explosion01_implosion_color.png","explosion01_implosion_main.dds",
    "explosion01_shockwave_main.dds","explosion01_smoke_alpha.dds",
    "explosion01_smoke_color_new.dds","explosion01_smoke_main.dds",
    "fire_alpha.dds","fire_color.dds","fire_main.dds",
    "fire_sparks_color.dds","fire_sparks_main.dds",
    "forcefield_alpha.dds","forcefield_glow_alpha.dds","forcefield_glow_color.dds",
    "forcefield_glow_main.dds","forcefield_vortex_color.dds","forcefield_vortex_main.dds",
    "legacy_fire_alpha_color.dds","smoke_color.dds","smoke_main.dds",
    "sparkles_color.dds","sparkles_main.dds","SquareParticle.png",
    # Sky textures (.tex)
    "indoor512_bk.tex","indoor512_dn.tex","indoor512_ft.tex",
    "indoor512_lf.tex","indoor512_rt.tex","indoor512_up.tex",
    "sky512_bk.tex","sky512_dn.tex","sky512_ft.tex",
    "sky512_lf.tex","sky512_rt.tex","sky512_up.tex"
)

# -- VALIDATE FILES -----------------------------------------------
function Invoke-ValidateFiles([string[]]$Files, [string]$DestDir, [string]$Cat,
                               [System.Collections.Generic.List[string]]$Errs) {
    if ($Files.Count -eq 0) { return }
    if (-not $DestDir -or -not (Test-Path $DestDir)) { $Errs.Add("Could not find $Cat folder: $DestDir"); return }
    foreach ($f in $Files) {
        $name = Split-Path $f -Leaf
        if ($script:CheckProofFiles -contains $name) { continue }
        if (-not (Test-Path (Join-Path $DestDir $name))) {
            # Shorten path to last 2 folder segments for readability
            $short = ($DestDir -split '\\' | Select-Object -Last 2) -join "\"
            $Errs.Add("Error! A file matching the name and format '$name' was not found in ...\$short`nCheck that the name and file format both match.")
        }
    }
}

# -- WATCHER STATE ------------------------------------------------
$global:CurrentVersionFolder = $null
$global:Prefs                = Load-Prefs
$global:AppExiting           = $false

# -- POLLING TIMER (runs on the WinForms UI thread - full global access) ------
# Replaces Register-ObjectEvent -Action which runs in a child runspace where
# $global: variables defined in the parent script are inaccessible, making the
# old FSW event handlers unable to read/write $global:RestoreCooldown, etc.
$global:WatchTimer           = $null

# Per-file cooldown table: tracks last time WE wrote a file so we don't
# re-restore our own write on the next poll cycle.
$global:RestoreCooldown      = @{}   # [filename] -> [DateTime] last-written-by-us

# Tracks the last-known modification time of each watched destination file
# so the poll can detect both deletion (file gone) and overwrite (mtime changed).
$global:FileLastSeen         = @{}   # [destPath] -> [DateTime] or $null if known-absent

# Tracks the LastWriteTime of the anchored version folder so we can detect
# a same-folder reinstall (folder path unchanged but Roblox rewrote its contents).
$global:CurrentVersionFolderMod = $null

# Deferred re-apply: instead of Start-Sleep on the UI thread we record a future
# DateTime; the Tick handler checks it and does the copy work when it arrives.
$global:ReapplyPending       = $false
$global:ReapplyAt            = $null
$global:ReapplyFolder        = $null

function Stop-AllWatchers {
    if ($global:WatchTimer) {
        $global:WatchTimer.Stop()
        $global:WatchTimer.Dispose()
        $global:WatchTimer = $null
    }
}

# Build the flat list of (backupPath, destPath) pairs we need to police.
function Get-WatchedPairs([hashtable]$Prefs, [string]$VersionFolder) {
    $pairs = [System.Collections.Generic.List[hashtable]]::new()
    if (-not $VersionFolder) { return $pairs }
    $sub = Get-SubPaths $VersionFolder
    $map = @{ SoundFiles=$sub.Sounds; CrosshairFiles=$sub.Crosshairs; ParticleFiles=$sub.Particles; SkyFiles=$sub.Sky }
    foreach ($key in $map.Keys) {
        foreach ($bp in $Prefs[$key]) {
            if (-not $bp) { continue }
            $dest = Join-Path $map[$key] (Split-Path $bp -Leaf)
            $pairs.Add(@{ Backup=$bp; Dest=$dest }) | Out-Null
        }
    }
    return $pairs
}

# Restore one file from its backup to its destination, with one retry.
function Invoke-RestoreFile([string]$BackupPath, [string]$DestPath) {
    $fileName = Split-Path $DestPath -Leaf
    $destDir  = Split-Path $DestPath -Parent
    if (-not (Test-Path $destDir)) {
        try { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        catch { Write-Log "Cannot create dir $destDir : $_" "ERROR"; return $false }
    }
    $global:RestoreCooldown[$fileName] = [DateTime]::UtcNow
    try {
        Copy-Item -Path $BackupPath -Destination $DestPath -Force -EA Stop
        Write-Log "Restored: $fileName"
        return $true
    } catch {
        Start-Sleep -Milliseconds 500
        try {
            Copy-Item -Path $BackupPath -Destination $DestPath -Force -EA Stop
            Write-Log "Restored (retry): $fileName"
            return $true
        } catch {
            Write-Log "Failed to restore ${fileName}: $_" "ERROR"
            return $false
        }
    }
}

function Sync-FileLastSeen([string]$VersionFolder) {
    # Record current mtime for every watched dest so the next poll has a baseline.
    $global:FileLastSeen = @{}
    foreach ($pair in (Get-WatchedPairs $global:Prefs $VersionFolder)) {
        if (Test-Path $pair.Dest) {
            $global:FileLastSeen[$pair.Dest] = (Get-Item $pair.Dest -EA SilentlyContinue).LastWriteTimeUtc
        } else {
            $global:FileLastSeen[$pair.Dest] = $null
        }
    }
}

function Start-Watching([hashtable]$Prefs) {
    Stop-AllWatchers
    $root = Get-VersionsRoot $Prefs.UseBloxstrap
    $ver  = Get-NewestVersionFolder $root
    if (-not $ver) { Write-Log "No version folder found in $root" "WARN"; return }
    $global:CurrentVersionFolder    = $ver
    $global:CurrentVersionFolderMod = (Get-Item $ver -EA SilentlyContinue).LastWriteTimeUtc
    Write-Log "Anchored to: $ver"

    # Apply immediately on activation and seed baseline
    Invoke-ApplyFiles $ver $Prefs
    Write-Log "Initial apply complete."
    Sync-FileLastSeen $ver

    # ---------------------------------------------------------------
    # Deferred re-apply state.
    # When a reinstall/update is detected we record a future timestamp
    # instead of calling Start-Sleep (which blocks the UI thread).
    # The Tick handler checks whether the deadline has passed and then
    # does the actual copy work.
    # ---------------------------------------------------------------
    $global:ReapplyAt      = $null   # [DateTime] after which we should apply
    $global:ReapplyFolder  = $null   # which version folder to apply into
    $global:ReapplyPending = $false

    # Track Roblox process state so we can fire the moment it launches.
    # We apply files as soon as the process appears - before it reads anything.
    $global:RobloxWasRunning = $false

    # WinForms timer fires on the UI thread - full access to all globals.
    $global:WatchTimer          = New-Object System.Windows.Forms.Timer
    $global:WatchTimer.Interval = 750   # faster tick so process launch is caught quickly

    $global:WatchTimer.Add_Tick({
        if ($global:AppExiting -or -not $global:Prefs.Activated) { return }

        $now = [DateTime]::UtcNow

        # ---------------------------------------------------------------
        # PHASE 0: Roblox process-launch detection
        # Apply files the instant the process appears, before it reads them.
        # ---------------------------------------------------------------
        $robloxProc    = Get-Process -Name "RobloxPlayerBeta","Windows10Universal" -ErrorAction SilentlyContinue |
                         Select-Object -First 1
        $robloxRunning = $null -ne $robloxProc

        if ($robloxRunning -and -not $global:RobloxWasRunning) {
            # Process just appeared. Apply immediately.
            Write-Log "Roblox process detected (PID $($robloxProc.Id)) - applying presets now..."
            if ($global:CurrentVersionFolder) {
                Invoke-ApplyFiles $global:CurrentVersionFolder $global:Prefs
                Sync-FileLastSeen $global:CurrentVersionFolder
                Write-Log "Applied on Roblox launch."
            }
        }
        $global:RobloxWasRunning = $robloxRunning

        # ---------------------------------------------------------------
        # PHASE A: deferred re-apply has been scheduled - wait for deadline
        # ---------------------------------------------------------------
        if ($global:ReapplyPending) {
            if ($now -lt $global:ReapplyAt) { return }   # not yet - keep waiting

            $targetVer = $global:ReapplyFolder
            Write-Log "Re-apply deadline reached - applying to: $targetVer"
            Invoke-ApplyFiles $targetVer $global:Prefs
            Write-Log "Re-apply complete."

            $global:CurrentVersionFolder    = $targetVer
            $global:CurrentVersionFolderMod = (Get-Item $targetVer -EA SilentlyContinue).LastWriteTimeUtc
            Sync-FileLastSeen $targetVer

            $global:ReapplyPending = $false
            $global:ReapplyAt      = $null
            $global:ReapplyFolder  = $null

            # Update status label
            if ($script:statusLabel) {
                $anchor = Split-Path $targetVer -Leaf
                $script:statusLabel.Text     = "Status: Active - anchored to $anchor"
                $script:statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
            }
            return
        }

        # ---------------------------------------------------------------
        # PHASE B: version-folder check (update -> new folder, or same-
        # folder reinstall detected via the folder's own LastWriteTime)
        # ---------------------------------------------------------------
        $root2  = Get-VersionsRoot $global:Prefs.UseBloxstrap
        $newVer = Get-NewestVersionFolder $root2

        if ($newVer) {
            $newVerMod = (Get-Item $newVer -EA SilentlyContinue).LastWriteTimeUtc

            $isNewFolder     = ($newVer -ne $global:CurrentVersionFolder)
            $isSameFolderMod = ($newVer -eq $global:CurrentVersionFolder) -and
                               ($newVerMod -and $newVerMod -ne $global:CurrentVersionFolderMod)

            if ($isNewFolder -or $isSameFolderMod) {
                $reason = if ($isNewFolder) { "new version folder" } else { "same-folder reinstall" }
                Write-Log "Roblox $reason detected: $newVer - scheduling re-apply in 8s..."

                # Schedule deferred apply 8 seconds from now so Roblox has time
                # to finish writing all its default files before we overwrite them.
                $global:ReapplyPending = $true
                $global:ReapplyAt      = $now.AddSeconds(8)
                $global:ReapplyFolder  = $newVer

                # Pre-seed last-seen to null so that if the deadline fires and
                # files still aren't there we treat them as missing next cycle.
                $global:FileLastSeen = @{}
                foreach ($pair in (Get-WatchedPairs $global:Prefs $newVer)) {
                    $global:FileLastSeen[$pair.Dest] = $null
                }

                # Update folder-mod baseline to the new value so we don't
                # re-trigger on every subsequent tick while waiting.
                $global:CurrentVersionFolderMod = $newVerMod
                return
            }
        }

        if (-not $global:CurrentVersionFolder) { return }

        # ---------------------------------------------------------------
        # PHASE C: per-file poll - detect deletion or external overwrite
        # ---------------------------------------------------------------
        $pairs = Get-WatchedPairs $global:Prefs $global:CurrentVersionFolder

        foreach ($pair in $pairs) {
            $bp       = $pair.Backup
            $dest     = $pair.Dest
            $name     = Split-Path $dest -Leaf
            $exists   = Test-Path $dest
            $lastSeen = $global:FileLastSeen[$dest]
            $cool     = $global:RestoreCooldown[$name]
            $inCool   = $cool -and ($now - $cool).TotalSeconds -lt 4

            if (-not $exists) {
                # Skip while cooldown is active (we just wrote it; dest not
                # visible yet is normal for a fraction of a second).
                if ($inCool) { continue }
                if (-not (Test-Path $bp)) { Write-Log "Backup missing for ${name}." "WARN"; continue }
                Write-Log "Missing: $name - restoring..."
                if (Invoke-RestoreFile $bp $dest) {
                    $global:FileLastSeen[$dest] = (Get-Item $dest -EA SilentlyContinue).LastWriteTimeUtc
                }

            } elseif ($null -ne $lastSeen) {
                # File present - check if someone else changed it
                $mtime = (Get-Item $dest -EA SilentlyContinue).LastWriteTimeUtc
                if ($mtime -and $mtime -ne $lastSeen) {
                    if ($inCool) {
                        # Our own write settling - just update baseline
                        $global:FileLastSeen[$dest] = $mtime
                        continue
                    }
                    Write-Log "External overwrite on ${name} - restoring..."
                    if (-not (Test-Path $bp)) { Write-Log "Backup missing for ${name}." "WARN"; continue }
                    if (Invoke-RestoreFile $bp $dest) {
                        $global:FileLastSeen[$dest] = (Get-Item $dest -EA SilentlyContinue).LastWriteTimeUtc
                    }
                }
            } else {
                # lastSeen is $null meaning we previously knew it was absent,
                # and now it exists - Roblox wrote the default back. Overwrite.
                if ($inCool) { $global:FileLastSeen[$dest] = (Get-Item $dest -EA SilentlyContinue).LastWriteTimeUtc; continue }
                Write-Log "File reappeared (reinstall default): ${name} - restoring..."
                if (-not (Test-Path $bp)) { Write-Log "Backup missing for ${name}." "WARN"; continue }
                if (Invoke-RestoreFile $bp $dest) {
                    $global:FileLastSeen[$dest] = (Get-Item $dest -EA SilentlyContinue).LastWriteTimeUtc
                }
            }
        }
    })

    $global:WatchTimer.Start()
    Write-Log "Poll timer started (750ms interval)."
}

# -- EXIT ---------------------------------------------------------
function Invoke-AppExit {
    if ($global:AppExiting) { return }
    $global:AppExiting = $true
    try { $global:TrayIcon.Visible = $false } catch {}
    try { $global:TrayIcon.Dispose() } catch {}
    Stop-AllWatchers
    try { $script:AppMutex.ReleaseMutex(); $script:AppMutex.Dispose() } catch {}
    Write-Log "Application closed."
    [System.Windows.Forms.Application]::Exit()
    [System.Environment]::Exit(0)
}

# -- ICON ---------------------------------------------------------
# The app icon is embedded as base64 so no external .ico file is needed.
# It is decoded once at startup and shared for title bar, taskbar, and tray.
$script:IconBase64 = @'
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
'@

function New-AppIcon {
    try {
        $bytes  = [Convert]::FromBase64String($script:IconBase64.Trim())
        $stream = New-Object System.IO.MemoryStream(,$bytes)
        $icon   = New-Object System.Drawing.Icon($stream)
        return $icon
    } catch {
        Write-Log "Failed to decode embedded icon: $_" "WARN"
        # Fallback: blue dot
        $bmp = New-Object System.Drawing.Bitmap 16,16
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.FillEllipse([System.Drawing.Brushes]::DodgerBlue,1,10,5,4)
        $g.FillRectangle([System.Drawing.Brushes]::DodgerBlue,5,3,2,9)
        $g.FillEllipse([System.Drawing.Brushes]::DodgerBlue,7,3,4,3)
        $g.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
}

# -- DIRTY CHECK --------------------------------------------------
function Get-UISnapshot {
    $s  = @($script:CategoryPanels["Sounds"].Tag     | ForEach-Object { Split-Path "$_" -Leaf }) -join "|"
    $c  = @($script:CategoryPanels["Crosshairs"].Tag | ForEach-Object { Split-Path "$_" -Leaf }) -join "|"
    $p  = @($script:CategoryPanels["Particles"].Tag  | ForEach-Object { Split-Path "$_" -Leaf }) -join "|"
    $k  = @($script:CategoryPanels["Sky"].Tag        | ForEach-Object { Split-Path "$_" -Leaf }) -join "|"
    return "$s`0$c`0$p`0$k`0$($script:chkBloxstrap.Checked)`0$($script:chkActivate.Checked)`0$($script:chkStartup.Checked)"
}
function Update-ApplyButton {
    if ($null -ne $script:btnApply) { $script:btnApply.Enabled = (Get-UISnapshot) -ne $script:savedSnapshot }
}

# -- ROW LAYOUT ---------------------------------------------------
# Fixed columns: name 0..183 (with 4px left pad = 179px visible), status at 188, X at 318
$script:NameColWidth   = 184
$script:StatusColX     = 190
$script:StatusColWidth = 126
$script:XColX          = 318
$script:RowWidth       = 336

function Update-RowPositions([System.Windows.Forms.Panel]$Panel) {
    $y = 0
    foreach ($ctrl in $Panel.Controls) { $ctrl.Location = New-Object System.Drawing.Point(0,$y); $y += $ctrl.Height }
}

function Reset-PanelToSaved([string]$Cat, [string[]]$Paths) {
    $flp = $script:CategoryPanels[$Cat]
    if (-not $flp) { return }
    $flp.Controls.Clear()
    $flp.Tag = [System.Collections.ArrayList]::new()
    foreach ($bp in $Paths) { if ($bp) { Add-FileRowToPanel $flp $bp } }
}

function Add-FileRowToPanel([System.Windows.Forms.Panel]$Panel, [string]$BackupPath) {
    $font8     = New-Object System.Drawing.Font("Segoe UI", 8)
    $font8i    = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $font8b    = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $fileName  = Split-Path $BackupPath -Leaf

    $row       = New-Object System.Windows.Forms.Panel
    $row.Size  = New-Object System.Drawing.Size($script:RowWidth, 20)
    $row.Tag   = $BackupPath

    # Name: fixed width, padded left by 4px, AutoEllipsis
    $lblName              = New-Object System.Windows.Forms.Label
    $lblName.Text         = $fileName
    $lblName.AutoSize     = $false
    $lblName.Size         = New-Object System.Drawing.Size($script:NameColWidth, 18)
    $lblName.Location     = New-Object System.Drawing.Point(4, 1)
    $lblName.Font         = $font8
    $lblName.AutoEllipsis = $true
    $row.Controls.Add($lblName)

    # Status: fixed X position so all rows align
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "File preset active..."
    $lblStatus.AutoSize  = $false
    $lblStatus.Size      = New-Object System.Drawing.Size($script:StatusColWidth, 18)
    $lblStatus.Location  = New-Object System.Drawing.Point($script:StatusColX, 1)
    $lblStatus.Font      = $font8i
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray
    $row.Controls.Add($lblStatus)

    # Red X
    $btnX           = New-Object System.Windows.Forms.Label
    $btnX.Text      = "X"
    $btnX.AutoSize  = $false
    $btnX.Size      = New-Object System.Drawing.Size(16, 18)
    $btnX.Location  = New-Object System.Drawing.Point($script:XColX, 1)
    $btnX.Font      = $font8b
    $btnX.ForeColor = [System.Drawing.Color]::Red
    $btnX.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btnX.Tag       = $BackupPath
    $row.Controls.Add($btnX)

    $btnX.Add_Click({
        $flp = $this.Parent.Parent
        $flp.Tag.Remove($this.Tag) | Out-Null
        $r   = $this.Parent
        $flp.Controls.Remove($r)
        $r.Dispose()
        Update-RowPositions $flp
        Update-ApplyButton
    })

    $Panel.Controls.Add($row)
    if ($Panel.Tag -isnot [System.Collections.ArrayList]) { $Panel.Tag = [System.Collections.ArrayList]::new() }
    $Panel.Tag.Add($BackupPath) | Out-Null
    Update-RowPositions $Panel
}

# -- FILE LIST PANEL FACTORY --------------------------------------
$script:FlpMinHeight = 60
$script:FlpMaxHeight = 200
$script:DragState    = @{}
$script:DragStartY   = @{}
$script:DragStartH   = @{}
$script:PanelLastClick = @{}
$script:CategoryPanels = @{}
$script:PanelCategory  = @{}
$script:ReflowItems    = $null

function Invoke-ReflowPanel {
    if ($null -eq $script:ReflowItems) { return }

    # WinForms AutoScroll panels internally shift child control positions by the
    # current scroll offset when you read or write .Top / .Location. This means
    # setting ctrl.Top = $y while scrolled actually places the control at
    # ($y + scrollY) in logical space, causing the gap bug.
    # Fix: snap the scroll back to (0,0) before doing any layout, then restore it.
    $savedScroll = New-Object System.Drawing.Point(0, 0)
    if ($script:ScrollPanel) {
        $savedScroll = New-Object System.Drawing.Point(
            -$script:ScrollPanel.AutoScrollPosition.X,
            -$script:ScrollPanel.AutoScrollPosition.Y)
        $script:ScrollPanel.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    }

    $y = 10
    foreach ($item in $script:ReflowItems) {
        $ctrl = $item.Control

        # Shadow items share a row with a previous control
        if ($item.ContainsKey('ShadowOf') -and $null -ne $item.ShadowOf) {
            $ctrl.Top  = $item.ShadowOf.Top
            $ctrl.Left = $item.OffsetX
            continue
        }

        $ctrl.Top = $y

        # For section container panels (Tag = category string), sync height to inner wrapper
        if ($ctrl -is [System.Windows.Forms.Panel] -and $ctrl.Tag -is [string] -and
            $ctrl.Tag -ne '' -and $ctrl.Controls.Count -gt 0) {
            $innerWrapper = $ctrl.Controls[0]
            if ($innerWrapper -is [System.Windows.Forms.Panel]) {
                $ctrl.Height = $innerWrapper.Height
            }
        }

        $y += $ctrl.Height + $item.Gap
    }

    if ($script:ScrollPanel) {
        $script:ScrollPanel.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($y + 20))
        $script:ScrollPanel.AutoScrollPosition = $savedScroll
    }
}

function New-FileListPanelWrapper([int]$xPos, [int]$yPos, [string[]]$InitPaths, [string]$Cat) {
    $initH   = 60
    $wrapper = New-Object System.Windows.Forms.Panel
    $wrapper.Location = New-Object System.Drawing.Point($xPos, $yPos)
    $wrapper.Size     = New-Object System.Drawing.Size(360, ($initH + 6))

    $flp = New-Object System.Windows.Forms.Panel
    $flp.Location    = New-Object System.Drawing.Point(0,0)
    $flp.Size        = New-Object System.Drawing.Size(360, $initH)
    $flp.AutoScroll  = $true
    $flp.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $flp.BackColor   = [System.Drawing.SystemColors]::Window
    $flp.Tag         = [System.Collections.ArrayList]::new()

    $flp.Add_MouseWheel({
        $cur  = $this.AutoScrollPosition
        $newY = [Math]::Max(0, -$cur.Y - ($_.Delta / 3))
        $this.AutoScrollPosition = New-Object System.Drawing.Point(0, [int]$newY)
    })
    $flp.Add_Click({
        $now = [DateTime]::UtcNow
        $last = $script:PanelLastClick[$this]
        if ($last -and ($now - $last).TotalSeconds -lt 2) { return }
        $script:PanelLastClick[$this] = $now
        $dir = Get-CategoryFolder $script:PanelCategory[$this]
        if ($dir -and (Test-Path $dir)) { Start-Process explorer.exe $dir }
        else { [System.Windows.Forms.MessageBox]::Show("Folder not found. Is Roblox installed-","Roblox Client Assistant",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null }
    })
    $script:PanelCategory[$flp]    = $Cat
    $script:CategoryPanels[$Cat]   = $flp
    foreach ($bp in $InitPaths) { if ($bp) { Add-FileRowToPanel $flp $bp } }
    $wrapper.Controls.Add($flp)

    $handle = New-Object System.Windows.Forms.Panel
    $handle.Location  = New-Object System.Drawing.Point(0, $initH)
    $handle.Size      = New-Object System.Drawing.Size(360, 6)
    $handle.BackColor = [System.Drawing.Color]::Transparent
    $handle.Cursor    = [System.Windows.Forms.Cursors]::SizeNS
    $wrapper.Controls.Add($handle)

    $handle.Add_MouseDown({
        $script:DragState[$this]  = $true
        $script:DragStartY[$this] = [System.Windows.Forms.Cursor]::Position.Y
        $script:DragStartH[$this] = $this.Parent.Controls[0].Height
    })
    $handle.Add_MouseMove({
        if (-not $script:DragState[$this]) { return }
        $newH = [Math]::Max($script:FlpMinHeight,[Math]::Min($script:FlpMaxHeight,
                $script:DragStartH[$this] + ([System.Windows.Forms.Cursor]::Position.Y - $script:DragStartY[$this])))
        $w = $this.Parent   # wrapper panel
        $f = $w.Controls[0] # flp (file list panel)
        $f.Height    = $newH
        $this.Top    = $newH
        $w.Height    = $newH + 6
        # Keep the outer container (section panel) in sync so reflow sees the right height
        $container = $w.Parent
        if ($container -and $container -isnot [System.Windows.Forms.Form]) {
            $container.Height = $newH + 6
        }
        Invoke-ReflowPanel
    })
    $handle.Add_MouseUp({ $script:DragState[$this] = $false })

    return $wrapper
}

# -- BUILD MAIN FORM ----------------------------------------------
function New-MainForm([hashtable]$Prefs) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = "Roblox Client Assistant"
    $form.Size          = New-Object System.Drawing.Size(520, 680)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox   = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.ShowInTaskbar = $true
    # Use the embedded icon for the title bar corner
    $form.Icon = New-AppIcon

    # X button -> minimize to tray (use $this, not $form, to avoid null ref)
    $form.Add_FormClosing({
        param($s,$e)
        if (-not $global:AppExiting) {
            $e.Cancel = $true
            $this.Hide()
            Write-Log "Minimized to tray."
        }
    })

    # Menu bar
    $menuStrip = New-Object System.Windows.Forms.MenuStrip
    $mFile     = New-Object System.Windows.Forms.ToolStripMenuItem("File")
    $mExit     = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
    $mExit.Add_Click({ Invoke-AppExit })
    $mFile.DropDownItems.Add($mExit) | Out-Null
    $mTools    = New-Object System.Windows.Forms.ToolStripMenuItem("Tools")
    $mLogs     = New-Object System.Windows.Forms.ToolStripMenuItem("View Debug Log")
    $mLogs.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } else { [System.Windows.Forms.MessageBox]::Show("No log entries yet.","Debug Log",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) } })
    $mClear    = New-Object System.Windows.Forms.ToolStripMenuItem("Clear Debug Log")
    $mClear.Add_Click({ if (([System.Windows.Forms.MessageBox]::Show("Clear the debug log-","Confirm",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)) -eq "Yes") { Set-Content -Path $LogFile -Value "" -EA SilentlyContinue } })
    $mContact  = New-Object System.Windows.Forms.ToolStripMenuItem("Contact")
    $mContact.Add_Click({ Start-Process $script:DownloadRepoUrl })
    $mTools.DropDownItems.Add($mLogs) | Out-Null; $mTools.DropDownItems.Add($mClear) | Out-Null
    $mTools.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $mTools.DropDownItems.Add($mContact) | Out-Null
    $menuStrip.Items.Add($mFile) | Out-Null; $menuStrip.Items.Add($mTools) | Out-Null
    $form.Controls.Add($menuStrip); $form.MainMenuStrip = $menuStrip

    # Outer scrollable panel
    $script:ScrollPanel = New-Object System.Windows.Forms.Panel
    $script:ScrollPanel.Location = New-Object System.Drawing.Point(0,28)
    $script:ScrollPanel.Size     = New-Object System.Drawing.Size(504,620)
    $script:ScrollPanel.AutoScroll = $true
    $form.Controls.Add($script:ScrollPanel)
    $script:ScrollPanel.Add_MouseWheel({
        $cur  = $this.AutoScrollPosition
        $newY = [Math]::Max(0, -$cur.Y - ($_.Delta / 3))
        $this.AutoScrollPosition = New-Object System.Drawing.Point(0, [int]$newY)
    })
    $sp = $script:ScrollPanel

    # Create checkboxes early (needed by Get-CategoryFolder)
    $script:chkBloxstrap = New-Object System.Windows.Forms.CheckBox
    $script:chkBloxstrap.Text    = "I use Bloxstrap as my primary bootstrapper"
    $script:chkBloxstrap.Checked = $Prefs.UseBloxstrap
    $script:chkBloxstrap.Size    = New-Object System.Drawing.Size(380,22)

    $script:chkActivate = New-Object System.Windows.Forms.CheckBox
    $script:chkActivate.Text    = "Enable active replacement utility"
    $script:chkActivate.Checked = $Prefs.Activated
    $script:chkActivate.Size    = New-Object System.Drawing.Size(320,22)

    $script:chkStartup = New-Object System.Windows.Forms.CheckBox
    $script:chkStartup.Text    = "Launch on startup"
    $script:chkStartup.Checked = Get-StartupEnabled
    $script:chkStartup.Size    = New-Object System.Drawing.Size(320,22)

    $script:ReflowItems = [System.Collections.ArrayList]::new()
    $y = 10

    # -- Section builder ------------------------------------------
    function Add-Section([string]$LblText, [int]$yPos, [string[]]$InitPaths, [string]$Cat) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $LblText; $lbl.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
        $lbl.Location = New-Object System.Drawing.Point(12,$yPos); $lbl.Size = New-Object System.Drawing.Size(460,18)
        $sp.Controls.Add($lbl)
        $script:ReflowItems.Add(@{Control=$lbl;Gap=4}) | Out-Null

        # Container holds wrapper + buttons side by side
        $container = New-Object System.Windows.Forms.Panel
        $container.Location = New-Object System.Drawing.Point(12,($yPos+22))
        $container.Size     = New-Object System.Drawing.Size(468,66)
        $container.Tag      = $Cat
        $sp.Controls.Add($container)
        $script:ReflowItems.Add(@{Control=$container;Gap=8}) | Out-Null

        $wrapper = New-FileListPanelWrapper 0 0 $InitPaths $Cat
        $container.Controls.Add($wrapper)

        $btnC = New-Object System.Windows.Forms.Button; $btnC.Text="Choose Files"
        $btnC.Location=New-Object System.Drawing.Point(364,0); $btnC.Size=New-Object System.Drawing.Size(100,26)
        $btnC.Tag=$Cat; $container.Controls.Add($btnC)

        $btnC.Add_Click({
            $cat = $this.Tag
            $flp = $script:CategoryPanels[$cat]
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Multiselect=$true; $dlg.Title="Select files for $cat"
            if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

            # Validate BEFORE importing
            $errs   = [System.Collections.Generic.List[string]]::new()
            $destDir = Get-CategoryFolder $cat
            foreach ($f in $dlg.FileNames) {
                $name = Split-Path $f -Leaf
                if ($script:CheckProofFiles -contains $name) { continue }
                if (-not $destDir -or -not (Test-Path $destDir)) {
                    $errs.Add("Could not find $cat folder. Is Roblox installed-"); break
                }
                if (-not (Test-Path (Join-Path $destDir $name))) {
                    $short = ($destDir -split '\\' | Select-Object -Last 2) -join "\"
                    $errs.Add("Error! A file matching the name and format '$name' was not found in ...\$short`nCheck that the name and file format both match.")
                }
            }
            if ($errs.Count -gt 0) {
                [System.Windows.Forms.MessageBox]::Show(($errs -join "`n`n"),"Validation Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
                return
            }
            foreach ($f in $dlg.FileNames) {
                $bp = Import-ToBackup $f
                $bpLeaf = Split-Path $bp -Leaf
                if (-not (@($flp.Tag) | Where-Object { (Split-Path $_ -Leaf) -eq $bpLeaf })) {
                    Add-FileRowToPanel $flp $bp
                }
            }
            Update-ApplyButton
        })

        $btnX2 = New-Object System.Windows.Forms.Button; $btnX2.Text="Clear"
        $btnX2.Location=New-Object System.Drawing.Point(364,30); $btnX2.Size=New-Object System.Drawing.Size(100,26)
        $btnX2.Tag=$Cat; $container.Controls.Add($btnX2)
        $btnX2.Add_Click({
            $flp = $script:CategoryPanels[$this.Tag]
            $flp.Controls.Clear(); $flp.Tag = [System.Collections.ArrayList]::new()
            Update-ApplyButton
        })

        return $container
    }

    $wS = Add-Section "Action Audios:" $y $Prefs.SoundFiles     "Sounds";     $y += 22 + $wS.Height + 8
    $wC = Add-Section "Crosshairs:"    $y $Prefs.CrosshairFiles "Crosshairs"; $y += 22 + $wC.Height + 8
    $wP = Add-Section "Particles:"     $y $Prefs.ParticleFiles  "Particles";  $y += 22 + $wP.Height + 8
    $wK = Add-Section "Sky Textures:"  $y $Prefs.SkyFiles       "Sky";        $y += 22 + $wK.Height + 14

    # Note label (full width, own row)
    $noteLabel = New-Object System.Windows.Forms.Label
    $noteLabel.Text = "Names must match the files you're trying to replace!"
    $noteLabel.Location = New-Object System.Drawing.Point(12,$y); $noteLabel.Size = New-Object System.Drawing.Size(468,18)
    $noteLabel.ForeColor = [System.Drawing.Color]::DarkRed
    $sp.Controls.Add($noteLabel)
    $script:ReflowItems.Add(@{Control=$noteLabel;Gap=6}) | Out-Null
    $y += 24

    # Reset All button + prerel version label on the same row
    $btnReset = New-Object System.Windows.Forms.Button; $btnReset.Text="Reset All"
    $btnReset.Location=New-Object System.Drawing.Point(12,$y); $btnReset.Size=New-Object System.Drawing.Size(180,26)
    $sp.Controls.Add($btnReset)
    $script:ReflowItems.Add(@{Control=$btnReset;Gap=8}) | Out-Null

    $lblVersion = New-Object System.Windows.Forms.Label
    $lblVersion.Text = "v$($script:AppVersion)"
    $lblVersion.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
    $lblVersion.ForeColor = [System.Drawing.Color]::Gray
    $lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $lblVersion.Location = New-Object System.Drawing.Point(200,$y)
    $lblVersion.Size = New-Object System.Drawing.Size(280,26)
    $sp.Controls.Add($lblVersion)
    # lblVersion shadows btnReset on the same row â€” track it via a paired-control entry
    $script:ReflowItems.Add(@{Control=$lblVersion;Gap=0;ShadowOf=$btnReset;OffsetX=200}) | Out-Null
    $btnReset.Add_Click({
        $sv = Load-Prefs
        Reset-PanelToSaved "Sounds"     $sv.SoundFiles
        Reset-PanelToSaved "Crosshairs" $sv.CrosshairFiles
        Reset-PanelToSaved "Particles"  $sv.ParticleFiles
        Reset-PanelToSaved "Sky"        $sv.SkyFiles
        foreach ($cat in @("Sounds","Crosshairs","Particles","Sky")) {
            $flp = $script:CategoryPanels[$cat]
            if ($flp) {
                $flp.Height = 60
                $wrapper = $flp.Parent   # wrapper panel
                $wrapper.Height = 66
                $handle = $wrapper.Controls[1]  # drag handle
                if ($handle) { $handle.Top = 60 }
                $container = $wrapper.Parent    # section container
                if ($container) { $container.Height = 66 }
            }
        }
        Invoke-ReflowPanel; Update-ApplyButton
    })
    $y += 32

    # Sep1
    $sep1 = New-Object System.Windows.Forms.Label; $sep1.BorderStyle=[System.Windows.Forms.BorderStyle]::Fixed3D
    $sep1.Location=New-Object System.Drawing.Point(12,$y); $sep1.Size=New-Object System.Drawing.Size(468,2)
    $sp.Controls.Add($sep1); $script:ReflowItems.Add(@{Control=$sep1;Gap=10}) | Out-Null; $y += 12

    # Tooltips
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($script:chkActivate,  "When checked, the app actively monitors your client files and restores your custom versions whenever they are modified or deleted by a Roblox update.")
    $tip.SetToolTip($script:chkBloxstrap, "Check this if you launch Roblox through Bloxstrap. Changes all watched folder paths from Roblox\Versions to Bloxstrap\Versions.")
    $tip.SetToolTip($script:chkStartup,   "When checked, this app starts automatically in the system tray every time you log into Windows.")

    # Checkboxes
    $script:chkActivate.Location  = New-Object System.Drawing.Point(12,$y); $sp.Controls.Add($script:chkActivate)
    $script:ReflowItems.Add(@{Control=$script:chkActivate;Gap=0}) | Out-Null; $y+=28
    $script:chkBloxstrap.Location = New-Object System.Drawing.Point(12,$y); $sp.Controls.Add($script:chkBloxstrap)
    $script:ReflowItems.Add(@{Control=$script:chkBloxstrap;Gap=0}) | Out-Null; $y+=28
    $script:chkStartup.Location   = New-Object System.Drawing.Point(12,$y); $sp.Controls.Add($script:chkStartup)
    $script:ReflowItems.Add(@{Control=$script:chkStartup;Gap=8}) | Out-Null; $y+=28

    # Sep2
    $sep2 = New-Object System.Windows.Forms.Label; $sep2.BorderStyle=[System.Windows.Forms.BorderStyle]::Fixed3D
    $sep2.Location=New-Object System.Drawing.Point(12,$y); $sep2.Size=New-Object System.Drawing.Size(468,2)
    $sp.Controls.Add($sep2); $script:ReflowItems.Add(@{Control=$sep2;Gap=12}) | Out-Null; $y+=12

    # Status
    $script:statusLabel = New-Object System.Windows.Forms.Label
    $script:statusLabel.Text="Status: Not applied yet."; $script:statusLabel.ForeColor=[System.Drawing.Color]::Gray
    $script:statusLabel.Location=New-Object System.Drawing.Point(12,$y); $script:statusLabel.Size=New-Object System.Drawing.Size(460,18)
    $sp.Controls.Add($script:statusLabel); $script:ReflowItems.Add(@{Control=$script:statusLabel;Gap=10}) | Out-Null; $y+=28

    # Apply
    $script:btnApply = New-Object System.Windows.Forms.Button
    $script:btnApply.Text="Apply Changes"; $script:btnApply.BackColor=[System.Drawing.SystemColors]::Control
    $script:btnApply.FlatStyle=[System.Windows.Forms.FlatStyle]::Standard
    $script:btnApply.Location=New-Object System.Drawing.Point(12,$y); $script:btnApply.Size=New-Object System.Drawing.Size(468,30)
    $sp.Controls.Add($script:btnApply); $script:ReflowItems.Add(@{Control=$script:btnApply;Gap=10}) | Out-Null; $y+=42

    $sp.AutoScrollMinSize = New-Object System.Drawing.Size(0,$y)

    # Run reflow once immediately so all controls start at their correct positions
    Invoke-ReflowPanel

    # Dirty check init
    $script:savedSnapshot = ""
    if (Test-Path $PrefsFile) {
        $sv = Load-Prefs
        $script:savedSnapshot  = ($sv.SoundFiles     | ForEach-Object { Split-Path $_ -Leaf }) -join "|"
        $script:savedSnapshot += "`0$(($sv.CrosshairFiles | ForEach-Object { Split-Path $_ -Leaf }) -join '|')"
        $script:savedSnapshot += "`0$(($sv.ParticleFiles  | ForEach-Object { Split-Path $_ -Leaf }) -join '|')"
        $script:savedSnapshot += "`0$(($sv.SkyFiles       | ForEach-Object { Split-Path $_ -Leaf }) -join '|')"
        $script:savedSnapshot += "`0$($sv.UseBloxstrap)`0$($sv.Activated)`0$($sv.RunOnStartup)"
        $script:btnApply.Enabled = $false
    }

    $script:chkActivate.Add_CheckedChanged({  Update-ApplyButton })
    $script:chkBloxstrap.Add_CheckedChanged({ Update-ApplyButton })
    $script:chkStartup.Add_CheckedChanged({   Update-ApplyButton })

    # Apply logic
    $script:btnApply.Add_Click({
        $useBlox   = $script:chkBloxstrap.Checked
        $activated = $script:chkActivate.Checked
        $startup   = $script:chkStartup.Checked
        $sP = @($script:CategoryPanels["Sounds"].Tag     | ForEach-Object { "$_" })
        $cP = @($script:CategoryPanels["Crosshairs"].Tag | ForEach-Object { "$_" })
        $pP = @($script:CategoryPanels["Particles"].Tag  | ForEach-Object { "$_" })
        $kP = @($script:CategoryPanels["Sky"].Tag        | ForEach-Object { "$_" })

        $root    = Get-VersionsRoot $useBlox
        $ver     = Get-NewestVersionFolder $root
        $sub     = if ($ver) { Get-SubPaths $ver } else { $null }
        $errList = [System.Collections.Generic.List[string]]::new()

        if ($sub) {
            Invoke-ValidateFiles $sP $sub.Sounds     "Action Audios" $errList
            Invoke-ValidateFiles $cP $sub.Crosshairs "Crosshairs"    $errList
            Invoke-ValidateFiles $pP $sub.Particles  "Particles"     $errList
            Invoke-ValidateFiles $kP $sub.Sky        "Sky Textures"  $errList
        } elseif (($sP.Count+$cP.Count+$pP.Count+$kP.Count) -gt 0) {
            $errList.Add("Could not locate a Roblox$(if($useBlox){'/Bloxstrap'}) version folder. Is Roblox installed-")
        }

        if ($errList.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(($errList -join "`n`n"),"Validation Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            return
        }

        $global:Prefs = @{ UseBloxstrap=$useBlox; Activated=$activated; RunOnStartup=$startup; SoundFiles=$sP; CrosshairFiles=$cP; ParticleFiles=$pP; SkyFiles=$kP }
        Save-Prefs $global:Prefs; Set-StartupEnabled $startup; Write-Log "Preferences saved."

        $script:savedSnapshot  = ($sP | ForEach-Object { Split-Path $_ -Leaf }) -join "|"
        $script:savedSnapshot += "`0$(($cP | ForEach-Object { Split-Path $_ -Leaf }) -join '|')"
        $script:savedSnapshot += "`0$(($pP | ForEach-Object { Split-Path $_ -Leaf }) -join '|')"
        $script:savedSnapshot += "`0$(($kP | ForEach-Object { Split-Path $_ -Leaf }) -join '|')"
        $script:savedSnapshot += "`0$useBlox`0$activated`0$startup"
        $script:btnApply.Enabled = $false

        if ($activated) {
            Start-Watching $global:Prefs
            $anchor = if ($global:CurrentVersionFolder) { Split-Path $global:CurrentVersionFolder -Leaf } else { "unknown" }
            $script:statusLabel.Text="Status: Active - anchored to $anchor"; $script:statusLabel.ForeColor=[System.Drawing.Color]::DarkGreen
            $global:miStatus.Text="Status: Active"
        } else {
            Stop-AllWatchers
            $script:statusLabel.Text="Status: Deactivated."; $script:statusLabel.ForeColor=[System.Drawing.Color]::DarkOrange
            $global:miStatus.Text="Status: Inactive"
        }

        [System.Windows.Forms.MessageBox]::Show("Changes applied successfully!","Roblox Client Assistant",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::None) | Out-Null
    })

    return $form
}

# -- TRAY ---------------------------------------------------------
$global:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$global:TrayIcon.Icon    = New-AppIcon
$global:TrayIcon.Text    = "Roblox Client Assistant"
$global:TrayIcon.Visible = $true

$ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen  = New-Object System.Windows.Forms.ToolStripMenuItem("Open")
$miOpen.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$miOpen.Add_Click({ $global:MainForm.Show(); $global:MainForm.WindowState="Normal"; $global:MainForm.BringToFront() })
$ctxMenu.Items.Add($miOpen) | Out-Null
$ctxMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$global:miStatus = New-Object System.Windows.Forms.ToolStripMenuItem("Status: Initializing...")
$global:miStatus.Enabled = $false
$ctxMenu.Items.Add($global:miStatus) | Out-Null
$ctxMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miClose = New-Object System.Windows.Forms.ToolStripMenuItem("Close")
$miClose.Add_Click({ Invoke-AppExit })
$ctxMenu.Items.Add($miClose) | Out-Null
$global:TrayIcon.ContextMenuStrip = $ctxMenu
$global:TrayIcon.Add_MouseClick({
    param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $global:MainForm.Show(); $global:MainForm.WindowState="Normal"; $global:MainForm.BringToFront()
    }
})

# -- LAUNCH -------------------------------------------------------
$global:Prefs    = Load-Prefs
$global:MainForm = New-MainForm $global:Prefs
Write-Log "Application started."

if ($global:Prefs.Activated -and ($global:Prefs.SoundFiles.Count+$global:Prefs.CrosshairFiles.Count+$global:Prefs.ParticleFiles.Count+$global:Prefs.SkyFiles.Count) -gt 0) {
    Start-Watching $global:Prefs; $global:miStatus.Text="Status: Active"; Write-Log "Auto-activated on launch."
} else { $global:miStatus.Text="Status: Inactive" }

# Show the window when first launched (not hidden to tray)
$global:MainForm.Text = "Roblox Client Assistant"
$global:MainForm.Show()
$global:MainForm.BringToFront()
Start-UpdateCheckTimer

[System.Windows.Forms.Application]::Run()

# Release the single-instance mutex on clean exit
try { $script:AppMutex.ReleaseMutex(); $script:AppMutex.Dispose() } catch {}



