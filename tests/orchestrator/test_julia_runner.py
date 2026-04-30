import pytest
import json
from unittest.mock import patch, MagicMock
from src.orchestrator.julia_runner import SubprocessWrapper

def test_evaluate_formula_success():
    wrapper = SubprocessWrapper(project_path=".", script_path="dummy.jl")
    
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = '{"status": "success", "fitness": 1.23, "rmse": 1.0, "penalty": 0.23, "coefficients": [1.0]}'
    
    with patch("src.orchestrator.julia_runner.subprocess.run", return_value=mock_result) as mock_run:
        result = wrapper.evaluate_formula("c[1]*xmeas_1", "xmeas_7", "data.RData", max_steps=100)
        
        assert result["status"] == "success"
        assert result["fitness"] == 1.23
        
        # 呼ばれた際の入力引数をチェック
        call_args = mock_run.call_args
        assert call_args is not None
        
        # 標準入力に渡されたJSONをチェック
        kwargs = call_args.kwargs
        input_json = json.loads(kwargs["input"])
        assert input_json["formula"] == "c[1]*xmeas_1"
        assert input_json["target_variable"] == "xmeas_7"

def test_evaluate_formula_timeout():
    wrapper = SubprocessWrapper(project_path=".", script_path="dummy.jl")
    
    import subprocess
    with patch("src.orchestrator.julia_runner.subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="julia", timeout=10)):
        result = wrapper.evaluate_formula("c[1]*xmeas_1", "xmeas_7", "data.RData")
        assert result["status"] == "error"
        assert result["error_type"] == "TimeoutExpired"
