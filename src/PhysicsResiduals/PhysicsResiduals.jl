module PhysicsResiduals

# ============================================================================
# 反応器冷却水エネルギー収支残差(reactor-cw-energy-residual spec)の薄い集約モジュール。
#
# `NumericalEvaluator.jl`と同型のinclude専用モジュール: 本specに固有の実装は
# すべて`ReactorCwEnergyResidual.jl`に置き、ここでは読み込みとexportのみを行う。
#
# 設計根拠: design.md「Design Decisions」の
# 「ファイル構成は単一ファイル+薄い集約モジュールに留める」を参照。
# Phase 1の既存資産(`VerificationHarness.jl`, `NumericalEvaluator/*`, `TEPDataLoader.jl`)
# は変更しない(読み取り専用の参照のみ)。
# ============================================================================

include("ReactorCwEnergyResidual.jl")

# タスク1.2(FaultTiming)で実装した公開名をexportする。
# 他のコンポーネント(LambdaIdentifier等、タスク1.3以降)もこれらを利用するため、
# 本specの外部公開インターフェースとしてここに明記する(design.md Dependencies参照)。
export FAULT_INJECTION_SAMPLE, verify_injection_timing, respects_run_boundary

# タスク1.3(ResidualFormula)で実装した公開名をexportする。
# LambdaIdentifier(タスク2.1)がbuild_design_matrixを使って設計行列を得る
# (design.md ResidualFormula「Implementation Notes」Integration参照)。
export ResidualFeatures, LAMBDA_SIGN_CONSTRAINTS, LAMBDA_NON_IDENTIFIABILITY_NOTE,
       build_design_matrix, ResidualFeaturesDynamic, build_design_matrix_with_dynamic_term,
       assess_quasi_steady_adequacy

# タスク2.1(LambdaIdentifier)で実装した公開名をexportする。
# NormalFitSplitは、split_normal_dataだけが正規にfit部分集合を生成し、identify_lambdaは
# この型のみを受理することで、異常データを直接渡せないようにする型安全性の要となる
# (design.md LambdaIdentifier「Responsibilities & Constraints」、本ファイルの
# NormalFitSplit/identify_lambdaのドキュメント参照)。
export NormalFitSplit, ReactorCwLambda, PLAUSIBLE_TCW_IN_RANGE,
       split_normal_data, identify_lambda, check_physical_plausibility

# タスク2.2(LambdaValidator)で実装した公開名をexportする。
# bootstrap_lambda_uncertaintyはidentify_lambdaをラン単位の復元抽出標本に繰り返し適用し、
# check_holdout_stabilityはholdoutでの再同定結果がその信頼区間内かを判定する
# (design.md LambdaValidator「Service Interface」参照)。
export LambdaUncertainty, bootstrap_lambda_uncertainty, check_holdout_stability

# タスク3.1(MeanShiftDetector)で実装した公開名をexportする。
# calibrate_thresholdは正常検証データ(holdout)のみからしきい値を決定し(Requirement 4.3)、
# detect_mean_shiftは凍結lambdaのもとで残差がしきい値を超えた行をフラグし(Requirement 4.1-4.2)、
# evaluate_fault_detectionはFaultTiming.FAULT_INJECTION_SAMPLEを基準としたFDR・ADDと
# FARをDetectionMetricsとして報告する(design.md MeanShiftDetector「Service Interface」参照)。
export DetectionMetrics, calibrate_threshold, detect_mean_shift, evaluate_fault_detection

end # module
