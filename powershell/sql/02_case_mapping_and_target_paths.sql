/*
    Step 4 (part 2/2): case-ID mapping + computed TARGET path, in one query.

    Run this against:  SQLSRV01\MAIN01 , database Patricia_Main_Live
    (adjust the database name if PAT_CASE for the Main *live* instance lives
    in a different database on MAIN01 than the mapping table).

    Unlike a per-search filter, this dumps the ENTIRE mapping table (it is a
    reference table, not expected to be huge) joined to Main's PAT_CASE, with
    TARGET_FOLDER already computed. Export the result once as CSV
    (case_mapping.csv) and reuse it across runs - only re-export when new
    case mappings have been added on the Main side.

    In SSMS: Results to Grid -> right-click the result grid -> "Save Results
    As..." -> CSV. Or enable "Results to File" before running the query.

    Note: on some Windows locales (e.g. German) SSMS's CSV export uses ';'
    as the field separator instead of ','. Run-RenToMain.ps1 auto-detects
    this, so either is fine - no need to change your regional settings.
*/

:setvar TargetRoot "\\brimain\Main\Patricia\documents"

DECLARE @TargetRoot NVARCHAR(400) = '$(TargetRoot)';

SELECT
    m.RENEWALS_CASE_ID,
    m.MAIN_LIVE_CASE_ID,
    c.CASE_TYPE_ID,
    c.CASE_NUMBER,
    c.STATE_ID AS COUNTRY,
    c.CASE_NUMBER_EXTENSION,
    -- Assumed folder layout: CaseType \ FamilyNumber(6, zero-padded) \ Country(upper) \ Extension
    -- Keep this in sync with sql/01_source_documents.sql's SOURCE_PATH expression.
    @TargetRoot
        + N'\' + CAST(c.CASE_TYPE_ID AS NVARCHAR(10))
        + N'\' + RIGHT(REPLICATE('0', 6) + CAST(c.CASE_NUMBER AS NVARCHAR(10)), 6)
        + N'\' + UPPER(LTRIM(RTRIM(c.STATE_ID)))
        + N'\' + LTRIM(RTRIM(c.CASE_NUMBER_EXTENSION))     AS TARGET_FOLDER
FROM dbo.wr_Renewals_vs_Main_Live m
JOIN dbo.PAT_CASE c
    ON c.CASE_ID = m.MAIN_LIVE_CASE_ID
WHERE m.RENEWALS_CASE_ID IS NOT NULL
ORDER BY m.RENEWALS_CASE_ID;
