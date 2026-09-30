#requires -version 5.1
#requires -PSEdition Desktop
<#
.SYNOPSIS
    Accio Optimizer - Manutencao, diagnostico e otimizacao segura para Windows 10/11.

.DESCRIPTION
    Ferramenta focada em ganhos reais e reversibilidade.
    - Cria snapshots internos antes de alteracoes persistentes.
    - Tenta criar Ponto de Restauracao do Windows.
    - Mantem logs de todas as operacoes.
    - Nao desativa Defender, Windows Update, Search, SysMain, servicos de impressao,
      Bluetooth, Microsoft Store ou outros componentes essenciais.
    - Nao altera HPET/BCD, pagefile, prioridades de kernel ou "tweaks de FPS" sem base.

.NOTES
    Nome: Accio Optimizer
    Versao: 1.0.1
    Requer: Windows 10/11 + Windows PowerShell 5.1
#>

[CmdletBinding()]
param(
    [string]$ExpectedUserSid
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$script:AppName = 'Accio Optimizer'
$script:Version = '1.0.1'
$script:HadErrors = $false
$script:CommonAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$script:LocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$script:WindowsPath = Split-Path -Parent ([Environment]::SystemDirectory)
$script:BasePath = Join-Path $script:CommonAppData 'AccioOptimizer'
$script:LogsPath = Join-Path $script:BasePath 'Logs'
$script:BackupsPath = Join-Path $script:BasePath 'Backups'
$script:LogFile = $null

$script:RegistryTargets = @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency' },
    @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate' },
    @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'MenuShowDelay' },
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting' }
)

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Start-Elevated {
    if (-not $PSCommandPath) {
        Write-Host '[ERRO] Execute este script a partir do arquivo AccioOptimizer.ps1.' -ForegroundColor Red
        exit 1
    }

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $argumentList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ExpectedUserSid `"$currentSid`""
    try {
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList -Wait -PassThru -ErrorAction Stop
        exit $process.ExitCode
    } catch {
        Write-Host '[ERRO] Nao foi possivel solicitar privilegios de Administrador.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
        exit 1
    }
}

if (-not (Test-IsAdministrator)) {
    Start-Elevated
}

if ($ExpectedUserSid) {
    $elevatedSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($ExpectedUserSid -ne $elevatedSid) {
        Write-Host '[ERRO] A elevacao foi feita com outra conta de usuario.' -ForegroundColor Red
        Write-Host 'Entre em uma conta Administradora e execute novamente para evitar alterar o HKCU da conta errada.' -ForegroundColor Yellow
        exit 1
    }
}

try {
    New-Item -ItemType Directory -Path $script:LogsPath -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path $script:BackupsPath -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host '[ERRO] Nao foi possivel criar a pasta de dados do Accio Optimizer.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor DarkRed
    exit 1
}

$script:LogFile = Join-Path $script:LogsPath ("AccioOptimizer_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO',
        [switch]$NoConsole
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $stamp, $Level, $Message

    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {}

    if ($Level -eq 'ERROR') {
        $script:HadErrors = $true
    }

    if (-not $NoConsole) {
        switch ($Level) {
            'OK'    { Write-Host $line -ForegroundColor Green }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line -ForegroundColor Gray }
        }
    }
}

function Set-SecureDirectoryAcl {
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)

        $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl

        foreach ($sidValue in @('S-1-5-18','S-1-5-32-544')) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, $fullControl, $inheritance, $propagation, $allow
            )
            [void]$acl.AddAccessRule($rule)
        }

        $currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $readRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $currentUserSid,
            [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($readRule)

        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        return $true
    } catch {
        Write-Log ("Nao foi possivel proteger a pasta {0}: {1}" -f $Path, $_.Exception.Message) 'ERROR'
        return $false
    }
}

foreach ($dataPath in @($script:BasePath, $script:LogsPath, $script:BackupsPath)) {
    if (-not (Set-SecureDirectoryAcl -Path $dataPath)) {
        Write-Host 'As pastas de dados nao puderam ser protegidas. O programa sera encerrado.' -ForegroundColor Red
        exit 1
    }
}

function Pause-Accio {
    Write-Host ''
    [void](Read-Host 'Pressione ENTER para continuar')
}

function Confirm-Accio {
    param(
        [Parameter(Mandatory=$true)][string]$Question,
        [bool]$DefaultNo = $true
    )

    $suffix = if ($DefaultNo) { '[s/N]' } else { '[S/n]' }
    $answer = Read-Host "$Question $suffix"

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return (-not $DefaultNo)
    }
    return ($answer.Trim().ToLowerInvariant() -in @('s','sim','y','yes'))
}

function Test-SupportedWindows {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ([int]$os.ProductType -ne 1) {
            Write-Log 'Windows Server detectado. Esta versao foi projetada para Windows cliente 10/11.' 'WARN'
        }

        $build = [int]$os.BuildNumber
        if ($build -lt 10240) {
            Write-Log ("Build do Windows nao suportado: {0}" -f $os.BuildNumber) 'ERROR'
            return $false
        }
        return $true
    } catch {
        Write-Log ("Falha ao identificar o Windows: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Get-ActivePowerSchemeGuid {
    try {
        $text = (& powercfg.exe /getactivescheme 2>&1 | Out-String)
        if ($text -match '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})') {
            return $Matches[1].ToLowerInvariant()
        }
    } catch {}
    return $null
}

function Get-TrimState {
    try {
        $text = (& fsutil.exe behavior query DisableDeleteNotify 2>&1 | Out-String)
        if ($text -match 'NTFS\s+DisableDeleteNotify\s*=\s*([01])') {
            return [int]$Matches[1]
        }
    } catch {}
    return $null
}

function Get-RegistryValueState {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )

    $exists = $false
    $kind = $null
    $value = $null
    $keyExists = $false

    try {
        if (Test-Path -LiteralPath $Path) {
            $key = Get-Item -LiteralPath $Path -ErrorAction Stop
            $keyExists = $true
            if ($key.GetValueNames() -contains $Name) {
                $exists = $true
                $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $kind = $key.GetValueKind($Name).ToString()
            }
        }
    } catch {
        throw ("Falha ao ler o Registro {0}\{1}: {2}" -f $Path, $Name, $_.Exception.Message)
    }

    return [PSCustomObject]@{
        Path      = $Path
        Name      = $Name
        KeyExists = $keyExists
        Exists    = $exists
        Kind      = $kind
        Value     = $value
    }
}

