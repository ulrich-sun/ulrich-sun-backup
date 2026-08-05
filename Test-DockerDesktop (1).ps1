#requires -Version 5.1
<#
.SYNOPSIS
    Banc d'essai et diagnostic de Docker Desktop sous Windows (backend WSL2).

.DESCRIPTION
    Ce script pousse Docker Desktop et la machine hote dans leurs retranchements
    afin de produire un rapport factuel sur :
      - la configuration de l'hote, de WSL2 et de Docker Desktop
      - la latence de demarrage des conteneurs (cold start)
      - le comportement CPU sous saturation et le respect des limites --cpus
      - la pression memoire, l'OOM-kill et la restitution de la RAM par Vmmem
      - les performances disque : volume nomme vs bind mount Windows
      - la densite de conteneurs supportee et la reactivite du demon
      - la stabilite du demon pendant la charge (erreurs / pertes de contact)

    Il n'a besoin QUE d'une image deja presente localement (contrainte de
    telechargement d'images respectee). Aucune image n'est tiree du registre.

.PARAMETER Image
    Image locale a utiliser. Si omis, la plus petite image locale disposant
    d'un shell POSIX est selectionnee automatiquement.

.PARAMETER OutputDir
    Repertoire de sortie du rapport et des CSV.

.PARAMETER MaxContainers
    Nombre maximal de conteneurs pour le test de densite.

.PARAMETER IoSizeMB
    Taille du fichier de test pour les mesures d'E/S sequentielles.

.PARAMETER SmallFiles
    Nombre de petits fichiers pour le test d'E/S de metadonnees.

.PARAMETER Aggressive
    Active les paliers de charge eleves (CPU = 2x nproc, memoire = 50% de la RAM
    allouee a la VM). A n'utiliser que sur un poste sans travail en cours.

.PARAMETER SkipStress
    N'execute que l'inventaire et la mesure de repos (mode audit, sans risque).

.EXAMPLE
    .\Test-DockerDesktop.ps1

.EXAMPLE
    .\Test-DockerDesktop.ps1 -Image alpine:3.19 -Aggressive -MaxContainers 40

.NOTES
    A executer dans un PowerShell utilisateur (les droits admin ne sont pas
    requis). Fermez vos IDE et arretez vos conteneurs de travail avant de lancer.
    Toutes les metriques hote sont collectees via CIM/WMI, donc insensibles a la
    langue du systeme (Windows FR pris en charge).
#>

[CmdletBinding()]
param(
    [string] $Image,
    [string] $OutputDir = (Join-Path $env:USERPROFILE "Desktop\docker-bench"),
    [int]    $MaxContainers = 20,
    [int]    $IoSizeMB = 512,
    [int]    $SmallFiles = 1000,
    [switch] $Aggressive,
    [switch] $SkipStress,
    [string] $ImportTar
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================================
#  INFRASTRUCTURE
# ============================================================================

$script:Prefix    = "dbench"
$script:Findings  = New-Object System.Collections.ArrayList
$script:Results   = [ordered]@{}
$script:DaemonErr = 0
$script:DaemonOk  = 0

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}

function Write-Info { param([string]$T) Write-Host "  [i] $T" -ForegroundColor Gray }
function Write-Ok   { param([string]$T) Write-Host "  [+] $T" -ForegroundColor Green }
function Write-Warn2{ param([string]$T) Write-Host "  [!] $T" -ForegroundColor Yellow }
function Write-Bad  { param([string]$T) Write-Host "  [X] $T" -ForegroundColor Red }

function Add-Finding {
    param(
        [ValidateSet('CRITIQUE','AVERTISSEMENT','INFO','OK')] [string]$Severity,
        [string]$Category,
        [string]$Message,
        [string]$Recommendation = ""
    )
    [void]$script:Findings.Add([pscustomobject]@{
        Severite       = $Severity
        Categorie      = $Category
        Constat        = $Message
        Recommandation = $Recommendation
    })
    switch ($Severity) {
        'CRITIQUE'      { Write-Bad   "$Category : $Message" }
        'AVERTISSEMENT' { Write-Warn2 "$Category : $Message" }
        'OK'            { Write-Ok    "$Category : $Message" }
        default         { Write-Info  "$Category : $Message" }
    }
}

function Invoke-Cli {
    <# Execute une commande externe et renvoie stdout/stderr/exitcode/duree #>
    param([string]$FilePath, [string[]]$Args, [int]$TimeoutSec = 120)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    # Les arguments contenant des espaces (ex : {{json .}}) doivent etre proteges,
    # sinon Windows les decoupe et docker recoit un template invalide.
    $quotedArgs = @()
    foreach ($a in $Args) {
        if ($a -match '\s' -and -not ($a.StartsWith('"') -and $a.EndsWith('"'))) {
            $quotedArgs += ('"' + $a + '"')
        } else {
            $quotedArgs += $a
        }
    }
    $psi.FileName               = $FilePath
    $psi.Arguments              = ($quotedArgs -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $p  = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        $sw.Stop()
        return [pscustomobject]@{ Out=""; Err="TIMEOUT"; Code=-999; Ms=$sw.Elapsed.TotalMilliseconds }
    }
    $sw.Stop()
    return [pscustomobject]@{
        Out  = $so.Result
        Err  = $se.Result
        Code = $p.ExitCode
        Ms   = $sw.Elapsed.TotalMilliseconds
    }
}

function Invoke-Docker {
    param([string[]]$Args, [int]$TimeoutSec = 120)
    $r = Invoke-Cli -FilePath "docker" -Args $Args -TimeoutSec $TimeoutSec
    if ($r.Code -eq 0) { $script:DaemonOk++ } else { $script:DaemonErr++ }
    return $r
}

function Get-HostSnapshot {
    <# Metriques hote via CIM : independant de la langue de Windows #>
    $cpu  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
    $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $proc = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue

    $vm     = $proc | Where-Object { $_.Name -like 'vmmem*' }
    $dockp  = $proc | Where-Object { $_.Name -match '^(com\.docker|Docker Desktop|dockerd|vpnkit|wslservice|vmcompute)' }
    $system = $proc | Where-Object { $_.Name -eq 'System' }
    $av     = $proc | Where-Object { $_.Name -match '(?i)(mfe|trellix|mcshield|masvc|macmnsvc|MsMpEng|MpDefender|SentinelAgent|CSFalcon|cb)' }

    [pscustomobject]@{
        Timestamp        = (Get-Date).ToString('o')
        CpuTotalPct      = [double]($cpu.PercentProcessorTime)
        DiskReadMBps     = [math]::Round(([double]$disk.DiskReadBytesPerSec) / 1MB, 2)
        DiskWriteMBps    = [math]::Round(([double]$disk.DiskWriteBytesPerSec) / 1MB, 2)
        DiskBusyPct      = [math]::Round(100 - [double]$disk.PercentIdleTime, 1)
        DiskQueue        = [double]$disk.CurrentDiskQueueLength
        MemFreeMB        = [math]::Round(([double]$os.FreePhysicalMemory) / 1KB, 0)
        VmmemMB          = [math]::Round((($vm     | Measure-Object WorkingSetPrivate -Sum).Sum) / 1MB, 0)
        VmmemCpuPct      = [double](($vm     | Measure-Object PercentProcessorTime -Sum).Sum)
        DockerProcMB     = [math]::Round((($dockp  | Measure-Object WorkingSetPrivate -Sum).Sum) / 1MB, 0)
        DockerProcCpuPct = [double](($dockp  | Measure-Object PercentProcessorTime -Sum).Sum)
        SystemCpuPct     = [double](($system | Measure-Object PercentProcessorTime -Sum).Sum)
        AvCpuPct         = [double](($av     | Measure-Object PercentProcessorTime -Sum).Sum)
    }
}

function Start-Sampler {
    param([string]$CsvPath, [int]$IntervalMs = 1000)
    $sb = {
        param($csv, $interval)
        $header = $false
        while ($true) {
            try {
                $cpu  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
                $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
                $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                $proc = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue
                $vm    = $proc | Where-Object { $_.Name -like 'vmmem*' }
                $dockp = $proc | Where-Object { $_.Name -match '^(com\.docker|Docker Desktop|dockerd|vpnkit)' }
                $sys   = $proc | Where-Object { $_.Name -eq 'System' }
                $av    = $proc | Where-Object { $_.Name -match '(?i)(mfe|trellix|mcshield|masvc|macmnsvc|MsMpEng|SentinelAgent|CSFalcon)' }

                $row = [pscustomobject]@{
                    Timestamp        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    Phase            = (Get-Content -Path "$csv.phase" -ErrorAction SilentlyContinue)
                    CpuTotalPct      = [double]$cpu.PercentProcessorTime
                    SystemCpuPct     = [double](($sys | Measure-Object PercentProcessorTime -Sum).Sum)
                    AvCpuPct         = [double](($av  | Measure-Object PercentProcessorTime -Sum).Sum)
                    VmmemCpuPct      = [double](($vm  | Measure-Object PercentProcessorTime -Sum).Sum)
                    VmmemMB          = [math]::Round((($vm    | Measure-Object WorkingSetPrivate -Sum).Sum)/1MB,0)
                    DockerProcMB     = [math]::Round((($dockp | Measure-Object WorkingSetPrivate -Sum).Sum)/1MB,0)
                    MemFreeMB        = [math]::Round(([double]$os.FreePhysicalMemory)/1KB,0)
                    DiskReadMBps     = [math]::Round(([double]$disk.DiskReadBytesPerSec)/1MB,2)
                    DiskWriteMBps    = [math]::Round(([double]$disk.DiskWriteBytesPerSec)/1MB,2)
                    DiskBusyPct      = [math]::Round(100-[double]$disk.PercentIdleTime,1)
                    DiskQueue        = [double]$disk.CurrentDiskQueueLength
                }
                if (-not $header) { $row | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8; $header = $true }
                else              { $row | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Append }
            } catch { }
            Start-Sleep -Milliseconds $interval
        }
    }
    return Start-Job -ScriptBlock $sb -ArgumentList $CsvPath, $IntervalMs
}

function Set-Phase {
    param([string]$Name)
    Set-Content -Path "$script:SamplerCsv.phase" -Value $Name -Encoding ASCII -ErrorAction SilentlyContinue
    $script:PhaseMarks += [pscustomobject]@{ Phase = $Name; Start = (Get-Date) }
}

function Get-PhaseStats {
    param([string]$CsvPath, [string]$Phase)
    if (-not (Test-Path $CsvPath)) { return $null }
    $rows = Import-Csv $CsvPath | Where-Object { $_.Phase -eq $Phase }
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    $f = { param($p) ($rows | ForEach-Object { [double]$_.$p }) }
    [pscustomobject]@{
        Phase            = $Phase
        Echantillons     = $rows.Count
        CpuMoyen         = [math]::Round(((& $f 'CpuTotalPct')   | Measure-Object -Average).Average,1)
        CpuMax           = [math]::Round(((& $f 'CpuTotalPct')   | Measure-Object -Maximum).Maximum,1)
        SystemCpuMoyen   = [math]::Round(((& $f 'SystemCpuPct')  | Measure-Object -Average).Average,1)
        AvCpuMoyen       = [math]::Round(((& $f 'AvCpuPct')      | Measure-Object -Average).Average,1)
        VmmemCpuMoyen    = [math]::Round(((& $f 'VmmemCpuPct')   | Measure-Object -Average).Average,1)
        VmmemMoMoyen     = [math]::Round(((& $f 'VmmemMB')       | Measure-Object -Average).Average,0)
        VmmemMoMax       = [math]::Round(((& $f 'VmmemMB')       | Measure-Object -Maximum).Maximum,0)
        DockerMoMoyen    = [math]::Round(((& $f 'DockerProcMB')  | Measure-Object -Average).Average,0)
        RamLibreMinMo    = [math]::Round(((& $f 'MemFreeMB')     | Measure-Object -Minimum).Minimum,0)
        LectureMoyMBps   = [math]::Round(((& $f 'DiskReadMBps')  | Measure-Object -Average).Average,1)
        EcritureMoyMBps  = [math]::Round(((& $f 'DiskWriteMBps') | Measure-Object -Average).Average,1)
        DisqueOccupePct  = [math]::Round(((& $f 'DiskBusyPct')   | Measure-Object -Average).Average,1)
        FileAttenteMax   = [math]::Round(((& $f 'DiskQueue')     | Measure-Object -Maximum).Maximum,1)
    }
}

function Remove-BenchArtifacts {
    Write-Info "Nettoyage des conteneurs et volumes de test..."
    $ids = (Invoke-Docker @('ps','-aq','--filter',"name=$script:Prefix") -TimeoutSec 60).Out
    if ($ids.Trim()) {
        $list = ($ids -split "`n" | Where-Object { $_.Trim() }) -join ' '
        [void](Invoke-Docker @('rm','-f',$list) -TimeoutSec 180)
    }
    [void](Invoke-Docker @('volume','rm','-f',"${script:Prefix}_vol") -TimeoutSec 60)
    if ($script:BindPath -and (Test-Path $script:BindPath)) {
        Remove-Item -Path $script:BindPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
#  0. PREPARATION
# ============================================================================

$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutputDir = Join-Path $OutputDir $runStamp
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$script:SamplerCsv = Join-Path $OutputDir "metriques-hote.csv"
$script:PhaseMarks = @()
$script:BindPath   = Join-Path $env:TEMP "$script:Prefix-bind"

Write-Step "BANC D'ESSAI DOCKER DESKTOP - $runStamp"
Write-Info "Sortie : $OutputDir"
if (-not $SkipStress) {
    Write-Warn2 "Ce test va saturer volontairement CPU / RAM / disque pendant plusieurs minutes."
    Write-Warn2 "Fermez vos IDE et arretez vos conteneurs de travail. Ctrl+C pour annuler."
    Start-Sleep -Seconds 5
}

# ---- Docker present ?
$dv = Invoke-Docker @('version','--format','{{json .}}') -TimeoutSec 60
if ($dv.Code -ne 0) {
    Write-Bad "Le client Docker ne repond pas. Docker Desktop est-il demarre ?"
    Write-Bad ($dv.Err.Trim())
    exit 1
}
$verJson = $null; try { $verJson = $dv.Out | ConvertFrom-Json } catch {}

# ============================================================================
#  1. INVENTAIRE HOTE / WSL / DOCKER
# ============================================================================

Write-Step "1. INVENTAIRE DE L'ENVIRONNEMENT"

$cs  = Get-CimInstance Win32_ComputerSystem
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$sysDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$phys = Get-CimInstance Win32_DiskDrive | Select-Object -First 1

$hostInfo = [ordered]@{
    'Machine'              = "$($cs.Manufacturer) $($cs.Model)"
    'Systeme'              = "$($os.Caption) $($os.Version) ($($os.OSArchitecture))"
    'Processeur'           = $cpu.Name.Trim()
    'Coeurs / Threads'     = "$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)"
    'RAM totale'           = "$([math]::Round($cs.TotalPhysicalMemory/1GB,1)) Go"
    'RAM libre (instant)'  = "$([math]::Round($os.FreePhysicalMemory/1MB,1)) Go"
    'Disque C: libre'      = "$([math]::Round($sysDisk.FreeSpace/1GB,1)) Go / $([math]::Round($sysDisk.Size/1GB,1)) Go"
    'Modele disque'        = "$($phys.Model)"
    'Virtualisation firmware' = "$($cs.HypervisorPresent)"
}
$totalRamGB   = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
$logicalCores = [int]$cpu.NumberOfLogicalProcessors
$hostInfo.GetEnumerator() | ForEach-Object { Write-Info ("{0,-24} : {1}" -f $_.Key, $_.Value) }
$script:Results['Hote'] = $hostInfo

if ($totalRamGB -lt 16) {
    Add-Finding 'AVERTISSEMENT' 'Materiel' "La machine dispose de $totalRamGB Go de RAM." `
        "En dessous de 16 Go, Docker Desktop + IDE + antivirus d'entreprise laissent tres peu de marge. C'est une cause frequente de gel et de kill de conteneurs."
}
if ($sysDisk.FreeSpace/1GB -lt 30) {
    Add-Finding 'CRITIQUE' 'Materiel' "Il ne reste que $([math]::Round($sysDisk.FreeSpace/1GB,1)) Go sur C:." `
        "Le disque virtuel WSL grossit dynamiquement. Sous 20-30 Go libres, Docker Desktop se met en erreur ou corrompt son ext4.vhdx."
}

# ---- Docker version / info
Write-Info ""
if ($verJson) {
    Write-Info ("{0,-24} : {1}" -f 'Client Docker', $verJson.Client.Version)
    if ($verJson.Server) { Write-Info ("{0,-24} : {1}" -f 'Serveur Docker', $verJson.Server.Version) }
}
$di = Invoke-Docker @('info','--format','{{json .}}') -TimeoutSec 90
$info = $null; try { $info = $di.Out | ConvertFrom-Json } catch {}
if (-not $info) {
    Write-Bad "docker info n'a pas renvoye de JSON exploitable (code $($di.Code))."
    if ($di.Err.Trim()) { Write-Bad ("  stderr : " + (($di.Err -split "`n")[0])) }
    Add-Finding 'CRITIQUE' 'Moteur Docker' "Le client Docker repond mais le moteur ne renvoie pas ses informations (code $($di.Code))." `
        "Le CLI est installe sans moteur fonctionnel, ou Docker Desktop n'a pas fini de demarrer. Ouvrez Docker Desktop et attendez l'etat Engine running avant de relancer le test."
}

$dockerInfo = [ordered]@{}
if ($info) {
    $dockerInfo = [ordered]@{
        'Version serveur'     = $info.ServerVersion
        'Pilote de stockage'  = $info.Driver
        'Pilote cgroup'       = $info.CgroupDriver
        'Version cgroup'      = $info.CgroupVersion
        'Noyau'               = $info.KernelVersion
        'OS conteneurs'       = $info.OperatingSystem
        'CPU vus par Docker'  = $info.NCPU
        'RAM vue par Docker'  = "$([math]::Round($info.MemTotal/1GB,2)) Go"
        'Conteneurs (total)'  = $info.Containers
        'Conteneurs actifs'   = $info.ContainersRunning
        'Images locales'      = $info.Images
        'Latence docker info' = "$([math]::Round($di.Ms,0)) ms"
    }
    $dockerInfo.GetEnumerator() | ForEach-Object { Write-Info ("{0,-24} : {1}" -f $_.Key, $_.Value) }

    $vmRamGB = [math]::Round($info.MemTotal/1GB,2)
    if ($info.NCPU -ge $logicalCores) {
        Add-Finding 'AVERTISSEMENT' 'Configuration WSL' "La VM Docker voit $($info.NCPU) vCPU, soit la totalite des $logicalCores threads de l'hote." `
            "Sans limite, un `docker build` ou un conteneur emballe gele tout le poste (Windows n'a plus de CPU pour l'interface). Limitez a environ 50-75% via processors dans .wslconfig."
    }
    if ($vmRamGB -ge ($totalRamGB * 0.75)) {
        Add-Finding 'AVERTISSEMENT' 'Configuration WSL' "La VM Docker peut consommer jusqu'a $vmRamGB Go sur $totalRamGB Go de RAM physique." `
            "C'est le comportement par defaut de WSL2 (80% de la RAM). Il provoque le swap massif de Windows et les freezes signales. Fixez memory dans .wslconfig."
    }
    if ($di.Ms -gt 3000) {
        Add-Finding 'AVERTISSEMENT' 'Demon' "La commande docker info met $([math]::Round($di.Ms,0)) ms a repondre au repos." `
            "Une latence superieure a 3 s au repos indique un demon deja sous contrainte (E/S disque ou analyse antivirus)."
    }
}
$script:Results['Docker'] = $dockerInfo

# ---- Backend WSL
Write-Info ""
$wslList = Invoke-Cli -FilePath "wsl.exe" -Args @('-l','-v') -TimeoutSec 60
$wslTxt  = ($wslList.Out -replace "`0","").Trim()
if ($wslTxt) {
    Write-Info "Distributions WSL :"
    $wslTxt -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "      $($_.Trim())" -ForegroundColor DarkGray }
}
if ($wslTxt -match "(?i)(aucune distribution|no installed distributions|has no installed distributions)") {
    Add-Finding 'CRITIQUE' 'Backend' "WSL ne declare aucune distribution installee : les distributions docker-desktop sont absentes." `
        "Soit Docker Desktop utilise le backend Hyper-V (moins performant et incompatible avec les reglages .wslconfig), soit son installation WSL est cassee. Verifiez Settings > General > Use the WSL 2 based engine, puis Troubleshoot > Reset to factory defaults si les distributions ne reapparaissent pas."
} elseif ($wslTxt -notmatch "(?i)docker-desktop") {
    Add-Finding 'AVERTISSEMENT' 'Backend' "Aucune distribution docker-desktop visible dans WSL." `
        "Verifiez le backend utilise par Docker Desktop."
}
$wslStatus = Invoke-Cli -FilePath "wsl.exe" -Args @('--status') -TimeoutSec 60
$wslStatusTxt = ($wslStatus.Out -replace "`0","").Trim()
$wslVersionCmd = Invoke-Cli -FilePath "wsl.exe" -Args @('--version') -TimeoutSec 60
$wslVersionTxt = ($wslVersionCmd.Out -replace "`0","").Trim()

# ---- .wslconfig
$wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
$wslConfigTxt  = ""
if (Test-Path $wslConfigPath) {
    $wslConfigTxt = Get-Content $wslConfigPath -Raw
    Write-Ok ".wslconfig present : $wslConfigPath"
    if ($wslConfigTxt -notmatch '(?im)^\s*memory\s*=') {
        Add-Finding 'AVERTISSEMENT' 'Configuration WSL' "Aucune directive memory dans .wslconfig." `
            "Ajoutez memory=<N>GB pour plafonner la VM."
    }
    if ($wslConfigTxt -notmatch '(?im)^\s*autoMemoryReclaim\s*=') {
        Add-Finding 'AVERTISSEMENT' 'Configuration WSL' "autoMemoryReclaim n'est pas active." `
            "Sans cette option, la RAM prise par Vmmem n'est jamais rendue a Windows apres un pic. Ajoutez autoMemoryReclaim=gradual."
    }
    if ($wslConfigTxt -notmatch '(?im)^\s*sparseVhd\s*=') {
        Add-Finding 'INFO' 'Configuration WSL' "sparseVhd n'est pas active." `
            "Ajoutez sparseVhd=true pour que le disque virtuel se retracte apres suppression d'images."
    }
} else {
    Add-Finding 'CRITIQUE' 'Configuration WSL' "Aucun fichier .wslconfig n'existe pour cet utilisateur." `
        "WSL2 s'autorise alors 80% de la RAM et 100% des CPU. C'est la premiere cause des plantages et de la surconsommation rapportes par les equipes de developpement. Voir le modele fourni en annexe du rapport."
}

# ---- Parametres Docker Desktop
$dockerSettings = $null
foreach ($p in @(
    (Join-Path $env:APPDATA "Docker\settings-store.json"),
    (Join-Path $env:APPDATA "Docker\settings.json"))) {
    if (Test-Path $p) {
        try { $dockerSettings = Get-Content $p -Raw | ConvertFrom-Json; $dockerSettingsPath = $p; break } catch {}
    }
}
if ($dockerSettings) {
    Write-Ok "Parametres Docker Desktop : $dockerSettingsPath"
    foreach ($k in @('MemoryMiB','Cpus','SwapMiB','DiskSizeMiB','UseVirtualizationFrameworkVirtioFS','UseResourceSaver','EnableVirtualizationFramework')) {
        if ($dockerSettings.PSObject.Properties.Name -contains $k) {
            Write-Info ("{0,-24} : {1}" -f $k, $dockerSettings.$k)
        }
    }
    if ($dockerSettings.PSObject.Properties.Name -contains 'UseResourceSaver' -and -not $dockerSettings.UseResourceSaver) {
        Add-Finding 'INFO' 'Docker Desktop' "Le mode Resource Saver est desactive." `
            "Activez-le : il arrete la VM apres inactivite et rend la RAM a Windows."
    }
}

# ---- Disque virtuel WSL
$vhdxFiles = @()
foreach ($root in @(
    (Join-Path $env:LOCALAPPDATA "Docker\wsl"),
    (Join-Path $env:LOCALAPPDATA "Packages"))) {
    if (Test-Path $root) {
        $vhdxFiles += Get-ChildItem -Path $root -Filter "*.vhdx" -Recurse -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -match '(?i)(docker|ext4)' }
    }
}
$vhdxInfo = @()
foreach ($v in $vhdxFiles) {
    $sizeGB = [math]::Round($v.Length/1GB,2)
    $vhdxInfo += [pscustomobject]@{ Fichier = $v.FullName; TailleGo = $sizeGB }
    Write-Info ("VHDX : {0} = {1} Go" -f $v.Name, $sizeGB)
    if ($sizeGB -gt 50) {
        Add-Finding 'AVERTISSEMENT' 'Stockage' "Le disque virtuel $($v.Name) occupe $sizeGB Go." `
            "Un docker system prune ne reduit pas le fichier. Compactez-le (wsl --shutdown puis Optimize-VHD ou diskpart compact) et activez sparseVhd."
    }
}

# ---- Securite / antivirus : point cle au vu des captures
Write-Info ""
$secProcs = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '(?i)(mfe|trellix|mcshield|masvc|macmnsvc|MsMpEng|SentinelAgent|CSFalcon|cbagent|Tanium|Netskope|Zscaler|Forcepoint)' } |
    Select-Object ProcessName, Id, @{n='RamMo';e={[math]::Round($_.WorkingSet64/1MB,0)}}
if ($secProcs) {
    Write-Warn2 "Agents de securite / DLP detectes :"
    $secProcs | ForEach-Object { Write-Host ("      {0} (PID {1}) - {2} Mo" -f $_.ProcessName, $_.Id, $_.RamMo) -ForegroundColor DarkYellow }
    Add-Finding 'CRITIQUE' 'Antivirus / DLP' "Des agents de securite temps reel tournent sur le poste ($((($secProcs.ProcessName | Select-Object -Unique) -join ', '))). " `
        "Ils inspectent chaque E/S du fichier ext4.vhdx et des dossiers de projet montes. C'est la cause typique d'un processus System a 20% de CPU avec un disque a 100% et d'E/S conteneur anormalement elevees. Demandez a l'equipe securite des exclusions sur les chemins WSL/Docker (voir annexe du rapport)."
}

$defExcl = $null
try { $defExcl = (Get-MpPreference -ErrorAction Stop).ExclusionPath } catch {}
if ($defExcl) {
    Write-Info "Exclusions Defender declarees : $($defExcl -join '; ')"
    if (-not ($defExcl -match '(?i)(docker|wsl|vhdx)')) {
        Add-Finding 'AVERTISSEMENT' 'Antivirus / DLP' "Aucune exclusion Defender ne cible les chemins Docker/WSL." ""
    }
} 

# ---- Journaux Docker Desktop : recherche de plantages passes
$logDirs = @(
    (Join-Path $env:LOCALAPPDATA "Docker\log\host"),
    (Join-Path $env:LOCALAPPDATA "Docker\log\vm"),
    (Join-Path $env:APPDATA "Docker\log")
) | Where-Object { Test-Path $_ }

$crashHits = @()
foreach ($d in $logDirs) {
    $files = Get-ChildItem $d -Filter "*.log" -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) }
    foreach ($f in $files) {
        try {
            $hits = Select-String -Path $f.FullName -Pattern 'panic:|fatal|OOM|out of memory|killed process|crash|unexpected shutdown|Timeout|engine failed|restarting' -ErrorAction SilentlyContinue
            if ($hits) {
                $crashHits += [pscustomobject]@{ Fichier = $f.Name; Occurrences = $hits.Count; Dernier = ($hits | Select-Object -Last 1).Line }
            }
        } catch {}
    }
}
if ($crashHits) {
    $tot = ($crashHits | Measure-Object Occurrences -Sum).Sum
    Write-Warn2 "$tot lignes d'erreur/plantage trouvees dans les journaux des 14 derniers jours."
    Add-Finding 'AVERTISSEMENT' 'Journaux' "$tot evenements de type erreur, OOM ou redemarrage inattendu dans les journaux Docker Desktop des 14 derniers jours." `
        "Le detail est exporte dans journaux-erreurs.csv. Ces traces corroborent les plaintes des equipes sur les plantages repetes."
    $crashHits | Export-Csv (Join-Path $OutputDir "journaux-erreurs.csv") -NoTypeInformation -Encoding UTF8
} else {
    Add-Finding 'OK' 'Journaux' "Aucune erreur majeure dans les journaux Docker Desktop recents." ""
}

# ---- Evenements Windows : arrets brutaux, memoire
try {
    $evts = Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=(Get-Date).AddDays(-14); Id=@(41,1001,2004,6008) } -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, ProviderName, @{n='Message';e={ ($_.Message -split "`n")[0] }}
    if ($evts) {
        $evts | Export-Csv (Join-Path $OutputDir "evenements-windows.csv") -NoTypeInformation -Encoding UTF8
        Add-Finding 'AVERTISSEMENT' 'Systeme' "$($evts.Count) evenements Windows de type arret brutal / pression memoire sur 14 jours." `
            "Voir evenements-windows.csv. Un ID 2004 (Resource Exhaustion) confirme une saturation memoire de l'hote."
    }
} catch {}

# ============================================================================
#  2. SELECTION DE L'IMAGE (sans telechargement)
# ============================================================================

Write-Step "2. SELECTION DE L'IMAGE DE TEST (aucun telechargement)"

if ($ImportTar) {
    if (-not (Test-Path $ImportTar)) { Write-Bad "Archive introuvable : $ImportTar"; exit 1 }
    $base = [IO.Path]::GetFileName($ImportTar) -replace '\.(tar|tar\.gz|tgz|tar\.xz)$','' -replace '[^a-zA-Z0-9._-]','-'
    $tag  = "rq-bench/" + $base.ToLower() + ":local"
    Write-Info "Import de l'archive locale $ImportTar (aucun acces registre)..."
    $imp = Invoke-Docker @('import',$ImportTar,$tag) -TimeoutSec 300
    if ($imp.Code -eq 0) { Write-Ok "Image importee : $tag"; if (-not $Image) { $Image = $tag } }
    else { Write-Bad "Echec de l'import : $($imp.Err.Trim())"; exit 1 }
}

$imgRaw = (Invoke-Docker @('image','ls','--format','{{.Repository}}:{{.Tag}}|{{.Size}}') -TimeoutSec 90).Out
$localImages = @()
foreach ($line in ($imgRaw -split "`n")) {
    if (-not $line.Trim()) { continue }
    $parts = $line.Trim() -split '\|'
    if ($parts[0] -match '<none>') { continue }
    $localImages += [pscustomobject]@{ Ref = $parts[0]; Size = $parts[1] }
}
Write-Info "$($localImages.Count) image(s) exploitable(s) en local."

function Test-ImageShell {
    param([string]$Ref)
    $r = Invoke-Docker @('run','--rm','--entrypoint','/bin/sh',$Ref,'-c','"echo DBENCH_OK"') -TimeoutSec 90
    return ($r.Code -eq 0 -and $r.Out -match 'DBENCH_OK')
}

if ($Image) {
    if (-not (Test-ImageShell $Image)) {
        Write-Bad "L'image $Image n'est pas utilisable (absente en local ou sans /bin/sh)."
        exit 1
    }
    Write-Ok "Image imposee : $Image"
} else {
    $preferred = @('busybox','alpine','debian','ubuntu','python','node','openjdk','eclipse-temurin','mcr.microsoft.com')
    $ordered = @()
    foreach ($p in $preferred) { $ordered += ($localImages | Where-Object { $_.Ref -match "(?i)$([regex]::Escape($p))" }) }
    $ordered += ($localImages | Where-Object { $ordered -notcontains $_ })
    foreach ($cand in ($ordered | Select-Object -Unique -First 12)) {
        Write-Info "Essai de $($cand.Ref) ..."
        if (Test-ImageShell $cand.Ref) { $Image = $cand.Ref; break }
    }
    if (-not $Image) {
        Write-Bad "Aucune image locale ne fournit de shell POSIX."
        Write-Bad "Solution sans registre : .\Test-DockerDesktop.ps1 -ImportTar .\rq-busybox-rootfs.tar"
        Write-Bad "Ou demandez a votre equipe l'autorisation pour busybox:latest ou alpine:latest,"
        Write-Bad "ou importez une archive : docker load -i busybox.tar"
        exit 1
    }
    Write-Ok "Image retenue : $Image"
}
$script:Results['ImageTest'] = $Image

if ($SkipStress) {
    Write-Warn2 "Mode -SkipStress : les tests de charge sont ignores."
}

# ============================================================================
#  3. MESURES
# ============================================================================

Remove-BenchArtifacts
$sampler = Start-Sampler -CsvPath $script:SamplerCsv -IntervalMs 1000
Start-Sleep -Seconds 2

$tests = New-Object System.Collections.ArrayList
function Add-Test {
    param([string]$Test, [string]$Metrique, $Valeur, [string]$Unite, [string]$Commentaire = "")
    [void]$tests.Add([pscustomobject]@{ Test=$Test; Metrique=$Metrique; Valeur=$Valeur; Unite=$Unite; Commentaire=$Commentaire })
    Write-Host ("      {0,-42} {1,12} {2}" -f $Metrique, $Valeur, $Unite) -ForegroundColor White
}

try {

# ---------------------------------------------------------------- 3.0 REPOS
Write-Step "3.0 LIGNE DE BASE AU REPOS (45 s)"
Set-Phase 'repos'
Write-Info "Mesure de la consommation de Docker Desktop sans aucune charge..."
Start-Sleep -Seconds 45
$baseline = Get-PhaseStats $script:SamplerCsv 'repos'
if ($baseline) {
    Add-Test 'Repos' 'CPU hote moyen'            $baseline.CpuMoyen        '%'
    Add-Test 'Repos' 'CPU processus System'      $baseline.SystemCpuMoyen  '%'
    Add-Test 'Repos' 'CPU agents de securite'    $baseline.AvCpuMoyen      '%'
    Add-Test 'Repos' 'CPU Vmmem (VM WSL)'        $baseline.VmmemCpuMoyen   '%'
    Add-Test 'Repos' 'RAM Vmmem'                 $baseline.VmmemMoMoyen    'Mo'
    Add-Test 'Repos' 'RAM processus Docker'      $baseline.DockerMoMoyen   'Mo'
    Add-Test 'Repos' 'Ecriture disque hote'      $baseline.EcritureMoyMBps 'Mo/s'
    Add-Test 'Repos' 'Occupation disque'         $baseline.DisqueOccupePct '%'

    if ($baseline.CpuMoyen -gt 25) {
        Add-Finding 'CRITIQUE' 'Repos' "Le poste consomme deja $($baseline.CpuMoyen)% de CPU sans aucune charge Docker." `
            "Un poste qui ne descend pas sous 25% au repos n'a plus de reserve. Les developpeurs percoivent cela comme des plantages de Docker alors que la contention est globale."
    }
    if ($baseline.SystemCpuMoyen -gt 8) {
        Add-Finding 'CRITIQUE' 'Repos' "Le processus System consomme $($baseline.SystemCpuMoyen)% de CPU au repos." `
            "Le processus System porte les pilotes filtres (antivirus, DLP, chiffrement). Une telle valeur signe une inspection temps reel des E/S de la VM WSL. C'est exactement le symptome visible sur vos captures d'ecran."
    }
    if ($baseline.DisqueOccupePct -gt 70) {
        Add-Finding 'CRITIQUE' 'Repos' "Le disque est occupe a $($baseline.DisqueOccupePct)% au repos (file d'attente max $($baseline.FileAttenteMax))." `
            "Le disque est le goulot d'etranglement principal. Tant qu'il sature au repos, aucun reglage Docker ne corrigera les lenteurs."
    }
    if ($baseline.VmmemMoMoyen -gt 2048) {
        Add-Finding 'AVERTISSEMENT' 'Repos' "Vmmem occupe deja $($baseline.VmmemMoMoyen) Mo au repos." `
            "Activez autoMemoryReclaim=gradual et le mode Resource Saver."
    }
}

if (-not $SkipStress) {

# ------------------------------------------------- 3.1 LATENCE DE DEMARRAGE
Write-Step "3.1 LATENCE DE DEMARRAGE DES CONTENEURS (cold start)"
Set-Phase 'coldstart'
$starts = @()
for ($i=1; $i -le 10; $i++) {
    $r = Invoke-Docker @('run','--rm','--name',"$script:Prefix-cs-$i",'--entrypoint','/bin/sh',$Image,'-c','"exit 0"') -TimeoutSec 120
    if ($r.Code -eq 0) { $starts += $r.Ms; Write-Host ("      demarrage {0,2} : {1,7:N0} ms" -f $i, $r.Ms) -ForegroundColor DarkGray }
    else { Write-Bad "Echec du demarrage $i : $($r.Err.Trim())" }
}
if ($starts.Count) {
    $csAvg = [math]::Round(($starts | Measure-Object -Average).Average,0)
    $csMin = [math]::Round(($starts | Measure-Object -Minimum).Minimum,0)
    $csMax = [math]::Round(($starts | Measure-Object -Maximum).Maximum,0)
    Add-Test 'Cold start' 'Latence moyenne run+exit' $csAvg 'ms'
    Add-Test 'Cold start' 'Latence minimale'         $csMin 'ms'
    Add-Test 'Cold start' 'Latence maximale'         $csMax 'ms'
    Add-Test 'Cold start' 'Ecart max/min'            ([math]::Round($csMax/[math]::Max($csMin,1),1)) 'x' 'Instabilite si > 3'

    if ($csAvg -gt 2500) {
        Add-Finding 'CRITIQUE' 'Latence' "Demarrer un conteneur vide prend en moyenne $csAvg ms." `
            "Une valeur saine est de 300 a 800 ms. Au dela de 2,5 s, chaque docker compose up devient penible et les healthchecks / timeouts des outils de developpement echouent : c'est le vecu decrit par les equipes."
    } elseif ($csAvg -gt 1200) {
        Add-Finding 'AVERTISSEMENT' 'Latence' "Latence de demarrage moyenne de $csAvg ms (cible < 800 ms)." ""
    } else {
        Add-Finding 'OK' 'Latence' "Latence de demarrage correcte ($csAvg ms)." ""
    }
    if ($csMax -gt ($csMin * 4)) {
        Add-Finding 'AVERTISSEMENT' 'Latence' "Le temps de demarrage varie d'un facteur $([math]::Round($csMax/[math]::Max($csMin,1),1)) entre le meilleur et le pire cas." `
            "Cette variabilite est typique d'une analyse antivirus asynchrone ou d'une contention disque."
    }
}

# ------------------------------------------------------- 3.2 CHARGE CPU
Write-Step "3.2 SATURATION CPU ET RESPECT DES LIMITES"
Set-Phase 'cpu'
$cpuTargets = if ($Aggressive) { [int]($logicalCores * 2) } else { $logicalCores }
Write-Info "Lancement de $cpuTargets conteneurs de calcul (boucle serree, 1 CPU chacun)..."
for ($i=1; $i -le $cpuTargets; $i++) {
    [void](Invoke-Docker @('run','-d','--name',"$script:Prefix-cpu-$i",'--cpus','1','--entrypoint','/bin/sh',$Image,'-c','"while : ; do : ; done"') -TimeoutSec 60)
}
Start-Sleep -Seconds 30

$statsRaw = (Invoke-Docker @('stats','--no-stream','--format','{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}') -TimeoutSec 120).Out
$cpuStats = @()
foreach ($l in ($statsRaw -split "`n")) {
    if ($l -match "$script:Prefix-cpu") {
        $p = $l.Trim() -split '\|'
        $cpuStats += [double]($p[1] -replace '[%\s]','' -replace ',','.')
    }
}
$cpuPhase = Get-PhaseStats $script:SamplerCsv 'cpu'
if ($cpuStats.Count) {
    $avgPerContainer = [math]::Round(($cpuStats | Measure-Object -Average).Average,1)
    Add-Test 'CPU' 'Conteneurs de calcul lances'  $cpuTargets ''
    Add-Test 'CPU' 'CPU moyen par conteneur'      $avgPerContainer '%' 'Cible 100% avec --cpus 1'
    Add-Test 'CPU' 'CPU hote pendant la charge'   $cpuPhase.CpuMoyen '%'
    Add-Test 'CPU' 'CPU Vmmem pendant la charge'  $cpuPhase.VmmemCpuMoyen '%'
    Add-Test 'CPU' 'CPU System pendant la charge' $cpuPhase.SystemCpuMoyen '%'

    if ($avgPerContainer -lt 70) {
        Add-Finding 'AVERTISSEMENT' 'CPU' "Avec --cpus 1, chaque conteneur n'obtient que $avgPerContainer% d'un coeur." `
            "La limite n'est pas honoree ou la VM est deja saturee : les conteneurs se volent le CPU. Reduisez le nombre de vCPU alloues a WSL ou repartissez la charge."
    }
}

# Respect d'une limite fractionnaire
[void](Invoke-Docker @('run','-d','--name',"$script:Prefix-cpuhalf",'--cpus','0.5','--entrypoint','/bin/sh',$Image,'-c','"while : ; do : ; done"') -TimeoutSec 60)
Start-Sleep -Seconds 15
$halfRaw = (Invoke-Docker @('stats','--no-stream','--format','{{.Name}}|{{.CPUPerc}}',"$script:Prefix-cpuhalf") -TimeoutSec 90).Out
if ($halfRaw -match '\|') {
    $halfVal = [double](($halfRaw -split '\|')[1] -replace '[%\s]','' -replace ',','.')
    Add-Test 'CPU' 'Conteneur limite a --cpus 0.5' $halfVal '%' 'Cible ~50%'
    if ($halfVal -gt 75) {
        Add-Finding 'CRITIQUE' 'CPU' "Un conteneur limite a --cpus 0.5 consomme $halfVal% d'un coeur." `
            "Les quotas cgroup ne sont pas appliques : un seul conteneur peut alors monopoliser la machine."
    } else {
        Add-Finding 'OK' 'CPU' "Les limites CPU (cgroup) sont correctement appliquees." ""
    }
}

Write-Info "Reactivite du demon pendant la saturation CPU..."
$lat = @()
for ($i=1; $i -le 5; $i++) {
    $r = Invoke-Docker @('ps','-q') -TimeoutSec 60
    $lat += $r.Ms
    Start-Sleep -Seconds 2
}
$latAvg = [math]::Round(($lat | Measure-Object -Average).Average,0)
Add-Test 'CPU' 'Latence docker ps sous charge' $latAvg 'ms'
if ($latAvg -gt 5000) {
    Add-Finding 'CRITIQUE' 'Demon' "Sous charge CPU, docker ps met $latAvg ms a repondre." `
        "Le demon devient inutilisable pendant une compilation. Les developpeurs interpretent ce blocage comme un plantage de Docker Desktop."
}

Write-Info "Arret des conteneurs de calcul..."
Remove-BenchArtifacts
Start-Sleep -Seconds 10

# ---------------------------------------------------- 3.3 PRESSION MEMOIRE
Write-Step "3.3 PRESSION MEMOIRE ET RESTITUTION DE LA RAM"
Set-Phase 'memoire'

$vmRamMB = if ($info) { [int]($info.MemTotal/1MB) } else { [int]($totalRamGB*1024*0.5) }
$limitMB = if ($Aggressive) { [int]($vmRamMB*0.5) } else { [int]($vmRamMB*0.25) }
if ($limitMB -lt 512) { $limitMB = 512 }
Write-Info "Conteneur limite a $limitMB Mo ; allocation progressive jusqu'a depassement."

$preMem = (Get-HostSnapshot).VmmemMB
$fillCmd = '"mkdir -p /ram; i=1; while [ $i -le 40 ]; do dd if=/dev/zero of=/ram/blk$i bs=1M count=64 2>/dev/null || exit 7; echo alloc=$((i*64))Mo; sleep 1; i=$((i+1)); done"'
$memRun = Invoke-Docker @('run','--name',"$script:Prefix-mem",'--memory',"${limitMB}m",'--memory-swap',"${limitMB}m",'--tmpfs',"/ram:size=$([int]($limitMB*2))m",'--entrypoint','/bin/sh',$Image,'-c',$fillCmd) -TimeoutSec 240

$insp = (Invoke-Docker @('inspect','--format','{{.State.OOMKilled}}|{{.State.ExitCode}}',"$script:Prefix-mem") -TimeoutSec 60).Out.Trim()
$oomKilled = $insp -match '^true'
$exitCode  = ($insp -split '\|')[-1]
$allocated = 0
if ($memRun.Out -match '(?s).*alloc=(\d+)Mo') {
    $allocated = [int](([regex]::Matches($memRun.Out,'alloc=(\d+)Mo') | Select-Object -Last 1).Groups[1].Value)
}
$memPhase = Get-PhaseStats $script:SamplerCsv 'memoire'
Add-Test 'Memoire' 'Limite imposee au conteneur' $limitMB 'Mo'
Add-Test 'Memoire' 'Memoire allouee avant arret' $allocated 'Mo'
Add-Test 'Memoire' 'OOM-kill declenche'          ($(if($oomKilled){'oui'}else{'non'})) '' "Code de sortie $exitCode"
Add-Test 'Memoire' 'Pic RAM Vmmem'               $memPhase.VmmemMoMax 'Mo'
Add-Test 'Memoire' 'RAM Windows libre minimale'  $memPhase.RamLibreMinMo 'Mo'

if ($oomKilled -or $exitCode -eq '137') {
    Add-Finding 'OK' 'Memoire' "Le confinement memoire fonctionne : le conteneur a ete stoppe par l'OOM-killer a la limite." `
        "Rappel aux equipes : un conteneur qui disparait avec le code 137 n'est pas un plantage de Docker, c'est un depassement de --memory. Il faut dimensionner les limites dans le compose."
} else {
    Add-Finding 'AVERTISSEMENT' 'Memoire' "Le conteneur n'a pas ete arrete a la limite de $limitMB Mo (code $exitCode)." `
        "Verifiez que cgroup v2 est actif dans WSL. Sans confinement effectif, un conteneur peut vider la RAM de l'hote."
}
if ($memPhase -and $memPhase.RamLibreMinMo -lt 1024) {
    Add-Finding 'CRITIQUE' 'Memoire' "La RAM libre de Windows est tombee a $($memPhase.RamLibreMinMo) Mo pendant le test." `
        "A ce niveau Windows swappe massivement : gel de l'interface, arret de processus, et Docker Desktop apparait comme responsable. Plafonnez la VM via memory dans .wslconfig."
}

Write-Info "Test de restitution de la memoire (60 s apres l'arret)..."
[void](Invoke-Docker @('rm','-f',"$script:Prefix-mem") -TimeoutSec 90)
$peak = $memPhase.VmmemMoMax
Start-Sleep -Seconds 60
$postMem = (Get-HostSnapshot).VmmemMB
Add-Test 'Memoire' 'RAM Vmmem avant test'          $preMem  'Mo'
Add-Test 'Memoire' 'RAM Vmmem 60 s apres l''arret' $postMem 'Mo'
if ($peak -gt 0) {
    $reclaimed = [math]::Round((($peak - $postMem) / [math]::Max($peak - $preMem,1)) * 100, 0)
    if ($reclaimed -lt 0) { $reclaimed = 0 }
    Add-Test 'Memoire' 'Memoire rendue a Windows' $reclaimed '%' 'Cible > 60%'
    if ($reclaimed -lt 40) {
        Add-Finding 'CRITIQUE' 'Memoire' "Seulement $reclaimed% de la memoire du pic a ete rendue a Windows apres l'arret du conteneur." `
            "C'est le comportement classique de WSL2 : Vmmem conserve la RAM. Sur une journee de travail, la memoire s'accumule jusqu'au gel du poste. Correctif : autoMemoryReclaim=gradual dans .wslconfig, plus wsl --shutdown en fin de journee."
    } else {
        Add-Finding 'OK' 'Memoire' "La memoire est correctement restituee a Windows ($reclaimed%)." ""
    }
}

# --------------------------------------------------------- 3.4 E/S DISQUE
Write-Step "3.4 PERFORMANCES DISQUE : VOLUME NOMME vs BIND MOUNT WINDOWS"
Set-Phase 'disque'
New-Item -ItemType Directory -Path $script:BindPath -Force | Out-Null
[void](Invoke-Docker @('volume','create',"${script:Prefix}_vol") -TimeoutSec 60)

$runIo = Invoke-Docker @('run','-d','--name',"$script:Prefix-io",
    '-v',"${script:Prefix}_vol:/vol",
    '-v',"`"$($script:BindPath):/bind`"",
    '--entrypoint','/bin/sh',$Image,'-c','"sleep 900"') -TimeoutSec 120

if ($runIo.Code -ne 0) {
    Add-Finding 'AVERTISSEMENT' 'Disque' "Impossible de monter le bind mount ($($runIo.Err.Trim()))." `
        "Verifiez le partage de fichiers dans les parametres Docker Desktop."
} else {
    function Measure-Io {
        param([string]$Label, [string]$Cmd, [int]$Timeout = 600)
        $r = Invoke-Docker @('exec',"$script:Prefix-io",'/bin/sh','-c',"`"$Cmd`"") -TimeoutSec $Timeout
        return [pscustomobject]@{ Label=$Label; Ms=$r.Ms; Ok=($r.Code -eq 0); Err=$r.Err }
    }

    Write-Info "Ecriture sequentielle de $IoSizeMB Mo..."
    $wVol  = Measure-Io 'vol-write'  "dd if=/dev/zero of=/vol/f bs=1M count=$IoSizeMB 2>/dev/null; sync"
    $wBind = Measure-Io 'bind-write' "dd if=/dev/zero of=/bind/f bs=1M count=$IoSizeMB 2>/dev/null; sync"
    Write-Info "Lecture sequentielle..."
    $rVol  = Measure-Io 'vol-read'   "dd if=/vol/f of=/dev/null bs=1M 2>/dev/null"
    $rBind = Measure-Io 'bind-read'  "dd if=/bind/f of=/dev/null bs=1M 2>/dev/null"
    Write-Info "Creation de $SmallFiles petits fichiers (metadonnees)..."
    $sVol  = Measure-Io 'vol-small'  "mkdir -p /vol/s; i=0; while [ `$i -lt $SmallFiles ]; do echo x > /vol/s/f`$i; i=`$((i+1)); done; sync"
    $sBind = Measure-Io 'bind-small' "mkdir -p /bind/s; i=0; while [ `$i -lt $SmallFiles ]; do echo x > /bind/s/f`$i; i=`$((i+1)); done; sync"
    Write-Info "Parcours de l'arborescence (stat)..."
    $lVol  = Measure-Io 'vol-list'   "ls -la /vol/s > /dev/null; find /vol/s -type f | wc -l > /dev/null"
    $lBind = Measure-Io 'bind-list'  "ls -la /bind/s > /dev/null; find /bind/s -type f | wc -l > /dev/null"

    $volWMBps  = [math]::Round($IoSizeMB / ([math]::Max($wVol.Ms,1)/1000),1)
    $bindWMBps = [math]::Round($IoSizeMB / ([math]::Max($wBind.Ms,1)/1000),1)
    $volRMBps  = [math]::Round($IoSizeMB / ([math]::Max($rVol.Ms,1)/1000),1)
    $bindRMBps = [math]::Round($IoSizeMB / ([math]::Max($rBind.Ms,1)/1000),1)
    $volFps    = [math]::Round($SmallFiles / ([math]::Max($sVol.Ms,1)/1000),0)
    $bindFps   = [math]::Round($SmallFiles / ([math]::Max($sBind.Ms,1)/1000),0)

    Add-Test 'Disque' 'Ecriture - volume nomme'      $volWMBps  'Mo/s'
    Add-Test 'Disque' 'Ecriture - bind mount'        $bindWMBps 'Mo/s'
    Add-Test 'Disque' 'Lecture - volume nomme'       $volRMBps  'Mo/s'
    Add-Test 'Disque' 'Lecture - bind mount'         $bindRMBps 'Mo/s'
    Add-Test 'Disque' 'Petits fichiers - volume'     $volFps    'fichiers/s'
    Add-Test 'Disque' 'Petits fichiers - bind mount' $bindFps   'fichiers/s'
    Add-Test 'Disque' 'Parcours ls/find - volume'    ([math]::Round($lVol.Ms,0))  'ms'
    Add-Test 'Disque' 'Parcours ls/find - bind'      ([math]::Round($lBind.Ms,0)) 'ms'

    $ratioSeq   = [math]::Round($volWMBps / [math]::Max($bindWMBps,0.1),1)
    $ratioSmall = [math]::Round($volFps   / [math]::Max($bindFps,1),1)
    Add-Test 'Disque' 'Penalite bind mount - sequentiel' $ratioSeq   'x'
    Add-Test 'Disque' 'Penalite bind mount - metadonnees' $ratioSmall 'x'

    if ($ratioSmall -gt 5) {
        Add-Finding 'CRITIQUE' 'Disque' "Les operations sur petits fichiers sont ${ratioSmall}x plus lentes via un bind mount Windows que dans un volume nomme ($bindFps contre $volFps fichiers/s)." `
            "C'est LA cause principale des environnements de developpement lents : node_modules, vendor, .git, cache Maven ou Gradle montes depuis C:\ traversent la couche de traduction 9p/virtioFS et l'antivirus. Placez ces repertoires dans des volumes nommes, ou deplacez le code source dans le systeme de fichiers WSL (\\\\wsl$\\...)."
    } elseif ($ratioSmall -gt 2) {
        Add-Finding 'AVERTISSEMENT' 'Disque' "Penalite de ${ratioSmall}x sur les petits fichiers via bind mount." `
            "Activez virtioFS dans les parametres Docker Desktop et privilegiez les volumes nommes pour les dependances."
    } else {
        Add-Finding 'OK' 'Disque' "La penalite des bind mounts reste acceptable (${ratioSmall}x)." ""
    }
    if ($volWMBps -lt 150) {
        Add-Finding 'AVERTISSEMENT' 'Disque' "L'ecriture dans un volume nomme plafonne a $volWMBps Mo/s." `
            "Un SSD NVMe sain depasse 500 Mo/s meme via WSL. Une valeur basse indique une inspection temps reel du fichier ext4.vhdx par l'antivirus, ou un disque sature."
    }

    $diskPhase = Get-PhaseStats $script:SamplerCsv 'disque'
    if ($diskPhase) {
        Add-Test 'Disque' 'Occupation disque hote pendant les E/S' $diskPhase.DisqueOccupePct '%'
        Add-Test 'Disque' 'CPU System pendant les E/S'             $diskPhase.SystemCpuMoyen  '%'
        if ($diskPhase.SystemCpuMoyen -gt 12) {
            Add-Finding 'CRITIQUE' 'Antivirus / DLP' "Pendant les E/S conteneur, le processus System monte a $($diskPhase.SystemCpuMoyen)% de CPU." `
                "Correlation directe entre les E/S de la VM et le CPU des pilotes filtres : chaque bloc ecrit par un conteneur est analyse par l'agent de securite. Sans exclusions, aucun reglage Docker ne compensera."
        }
    }
    [void](Invoke-Docker @('rm','-f',"$script:Prefix-io") -TimeoutSec 120)
}

# ------------------------------------------------------- 3.5 DENSITE
Write-Step "3.5 DENSITE DE CONTENEURS ET REACTIVITE DU DEMON"
Set-Phase 'densite'
$launched = 0; $failed = 0; $launchTimes = @(); $daemonLat = @()
for ($i=1; $i -le $MaxContainers; $i++) {
    $r = Invoke-Docker @('run','-d','--name',"$script:Prefix-d-$i",'--entrypoint','/bin/sh',$Image,'-c','"sleep 600"') -TimeoutSec 120
    if ($r.Code -eq 0) { $launched++; $launchTimes += $r.Ms }
    else { $failed++; Write-Bad "Echec au conteneur $i : $(($r.Err -split "`n")[0])" }
    if ($i % 5 -eq 0) {
        $pr = Invoke-Docker @('ps','-q') -TimeoutSec 90
        $daemonLat += $pr.Ms
        Write-Host ("      {0,3} conteneurs actifs - docker ps : {1,6:N0} ms" -f $launched, $pr.Ms) -ForegroundColor DarkGray
    }
}
$densPhase = Get-PhaseStats $script:SamplerCsv 'densite'
Add-Test 'Densite' 'Conteneurs demarres'          $launched ''
Add-Test 'Densite' 'Echecs de demarrage'          $failed   ''
if ($launchTimes.Count) {
    Add-Test 'Densite' 'Latence moyenne de creation' ([math]::Round(($launchTimes | Measure-Object -Average).Average,0)) 'ms'
    $firstFive = ($launchTimes | Select-Object -First 5 | Measure-Object -Average).Average
    $lastFive  = ($launchTimes | Select-Object -Last  5 | Measure-Object -Average).Average
    $degrade = [math]::Round($lastFive / [math]::Max($firstFive,1),1)
    Add-Test 'Densite' 'Degradation (5 derniers / 5 premiers)' $degrade 'x'
    if ($degrade -gt 3) {
        Add-Finding 'AVERTISSEMENT' 'Densite' "La creation de conteneurs devient ${degrade}x plus lente au fil du test." `
            "Le demon se degrade avec le nombre de conteneurs. Un docker compose de 15 a 20 services devient tres long a monter."
    }
}
if ($densPhase) {
    Add-Test 'Densite' 'RAM Vmmem a pleine densite' $densPhase.VmmemMoMax 'Mo'
    Add-Test 'Densite' 'RAM Windows libre minimale' $densPhase.RamLibreMinMo 'Mo'
}
if ($daemonLat.Count) {
    $dlMax = [math]::Round(($daemonLat | Measure-Object -Maximum).Maximum,0)
    Add-Test 'Densite' 'Latence docker ps maximale' $dlMax 'ms'
    if ($dlMax -gt 8000) {
        Add-Finding 'CRITIQUE' 'Demon' "docker ps atteint $dlMax ms avec $launched conteneurs actifs." `
            "L'interface de Docker Desktop devient alors non reactive : c'est ce que les equipes decrivent comme un plantage."
    }
}
if ($failed -gt 0) {
    Add-Finding 'CRITIQUE' 'Densite' "$failed conteneurs sur $MaxContainers n'ont pas pu demarrer." `
        "La limite pratique de ce poste se situe autour de $launched conteneurs simultanes. Les compose depassant ce seuil echoueront de maniere aleatoire."
} else {
    Add-Finding 'OK' 'Densite' "Les $launched conteneurs demandes ont tous demarre." ""
}

Remove-BenchArtifacts

# -------------------------------------------------- 3.6 RECUPERATION
Write-Step "3.6 RETOUR AU REPOS APRES CHARGE"
Set-Phase 'recuperation'
Start-Sleep -Seconds 60
$recov = Get-PhaseStats $script:SamplerCsv 'recuperation'
if ($recov -and $baseline) {
    Add-Test 'Recuperation' 'CPU hote apres charge'   $recov.CpuMoyen  '%' "Repos initial : $($baseline.CpuMoyen)%"
    Add-Test 'Recuperation' 'RAM Vmmem apres charge'  $recov.VmmemMoMoyen 'Mo' "Repos initial : $($baseline.VmmemMoMoyen) Mo"
    if ($recov.VmmemMoMoyen -gt ($baseline.VmmemMoMoyen * 2) -and $recov.VmmemMoMoyen -gt 1500) {
        Add-Finding 'CRITIQUE' 'Recuperation' "Une minute apres la fin des tests, Vmmem occupe encore $($recov.VmmemMoMoyen) Mo contre $($baseline.VmmemMoMoyen) Mo au depart." `
            "La memoire n'est pas liberee entre deux sessions de travail. Cumule sur une journee, cela explique les plantages en fin d'apres-midi."
    }
}

} # fin -SkipStress

# ---- Fiabilite globale du demon
$totalCalls = $script:DaemonOk + $script:DaemonErr
if ($totalCalls -gt 0) {
    $errRate = [math]::Round(($script:DaemonErr / $totalCalls) * 100,1)
    Add-Test 'Stabilite' 'Commandes docker executees' $totalCalls ''
    Add-Test 'Stabilite' 'Taux d''echec des commandes' $errRate '%'
    if ($errRate -gt 5) {
        Add-Finding 'CRITIQUE' 'Stabilite' "$errRate% des commandes docker ont echoue pendant le banc d'essai." `
            "Le demon est instable sous charge. Recuperez les journaux via Docker Desktop > Troubleshoot > Get support et ouvrez un ticket avec ce rapport."
    } else {
        Add-Finding 'OK' 'Stabilite' "Taux d'echec des commandes docker de $errRate%." ""
    }
}

}
finally {
    Write-Step "NETTOYAGE"
    Remove-BenchArtifacts
    if ($sampler) { Stop-Job $sampler -ErrorAction SilentlyContinue; Remove-Job $sampler -Force -ErrorAction SilentlyContinue }
    Remove-Item "$script:SamplerCsv.phase" -Force -ErrorAction SilentlyContinue
    Write-Ok "Environnement remis en etat."
}

# ============================================================================
#  4. RAPPORT
# ============================================================================

Write-Step "4. GENERATION DU RAPPORT"

Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$tests | Export-Csv (Join-Path $OutputDir "mesures.csv") -NoTypeInformation -Encoding UTF8
$script:Findings | Export-Csv (Join-Path $OutputDir "constats.csv") -NoTypeInformation -Encoding UTF8

$phaseStats = @()
foreach ($ph in @('repos','coldstart','cpu','memoire','disque','densite','recuperation')) {
    $s = Get-PhaseStats $script:SamplerCsv $ph
    if ($s) { $phaseStats += $s }
}
if ($phaseStats) { $phaseStats | Export-Csv (Join-Path $OutputDir "synthese-phases.csv") -NoTypeInformation -Encoding UTF8 }

$nCrit = ($script:Findings | Where-Object { $_.Severite -eq 'CRITIQUE' }).Count
$nWarn = ($script:Findings | Where-Object { $_.Severite -eq 'AVERTISSEMENT' }).Count

$verdict = if ($nCrit -ge 3) { "INADAPTE EN L'ETAT - correctifs requis avant usage en developpement" }
           elseif ($nCrit -ge 1) { "DEGRADE - anomalies bloquantes identifiees" }
           elseif ($nWarn -ge 3) { "FONCTIONNEL MAIS SOUS-OPTIMISE" }
           else { "CONFORME" }

$wslTemplate = @"
[wsl2]
# Plafond memoire de la VM : environ 50% de la RAM physique
memory=$([math]::Max([math]::Floor($totalRamGB*0.5),4))GB
# Nombre de vCPU : environ 50 a 75% des threads logiques
processors=$([math]::Max([math]::Floor($logicalCores*0.6),2))
swap=2GB
# Rend progressivement la RAM inutilisee a Windows (WSL >= 1.3.10)
autoMemoryReclaim=gradual
# Permet au disque virtuel de se retracter apres suppression d'images
sparseVhd=true
# Reseau : a tester, resout de nombreux problemes de DNS/VPN d'entreprise
networkingMode=mirrored
dnsTunneling=true
autoProxy=true

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
"@

$exclusionPaths = @(
    "%LOCALAPPDATA%\Docker",
    "%APPDATA%\Docker",
    "%ProgramFiles%\Docker",
    "%LOCALAPPDATA%\Packages\*Ubuntu*",
    "\\wsl$\",
    "\\wsl.localhost\",
    "*.vhdx",
    "vmmem.exe / vmmemWSL.exe",
    "com.docker.backend.exe, dockerd.exe, Docker Desktop.exe, wslservice.exe, vmcompute.exe"
)

# ---- Markdown
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Rapport de banc d'essai - Docker Desktop")
[void]$md.AppendLine("")
[void]$md.AppendLine("| | |")
[void]$md.AppendLine("|---|---|")
[void]$md.AppendLine("| Date | $(Get-Date -Format 'dd/MM/yyyy HH:mm') |")
[void]$md.AppendLine("| Poste | $env:COMPUTERNAME |")
[void]$md.AppendLine("| Utilisateur | $env:USERNAME |")
[void]$md.AppendLine("| Image de test | $Image |")
[void]$md.AppendLine("| Mode | $(if($SkipStress){'Audit seul'}elseif($Aggressive){'Charge agressive'}else{'Charge standard'}) |")
[void]$md.AppendLine("| **Verdict** | **$verdict** |")
[void]$md.AppendLine("| Constats critiques | $nCrit |")
[void]$md.AppendLine("| Avertissements | $nWarn |")
[void]$md.AppendLine("")
[void]$md.AppendLine("## 1. Synthese pour la direction")
[void]$md.AppendLine("")
foreach ($f in ($script:Findings | Where-Object { $_.Severite -eq 'CRITIQUE' })) {
    [void]$md.AppendLine("- **[$($f.Categorie)]** $($f.Constat)")
    if ($f.Recommandation) { [void]$md.AppendLine("  - *Action :* $($f.Recommandation)") }
}
if ($nCrit -eq 0) { [void]$md.AppendLine("Aucun constat critique.") }
[void]$md.AppendLine("")
[void]$md.AppendLine("## 2. Environnement")
[void]$md.AppendLine("")
[void]$md.AppendLine("### 2.1 Poste de travail")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Element | Valeur |")
[void]$md.AppendLine("|---|---|")
foreach ($k in $hostInfo.Keys) { [void]$md.AppendLine("| $k | $($hostInfo[$k]) |") }
[void]$md.AppendLine("")
[void]$md.AppendLine("### 2.2 Docker Desktop")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Element | Valeur |")
[void]$md.AppendLine("|---|---|")
foreach ($k in $dockerInfo.Keys) { [void]$md.AppendLine("| $k | $($dockerInfo[$k]) |") }
[void]$md.AppendLine("")
if ($vhdxInfo) {
    [void]$md.AppendLine("### 2.3 Disques virtuels")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Fichier | Taille (Go) |")
    [void]$md.AppendLine("|---|---|")
    foreach ($v in $vhdxInfo) { [void]$md.AppendLine("| $($v.Fichier) | $($v.TailleGo) |") }
    [void]$md.AppendLine("")
}
[void]$md.AppendLine("### 2.4 Configuration WSL en vigueur")
[void]$md.AppendLine("")
[void]$md.AppendLine('```ini')
[void]$md.AppendLine($(if ($wslConfigTxt) { $wslConfigTxt.Trim() } else { "(aucun fichier .wslconfig - valeurs par defaut : 80% de la RAM, tous les CPU)" }))
[void]$md.AppendLine('```')
[void]$md.AppendLine("")
[void]$md.AppendLine("## 3. Resultats des mesures")
[void]$md.AppendLine("")
foreach ($grp in ($tests | Group-Object Test)) {
    [void]$md.AppendLine("### $($grp.Name)")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Metrique | Valeur | Unite | Commentaire |")
    [void]$md.AppendLine("|---|---:|---|---|")
    foreach ($t in $grp.Group) { [void]$md.AppendLine("| $($t.Metrique) | $($t.Valeur) | $($t.Unite) | $($t.Commentaire) |") }
    [void]$md.AppendLine("")
}
if ($phaseStats) {
    [void]$md.AppendLine("## 4. Consommation de l'hote par phase")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Phase | CPU moy % | System % | Antivirus % | Vmmem % | Vmmem Mo (max) | RAM libre min Mo | Disque occupe % |")
    [void]$md.AppendLine("|---|---:|---:|---:|---:|---:|---:|---:|")
    foreach ($p in $phaseStats) {
        [void]$md.AppendLine("| $($p.Phase) | $($p.CpuMoyen) | $($p.SystemCpuMoyen) | $($p.AvCpuMoyen) | $($p.VmmemCpuMoyen) | $($p.VmmemMoMax) | $($p.RamLibreMinMo) | $($p.DisqueOccupePct) |")
    }
    [void]$md.AppendLine("")
}
[void]$md.AppendLine("## 5. Tous les constats")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Severite | Categorie | Constat | Recommandation |")
[void]$md.AppendLine("|---|---|---|---|")
foreach ($f in ($script:Findings | Sort-Object { switch ($_.Severite) { 'CRITIQUE' { 0 } 'AVERTISSEMENT' { 1 } 'INFO' { 2 } default { 3 } } })) {
    [void]$md.AppendLine("| $($f.Severite) | $($f.Categorie) | $($f.Constat) | $($f.Recommandation) |")
}
[void]$md.AppendLine("")
[void]$md.AppendLine("## 6. Annexe A - Modele de .wslconfig recommande")
[void]$md.AppendLine("")
[void]$md.AppendLine("A placer dans ``$env:USERPROFILE\.wslconfig``, puis executer ``wsl --shutdown`` et relancer Docker Desktop.")
[void]$md.AppendLine("")
[void]$md.AppendLine('```ini')
[void]$md.AppendLine($wslTemplate)
[void]$md.AppendLine('```')
[void]$md.AppendLine("")
[void]$md.AppendLine("## 7. Annexe B - Exclusions antivirus / DLP a demander")
[void]$md.AppendLine("")
[void]$md.AppendLine("A transmettre a l'equipe securite. Sans ces exclusions, les E/S des conteneurs sont analysees bloc par bloc, ce qui produit un processus System a plus de 15% de CPU et un disque sature.")
[void]$md.AppendLine("")
foreach ($p in $exclusionPaths) { [void]$md.AppendLine("- ``$p``") }
[void]$md.AppendLine("")
[void]$md.AppendLine("## 8. Annexe C - Bonnes pratiques a diffuser aux equipes")
[void]$md.AppendLine("")
[void]$md.AppendLine("1. Placer le code source dans le systeme de fichiers WSL (``\\wsl$\...``) plutot que sur ``C:\``, ou au minimum monter ``node_modules``, ``vendor``, ``target``, ``.gradle`` en volumes nommes.")
[void]$md.AppendLine("2. Declarer systematiquement ``mem_limit`` et ``cpus`` dans les fichiers compose : un conteneur sans limite peut assecher le poste.")
[void]$md.AppendLine("3. Un conteneur qui s'arrete avec le code 137 n'est pas un plantage de Docker : c'est un depassement de la limite memoire.")
[void]$md.AppendLine("4. Executer ``wsl --shutdown`` en fin de journee pour rendre la RAM a Windows.")
[void]$md.AppendLine("5. Purger regulierement : ``docker system prune -af --volumes`` puis compacter le VHDX.")
[void]$md.AppendLine("6. Activer virtioFS et le mode Resource Saver dans les parametres de Docker Desktop.")
[void]$md.AppendLine("7. Reduire le nombre de services demarres simultanement : n'activer que les profils compose necessaires.")

$mdPath = Join-Path $OutputDir "rapport-docker-desktop.md"
$md.ToString() | Out-File -FilePath $mdPath -Encoding UTF8

# ---- HTML
$rowsFind = ""
foreach ($f in ($script:Findings | Sort-Object { switch ($_.Severite) { 'CRITIQUE' { 0 } 'AVERTISSEMENT' { 1 } 'INFO' { 2 } default { 3 } } })) {
    $cls = switch ($f.Severite) { 'CRITIQUE' {'crit'} 'AVERTISSEMENT' {'warn'} 'OK' {'ok'} default {'info'} }
    $rowsFind += "<tr class='$cls'><td><span class='badge $cls'>$($f.Severite)</span></td><td>$([System.Web.HttpUtility]::HtmlEncode($f.Categorie))</td><td>$([System.Web.HttpUtility]::HtmlEncode($f.Constat))</td><td>$([System.Web.HttpUtility]::HtmlEncode($f.Recommandation))</td></tr>`n"
}
$rowsTests = ""
foreach ($t in $tests) {
    $rowsTests += "<tr><td>$($t.Test)</td><td>$([System.Web.HttpUtility]::HtmlEncode($t.Metrique))</td><td class='num'>$($t.Valeur)</td><td>$($t.Unite)</td><td class='muted'>$([System.Web.HttpUtility]::HtmlEncode($t.Commentaire))</td></tr>`n"
}
$rowsPhase = ""
foreach ($p in $phaseStats) {
    $rowsPhase += "<tr><td>$($p.Phase)</td><td class='num'>$($p.CpuMoyen)</td><td class='num'>$($p.SystemCpuMoyen)</td><td class='num'>$($p.AvCpuMoyen)</td><td class='num'>$($p.VmmemCpuMoyen)</td><td class='num'>$($p.VmmemMoMax)</td><td class='num'>$($p.RamLibreMinMo)</td><td class='num'>$($p.DisqueOccupePct)</td></tr>`n"
}
$verdictCls = if ($nCrit -ge 1) { 'crit' } elseif ($nWarn -ge 3) { 'warn' } else { 'ok' }

$html = @"
<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8">
<title>Rapport Docker Desktop - $env:COMPUTERNAME</title>
<style>
 body{font-family:Segoe UI,system-ui,sans-serif;margin:0;background:#f4f6f8;color:#1b1f24}
 .wrap{max-width:1100px;margin:0 auto;padding:32px}
 h1{font-size:26px;margin:0 0 4px} h2{margin-top:38px;border-bottom:2px solid #d9dee3;padding-bottom:6px;font-size:19px}
 .sub{color:#5a636d;margin-bottom:24px}
 .verdict{padding:18px 22px;border-radius:8px;font-size:17px;font-weight:600;margin:20px 0}
 .verdict.crit{background:#fdecea;border-left:6px solid #c0392b;color:#7d241a}
 .verdict.warn{background:#fef6e6;border-left:6px solid #e0a012;color:#7a5606}
 .verdict.ok{background:#eaf7ee;border-left:6px solid #219653;color:#14572f}
 table{width:100%;border-collapse:collapse;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.08);font-size:13.5px}
 th{background:#2c3e50;color:#fff;text-align:left;padding:9px 11px;font-weight:600}
 td{padding:8px 11px;border-top:1px solid #e6eaee;vertical-align:top}
 td.num{text-align:right;font-variant-numeric:tabular-nums;font-weight:600}
 td.muted{color:#6b747d}
 tr.crit td{background:#fef7f6} tr.warn td{background:#fffcf3}
 .badge{padding:2px 8px;border-radius:11px;font-size:11px;font-weight:700;color:#fff;white-space:nowrap}
 .badge.crit{background:#c0392b} .badge.warn{background:#e0a012} .badge.ok{background:#219653} .badge.info{background:#5a636d}
 .cards{display:flex;gap:14px;flex-wrap:wrap;margin:18px 0}
 .card{background:#fff;border-radius:8px;padding:14px 18px;flex:1;min-width:150px;box-shadow:0 1px 3px rgba(0,0,0,.08)}
 .card .v{font-size:24px;font-weight:700} .card .l{font-size:12px;color:#6b747d;text-transform:uppercase;letter-spacing:.4px}
 pre{background:#1e2630;color:#e8eef5;padding:16px;border-radius:8px;overflow-x:auto;font-size:12.5px;line-height:1.5}
 ul{line-height:1.75}
</style></head><body><div class="wrap">
<h1>Banc d'essai Docker Desktop</h1>
<div class="sub">$env:COMPUTERNAME &middot; $env:USERNAME &middot; $(Get-Date -Format 'dd/MM/yyyy HH:mm') &middot; image de test : $Image</div>
<div class="verdict $verdictCls">Verdict : $verdict</div>
<div class="cards">
 <div class="card"><div class="l">Critiques</div><div class="v">$nCrit</div></div>
 <div class="card"><div class="l">Avertissements</div><div class="v">$nWarn</div></div>
 <div class="card"><div class="l">RAM du poste</div><div class="v">$totalRamGB Go</div></div>
 <div class="card"><div class="l">Threads CPU</div><div class="v">$logicalCores</div></div>
 <div class="card"><div class="l">Mesures</div><div class="v">$($tests.Count)</div></div>
</div>
<h2>Constats et recommandations</h2>
<table><tr><th>Severite</th><th>Categorie</th><th>Constat</th><th>Recommandation</th></tr>$rowsFind</table>
<h2>Mesures detaillees</h2>
<table><tr><th>Test</th><th>Metrique</th><th>Valeur</th><th>Unite</th><th>Commentaire</th></tr>$rowsTests</table>
<h2>Consommation de l'hote par phase</h2>
<table><tr><th>Phase</th><th>CPU moy %</th><th>System %</th><th>Antivirus %</th><th>Vmmem %</th><th>Vmmem Mo max</th><th>RAM libre min Mo</th><th>Disque occupe %</th></tr>$rowsPhase</table>
<h2>Annexe A - .wslconfig recommande</h2>
<p>A placer dans <code>%USERPROFILE%\.wslconfig</code>, puis <code>wsl --shutdown</code> et redemarrage de Docker Desktop.</p>
<pre>$([System.Web.HttpUtility]::HtmlEncode($wslTemplate))</pre>
<h2>Annexe B - Exclusions antivirus / DLP a demander</h2>
<ul>$(($exclusionPaths | ForEach-Object { "<li><code>$([System.Web.HttpUtility]::HtmlEncode($_))</code></li>" }) -join '')</ul>
<h2>Annexe C - Bonnes pratiques equipes</h2>
<ul>
<li>Code source dans le systeme de fichiers WSL (<code>\\wsl$\...</code>) plutot que sur <code>C:\</code>.</li>
<li>Dependances (node_modules, vendor, .gradle, target) en volumes nommes, jamais en bind mount.</li>
<li><code>mem_limit</code> et <code>cpus</code> declares dans chaque service compose.</li>
<li>Code de sortie 137 = depassement de la limite memoire, pas un plantage de Docker.</li>
<li><code>wsl --shutdown</code> en fin de journee pour restituer la RAM a Windows.</li>
<li>Purge periodique et compactage du VHDX.</li>
<li>virtioFS et Resource Saver actives dans Docker Desktop.</li>
</ul>
</div></body></html>
"@
$htmlPath = Join-Path $OutputDir "rapport-docker-desktop.html"
$html | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Ok "Rapport HTML     : $htmlPath"
Write-Ok "Rapport Markdown : $mdPath"
Write-Ok "Mesures brutes   : $script:SamplerCsv"

Write-Step "VERDICT : $verdict  ($nCrit critique(s), $nWarn avertissement(s))"
try { Start-Process $htmlPath } catch {}
