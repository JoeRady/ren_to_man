# ren_to_man

Findet Patricia-Dokumente, die von der **Renewals**- in die **Main**-Instanz
kopiert werden sollen: liest `PAT_DOC_LOG` / `PAT_CASE` auf der Quellseite,
mappt die `CASE_ID` über `wr_Renewals_vs_Main_Live` auf die Ziel-`CASE_ID`,
baut Quell- und Zielpfad anhand der vierstufigen Ordnerstruktur (`Case Type /
Family Number / Country / Case Number Extension`).

**Sicherheitsmodell:** Die SQL-Abfragen (siehe [`powershell/sql/`](powershell/sql/))
sind reine `SELECT`-Statements — keine einzige schreibt in die Datenbank.
Die primäre **PowerShell-Variante spricht die Datenbank inzwischen gar nicht
mehr selbst an** (siehe Hinweis unten zu Constrained Language Mode): du
führst die SQL-Skripte selbst z.B. in SSMS aus und exportierst die Ergebnisse
als CSV, das Tool liest nur noch diese CSVs. Das eigentliche Kopieren
(Schritt 5) passiert nicht direkt, sondern über ein separat generiertes,
eigenständiges Skript ohne jede Datenbankabhängigkeit, das vor der Ausführung
vollständig geprüft werden kann.

## Varianten

| Variante | Ordner | Wann verwenden |
|---|---|---|
| **PowerShell** | [`powershell/`](powershell/README.md) | **Primär.** CSV/SSMS-basiert, funktioniert auch unter PowerShell **Constrained Language Mode** (häufig auf Corporate-Windows-Rechnern per AppLocker/WDAC erzwungen) und unabhängig von Adminrechten. |
| Python | [`python/`](python/README.md) | Alternative mit direkter DB-Anbindung (`pyodbc`) und direktem Kopieren — nur nutzbar, wenn Python ausführbar ist und keine Language-Mode-Einschränkung greift. |

Die Python-Variante ist seit der letzten größeren Iteration nicht mehr auf
dem gleichen Stand wie PowerShell (kein CSV-Workflow, direkter DB-Zugriff und
Direktkopie) — siehe [`python/README.md`](python/README.md).

## Eigenständig testbare SQL-Abfragen für Schritt 4

Unter [`powershell/sql/`](powershell/sql/) liegen die für Schritt 4
("Auflistung der gefundenen Dokumente") verwendeten SQL-Skripte, parametrisiert
über `:setvar`-Variablen, damit sie direkt in SSMS oder per `sqlcmd` gegen die
echten Instanzen getestet werden können — das ist bei der PowerShell-Variante
inzwischen sogar der reguläre, einzige Weg, wie die Datenbank überhaupt
abgefragt wird (siehe [`powershell/README.md`](powershell/README.md#wichtig-powershell-constrained-language-mode)).

## Schritte 1-6 (Kurzüberblick)

1. Eingabe `LOGIN_ID` und/oder `CATEGORY_ID` (mindestens eines von beiden) —
   als `:setvar` im SQL-Skript
2. Zeitraum von...bis — ebenfalls als `:setvar`
3. Zielpfad (Root der Main-Ordnerstruktur) — ebenfalls als `:setvar`
4. Auflistung der gefundenen Dokumente (Quellpfad, `DOC_LOG_ID`, `LOG_DATE`,
   `DOC_NAME`, `DOC_FILE_NAME`, Zielpfad) als CSV — rein lesend, PowerShell
   fragt dafür nur noch die von dir exportierten CSVs ab, nie die Datenbank
   selbst
5. Kopieren: `Run-RenToMan.ps1 -GenerateCopyScript` erzeugt ein
   eigenständiges, DB-unabhängiges Kopierskript zum Prüfen vor der
   Ausführung; legt Zielordner an und behandelt Dateinamen mit Umlauten
   korrekt (Unicode)
6. `Build-RenToManReport.ps1` erzeugt aus dem Log des Kopierskripts einen
   menschenlesbaren Report

## Bekannte Annahmen / offene Punkte für weitere Iterationen

- **Ordner-Namenskonvention** (Padding von Case Type/Family Number,
  Groß-/Kleinschreibung von Country/Extension) ist als Best-Guess direkt in
  den SQL-Skripten hinterlegt und sollte anhand echter Listing-Läufe
  verifiziert werden, bevor ein Kopierskript erzeugt/ausgeführt wird.
- Es wird angenommen, dass genau eine Datei pro `PAT_DOC_LOG`-Eintrag
  existiert (`DOC_FILE_NAME` im Case-Ordner). Mehrere Dateien/Anhänge pro
  Dokument sind noch nicht abgebildet.
- Es wird bislang **kein** `PAT_DOC_LOG`-Eintrag auf der Main-Seite angelegt —
  es werden nur die Dateien auf dem Filesystem kopiert.
- Bereits vorhandene Zieldateien werden übersprungen, nicht überschrieben.
- Log/Report liegen als lokale Dateien (JSONL/CSV/TXT), nicht in einer
  DB-Tabelle.
- Falls sich herausstellt, dass bei euch doch kein Constrained Language Mode
  gilt (oder IT `sqlcmd`/`SqlServer`-Modul bereitstellt), könnte eine direkte
  DB-Anbindung wieder ergänzt werden — aktuell bewusst nicht eingebaut.
