import pytest
from src.orchestrator.preprocessing import compute_forbidden_variables


def test_forbidden_variables_reactor_target():
    forbidden = compute_forbidden_variables("xmeas_7")
    assert forbidden == {"xmeas_11", "xmeas_12", "xmeas_13", "xmeas_15", "xmeas_16", "xmeas_18"}


def test_forbidden_variables_separator_target_includes_stripper_pressure():
    # xmeas_16 (Stripper Pressure) が禁止集合に含まれることを明示的に確認する
    # (相関の罠: XMEAS(13)モデルが下流ストリッパー圧力をスケーリングに多用していた懸念への回帰テスト)
    forbidden = compute_forbidden_variables("xmeas_13")
    assert forbidden == {"xmeas_7", "xmeas_8", "xmeas_9", "xmeas_15", "xmeas_16", "xmeas_18"}
    assert "xmeas_16" in forbidden


def test_forbidden_variables_stripper_target():
    forbidden = compute_forbidden_variables("xmeas_16")
    assert forbidden == {"xmeas_7", "xmeas_8", "xmeas_9", "xmeas_11", "xmeas_12", "xmeas_13"}


def test_forbidden_variables_flux_variable_returns_empty_set():
    # フラックス系変数(流量)はどのユニット状態量にも属さないため禁止規則の対象外
    assert compute_forbidden_variables("xmeas_6") == set()


def test_forbidden_variables_is_case_insensitive():
    assert compute_forbidden_variables("XMEAS_7") == compute_forbidden_variables("xmeas_7")


def test_forbidden_variables_never_includes_own_unit():
    for target in ("xmeas_7", "xmeas_8", "xmeas_9", "xmeas_11", "xmeas_12", "xmeas_13", "xmeas_15", "xmeas_16", "xmeas_18"):
        forbidden = compute_forbidden_variables(target)
        assert target not in forbidden
