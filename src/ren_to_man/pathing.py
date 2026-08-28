"""Build source and target filesystem paths from Patricia case data.

Folder layout on both instances (per the task description):

    <root>/<case_type>/<family_number>/<country>/<case_number_extension>/

  case_type        numeric, max 2 digits            (PAT_CASE.CASE_TYPE_ID)
  family_number    numeric, 6 digits                (PAT_CASE.CASE_NUMBER)
  country          alphabetic, 2 chars, ISO code     (PAT_CASE.STATE_ID)
  case_number_ext  alphanumeric, 2-4 chars           (PAT_CASE.CASE_NUMBER_EXTENSION)

The exact padding/casing convention is an assumption (see config.example.yaml
folder_format) - verify against a real `list`/dry-run before doing a live
copy and adjust the config if needed.
"""

from __future__ import annotations

from pathlib import PureWindowsPath

from .config import FolderFormatConfig
from .models import CaseInfo


def case_folder_parts(case: CaseInfo, fmt: FolderFormatConfig) -> list[str]:
    if fmt.case_type_zero_pad:
        case_type = f"{int(case.case_type_id):0{fmt.case_type_width}d}"
    else:
        case_type = str(int(case.case_type_id))

    if fmt.family_number_zero_pad:
        family_number = f"{int(case.case_number):0{fmt.family_number_width}d}"
    else:
        family_number = str(int(case.case_number))

    country = (case.state_id or "").strip()
    if fmt.country_uppercase:
        country = country.upper()

    extension = (case.case_number_extension or "").strip()
    if fmt.extension_uppercase:
        extension = extension.upper()

    return [case_type, family_number, country, extension]


def case_folder_path(root: str, case: CaseInfo, fmt: FolderFormatConfig) -> PureWindowsPath:
    base = PureWindowsPath(root)
    for part in case_folder_parts(case, fmt):
        base = base / part
    return base


def to_long_path(path: PureWindowsPath) -> str:
    """Return a string form safe for very long UNC paths on Windows.

    Local os-level copy code should use this when actually touching the
    filesystem; PureWindowsPath is used elsewhere purely for path building so
    the logic can be unit-tested on non-Windows machines too.
    """
    s = str(path)
    if s.startswith("\\\\") and not s.startswith("\\\\?\\UNC\\"):
        return "\\\\?\\UNC\\" + s.lstrip("\\")
    if len(s) < 240 or s.startswith("\\\\?\\"):
        return s
    return "\\\\?\\" + s
