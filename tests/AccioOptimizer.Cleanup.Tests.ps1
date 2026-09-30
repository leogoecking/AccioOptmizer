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

function Assert-Cleanup {
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

Assert-Cleanup -Condition ($parseErrors.Count -eq 0) -Message 'O script principal possui sintaxe valida.'

$definitions = @{}
$ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object {
    $definitions[$_.Name] = $_.Extent.Text
}

foreach ($name in @(
    'Write-Log',
    'Get-NormalizedDirectoryPath',
    'Test-CleanupPathSafe',
    'Clear-DirectoryContentSafe',
    'Invoke-SafeCleanup',
    'Invoke-DeepCleanup'
)) {
    if (-not $definitions.ContainsKey($name)) {
        throw ("Funcao necessaria ao teste nao encontrada: {0}" -f $name)
    }
    Invoke-Expression $definitions[$name]
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AccioCleanupTests_{0}" -f [guid]::NewGuid().ToString('N'))
$script:LocalAppData = Join-Path $testRoot 'UserLocal'
$script:WindowsPath = Join-Path $testRoot 'Windows'
$script:CommonAppData = Join-Path $testRoot 'ProgramData'
$script:LogFile = Join-Path $testRoot 'cleanup.log'
$script:HadErrors = $false
$script:DeliveryCalled = $false

$userTemp = Join-Path $script:LocalAppData 'Temp'
$windowsTemp = Join-Path $script:WindowsPath 'Temp'
$shaderCache = Join-Path $script:LocalAppData 'D3DSCache'
$werQueue = Join-Path $script:CommonAppData 'Microsoft\Windows\WER\ReportQueue'
$werArchive = Join-Path $script:CommonAppData 'Microsoft\Windows\WER\ReportArchive'
$outside = Join-Path $testRoot 'Outside'

function New-TestDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
}

function Get-ChildCount {
    param([Parameter(Mandatory=$true)][string]$Path)
    return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop).Count
}

function global:Delete-DeliveryOptimizationCache {
    param([switch]$Force)
    $script:DeliveryCalled = $true
}

$script:ConfirmAnswers = New-Object 'System.Collections.Generic.Queue[bool]'
function global:Confirm-Accio {
    param(
        [Parameter(Mandatory=$true)][string]$Question,
        [bool]$DefaultNo = $true
    )
    if ($script:ConfirmAnswers.Count -eq 0) { throw 'Resposta de confirmacao nao configurada no teste.' }
    return $script:ConfirmAnswers.Dequeue()
}

New-TestDirectory -Path $testRoot

