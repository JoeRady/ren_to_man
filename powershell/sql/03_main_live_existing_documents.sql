/*
    Verification input 1/2: existing PAT_DOC_LOG rows on the Main *live*
    instance, for every case that has a Renewals mapping.

    Run this against:  SQLSRV01\MAIN01 , database Patricia_Main_Live
    (same instance/database as sql/02_case_mapping_and_target_paths.sql -
    adjust if PAT_DOC_LOG for the Main live instance lives elsewhere).

    Self-contained like sql/02: no manual ID list to paste in, it looks up
    the relevant CASE_IDs itself via wr_Renewals_vs_Main_Live. Export as CSV
    (main_live_documents.csv).

    Unlike case_mapping.csv, documents get added to Main continuously, so
    re-export this shortly before each run rather than reusing an old copy -
    stale data here could cause the tool to treat an already-migrated
    document as new and copy/insert it again.
*/

SELECT
    dl.CASE_ID,
    dl.DOC_FILE_NAME
FROM dbo.PAT_DOC_LOG dl
WHERE dl.CASE_ID IN (
    SELECT MAIN_LIVE_CASE_ID
    FROM dbo.wr_Renewals_vs_Main_Live
    WHERE RENEWALS_CASE_ID IS NOT NULL
)
ORDER BY dl.CASE_ID, dl.DOC_FILE_NAME;
