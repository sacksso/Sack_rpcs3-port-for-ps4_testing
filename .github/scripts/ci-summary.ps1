<# Resume en el "Summary" del job las lineas de error y la cola de cada log. Pensado para pegarme el resultado tal cual. #>
param(
    [string]$LogDir = 'C:/logs',
    [string]$Title = 'Build'
)
$fence = '```'
$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine("## $Title - errores y cola de los logs")
$logs = @()
if (Test-Path $LogDir) { $logs = @(Get-ChildItem $LogDir -Filter *.log -ErrorAction SilentlyContinue) }
if (-not $logs.Count) { [void]$sb.AppendLine('No hay logs.') }
foreach ($f in $logs) {
    [void]$sb.AppendLine("### $($f.Name)")
    $hits = @(Select-String -Path $f.FullName -Pattern 'error:|FAILED:|fatal error|undefined reference|CMake Error|Traceback|Command failed|Exception' | Select-Object -First 20)
    if ($hits.Count) {
        [void]$sb.AppendLine('Primeros errores:')
        [void]$sb.AppendLine($fence)
        foreach ($h in $hits) { $l = $h.Line.Trim(); if ($l.Length -gt 300) { $l = $l.Substring(0, 300) + '...' }; [void]$sb.AppendLine($l) }
        [void]$sb.AppendLine($fence)
    }
    [void]$sb.AppendLine('Cola:')
    [void]$sb.AppendLine($fence)
    foreach ($l in (Get-Content $f.FullName -Tail 25)) { if ($l.Length -gt 300) { $l = $l.Substring(0, 300) + '...' }; [void]$sb.AppendLine($l) }
    [void]$sb.AppendLine($fence)
}
$text = $sb.ToString()
if ($text.Length -gt 900000) { $text = $text.Substring(0, 900000) }
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $text } else { Write-Output $text }
