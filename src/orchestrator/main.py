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
    parser.add_argument("--max-gen", type=int, default=20, help="Maximum number of generations")
    parser.add_argument("--target-rmse", type=float, default=0.01, help="Stop if RMSE reaches this value")
    parser.add_argument("--dataset", type=str, default="TEP_FaultFree_Training.RData", help="Path to the TEP dataset")
    parser.add_argument("--interactive", action="store_true", help="Use manual input instead of LLM API")
    parser.add_argument("--no-diff", action="store_false", dest="predict_diff", help="Predict absolute values instead of 1-step change")
    parser.add_argument("--n-mic", type=int, default=10, help="Number of variables to select with MIC")
    parser.set_defaults(predict_diff=True)
    
    args = parser.parse_args()

    # Normalize target variable to match lowercase Julia column names (e.g. xmeas_15 instead of XMEAS(15))
    import re
    target_var = args.target
    m_meas = re.match(r"XMEAS\((\d+)\)", target_var, re.IGNORECASE)
    m_mv = re.match(r"XMV\((\d+)\)", target_var, re.IGNORECASE)
    if m_meas:
        target_normalized = f"xmeas_{m_meas.group(1)}"
    elif m_mv:
        target_normalized = f"xmv_{m_mv.group(1)}"
    else:
        target_normalized = target_var.lower()

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
        # LLMClient (Anthropic SDK) は ANTHROPIC_API_KEY -> ANTHROPIC_AUTH_TOKEN ->
        # `ant auth login` のプロファイルの順で自動的にAPIキー/認証情報を解決する
        if not os.getenv("ANTHROPIC_API_KEY") and not os.getenv("ANTHROPIC_AUTH_TOKEN"):
            logger.warning("ANTHROPIC_API_KEY not found in environment. Falling back to `ant auth login` profile if configured.")
        client = LLMClient()

    facade = LLMFacade(
        prompt_manager=PromptManager(),
        client=client,
        parser=ResponseParser()
    )

    # MICスクリーニング処理と目的変数差分化の事前計算
    mic_vars = []
    if args.predict_diff:
        logger.info("Computing MIC scores for screening...")
        try:
            import pyreadr
            import pandas as pd
            from src.orchestrator.preprocessing import calculate_mic_scores
            
            result = pyreadr.read_rdata(args.dataset)
            df = None
            for key in result.keys():
                if isinstance(result[key], pd.DataFrame):
                    df = result[key]
                    break
                    
            if df is not None:
                # Julia側と一致するよう小文字に変換
                df.columns = [col.lower() for col in df.columns]
                mic_vars = calculate_mic_scores(df, target_normalized, n_select=args.n_mic)
            else:
                logger.warning("No DataFrame found in RData for MIC screening.")
        except ImportError:
            logger.warning("pyreadr/pandas are not installed. Skipping Python-side MIC screening. (Please install pyreadr, pandas, scikit-learn to enable)")
        except Exception as e:
            logger.warning(f"Failed to calculate MIC scores: {e}. Skipping MIC screening.")

    # 3. 履歴管理とループの実行
    history = HistoryManager()

    loop = EvolutionLoop(
        llm_facade=facade,
        julia_runner=runner,
        history_manager=history,
        max_generations=args.max_gen,
        target_rmse=args.target_rmse,
        dataset_path=args.dataset,
        target_variable=target_normalized,
        mic_variables=mic_vars,
        predict_diff=args.predict_diff
    )

    history_path = os.path.join("results", f"history_{target_normalized}.json")
    try:
        loop.run()
    except KeyboardInterrupt:
        logger.info("Loop interrupted by user.")
    except Exception as e:
        logger.error(f"An error occurred during the evolution loop: {e}")
        raise
    finally:
        # 中断・エラー時も含め、その時点までの世代履歴を永続化する
        history.save_to_json(history_path)
        logger.info(f"Generation history saved to: {history_path}")

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
