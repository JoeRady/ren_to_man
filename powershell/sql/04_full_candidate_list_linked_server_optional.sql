/*
    OPTIONAL: single combined query producing the full Step 4 candidate list
    (source path + target path in one result set) in a single round trip.

    This only works if a LINKED SERVER from MAIN01 to REN01 exists (ask your
    DBA - it is NOT assumed to exist by default). Replace [REN01_LINK] below
    with the actual linked server name, then run this against:

        SQLSRV01\MAIN01 , database Patricia_Main_Live

    If no linked server is available, use 01/02/03 separately (or the
    PowerShell tool, which queries both instances itself and does not need a
    linked server) instead of this script.
*/

:setvar LoginId ""
:setvar CategoryId ""
:setvar FromDate "2026-01-01"
:setvar ToDate "2026-06-30"
:setvar SourceRoot "\\brifile\Renewals\Patricia\documents"
:setvar TargetRoot "\\brimain\Main\Patricia\documents"

DECLARE @LoginId    NVARCHAR(100) = NULLIF('$(LoginId)', '');
DECLARE @CategoryId INT           = NULLIF('$(CategoryId)', '');
DECLARE @FromDate   DATE          = '$(FromDate)';
DECLARE @ToDate     DATE          = '$(ToDate)';
DECLARE @SourceRoot NVARCHAR(400) = '$(SourceRoot)';
DECLARE @TargetRoot NVARCHAR(400) = '$(TargetRoot)';

;WITH SourceDocs AS (
    SELECT
        dl.DOC_LOG_ID,
        dl.CASE_ID,
        dl.LOGIN_ID,
        dl.LOG_DATE,
        dl.DOC_NAME,
        dl.DOC_FILE_NAME,
        dl.CATEGORY_ID,
        c.CASE_TYPE_ID,
        c.CASE_NUMBER,
        c.STATE_ID AS COUNTRY,
        c.CASE_NUMBER_EXTENSION
    FROM [REN01_LINK].Patricia.dbo.PAT_DOC_LOG dl
    JOIN [REN01_LINK].Patricia.dbo.PAT_CASE c
        ON c.CASE_ID = dl.CASE_ID
    WHERE dl.LOG_DATE >= @FromDate
      AND dl.LOG_DATE <  DATEADD(day, 1, @ToDate)
      AND (@LoginId IS NULL OR dl.LOGIN_ID = @LoginId)
      AND (@CategoryId IS NULL OR dl.CATEGORY_ID = @CategoryId)
)
SELECT
    sd.DOC_LOG_ID,
    sd.CASE_ID              AS SOURCE_CASE_ID,
    map.MAIN_LIVE_CASE_ID   AS TARGET_CASE_ID,
    sd.LOGIN_ID,
    sd.LOG_DATE,
    sd.DOC_NAME,
    sd.DOC_FILE_NAME,
    sd.CATEGORY_ID,
    @SourceRoot
        + N'\' + CAST(sd.CASE_TYPE_ID AS NVARCHAR(10))
        + N'\' + RIGHT(REPLICATE('0', 6) + CAST(sd.CASE_NUMBER AS NVARCHAR(10)), 6)
        + N'\' + UPPER(LTRIM(RTRIM(sd.COUNTRY)))
        + N'\' + LTRIM(RTRIM(sd.CASE_NUMBER_EXTENSION))
        + N'\' + sd.DOC_FILE_NAME                                          AS SOURCE_PATH,
    CASE WHEN tc.CASE_ID IS NULL THEN NULL ELSE
        @TargetRoot
            + N'\' + CAST(tc.CASE_TYPE_ID AS NVARCHAR(10))
            + N'\' + RIGHT(REPLICATE('0', 6) + CAST(tc.CASE_NUMBER AS NVARCHAR(10)), 6)
            + N'\' + UPPER(LTRIM(RTRIM(tc.STATE_ID)))
            + N'\' + LTRIM(RTRIM(tc.CASE_NUMBER_EXTENSION))
            + N'\' + sd.DOC_FILE_NAME
    END                                                                    AS TARGET_PATH,
    CASE
        WHEN map.MAIN_LIVE_CASE_ID IS NULL THEN 'no mapping in wr_Renewals_vs_Main_Live'
        WHEN tc.CASE_ID IS NULL THEN 'target case not found in Main PAT_CASE'
        ELSE NULL
    END                                                                    AS SKIP_REASON
FROM SourceDocs sd
LEFT JOIN dbo.wr_Renewals_vs_Main_Live map
    ON map.RENEWALS_CASE_ID = sd.CASE_ID
LEFT JOIN dbo.PAT_CASE tc
    ON tc.CASE_ID = map.MAIN_LIVE_CASE_ID
ORDER BY sd.CASE_ID, sd.LOG_DATE;
