# ren_to_man (PowerShell)

Kopiert Patricia-Dokumente aus der **Renewals**-Instanz in die **Main**-Instanz.
Nutzt `System.Data.SqlClient` (Teil des .NET Framework, das mit Windows
PowerShell 5.1 mitgeliefert wird) — **kein Zusatzmodul nötig** (kein `SqlServer`-
Modul, kein `Invoke-Sqlcmd`, kein Internetzugriff zur Installation).

> Primäres Zielsystem: **Windows PowerShell 5.1** (`powershell.exe`), wie es
> auf den meisten Corporate-Windows-Rechnern vorinstalliert ist. Unter
> PowerShell 7 (`pwsh`) kann `System.Data.SqlClient` fehlen — dort ggf. zuerst
> `Install-Module SqlServer` (falls ein interner PSGallery-Proxy verfügbar
> ist) oder auf Windows PowerShell 5.1 wechseln.

## Setup

1. Ordner `powershell/` auf die Corporate-Maschine kopieren.
2. `RenToMan.config.example.psd1` nach `RenToMan.config.psd1` kopieren und
   Server-/Datenbanknamen sowie ggf. SQL-Zugangsdaten eintragen. **Nicht**
   mit echten Zugangsdaten committen.
3. Falls die Ausführung von Skripten standardmäßig blockiert ist (Corporate
   Execution Policy), das Skript signieren lassen oder für die aktuelle
   Session freigeben, z.B.:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```
   (nur falls von der IT erlaubt — ansonsten IT nach dem korrekten Weg fragen).

## Benutzung

**Schritt 1-4 — nur suchen & auflisten (Dry Run, Standard):**

```powershell
cd powershell
.\Run-RenToMan.ps1 `
    -LoginId jsmith `
    -FromDate 2026-01-01 -ToDate 2026-06-30 `
    -TargetRoot '\\brimain\Main\Patricia\documents'
```

Schreibt eine CSV mit allen gefundenen Dokumenten (`DOC_LOG_ID`, `LOG_DATE`,
`DOC_NAME`, `DOC_FILE_NAME`, Quellpfad, Zielpfad, ggf. Skip-Grund) nach
`logs\candidates_<timestamp>.csv` und zeigt die ersten 20 Zeilen direkt in
der Konsole. **Vor jedem echten Kopiervorgang prüfen**, ob die Pfade
plausibel aussehen — die Ordner-Namenskonvention (Padding,
Groß-/Kleinschreibung) ist in `RenToMan.config.psd1` unter `FolderFormat`
konfigurierbar.

Statt `-LoginId` kann auch `-CategoryId` (oder beides kombiniert) angegeben
werden; mindestens eines von beiden ist Pflicht.

**Schritt 5-6 — tatsächlich kopieren + Log/Report schreiben:**

```powershell
.\Run-RenToMan.ps1 `
    -LoginId jsmith `
    -FromDate 2026-01-01 -ToDate 2026-06-30 `
    -TargetRoot '\\brimain\Main\Patricia\documents' `
    -Execute
```

Legt fehlende Zielordner an, kopiert Dateien (Dateinamen inkl. Umlaute
funktionieren nativ, da .NET-Strings durchgängig UTF-16 sind und direkt an
die Windows-Dateisystem-API übergeben werden), überspringt bereits
vorhandene Zieldateien, und schreibt:

- `logs\run_<timestamp>.jsonl` — maschinenlesbares Log jeder Kopieraktion
  (Status: `copied` / `skipped` / `missing_source` / `error`)
- `logs\report_<timestamp>.txt` — menschenlesbare Zusammenfassung

## Struktur

```
powershell/
  RenToMan.psd1                    Modul-Manifest
  RenToMan.psm1                    Kernlogik (DB-Zugriff, Pfadaufbau, Kopieren, Log/Report)
  RenToMan.config.example.psd1     Vorlage für Konfiguration (Server, Pfade, Ordner-Format)
  Run-RenToMan.ps1                 Kommandozeilen-Einstiegspunkt
  sql/
    01_source_documents.sql        Schritt 4, Teil 1: Quelldokumente (REN01)
    02_case_id_mapping.sql         Schritt 4, Teil 2: Case-ID-Mapping (MAIN01)
    03_target_case_info.sql        Schritt 4, Teil 3: Zielpfad je Case (MAIN01)
    04_full_candidate_list_linked_server.sql
                                    Optional: alles in einer Query (braucht Linked Server)
  tests/
    RenToMan.Tests.ps1             Pester-Tests für die DB-unabhängige Logik
```

### SQL separat testen (Punkt 4)

Die drei Skripte in `sql/` bilden zusammen genau die Logik von Schritt 4 ab
und lassen sich unabhängig vom PowerShell-Tool in SSMS oder per `sqlcmd`
gegen die echten Instanzen testen:

1. `01_source_documents.sql` gegen `SQLSRV01\REN01` / `Patricia` — liefert
   die gefundenen Dokumente inkl. berechnetem `SOURCE_PATH`.
2. `02_case_id_mapping.sql` gegen `SQLSRV01\MAIN01` / `Patricia_Main_Live` —
   löst die `CASE_ID`s aus Schritt 1 auf `MAIN_LIVE_CASE_ID` auf (Liste der
   IDs im Skript eintragen).
3. `03_target_case_info.sql` gegen `SQLSRV01\MAIN01` — liefert je
   `MAIN_LIVE_CASE_ID` den berechneten `TARGET_FOLDER`.

Jedes Skript nutzt `:setvar`-Variablen (SSMS: "SQLCMD Mode" im Query-Menü
aktivieren, oder `sqlcmd -v Name=Wert ...`), sodass Login/Kategorie/Zeitraum/
Pfade ohne Codeänderung durchgetestet werden können.

Falls ein Linked Server von MAIN01 nach REN01 existiert, liefert
`04_full_candidate_list_linked_server.sql` das komplette Ergebnis (Quell- und
Zielpfad, Skip-Grund) in einer einzigen Abfrage.

### Tests

```powershell
Install-Module Pester -Scope CurrentUser   # falls noch nicht vorhanden
Invoke-Pester -Path .\tests\RenToMan.Tests.ps1
```

Diese Tests wurden **nicht** in dieser (Linux-)Entwicklungsumgebung
ausgeführt, da dort kein PowerShell verfügbar ist — bitte auf der
Corporate-Maschine laufen lassen und Auffälligkeiten zurückmelden.

## Bekannte Annahmen / offene Punkte für weitere Iterationen

- Gleiche Annahmen wie in der Python-Variante (siehe `../python/README.md`):
  Ordner-Namenskonvention ist ein Best-Guess und sollte anhand echter
  Listing-Läufe verifiziert werden; ein Dokument entspricht genau einer
  Datei im Case-Ordner; es wird noch **kein** `PAT_DOC_LOG`-Eintrag auf der
  Main-Seite angelegt (nur Filesystem-Kopie); bereits vorhandene
  Zieldateien werden übersprungen, nicht überschrieben; Log/Report liegen
  lokal als JSONL/CSV/TXT, nicht in einer DB-Tabelle.
- SQL-Authentifizierung via Windows Integrated Security (`Trusted_Connection`)
  ist Standard; für SQL-Auth `IntegratedSecurity = $false` plus
  `UserId`/`Password` in der Config setzen.
