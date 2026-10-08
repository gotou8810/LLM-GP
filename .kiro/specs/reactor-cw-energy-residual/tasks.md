# Implementation Plan

> すべてのCoreタスクは`src/PhysicsResiduals/ReactorCwEnergyResidual.jl`という単一ファイルを編集する（design.mdのSimplification判断）。そのため、コンポーネント間に論理的な独立性があっても、ファイル競合を避けるため`(P)`マーカーは付与しない（並列タスク判定基準「No conflicting files or shared mutable resources」に抵触するため）。

- [ ] 1. Foundation: モジュール構成とデータ仕様・投入時刻・残差式の基盤整備
- [x] 1.1 Juliaモジュールの骨格とデータ仕様ドキュメントのセットアップ
  - `src/PhysicsResiduals/PhysicsResiduals.jl`（薄い集約モジュール、`NumericalEvaluator.jl`と同型のinclude構成）を作成する
  - `src/PhysicsResiduals/ReactorCwEnergyResidual.jl`の空ファイルを作成し、集約モジュールからincludeする
  - `test/PhysicsResiduals/runtests.jl`に空の`@testset`スケルトンを作成する
  - `docs/dataset_spec.md`に、研究で確定したデータ仕様（Rieth et al. 2017版、3分間隔、500ラン×500サンプル、故障投入サンプル21とその実測根拠）を記載する
  - 完了の確認: `julia --project=. -e 'include("src/PhysicsResiduals/PhysicsResiduals.jl")'`がエラーなく完了する
  - _Requirements: 8.1_

- [x] 1.2 故障投入時刻とラン境界ユーティリティの実装（FaultTiming）
  - `FAULT_INJECTION_SAMPLE = 21`定数を定義する
  - `verify_injection_timing`関数を実装する（対象3 IDVについて、サンプル20以前に正常データ分布からの有意な逸脱がないことを統計的に確認する）
  - `respects_run_boundary`関数を実装する（`simulationRun`をまたいだデータ参照を防ぐ分割ユーティリティ）
  - 完了の確認: 実際の異常データ（IDV4/11/14）に対し`verify_injection_timing`を実行すると`true`が返る
  - _Requirements: 8.1, 8.2, 8.3_
  - _Boundary: FaultTiming_

- [x] 1.3 残差式と$\lambda$制約の定義（ResidualFormula）
  - `build_design_matrix`関数を実装する（$y=T_r-T_{cw,out}$、$x_1=u_{10}T_{cw,out}$、$x_2=u_{10}$を構築）
  - `LAMBDA_SIGN_CONSTRAINTS`定数（$a>0$, $b<0$の期待符号）を定義する
  - `assess_quasi_steady_adequacy`関数を実装する（正常データ残差の系統的な未説明構造の有無を判定し、不十分な場合に$T_{cw,out}$の変化率項を追加するロジックを含む）
  - $k$/$UA$が比としてのみ同定可能であることをコードコメントとレポート文言に明記する
  - 完了の確認: 実データに対し`build_design_matrix`を呼ぶと、同じ長さの3ベクトル（$y, x_1, x_2$）が返る
  - _Requirements: 1.1, 1.2, 1.5, 1.6_
  - _Boundary: ResidualFormula_

- [ ] 2. Core: $\lambda$の同定と不確かさ検証
- [ ] 2.1 正常データの分割と$\lambda$同定（LambdaIdentifier）
  - `split_normal_data`関数（`simulationRun`基準、`fit_run_max=400`で重複なく分割）を実装する
  - `identify_lambda`関数（厳密OLSで$a,b$を同定し$T_{cw,in}$を導出）を実装する。入力の型シグネチャが異常データを受け取れないようにする
  - `check_physical_plausibility`関数（符号制約チェックと、$T_{cw,in}<T_{cw,out}$かつ妥当範囲内かのチェック）を実装する
  - 完了の確認: 既知の$a,b$から生成した合成データに対し`identify_lambda`を実行すると、数値許容誤差内で元の$a,b$が復元される
  - _Requirements: 2.1, 2.2, 2.3, 1.3, 1.4_
  - _Boundary: LambdaIdentifier_
  - _Depends: 1.3_

