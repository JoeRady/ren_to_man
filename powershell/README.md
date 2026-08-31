# ren_to_man (PowerShell)

Findet Patricia-Dokumente, die von der **Renewals**- in die **Main**-Instanz
kopiert werden sollen. Nutzt `System.Data.SqlClient` (Teil des .NET
Framework, das mit Windows PowerShell 5.1 mitgeliefert wird) — **kein
Zusatzmodul nötig** (kein `SqlServer`-Modul, kein `Invoke-Sqlcmd`, kein
Internetzugriff zur Installation).

> Primäres Zielsystem: **Windows PowerShell 5.1** (`powershell.exe`), wie es
> auf den meisten Corporate-Windows-Rechnern vorinstalliert ist. Unter
> PowerShell 7 (`pwsh`) kann `System.Data.SqlClient` fehlen — dort ggf. zuerst
> `Install-Module SqlServer` (falls ein interner PSGallery-Proxy verfügbar
> ist) oder auf Windows PowerShell 5.1 wechseln.

## Sicherheitsmodell: DB-Zugriff nur lesend, Kopieren getrennt & reviewbar

Diese Architektur trennt bewusst zwei Dinge, die nichts miteinander zu tun
haben müssen:

1. **`Run-RenToMan.ps1`** spricht die Datenbanken an. Es führt **ausschließlich
   `SELECT`-Abfragen** aus (`Get-SourceDocLogEntries`, `Get-CaseInfo`,
   `Get-CaseIdMapping` in `RenToMan.psm1`) — es gibt im Code keinen einzigen
   `INSERT`/`UPDATE`/`DELETE`-Pfad, und alle Werte werden als SQL-Parameter
   übergeben (kein String-Concatenation, also auch kein SQL-Injection-Risiko).
   Dieses Skript kopiert **selbst keine einzige Datei**.
2. Mit `-GenerateCopyScript` erzeugt es ein **eigenständiges** `.ps1`-Skript
   (`copy_script_<timestamp>.ps1`), das die eigentliche Kopieraktion (Schritt
   5) enthält. Dieses generierte Skript hat **keine Datenbankabhängigkeit
   mehr** — es braucht nur noch Lese-/Schreibrechte auf die aufgelisteten
   Ordner. Es lässt sich vor der Ausführung vollständig lesen/prüfen, fragt
   standardmäßig eine Bestätigung ab (Eingabe von `JA`, überspringbar mit
   `-Force`), und kann getrennt — z.B. zu einem anderen Zeitpunkt oder unter
   einem anderen Konto — ausgeführt werden.

Als zusätzliche Absicherung (defense in depth), unabhängig vom Code:
Standardmäßig verbindet sich das Tool per Windows Integrated Security mit den
Rechten des ausführenden Kontos. Empfehlenswert ist, dafür einen **separaten
SQL-Login mit reinem Lesezugriff** (`db_datareader`) auf beide Datenbanken
einzurichten (`IntegratedSecurity = $false` + `UserId`/`Password` in der
Config) — dann ist ein Schreibzugriff selbst bei einem Software-Fehler
technisch unmöglich, nicht nur "vom Code her nicht vorgesehen".

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

**Schritt 1-4 — nur suchen & auflisten (rein lesend, kein Kopierskript):**

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
der Konsole. **Vor der Erzeugung des Kopierskripts prüfen**, ob die Pfade
plausibel aussehen — die Ordner-Namenskonvention (Padding,
Groß-/Kleinschreibung) ist in `RenToMan.config.psd1` unter `FolderFormat`
konfigurierbar.

Statt `-LoginId` kann auch `-CategoryId` (oder beides kombiniert) angegeben
werden; mindestens eines von beiden ist Pflicht.

**Schritt 5 — Kopierskript erzeugen (immer noch nichts wird kopiert):**

```powershell
.\Run-RenToMan.ps1 `
    -LoginId jsmith `
    -FromDate 2026-01-01 -ToDate 2026-06-30 `
    -TargetRoot '\\brimain\Main\Patricia\documents' `
    -GenerateCopyScript
```

Erzeugt zusätzlich `logs\copy_script_<timestamp>.ps1`. Dieses Skript:

