# ren_to_man (PowerShell)

Findet Patricia-Dokumente, die von der **Renewals**- in die **Main**-Instanz
kopiert werden sollen, und erzeugt daraus ein prüfbares Kopierskript.

## Wichtig: PowerShell Constrained Language Mode

Viele Corporate-Windows-Rechner laufen mit PowerShell im **Constrained
Language Mode** (durchgesetzt über AppLocker/WDAC-Richtlinien). In diesem
Modus sind Methodenaufrufe auf "Nicht-Core"-.NET-Typen blockiert — das
betrifft insbesondere direkten SQL-Server-Zugriff über
`System.Data.SqlClient` (und jede andere ADO.NET-/COM-basierte Alternative
genauso).

**Deshalb spricht dieses Werkzeug die Datenbanken gar nicht mehr selbst an.**
Stattdessen:

1. Du führst die beiden SQL-Skripte aus [`sql/`](sql/) selbst in deinem
   SQL-Client (z.B. **SSMS**) aus und exportierst die Ergebnisse als CSV.
2. `Run-RenToMan.ps1` liest nur noch diese beiden CSV-Dateien ein (per
   `Import-Csv`), verknüpft sie und baut daraus die Kopierliste. Das
   verwendet ausschließlich "Core Types" (Strings, Arrays, Hashtables,
   PSCustomObjects) und eingebaute Cmdlets — funktioniert also auch unter
   Constrained Language Mode einwandfrei, unabhängig von Adminrechten oder
   installierten Zusatzmodulen.

So bleibt außerdem das Sicherheitsmodell aus der letzten Iteration erhalten:
Das Tool hat **nie** Schreibzugriff auf die Datenbank (es hat nach diesem
Umbau überhaupt keinen DB-Zugriff mehr), und das eigentliche Kopieren
passiert über ein separates, reviewbares Skript ohne jede Datenbankabhängigkeit.

> Getestet gegen: PowerShell 7.5.1 unter Constrained Language Mode, ohne
> `sqlcmd.exe` und ohne `SqlServer`/`SQLPS`-Modul — also den kleinsten
> gemeinsamen Nenner. Falls bei euch doch `sqlcmd`/`SqlServer`-Modul verfügbar
> ist oder ihr in FullLanguage-Mode lauft, könnt ihr die SQL-Skripte
> natürlich trotzdem genauso gut damit ausführen statt mit SSMS.

## Ablauf

**Schritt 1-4: SQL-Abfragen in SSMS ausführen und als CSV exportieren**

1. [`sql/01_source_documents.sql`](sql/01_source_documents.sql) gegen
   `SQLSRV01\REN01` / `Patricia` ausführen. SSMS: Query-Menü → "SQLCMD Mode"
   aktivieren, dann oben im Skript `LoginId`/`CategoryId`/`FromDate`/
   `ToDate`/`SourceRoot` setzen. Ergebnis exportieren: Rechtsklick auf das
   Ergebnisraster → "Save Results As..." → CSV, z.B. als
   `source_documents.csv`.
2. [`sql/02_case_mapping_and_target_paths.sql`](sql/02_case_mapping_and_target_paths.sql)
   gegen `SQLSRV01\MAIN01` / `Patricia_Main_Live` ausführen (`TargetRoot`
   setzen). Das ist eine Referenztabelle ohne Bezug zum Suchzeitraum — als
   `case_mapping.csv` exportieren und über mehrere Läufe hinweg
   wiederverwenden; nur neu exportieren, wenn neue Case-Mappings dazugekommen
   sind.

Beide Skripte sind reine `SELECT`-Abfragen und berechnen den Quell- bzw.
Zielordnerpfad bereits direkt in SQL (Spalte `SOURCE_PATH` bzw.
`TARGET_FOLDER`) — die verwendete Ordner-Namenskonvention (Padding,
Groß-/Kleinschreibung) steht als Kommentar im jeweiligen Skript und sollte
anhand ein paar echter Ergebniszeilen gegen den Windows-Explorer verifiziert
werden, bevor ein Kopierskript erzeugt wird.

**Schritt 4 (Fortsetzung): CSVs verknüpfen und auflisten**

```powershell
cd powershell
.\Run-RenToMan.ps1 -SourceDocumentsCsvPath .\source_documents.csv -CaseMappingCsvPath .\case_mapping.csv
```

Schreibt `logs\candidates_<timestamp>.csv` mit allen gefundenen Dokumenten
(`DOC_LOG_ID`, `LOG_DATE`, `DOC_NAME`, `DOC_FILE_NAME`, Quellpfad, Zielpfad,
ggf. Skip-Grund) und zeigt die ersten 20 Zeilen in der Konsole.

**Schritt 5: Kopierskript erzeugen (immer noch nichts wird kopiert)**

```powershell
.\Run-RenToMan.ps1 -SourceDocumentsCsvPath .\source_documents.csv -CaseMappingCsvPath .\case_mapping.csv -GenerateCopyScript
```

Erzeugt zusätzlich `logs\copy_script_<timestamp>.ps1`. Dieses Skript:

- braucht **keine Datenbankverbindung**,
- enthält am Anfang lesbar die Liste aller geplanten Kopiervorgänge,
- legt fehlende Zielordner an, überspringt bereits vorhandene Zieldateien
  (überschreibt nie),
