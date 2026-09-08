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

def test_history_manager_prefers_sign_valid_over_lower_fitness():
    # Method A: 数値上fitnessが良くても、符号チェック(sign_valid)に失敗した記録は
    # sign_validな記録がある限りベストにしない
    hm = HistoryManager()

    valid_record = GenerationRecord(
        generation=1, formula="c[1]*xmv_5 - c[2]*xmeas_10", rmse=0.30, penalty=0.0,
        fitness=0.30, feedback="mass balance, sign OK", sign_valid=True
    )
    hm.add_record(valid_record)
    assert hm.get_best_record() == valid_record

    # 数値上はより良い(fitnessが低い)が、符号チェックに失敗した記録
    invalid_but_better_fitness = GenerationRecord(
        generation=2, formula="c[1]*xmeas_11", rmse=0.22, penalty=0.0,
        fitness=0.22, feedback="sign FAILED", sign_valid=False
    )
    hm.add_record(invalid_but_better_fitness)
    # ベストはsign_validな記録のまま(数値上劣っていても)
    assert hm.get_best_record() == valid_record

    # sign_validでさらに良い記録が来たら更新される
    better_valid_record = GenerationRecord(
        generation=3, formula="c[1]*xmv_5 - c[2]*xmeas_10 - c[3]*xmeas_5", rmse=0.28, penalty=0.0,
        fitness=0.28, feedback="mass balance extended, sign OK", sign_valid=True
    )
    hm.add_record(better_valid_record)
    assert hm.get_best_record() == better_valid_record

def test_history_manager_falls_back_to_best_fitness_when_none_sign_valid():
    # sign_validな記録が1つもない場合は、従来通りfitness最良のものを選ぶ
    hm = HistoryManager()
    r1 = GenerationRecord(generation=1, formula="c[1]*xmeas_11", rmse=0.5, penalty=0.0, fitness=0.5, feedback="fail", sign_valid=False)
    r2 = GenerationRecord(generation=2, formula="c[1]*xmeas_20", rmse=0.3, penalty=0.0, fitness=0.3, feedback="fail", sign_valid=False)
    hm.add_record(r1)
    hm.add_record(r2)
    assert hm.get_best_record() == r2

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
