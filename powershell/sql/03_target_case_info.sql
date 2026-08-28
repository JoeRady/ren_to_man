/*
    Step 4 (part 3/3): build the TARGET path for each mapped Main CASE_ID.

    Run this against:  SQLSRV01\MAIN01 , database Patricia_Main_Live
    (adjust the database name if PAT_CASE for the Main *live* instance lives
    in a different database on MAIN01 than the mapping table - the task
    description only specifies the mapping table's database).

    Paste the MAIN_LIVE_CASE_ID values from 02_case_id_mapping.sql into
    @MainCaseIds below.

    Example via sqlcmd:
        sqlcmd -S SQLSRV01\MAIN01 -d Patricia_Main_Live -E -i 03_target_case_info.sql ^
            -v TargetRoot="\\brimain\Main\Patricia\documents"
*/

:setvar TargetRoot "\\brimain\Main\Patricia\documents"

DECLARE @TargetRoot NVARCHAR(400) = '$(TargetRoot)';

DECLARE @MainCaseIds TABLE (CASE_ID INT PRIMARY KEY);
INSERT INTO @MainCaseIds (CASE_ID) VALUES
    (200001), (200002), (200003);
    -- <- replace with the real MAIN_LIVE_CASE_ID list from step 2.

SELECT
    c.CASE_ID,
    c.CASE_TYPE_ID,
    c.CASE_NUMBER,
    c.STATE_ID AS COUNTRY,
    c.CASE_NUMBER_EXTENSION,
    @TargetRoot
        + N'\' + CAST(c.CASE_TYPE_ID AS NVARCHAR(10))
        + N'\' + RIGHT(REPLICATE('0', 6) + CAST(c.CASE_NUMBER AS NVARCHAR(10)), 6)
        + N'\' + UPPER(LTRIM(RTRIM(c.STATE_ID)))
        + N'\' + LTRIM(RTRIM(c.CASE_NUMBER_EXTENSION))     AS TARGET_FOLDER
FROM dbo.PAT_CASE c
WHERE c.CASE_ID IN (SELECT CASE_ID FROM @MainCaseIds)
ORDER BY c.CASE_ID;
