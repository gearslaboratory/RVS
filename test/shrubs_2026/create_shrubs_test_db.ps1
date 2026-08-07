param(
    [string]$TaskDirectory = 'C:\Users\ninglis\Desktop\admin\grants\RVS_CARB\task1',
    [string]$TemplateDatabase = (Join-Path $PSScriptRoot '..\..\rvs_demo_fromRobbAddFieldTypeMissing.db')
)

$ErrorActionPreference = 'Stop'

$outputDirectory = $PSScriptRoot
$databasePath = Join-Path $outputDirectory 'shrubs_2026_test.db'
$crosswalkOutput = Join-Path $outputDirectory 'Bio_Crosswalk_2026_selected.csv'
$equationOutput = Join-Path $outputDirectory 'Bio_Equation2026.csv'
$equationUpdateLog = Join-Path $outputDirectory 'equation_updates.csv'
$plotsOutput = Join-Path $outputDirectory 'Plots_Active.csv'
$shrubsOutput = Join-Path $outputDirectory 'Shrubs_Active.csv'
$loadSql = Join-Path $outputDirectory 'load_shrubs_2026.sql'

# Height is selected over volume where both forms were available.  ARTR2 keeps
# its current default BAT2 assignment to provide the requested comparison plot.
$selectedBat = [ordered]@{
    ARTR2 = 1160
    ADFA = 1494; ADSP = 1512; ARGL3 = 1513; ARPA6 = 1217; ARUV = 744; ARVI4 = 1220; ARCA11 = 1495
    CEFR = 1226; CEGR = 1514; CEIN3 = 1229; CEPI = 1232; CEMO2 = 1515
    CECO = 1223; CEVE = 632; CHSE11 = 1235; CHNA2 = 1238; CHPA13 = 1241; DERI = 1499; ERTR7 = 1500
    ERFA2 = 1516; HESC2 = 1503; HIIN3 = 1504; MAAQ2 = 1470; PREM = 1244
    PUTR2 = 636; QUCH2 = 1247; QUDU = 1518; QUKE = 1251; QUVA = 1256; QUWI2 = 1259
    RUPA = 201; SAME3 = 1506; STVI2 = 1507; SYAL = 804; VASC = 743
}

$crosswalkPath = Join-Path $TaskDirectory 'Bio_Crosswalk.csv'
$equationPath = Join-Path $TaskDirectory 'Bio_Equation2026.csv'
$crosswalk = @(Import-Csv -LiteralPath $crosswalkPath)
$equations = @(Import-Csv -LiteralPath $equationPath)

# USDA/NRCS plant-symbol common names for active equations whose supplied
# equation rows omit COMM_NAME.
$commonNameOverrides = @{
    ADFA = 'Chamise'
    ARCA11 = 'California sagebrush'
    DERI = 'Bush poppy'
    ERTR7 = 'Hairy yerba santa'
    HESC2 = 'Peak rushrose'
    HIIN3 = 'Shortpod mustard'
    SAME3 = 'Black sage'
    STVI2 = 'Rod wirelettuce'
}
foreach ($equation in $equations) {
    if ($commonNameOverrides.ContainsKey($equation.spp_code)) {
        $equation.COMM_NAME = $commonNameOverrides[$equation.spp_code]
    }
}

# Vourlitis et al. (2021) Table 1 defines m as the slope and b as the
# intercept of ln(biomass) = b + m * ln(volume).  The source CSV initially
# placed m in CF1 and b in CF2, while librvs consistently interprets CF1 as
# the intercept and CF2 as the slope.  Correct all Vourlitis rows before
# loading the replacement Bio_Equation table.
$vourlitisChanges = @()
foreach ($equation in $equations) {
    if ($equation.comments -eq 'Vourlitis2021') {
        $oldCf1 = $equation.CF1
        $oldCf2 = $equation.CF2
        $equation.CF1 = $oldCf2
        $equation.CF2 = $oldCf1
        $equation.EQUATION = "BAT = exp($($equation.CF1) + $($equation.CF2) * ln(VOL))"
        $vourlitisChanges += [pscustomobject][ordered]@{
            source = 'Vourlitis2021'
            equation_status = 'New (non-BioPak)'
            EQN_NUM = $equation.EQN_NUM
            spp_code = $equation.spp_code
            scientific_name = $equation.SCI_NAME
            common_name = if ([string]::IsNullOrWhiteSpace($equation.COMM_NAME)) { 'Not supplied' } else { $equation.COMM_NAME }
            parameter = $equation.PA1_CODE
            old_CF1_m = $oldCf1
            old_CF2_b = $oldCf2
            new_CF1_b = $equation.CF1
            new_CF2_m = $equation.CF2
            equation_form = $equation.EQ_FRM
        }
    }
}

