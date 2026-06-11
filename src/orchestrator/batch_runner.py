import argparse
import subprocess
import sys
import time
import logging

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] BatchRunner: %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("batch_run.log", mode="a", encoding="utf-8")
    ]
)
logger = logging.getLogger("BatchRunner")

# Predefined Waves of Tennessee Eastman Process variables
WAVES = {
    1: ["XMEAS(15)", "XMEAS(16)", "XMEAS(18)"],  # Wave 1: Stripper Refinery Unit (Dynamics)
    2: ["XMV(8)", "XMV(9)", "XMV(11)"],          # Wave 2: Control Valve Inversions (Feedback Loops)
    3: [                                           # Wave 3: Composition & Remaining (Diagnostics)
        "XMEAS(14)", "XMEAS(17)", "XMEAS(19)", 
        "XMEAS(21)", "XMEAS(22)"
    ]
}

def run_target(target: str, max_gen: int, target_rmse: float, dataset: str):
    import os
    cmd = [
        sys.executable, "src/orchestrator/main.py",
        "--target", target,
        "--max-gen", str(max_gen),
        "--target-rmse", str(target_rmse),
        "--dataset", dataset
    ]
    logger.info(f"Starting symbolic regression for target: {target}")
    logger.info(f"Command: {' '.join(cmd)}")
    
    # Configure env with current working directory in PYTHONPATH
    env = os.environ.copy()
    current_pythonpath = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = (os.getcwd() + os.pathsep + current_pythonpath) if current_pythonpath else os.getcwd()
    
    try:
        # Run subprocess and stream output with env configured
        result = subprocess.run(cmd, check=True, env=env)
        logger.info(f"Successfully completed evolution loop for target: {target}")
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Evolution loop failed for target {target} with exit code {e.returncode}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error running target {target}: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="TEP Multi-Wave Batch Executor for LLM-GP")
    parser.add_argument("--wave", type=int, choices=[1, 2, 3], default=1, help="The wave number to execute (1, 2, or 3)")
    parser.add_argument("--max-gen", type=int, default=20, help="Maximum number of generations per variable")
    parser.add_argument("--target-rmse", type=float, default=0.01, help="Target RMSE threshold to stop optimization early")
    parser.add_argument("--dataset", type=str, default="TEP_FaultFree_Training.RData", help="Path to TEP dataset")
    parser.add_argument("--cooldown", type=int, default=15, help="Cooldown time (seconds) between variables to prevent rate limiting")
    
    args = parser.parse_args()
    
    wave_vars = WAVES.get(args.wave)
    if not wave_vars:
        logger.error(f"Invalid wave number: {args.wave}")
        sys.exit(1)
        
    logger.info(f"============================================================")
    logger.info(f"Initializing TEP LLM-GP Batch Run - WAVE {args.wave}")
    logger.info(f"Target Variables in Wave {args.wave}: {wave_vars}")
    logger.info(f"Max Generations per target: {args.max_gen}")
    logger.info(f"Cooldown delay: {args.cooldown} seconds")
    logger.info(f"============================================================")
    
    results = {}
    for i, target in enumerate(wave_vars):
        if i > 0:
            logger.info(f"Sleeping for {args.cooldown} seconds to prevent API rate limiting...")
            time.sleep(args.cooldown)
            
        success = run_target(target, args.max_gen, args.target_rmse, args.dataset)
        results[target] = "SUCCESS" if success else "FAILED"
        
    logger.info(f"============================================================")
    logger.info(f"Batch execution completed for Wave {args.wave}!")
    for target, status in results.items():
        logger.info(f"  - {target}: {status}")
    logger.info(f"============================================================")

if __name__ == "__main__":
    main()
