<#
.SYNOPSIS
    Проверка структуры курса «Реализация CI/CD на базе Jenkins».

.DESCRIPTION
    Скрипт отвечает на вопросы, которые не видны при чтении отдельной
    практики, но сразу заметны студенту:

      * все ли практики на месте и нет ли пропусков в нумерации;
      * совпадает ли таблица содержания в README.md с файлами на диске;
      * существуют ли все файлы и каталоги, на которые ссылается README;
      * в правильной ли кодировке тексты (UTF-8 без BOM) и с какими
        переводами строк (нужны LF: файлы практик читают на Linux);
      * нет ли табуляции и слишком длинных строк в текстах;
      * не остались ли файлы прежней версии курса, заменённые новыми.

    Дополняет tools/validate_files.py: тот проверяет содержимое файлов
    (XML, YAML, Groovy, shell), а этот — структуру курса целиком.

.PARAMETER MaxLineLength
    Предельная длина строки в текстах практик. По умолчанию 96 символов:
    столько помещается в окно терминала и в область чтения на портале.

.EXAMPLE
    powershell -File tools/check_course.ps1
    powershell -File tools/check_course.ps1 -MaxLineLength 100

.NOTES
    Код возврата 0 — замечаний нет, 1 — есть ошибки, 2 — есть только
    предупреждения.
