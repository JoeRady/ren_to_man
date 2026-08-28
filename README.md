# ren_to_man

Kopiert Patricia-Dokumente aus der **Renewals**-Instanz in die **Main**-Instanz:
liest `PAT_DOC_LOG` / `PAT_CASE` auf der Quellseite, mappt die `CASE_ID` über
`wr_Renewals_vs_Main_Live` auf die Ziel-`CASE_ID`, baut Quell- und Zielpfad
anhand der vierstufigen Ordnerstruktur (`Case Type / Family Number / Country /
Case Number Extension`) und kopiert die Dateien.

## Setup

```bash
python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -e .
cp config.example.yaml config.yaml   # dann Zugangsdaten/Pfade eintragen
```

Für den DB-Zugriff wird `pyodbc` mit einem installierten
"ODBC Driver 17 (oder neuer) for SQL Server" benötigt.

## Benutzung

**Schritt 1-4 — nur suchen & auflisten (Dry Run, Standard):**

```bash
python -m ren_to_man run \
  --login-id jsmith \
  --from-date 2026-01-01 --to-date 2026-06-30 \
  --target-root "\\brimain\Main\Patricia\documents"
```

Das schreibt eine CSV mit allen gefundenen Dokumenten (`DOC_LOG_ID`,
`LOG_DATE`, `DOC_NAME`, `DOC_FILE_NAME`, Quellpfad, Zielpfad, ggf.
Skip-Grund) nach `logs/candidates_<timestamp>.csv` und zeigt die ersten 20
Zeilen direkt in der Konsole. **Vor jedem echten Kopiervorgang prüfen**, ob
die Pfade plausibel aussehen — die Ordner-Namenskonvention (Padding,
Groß-/Kleinschreibung) ist in `config.yaml` unter `folder_format`
konfigurierbar und muss ggf. an die reale Struktur angepasst werden.

Statt `--login-id` kann auch `--category-id` (oder beides kombiniert)
angegeben werden; mindestens eines von beiden ist Pflicht.

**Schritt 5-6 — tatsächlich kopieren + Log/Report schreiben:**

```bash
python -m ren_to_man run \
  --login-id jsmith \
  --from-date 2026-01-01 --to-date 2026-06-30 \
  --target-root "\\brimain\Main\Patricia\documents" \
  --execute
```

Legt fehlende Zielordner an, kopiert Dateien (Dateinamen inkl. Umlaute werden
korrekt behandelt, da Python 3 durchgängig Unicode-Strings verwendet und
diese direkt an die Windows-Wide-API übergibt), überspringt bereits
vorhandene Zieldateien, und schreibt:

- `logs/run_<timestamp>.jsonl` — maschinenlesbares Log jeder Kopieraktion
  (Status: `copied` / `skipped` / `missing_source` / `error`)
- `logs/report_<timestamp>.txt` — menschenlesbare Zusammenfassung

## Struktur

```
src/ren_to_man/
  config.py     Laden von config.yaml
  db.py         MSSQL-Zugriff (Renewals, Main, Case-ID-Mapping)
  models.py     Datenklassen
  pathing.py    Ordnerpfad-Aufbau aus Case-Type/Family/Country/Extension
  planner.py    Verknüpft DB-Daten -> Liste geplanter Kopien (Schritt 4)
  copier.py     Kopiert Dateien, legt Zielordner an (Schritt 5)
  reporting.py  CSV-Liste, JSONL-Log, Textreport (Schritt 6)
  cli.py        Kommandozeile, verbindet alles
```

Reine Logik-Tests (Pfadaufbau, Planung, Kopieren) laufen ohne DB-Zugriff:

```bash
pip install -e . pytest
pytest
```

## Bekannte Annahmen / offene Punkte für weitere Iterationen

- **Ordner-Namenskonvention** (Padding von Case Type/Family Number,
  Groß-/Kleinschreibung von Country/Extension) ist als Best-Guess in
  `config.example.yaml` hinterlegt und sollte anhand echter Listing-Läufe
  verifiziert werden.
- Es wird angenommen, dass genau eine Datei pro `PAT_DOC_LOG`-Eintrag existiert
  (`DOC_FILE_NAME` im Case-Ordner). Mehrere Dateien/Anhänge pro Dokument sind
  noch nicht abgebildet.
- Es wird bislang **kein** `PAT_DOC_LOG`-Eintrag auf der Main-Seite angelegt —
  es werden nur die Dateien auf dem Filesystem kopiert. Ein Platzhalter dafür
  liegt in `db.py::insert_target_doc_log`.
- Bereits vorhandene Zieldateien werden übersprungen, nicht überschrieben.
- Log/Report liegen aktuell als lokale Dateien (JSONL/CSV/TXT), nicht in einer
  DB-Tabelle — kann in einer späteren Iteration ergänzt werden, falls
  gewünscht.