$equationByNumber = @{}
foreach ($equation in $equations) { $equationByNumber[[int]$equation.EQN_NUM] = $equation }

$crosswalkByCode = @{}
foreach ($row in $crosswalk) { $crosswalkByCode[$row.spp_code] = $row }

foreach ($speciesCode in $selectedBat.Keys) {
    $equation = $equationByNumber[[int]$selectedBat[$speciesCode]]
    if ($null -eq $equation) { throw "Selected equation $($selectedBat[$speciesCode]) for $speciesCode is absent from Bio_Equation2026.csv." }

    if ($crosswalkByCode.ContainsKey($speciesCode)) {
        $crosswalkByCode[$speciesCode].BAT2 = $selectedBat[$speciesCode]
    }
    else {
        # New species receive the standard PCH equation so width and volume can
        # be derived from height when a selected BAT equation requires VOL.
        $newRow = [pscustomobject][ordered]@{
            dom_spp = $equation.SCI_NAME
            spp_code = $speciesCode
            lifeform = 'Shrub'
            Priority = 1
            surrogate = ''
            BAP = 999
            BAT = 999
            ALB = 630
            PCH = 1155
            BFT = 88
            BAT2 = $selectedBat[$speciesCode]
        }
        $crosswalk += $newRow
        $crosswalkByCode[$speciesCode] = $newRow
    }
}