function Test-RegistryTargetAllowed {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name
    )

    foreach ($target in $script:RegistryTargets) {
        if ($target.Path -eq $Path -and $target.Name -eq $Name) {
            return $true
        }
    }
    return $false
}

function Test-TrustedOwner {
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        $owner = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        return ($owner -in @('S-1-5-18','S-1-5-32-544',$currentSid))
    } catch {
        return $false
    }
}

function Test-SnapshotState {
    param(
        [Parameter(Mandatory=$true)]$State,
        [Parameter(Mandatory=$true)][string]$SnapshotDirectory,
        [Parameter(Mandatory=$true)][string]$StateFile
    )

    try {
        $backupRoot = [IO.Path]::GetFullPath($script:BackupsPath).TrimEnd('\') + '\'
        $snapshotPath = [IO.Path]::GetFullPath($SnapshotDirectory).TrimEnd('\') + '\'
        $statePath = [IO.Path]::GetFullPath($StateFile)

        if (-not $snapshotPath.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not $statePath.StartsWith($snapshotPath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Test-TrustedOwner -Path $SnapshotDirectory)) { return $false }
        if (-not (Test-TrustedOwner -Path $StateFile)) { return $false }
        if ([int]$State.SchemaVersion -ne 1) { return $false }
        if ([string]$State.ComputerName -ne $env:COMPUTERNAME) { return $false }
        if ([string]$State.UserName -ne $env:USERNAME) { return $false }

        $registryValues = @($State.RegistryValues)
        if ($registryValues.Count -ne $script:RegistryTargets.Count) { return $false }

        $seen = @{}
        foreach ($reg in $registryValues) {
            $path = [string]$reg.Path
            $name = [string]$reg.Name
            if (-not (Test-RegistryTargetAllowed -Path $path -Name $name)) { return $false }
            $identity = ('{0}|{1}' -f $path, $name).ToLowerInvariant()
            if ($seen.ContainsKey($identity)) { return $false }
            $seen[$identity] = $true

            if ([bool]$reg.Exists -and [string]$reg.Kind -notin @('String','ExpandString','Binary','DWord','MultiString','QWord')) {
                return $false
            }
        }

        if ($State.ActivePowerScheme -and [string]$State.ActivePowerScheme -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
            return $false
        }

        if ($null -ne $State.TrimDisableNotify -and [string]$State.TrimDisableNotify -notin @('0','1')) {
            return $false
        }

        return $true
    } catch {
        return $false
    }
}

function Export-RegistrySafetyCopies {
    param([Parameter(Mandatory=$true)][string]$Destination)

    $keys = @(
        @{ Provider='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Native='HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; File='Themes_Personalize.reg' },
        @{ Provider='HKCU:\Control Panel\Desktop'; Native='HKCU\Control Panel\Desktop'; File='Desktop.reg' },
        @{ Provider='HKCU:\Control Panel\Desktop\WindowMetrics'; Native='HKCU\Control Panel\Desktop\WindowMetrics'; File='WindowMetrics.reg' },
        @{ Provider='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Native='HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; File='VisualEffects.reg' }
    )

    foreach ($item in $keys) {
        if (Test-Path -LiteralPath $item.Provider) {
            try {
                & reg.exe export $item.Native (Join-Path $Destination $item.File) /y *> $null
            } catch {}
        }
    }
}

function New-BackupSnapshot {
    param(
        [string]$Reason = 'Manual',
        [switch]$TryRestorePoint
    )

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $backupDir = Join-Path $script:BackupsPath ("{0}_{1}" -f $timestamp, ($Reason -replace '[^A-Za-z0-9_-]','_'))

    try {
        New-Item -ItemType Directory -Path $backupDir -ErrorAction Stop | Out-Null
        if (-not (Set-SecureDirectoryAcl -Path $backupDir)) {
            throw 'A pasta do snapshot nao pode ser protegida.'
        }

        $regState = @()
        foreach ($target in $script:RegistryTargets) {
            $regState += Get-RegistryValueState -Path $target.Path -Name $target.Name
        }

        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

        $state = [PSCustomObject]@{
            SchemaVersion      = 1
            AppVersion         = $script:Version
            CreatedAt          = (Get-Date).ToString('o')
            Reason             = $Reason
            ComputerName       = $env:COMPUTERNAME
            UserName           = $env:USERNAME
            WindowsCaption     = if ($os) { $os.Caption } else { $null }
            WindowsBuild       = if ($os) { $os.BuildNumber } else { $null }
            ActivePowerScheme  = Get-ActivePowerSchemeGuid
            TrimDisableNotify  = Get-TrimState
            RegistryValues     = $regState
        }

        $stateFile = Join-Path $backupDir 'state.json'
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8 -ErrorAction Stop
        $savedState = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-SnapshotState -State $savedState -SnapshotDirectory $backupDir -StateFile $stateFile)) {
            throw 'O state.json criado nao passou pela validacao de integridade.'
        }

        try {
            Get-CimInstance Win32_StartupCommand -ErrorAction Stop |
                Select-Object Name, Command, Location, User |
                Export-Csv -LiteralPath (Join-Path $backupDir 'startup_items.csv') -NoTypeInformation -Encoding UTF8
        } catch {}

        try {
            Get-CimInstance Win32_Service -ErrorAction Stop |
                Select-Object Name, DisplayName, State, StartMode |
                Export-Csv -LiteralPath (Join-Path $backupDir 'services_state.csv') -NoTypeInformation -Encoding UTF8
        } catch {}

        try {
            & powercfg.exe /list 2>&1 | Out-File -LiteralPath (Join-Path $backupDir 'power_schemes.txt') -Encoding UTF8
            & ipconfig.exe /all 2>&1 | Out-File -LiteralPath (Join-Path $backupDir 'network_info.txt') -Encoding UTF8
            & fsutil.exe behavior query DisableDeleteNotify 2>&1 | Out-File -LiteralPath (Join-Path $backupDir 'trim_state.txt') -Encoding UTF8
        } catch {}

        Export-RegistrySafetyCopies -Destination $backupDir
        Write-Log ("Snapshot interno criado: {0}" -f $backupDir) 'OK'

        if ($TryRestorePoint) {
            New-WindowsRestorePoint -Reason $Reason | Out-Null
        }

        return $backupDir
    } catch {
        Write-Log ("Falha ao criar snapshot: {0}" -f $_.Exception.Message) 'ERROR'
        return $null
    }
}

