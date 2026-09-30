#requires -version 5.1

[CmdletBinding()]
param(
    [switch]$OnlyH1H2
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $projectRoot 'AccioOptimizer.ps1') -Raw -Encoding UTF8
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'O script principal nao possui sintaxe valida.' }

$definitions = @{}
$ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $definitions[$_.Name] = $_.Extent.Text }

foreach ($name in @('Write-Log', 'Get-NormalizedDirectoryPath', 'Test-CleanupPathSafe', 'Clear-DirectoryContentSafe')) {
    if (-not $definitions.ContainsKey($name)) { throw ("Funcao ausente: {0}" -f $name) }
    Invoke-Expression $definitions[$name]
}

$fixtureParent = Join-Path $PSScriptRoot '.fixtures'
$fixtureRoot = Join-Path $fixtureParent ("AccioBugHunt_{0}" -f [guid]::NewGuid().ToString('N'))
$results = New-Object System.Collections.Generic.List[object]

function New-Directory {
    param([Parameter(Mandatory=$true)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
}

function Set-CaseContext {
    param(
        [Parameter(Mandatory=$true)][string]$CaseRoot,
        [Parameter(Mandatory=$true)][string]$LocalPath
    )
    New-Directory -Path $CaseRoot
    $script:LocalAppData = $LocalPath
    $script:WindowsPath = Join-Path $CaseRoot 'SyntheticWindows'
    $script:CommonAppData = Join-Path $CaseRoot 'SyntheticProgramData'
    $script:LogFile = Join-Path $CaseRoot 'experiment.log'
    $script:HadErrors = $false
}

function Add-Result {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Hypothesis,
        [Parameter(Mandatory=$true)][string]$Expected,
        [Parameter(Mandatory=$true)][string]$Observed,
        [Parameter(Mandatory=$true)][bool]$MeetsExpected
    )
    $results.Add([PSCustomObject]@{
        Id = $Id
        Hypothesis = $Hypothesis
        Expected = $Expected
        Observed = $Observed
        Signal = $(if ($MeetsExpected) { 'EXPECTED' } else { 'BUG_CANDIDATE' })
    })
}

function Add-Inconclusive {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Hypothesis,
        [Parameter(Mandatory=$true)][string]$Expected,
        [Parameter(Mandatory=$true)][string]$Reason
    )
    $results.Add([PSCustomObject]@{
        Id = $Id
        Hypothesis = $Hypothesis
        Expected = $Expected
        Observed = $Reason
        Signal = 'INCONCLUSIVE'
    })
}

New-Directory -Path $fixtureRoot