#>
param(
    [int]$MaxLineLength = 96
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$checked = 0

function Add-Error($message) { $script:errors.Add($message) }
function Add-Warning($message) { $script:warnings.Add($message) }

function Get-RelativePath($fullName) {
    $rootFull = (Resolve-Path $Root).Path
    return $fullName.Replace($rootFull, '').TrimStart('\', '/').Replace('\', '/')
}

# --------------------------------------------------------------- структура

# Имена практик ожидаются такими. Список здесь — не украшение: если
# практику переименовали и забыли поправить README, скрипт это покажет.
$expectedPractices = @(
    '1_install.txt',
    '2_administration.txt',
    '3_jobs.txt',
    '4_nodes.txt',
    '5_cli.txt',
    '6_gitea.txt',
    '7_triggers.txt',
    '8_build_with_params.txt',
    '9_groovy.txt',
    '10_pipeline.txt',
    '11_deploy.txt',
    '12_docker.txt',
    '13_shared_libraries.txt',
    '14_jcasc_backup.txt'
)

# Файлы прежней версии курса: они заменены новыми.
$obsoleteFiles = @(
    '1_install_jenkins.txt',
    '2_administration_jenkins.txt',
    '6_deploy_from_github.txt',
    'files for practics\index.html'
)

$readme = Join-Path $Root 'README.md'
if (-not (Test-Path $readme)) {
    Add-Error 'нет README.md — с него начинается курс'
}

Write-Host 'Проверка структуры курса'
Write-Host ''

# ------------------------------------------------------------- практики

foreach ($practice in $expectedPractices) {
    $path = Join-Path $Root $practice
    if (-not (Test-Path $path)) {
        Add-Error "нет практики $practice"
        continue
    }
    $checked++

    if ($readme -and (Test-Path $readme)) {
        $readmeText = Get-Content $readme -Raw -Encoding UTF8
        if ($readmeText -notmatch [regex]::Escape($practice)) {
            Add-Error "практика $practice не упомянута в README.md"
        }
    }
}

# Нумерация: 1..14 подряд, без пропусков.
$actualNumbers = @()
Get-ChildItem -Path $Root -Filter '*.txt' -File | ForEach-Object {
    if ($_.Name -match '^(\d+)_') { $actualNumbers += [int]$Matches[1] }
}
$actualNumbers = $actualNumbers | Sort-Object
for ($i = 1; $i -le $actualNumbers.Count; $i++) {
    if ($actualNumbers[$i - 1] -ne $i) {
        Add-Warning ("нумерация практик: ожидался номер {0}, найден {1}" -f $i, $actualNumbers[$i - 1])
        break
    }
}

# Остатки прежней версии курса.
foreach ($obsolete in $obsoleteFiles) {
    if (Test-Path (Join-Path $Root $obsolete)) {
        Add-Warning "остался файл прежней версии курса: $obsolete"
    }
}

# -------------------------------------------------- ссылки из README

if ($readme -and (Test-Path $readme)) {
    $readmeText = Get-Content $readme -Raw -Encoding UTF8
    $links = [regex]::Matches($readmeText, '\[[^\]]*\]\(([^)]+)\)')
    foreach ($link in $links) {
        $target = $link.Groups[1].Value
        if ($target -match '^(https?:|#|mailto:)' -or $target -match '^<') { continue }
        $targetPath = Join-Path $Root ($target -replace '/', '\')
        if (-not (Test-Path $targetPath)) {
            Add-Error "README ссылается на отсутствующий файл: $target"
        }
    }
}

# ------------------------------------------------ кодировка и форматирование

# Каталог archive/ в проверку не входит: там лежат тексты прежней версии
# курса, в том числе сохранённые в других кодировках и с переводами строк
# CRLF. Ругаться на исторический материал смысла нет — его не читают
# на занятиях, а исправлять его никто не будет.
$textFiles = Get-ChildItem -Path $Root -Recurse -File -Include '*.txt', '*.md', '*.sh', '*.groovy', '*.xml', '*.yaml', '*.yml', '*.json', '*.ini', 'Jenkinsfile*' |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\archive\\' }

foreach ($file in $textFiles) {
    $checked++
    $relative = Get-RelativePath $file.FullName
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

    # BOM в начале файла ломает shebang скрипта и первый ключ YAML.
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-Error "$relative : файл начинается с BOM (нужен UTF-8 без BOM)"
    }

    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($raw.Contains("`r`n")) {
        Add-Error "$relative : переводы строк CRLF (нужны LF)"
    }

    $lines = $raw -split "`r?`n"
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $line = $lines[$n]

        if ($line.Contains("`t") -and $relative -match '\.(yaml|yml|ini)$') {
            Add-Error "$relative : строка $($n + 1): табуляция в YAML или INI"
            break
        }

        if ($line.Length -gt $MaxLineLength -and $relative -match '\.txt$') {
            Add-Warning "$relative : строка $($n + 1) длиной $($line.Length) символов"
        }
    }

    # Пробелы в конце строки не видны глазами, но мешают сравнению версий.
    $trailing = 0
    for ($n = 0; $n -lt $lines.Count; $n++) {
        if ($lines[$n] -match '[ ]+$') { $trailing++ }
    }
    if ($trailing -gt 3) {
        Add-Warning "$relative : строк с пробелами в конце — $trailing"
    }
}

# --------------------------------------------------------- служебные каталоги

foreach ($dir in @('files', 'tools')) {
    if (-not (Test-Path (Join-Path $Root $dir))) {
        Add-Error "нет каталога $dir"
    }
}

foreach ($required in @('LICENSE', 'LICENSE-CONTENT',
                        'files\www\index.html',
                        'files\scripts\deploy_site.sh',
                        'files\pipelines\Jenkinsfile.build-test-deploy',
                        'files\jcasc\jenkins.yaml',
                        'tools\validate_files.py')) {
    if (-not (Test-Path (Join-Path $Root $required))) {
        Add-Warning "нет ожидаемого файла: $required"
    }
}

# ------------------------------------------------------------------ отчёт

Write-Host ("Проверено файлов и практик: {0}" -f $checked)
Write-Host ''

if ($warnings.Count -gt 0) {
    Write-Host ("ПРЕДУПРЕЖДЕНИЯ ({0}):" -f $warnings.Count)
    foreach ($message in $warnings) { Write-Host ("  ! {0}" -f $message) }
    Write-Host ''
}

if ($errors.Count -gt 0) {
    Write-Host ("ОШИБКИ ({0}):" -f $errors.Count)
    foreach ($message in $errors) { Write-Host ("  x {0}" -f $message) }
    Write-Host ''
    Write-Host ("Итог: ошибок {0}, предупреждений {1}" -f $errors.Count, $warnings.Count)
    exit 1
}

if ($warnings.Count -gt 0) {
    Write-Host ("Итог: ошибок нет, предупреждений {0}" -f $warnings.Count)
    exit 2
}

Write-Host 'Структура курса в порядке: замечаний нет.'
exit 0
