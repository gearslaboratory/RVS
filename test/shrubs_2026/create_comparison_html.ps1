param(
    [string]$Image = 'shrubs_test'
)

$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$queryFile = Join-Path $PSScriptRoot 'comparison_query.sql'
$sql = @"
WITH baseline AS (
  SELECT total_biomass AS baseline FROM Biomass_Output_Spp WHERE spp_code = 'ARTR2'
)
SELECT s.spp_code, s.bio_eq AS equation, round(b.baseline, 2) AS baseline_lb_acre,
       round(s.total_biomass, 2) AS biomass_lb_acre,
       round(100.0 * (s.total_biomass / b.baseline - 1), 1) AS difference_pct
FROM Biomass_Output_Spp s CROSS JOIN baseline b
WHERE s.spp_code <> 'ARTR2'
ORDER BY s.total_biomass DESC;
"@
Set-Content -LiteralPath $queryFile -Value $sql.Replace("`r", ' ').Replace("`n", ' ') -NoNewline
try {
    $containerCommand = 'cd /work/test/shrubs_2026 && sqlite3 -header -csv shrubs_2026_output.db < comparison_query.sql'
    $rows = @(& docker run --rm -v "${workspace}:/work" $Image sh -c $containerCommand | ConvertFrom-Csv)
}
finally {
    Remove-Item -LiteralPath $queryFile -Force -ErrorAction SilentlyContinue
}
if ($rows.Count -eq 0) { throw 'No active mapping rows were returned from shrubs_2026_output.db.' }

$updatesByCode = @{}
Import-Csv -LiteralPath (Join-Path $PSScriptRoot 'equation_updates.csv') | ForEach-Object { $updatesByCode[$_.spp_code] = $_ }
foreach ($row in $rows) {
    $update = $updatesByCode[$row.spp_code]
    $row | Add-Member -NotePropertyName common_name -NotePropertyValue $update.common_name
    $row | Add-Member -NotePropertyName scientific_name -NotePropertyValue $update.scientific_name
    $row | Add-Member -NotePropertyName selection -NotePropertyValue $(if ($update.equation_type -eq 'BioPak existing') { 'Existing' } else { 'New' })
    $row | Add-Member -NotePropertyName updated_where -NotePropertyValue $(if ($update.change -match 'code') { 'Crosswalk + code' } else { 'Crosswalk' })
}

$baseline = [double]$rows[0].baseline_lb_acre
$allValues = @($rows | ForEach-Object { [double]$_.biomass_lb_acre }) + $baseline
$logMin = [Math]::Floor([Math]::Log10(($allValues | Measure-Object -Minimum).Minimum))
$logMax = [Math]::Ceiling([Math]::Log10(($allValues | Measure-Object -Maximum).Maximum))
$baselinePosition = 100 * ([Math]::Log10($baseline) - $logMin) / ($logMax - $logMin)
$dotRows = foreach ($row in $rows) {
    $value = [double]$row.biomass_lb_acre
    $position = 100 * ([Math]::Log10($value) - $logMin) / ($logMax - $logMin)
    $class = if ($row.selection -eq 'Existing') { 'existing' } else { 'new' }
    "<div class='dot-row'><span>$($row.spp_code)</span><div class='dot-track'><i class='baseline' style='left:$([Math]::Round($baselinePosition,2))%'></i><i class='$class' style='left:$([Math]::Round($position,2))%'></i></div><strong>$($value.ToString('N1'))</strong></div>"
}

$tableRows = foreach ($row in $rows) {
    $value = [double]$row.biomass_lb_acre
    $pct = [double]$row.difference_pct
    $sign = if ($pct -ge 0) { '+' } else { '' }
    "<tr><td>$($row.spp_code)</td><td>$($row.common_name)</td><td>$($row.scientific_name)</td><td>$($row.equation)</td><td>$($row.selection)</td><td>$($row.updated_where)</td><td>$($value.ToString('N1'))</td><td>$sign$($pct.ToString('N1'))%</td></tr>"
}

$output = Join-Path $PSScriptRoot 'shrubs_2026_before_after.html'
$document = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Active Shrub BAT Mapping Test</title>
<style>
body{font:15px/1.45 system-ui,-apple-system,Segoe UI,sans-serif;margin:0;color:#17212b;background:#f6f8fa}main{max-width:1100px;margin:auto;padding:28px}h1{margin:0 0 6px}h2{margin-top:32px}.note{color:#4d5966}.metric{display:inline-block;background:#e7f0f7;padding:12px 18px;border-radius:6px;margin:10px 16px 4px 0}.chart{background:white;padding:18px;border-radius:8px;box-shadow:0 1px 4px #0002}.legend{font-size:13px}.swatch{display:inline-block;width:12px;height:12px;border-radius:50%;margin:0 5px 0 14px}.new{background:#237a57}.existing{background:#2968a8}.dot-row{display:grid;grid-template-columns:72px 1fr 86px;gap:10px;align-items:center;margin:7px 0}.dot-track{height:18px;background:#eaf0f4;position:relative}.dot-track i{position:absolute}.dot-track .baseline{top:0;height:18px;border-left:2px solid #6f7d88}.dot-track .new,.dot-track .existing{top:3px;width:12px;height:12px;border-radius:50%;transform:translateX(-50%)}table{width:100%;border-collapse:collapse;background:white}th,td{padding:8px 10px;border-bottom:1px solid #dbe2e8;text-align:right}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){text-align:left}th:nth-child(3),td:nth-child(3),th:nth-child(4),td:nth-child(4),th:nth-child(5),td:nth-child(5){text-align:center}footer{margin-top:24px;color:#4d5966;font-size:13px}
</style></head><body><main>
<h1>Active shrub BAT mapping test</h1>
<p class="note">One shrub at 100% cover and 100 cm height; expanded shrub biomass in lb/ac. Non-BioPak equations are used only when published after BioPak (1994), or BioPak is used when it is the only usable exact species equation.</p>
<div class="metric"><b>ARTR2 baseline (BioPak 1160)</b><br>$($baseline.ToString('N1')) lb/ac</div><div class="metric"><b>Active changed mappings</b><br>$($rows.Count)</div>
<h2>Final active biomass</h2><p class="legend"><i class="swatch new"></i>New equation <i class="swatch existing"></i>Existing BioPak <span class="note">Vertical line: ARTR2 baseline; log scale.</span></p><div class="chart">$($dotRows -join "`n")</div>
<h2>Output table</h2><table><thead><tr><th>Code</th><th>Common name</th><th>Scientific name</th><th>BAT</th><th>Type</th><th>Updated</th><th>lb/ac</th><th>vs ARTR2</th></tr></thead><tbody>$($tableRows -join "`n")</tbody></table>
<footer>ARTR2/1160 is the unchanged comparison baseline and is not included in the update count.</footer></main></body></html>
"@
Set-Content -LiteralPath $output -Value $document -NoNewline
Write-Output $output
