import pytest
from unittest.mock import MagicMock
from src.orchestrator.loop import EvolutionLoop, check_sign_consistency, check_ideal_gas_magnitude
from src.orchestrator.history import HistoryManager
from src.llm_interface.models import StructuredResult

def test_evolution_loop():
    mock_facade = MagicMock()
    # 常に決まった式とフィードバックを返すようにモック
    mock_facade.generate_candidate.return_value = StructuredResult(
        formula="c[1]*x", feedback="test feedback"
    )
    
    mock_runner = MagicMock()
    # 1世代目はRMSE10.0、2世代目はRMSE0.5（目標達成）を返すようにモック
    mock_runner.evaluate_formula.side_effect = [
        {"status": "success", "fitness": 10.0, "rmse": 10.0, "penalty": 0.0, "coefficients": [1.0]},
        {"status": "success", "fitness": 0.5, "rmse": 0.5, "penalty": 0.0, "coefficients": [2.0]},
        # 以降は呼ばれないはずだが念のため
        {"status": "success", "fitness": 0.1, "rmse": 0.1, "penalty": 0.0, "coefficients": [2.0]}
    ]
    
    hm = HistoryManager()
    
    loop = EvolutionLoop(
        llm_facade=mock_facade,
        julia_runner=mock_runner,
        history_manager=hm,
        max_generations=5,
        target_rmse=1.0,
        dataset_path="dummy.RData",
        target_variable="y"
    )
    
    loop.run()
    
    # 検証
    # 目標RMSEを2世代目で下回ったため、そこで早期終了するはず
    assert mock_facade.generate_candidate.call_count == 2
    assert mock_runner.evaluate_formula.call_count == 2
    assert len(hm.records) == 2
    
    best = hm.get_best_record()
    assert best is not None
    assert best.rmse == 0.5

def test_check_sign_consistency_empty_expected_signs_skips():
    assert check_sign_consistency("c[1]*x + c[2]", [1.5, -2.0], []) == ""

def test_check_sign_consistency_all_pass():
    result = check_sign_consistency("c[1]*x - c[2]*y + c[3]", [1.5, 2.0, 3.0], [1, -1, 0])
    assert "SIGN CHECK PASSED" in result
    assert "MISMATCH" not in result

def test_check_sign_consistency_detects_mismatch():
    # 期待符号は正だが、実際にフィットされた係数は負(XMEAS13のxmeas_11で実際に起きたケース)
    result = check_sign_consistency("c[1]*x + c[2]*y", [-3.04, -0.22], [1, -1])
    assert "SIGN CHECK FAILED" in result
    assert "MISMATCH" in result

def test_check_sign_consistency_length_mismatch_skipped_gracefully():
    result = check_sign_consistency("c[1]*x", [1.0, 2.0], [1])
    assert "skipped" in result

def test_check_sign_consistency_accounts_for_explicit_minus_prefix():
    # "- c[2]*xmeas_10" のように明示的な"-"が式中にある場合、
    # c[2]自体が負でも正味の効果は正になる(XMEAS13で実際に見落としていたケース)
    result = check_sign_consistency("c[1]*xmeas_6 - c[2]*xmeas_10 + c[3]", [0.5, -0.02, 1.0], [1, -1, 0])
    # c[2]=-0.02, 直前に明示的な"-"があるので正味効果は+0.02 -> 期待符号(-)と不一致
    assert "SIGN CHECK FAILED" in result
    assert "MISMATCH" in result

def test_check_ideal_gas_magnitude_plausible():
    # 実測データ相当: 平均圧力2633.77kPa, 平均温度80.11℃ -> 理論値P/T(K) ≈ 7.4557
    result = check_ideal_gas_magnitude(5.0, mean_pressure=2633.77, mean_temperature_c=80.11)
    assert "PLAUSIBLE" in result
    assert "MISMATCH" not in result and "IMPLAUSIBLE" not in result

def test_check_ideal_gas_magnitude_implausible_too_large():
    result = check_ideal_gas_magnitude(500.0, mean_pressure=2633.77, mean_temperature_c=80.11)
    assert "IMPLAUSIBLE" in result

def test_check_ideal_gas_magnitude_implausible_too_small():
    result = check_ideal_gas_magnitude(0.001, mean_pressure=2633.77, mean_temperature_c=80.11)
    assert "IMPLAUSIBLE" in result

def test_check_ideal_gas_magnitude_sign_mismatch():
    # XMEAS(13)の実データで実際にフィットされたxmeas_11係数(-2.78)を使った実例。
    # 符号チェックでも既にMISMATCHだったが、大きさチェックでも独立に不整合を検出できることを確認する。
    result = check_ideal_gas_magnitude(-2.78, mean_pressure=2633.77, mean_temperature_c=80.11)
    assert "MISMATCH" in result

def test_check_ideal_gas_magnitude_zero_theoretical_skipped():
    result = check_ideal_gas_magnitude(1.0, mean_pressure=0.0, mean_temperature_c=80.11)
    assert "skipped" in result

def test_check_sign_consistency_explicit_minus_prefix_correctly_passes():
    # 正味の効果が期待符号と一致する場合は正しくPASSEDになる
    result = check_sign_consistency("c[1]*xmeas_6 - c[2]*xmeas_10 + c[3]", [0.5, 0.02, 1.0], [1, -1, 0])
    # c[2]=+0.02, 直前に明示的な"-"があるので正味効果は-0.02 -> 期待符号(-)と一致
    assert "SIGN CHECK PASSED" in result

def test_evolution_loop_appends_sign_check_to_feedback():
    mock_facade = MagicMock()
    mock_facade.generate_candidate.return_value = StructuredResult(
        formula="c[1]*x", feedback="test feedback", law="Energy balance", expected_signs=[1]
    )

    mock_runner = MagicMock()
    # 期待符号は正だが実際は負 -> SIGN CHECK FAILEDがfeedbackに追記されるはず
    mock_runner.evaluate_formula.return_value = {
        "status": "success", "fitness": 0.5, "rmse": 0.5, "penalty": 0.0, "coefficients": [-1.0]
    }

    hm = HistoryManager()
    loop = EvolutionLoop(
        llm_facade=mock_facade,
        julia_runner=mock_runner,
        history_manager=hm,
        max_generations=1,
        target_rmse=0.01,
        dataset_path="dummy.RData",
        target_variable="y"
    )
    loop.run()

    assert "SIGN CHECK FAILED" in hm.records[0].feedback
