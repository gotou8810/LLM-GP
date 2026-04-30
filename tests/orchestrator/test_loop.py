import pytest
from unittest.mock import MagicMock
from src.orchestrator.loop import EvolutionLoop
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
