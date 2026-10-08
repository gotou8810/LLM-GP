# Research & Design Decisions

## Summary
- **Feature**: `reactor-cw-energy-residual`
- **Discovery Scope**: Extension（既存の`src/VerificationHarness.jl`・`src/NumericalEvaluator/linear_fit.jl`・`src/TEPDataLoader.jl`を土台とする軽量Discovery）
- **Key Findings**:
  - `VerificationHarness.jl`は目的変数を$\Delta y(t)=y(t)-y(t-1)$として扱う差分予測専用の設計であり、本specの残差（$T_r-T_{cw,out}$という同時刻の代数式）はこの枠組みに直接は乗らない。流用ではなく、同じ思想（ラン境界尊重・MASE・JSON出力）を踏襲した新規モジュールが必要
  - `VerificationHarness.jl`の`evaluate_fdi`内の`findfirst(v -> v > 0, fault_col)`は、要件8で修正対象とした「故障投入時刻バグ」そのものである。`fault_col`はラン全体に付与された定数ラベルのため、常に先頭行（インデックス1）を返してしまう。これは既存ハーネスにも存在する未修正の問題であり、本spec側では正しい投入時刻（サンプル21）を使うが、`VerificationHarness.jl`自体は本specの対象外として変更しない
  - `linear_fit.jl`の`try_linear_ols_fit`は、LLMが生成した任意の数式文字列に対して線形性を数値的に検証してからOLSを行う汎用関数であり、インターフェース（`eval_func(coeffs, row)`形式、DataFrame行単位アクセス）が本specの既知線形な残差には過剰。関数自体は流用せず、末尾の「厳密OLS（`G \ (y .- h)`）」という実績ある数値解法パターンのみを踏襲する

## Research Log

### 既存Julia資産の残差式への適用可能性
- **Context**: brief.mdのApproach Decisionで「既存の`linear_fit.jl`をそのまま再利用できる」としていたが、設計に入る前に実際のシグネチャを確認する必要があった
- **Sources Consulted**: `src/NumericalEvaluator/linear_fit.jl`、`src/VerificationHarness.jl`（全文）
- **Findings**:
  - `VerificationHarness.fit_ols`は`all_dy = y[t] - y[t-1]`を固定的に計算し、予測を`y[t-1] + dp`として再構成する。本specの残差は$y = T_r(t) - T_{cw,out}(t)$という同時刻の代数関係で、時間差分ではない
  - `VerificationHarness.evaluate_fdi`の投入時刻検出バグを確認（上記Key Findings参照）
  - `linear_fit.jl`の線形性数値検証（重ね合わせの原理を3回のランダム係数ベクトルで確認）は、文字列からパースされた任意の式を対象とするGPループ特有の処理であり、本specのように式の線形性が物理的導出から自明な場合は不要なオーバーヘッド
- **Implications**: 新規モジュール`src/PhysicsResiduals/`を作成する。ただし車輪の再発明を避けるため、以下は明示的に流用する：
  - `TEPDataLoader.load_rdata`（データロード、変更なし）
  - ラン境界を尊重したfit/holdout分割、MASE（分母をFITで固定）、JSON出力という`VerificationHarness.jl`の設計思想・命名規約
  - 厳密OLS（`A \ b`）という数値解法そのもの

### 故障投入時刻の確定方法
- **Context**: 要件8は「ラベル列ではなく実際の投入時刻を特定して使う」ことを求めているが、具体的にどう特定するかを設計する必要がある
- **Sources Consulted**: brief.md（Discovery時点でIDV(1)/(4)/(6)を対象に実測確認済み：サンプル21で急変、サンプル20まで完全に正常）
- **Findings**: Rieth et al. 2017データセットは、どのIDV・どのランでも故障投入が固定時刻（サンプル21）に起きる設計になっている（シミュレーション開始から1時間後に投入、3分間隔なので20サンプル後）
- **Implications**: 実行時に動的検出する必要はなく、**サンプル21を定数として定義**すればよい。ただし誤りに気づかず使い続けるリスクを避けるため、実装時に対象3 IDVについて「サンプル20以前に正常からの統計的逸脱がない」ことを検証するサニティチェックを含める

### 残差「第2の統計量」（分散変化型故障）の設計
- **Context**: 要件5は分散変化型故障（IDV11/14）検知に第2の統計量を必須としたが、具体的な統計量の形は未決定
- **Sources Consulted**: brief.md（IDV11: ラン内標準偏差比6.5倍、IDV14: 13.8倍という実測値）
- **Findings**: 最も単純で解釈しやすいのは、残差系列に対する移動（窓内）標準偏差。窓長は固定値を設計時点で断定せず、実装時にデータで検証可能なパラメータとして持たせる
- **Implications**: 検知経路を2つ（平均残差の大きさに基づく経路、窓内標準偏差に基づく経路）明確に分離して設計する。両者はそれぞれ独立にしきい値を持ち、どちらかが発火すれば検知とする

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| `VerificationHarness.jl`を拡張（Δy以外の目的変数形式をオプション対応） | 既存モジュールに分岐ロジックを追加 | 単一モジュールに機能が集約される | Δy専用の設計（`y[t-1]+dp`再構成等）に分岐を混ぜると可読性が落ちる。Phase 1の既存利用箇所（XMEAS7等）への影響範囲確認が必要になり、Phase 1の「完了・履歴」という位置づけと衝突する | 却下 |
| 新規モジュール`src/PhysicsResiduals/`を作成（**採用**） | 代数的残差専用の新規モジュール。データロード・数値解法は既存資産を関数単位で再利用 | Phase 1コードに触れないため、既存の確定済み結果（XMEAS7等）への影響ゼロ。残差というPhase 2固有の概念に特化した設計にできる | 新規モジュールゆえ、将来`fdi-evaluation-foundation`等と重複する可能性があるコードが出うる | 採用。重複が実際に顕在化した時点（2本目の残差specで）で共通化を検討する（Simplificationの原則：今ないものを先回りして作らない） |

