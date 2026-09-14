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
    sign_valid: bool = True  # Method A符号チェック(loop.pyのcheck_sign_consistency)にFAILEDした記録はFalse。
    # 法則を宣言していない(自由記号回帰)場合はTrueのまま=中立扱い。
    judge_verdict: str = "PASS"  # 独立した審判LLM(loop.pyのjudge_candidate呼び出し)の判定。
    # "FLAG"は、提案側の説明文が渡された証拠(Skill Score・符号チェック結果等)と矛盾/過大主張
    # していることを意味する。審判を呼んでいない場合は"PASS"のまま=中立扱い。
    judge_reasoning: str = ""

    @property
    def is_trustworthy(self) -> bool:
        """符号チェックと審判の両方に問題がない記録かどうか。ベスト記録選定に使う。"""
        return self.sign_valid and self.judge_verdict != "FLAG"

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

        # ベスト更新: is_trustworthy(符号チェック合格 かつ 審判がFLAGしていない)を最優先し、
        # 同じis_trustworthy同士でのみfitnessの小ささを比較する。
        # 符号チェックに失敗した記録、あるいは審判が「説明文が証拠と矛盾/過大主張」と
        # 判定した記録は、数値上のfitnessがどれだけ良くても、is_trustworthy=Trueの記録が
        # ある限りベストにはしない(物理的に検証されていないため)。
        if self.best_record is None:
            self.best_record = record
        elif record.is_trustworthy != self.best_record.is_trustworthy:
            if record.is_trustworthy:
                self.best_record = record
        elif record.fitness < self.best_record.fitness:
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
