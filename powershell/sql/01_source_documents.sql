/*
    Step 4 (part 1/2): find candidate documents on the SOURCE (Renewals) instance.

    Run this against:  SQLSRV01\REN01 , database Patricia

    Enable "SQLCMD Mode" in SSMS (Query menu -> SQLCMD Mode) to use the
    :setvar variables below, or run via sqlcmd.exe, e.g.:

        sqlcmd -S SQLSRV01\REN01 -d Patricia -E -i 01_source_documents.sql ^
            -v LoginId="jsmith" CategoryId="" FromDate="2026-01-01" ToDate="2026-06-30" ^
               SourceRoot="\\brifile\Renewals\Patricia\documents"

    Leave LoginId or CategoryId empty ('') to not filter on that field - but
    at least one of the two must be non-empty.

    This also computes SOURCE_PATH using the ASSUMED folder-naming convention
    (see powershell/README.md / RenToMan.psd1 FolderFormat):
        <root>\<CaseType>\<FamilyNumber (6 digits, zero-padded)>\<Country>\<Extension>\<DOC_FILE_NAME>
    Adjust the padding/casing expressions below if the real folders differ,
    then compare a few rows against Windows Explorer to confirm.
*/

:setvar LoginId ""
:setvar CategoryId ""
:setvar FromDate "2026-01-01"
:setvar ToDate "2026-06-30"
:setvar SourceRoot "\\brifile\Renewals\Patricia\documents"

DECLARE @LoginId      NVARCHAR(100) = NULLIF('$(LoginId)', '');
DECLARE @CategoryId   INT           = NULLIF('$(CategoryId)', '');
DECLARE @FromDate     DATE          = '$(FromDate)';
DECLARE @ToDate       DATE          = '$(ToDate)';
DECLARE @SourceRoot   NVARCHAR(400) = '$(SourceRoot)';

IF @LoginId IS NULL AND @CategoryId IS NULL
BEGIN
    RAISERROR('Provide at least one of LoginId / CategoryId.', 16, 1);
    RETURN;
END

SELECT
    dl.DOC_LOG_ID,
    dl.CASE_ID,
    dl.LOGIN_ID,
    dl.LOG_DATE,
    dl.DOC_TYPE,
    dl.DOC_NAME,
    dl.DOC_FILE_NAME,
    dl.CATEGORY_ID,
    c.CASE_TYPE_ID,
    c.CASE_NUMBER,
    c.STATE_ID            AS COUNTRY,
    c.CASE_NUMBER_EXTENSION,
    -- Assumed folder layout: CaseType \ FamilyNumber(6, zero-padded) \ Country(upper) \ Extension
    @SourceRoot
        + N'\' + CAST(c.CASE_TYPE_ID AS NVARCHAR(10))
        + N'\' + RIGHT(REPLICATE('0', 6) + CAST(c.CASE_NUMBER AS NVARCHAR(10)), 6)
        + N'\' + UPPER(LTRIM(RTRIM(c.STATE_ID)))
        + N'\' + LTRIM(RTRIM(c.CASE_NUMBER_EXTENSION))
        + N'\' + dl.DOC_FILE_NAME                          AS SOURCE_PATH
FROM dbo.PAT_DOC_LOG dl
JOIN dbo.PAT_CASE c
    ON c.CASE_ID = dl.CASE_ID
WHERE dl.LOG_DATE >= @FromDate
  AND dl.LOG_DATE <  DATEADD(day, 1, @ToDate)
  AND (@LoginId IS NULL OR dl.LOGIN_ID = @LoginId)
  AND (@CategoryId IS NULL OR dl.CATEGORY_ID = @CategoryId)
ORDER BY dl.CASE_ID, dl.LOG_DATE;
