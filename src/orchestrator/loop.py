# loop.py

import logging
from .history import HistoryManager, GenerationRecord
from .julia_runner import SubprocessWrapper
from src.llm_interface.facade import LLMFacade

logger = logging.getLogger(__name__)

import re


def _formula_sign_prefix(formula: str, coeff_index: int) -> int:
    """
    数式文字列中で c[i] の直前(空白を挟んでもよい)にある明示的な単項符号を検出する。
    "- c[2]*xmeas_10" のように c[i] の前に "-" が書かれている場合、
    フィットされた係数 c[2] 自体の符号と、xmeas_10 に実際にかかる正味の効果の符号は
    逆になる(c[2]が負なら正味は正)。この関数はその前置符号を +1/-1 として返す
    (符号が書かれていない、または"+"の場合は+1)。
    複雑な式(項の途中に係数が現れる等)には対応しない簡易的なヒューリスティックであり、
    "c[i]*variable" の形で係数が項の先頭に書かれる、このプロジェクトで一貫して観測される
    パターンを前提とする。
    """
    match = re.search(r'([+\-])?\s*c\[' + str(coeff_index) + r'\]', formula)
    if match and match.group(1) == '-':
        return -1
    return 1


def check_sign_consistency(formula: str, coefficients: list, expected_signs: list) -> str:
    """
    Method A(単一法則への収束)の検証: フィットされた係数が数式中で実際に持つ正味の符号
    (c[i]自体の符号 × 数式中でc[i]の直前にある明示的な単項符号)が、
    LLMがフィット前に理論から宣言した期待符号(expected_signs)と一致するかを確認する。
    アブレーションが検証できない「物理法則としての正当性」を直接チェックする、独立した検証。
    expected_signsが空(法則を宣言していない自由記号回帰)の場合はチェックをスキップする。
    """
    if not expected_signs:
        return ""
    if len(expected_signs) != len(coefficients):
        return (f"SIGN CHECK: skipped (expected_signs has {len(expected_signs)} entries "
                f"but formula has {len(coefficients)} coefficients - counts must match c[1], c[2], ...)")

    details = []
    all_match = True
    for i, (c, exp) in enumerate(zip(coefficients, expected_signs), start=1):
        prefix = _formula_sign_prefix(formula, i)
        net_c = c * prefix
        actual_sign = 1 if net_c > 0 else (-1 if net_c < 0 else 0)
        exp_str = "+" if exp > 0 else ("-" if exp < 0 else "0")
        if exp == 0:
            verdict = "unconstrained"
        elif actual_sign == exp:
            verdict = "OK"
        else:
            verdict = "MISMATCH"
            all_match = False
        prefix_note = " (formula has explicit '-' before this term, net effect shown)" if prefix == -1 else ""
        details.append(f"c[{i}]={c:.4f}, net effect on target={net_c:.4f}{prefix_note} (expected {exp_str}, {verdict})")

    if all_match:
        header = "SIGN CHECK PASSED"
    else:
        header = ("SIGN CHECK FAILED - the fitted coefficient contradicts the physical law's own theoretical "
                   "prediction. This means the declared law is likely wrong or confounded (e.g. by closed-loop "
                   "control), NOT that the term should be kept with a post-hoc reinterpreted sign. Do not just "
                   "relabel the mechanism to match the fitted sign - either investigate the confounding or "
                   "commit to a different law from the library")
    return f"{header}: " + "; ".join(details)


def contains_target_variable(formula: str, target_variable: str) -> bool:
    """
    数式がターゲット変数自身を(トークン境界で)入力として含んでいるかを検出する。
    プロンプト文中の「ターゲット自身を入力に使うな」という文言だけでは守られない実例
    (xmeas_13をターゲットとする探索で、LLMが繰り返しxmeas_13自身を式に含めた)が
    発生したため、機械的なハードチェックとして追加した。自己回帰項の使用は
    CLAUDE.mdのTEP動的モデリング指針でも明確に禁止されている。
    """
    pattern = r'\b' + re.escape(target_variable) + r'\b'
    return re.search(pattern, formula, re.IGNORECASE) is not None


