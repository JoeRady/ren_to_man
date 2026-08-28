# ren_to_man

Kopiert Patricia-Dokumente aus der **Renewals**-Instanz in die **Main**-Instanz:
liest `PAT_DOC_LOG` / `PAT_CASE` auf der Quellseite, mappt die `CASE_ID` über
`wr_Renewals_vs_Main_Live` auf die Ziel-`CASE_ID`, baut Quell- und Zielpfad
anhand der vierstufigen Ordnerstruktur (`Case Type / Family Number / Country /
Case Number Extension`) und kopiert die Dateien.

## Varianten

| Variante | Ordner | Wann verwenden |
|---|---|---|
| **PowerShell** | [`powershell/`](powershell/README.md) | **Primär** — läuft mit Windows PowerShell 5.1 ohne Zusatz-Installation (kein Python nötig), passend für Corporate-Windows-Umgebungen. |
| Python | [`python/`](python/README.md) | Alternative, z.B. für lokale Tests oder falls Python-Ausführung erlaubt ist. |

Beide Varianten implementieren dieselbe Logik (Schritte 1-6) und dieselben
Konfigurationsannahmen; siehe die jeweiligen READMEs für Details.

## Eigenständig testbare SQL-Abfrage für Schritt 4

Unter [`powershell/sql/`](powershell/sql/) liegen die für Schritt 4
("Auflistung der gefundenen Dokumente") verwendeten SQL-Skripte separat vom
Tool, parametrisiert über `:setvar`-Variablen, damit sie direkt in SSMS oder
per `sqlcmd` gegen die echten Instanzen getestet werden können, ohne
PowerShell oder Python auszuführen.

## Schritte 1-6 (Kurzüberblick)

1. Eingabe `LOGIN_ID` und/oder `CATEGORY_ID` (mindestens eines von beiden)
2. Zeitraum von...bis
3. Zielpfad (Root der Main-Ordnerstruktur)
4. Auflistung der gefundenen Dokumente (Quellpfad, `DOC_LOG_ID`, `LOG_DATE`,
   `DOC_NAME`, `DOC_FILE_NAME`, Zielpfad) als CSV — Standard ist ein reiner
   Dry Run, es wird noch nichts kopiert
5. Kopieren (nur mit explizitem `-Execute` / `--execute`): legt Zielordner
   an, behandelt Dateinamen mit Umlauten korrekt (UTF-8/Unicode)
6. Log (JSONL) + menschenlesbarer Report je Lauf

## Bekannte Annahmen / offene Punkte für weitere Iterationen

- **Ordner-Namenskonvention** (Padding von Case Type/Family Number,
  Groß-/Kleinschreibung von Country/Extension) ist als Best-Guess in der
  jeweiligen Konfigurationsdatei hinterlegt und sollte anhand echter
  Listing-Läufe (Schritt 4) verifiziert werden, bevor live kopiert wird.
- Es wird angenommen, dass genau eine Datei pro `PAT_DOC_LOG`-Eintrag
  existiert (`DOC_FILE_NAME` im Case-Ordner). Mehrere Dateien/Anhänge pro
  Dokument sind noch nicht abgebildet.
- Es wird bislang **kein** `PAT_DOC_LOG`-Eintrag auf der Main-Seite angelegt —
  es werden nur die Dateien auf dem Filesystem kopiert.
- Bereits vorhandene Zieldateien werden übersprungen, nicht überschrieben.
- Log/Report liegen aktuell als lokale Dateien (JSONL/CSV/TXT), nicht in einer
  DB-Tabelle — kann in einer späteren Iteration ergänzt werden, falls
  gewünscht.