- [ ] 2.2 $\lambda$の不確かさとホールドアウト安定性の検証（LambdaValidator）
  - `bootstrap_lambda_uncertainty`関数（ラン単位リサンプリングで信頼区間を算出、時系列相関を壊さない）を実装する
  - `check_holdout_stability`関数（保留部分集合での再同定が信頼区間内に収まるかを判定）を実装する
  - 完了の確認: 実際の正常データに対し`bootstrap_lambda_uncertainty`を実行すると、$a,b,T_{cw,in}$それぞれの信頼区間が返る
  - _Requirements: 3.1, 3.2, 3.3_
  - _Boundary: LambdaValidator_
  - _Depends: 2.1_

- [ ] 3. Core: 2経路の異常検知
- [ ] 3.1 平均シフト型検知の実装（MeanShiftDetector、IDV4）
  - `calibrate_threshold`関数（正常保留データのみからFIT残差最大×1.25でしきい値を決定）を実装する
  - `detect_mean_shift`関数（残差系列の継続算出と検知フラグ）を実装する
  - `evaluate_fault_detection`関数（IDVごとのFDR・ADD・FAR算出、`FaultTiming.FAULT_INJECTION_SAMPLE`を基準とした検知遅れ計測）を実装する
  - 完了の確認: 実際の異常データ（IDV4）に対し`evaluate_fault_detection`を実行すると、FDR・ADD・FAR付きの検知指標が返る
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_
  - _Boundary: MeanShiftDetector_
  - _Depends: 2.2, 1.2_

- [ ] 3.2 分散変化型検知の実装（VarianceShiftDetector、IDV11/14）
  - `calibrate_variance_threshold`関数（窓内標準偏差の正常保留データからのしきい値算出）を実装する
  - `detect_variance_shift`関数を実装する
  - `evaluate_fault_detection`関数（平均ベースとは独立した検知指標を返す）を実装する
  - 完了の確認: 実際の異常データ（IDV11, IDV14）に対し`evaluate_fault_detection`を実行すると、平均シフト経路とは別の検知指標が返る
  - _Requirements: 5.1, 5.2, 5.3, 5.4_
  - _Boundary: VarianceShiftDetector_
  - _Depends: 2.2, 1.2_

- [ ] 4. Core: 診断・比較実験・誠実さの確認
- [ ] 4.1 診断用$\lambda$再推定の実装（LambdaDiagnostics）
  - `diagnose_sliding_window`関数（直近データから$\lambda$を再同定し、凍結$\lambda$との差分を報告。凍結$\lambda$は変更しない）を実装する
  - 完了の確認: 既知の$\lambda$ドリフトを持つ合成データに対し`diagnose_sliding_window`を実行すると、各$\lambda$要素の変化方向・大きさが正しく返り、入力の凍結$\lambda$は変更されない
  - _Requirements: 6.1, 6.2, 6.3_
  - _Boundary: LambdaDiagnostics_
  - _Depends: 1.3_

- [ ] 4.2 操作量ablationと持続性ベースラインの実装（ComparisonExperiments）
  - `evaluate_pv_only_variant`関数（$u_{10}$を正常データ平均値に固定した比較用残差で、同じ$\lambda$同定・検知パイプラインを実行）を実装する
  - `evaluate_persistence_baseline`関数（$y(t-1)$を予測値とするMAE算出）を実装する
  - 完了の確認: IDV4/11/14の異常データに対し`evaluate_pv_only_variant`を実行すると、主要モデルと同じ形式の検知指標が返り、直接比較できる
  - _Requirements: 7.1, 7.2, 7.3_
  - _Boundary: ComparisonExperiments_
  - _Depends: 2.1, 1.2_

- [ ] 4.3 マスキング確認の実装（MaskingChecker）
  - `check_masking_risk`関数（対象外17 IDVそれぞれについてXMV(10)の平均シフトz値と分散比を算出し、|z|>3または分散比>2倍で`flagged=true`とする）を実装する
  - 完了の確認: 実際の異常データ全体に対し`check_masking_risk`を実行すると、17件の所見が返る
  - _Requirements: 9.2_
  - _Boundary: MaskingChecker_
  - _Depends: 1.2_

