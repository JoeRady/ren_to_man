@{
    # Copy this file to RenToMain.config.psd1 (or point -ConfigPath at your own
    # copy). This tool no longer connects to SQL Server itself (see
    # README.md - many corporate machines run PowerShell under Constrained
    # Language Mode, which blocks the .NET types needed for that). Instead,
    # run the queries in powershell/sql/ yourself (e.g. in SSMS) and export
    # the results as CSV, then pass those CSV paths to Run-RenToMain.ps1.

    Logging = @{
        # Where the candidate CSV and generated copy script are written.
        LogDir = '.\logs'
    }
}
