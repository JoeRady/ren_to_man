from ren_to_man.config import FolderFormatConfig
from ren_to_man.models import CaseInfo
from ren_to_man.pathing import case_folder_path, to_long_path


def test_case_folder_path_default_format():
    fmt = FolderFormatConfig()
    case = CaseInfo(case_id=1, case_type_id=2, case_number=666777, state_id="de", case_number_extension="ep")
    p = case_folder_path("\\\\brifile\\Renewals\\Patricia\\documents", case, fmt)
    assert str(p) == "\\\\brifile\\Renewals\\Patricia\\documents\\2\\666777\\DE\\ep"


def test_case_folder_path_zero_padded_case_type():
    fmt = FolderFormatConfig(case_type_zero_pad=True, case_type_width=2)
    case = CaseInfo(case_id=1, case_type_id=2, case_number=123, state_id="US", case_number_extension="A1")
    p = case_folder_path("D:\\docs", case, fmt)
    assert str(p) == "D:\\docs\\02\\000123\\US\\A1"


def test_to_long_path_unc():
    from pathlib import PureWindowsPath

    p = PureWindowsPath("\\\\brifile\\share\\a\\b")
    assert to_long_path(p) == "\\\\?\\UNC\\brifile\\share\\a\\b"


def test_to_long_path_short_local_untouched():
    from pathlib import PureWindowsPath

    p = PureWindowsPath("C:\\short\\path.pdf")
    assert to_long_path(p) == "C:\\short\\path.pdf"
