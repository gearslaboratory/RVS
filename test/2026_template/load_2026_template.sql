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