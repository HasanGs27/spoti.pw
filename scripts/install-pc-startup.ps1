param(
    [Parameter(Mandatory=$true)][ValidateSet('check','enable','disable')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Python,
    [Parameter(Mandatory=$true)][string]$Launcher,
    [Parameter(Mandatory=$true)][string]$Workspace,
    [Parameter(Mandatory=$true)][string]$Arguments,
    [Parameter(Mandatory=$true)][string]$Owner,
    [string]$StartupDirectory
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not $StartupDirectory) { $StartupDirectory = [Environment]::GetFolderPath('Startup') }
if (-not $StartupDirectory) { throw 'Startup directory unavailable.' }
$startupPath = [IO.Path]::GetFullPath($StartupDirectory)
$linkPath = Join-Path $startupPath 'Spoti - telechargements PC.lnk'
$description = 'spoti.pw PC companion v1 | ' + $Owner
$exists = Test-Path -LiteralPath $linkPath
$owned = $false
$shell = New-Object -ComObject WScript.Shell
try {
    if ($exists) {
        $file = Get-Item -LiteralPath $linkPath
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Startup entry is not a regular shortcut.'
        }
        $shortcut = $shell.CreateShortcut($linkPath)
        $owned = ($shortcut.Description -ceq $description) -and
                 ($shortcut.TargetPath -ieq [IO.Path]::GetFullPath($Python)) -and
                 ($shortcut.WorkingDirectory -ieq [IO.Path]::GetFullPath($Workspace)) -and
                 ($shortcut.Arguments -ceq $Arguments)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    }
    if (($Mode -ne 'check') -and $exists -and -not $owned) {
        throw 'Another startup entry owns this name; nothing was changed.'
    }
    if ($Mode -eq 'enable' -and -not $exists) {
        foreach ($path in @($Python, $Launcher)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Required launcher file missing.' }
        }
        if (-not (Test-Path -LiteralPath $startupPath -PathType Container)) {
            throw 'Startup directory missing; nothing was changed.'
        }
        $shortcut = $shell.CreateShortcut($linkPath)
        $shortcut.TargetPath = [IO.Path]::GetFullPath($Python)
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = [IO.Path]::GetFullPath($Workspace)
        $shortcut.Description = $description
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        $exists = $true
        $owned = $true
    }
    if ($Mode -eq 'disable' -and $exists -and $owned) {
        Remove-Item -LiteralPath $linkPath
        $exists = $false
        $owned = $false
    }
    @{enabled=($exists -and $owned); owned=$owned; conflict=($exists -and -not $owned); available=$true} | ConvertTo-Json -Compress
} finally {
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}