try {
    New-TestDirectory -Path $userTemp
    New-TestDirectory -Path (Join-Path $userTemp 'Nested')
    Set-Content -LiteralPath (Join-Path $userTemp 'normal.tmp') -Value 'normal' -Encoding UTF8 -ErrorAction Stop
    Set-Content -LiteralPath (Join-Path $userTemp 'Nested\nested.tmp') -Value 'nested' -Encoding UTF8 -ErrorAction Stop
    $hiddenFile = Join-Path $userTemp 'hidden.tmp'
    Set-Content -LiteralPath $hiddenFile -Value 'hidden' -Encoding UTF8 -ErrorAction Stop
    (Get-Item -LiteralPath $hiddenFile -Force).Attributes = [IO.FileAttributes]::Hidden

    $junctionTarget = Join-Path $outside 'JunctionTarget'
    $junctionPath = Join-Path $userTemp 'PreservedJunction'
    New-TestDirectory -Path $junctionTarget
    Set-Content -LiteralPath (Join-Path $junctionTarget 'must-survive.txt') -Value 'outside' -Encoding UTF8 -ErrorAction Stop
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    } catch {
        Write-Host ("[SKIP] Junction indisponivel neste ambiente: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    $singleResult = Clear-DirectoryContentSafe -Path $userTemp -Label 'Fixture Temp'
    Assert-Cleanup -Condition $singleResult -Message 'A limpeza controlada conclui sem abortar.'
    Assert-Cleanup -Condition (Test-Path -LiteralPath $userTemp -PathType Container) -Message 'O diretorio-pai Temp e preservado.'
    Assert-Cleanup -Condition (-not (Test-Path -LiteralPath (Join-Path $userTemp 'normal.tmp'))) -Message 'Arquivo temporario normal e removido.'
    Assert-Cleanup -Condition (-not (Test-Path -LiteralPath (Join-Path $userTemp 'Nested'))) -Message 'Subdiretorio temporario e removido recursivamente.'
    Assert-Cleanup -Condition (-not (Test-Path -LiteralPath $hiddenFile)) -Message 'Arquivo oculto e removido.'

    if ($junctionCreated) {
        Assert-Cleanup -Condition (Test-Path -LiteralPath $junctionPath) -Message 'Junction dentro do Temp e preservada.'
        Assert-Cleanup -Condition (Test-Path -LiteralPath (Join-Path $junctionTarget 'must-survive.txt')) -Message 'Destino externo da junction permanece intacto.'

        $originalLocalAppData = $script:LocalAppData
        $rootJunctionLocal = Join-Path $testRoot 'RootJunctionLocal'
        $rootJunctionTarget = Join-Path $outside 'RootJunctionTarget'
        $rootJunctionPath = Join-Path $rootJunctionLocal 'Temp'
        New-TestDirectory -Path $rootJunctionLocal
        New-TestDirectory -Path $rootJunctionTarget
        $rootTargetMarker = Join-Path $rootJunctionTarget 'must-survive-root.txt'
        Set-Content -LiteralPath $rootTargetMarker -Value 'outside-root' -Encoding UTF8 -ErrorAction Stop
        New-Item -ItemType Junction -Path $rootJunctionPath -Target $rootJunctionTarget -ErrorAction Stop | Out-Null
        $script:LocalAppData = $rootJunctionLocal
        try {
            $rootJunctionResult = Clear-DirectoryContentSafe -Path $rootJunctionPath -Label 'Temp raiz redirecionado'
            Assert-Cleanup -Condition (-not $rootJunctionResult) -Message 'O proprio Temp como junction e recusado.'
            Assert-Cleanup -Condition (Test-Path -LiteralPath $rootTargetMarker) -Message 'O destino externo do Temp-junction permanece intacto.'
        } finally {
            $script:LocalAppData = $originalLocalAppData
        }

        $ancestorJunctionRoot = Join-Path $testRoot 'AncestorJunction'
        $ancestorJunctionTarget = Join-Path $outside 'AncestorJunctionTarget'
        $ancestorJunctionTargetTemp = Join-Path $ancestorJunctionTarget 'Temp'
        $ancestorJunctionPath = Join-Path $ancestorJunctionRoot 'UserLocalLink'
        New-TestDirectory -Path $ancestorJunctionRoot
        New-TestDirectory -Path $ancestorJunctionTargetTemp
        $ancestorTargetMarker = Join-Path $ancestorJunctionTargetTemp 'must-survive-ancestor.txt'
        Set-Content -LiteralPath $ancestorTargetMarker -Value 'outside-ancestor' -Encoding UTF8 -ErrorAction Stop
        New-Item -ItemType Junction -Path $ancestorJunctionPath -Target $ancestorJunctionTarget -ErrorAction Stop | Out-Null
        $script:LocalAppData = $ancestorJunctionPath
        try {
            $ancestorResult = Clear-DirectoryContentSafe -Path (Join-Path $ancestorJunctionPath 'Temp') -Label 'Temp com ancestral redirecionado'
            Assert-Cleanup -Condition ((-not $ancestorResult) -and (Test-Path -LiteralPath $ancestorTargetMarker -PathType Leaf)) -Message 'H1: junction ancestral e recusada e o marcador externo permanece intacto.'
        } finally {
            $script:LocalAppData = $originalLocalAppData
        }
    }

    $rootFileLocal = Join-Path $testRoot 'RootFileLocal'
    $rootFilePath = Join-Path $rootFileLocal 'Temp'
    New-TestDirectory -Path $rootFileLocal
    Set-Content -LiteralPath $rootFilePath -Value 'root-file' -Encoding UTF8 -ErrorAction Stop
    $originalLocalAppData = $script:LocalAppData
    $script:LocalAppData = $rootFileLocal
    try {
        $rootFileResult = Clear-DirectoryContentSafe -Path $rootFilePath -Label 'Arquivo no lugar do Temp'
        Assert-Cleanup -Condition ((-not $rootFileResult) -and (Test-Path -LiteralPath $rootFilePath -PathType Leaf)) -Message 'H2: arquivo no lugar da raiz e recusado e preservado.'
    } finally {
        $script:LocalAppData = $originalLocalAppData
    }

    $unsafeMissing = Join-Path $testRoot 'NaoPermitido\Temp'
    $unsafeResult = Clear-DirectoryContentSafe -Path $unsafeMissing -Label 'Caminho inseguro inexistente'
    Assert-Cleanup -Condition (-not $unsafeResult) -Message 'Caminho fora da allowlist e recusado mesmo quando ainda nao existe.'

    $allowedMissing = $werArchive
    $allowedMissingResult = Clear-DirectoryContentSafe -Path $allowedMissing -Label 'Caminho permitido inexistente'
    Assert-Cleanup -Condition $allowedMissingResult -Message 'Caminho permitido e inexistente continua sendo ignorado com sucesso.'
    Assert-Cleanup -Condition (-not (Test-Path -LiteralPath $allowedMissing)) -Message 'Validar caminho permitido inexistente nao cria o diretorio.'

    $lockedFile = Join-Path $userTemp 'locked.tmp'
    Set-Content -LiteralPath $lockedFile -Value 'locked' -Encoding UTF8 -ErrorAction Stop
    $lockStream = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lockedResult = Clear-DirectoryContentSafe -Path $userTemp -Label 'Fixture com arquivo bloqueado'
        Assert-Cleanup -Condition $lockedResult -Message 'Arquivo bloqueado e tratado como preservado, sem abortar a rotina.'
        Assert-Cleanup -Condition (Test-Path -LiteralPath $lockedFile) -Message 'Arquivo bloqueado permanece no disco.'
    } finally {
        $lockStream.Dispose()
    }
    Remove-Item -LiteralPath $lockedFile -Force -ErrorAction Stop

    foreach ($path in @($userTemp, $windowsTemp)) {
        New-TestDirectory -Path $path
        Set-Content -LiteralPath (Join-Path $path 'safe-cleanup.tmp') -Value 'remove' -Encoding UTF8 -ErrorAction Stop
    }
    $script:DeliveryCalled = $false
    $safeResult = Invoke-SafeCleanup
    Assert-Cleanup -Condition $safeResult -Message 'A limpeza segura retorna sucesso quando todas as etapas concluem.'
    Assert-Cleanup -Condition $script:DeliveryCalled -Message 'O cache do Delivery Optimization e solicitado.'
    Assert-Cleanup -Condition ((Get-ChildCount -Path $userTemp) -eq $(if ($junctionCreated) { 1 } else { 0 })) -Message 'O Temp do usuario fica sem arquivos removiveis.'
    Assert-Cleanup -Condition ((Get-ChildCount -Path $windowsTemp) -eq 0) -Message 'O Temp do Windows fica vazio na fixture.'

    function global:Delete-DeliveryOptimizationCache {
        param([switch]$Force)
        throw 'Falha simulada do Delivery Optimization'
    }
    $script:HadErrors = $false
    $deliveryFailureResult = Invoke-SafeCleanup
    Assert-Cleanup -Condition (-not $deliveryFailureResult) -Message 'Falha do Delivery Optimization e propagada.'
    Assert-Cleanup -Condition $script:HadErrors -Message 'Falha agregada da limpeza e registrada como erro.'

    function global:Delete-DeliveryOptimizationCache {
        param([switch]$Force)
        $script:DeliveryCalled = $true
    }
    foreach ($path in @($shaderCache, $werQueue, $werArchive)) {
        New-TestDirectory -Path $path
        Set-Content -LiteralPath (Join-Path $path 'deep.tmp') -Value 'remove' -Encoding UTF8 -ErrorAction Stop
    }
    $script:ConfirmAnswers.Enqueue($false)
    $cancelResult = Invoke-DeepCleanup
    Assert-Cleanup -Condition $cancelResult -Message 'Cancelar a limpeza profunda nao e tratado como erro.'
    Assert-Cleanup -Condition (Test-Path -LiteralPath (Join-Path $shaderCache 'deep.tmp')) -Message 'Cancelar preserva o conteudo da limpeza profunda.'

    $script:ConfirmAnswers.Enqueue($true)
    $script:ConfirmAnswers.Enqueue($false)
    $deepResult = Invoke-DeepCleanup
    Assert-Cleanup -Condition $deepResult -Message 'A limpeza profunda conclui quando confirmada e a Lixeira e preservada.'
    foreach ($path in @($shaderCache, $werQueue, $werArchive)) {
        Assert-Cleanup -Condition (Test-Path -LiteralPath $path -PathType Container) -Message ("Diretorio profundo preservado: {0}" -f $path)
        Assert-Cleanup -Condition ((Get-ChildCount -Path $path) -eq 0) -Message ("Conteudo profundo removido: {0}" -f $path)
    }

    $logText = Get-Content -LiteralPath $script:LogFile -Raw -Encoding UTF8
    Assert-Cleanup -Condition ($logText -match 'Link/junction preservado|Junction indisponivel') -Message 'A preservacao de reparse point fica observavel no teste/log.'
    Assert-Cleanup -Condition ($logText -match 'em uso/protegido') -Message 'Arquivos bloqueados ficam registrados no log.'
    Assert-Cleanup -Condition ($logText -match 'A limpeza segura terminou com uma ou mais falhas') -Message 'Falha agregada fica registrada no log.'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("{0} teste(s) de limpeza falharam." -f $failures.Count) -ForegroundColor Red
    exit 1
}

Write-Host 'Todos os testes de limpeza passaram.' -ForegroundColor Green
exit 0
