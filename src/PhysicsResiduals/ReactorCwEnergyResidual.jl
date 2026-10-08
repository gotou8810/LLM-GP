# ============================================================================
# 反応器冷却水エネルギー収支残差 (reactor-cw-energy-residual spec)
#
# 本ファイルは、design.md「Components and Interfaces」で定義された以下10コンポーネントを
# 関数群として実装する予定地点(本タスク1.1では骨格のみで、ロジックは未実装):
#   - ResidualFormula        : 残差式 r = k*u10*(Tr-Tcwout) - UA*(Tr-Tcwout) の定義
#   - FaultTiming            : 故障投入時刻(サンプル21, 定数)とサニティチェック
#   - LambdaIdentifier       : 正常データ(fit部分集合)のみでの未知パラメータlambda同定
#   - LambdaValidator        : holdout部分集合での不確かさ・安定性・符号検証
#   - MeanShiftDetector      : 平均シフト型故障(IDV4)向けの検知経路
#   - VarianceShiftDetector  : 分散変化型故障(IDV11, IDV14)向けの検知経路
#   - LambdaDiagnostics      : 検知後のスライディング窓によるlambda再推定(凍結値は上書きしない)
#   - ComparisonExperiments  : 操作量ablationおよび持続性ベースラインとの比較実験
#   - MaskingChecker         : 対象外故障による操作量マスキングの確認
#   - EvaluationReport       : 上記すべてを統合したJSON形式のレポート出力
#
# 実装はタスク1.2以降で段階的に追加する。
# ============================================================================
