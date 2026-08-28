# ren_to_man (Python)

Alternative Implementierung zur primären [PowerShell-Variante](../powershell/README.md)
— gleiche Logik, gleiche Konfigurationsannahmen. Nutzen, falls Python in
eurer Umgebung ausführbar ist (z.B. lokale Tests, Nicht-Corporate-Maschine).

## Setup

```bash
cd python
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

Für die vollständige Liste bekannter Annahmen/offener Punkte siehe das
[Haupt-README](../README.md).
