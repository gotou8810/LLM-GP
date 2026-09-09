import numpy as np
import pandas as pd
import pytest
from src.orchestrator.preprocessing import compute_forbidden_variables, compute_ccf_asymmetry, filter_reactive_variables, calculate_mic_scores


def test_calculate_mic_scores_excludes_non_physical_id_columns():
    # simulationrun/sample/faultnumberのようなID列がMIC候補に混入しないことを確認する
    # (XMEAS(18)探索でこれらが上位候補に紛れ込んだ実例があった)
    rng = np.random.default_rng(0)
    n = 200
    df = pd.DataFrame({
        "simulationrun": np.repeat(np.arange(1, 5), n // 4),
        "sample": np.tile(np.arange(1, n // 4 + 1), 4),
        "faultnumber": np.zeros(n),
        "xmeas_1": rng.normal(size=n),
        "xmeas_2": rng.normal(size=n),
        "target": rng.normal(size=n),
    })
    top = calculate_mic_scores(df, "target", n_select=5)
    assert "simulationrun" not in top
    assert "sample" not in top
    assert "faultnumber" not in top


def _make_causal_reactive_dataframe(n_runs=20, n_samples=200, seed=0):
    """
    y(ターゲット)に対して、x_causal(yに先行する真の原因)とx_reactive(yの変化に
    1ステップ遅れで反応する変数)を持つ合成データを生成する(CCF非対称性検定の検証用)。
    """
    rng = np.random.default_rng(seed)
    rows = []
    for run in range(1, n_runs + 1):
        dy = rng.normal(0, 1, n_samples)
        y = np.concatenate([[0], np.cumsum(dy)])
        dx_causal = np.concatenate([dy[1:], [0]]) + rng.normal(0, 0.3, n_samples)
        x_causal = np.concatenate([[0], np.cumsum(dx_causal)])
        dx_reactive = np.concatenate([[0], dy[:-1]]) + rng.normal(0, 0.3, n_samples)
        x_reactive = np.concatenate([[0], np.cumsum(dx_reactive)])
        for i in range(n_samples + 1):
            rows.append({
                "simulationrun": run, "sample": i + 1,
                "y": y[i], "x_causal": x_causal[i], "x_reactive": x_reactive[i],
            })
    return pd.DataFrame(rows)


def test_ccf_asymmetry_detects_causal_variable():
    df = _make_causal_reactive_dataframe()
    diag = compute_ccf_asymmetry(df, "y", "x_causal", max_lag=10)
    assert diag["ratio"] < 0.5
    assert diag["pos_lag"] > 0

def test_ccf_asymmetry_detects_reactive_variable():
    df = _make_causal_reactive_dataframe()
    diag = compute_ccf_asymmetry(df, "y", "x_reactive", max_lag=10)
    assert diag["ratio"] > 2.0
    assert diag["neg_lag"] < 0

def test_filter_reactive_variables_excludes_only_clearly_reactive():
    df = _make_causal_reactive_dataframe()
    kept, excluded = filter_reactive_variables(df, "y", ["x_causal", "x_reactive"])
    assert kept == ["x_causal"]
    assert "x_reactive" in excluded
    assert excluded["x_reactive"]["ratio"] > 2.0

def test_filter_reactive_variables_missing_column_is_kept_not_crashed():
    df = _make_causal_reactive_dataframe()
    kept, excluded = filter_reactive_variables(df, "y", ["x_causal", "nonexistent_var"])
    assert "nonexistent_var" in kept
    assert "nonexistent_var" not in excluded


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