- [ ] 5. Integration: 評価パイプラインの統合
- [ ] 5.1 評価パイプラインの統合とレポート生成（EvaluationReport）
  - `evaluate_reactor_cw_residual`関数（全コンポーネントをオーケストレーションするトップレベル関数）を実装する：投入時刻サニティチェック→$\lambda$同定→検証（不安定ならここで停止し無効として報告）→2経路の検知→ablation/ベースライン比較→マスキング確認→レポート統合、の順で呼び出す
  - `limitations`フィールド（性能基準未達の対象故障を明記）と`claims`フィールド（IDV4/11/14以外への検知能力を主張しない固定文言）を実装する
  - JSON出力機能（`VerificationHarness.jl`と同じ規約）を実装する
  - 完了の確認: 正常データ・異常データのパスを渡して`evaluate_reactor_cw_residual`を実行すると、design.mdのData Contracts & Integrationで定義したキー構造を持つJSONファイルが生成される
  - _Requirements: 9.1, 9.3_
  - _Boundary: EvaluationReport_
  - _Depends: 2.1, 2.2, 3.1, 3.2, 4.1, 4.2, 4.3_

- [ ] 6. Validation: テストと回帰確認
- [ ] 6.1 単体テストの実装
  - 合成データでの`build_design_matrix`の正しさ、`identify_lambda`による既知$\lambda$の復元、符号反転時の`check_physical_plausibility`（`valid=false`を返すこと）、`respects_run_boundary`のラン境界非超過を検証するテストを実装する
  - 完了の確認: `julia --project=. test/PhysicsResiduals/runtests.jl`の単体テスト`@testset`が全件成功する
  - _Requirements: 1.1, 2.1, 1.3, 1.4, 8.3_
  - _Depends: 2.1, 1.3, 1.2_

- [ ] 6.2 統合テストの実装（実データでの$\lambda$同定・検証）
  - 実際の正常データ（run≤400）で`identify_lambda`を実行し$a>0$・$b<0$・$T_{cw,in}$が妥当範囲であることを確認するテストを実装する
  - `check_holdout_stability`を実データのholdout分割（run>400）で実行し、結果が再現可能であることを確認するテストを実装する
  - `verify_injection_timing`を実際の異常データ（IDV4/11/14）に対して実行し`true`が返ることを確認するテストを実装する
  - 完了の確認: 上記3件のテストが`@testset`内で全件成功する
  - _Requirements: 2.1, 2.2, 2.3, 1.3, 1.4, 3.2, 3.3, 8.1_
  - _Depends: 6.1_

- [ ] 6.3 統合テストの実装（故障投入時刻バグの回帰確認）
  - 既存`VerificationHarness.jl`の投入時刻検出ロジック（`findfirst(v->v>0, fault_col)`が常にサンプル1を返す）を用いた場合のADDと、本specの`FAULT_INJECTION_SAMPLE=21`を用いた場合のADDを同一の異常データで比較するテストを実装する
  - 完了の確認: 両者のADDの差分が期待通り20サンプルであることをアサートするテストがパスする
  - _Requirements: 8.2_
  - _Depends: 6.2_

- [ ] 6.4 E2Eテストの実装
  - 正常・異常データ全体に対し`evaluate_reactor_cw_residual`をエンドツーエンドで実行し、IDV4/11/14のFDR/ADD/FAR出力、PV-onlyablationと持続性ベースラインの並記出力を確認するテストを実装する
  - `masking_findings`が17件出力され、`claims`フィールドに固定文言が含まれることを確認するテストを実装する
  - 完了の確認: E2Eテスト`@testset`が全件成功し、出力JSONファイルが指定パスに生成されていることを確認できる
  - _Requirements: 4.4, 5.4, 7.2, 7.3, 9.1, 9.2, 9.3_
  - _Depends: 5.1, 6.3_
