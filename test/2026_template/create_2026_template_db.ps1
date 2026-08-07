param(
    [string]$TemplateDatabase = (Join-Path $PSScriptRoot '..\..\rvs_demo_fromRobbAddFieldTypeMissing.db')
)

$ErrorActionPreference = 'Stop'
$sourceDirectory = Join-Path $PSScriptRoot '..\shrubs_2026'
$databasePath = Join-Path $PSScriptRoot '2026_template.db'
$crosswalkPath = Join-Path $PSScriptRoot 'Bio_Crosswalk_2026.csv'
$equationPath = Join-Path $PSScriptRoot 'Bio_Equation2026.csv'
$plotsPath = Join-Path $PSScriptRoot 'Plots_Active.csv'
$shrubsPath = Join-Path $PSScriptRoot 'Shrubs_Active.csv'
$disturbancePath = Join-Path $PSScriptRoot 'Disturbance_Plots.csv'
$loadSqlPath = Join-Path $PSScriptRoot 'load_2026_template.sql'

Copy-Item -LiteralPath (Join-Path $sourceDirectory 'Bio_Crosswalk_2026_selected.csv') -Destination $crosswalkPath -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'Bio_Equation2026.csv') -Destination $equationPath -Force

$plotDefaults = [ordered]@{
    BPS_CODE = 11030
    BPS_NAME = 'California Coastal Live Oak Woodland and Savanna'
    BPS_MODEL = '0411030'
    latitude = 37.68
    longitude = -122.04
    PPT_1 = 529.89; PPT_2 = 529.89; PPT_3 = 529.89; PPT_4 = 529.89; PPT_5 = 529.89
    NDVI_1 = 6578.105469; NDVI_2 = 6578.105469; NDVI_3 = 6578.105469; NDVI_4 = 6578.105469; NDVI_5 = 6578.105469
    sclass = 0
}

$examples = @(
    @{ id = 2026001; name = 'T2026_01'; herbCover = 40.0; herbHeight = 20.0; shrubs = (,@('ARTR2', 'Wyoming big sagebrush', 35.0, 70.0)) }
    @{ id = 2026002; name = 'T2026_02'; herbCover = 20.0; herbHeight = 15.0; shrubs = (,@('ARCA11', 'California sagebrush', 50.0, 90.0)) }
    @{ id = 2026003; name = 'T2026_03'; herbCover = 25.0; herbHeight = 25.0; shrubs = (,@('ADFA', 'Chamise', 45.0, 120.0)) }
    @{ id = 2026004; name = 'T2026_04'; herbCover = 30.0; herbHeight = 18.0; shrubs = @(@('CECO', 'Mountain whitethorn', 35.0, 140.0), @('SYAL', 'Common snowberry', 25.0, 70.0)) }
    @{ id = 2026005; name = 'T2026_05'; herbCover = 15.0; herbHeight = 12.0; shrubs = (,@('VASC', 'Grouse whortleberry', 60.0, 50.0)) }
    @{ id = 2026006; name = 'T2026_06'; herbCover = 35.0; herbHeight = 30.0; shrubs = @(@('QUKE', 'California black oak', 30.0, 200.0), @('RUPA', 'Western thimbleberry', 30.0, 100.0)) }
    @{ id = 2026007; name = 'T2026_07'; herbCover = 45.0; herbHeight = 22.0; shrubs = (,@('PUTR2', 'Antelope bitterbrush', 40.0, 90.0)) }
    @{ id = 2026008; name = 'T2026_08'; herbCover = 10.0; herbHeight = 10.0; shrubs = (,@('ARUV', 'Kinnikinnick', 70.0, 30.0)) }
    @{ id = 2026009; name = 'T2026_09'; herbCover = 25.0; herbHeight = 20.0; shrubs = (,@('SAME3', 'Black sage', 45.0, 80.0)) }
    @{ id = 2026010; name = 'T2026_10'; herbCover = 20.0; herbHeight = 18.0; shrubs = (,@('CEVE', 'Snowbrush ceanothus', 55.0, 130.0)) }
)

$plots = @()
$shrubs = @()
foreach ($example in $examples) {
    $plots += [pscustomobject]([ordered]@{ PLOT_ID = $example.id; herb_cover = $example.herbCover; herb_height = $example.herbHeight } + $plotDefaults)
    foreach ($shrub in $example.shrubs) {
        $shrubs += [pscustomobject][ordered]@{
            PLOT_ID = $example.id
            PLOT_NAME = $example.name
            dom_spp = $shrub[1]
            spp_code = $shrub[0]
            cover_o = ('{0:F1}' -f $shrub[2])
            height = ('{0:F1}' -f $shrub[3])
            BPS_CODE = $plotDefaults.BPS_CODE
            BPS_NAME = $plotDefaults.BPS_NAME
            height_ft = [Math]::Round($shrub[3] / 30.48, 4)
            o_code = $shrub[0]
            cover = ('{0:F1}' -f $shrub[2])
        }
    }
}
$disturbances = @(
    [pscustomobject][ordered]@{ PLOT_ID = 2026003; PLOT_NAME = 'T2026_03'; DIST_TYPE = 'GRAZE'; DIST_SUBTYPE = 'COW'; START_YEAR = 1; STOP_YEAR = 10; FREQ = 2; P1_VAL = 40.0; P2_VAL = 1000.0; P3_VAL = 90.0 }
    [pscustomobject][ordered]@{ PLOT_ID = 2026008; PLOT_NAME = 'T2026_08'; DIST_TYPE = 'GRAZE'; DIST_SUBTYPE = 'GOAT'; START_YEAR = 2; STOP_YEAR = 8; FREQ = 1; P1_VAL = 25.0; P2_VAL = 1000.0; P3_VAL = 60.0 }
)

$plots | Export-Csv -LiteralPath $plotsPath -NoTypeInformation
$shrubs | Export-Csv -LiteralPath $shrubsPath -NoTypeInformation
$disturbances | Export-Csv -LiteralPath $disturbancePath -NoTypeInformation
Copy-Item -LiteralPath $TemplateDatabase -Destination $databasePath -Force

@"
DELETE FROM Bio_Crosswalk;
DELETE FROM Bio_Equation;
DELETE FROM Plots_Active;
DELETE FROM Shrubs_Active;
DELETE FROM Disturbance_Plots;
DELETE FROM Disturbance_Plots_NoFire;
.mode csv
.import --skip 1 'Bio_Crosswalk_2026.csv' Bio_Crosswalk
.import --skip 1 'Bio_Equation2026.csv' Bio_Equation
.import --skip 1 'Plots_Active.csv' Plots_Active
.import --skip 1 'Shrubs_Active.csv' Shrubs_Active
.import --skip 1 'Disturbance_Plots.csv' Disturbance_Plots
UPDATE Shrubs_Active
SET cover_o = CAST(cover_o AS REAL), height = CAST(height AS REAL),
    height_ft = CAST(height_ft AS REAL), cover = CAST(cover AS REAL);
VACUUM;
"@ | Set-Content -LiteralPath $loadSqlPath -NoNewline

Write-Output "Template database: $databasePath"
Write-Output "Example plots: $($plots.Count); shrub records: $($shrubs.Count); disturbed plots: $($disturbances.Count)"