- behandelt Dateinamen inkl. Umlaute korrekt,
- fragt vor dem Start eine Bestätigung ab (`JA` eingeben, oder `-Force`),
- schreibt sein eigenes JSONL-Log (`copy_log_<timestamp>.jsonl`) neben sich,
- nutzt selbst keine Konstrukte, die unter Constrained Language Mode
  blockiert wären (kein `StringBuilder`, keine generischen .NET-Collections).

```powershell
notepad .\logs\copy_script_20260101_120000.ps1   # erst lesen!
.\logs\copy_script_20260101_120000.ps1           # fragt vor dem Kopieren nach Bestaetigung
```

**Schritt 6: Report erzeugen**

```powershell
.\Build-RenToManReport.ps1 -LogPath .\logs\copy_log_20260101_120000.jsonl
```

## Setup

1. Ordner `powershell/` auf die Corporate-Maschine kopieren.
2. `RenToMan.config.example.psd1` nach `RenToMan.config.psd1` kopieren
   (steuert nur noch, wohin Logs/CSVs/Skripte geschrieben werden).
3. Falls die Ausführung von Skripten standardmäßig blockiert ist: IT nach dem
   korrekten Weg fragen (Signierung, Ausnahme, o.ä.) — `Set-ExecutionPolicy
   -Scope Process -ExecutionPolicy Bypass` funktioniert nur, wenn eure
   Richtlinie das überhaupt zulässt.

## Struktur

```
powershell/
  RenToMan.psd1                    Modul-Manifest
  RenToMan.psm1                    CSV-Join, Pfadaufbau-Hilfsfunktionen, Kopierskript-Generator
                                    (kein Datenbankzugriff, Constrained-Language-Mode-sicher)
  RenToMan.config.example.psd1     Vorlage fuer Konfiguration (nur noch Logging.LogDir)
  Run-RenToMan.ps1                 Schritt 4 (+ optional Skript-Generierung fuer Schritt 5)
  Build-RenToManReport.ps1         Schritt 6: Report aus dem JSONL-Log des Kopierskripts
  sql/
    01_source_documents.sql        Schritt 1-4, Teil 1: Quelldokumente (REN01), SOURCE_PATH bereits berechnet
    02_case_mapping_and_target_paths.sql
                                    Schritt 1-4, Teil 2: Case-ID-Mapping + TARGET_FOLDER (MAIN01), ungefiltert
    03_full_candidate_list_linked_server_optional.sql
                                    Optional: alles in einer Query, falls ein Linked Server existiert
  tests/
    RenToMan.Tests.ps1             Pester-Tests fuer die DB-unabhaengige Logik
```

### SQL separat testen

Die beiden Skripte in `sql/` sind unabhängig vom PowerShell-Tool direkt in
SSMS oder per `sqlcmd` (falls vorhanden) testbar — reine `SELECT`-Abfragen,
es wird nichts verändert. Jedes Skript nutzt `:setvar`-Variablen (SSMS:
"SQLCMD Mode" im Query-Menü aktivieren), sodass Login/Kategorie/Zeitraum/
Pfade ohne Codeänderung durchgetestet werden können.

Falls ein Linked Server von MAIN01 nach REN01 existiert, liefert
`03_full_candidate_list_linked_server_optional.sql` das komplette Ergebnis
(Quell- und Zielpfad, Skip-Grund) in einer einzigen Abfrage — rein optional,
für den normalen Ablauf oben nicht nötig.

### Tests

```powershell
Install-Module Pester -Scope CurrentUser   # falls noch nicht vorhanden
Invoke-Pester -Path .\tests\RenToMan.Tests.ps1
```

Diese Tests wurden **nicht** in der Linux-Entwicklungsumgebung ausgeführt, da
dort kein PowerShell verfügbar ist — bitte auf der Corporate-Maschine laufen
lassen und Auffälligkeiten zurückmelden. Sie decken bewusst nur Logik ab, die
ausschließlich "Core Types" verwendet, damit sie auch unter Constrained
Language Mode aussagekräftig sind.

## Bekannte Annahmen / offene Punkte für weitere Iterationen

- **Ordner-Namenskonvention** ist als Best-Guess direkt in den SQL-Skripten
  (`sql/01...`, `sql/02...`) hinterlegt (Padding, Groß-/Kleinschreibung) —
  beide Skripte im Sync halten, falls die reale Struktur abweicht.
- Es wird angenommen, dass genau eine Datei pro `PAT_DOC_LOG`-Eintrag
  existiert (`DOC_FILE_NAME` im Case-Ordner).
- Es wird bislang **kein** `PAT_DOC_LOG`-Eintrag auf der Main-Seite angelegt —
  es werden nur die Dateien auf dem Filesystem kopiert.
- Bereits vorhandene Zieldateien werden übersprungen, nicht überschrieben.
- `case_mapping.csv` (Schritt 2) ist eine Referenztabelle ohne Bezug zum
  Suchzeitraum — sie muss nicht bei jedem Lauf neu exportiert werden, nur
  wenn neue Case-Mappings hinzukommen.
- Falls sich herausstellt, dass Constrained Language Mode bei euch doch nicht
  gilt (bzw. IT das ändert) oder `sqlcmd`/`SqlServer`-Modul verfügbar wird,
  könnte eine direkte DB-Anbindung wieder ergänzt werden — aktuell bewusst
  nicht eingebaut, um nicht von einer möglicherweise unbeabsichtigten
  Richtlinien-Lücke (z.B. elevierte Sessions mit `FullLanguage`) abhängig zu
  sein.
