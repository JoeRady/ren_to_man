# ren_to_man

Findet Patricia-Dokumente, die von der **Renewals**- in die **Main**-Instanz
kopiert werden sollen: liest `PAT_DOC_LOG` / `PAT_CASE` auf der Quellseite,
mappt die `CASE_ID` über `wr_Renewals_vs_Main_Live` auf die Ziel-`CASE_ID`,
baut Quell- und Zielpfad anhand der vierstufigen Ordnerstruktur (`Case Type /
Family Number / Country / Case Number Extension`).

**Sicherheitsmodell:** Der Teil, der die Datenbanken anspricht, führt
ausschließlich `SELECT`-Abfragen aus — es gibt im Code keinen einzigen
schreibenden SQL-Pfad. Das eigentliche Kopieren (Schritt 5) passiert nicht
direkt durch dieses Tool, sondern durch ein separat generiertes,
eigenständiges Skript ohne jede Datenbankabhängigkeit, das vor der Ausführung
vollständig geprüft werden kann. Details dazu in der jeweiligen
Varianten-README.

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
   `DOC_NAME`, `DOC_FILE_NAME`, Zielpfad) als CSV — rein lesend, es wird noch
   nichts kopiert und kein DB-Schreibzugriff verwendet
5. Kopieren: **PowerShell-Variante (empfohlen)** erzeugt mit
   `-GenerateCopyScript` ein eigenständiges, DB-unabhängiges Kopierskript zum
   Prüfen vor der Ausführung (siehe [`powershell/README.md`](powershell/README.md#sicherheitsmodell-db-zugriff-nur-lesend-kopieren-getrennt--reviewbar));
   die **Python-Variante** kopiert mit `--execute` direkt. Beide legen
   Zielordner an und behandeln Dateinamen mit Umlauten korrekt
   (UTF-8/Unicode).
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
