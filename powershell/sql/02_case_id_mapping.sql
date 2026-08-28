/*
    Step 4 (part 2/3): resolve source (Renewals) CASE_ID -> target (Main) CASE_ID.

    Run this against:  SQLSRV01\MAIN01 , database Patricia_Main_Live

    Paste the list of CASE_ID values you got from 01_source_documents.sql
    (distinct CASE_ID column) into @RenewalsCaseIds below, or remove the
    WHERE clause entirely to dump the full mapping table.

    Example via sqlcmd:
        sqlcmd -S SQLSRV01\MAIN01 -d Patricia_Main_Live -E -i 02_case_id_mapping.sql
*/

DECLARE @RenewalsCaseIds TABLE (CASE_ID INT PRIMARY KEY);
INSERT INTO @RenewalsCaseIds (CASE_ID) VALUES
    (100001), (100002), (100003);
    -- <- replace with the real CASE_ID list from step 1, or leave as-is and
    --    ignore the filter below by commenting out the WHERE clause.

SELECT
    m.RENEWALS_CASE_ID,
    m.MAIN_LIVE_CASE_ID
FROM dbo.wr_Renewals_vs_Main_Live m
WHERE m.RENEWALS_CASE_ID IN (SELECT CASE_ID FROM @RenewalsCaseIds)
ORDER BY m.RENEWALS_CASE_ID;