# A compact, deduplicated log of equations added to the test configuration.
# ARTR2/BAT 1160 is the retained legacy comparison baseline, not an update.
$selectedEquationNumbers = @($selectedBat.Values | ForEach-Object { [int]$_ } | Where-Object { $_ -ne 1160 })
$equationUpdates = @()
foreach ($equationNumber in ($selectedEquationNumbers | Sort-Object -Unique)) {
    $equation = $equationByNumber[$equationNumber]
    $isBioPak = $equation.comments -eq 'BioPak'
    $needsCode = $equationNumber -in 744, 1223, 1251, 1470, 1494, 1512, 1513, 1514, 1515, 1516, 1518
    $equationUpdates += [pscustomobject][ordered]@{
        equation_type = if ($isBioPak) { 'BioPak existing' } else { 'Newer non-BioPak' }
        source = $equation.comments
        EQN_NUM = $equation.EQN_NUM
        spp_code = $equation.spp_code
        scientific_name = $equation.SCI_NAME
        common_name = if ([string]::IsNullOrWhiteSpace($equation.COMM_NAME)) { 'Not supplied' } else { $equation.COMM_NAME }
        parameter = (@($equation.PA1_CODE, $equation.PA2_CODE, $equation.PA3_CODE) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ', '
        change = if ($needsCode) { 'Added to BAT2 crosswalk and code' } else { 'Added to BAT2 crosswalk' }
    }
}
$equationUpdates | Sort-Object { [int]$_.EQN_NUM } | Export-Csv -LiteralPath $equationUpdateLog -NoTypeInformation

# Keep every provided crosswalk row, amend the selected mappings above, and
# append missing selected species.  This is the full replacement table loaded
# into the test database.
$crosswalk | Export-Csv -LiteralPath $crosswalkOutput -NoTypeInformation

# The SQLite table has no comments column; preserve all columns it does have.
$equationColumns = @(
    'EQN_NUM', 'lifeform', 'spp_code', 'SCI_NAME', 'COMM_NAME', 'ret_code',
    'description', 'GEO_AREA', 'SER_STAG', 'TAX_LIFE', 'PA1_CODE', 'PA1_TEXT',
    'PA1_MIN', 'PA1_MAX', 'PA1_UNIT', 'PA2_CODE', 'PA2_TEXT', 'PA2_MIN',
    'PA2_MAX', 'PA2_UNIT', 'PA3_CODE', 'PA3_TEXT', 'PA3_MIN', 'PA3_MAX',
    'PA3_UNIT', 'DEP_VAR', 'DPV_MIN', 'DPV_MAX', 'DPV_UNIT', 'CF1', 'CF2',
    'CF3', 'CF4', 'EQUATION', 'EQ_FRM'
)
$equations | Select-Object -Property $equationColumns | Export-Csv -LiteralPath $equationOutput -NoTypeInformation

$plotTemplate = [ordered]@{
    BPS_CODE = 11030
    BPS_NAME = 'California Coastal Live Oak Woodland and Savanna'
    BPS_MODEL = '0411030'
    herb_cover = 0
    herb_height = 0
    latitude = 37.68
    longitude = -122.04
    PPT_1 = 529.89; PPT_2 = 529.89; PPT_3 = 529.89; PPT_4 = 529.89; PPT_5 = 529.89
    NDVI_1 = 6578.105469; NDVI_2 = 6578.105469; NDVI_3 = 6578.105469; NDVI_4 = 6578.105469; NDVI_5 = 6578.105469
    sclass = 0
}

$plots = @()
$shrubs = @()
$plotId = 900001
foreach ($speciesCode in $selectedBat.Keys) {
    $equation = $equationByNumber[[int]$selectedBat[$speciesCode]]
    $plotName = "${speciesCode}_100pct"
    $plots += [pscustomobject]([ordered]@{ PLOT_ID = $plotId } + $plotTemplate)
    $shrubs += [pscustomobject][ordered]@{
        PLOT_ID = $plotId
        PLOT_NAME = $plotName
        dom_spp = $equation.SCI_NAME
        spp_code = $speciesCode
        # Use decimal text so SQLite imports these as REAL values.  librvs'
        # legacy reader does not coerce INTEGER storage values to doubles.
        cover_o = '100.0'
        height = '100.0'
        BPS_CODE = $plotTemplate.BPS_CODE
        BPS_NAME = $plotTemplate.BPS_NAME
        height_ft = 3.28084
        o_code = $speciesCode
        cover = '100.0'
    }
    $plotId++
}

$plots | Export-Csv -LiteralPath $plotsOutput -NoTypeInformation
$shrubs | Export-Csv -LiteralPath $shrubsOutput -NoTypeInformation

Copy-Item -LiteralPath $TemplateDatabase -Destination $databasePath -Force

@"
DELETE FROM Bio_Crosswalk;
DELETE FROM Bio_Equation;
DELETE FROM Plots_Active;
DELETE FROM Shrubs_Active;
DELETE FROM Disturbance_Plots;
DELETE FROM Disturbance_Plots_NoFire;
.mode csv
.import --skip 1 'Bio_Crosswalk_2026_selected.csv' Bio_Crosswalk
.import --skip 1 'Bio_Equation2026.csv' Bio_Equation
.import --skip 1 'Plots_Active.csv' Plots_Active
.import --skip 1 'Shrubs_Active.csv' Shrubs_Active
UPDATE Shrubs_Active
SET cover_o = CAST(cover_o AS REAL),
    height = CAST(height AS REAL),
    height_ft = CAST(height_ft AS REAL),
    cover = CAST(cover AS REAL);
VACUUM;
"@ | Set-Content -LiteralPath $loadSql -NoNewline

Write-Output "Database template copy: $databasePath"
Write-Output "Load script: $loadSql"
Write-Output "Plots: $($plots.Count); shrubs: $($shrubs.Count); selected BAT mappings: $($selectedBat.Count)"
Write-Output "Comprehensive equation update rows: $($equationUpdates.Count)"
