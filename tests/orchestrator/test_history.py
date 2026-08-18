import json
import pytest
from src.orchestrator.history import HistoryManager, GenerationRecord

def test_history_manager_add_and_best():
    hm = HistoryManager()
    
    # 記録の追加
    record1 = GenerationRecord(generation=1, formula="c[1]*X", rmse=10.5, penalty=0.0, fitness=10.5, feedback="init")
    hm.add_record(record1)
    
    assert hm.get_best_record() == record1
    
    # より良い記録の追加
    record2 = GenerationRecord(generation=2, formula="c[1]*X + c[2]", rmse=5.2, penalty=0.1, fitness=5.3, feedback="added constant")
    hm.add_record(record2)
    
    assert hm.get_best_record() == record2
    
    # 悪い記録の追加
    record3 = GenerationRecord(generation=3, formula="c[1]*X^2", rmse=20.0, penalty=0.0, fitness=20.0, feedback="worse")
    hm.add_record(record3)
    
    # ベストは変わらないはず
    assert hm.get_best_record() == record2

def test_history_manager_context():
    hm = HistoryManager()
    record = GenerationRecord(generation=1, formula="c[1]*X", rmse=10.5, penalty=0.0, fitness=10.5, feedback="init")
    hm.add_record(record)
    
    context = hm.get_context_dict()
    assert "best_formula" in context
    assert context["best_formula"] == "c[1]*X"
    assert context["best_fitness"] == 10.5
    assert "history" in context
    assert len(context["history"]) == 1

def test_history_manager_save_to_json(tmp_path):
    hm = HistoryManager()
    record1 = GenerationRecord(generation=1, formula="c[1]*X", rmse=10.5, penalty=0.0, fitness=10.5, feedback="init")
    record2 = GenerationRecord(generation=2, formula="c[1]*X + c[2]", rmse=5.2, penalty=0.1, fitness=5.3, feedback="added constant")
    hm.add_record(record1)
    hm.add_record(record2)

    out_path = tmp_path / "results" / "history_xmeas_7.json"
    hm.save_to_json(str(out_path))

    assert out_path.exists()
    with open(out_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    assert len(data["records"]) == 2
    assert data["records"][0]["formula"] == "c[1]*X"
    assert data["best_record"]["formula"] == "c[1]*X + c[2]"
