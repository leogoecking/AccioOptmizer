#requires -version 5.1

[CmdletBinding()]
param()

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
    Invoke-Expression $definitions[$name]
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AccioBugHunt_{0}" -f [guid]::NewGuid().ToString('N'))
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
    $script:WindowsPath = Join-Path $CaseRoot 'Windows'
    $script:CommonAppData = Join-Path $CaseRoot 'ProgramData'
    $script:LogFile = Join-Path $CaseRoot 'experiment.log'
    $script:HadErrors = $false
}

function Add-Result {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Hypothesis,
        [Parameter(Mandatory=$true)][string]$Expected,
        [Parameter(Mandatory=$true)][string]$Observed,
        [Parameter(Mandatory=$true)][string]$Signal
    )
    $results.Add([PSCustomObject]@{
        Id = $Id
        Hypothesis = $Hypothesis
        Expected = $Expected
        Observed = $Observed
        Signal = $Signal
    })
}

New-Directory -Path $testRoot

try {
    # H1: a raiz permitida nao e reparse point, mas um ancestral dela e.
    $caseRoot = Join-Path $testRoot 'H1-AncestorJunction'
    $outsideBase = Join-Path $caseRoot 'ExternalLike\UserLocal'
    $outsideTemp = Join-Path $outsideBase 'Temp'
    $localLink = Join-Path $caseRoot 'UserLocalLink'
    New-Directory -Path $outsideTemp
    $marker = Join-Path $outsideTemp 'must-survive.txt'
    Set-Content -LiteralPath $marker -Value 'synthetic' -Encoding UTF8
    try {
        New-Item -ItemType Junction -Path $localLink -Target $outsideBase -ErrorAction Stop | Out-Null
        Set-CaseContext -CaseRoot $caseRoot -LocalPath $localLink
        $result = Clear-DirectoryContentSafe -Path (Join-Path $localLink 'Temp') -Label 'H1 ancestor junction'
        $survived = Test-Path -LiteralPath $marker
        Add-Result -Id 'H1' `
            -Hypothesis 'Uma junction em ancestral da raiz permitida pode redirecionar a limpeza.' `
            -Expected 'Recusar a limpeza e preservar o marcador externo sintetico.' `
            -Observed ("retorno={0}; marcadorSobreviveu={1}" -f $result, $survived) `
            -Signal $(if (-not $survived) { 'BUG' } else { 'NO_PROBLEM' })
    } catch {
        Add-Result -Id 'H1' -Hypothesis 'Junction em ancestral.' -Expected 'Executar fixture.' -Observed $_.Exception.Message -Signal 'INCONCLUSIVE'
    }

    # H2: a entrada permitida existe, mas e arquivo regular em vez de diretorio.
    $caseRoot = Join-Path $testRoot 'H2-RootFile'
    $localBase = Join-Path $caseRoot 'UserLocal'
    New-Directory -Path $localBase
    $rootFile = Join-Path $localBase 'Temp'
    Set-Content -LiteralPath $rootFile -Value 'root-file' -Encoding UTF8
    Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
    $result = Clear-DirectoryContentSafe -Path $rootFile -Label 'H2 arquivo no lugar da raiz'
    $rootSurvived = Test-Path -LiteralPath $rootFile -PathType Leaf
    Add-Result -Id 'H2' `
        -Hypothesis 'Um arquivo regular no caminho permitido pode ser aceito como diretorio de limpeza.' `
        -Expected 'Recusar com falha e preservar o objeto raiz.' `
        -Observed ("retorno={0}; arquivoRaizSobreviveu={1}" -f $result, $rootSurvived) `
        -Signal $(if ($result) { 'BUG' } else { 'NO_PROBLEM' })

    # H3: junction aninhada abaixo de um diretorio comum removido recursivamente.
    $caseRoot = Join-Path $testRoot 'H3-NestedJunction'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $tempPath = Join-Path $localBase 'Temp'
    $wrapper = Join-Path $tempPath 'Wrapper'
    $external = Join-Path $caseRoot 'ExternalLike\NestedTarget'
    New-Directory -Path $wrapper
    New-Directory -Path $external
    $marker = Join-Path $external 'must-survive.txt'
    Set-Content -LiteralPath $marker -Value 'synthetic' -Encoding UTF8
    try {
        New-Item -ItemType Junction -Path (Join-Path $wrapper 'NestedLink') -Target $external -ErrorAction Stop | Out-Null
        Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
        $result = Clear-DirectoryContentSafe -Path $tempPath -Label 'H3 junction aninhada'
        $survived = Test-Path -LiteralPath $marker
        Add-Result -Id 'H3' `
            -Hypothesis 'Remove-Item recursivo pode atravessar uma junction que nao e filha imediata da raiz.' `
            -Expected 'Preservar o destino externo sintetico.' `
            -Observed ("retorno={0}; marcadorSobreviveu={1}" -f $result, $survived) `
            -Signal $(if ($survived) { 'NO_PROBLEM' } else { 'BUG' })
    } catch {
        Add-Result -Id 'H3' -Hypothesis 'Junction aninhada.' -Expected 'Executar fixture.' -Observed $_.Exception.Message -Signal 'INCONCLUSIVE'
    }

    # H4: a raiz e uma junction quebrada; Test-Path pode confundi-la com ausencia legitima.
    $caseRoot = Join-Path $testRoot 'H4-BrokenRootJunction'
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
        $isReparse = ($null -ne $rootItem) -and (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        Add-Result -Id 'H4' `
            -Hypothesis 'Uma junction-raiz quebrada pode ser tratada como caminho permitido inexistente.' `
            -Expected 'Reconhecer o reparse point e recusar.' `
            -Observed ("retorno={0}; junctionAindaExiste={1}; detectadaComoReparse={2}" -f $result, ($null -ne $rootItem), $isReparse) `
            -Signal $(if ($result -and $isReparse) { 'BUG' } elseif (-not $isReparse) { 'INCONCLUSIVE' } else { 'NO_PROBLEM' })
    } catch {
        Add-Result -Id 'H4' -Hypothesis 'Junction-raiz quebrada.' -Expected 'Executar fixture.' -Observed $_.Exception.Message -Signal 'INCONCLUSIVE'
    }

    # H5: hard link aponta para dados sinteticos fora da raiz.
    $caseRoot = Join-Path $testRoot 'H5-HardLink'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $tempPath = Join-Path $localBase 'Temp'
    $external = Join-Path $caseRoot 'ExternalLike'
    New-Directory -Path $tempPath
    New-Directory -Path $external
    $source = Join-Path $external 'source.txt'
    $hardLink = Join-Path $tempPath 'linked.txt'
    Set-Content -LiteralPath $source -Value 'synthetic' -Encoding UTF8
    try {
        New-Item -ItemType HardLink -Path $hardLink -Target $source -ErrorAction Stop | Out-Null
        Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
        $result = Clear-DirectoryContentSafe -Path $tempPath -Label 'H5 hard link'
        $sourceSurvived = Test-Path -LiteralPath $source
        Add-Result -Id 'H5' `
            -Hypothesis 'Excluir um hard link interno pode remover o nome externo ou seus dados.' `
            -Expected 'Remover somente o link interno e preservar o nome/conteudo externo.' `
            -Observed ("retorno={0}; fonteSobreviveu={1}; conteudo={2}" -f $result, $sourceSurvived, $(if ($sourceSurvived) { Get-Content -LiteralPath $source -Raw } else { '<ausente>' })) `
            -Signal $(if ($sourceSurvived) { 'NO_PROBLEM' } else { 'BUG' })
    } catch {
        Add-Result -Id 'H5' -Hypothesis 'Hard link interno.' -Expected 'Executar fixture.' -Observed $_.Exception.Message -Signal 'INCONCLUSIVE'
    }

    # H6: representacao equivalente com ponto final de segmento e repeticao da operacao.
    $caseRoot = Join-Path $testRoot 'H6-AliasAndIdempotency'
    $localBase = Join-Path $caseRoot 'UserLocal'
    $tempPath = Join-Path $localBase 'Temp'
    New-Directory -Path $tempPath
    $marker = Join-Path $tempPath 'remove.txt'
    Set-Content -LiteralPath $marker -Value 'synthetic' -Encoding UTF8
    Set-CaseContext -CaseRoot $caseRoot -LocalPath $localBase
    $aliasPath = Join-Path $tempPath '.'
    $first = Clear-DirectoryContentSafe -Path $aliasPath -Label 'H6 alias equivalente'
    $second = Clear-DirectoryContentSafe -Path $tempPath -Label 'H6 segunda execucao'
    $rootSurvived = Test-Path -LiteralPath $tempPath -PathType Container
    $markerSurvived = Test-Path -LiteralPath $marker
    Add-Result -Id 'H6' `
        -Hypothesis 'Alias de caminho ou segunda execucao pode contornar a allowlist ou remover a raiz.' `
        -Expected 'Ambas concluem, removem apenas o conteudo e preservam a raiz.' `
        -Observed ("primeira={0}; segunda={1}; raizSobreviveu={2}; marcadorSobreviveu={3}" -f $first, $second, $rootSurvived, $markerSurvived) `
        -Signal $(if ($first -and $second -and $rootSurvived -and (-not $markerSurvived)) { 'NO_PROBLEM' } else { 'BUG' })
} finally {
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$results | ConvertTo-Json -Depth 4