def check_ideal_gas_magnitude(coefficient: float, mean_pressure: float, mean_temperature_c: float) -> str:
    """
    Method A検証の追加層(符号だけでなく"大きさ"の妥当性): エネルギー収支/理想気体の
    状態方程式($PV=nRT$, モル数一定)は、圧力の温度に対する感度について
    $$\\frac{\\partial P}{\\partial T}\\Big|_{n,V} = \\frac{nR}{V} = \\frac{P}{T}\\ (絶対温度)$$
    という理論値を独立に予言する。運転データの平均圧力・平均温度(絶対温度に変換)から
    この理論値を計算し、フィットされた係数のオーダー(桁)がこれと整合するかを確認する。

    注意: これは1分刻みの離散差分を瞬間偏微分の近似として扱う概算のオーダーチェックであり、
    「符号が合っているか」より一段厳しいが、依然として厳密な証明ではない。
    また、この関数はTEPの測定単位系(kPa, ℃)がteprob.f内部の単位系と直接比較可能という
    前提を置いていない — P/Tは実測データ自身から計算するため、外部の物理定数の単位変換に
    伴うリスクを回避している。質量収支・弁特性等、他の法則の大きさチェックは
    TEPの流量測定単位の確認が必要なため未実装(variable-modeling-methodology.md参照)。
    """
    T_kelvin = mean_temperature_c + 273.15
    theoretical = mean_pressure / T_kelvin
    if theoretical == 0:
        return "MAGNITUDE CHECK: skipped (theoretical P/T value is zero)"

    ratio = coefficient / theoretical
    if ratio <= 0:
        verdict = "MISMATCH (sign disagrees with the P/T-based magnitude basis)"
    elif 0.1 <= ratio <= 10:
        verdict = f"PLAUSIBLE (within 1 order of magnitude of theoretical P/T={theoretical:.4f})"
    else:
        verdict = f"IMPLAUSIBLE (more than 1 order of magnitude off from theoretical P/T={theoretical:.4f})"

    return f"MAGNITUDE CHECK: fitted={coefficient:.4f}, theoretical(P/T)={theoretical:.4f}, ratio={ratio:.2f} -> {verdict}"


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
        target_variable: str,
        mic_variables: list = None,
        predict_diff: bool = True,
        reactive_exclusions: dict = None
    ):
        self.llm = llm_facade
        self.runner = julia_runner
        self.history = history_manager
        self.max_generations = max_generations
        self.target_rmse = target_rmse
        self.dataset_path = dataset_path
        self.target_variable = target_variable
        self.mic_variables = mic_variables or []
        self.predict_diff = predict_diff
        self.reactive_exclusions = reactive_exclusions or {}

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
                    target_variable=self.target_variable,
                    mic_variables=self.mic_variables,
                    reactive_exclusions=self.reactive_exclusions
                )
                logger.info(f"Proposed Formula: {candidate.formula}")
                logger.info(f"LLM Feedback: {candidate.feedback}")
            except Exception as e:
                logger.error(f"Failed to generate candidate at generation {gen}: {e}")
                continue # 次の世代へ（または終了処理）

            # 1.5. ターゲット自身を入力に使っていないか(自己回帰)をJulia評価の前に機械的チェックする。
            # プロンプト文中の「ターゲット自身を使うな」という文言だけでは守られない実例が発生したため、
            # ハードなゲートとして追加した(Julia評価すら行わず、次世代へ強いフィードバックとともに進む)。
            if contains_target_variable(candidate.formula, self.target_variable):
                logger.warning(
                    f"REJECTED (self-reference): formula uses the target variable "
                    f"'{self.target_variable}' as an input. Autoregressive terms are forbidden."
                )
                record = GenerationRecord(
                    generation=gen,
                    formula=candidate.formula,
                    rmse=float('inf'),
                    penalty=float('inf'),
                    fitness=float('inf'),
                    feedback=(f"{candidate.feedback}\n[REJECTED: formula uses the target variable "
                              f"'{self.target_variable}' as an input - this is an autoregressive term "
                              f"and is strictly forbidden. Do not use the target variable anywhere in "
                              f"the formula, including inside nonlinear functions.]"),
                    sign_valid=False
                )
                self.history.add_record(record)
                continue

            # 2. Juliaで式を評価
            eval_result = self.runner.evaluate_formula(
                formula=candidate.formula,
                target_variable=self.target_variable,
                dataset_path=self.dataset_path,
                predict_diff=self.predict_diff
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
                skill_score = eval_result.get("skill_score")
                naive_mae = eval_result.get("naive_mae")
                skill_str = f", Skill: {skill_score:.4f}" if skill_score is not None else ""
                logger.info(f"Evaluation Success - RMSE: {rmse:.4f}, Fitness: {fitness:.4f}{skill_str}")

                sign_check = check_sign_consistency(candidate.formula, eval_result.get("coefficients", []), candidate.expected_signs)
                feedback = candidate.feedback
                sign_valid = "SIGN CHECK FAILED" not in sign_check
                if sign_check:
                    logger.info(sign_check)
                    feedback = f"{candidate.feedback}\n[{sign_check}]"

                # Skill Score(素朴予想=「変化なし」との比較): 2026-09-09発見。対象変数の
                # 変動が乏しいと素朴予想でも低いRMSEが出てしまい、GPループがそれに気づかず
                # 世代を進めてしまう罠があった(XMEAS16/18で実証済み)。フィードバックに
                # 明示し、LLMが「良いRMSEだが素朴予想と大差ない」候補を自ら見直せるようにする。
                if skill_score is not None:
                    if skill_score <= 0.05:
                        skill_note = (
                            f"[SKILL SCORE WARNING: {skill_score:.4f} (naive 'no-change' baseline MAE={naive_mae:.4f}, "
                            f"this formula's MAE={rmse:.4f}). A skill score near or below 0 means this formula is "
                            f"essentially NO BETTER than predicting zero change - it may look like a good fit only "
                            f"because this variable barely moves. This is NOT sufficient evidence of a real physical "
                            f"relationship, even if RMSE/fitness look good and the sign check passes.]"
                        )
                    else:
                        skill_note = f"[SKILL SCORE: {skill_score:.4f} (beats the naive 'no-change' baseline by this margin, naive MAE={naive_mae:.4f})]"
                    feedback = f"{feedback}\n{skill_note}"

                # 5. 独立した審判LLMによる説明文の整合性チェック。提案側とは別のLLM呼び出しで、
                # 数値の再計算はさせず、提案側のfeedback(説明文)が確定済みの証拠(Skill Score・
                # 符号チェック結果)と矛盾/過大主張していないかだけを判定させる(自作自演の
                # ストーリーテリング対策)。
                judge_verdict = "PASS"
                judge_reasoning = ""
                try:
                    judge_result = self.llm.judge_candidate(
                        formula=candidate.formula,
                        law=candidate.law or "(none declared)",
                        sign_check_result=sign_check or "(no expected signs declared, sign check skipped)",
                        skill_score=f"{skill_score:.4f}" if skill_score is not None else "N/A",
                        naive_mae=f"{naive_mae:.4f}" if naive_mae is not None else "N/A",
                        proposer_feedback=candidate.feedback,
                        reactive_exclusions=self.reactive_exclusions
                    )
                    judge_verdict = judge_result.verdict
                    judge_reasoning = judge_result.reasoning
                    if judge_verdict == "FLAG":
                        logger.warning(f"JUDGE FLAGGED: {judge_reasoning}")
                        feedback = f"{feedback}\n[JUDGE FLAG: {judge_reasoning}]"
                    else:
                        logger.info(f"Judge: PASS - {judge_reasoning}")
                except Exception as e:
                    logger.warning(f"Judge call failed, treating as neutral PASS for this generation: {e}")

                record = GenerationRecord(
                    generation=gen,
                    formula=candidate.formula,
                    rmse=rmse,
                    penalty=penalty,
                    fitness=fitness,
                    feedback=feedback,
                    sign_valid=sign_valid,
                    judge_verdict=judge_verdict,
                    judge_reasoning=judge_reasoning
                )

            # 3. 履歴に記録
            self.history.add_record(record)
            
            # 4. 早期終了判定
            if record.rmse <= self.target_rmse:
                logger.info(f"Target RMSE ({self.target_rmse}) achieved at generation {gen}!")
                break
                
        logger.info("Evolutionary Loop finished.")
