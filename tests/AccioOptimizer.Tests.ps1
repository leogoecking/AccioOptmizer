#requires -version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'AccioOptimizer.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $source, [ref]$tokens, [ref]$parseErrors
)

$failures = New-Object System.Collections.Generic.List[string]

function Assert-Accio {
    param(
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$true)][string]$Message
    )

    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Message) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] {0}" -f $Message) -ForegroundColor Red
        $failures.Add($Message)
    }
}

Assert-Accio -Condition ($parseErrors.Count -eq 0) -Message 'O script nao possui erros de sintaxe.'

$definitions = @{}
$ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object {
    $definitions[$_.Name] = $_.Extent.Text
}

$requiredFunctions = @(
    'Write-Log',
    'Invoke-CommandLogged',
    'Set-RegistryValueSafe',
    'Test-CleanupPathSafe',
    'Get-NormalizedDirectoryPath',
    'Test-RegistryTargetAllowed',
    'Test-TrustedOwner',
    'Test-SnapshotState'
)

foreach ($name in $requiredFunctions) {
    if (-not $definitions.ContainsKey($name)) {
        throw ("Funcao necessaria ao teste nao encontrada: {0}" -f $name)
    }
    Invoke-Expression $definitions[$name]
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AccioOptimizerTests_{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop | Out-Null

try {
    $script:LogFile = Join-Path $testRoot 'test.log'
    $script:HadErrors = $false

    $blankLineCode = Invoke-CommandLogged -File 'cmd.exe' `
        -Arguments @('/d','/c','(echo first&echo.&echo last)') `
        -FriendlyName 'Teste de linha vazia'
    Assert-Accio -Condition ($blankLineCode -eq 0) -Message 'Linhas vazias nao interrompem comandos externos.'

    $nonZeroCode = Invoke-CommandLogged -File 'cmd.exe' `
        -Arguments @('/d','/c','exit 7') `
        -FriendlyName 'Teste de codigo de saida'
    Assert-Accio -Condition ($nonZeroCode -eq 7) -Message 'Codigos de erro de comandos externos sao preservados.'

    $invalidRegistry = Set-RegistryValueSafe -Path 'Z:\AccioNaoExiste' `
        -Name 'Test' -Value 1 -Type DWord
    Assert-Accio -Condition (-not $invalidRegistry) -Message 'Falhas de gravacao no Registro sao propagadas.'
    Assert-Accio -Condition $script:HadErrors -Message 'Falhas definem o codigo global de erro.'

    $script:CommonAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $script:LocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $script:WindowsPath = Split-Path -Parent ([Environment]::SystemDirectory)
    $safeTemp = Join-Path $script:LocalAppData 'Temp'
    Assert-Accio -Condition (Test-CleanupPathSafe -Path $safeTemp) -Message 'Um diretorio Temp valido e aceito.'
    Assert-Accio -Condition (-not (Test-CleanupPathSafe -Path ([IO.Path]::GetPathRoot($testRoot)))) `
        -Message 'A raiz da unidade e recusada para limpeza.'
    $untrustedTemp = Join-Path $testRoot 'Temp'
    New-Item -ItemType Directory -Path $untrustedTemp -ErrorAction Stop | Out-Null
    Assert-Accio -Condition (-not (Test-CleanupPathSafe -Path $untrustedTemp)) `
        -Message 'Um diretorio chamado Temp fora da lista permitida e recusado.'

    if ((Test-Path -LiteralPath $env:TEMP) -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Temp'))) {
        $tempKey = Get-NormalizedDirectoryPath -Path $env:TEMP
        $localTempKey = Get-NormalizedDirectoryPath -Path (Join-Path $script:LocalAppData 'Temp')
        Assert-Accio -Condition ($tempKey -eq $localTempKey) -Message 'Nomes curto e longo do Temp sao deduplicados.'
    }

    $script:RegistryTargets = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency' },
        @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate' },
        @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'MenuShowDelay' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting' }
    )
    $script:BackupsPath = Join-Path $testRoot 'Backups'
    $snapshotDirectory = Join-Path $script:BackupsPath 'snapshot'
    New-Item -ItemType Directory -Path $snapshotDirectory -Force -ErrorAction Stop | Out-Null

    $state = [PSCustomObject]@{
        SchemaVersion     = 1
        AppVersion        = 'test'
        ComputerName      = $env:COMPUTERNAME
        UserName          = $env:USERNAME
        ActivePowerScheme = '381b4222-f694-41f0-9685-ff5bb260df2e'
        TrimDisableNotify = 0
        RegistryValues    = @(
            [PSCustomObject]@{ Path=$script:RegistryTargets[0].Path; Name=$script:RegistryTargets[0].Name; KeyExists=$true; Exists=$true; Kind='DWord'; Value=1 },
            [PSCustomObject]@{ Path=$script:RegistryTargets[1].Path; Name=$script:RegistryTargets[1].Name; KeyExists=$true; Exists=$true; Kind='String'; Value='1' },
            [PSCustomObject]@{ Path=$script:RegistryTargets[2].Path; Name=$script:RegistryTargets[2].Name; KeyExists=$true; Exists=$true; Kind='String'; Value='400' },
            [PSCustomObject]@{ Path=$script:RegistryTargets[3].Path; Name=$script:RegistryTargets[3].Name; KeyExists=$true; Exists=$true; Kind='DWord'; Value=0 }
        )
    }

    $stateFile = Join-Path $snapshotDirectory 'state.json'
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8 -ErrorAction Stop
    Assert-Accio -Condition (Test-SnapshotState -State $state -SnapshotDirectory $snapshotDirectory -StateFile $stateFile) `
        -Message 'Um snapshot valido e aceito.'

    $injectedState = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $injectedState.RegistryValues[0].Path = 'HKLM:\SOFTWARE\AccioInjected'
    Assert-Accio -Condition (-not (Test-SnapshotState -State $injectedState -SnapshotDirectory $snapshotDirectory -StateFile $stateFile)) `
        -Message 'Um destino de Registro injetado e recusado.'

    $wrongComputerState = $state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $wrongComputerState.ComputerName = 'OUTRO-COMPUTADOR'
    Assert-Accio -Condition (-not (Test-SnapshotState -State $wrongComputerState -SnapshotDirectory $snapshotDirectory -StateFile $stateFile)) `
        -Message 'Um snapshot de outro computador e recusado.'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("{0} teste(s) falharam." -f $failures.Count) -ForegroundColor Red
    exit 1
}

Write-Host 'Todos os testes passaram.' -ForegroundColor Green
exit 0
