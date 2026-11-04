# AHWatch auto-updater (Windows)
# Lives inside the AHWatch addon folder. Each run it:
#   1. Checks GitHub for a newer AHWatch and installs it (the old copy is backed up)
#   2. Sets "## Interface:" in AHWatch.toc to match the game, so it isn't "out of date"
# then closes.
#
#   updater.ps1        run a check (this is what runs at Windows startup)
#   updater.ps1 -On    run at Windows startup from now on
#   updater.ps1 -Off   stop running at Windows startup

param([switch]$On, [switch]$Off)

$Repo   = "Lubithmann-afk/WoW-Addon"
$Branch = "main"

$ErrorActionPreference = "Stop"
# Never sit inside the addon folder - Windows won't let a folder be replaced while it's in use
Set-Location $env:TEMP

$AddonDir  = $PSScriptRoot                                    # ...\Interface\AddOns\AHWatch
$GameDir   = Split-Path (Split-Path (Split-Path $AddonDir -Parent) -Parent) -Parent
$TocPath   = Join-Path $AddonDir "AHWatch.toc"
$DataDir   = Join-Path $env:LOCALAPPDATA "AHWatchUpdater"
$LogFile   = Join-Path $DataDir "updater.log"
$BackupDir = Join-Path $DataDir "backups"
$StartLink = Join-Path ([Environment]::GetFolderPath("Startup")) "AHWatch auto-update.lnk"
$script:HadProblem = $false

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

function Log([string]$text, [string]$color = "Gray") {
    Write-Host $text -ForegroundColor $color
    try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text) } catch {}
}
function Problem([string]$text) { $script:HadProblem = $true; Log $text "Yellow" }

function Read-TocField([string]$path, [string]$field) {
    if (-not (Test-Path $path)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line -match "^##\s*$field\s*:\s*(.+?)\s*$") { return $Matches[1] }
    }
    return $null
}
function Read-TocFieldFromText([string]$text, [string]$field) {
    $m = [regex]::Match($text, "(?m)^##\s*$field\s*:\s*(.+?)\s*$")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
function To-Version([string]$s) {
    if (-not $s) { return [version]"0.0" }
    $m = [regex]::Match($s, "\d+(\.\d+){0,3}")
    if (-not $m.Success) { return [version]"0.0" }
    $v = $m.Value
    if ($v -notmatch "\.") { $v = "$v.0" }
    return [version]$v
}

# The interface number the game is on: WoW saves it in WTF\Config.wtf; AHWatch
# also saves it in its own saved data whenever it loads, as a fallback
function Get-GameInterface {
    $cfg = Join-Path $GameDir "WTF\Config.wtf"
    if (Test-Path $cfg) {
        $m = Select-String -Path $cfg -Pattern 'SET\s+lastAddonVersion\s+"(\d+)"' | Select-Object -First 1
        if ($m) { return [int]$m.Matches[0].Groups[1].Value }
    }
    $best = 0
    $acct = Join-Path $GameDir "WTF\Account"
    if (Test-Path $acct) {
        Get-ChildItem -Path $acct -Recurse -Filter "AHWatch.lua" -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -like "*SavedVariables" } |
            ForEach-Object {
                $m = Select-String -Path $_.FullName -Pattern '\["clientToc"\]\s*=\s*(\d+)' | Select-Object -First 1
                if ($m) { $n = [int]$m.Matches[0].Groups[1].Value; if ($n -gt $best) { $best = $n } }
            }
    }
    if ($best -gt 0) { return $best }
    return $null
}

function Fix-Interface {
    if (-not (Test-Path $TocPath)) { return }
    $iface = Get-GameInterface
    if (-not $iface) { Log "Game's interface number not known yet - it'll be fixed after WoW has run once."; return }
    $current = Read-TocField $TocPath "Interface"
    if ($current -eq "$iface") { Log "Interface number matches the game ($iface)."; return }
    $text = [IO.File]::ReadAllText($TocPath)
    if ($text -match "(?m)^##\s*Interface\s*:") {
        $text = [regex]::Replace($text, "(?m)^##\s*Interface\s*:[^\r\n]*", "## Interface: $iface")
    } else {
        $text = "## Interface: $iface`r`n" + $text
    }
    [IO.File]::WriteAllText($TocPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Log "Interface number updated: $current -> $iface" "Green"
}

function Finish {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) {
            $lines = @(Get-Content $LogFile)
            $lines[($lines.Count - 500)..($lines.Count - 1)] | Set-Content $LogFile
        }
    } catch {}
    if ($script:HadProblem) { Log "Closing in 20 seconds. (Log: $LogFile)" "Yellow"; Start-Sleep -Seconds 20 }
    else { Start-Sleep -Seconds 3 }
    exit 0
}