- braucht **keine Datenbankverbindung** mehr,
- enthält am Anfang lesbar die Liste aller geplanten Kopiervorgänge
  (`$Items = @( [pscustomobject]@{ DocLogId = ...; Source = '...'; Target = '...' }, ... )`),
- legt fehlende Zielordner an, überspringt bereits vorhandene Zieldateien
  (überschreibt nie),
- behandelt Dateinamen inkl. Umlaute korrekt (.NET-Strings sind durchgängig
  UTF-16, keine manuelle Encoding-Behandlung nötig),
- fragt vor dem Start eine Bestätigung ab (`JA` eingeben, oder `-Force` zum
  Überspringen der Abfrage),
- schreibt sein eigenes JSONL-Log (`copy_log_<timestamp>.jsonl`) neben sich.

**Kopierskript prüfen und separat ausführen:**

```powershell
notepad .\logs\copy_script_20260101_120000.ps1   # oder VS Code etc. - erst lesen!
.\logs\copy_script_20260101_120000.ps1           # fragt vor dem Kopieren nach Bestaetigung
```

**Schritt 6 — Report aus dem Log erzeugen (ebenfalls ohne DB-Zugriff):**

```powershell
.\Build-RenToManReport.ps1 -LogPath .\logs\copy_log_20260101_120000.jsonl
```

Schreibt `logs\copy_log_20260101_120000.report.txt` mit einer Zusammenfassung
(Anzahl kopiert/übersprungen/fehlend/Fehler, Details zu Problemfällen).

## Struktur

```
powershell/
  RenToMan.psd1                    Modul-Manifest
  RenToMan.psm1                    Kernlogik: DB-Zugriff (nur SELECT), Pfadaufbau,
                                    Planung, Kopierskript-Generator
  RenToMan.config.example.psd1     Vorlage für Konfiguration (Server, Pfade, Ordner-Format)
  Run-RenToMan.ps1                 Schritte 1-4 (+ optional Skript-Generierung für Schritt 5)
  Build-RenToManReport.ps1         Schritt 6: Report aus dem JSONL-Log des Kopierskripts
  sql/
    01_source_documents.sql        Schritt 4, Teil 1: Quelldokumente (REN01)
    02_case_id_mapping.sql         Schritt 4, Teil 2: Case-ID-Mapping (MAIN01)
    03_target_case_info.sql        Schritt 4, Teil 3: Zielpfad je Case (MAIN01)
    04_full_candidate_list_linked_server.sql
                                    Optional: alles in einer Query (braucht Linked Server)
  tests/
    RenToMan.Tests.ps1             Pester-Tests für die DB-unabhängige Logik
                                    (inkl. generiertem Kopierskript)
```

### SQL separat testen (Punkt 4)

Die drei Skripte in `sql/` bilden zusammen genau die Logik von Schritt 4
("Auflistung der gefundenen Dokumente") ab und lassen sich unabhängig vom
PowerShell-Tool in SSMS oder per `sqlcmd` gegen die echten Instanzen testen —
auch das sind reine `SELECT`-Abfragen, es wird nichts verändert:

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

- **Ordner-Namenskonvention** (Padding von Case Type/Family Number,
  Groß-/Kleinschreibung von Country/Extension) ist als Best-Guess in
  `RenToMan.config.psd1` hinterlegt und sollte anhand echter Listing-Läufe
  verifiziert werden, bevor das Kopierskript erzeugt/ausgeführt wird.
- Es wird angenommen, dass genau eine Datei pro `PAT_DOC_LOG`-Eintrag
  existiert (`DOC_FILE_NAME` im Case-Ordner). Mehrere Dateien/Anhänge pro
  Dokument sind noch nicht abgebildet.
- Es wird bislang **kein** `PAT_DOC_LOG`-Eintrag auf der Main-Seite angelegt —
  es werden nur die Dateien auf dem Filesystem kopiert.
- Bereits vorhandene Zieldateien werden übersprungen, nicht überschrieben.
- Log/Report liegen lokal als JSONL/CSV/TXT, nicht in einer DB-Tabelle.
- SQL-Authentifizierung via Windows Integrated Security (`Trusted_Connection`)
  ist Standard; für SQL-Auth (empfohlen: separater Read-Only-Login)
  `IntegratedSecurity = $false` plus `UserId`/`Password` in der Config setzen.