try {
    # H1: junction em ancestral da raiz permitida.
    $caseRoot = Join-Path $fixtureRoot 'H1-AncestorJunction'
    $externalBase = Join-Path $caseRoot 'SyntheticExternal\UserLocal'
    $externalTemp = Join-Path $externalBase 'Temp'
    $localLink = Join-Path $caseRoot 'UserLocalLink'
    $marker = Join-Path $externalTemp 'must-survive.txt'
    New-Directory -Path $externalTemp
    Set-Content -LiteralPath $marker -Value 'synthetic-h1' -Encoding UTF8
    try {
        New-Item -ItemType Junction -Path $localLink -Target $externalBase -ErrorAction Stop | Out-Null
        Set-CaseContext -CaseRoot $caseRoot -LocalPath $localLink
        $result = Clear-DirectoryContentSafe -Path (Join-Path $localLink 'Temp') -Label 'H1 ancestor junction'
        $markerSurvived = Test-Path -LiteralPath $marker -PathType Leaf
        $meetsExpected = ((-not $result) -and $markerSurvived)
        Add-Result -Id 'H1' `
            -Hypothesis 'Uma junction em ancestral da raiz permitida pode redirecionar a limpeza.' `
            -Expected 'retorno=False AND marcadorSobreviveu=True' `
            -Observed ("retorno={0}; marcadorSobreviveu={1}" -f $result, $markerSurvived) `
            -MeetsExpected $meetsExpected
    } catch {
        Add-Inconclusive -Id 'H1' -Hypothesis 'Junction em ancestral.' `
            -Expected 'retorno=False AND marcadorSobreviveu=True' -Reason $_.Exception.Message
    }

    # H2: arquivo regular no lugar do diretorio-raiz permitido.
    $caseRoot = Join-Path $fixtureRoot 'H2-RootFile'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $rootFile = Join-Path $localBase 'Temp'
    New-Directory -Path $localBase
    Set-Content -LiteralPath $rootFile -Value 'synthetic-h2' -Encoding UTF8
    Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
    $result = Clear-DirectoryContentSafe -Path $rootFile -Label 'H2 arquivo no lugar da raiz'
    $rootFileSurvived = Test-Path -LiteralPath $rootFile -PathType Leaf
    $meetsExpected = ((-not $result) -and $rootFileSurvived)
    Add-Result -Id 'H2' `
        -Hypothesis 'Um arquivo regular no caminho permitido pode ser aceito como diretorio de limpeza.' `
        -Expected 'retorno=False AND arquivoRaizSobreviveu=True' `
        -Observed ("retorno={0}; arquivoRaizSobreviveu={1}" -f $result, $rootFileSurvived) `
        -MeetsExpected $meetsExpected

    if (-not $OnlyH1H2) {
    # H3: junction aninhada abaixo de diretorio comum removido recursivamente.
    $caseRoot = Join-Path $fixtureRoot 'H3-NestedJunction'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $tempPath = Join-Path $localBase 'Temp'
    $wrapper = Join-Path $tempPath 'Wrapper'
    $external = Join-Path $caseRoot 'SyntheticExternal\NestedTarget'
    $marker = Join-Path $external 'must-survive.txt'
    New-Directory -Path $wrapper
    New-Directory -Path $external
    Set-Content -LiteralPath $marker -Value 'synthetic-h3' -Encoding UTF8
    try {
        New-Item -ItemType Junction -Path (Join-Path $wrapper 'NestedLink') -Target $external -ErrorAction Stop | Out-Null
        Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
        $result = Clear-DirectoryContentSafe -Path $tempPath -Label 'H3 junction aninhada'
        $markerSurvived = Test-Path -LiteralPath $marker -PathType Leaf
        $meetsExpected = ($result -and $markerSurvived)
        Add-Result -Id 'H3' `
            -Hypothesis 'Remove-Item recursivo pode atravessar junction que nao e filha imediata.' `
            -Expected 'retorno=True AND marcadorSobreviveu=True' `
            -Observed ("retorno={0}; marcadorSobreviveu={1}" -f $result, $markerSurvived) `
            -MeetsExpected $meetsExpected
    } catch {
        Add-Inconclusive -Id 'H3' -Hypothesis 'Junction aninhada.' `
            -Expected 'retorno=True AND marcadorSobreviveu=True' -Reason $_.Exception.Message
    }

    # H4: junction-raiz quebrada.
    $caseRoot = Join-Path $fixtureRoot 'H4-BrokenRootJunction'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $target = Join-Path $caseRoot 'EphemeralTarget'
    $rootLink = Join-Path $localBase 'Temp'
    New-Directory -Path $localBase
    New-Directory -Path $target
    try {
        New-Item -ItemType Junction -Path $rootLink -Target $target -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
        $result = Clear-DirectoryContentSafe -Path $rootLink -Label 'H4 junction quebrada'
        $rootItem = Get-Item -LiteralPath $rootLink -Force -ErrorAction SilentlyContinue
        $junctionExists = ($null -ne $rootItem)
        $isReparse = $junctionExists -and (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        $meetsExpected = ((-not $result) -and $junctionExists -and $isReparse)
        Add-Result -Id 'H4' `
            -Hypothesis 'Uma junction-raiz quebrada pode ser confundida com caminho permitido inexistente.' `
            -Expected 'retorno=False AND junctionAindaExiste=True AND detectadaComoReparse=True' `
            -Observed ("retorno={0}; junctionAindaExiste={1}; detectadaComoReparse={2}" -f $result, $junctionExists, $isReparse) `
            -MeetsExpected $meetsExpected
    } catch {
        Add-Inconclusive -Id 'H4' -Hypothesis 'Junction-raiz quebrada.' `
            -Expected 'retorno=False AND junctionAindaExiste=True AND detectadaComoReparse=True' -Reason $_.Exception.Message
    }

    # H5: hard link interno para arquivo sintetico externo a raiz de limpeza.
    $caseRoot = Join-Path $fixtureRoot 'H5-HardLink'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $tempPath = Join-Path $localBase 'Temp'
    $external = Join-Path $caseRoot 'SyntheticExternal'
    $sourceFile = Join-Path $external 'source.txt'
    $hardLink = Join-Path $tempPath 'linked.txt'
    $expectedContent = "synthetic-h5`r`n"
    New-Directory -Path $tempPath
    New-Directory -Path $external
    Set-Content -LiteralPath $sourceFile -Value 'synthetic-h5' -Encoding UTF8
    try {
        New-Item -ItemType HardLink -Path $hardLink -Target $sourceFile -ErrorAction Stop | Out-Null
        Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
        $result = Clear-DirectoryContentSafe -Path $tempPath -Label 'H5 hard link'
        $internalLinkGone = -not (Test-Path -LiteralPath $hardLink)
        $sourceSurvived = Test-Path -LiteralPath $sourceFile -PathType Leaf
        $contentUnchanged = $sourceSurvived -and ((Get-Content -LiteralPath $sourceFile -Raw) -eq $expectedContent)
        $meetsExpected = ($result -and $internalLinkGone -and $sourceSurvived -and $contentUnchanged)
        Add-Result -Id 'H5' `
            -Hypothesis 'Excluir hard link interno pode remover o nome externo ou alterar seus dados.' `
            -Expected 'retorno=True AND linkInternoRemovido=True AND fonteSobreviveu=True AND conteudoInalterado=True' `
            -Observed ("retorno={0}; linkInternoRemovido={1}; fonteSobreviveu={2}; conteudoInalterado={3}" -f $result, $internalLinkGone, $sourceSurvived, $contentUnchanged) `
            -MeetsExpected $meetsExpected
    } catch {
        Add-Inconclusive -Id 'H5' -Hypothesis 'Hard link interno.' `
            -Expected 'retorno=True AND linkInternoRemovido=True AND fonteSobreviveu=True AND conteudoInalterado=True' -Reason $_.Exception.Message
    }

    # H6: alias equivalente e idempotencia.
    $caseRoot = Join-Path $fixtureRoot 'H6-AliasAndIdempotency'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $tempPath = Join-Path $localBase 'Temp'
    $marker = Join-Path $tempPath 'remove.txt'
    New-Directory -Path $tempPath
    Set-Content -LiteralPath $marker -Value 'synthetic-h6' -Encoding UTF8
    Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
    $first = Clear-DirectoryContentSafe -Path (Join-Path $tempPath '.') -Label 'H6 alias equivalente'
    $second = Clear-DirectoryContentSafe -Path $tempPath -Label 'H6 segunda execucao'
    $rootSurvived = Test-Path -LiteralPath $tempPath -PathType Container
    $markerRemoved = -not (Test-Path -LiteralPath $marker)
    $meetsExpected = ($first -and $second -and $rootSurvived -and $markerRemoved)
    Add-Result -Id 'H6' `
        -Hypothesis 'Alias equivalente ou repeticao pode contornar allowlist ou remover a raiz.' `
        -Expected 'primeira=True AND segunda=True AND raizSobreviveu=True AND marcadorRemovido=True' `
        -Observed ("primeira={0}; segunda={1}; raizSobreviveu={2}; marcadorRemovido={3}" -f $first, $second, $rootSurvived, $markerRemoved) `
        -MeetsExpected $meetsExpected
    }
} finally {
    $allowedParent = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\') + '\'
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\') + '\'
    if ($resolvedFixture.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results | ConvertTo-Json -Depth 4