## Design Decisions

### Decision: 新規モジュールとして実装し、`VerificationHarness.jl`は変更しない
- **Context**: 残差の目的変数形式（代数式）が既存ハーネスの前提（差分予測）と根本的に異なる
- **Alternatives Considered**:
  1. `VerificationHarness.jl`に目的変数形式のオプションを追加
  2. 新規モジュールを作成
- **Selected Approach**: 新規モジュール`src/PhysicsResiduals/`を作成
- **Rationale**: Phase 1の成果物（`VerificationHarness.jl`とその既存呼び出し元）を変更しないことで、roadmap.mdが「完了・履歴として保全」と位置づけたPhase 1の結果に影響を与えない。設計原則のBoundary Firstにも合致する
- **Trade-offs**: 一部のロジック（fit/holdout分割、MASE計算）が将来的に重複する可能性があるが、現時点で抽象化を先取りするとSimplification原則に反する
- **Follow-up**: `condenser-cw-energy-residual`（2本目の同型残差spec）に着手する際、共通化すべき部分が実際に見えてから抽出する

### Decision: ファイル構成は単一ファイル+薄い集約モジュールに留める
- **Context**: roadmap.mdのDiscovery時点の素案では`residuals.jl`/`lambda_identification.jl`/`diagnostics.jl`の3分割を想定していた
- **Alternatives Considered**:
  1. 素案通り3ファイルに機能分割
  2. 本spec固有のロジックを1ファイルに集約し、集約モジュールのみ分離
- **Selected Approach**: `src/PhysicsResiduals/PhysicsResiduals.jl`（薄い集約モジュール、`NumericalEvaluator.jl`と同じパターン）+ `src/PhysicsResiduals/ReactorCwEnergyResidual.jl`（本spec固有ロジック全体）の2ファイル
- **Rationale**: 現時点で実装が必要な機能はすべて本spec1本分であり、3分割は「将来複数の残差specが現れたときのための先回りの抽象化」に該当する。Simplification原則（「ただ1つの実装しかない抽象化層は不要」）に従い、2本目の残差specが実際に着手されるタイミングで、共通部分を見ながら分割し直す
- **Trade-offs**: ファイルが大きくなる可能性があるが、単一責務（反応器冷却水残差）の範囲内であり許容する
- **Follow-up**: ファイルが500行を超える場合は、2本目のspec着手前でも分割を検討する

### Decision: 故障投入時刻は実行時検出ではなく定数として定義する
- **Context**: 要件8は正しい投入時刻の使用を求めている
- **Alternatives Considered**:
  1. 各ランごとに統計的に投入点を検出するロジックを実装
  2. Discoveryで確定した定数（サンプル21）を使う
- **Selected Approach**: 定数として定義し、対象3 IDVについて「サンプル20以前に逸脱がない」ことを確認するサニティチェックを添える
- **Rationale**: Rieth 2017データセットは全ラン・全IDVで投入時刻が固定であることがDiscoveryで実測確認済み。動的検出は不要な複雑性を持ち込む（Simplification原則）
- **Trade-offs**: 万一データセットの前提が変わった場合に気づきにくくなるリスクがあるため、サニティチェックで軽量に担保する
- **Follow-up**: なし

### Decision: 持続性ベースラインは「$T_r-T_{cw,out}$の1サンプル前の値」をそのまま予測値とする
- **Context**: 要件7.3は持続性ベースラインとの比較を求めているが、本specの目的変数は差分ではなく代数式であり、Phase 1の「変化なし予測」をそのまま適用できない
- **Alternatives Considered**:
  1. 残差=0（物理モデルを一切使わない）を素朴予測とする
  2. $y(t-1)$（導出した目的変数自身の1サンプル前の値）を素朴予測とする
- **Selected Approach**: 2を採用。$\hat y_{naive}(t) = y(t-1)$、ただし$y = T_r - T_{cw,out}$
- **Rationale**: Phase 1で確立したpersistence-forecastの思想（「直前の値をそのまま使う」）を、導出した目的変数に対してそのまま適用する形であり、プロジェクト全体の比較方法論との一貫性を保てる
- **Trade-offs**: なし（既存の方法論をそのまま踏襲）
- **Follow-up**: なし

## Risks & Mitigations
- 分散型統計量（第2の統計量）の窓長が不適切だと、IDV11/14のどちらか一方しか検知できない可能性がある — 実装時に両IDVのラン内分散変化のタイムスケールを確認してから窓長を決定する
- $T_{cw,in}$の物理的妥当範囲（具体的な温度閾値）が未定義 — 設計で範囲チェックの構造は定義するが、具体的な数値範囲は実装時に`reference/teprob.f`を参照せず、工業用冷却水の一般的な知識（例: 0〜60°C程度）から独立に設定し、データとの整合性のみ確認する
- 新規モジュールと`fdi-evaluation-foundation`の将来的な統合時に、インターフェースの不整合が出る可能性 — Revalidation Triggersとして明記し、統合spec側で吸収する

## References
- `.kiro/specs/reactor-cw-energy-residual/brief.md` — Discoveryで確定した物理式・$\lambda$同定可能性分析・実測証拠
- `.kiro/steering/roadmap.md` Phase 2 — データ仕様（3分間隔、投入サンプル21）、XMV必要性の実測証拠
- `src/VerificationHarness.jl`、`src/NumericalEvaluator/linear_fit.jl`、`src/TEPDataLoader.jl` — 流用・非流用を判断した既存資産
