@{
    # Copy this file to RenToMan.config.psd1 (or point -ConfigPath at your own
    # copy) and fill in the connection details for your environment. Do not
    # commit a copy containing real SQL credentials.

    Databases = @{
        # Source Patricia instance ("Renewals")
        Renewals = @{
            Server              = 'SQLSRV01\REN01'
            Database            = 'Patricia'
            IntegratedSecurity  = $true   # $false -> use UserId/Password (SQL auth)
            UserId              = $null
            Password            = $null
        }

        # Target Patricia instance ("Main")
        Main = @{
            Server              = 'SQLSRV01\MAIN01'
            Database            = 'Patricia_Main_Live'
            IntegratedSecurity  = $true
            UserId              = $null
            Password            = $null
        }
    }

    Paths = @{
        # Root of the source document store (UNC path). Overridable per run
        # with -SourceRoot.
        SourceRoot = '\\brifile\Renewals\Patricia\documents'
    }

    # Folder-naming convention used to build the four-level case path:
    #   <case_type>\<family_number>\<country>\<case_number_extension>
    # These are ASSUMPTIONS based on the field widths described for the task.
    # Verify against a real listing run (Run-RenToMan.ps1 without -Execute)
    # before doing any live copy, and adjust here if the real folders differ.
    FolderFormat = @{
        CaseTypeZeroPad      = $false
        CaseTypeWidth        = 2
        FamilyNumberZeroPad  = $true
        FamilyNumberWidth    = 6
        CountryUppercase     = $true
        ExtensionUppercase   = $false
    }

    Logging = @{
        # Where the candidate CSV, JSONL run log and report are written.
        LogDir = '.\logs'
    }
}
