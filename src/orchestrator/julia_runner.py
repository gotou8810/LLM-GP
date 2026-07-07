# julia_runner.py

import subprocess
import json
import os
import shutil
from typing import Dict, Any

class SubprocessWrapper:
    """
    Juliaプロセスを呼び出し、標準入出力経由でJSONをやり取りするラッパー
    """
    def __init__(self, project_path: str = ".", script_path: str = "src/NumericalEvaluator/cli.jl"):
        self.project_path = project_path
        self.script_path = script_path
        
        # Determine Julia executable path
        self.julia_exe = "julia"
        if not shutil.which("julia"):
            if os.path.exists("/opt/bin/julia"):
                self.julia_exe = "/opt/bin/julia"

    def init_data(self, dataset_path: str):
        """
        データセットの存在を確認し、Julia環境が正しくセットアップされているか初期チェックを行う
        """
        if not os.path.exists(dataset_path):
            raise FileNotFoundError(f"Dataset not found at: {dataset_path}")
        
        # Juliaが実行可能か、プロジェクトがロードできるか軽くチェック
        try:
            subprocess.run([self.julia_exe, "--version"], check=True, capture_output=True)
        except Exception as e:
            raise RuntimeError(f"Julia is not installed or not in PATH: {e}")

    def evaluate_formula(self, formula: str, target_variable: str, dataset_path: str, max_steps: int = 1000, search_range: list = [-10.0, 10.0], predict_diff: bool = True, timeout: int = 180) -> Dict[str, Any]:
        """
        指定された数式をJuliaエンジンで評価する
        """
        payload = {
            "formula": formula,
            "target_variable": target_variable,
            "dataset_path": dataset_path,
            "hyperparameters": {
                "max_steps": max_steps,
                "search_range": search_range,
                "predict_diff": predict_diff
            }
        }
        
        # WindowsとUnixでパス区切りや実行方法が異なる場合があるが、ここでは基本的なコマンドリストを構築
        # NumericalEvaluator.jl を include して NumericalEvaluator.main() を呼ぶ
        # スクリプトのパスを確実に含める
        full_script_path = os.path.abspath(self.script_path)
        evaluator_path = os.path.join(os.path.dirname(full_script_path), "NumericalEvaluator.jl")
        
        cmd = [
            self.julia_exe,
            f"--project={self.project_path}",
            "-e",
            f"include(\"{evaluator_path}\"); NumericalEvaluator.main()"
        ]
        
        try:
            result = subprocess.run(
                cmd,
                input=json.dumps(payload),
                text=True,
                capture_output=True,
                timeout=timeout
            )
            
            if result.returncode != 0:
                return {
                    "status": "error",
                    "error_type": "ProcessError",
                    "message": f"Julia process exited with code {result.returncode}. Stderr: {result.stderr}"
                }
                
            return json.loads(result.stdout)
            
        except subprocess.TimeoutExpired:
            return {
                "status": "error",
                "error_type": "TimeoutExpired",
                "message": f"Evaluation timed out after {timeout} seconds."
            }
        except json.JSONDecodeError as e:
            return {
                "status": "error",
                "error_type": "JSONDecodeError",
                "message": f"Failed to decode output from Julia: {e}"
            }
        except Exception as e:
            return {
                "status": "error",
                "error_type": type(e).__name__,
                "message": str(e)
            }
