"""Configuration loading for ren_to_man."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml


@dataclass
class DbConfig:
    driver: str
    server: str
    database: str
    trusted_connection: bool = True
    username: Optional[str] = None
    password: Optional[str] = None

    def connection_string(self) -> str:
        parts = [
            f"DRIVER={{{self.driver}}}",
            f"SERVER={self.server}",
            f"DATABASE={self.database}",
        ]
        if self.trusted_connection:
            parts.append("Trusted_Connection=yes")
        else:
            parts.append(f"UID={self.username}")
            parts.append(f"PWD={self.password}")
        return ";".join(parts) + ";"


@dataclass
class FolderFormatConfig:
    case_type_zero_pad: bool = False
    case_type_width: int = 2
    family_number_zero_pad: bool = True
    family_number_width: int = 6
    country_uppercase: bool = True
    extension_uppercase: bool = False


@dataclass
class Config:
    renewals_db: DbConfig
    main_db: DbConfig
    source_root: str
    folder_format: FolderFormatConfig = field(default_factory=FolderFormatConfig)
    log_dir: str = "./logs"

    @staticmethod
    def load(path: str) -> "Config":
        with open(path, "r", encoding="utf-8") as f:
            raw = yaml.safe_load(f)

        dbs = raw.get("databases", {})
        renewals_db = DbConfig(**dbs["renewals"])
        main_db = DbConfig(**dbs["main"])

        paths = raw.get("paths", {})
        source_root = paths.get("source_root")
        if not source_root:
            raise ValueError("config: paths.source_root is required")

        folder_format = FolderFormatConfig(**raw.get("folder_format", {}))

        logging_cfg = raw.get("logging", {})
        log_dir = logging_cfg.get("log_dir", "./logs")

        return Config(
            renewals_db=renewals_db,
            main_db=main_db,
            source_root=source_root,
            folder_format=folder_format,
            log_dir=log_dir,
        )

    def ensure_log_dir(self) -> Path:
        p = Path(self.log_dir)
        p.mkdir(parents=True, exist_ok=True)
        return p


def default_config_path() -> str:
    return os.environ.get("REN_TO_MAN_CONFIG", "config.yaml")
