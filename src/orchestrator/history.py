# history.py

import json
import os
from dataclasses import dataclass, asdict
from typing import List, Dict, Any, Optional

@dataclass
class GenerationRecord:
    generation: int
    formula: str
    rmse: float
    penalty: float
    fitness: float
    feedback: str

class HistoryManager:
    """
    LLMが提案した数式と評価結果（適応度）の履歴を管理する。
    また、LLMのプロンプトに埋め込むためのコンテキストを提供する。
    """
    def __init__(self):
        self.records: List[GenerationRecord] = []
        self.best_record: Optional[GenerationRecord] = None

    def add_record(self, record: GenerationRecord) -> None:
        self.records.append(record)
        
        # 初回またはより良い(小さい)fitnessが見つかったら更新
        if self.best_record is None or record.fitness < self.best_record.fitness:
            self.best_record = record

    def get_best_record(self) -> Optional[GenerationRecord]:
        return self.best_record

    def save_to_json(self, filepath: str) -> None:
        """
        世代履歴を results/history_<target>.json 形式でディスクに永続化する。
        """
        dirname = os.path.dirname(filepath)
        if dirname:
            os.makedirs(dirname, exist_ok=True)

        data = {
            "records": [asdict(r) for r in self.records],
            "best_record": asdict(self.best_record) if self.best_record else None,
        }
        with open(filepath, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def get_context_dict(self) -> Dict[str, Any]:
        """
        LLMのプロンプトに渡すための履歴コンテキストを辞書形式で返す
        """
        if not self.records:
            return {
                "best_formula": "None",
                "best_fitness": float('inf'),
                "history": []
            }
            
        history_summary = []
        # 直近の履歴や全体サマリを構築する（ここでは全て含める）
        for r in self.records:
            history_summary.append(f"Gen {r.generation}: {r.formula} (Fitness: {r.fitness:.4f}, RMSE: {r.rmse:.4f}) - Feedback: {r.feedback}")
            
        return {
            "best_formula": self.best_record.formula if self.best_record else "None",
            "best_fitness": self.best_record.fitness if self.best_record else float('inf'),
            "history": history_summary
        }
