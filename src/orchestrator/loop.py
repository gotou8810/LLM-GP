# loop.py

import logging
from .history import HistoryManager, GenerationRecord
from .julia_runner import SubprocessWrapper
from src.llm_interface.facade import LLMFacade

logger = logging.getLogger(__name__)

class EvolutionLoop:
    """
    LLMによる数式生成とJuliaによる評価のサイクルを回すオーケストレーター
    """
    def __init__(
        self,
        llm_facade: LLMFacade,
        julia_runner: SubprocessWrapper,
        history_manager: HistoryManager,
        max_generations: int,
        target_rmse: float,
        dataset_path: str,
        target_variable: str
    ):
        self.llm = llm_facade
        self.runner = julia_runner
        self.history = history_manager
        self.max_generations = max_generations
        self.target_rmse = target_rmse
        self.dataset_path = dataset_path
        self.target_variable = target_variable

    def run(self):
        logger.info("Starting Evolutionary Loop...")
        for gen in range(1, self.max_generations + 1):
            logger.info(f"--- Generation {gen} ---")
            
            # 1. LLMにプロンプトを送り、新しい式を生成させる
            context = self.history.get_context_dict()
            # LLMFacade.generate_candidate() の引数は PromptManager のテンプレート変数名と一致させる
            # 例として context_dict を丸ごと渡す
            try:
                candidate = self.llm.generate_candidate(
                    history=context["history"], 
                    best_formula=context["best_formula"], 
                    best_fitness=context["best_fitness"],
                    target_variable=self.target_variable
                )
                logger.info(f"Proposed Formula: {candidate.formula}")
                logger.info(f"LLM Feedback: {candidate.feedback}")
            except Exception as e:
                logger.error(f"Failed to generate candidate at generation {gen}: {e}")
                continue # 次の世代へ（または終了処理）
                
            # 2. Juliaで式を評価
            eval_result = self.runner.evaluate_formula(
                formula=candidate.formula,
                target_variable=self.target_variable,
                dataset_path=self.dataset_path
            )
            
            if eval_result.get("status") == "error":
                logger.warning(f"Evaluation failed: {eval_result.get('message')}")
                # 失敗記録としてペナルティを高く設定して保存
                record = GenerationRecord(
                    generation=gen,
                    formula=candidate.formula,
                    rmse=float('inf'),
                    penalty=float('inf'),
                    fitness=float('inf'),
                    feedback=f"EVAL ERROR: {eval_result.get('message')}"
                )
            else:
                rmse = eval_result["rmse"]
                fitness = eval_result["fitness"]
                penalty = eval_result["penalty"]
                logger.info(f"Evaluation Success - RMSE: {rmse:.4f}, Fitness: {fitness:.4f}")
                
                record = GenerationRecord(
                    generation=gen,
                    formula=candidate.formula,
                    rmse=rmse,
                    penalty=penalty,
                    fitness=fitness,
                    feedback=candidate.feedback
                )

            # 3. 履歴に記録
            self.history.add_record(record)
            
            # 4. 早期終了判定
            if record.rmse <= self.target_rmse:
                logger.info(f"Target RMSE ({self.target_rmse}) achieved at generation {gen}!")
                break
                
        logger.info("Evolutionary Loop finished.")