# ------------------------------------------------------------- on / off
if ($On) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($StartLink)
    $lnk.TargetPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $env:TEMP
    $lnk.WindowStyle = 7    # minimized
    $lnk.Description = "Keeps the AHWatch addon up to date"
    $lnk.Save()
    Log "Auto-update is ON. AHWatch will check for updates each time Windows starts." "Green"
    Fix-Interface
    Finish
}
if ($Off) {
    if (Test-Path $StartLink) { Remove-Item -Force $StartLink }
    Log "Auto-update is OFF." "Green"
    Finish
}

# The addon was deleted but the startup shortcut is still there: tidy up quietly
if (-not (Test-Path $TocPath)) {
    if (Test-Path $StartLink) { Remove-Item -Force $StartLink -ErrorAction SilentlyContinue }
    exit 0
}

# ------------------------------------------------------------- check GitHub
Log "---- AHWatch auto-update ----" "Cyan"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ua = @{ "User-Agent" = "AHWatch-Updater" }

$installed = Read-TocField $TocPath "Version"
Log "Installed: $installed"

$remoteToc = $null
for ($try = 1; $try -le 3 -and -not $remoteToc; $try++) {
    try {
        $remoteToc = (Invoke-WebRequest -UseBasicParsing -Headers $ua -TimeoutSec 20 `
            -Uri "https://raw.githubusercontent.com/$Repo/$Branch/AHWatch/AHWatch.toc").Content
    } catch {
        if ($try -lt 3) { Log "Can't reach GitHub yet (try $try of 3), waiting for the network..."; Start-Sleep -Seconds 10 }
        else { Problem "Couldn't reach GitHub: $($_.Exception.Message)" }
    }
}

if ($remoteToc) {
    $latest = Read-TocFieldFromText $remoteToc "Version"
    Log "On GitHub: $latest"
    if ((To-Version $latest) -le (To-Version $installed)) {
        Log "AHWatch is up to date." "Green"
    } else {
        $work = Join-Path $env:TEMP ("AHWatchUpdate_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        try {
            $zip = Join-Path $work "ahwatch.zip"
            Log "Downloading AHWatch $latest..."
            Invoke-WebRequest -UseBasicParsing -Headers $ua -TimeoutSec 180 `
                -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip
            $unz = Join-Path $work "unzipped"
            Expand-Archive -Path $zip -DestinationPath $unz -Force
            $newToc = Get-ChildItem -Path $unz -Recurse -Filter "AHWatch.toc" |
                Where-Object { $_.Directory.Name -eq "AHWatch" } |
                Sort-Object { $_.FullName.Length } | Select-Object -First 1
            if (-not $newToc) { throw "the download doesn't contain the AHWatch folder" }

            # Back up the current copy, then swap in the new one (put the old one back if that fails)
            New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
            $backup = Join-Path $BackupDir ("AHWatch-{0}-{1}" -f $installed, (Get-Date -Format "yyyyMMdd-HHmmss"))
            Move-Item -Path $AddonDir -Destination $backup
            try {
                Copy-Item -Path $newToc.DirectoryName -Destination $AddonDir -Recurse -Force
            } catch {
                if (Test-Path $AddonDir) { Remove-Item -Recurse -Force $AddonDir }
                Move-Item -Path $backup -Destination $AddonDir
                throw
            }
            Log "Updated AHWatch $installed -> $latest" "Green"
            Get-ChildItem -Path $BackupDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
                ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
        } catch {
            Problem "Update failed, AHWatch was left as it was: $($_.Exception.Message)"
        } finally {
            Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        }
    }
}

# After any update, so a fresh download gets the right number too
try { Fix-Interface } catch { Problem "Couldn't update the interface number: $($_.Exception.Message)" }
Log "Done." "Green"
Finish
