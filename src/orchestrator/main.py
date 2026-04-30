import argparse
import logging
import sys
import os
from dotenv import load_dotenv

from src.orchestrator.loop import EvolutionLoop
from src.orchestrator.history import HistoryManager
from src.orchestrator.julia_runner import SubprocessWrapper
from src.llm_interface.facade import LLMFacade
from src.llm_interface.client import LLMClient, InteractiveLLMClient
from src.llm_interface.prompt_manager import PromptManager
from src.llm_interface.parser import ResponseParser

# ロギング設定
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("LLM-GP")

def main():
    # .env ファイルがあれば読み込む
    load_dotenv()
    
    parser = argparse.ArgumentParser(description="LLM-GP: Symbolic Regression with LLM and Julia")
    parser.add_argument("--target", type=str, default="XMEAS(7)", help="Target variable name in TEP dataset")
    parser.add_argument("--max-gen", type=int, default=10, help="Maximum number of generations")
    parser.add_argument("--target-rmse", type=float, default=0.01, help="Stop if RMSE reaches this value")
    parser.add_argument("--dataset", type=str, default="TEP_FaultFree_Training.RData", help="Path to the TEP dataset")
    parser.add_argument("--interactive", action="store_true", help="Use manual input instead of LLM API")
    
    args = parser.parse_args()

    # 1. Julia実行環境の準備
    # プロジェクトルートにある src/NumericalEvaluator/cli.jl を指すように設定
    julia_script = os.path.join("src", "NumericalEvaluator", "cli.jl")
    runner = SubprocessWrapper(script_path=julia_script)
    
    # データセットの存在確認と初期化
    logger.info(f"Initializing data with dataset: {args.dataset}")
    try:
        runner.init_data(args.dataset)
    except Exception as e:
        logger.error(f"Initialization failed: {e}")
        sys.exit(1)

    # 2. LLMインターフェースの準備
    if args.interactive:
        logger.info("Running in INTERACTIVE mode. Manual formula input required.")
        client = InteractiveLLMClient()
    else:
        logger.info("Running in API mode.")
        # LLMClient は環境変数等からAPIキーを取得することを想定
        api_key = os.getenv("GOOGLE_API_KEY")
        if not api_key:
            logger.warning("GOOGLE_API_KEY not found in environment. API calls may fail.")
        client = LLMClient(api_key=api_key)
    
    facade = LLMFacade(
        prompt_manager=PromptManager(),
        client=client,
        parser=ResponseParser()
    )

    # 3. 履歴管理とループの実行
    history = HistoryManager()
    
    loop = EvolutionLoop(
        llm_facade=facade,
        julia_runner=runner,
        history_manager=history,
        max_generations=args.max_gen,
        target_rmse=args.target_rmse,
        dataset_path=args.dataset,
        target_variable=args.target
    )

    try:
        loop.run()
    except KeyboardInterrupt:
        logger.info("Loop interrupted by user.")
    except Exception as e:
        logger.error(f"An error occurred during the evolution loop: {e}")
        raise

    # 4. 結果のサマリ表示
    best = history.get_best_record()
    logger.info("========================================")
    logger.info("Optimization Finished!")
    if best:
        logger.info(f"Best Formula: {best.formula}")
        logger.info(f"Best RMSE:    {best.rmse:.6f}")
        logger.info(f"Generation:   {best.generation}")
    else:
        logger.info("No successful records found.")
    logger.info("========================================")

if __name__ == "__main__":
    main()