function New-WindowsRestorePoint {
    param([string]$Reason = 'AccioOptimizer')

    Write-Log 'Tentando habilitar a Protecao do Sistema e criar Ponto de Restauracao...' 'INFO'
    try {
        $drive = [IO.Path]::GetPathRoot([Environment]::SystemDirectory)
        Enable-ComputerRestore -Drive $drive -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description ("Accio Optimizer - {0}" -f $Reason) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Ponto de Restauracao do Windows criado.' 'OK'
        return $true
    } catch {
        Write-Log ('Nao foi possivel criar um novo Ponto de Restauracao. O Windows pode limitar a criacao a um ponto por dia ou a Protecao do Sistema pode estar bloqueada. O snapshot interno foi mantido. Detalhe: {0}' -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Set-RegistryValueSafe {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)]$Value,
        [Parameter(Mandatory=$true)][ValidateSet('String','ExpandString','Binary','DWord','MultiString','QWord')][string]$Type
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Write-Log ("Registro ajustado: {0}\{1} = {2}" -f $Path, $Name, $Value) 'OK'
        return $true
    } catch {
        Write-Log ("Falha no Registro {0}\{1}: {2}" -f $Path, $Name, $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Restore-RegistryValueState {
    param([Parameter(Mandatory=$true)]$State)

    try {
        if (-not (Test-RegistryTargetAllowed -Path ([string]$State.Path) -Name ([string]$State.Name))) {
            throw 'Destino de Registro nao permitido.'
        }

        if ([bool]$State.Exists) {
            if (-not (Test-Path -LiteralPath ([string]$State.Path))) {
                New-Item -Path ([string]$State.Path) -Force -ErrorAction Stop | Out-Null
            }

            $kind = [string]$State.Kind
            if ($kind -notin @('String','ExpandString','Binary','DWord','MultiString','QWord')) {
                $kind = 'String'
            }

            New-ItemProperty -LiteralPath ([string]$State.Path) `
                -Name ([string]$State.Name) `
                -Value $State.Value `
                -PropertyType $kind `
                -Force `
                -ErrorAction Stop | Out-Null
        } else {
            if (Test-Path -LiteralPath ([string]$State.Path)) {
                $key = Get-Item -LiteralPath ([string]$State.Path) -ErrorAction Stop
                if ($key.GetValueNames() -contains ([string]$State.Name)) {
                    Remove-ItemProperty -LiteralPath ([string]$State.Path) -Name ([string]$State.Name) -ErrorAction Stop
                }

                if (-not [bool]$State.KeyExists) {
                    $key = Get-Item -LiteralPath ([string]$State.Path) -ErrorAction Stop
                    if ($key.GetValueNames().Count -eq 0 -and $key.SubKeyCount -eq 0) {
                        Remove-Item -LiteralPath ([string]$State.Path) -Force -ErrorAction Stop
                    }
                }
            }
        }
        Write-Log ("Restaurado: {0}\{1}" -f $State.Path, $State.Name) 'OK'
        return $true
    } catch {
        Write-Log ("Falha ao restaurar {0}\{1}: {2}" -f $State.Path, $State.Name, $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Invoke-CommandLogged {
    param(
        [Parameter(Mandatory=$true)][string]$File,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [string]$FriendlyName = $File
    )

    Write-Log ("Executando: {0}" -f $FriendlyName) 'INFO'
    try {
        & $File @Arguments 2>&1 | ForEach-Object {
            $text = if ($null -eq $_) { '' } else { $_.ToString() }
            Write-Host $text
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                Write-Log $text 'INFO' -NoConsole
            }
        }
        $exitCode = $LASTEXITCODE

        if ($null -eq $exitCode) { $exitCode = 0 }

        if ($exitCode -in @(0, 3010)) {
            Write-Log ("Concluido: {0} (codigo {1})" -f $FriendlyName, $exitCode) 'OK'
        } else {
            Write-Log ("{0} terminou com codigo {1}. Consulte o log." -f $FriendlyName, $exitCode) 'WARN'
        }
        return $exitCode
    } catch {
        Write-Log ("Falha ao executar {0}: {1}" -f $FriendlyName, $_.Exception.Message) 'ERROR'
        return -1
    }
}

function Get-NormalizedDirectoryPath {
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            $fileId = (& fsutil.exe file queryfileid $fullPath 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $fileId -match '0x[0-9a-fA-F]+') {
                $root = [IO.Path]::GetPathRoot($fullPath).ToLowerInvariant()
                return ('{0}|FILEID:{1}' -f $root, $Matches[0].ToLowerInvariant())
            }
        }
        return $fullPath.ToLowerInvariant()
    } catch {
        return $null
    }
}

function Test-CleanupPathSafe {
    param([Parameter(Mandatory=$true)][string]$Path)

    try {
        $candidate = Get-NormalizedDirectoryPath -Path $Path
        if (-not $candidate) { return $false }

        $allowedPaths = @(
            (Join-Path $script:LocalAppData 'Temp'),
            (Join-Path $script:WindowsPath 'Temp'),
            (Join-Path $script:LocalAppData 'D3DSCache'),
            (Join-Path $script:CommonAppData 'Microsoft\Windows\WER\ReportQueue'),
            (Join-Path $script:CommonAppData 'Microsoft\Windows\WER\ReportArchive')
        )

        foreach ($allowedPath in $allowedPaths) {
            if ((Get-NormalizedDirectoryPath -Path $allowedPath) -eq $candidate) {
                return $true
            }
        }
        return $false
    } catch {
        return $false
    }
}

function Clear-DirectoryContentSafe {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label
    )

    if (-not (Test-CleanupPathSafe -Path $Path)) {
        Write-Log ("Caminho de limpeza recusado por seguranca: {0}" -f $Path) 'ERROR'
        return $false
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log ("Ignorado (nao existe): {0}" -f $Label) 'INFO'
        return $true
    }

    try {
        $currentPath = [IO.Path]::GetFullPath($Path)
        $isCleanupRoot = $true

        while ($currentPath) {
            $currentItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop

            if ($isCleanupRoot -and -not $currentItem.PSIsContainer) {
                Write-Log ("Caminho de limpeza recusado por nao ser diretorio: {0}" -f $Path) 'ERROR'
                return $false
            }

            if ($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Log ("Caminho de limpeza recusado por conter link/junction na raiz ou ancestrais: {0}" -f $Path) 'ERROR'
                return $false
            }

            $parent = [IO.Directory]::GetParent($currentPath)
            if ($null -eq $parent) { break }
            $currentPath = $parent.FullName
            $isCleanupRoot = $false
        }
    } catch {
        Write-Log ("Falha ao validar o diretorio de limpeza {0}: {1}" -f $Path, $_.Exception.Message) 'ERROR'
        return $false
    }

    $removed = 0
    $failed = 0

    Write-Log ("Limpando: {0} -> {1}" -f $Label, $Path) 'INFO'

    try {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | ForEach-Object {
            try {
                if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $failed++
                    Write-Log ("Link/junction preservado durante a limpeza: {0}" -f $_.FullName) 'WARN'
                    return
                }

                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            } catch {
                $failed++
            }
        }

        if ($failed -eq 0) {
            Write-Log ("{0}: {1} item(ns) removido(s)." -f $Label, $removed) 'OK'
        } else {
            Write-Log ("{0}: {1} removido(s); {2} em uso/protegido(s) foram preservados." -f $Label, $removed, $failed) 'WARN'
        }
        return $true
    } catch {
        Write-Log ("Falha ao limpar {0}: {1}" -f $Label, $_.Exception.Message) 'WARN'
        return $false
    }
}

function Invoke-SafeCleanup {
    Write-Host ''
    Write-Host '=== LIMPEZA SEGURA ===' -ForegroundColor Cyan

    $targets = @(
        @{ Path = (Join-Path $script:LocalAppData 'Temp'); Label = 'Temporarios do usuario' },
        @{ Path = (Join-Path $script:WindowsPath 'Temp'); Label = 'Temporarios do Windows' }
    )

    $seen = @{}
    $success = $true
    foreach ($target in $targets) {
        if ([string]::IsNullOrWhiteSpace($target.Path)) { continue }
        $normalized = Get-NormalizedDirectoryPath -Path $target.Path
        if (-not $normalized) {
            Write-Log ("Nao foi possivel normalizar o caminho: {0}" -f $target.Path) 'ERROR'
            $success = $false
            continue
        }
        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            if (-not (Clear-DirectoryContentSafe -Path $target.Path -Label $target.Label)) {
                $success = $false
            }
        }
    }

    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        try {
            Write-Log 'Limpando cache do Delivery Optimization...' 'INFO'
            Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
            Write-Log 'Cache do Delivery Optimization limpo.' 'OK'
        } catch {
            Write-Log ("Delivery Optimization nao pode ser limpo: {0}" -f $_.Exception.Message) 'WARN'
            $success = $false
        }
    } else {
        Write-Log 'Cmdlet Delete-DeliveryOptimizationCache nao disponivel neste Windows. Ignorado.' 'INFO'
    }

    if (-not $success) {
        Write-Log 'A limpeza segura terminou com uma ou mais falhas.' 'ERROR'
    }
    return $success
}

function Invoke-DnsCacheCleanup {
    Write-Host ''
    Write-Host '=== LIMPEZA DO CACHE DNS ===' -ForegroundColor Cyan
    Write-Host 'Use esta opcao para diagnosticar problemas de resolucao de nomes; ela nao oferece ganho permanente de desempenho.' -ForegroundColor Gray

    try {
        Clear-DnsClientCache -ErrorAction Stop
        Write-Log 'Cache DNS limpo.' 'OK'
        return $true
    } catch {
        $dnsCode = Invoke-CommandLogged -File 'ipconfig.exe' `
            -Arguments @('/flushdns') `
            -FriendlyName 'Limpeza do cache DNS'
        if ($dnsCode -eq 0) { return $true }

        Write-Log 'Nao foi possivel limpar o cache DNS.' 'ERROR'
        return $false
    }
}

function Invoke-DeepCleanup {
    Write-Host ''
    Write-Host '=== LIMPEZA PROFUNDA (OPCIONAL) ===' -ForegroundColor Yellow
    Write-Host 'Itens abaixo sao recriados pelo Windows, mas podem causar recompilacao de caches no primeiro uso.' -ForegroundColor Yellow

    if (-not (Confirm-Accio 'Executar limpeza profunda?')) {
        Write-Log 'Limpeza profunda cancelada pelo usuario.' 'INFO'
        return $true
    }

    $success = Invoke-SafeCleanup

    $deepTargets = @(
        @{ Path = (Join-Path $script:LocalAppData 'D3DSCache'); Label = 'DirectX Shader Cache' },
        @{ Path = (Join-Path $script:CommonAppData 'Microsoft\Windows\WER\ReportQueue'); Label = 'Relatorios WER pendentes' },
        @{ Path = (Join-Path $script:CommonAppData 'Microsoft\Windows\WER\ReportArchive'); Label = 'Relatorios WER arquivados' }
    )

    foreach ($target in $deepTargets) {
        if (-not (Clear-DirectoryContentSafe -Path $target.Path -Label $target.Label)) {
            $success = $false
        }
    }

    if (Confirm-Accio 'Esvaziar a Lixeira? Isso nao pode ser desfeito pelo rollback do Accio Optimizer.') {
        try {
            if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
                Clear-RecycleBin -Force -ErrorAction Stop
                Write-Log 'Lixeira esvaziada.' 'OK'
            } else {
                Write-Log 'Clear-RecycleBin nao disponivel. Lixeira preservada.' 'WARN'
            }
        } catch {
            Write-Log ("Nao foi possivel esvaziar a Lixeira: {0}" -f $_.Exception.Message) 'WARN'
            $success = $false
        }
    } else {
        Write-Log 'Lixeira preservada.' 'INFO'
    }

    if (-not $success) {
        Write-Log 'A limpeza profunda terminou com uma ou mais falhas.' 'ERROR'
    }
    return $success
}

function Invoke-ComponentCleanup {
    Write-Host ''
    Write-Host '=== LIMPEZA DO COMPONENT STORE ===' -ForegroundColor Cyan
    Write-Host 'Usa DISM /StartComponentCleanup SEM /ResetBase, preservando a possibilidade de remover atualizacoes quando o Windows permitir.' -ForegroundColor Gray

    $code = Invoke-CommandLogged -File 'dism.exe' `
        -Arguments @('/Online','/Cleanup-Image','/StartComponentCleanup','/NoRestart') `
        -FriendlyName 'DISM StartComponentCleanup'
    $success = ($code -in @(0,3010))
    if (-not $success) {
        Write-Log 'A limpeza do Component Store nao foi concluida.' 'ERROR'
    }
    return $success
}

function Invoke-WindowsRepair {
    Write-Host ''
    Write-Host '=== REPARO DO WINDOWS ===' -ForegroundColor Cyan
    Write-Host 'Esta rotina pode levar algum tempo e usa primeiro DISM, depois SFC.' -ForegroundColor Gray

    $backup = New-BackupSnapshot -Reason 'Antes_Reparo' -TryRestorePoint
    if (-not $backup) {
        if (-not (Confirm-Accio 'O snapshot falhou. Deseja continuar mesmo assim?')) {
            return
        }
    }

    $dismCode = Invoke-CommandLogged -File 'dism.exe' `
        -Arguments @('/Online','/Cleanup-Image','/RestoreHealth','/NoRestart') `
        -FriendlyName 'DISM RestoreHealth'

    if ($dismCode -notin @(0,3010)) {
        Write-Log 'DISM reportou problema. O SFC ainda sera executado para diagnostico/reparo adicional.' 'WARN'
    }

    $sfcCode = Invoke-CommandLogged -File 'sfc.exe' -Arguments @('/scannow') -FriendlyName 'SFC Scannow'

    Write-Host ''
    Write-Host 'Logs nativos, se necessarios:' -ForegroundColor Gray
    Write-Host "  DISM: $env:WINDIR\Logs\DISM\dism.log"
    Write-Host "  SFC : $env:WINDIR\Logs\CBS\CBS.log"
    $success = ($dismCode -in @(0,3010) -and $sfcCode -eq 0)
    if (-not $success) {
        Write-Log 'O reparo do Windows terminou com uma ou mais falhas.' 'ERROR'
    }
    return $success
}

function Invoke-OptimizeVolumes {
    Write-Host ''
    Write-Host '=== OTIMIZACAO DE UNIDADES ===' -ForegroundColor Cyan
    Write-Host 'O Windows escolhera automaticamente TRIM para SSD e desfragmentacao adequada para HDD.' -ForegroundColor Gray

    $success = $true
    try {
        $volumes = Get-Volume -ErrorAction Stop | Where-Object {
            $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem
        }

        if (-not $volumes) {
            Write-Log 'Nenhuma unidade fixa com letra encontrada.' 'WARN'
            return $false
        }

        foreach ($volume in $volumes) {
            try {
                Write-Log ("Otimizando unidade {0}: ({1})" -f $volume.DriveLetter, $volume.FileSystem) 'INFO'
                Optimize-Volume -DriveLetter $volume.DriveLetter -Verbose -ErrorAction Stop 4>&1 | ForEach-Object {
                    $t = $_.ToString()
                    Write-Host $t
                    Write-Log $t 'INFO' -NoConsole
                }
                Write-Log ("Unidade {0}: otimizada." -f $volume.DriveLetter) 'OK'
            } catch {
                Write-Log ("Falha ao otimizar {0}: {1}" -f $volume.DriveLetter, $_.Exception.Message) 'WARN'
                $success = $false
            }
        }
    } catch {
        Write-Log ("Modulo Storage indisponivel ou falha ao obter volumes: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
    if (-not $success) {
        Write-Log 'A otimizacao de volumes terminou com uma ou mais falhas.' 'ERROR'
    }
    return $success
}

function Enable-TrimSafely {
    Write-Host ''
    Write-Host '=== TRIM / DELETE NOTIFY ===' -ForegroundColor Cyan

    $trim = Get-TrimState
    if ($null -eq $trim) {
        Write-Log 'Nao foi possivel determinar o estado do TRIM para NTFS.' 'WARN'
        return $false
    }

    if ($trim -eq 0) {
        Write-Log 'TRIM ja esta habilitado para NTFS (DisableDeleteNotify = 0).' 'OK'
        return $true
    }

    Write-Host 'TRIM aparece DESABILITADO para NTFS.' -ForegroundColor Yellow
    if (-not (Confirm-Accio 'Deseja habilitar TRIM? O estado atual sera salvo para rollback.')) {
        return $false
    }

    $backup = New-BackupSnapshot -Reason 'Antes_Habilitar_TRIM' -TryRestorePoint
    if (-not $backup) {
        Write-Log 'TRIM nao sera alterado porque o snapshot falhou.' 'ERROR'
        return $false
    }

    $code = Invoke-CommandLogged -File 'fsutil.exe' `
        -Arguments @('behavior','set','DisableDeleteNotify','0') `
        -FriendlyName 'Habilitar TRIM/DisableDeleteNotify=0'

    if ($code -eq 0) {
        Write-Log 'TRIM habilitado. Dispositivos sem suporte simplesmente nao utilizarao as notificacoes.' 'OK'
        return $true
    }
    Write-Log 'Nao foi possivel habilitar o TRIM.' 'ERROR'
    return $false
}

function Add-CreatedPowerSchemeToSnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$SnapshotDirectory,
        [Parameter(Mandatory=$true)][string]$Guid
    )

    try {
        if ($Guid -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
            throw 'GUID de plano de energia invalido.'
        }

        $changesFile = Join-Path $SnapshotDirectory 'changes.json'
        [PSCustomObject]@{
            SchemaVersion       = 1
            CreatedPowerSchemes = @($Guid.ToLowerInvariant())
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $changesFile -Encoding UTF8 -ErrorAction Stop
        return $true
    } catch {
        Write-Log ("Falha ao registrar plano criado no snapshot: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Set-PerformanceProfile {
    Write-Host ''
    Write-Host '=== PERFIL ACCIO PERFORMANCE ===' -ForegroundColor Cyan
    Write-Host 'Aplica ajustes reversiveis: plano de energia de alto desempenho e reducao de efeitos visuais.' -ForegroundColor Gray
    Write-Host 'Em notebook, o consumo e a temperatura podem aumentar quando estiver na tomada.' -ForegroundColor Yellow

    if (-not (Confirm-Accio 'Aplicar o perfil Accio Performance?')) {
        Write-Log 'Perfil de desempenho cancelado.' 'INFO'
        return $false
    }

    $backup = New-BackupSnapshot -Reason 'Antes_Perfil_Desempenho' -TryRestorePoint
    if (-not $backup) {
        Write-Log 'Perfil nao aplicado porque o snapshot interno falhou.' 'ERROR'
        return $false
    }

    # High Performance canonical scheme. If absent, try to duplicate the template.
    $highPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $code = Invoke-CommandLogged -File 'powercfg.exe' -Arguments @('/setactive',$highPerf) -FriendlyName 'Ativar plano Alto Desempenho'

    $powerSuccess = ($code -eq 0)
    if (-not $powerSuccess) {
        Write-Log 'Plano Alto Desempenho nao estava disponivel. Tentando criar uma copia do modelo...' 'INFO'
        try {
            $out = (& powercfg.exe /duplicatescheme $highPerf 2>&1 | Out-String)
            $duplicateCode = $LASTEXITCODE
            if (-not [string]::IsNullOrWhiteSpace($out)) { Write-Log $out.Trim() 'INFO' }
            if ($duplicateCode -eq 0 -and $out -match '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})') {
                $newGuid = $Matches[1].ToLowerInvariant()
                if ($newGuid -eq $highPerf) { throw 'O Windows nao retornou um novo GUID para o plano duplicado.' }

                if (-not (Add-CreatedPowerSchemeToSnapshot -SnapshotDirectory $backup -Guid $newGuid)) {
                    throw 'O plano criado nao pode ser associado ao snapshot.'
                }

                $renameCode = Invoke-CommandLogged -File 'powercfg.exe' `
                    -Arguments @('/changename',$newGuid,'Accio Performance','Plano criado pelo Accio Optimizer') `
                    -FriendlyName 'Nomear plano Accio Performance'
                $activateCode = Invoke-CommandLogged -File 'powercfg.exe' `
                    -Arguments @('/setactive',$newGuid) `
                    -FriendlyName 'Ativar Accio Performance'
                $powerSuccess = ($renameCode -eq 0 -and $activateCode -eq 0)
            } else {
                Write-Log 'Nao foi possivel criar um plano de alto desempenho neste hardware. O Windows pode usar Modern Standby/politicas do fabricante.' 'WARN'
            }
        } catch {
            Write-Log ("Falha ao criar plano de energia: {0}" -f $_.Exception.Message) 'WARN'
        }
    }

    $registrySuccess = $true
    if (-not (Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
        -Name 'EnableTransparency' -Value 0 -Type DWord)) { $registrySuccess = $false }

    if (-not (Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' `
        -Name 'MinAnimate' -Value '0' -Type String)) { $registrySuccess = $false }

    if (-not (Set-RegistryValueSafe -Path 'HKCU:\Control Panel\Desktop' `
        -Name 'MenuShowDelay' -Value '100' -Type String)) { $registrySuccess = $false }

    if (-not (Set-RegistryValueSafe -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
        -Name 'VisualFXSetting' -Value 2 -Type DWord)) { $registrySuccess = $false }

    if ($powerSuccess -and $registrySuccess) {
        Write-Log 'Perfil Accio Performance aplicado. Alguns efeitos visuais so mudam apos sair e entrar na conta ou reiniciar o Explorer/Windows.' 'OK'
        return $true
    }

    Write-Log 'Perfil Accio Performance aplicado apenas parcialmente. Consulte os erros acima e use o rollback se necessario.' 'ERROR'
    return $false
}

function Show-SystemDiagnostic {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '                  ACCIO DIAGNOSTICO' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cs = Get-CimInstance Win32_ComputerSystem
        $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

        Write-Host ('Windows : {0} - Build {1}' -f $os.Caption, $os.BuildNumber)
        Write-Host ('CPU     : {0}' -f $cpu.Name)
        Write-Host ('RAM     : {0} GB' -f $ramGB)
        Write-Host ('PC      : {0}' -f $env:COMPUTERNAME)
        Write-Host ('Usuario : {0}' -f $env:USERNAME)
        Write-Host ('Energia : {0}' -f (Get-ActivePowerSchemeGuid))

        $trim = Get-TrimState
        if ($null -eq $trim) {
            Write-Host 'TRIM    : Nao foi possivel determinar'
        } elseif ($trim -eq 0) {
            Write-Host 'TRIM    : Habilitado (NTFS DisableDeleteNotify = 0)' -ForegroundColor Green
        } else {
            Write-Host 'TRIM    : Desabilitado (NTFS DisableDeleteNotify = 1)' -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host 'Discos fisicos:' -ForegroundColor Cyan
        try {
            Get-PhysicalDisk -ErrorAction Stop |
                Select-Object FriendlyName, MediaType, HealthStatus,
                    @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}} |
                Format-Table -AutoSize
        } catch {
            Write-Host '  Informacao de Get-PhysicalDisk indisponivel.'
        }

        Write-Host 'Volumes:' -ForegroundColor Cyan
        try {
            Get-Volume -ErrorAction Stop |
                Where-Object { $_.DriveLetter } |
                Select-Object DriveLetter, FileSystemLabel, FileSystem,
                    @{N='SizeGB';E={[math]::Round($_.Size/1GB,1)}},
                    @{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB,1)}},
                    @{N='FreePct';E={if ($_.Size -gt 0) {[math]::Round(($_.SizeRemaining/$_.Size)*100,1)} else {0}}} |
                Format-Table -AutoSize
        } catch {}

        Write-Host 'Inicializacao automatica:' -ForegroundColor Cyan
        try {
            $startup = Get-CimInstance Win32_StartupCommand -ErrorAction Stop |
                Select-Object Name, Location, Command
            if ($startup) {
                $startup | Format-Table -AutoSize
            } else {
                Write-Host '  Nenhum item retornado pelo Win32_StartupCommand.'
            }
        } catch {
            Write-Host '  Nao foi possivel consultar.'
        }

        Write-Host ''
        Write-Host ('Log atual: {0}' -f $script:LogFile) -ForegroundColor DarkGray
    } catch {
        Write-Log ("Falha no diagnostico: {0}" -f $_.Exception.Message) 'ERROR'
    }
}

function Open-StartupSettings {
    try {
        Start-Process 'ms-settings:startupapps'
        Write-Log 'Tela de Aplicativos de Inicializacao aberta. Nenhum item foi desativado automaticamente.' 'OK'
    } catch {
        Write-Log 'Nao foi possivel abrir ms-settings:startupapps. Abrindo Gerenciador de Tarefas.' 'WARN'
        try { Start-Process 'taskmgr.exe' } catch {}
    }
}

function Show-WingetUpdates {
    Write-Host ''
    Write-Host '=== ATUALIZACOES DE APLICATIVOS (WINGET) ===' -ForegroundColor Cyan

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Log 'winget nao esta disponivel neste computador.' 'WARN'
        return $false
    }

    $listCode = Invoke-CommandLogged -File 'winget.exe' -Arguments @('upgrade') -FriendlyName 'Listar atualizacoes WinGet'
    if ($listCode -ne 0) {
        Write-Log 'A listagem do WinGet falhou; nenhuma atualizacao sera iniciada.' 'ERROR'
        return $false
    }

    Write-Host ''
    Write-Host 'O Accio Optimizer nao atualiza automaticamente sem sua confirmacao.' -ForegroundColor Gray
    if (Confirm-Accio 'Atualizar todos os pacotes elegiveis listados pelo WinGet?') {
        $backup = New-BackupSnapshot -Reason 'Antes_WinGet_Upgrade'
        if (-not $backup) {
            Write-Log 'A atualizacao foi cancelada porque o snapshot interno falhou.' 'ERROR'
            return $false
        }

        $upgradeCode = Invoke-CommandLogged -File 'winget.exe' `
            -Arguments @('upgrade','--all','--accept-source-agreements','--accept-package-agreements') `
            -FriendlyName 'WinGet Upgrade --all'
        $success = ($upgradeCode -in @(0,3010))
        if (-not $success) {
            Write-Log 'Uma ou mais atualizacoes do WinGet falharam.' 'ERROR'
        }
        return $success
    }
    return $true
}

function Restore-BackupSnapshot {
    Write-Host ''
    Write-Host '=== RESTAURAR SNAPSHOT ACCIO ===' -ForegroundColor Cyan
    Write-Host 'O rollback restaura configuracoes persistentes alteradas pelo Accio (Registro, energia e TRIM).' -ForegroundColor Gray
    Write-Host 'Arquivos temporarios apagados e Lixeira esvaziada nao podem ser recriados pelo rollback.' -ForegroundColor Yellow

    $dirs = @(Get-ChildItem -LiteralPath $script:BackupsPath -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 10)

    if ($dirs.Count -eq 0) {
        Write-Log 'Nenhum snapshot encontrado.' 'WARN'
        return
    }

    Write-Host ''
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        Write-Host ('[{0}] {1}' -f ($i + 1), $dirs[$i].Name)
    }
    Write-Host '[0] Cancelar'

    $choice = Read-Host 'Escolha o snapshot'
    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx)) {
        Write-Log 'Selecao invalida.' 'WARN'
        return
    }
    if ($idx -eq 0) { return }
    if ($idx -lt 1 -or $idx -gt $dirs.Count) {
        Write-Log 'Selecao invalida.' 'WARN'
        return
    }

    $selected = $dirs[$idx - 1]
    $stateFile = Join-Path $selected.FullName 'state.json'
    if (-not (Test-Path -LiteralPath $stateFile)) {
        Write-Log 'state.json nao encontrado neste snapshot.' 'ERROR'
        return
    }

    try {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not (Test-SnapshotState -State $state -SnapshotDirectory $selected.FullName -StateFile $stateFile)) {
            Write-Log 'O snapshot foi recusado: origem, proprietario ou conteudo nao confiavel.' 'ERROR'
            return $false
        }

        if (-not (Confirm-Accio ("Restaurar configuracoes do snapshot {0}?" -f $selected.Name))) {
            return $false
        }

        $success = $true

        foreach ($reg in @($state.RegistryValues)) {
            if (-not (Restore-RegistryValueState -State $reg)) {
                $success = $false
            }
        }

        if ($state.ActivePowerScheme) {
            $guid = [string]$state.ActivePowerScheme
            $code = Invoke-CommandLogged -File 'powercfg.exe' -Arguments @('/setactive',$guid) -FriendlyName 'Restaurar plano de energia'
            if ($code -ne 0) {
                Write-Log 'O esquema salvo pode ter sido removido apos o snapshot.' 'WARN'
                $success = $false
            }
        }

        if ($null -ne $state.TrimDisableNotify) {
            $trimValue = [string]$state.TrimDisableNotify
            $trimCode = Invoke-CommandLogged -File 'fsutil.exe' `
                -Arguments @('behavior','set','DisableDeleteNotify',$trimValue) `
                -FriendlyName 'Restaurar estado do TRIM'
            if ($trimCode -ne 0) { $success = $false }
        }

        $changesFile = Join-Path $selected.FullName 'changes.json'
        if (Test-Path -LiteralPath $changesFile) {
            if (-not (Test-TrustedOwner -Path $changesFile)) {
                Write-Log 'changes.json recusado por possuir proprietario nao confiavel.' 'ERROR'
                $success = $false
            } else {
                $changes = Get-Content -LiteralPath $changesFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                foreach ($createdGuid in @($changes.CreatedPowerSchemes)) {
                    $guidText = [string]$createdGuid
                    if ($guidText -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or $guidText -eq [string]$state.ActivePowerScheme) {
                        Write-Log 'GUID invalido ou inseguro encontrado em changes.json.' 'ERROR'
                        $success = $false
                        continue
                    }

                    $deleteCode = Invoke-CommandLogged -File 'powercfg.exe' `
                        -Arguments @('/delete',$guidText) `
                        -FriendlyName 'Remover plano criado pelo Accio'
                    if ($deleteCode -ne 0) { $success = $false }
                }
            }
        }

        if ($success) {
            Write-Log ("Rollback concluido a partir de: {0}" -f $selected.FullName) 'OK'
        } else {
            Write-Log ("Rollback concluido parcialmente a partir de: {0}" -f $selected.FullName) 'ERROR'
        }
        Write-Host ''
        Write-Host 'Recomenda-se sair e entrar na conta ou reiniciar o Windows para aplicar completamente ajustes visuais.' -ForegroundColor Yellow
        return $success
    } catch {
        Write-Log ("Falha no rollback: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Invoke-RecommendedOptimization {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '            ACCIO - OTIMIZACAO RECOMENDADA' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host 'Esta rotina executa:' -ForegroundColor Gray
    Write-Host '  - Snapshot interno + tentativa de Ponto de Restauracao'
    Write-Host '  - Limpeza segura de temporarios'
    Write-Host '  - Limpeza do Delivery Optimization quando suportada'
    Write-Host '  - DISM StartComponentCleanup sem ResetBase'
    Write-Host '  - Otimizacao de volumes usando a estrategia correta do Windows'
    Write-Host ''
    Write-Host 'Ela NAO desativa servicos, Defender, Update, Search, SysMain, Bluetooth ou impressao.' -ForegroundColor Green
    Write-Host ''

    if (-not (Confirm-Accio 'Executar a otimizacao recomendada?' $false)) {
        return
    }

    $backup = New-BackupSnapshot -Reason 'Antes_Otimizacao_Recomendada' -TryRestorePoint
    if (-not $backup) {
        Write-Log 'A otimizacao recomendada foi cancelada porque o snapshot interno falhou.' 'ERROR'
        return
    }

    $cleanupSuccess = Invoke-SafeCleanup
    $componentSuccess = Invoke-ComponentCleanup
    $volumeSuccess = Invoke-OptimizeVolumes

    if ($cleanupSuccess -and $componentSuccess -and $volumeSuccess) {
        Write-Log 'Otimizacao recomendada concluida.' 'OK'
    } else {
        Write-Log 'Otimizacao recomendada concluida parcialmente. Consulte os avisos e erros acima.' 'ERROR'
    }
    Write-Host ''
    Write-Host 'Opcional: use o menu "Perfil Accio Performance" para reduzir efeitos visuais e ativar Alto Desempenho.' -ForegroundColor Gray
    return ($cleanupSuccess -and $componentSuccess -and $volumeSuccess)
}

function Show-ProtectionPolicy {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host '             POLITICA DE SEGURANCA DO ACCIO' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host 'O Accio Optimizer deliberadamente NAO executa:' -ForegroundColor Yellow
    Write-Host '  - Desativacao do Microsoft Defender'
    Write-Host '  - Desativacao do Windows Update'
    Write-Host '  - Desativacao indiscriminada de servicos'
    Write-Host '  - Exclusao da pasta Prefetch'
    Write-Host '  - "Limpeza" de RAM/standby list'
    Write-Host '  - Alteracoes de HPET/BCD/timer resolution'
    Write-Host '  - Desativacao do arquivo de paginacao'
    Write-Host '  - Tweaks de TCP/Nagle globais para "aumentar internet"'
    Write-Host '  - Remocao automatica de Microsoft Store/Xbox/OneDrive'
    Write-Host '  - DISM /ResetBase na rotina recomendada'
    Write-Host ''
    Write-Host 'Essas alteracoes frequentemente oferecem ganho pequeno, nulo ou dependente do hardware e podem reduzir estabilidade, seguranca ou compatibilidade.' -ForegroundColor Gray
}

function Show-MainMenu {
    while ($true) {
        Clear-Host
        $host.UI.RawUI.WindowTitle = "$script:AppName $script:Version"

        Write-Host '============================================================' -ForegroundColor DarkCyan
        Write-Host '                    ACCIO OPTIMIZER' -ForegroundColor Cyan
        Write-Host ("                      v{0}" -f $script:Version) -ForegroundColor DarkGray
        Write-Host '============================================================' -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '[1]  Otimizacao segura recomendada' -ForegroundColor Green
        Write-Host '[2]  Limpeza segura de temporarios e caches'
        Write-Host '[3]  Otimizar SSD/HDD (TRIM/Defrag automatico)'
        Write-Host '[4]  Limpar Component Store (DISM)'
        Write-Host '[5]  Reparar Windows (DISM RestoreHealth + SFC)'
        Write-Host '[6]  Aplicar Perfil Accio Performance' -ForegroundColor Yellow
        Write-Host '[7]  Diagnostico do computador'
        Write-Host '[8]  Verificar/Habilitar TRIM'
        Write-Host '[9]  Gerenciar aplicativos de inicializacao'
        Write-Host '[10] Ver/instalar atualizacoes de apps via WinGet'
        Write-Host '[11] Limpeza profunda opcional' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '[12] Criar snapshot + Ponto de Restauracao'
        Write-Host '[13] Restaurar snapshot / rollback' -ForegroundColor Cyan
        Write-Host '[14] Ver politica de seguranca'
        Write-Host '[15] Limpar cache DNS (diagnostico)'
        Write-Host ''
        Write-Host '[0]  Sair'
        Write-Host ''
        Write-Host ("Dados: {0}" -f $script:BasePath) -ForegroundColor DarkGray
        Write-Host ("Log  : {0}" -f $script:LogFile) -ForegroundColor DarkGray
        Write-Host ''

        $option = Read-Host 'Escolha uma opcao'

        switch ($option) {
            '1'  { Invoke-RecommendedOptimization | Out-Null; Pause-Accio }
            '2'  { Invoke-SafeCleanup | Out-Null; Pause-Accio }
            '3'  { Invoke-OptimizeVolumes | Out-Null; Pause-Accio }
            '4'  { Invoke-ComponentCleanup | Out-Null; Pause-Accio }
            '5'  { Invoke-WindowsRepair | Out-Null; Pause-Accio }
            '6'  { Set-PerformanceProfile | Out-Null; Pause-Accio }
            '7'  { Show-SystemDiagnostic; Pause-Accio }
            '8'  { Enable-TrimSafely | Out-Null; Pause-Accio }
            '9'  { Open-StartupSettings; Pause-Accio }
            '10' { Show-WingetUpdates | Out-Null; Pause-Accio }
            '11' { Invoke-DeepCleanup | Out-Null; Pause-Accio }
            '12' { New-BackupSnapshot -Reason 'Manual' -TryRestorePoint | Out-Null; Pause-Accio }
            '13' { Restore-BackupSnapshot | Out-Null; Pause-Accio }
            '14' { Show-ProtectionPolicy; Pause-Accio }
            '15' { Invoke-DnsCacheCleanup | Out-Null; Pause-Accio }
            '0'  {
                Write-Log 'Accio Optimizer encerrado pelo usuario.' 'INFO'
                return
            }
            default {
                Write-Host 'Opcao invalida.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

Write-Log ("Iniciando {0} v{1}" -f $script:AppName, $script:Version) 'INFO'
Write-Log ("Windows PowerShell {0}" -f $PSVersionTable.PSVersion.ToString()) 'INFO'
Write-Log ("Executando como Administrador: {0}" -f (Test-IsAdministrator)) 'INFO'

if (Test-SupportedWindows) {
    Show-MainMenu
    if ($script:HadErrors) { exit 1 }
    exit 0
} else {
    Write-Host ''
    Write-Host 'Sistema nao suportado. O Accio Optimizer sera encerrado.' -ForegroundColor Red
    Pause-Accio
    exit 1
}
