# Requirements Document

## Project Description (Input)
LLMが生成した数式候補がデータにどの程度適合しているかを評価するためには、数式内の未知係数を最適化し、実測値との誤差（RMSE等）を高速に計算する機能が必要。LLMから文字列として渡された数式に対して、未知の係数を差分進化法（DE）で最適化し、RMSEとペナルティ（複雑さや物理制約）を考慮した適応度スコアを返すJuliaプログラムが実装されていること。

## Boundary Context
- **In scope**: 文字列として与えられた数式のパース・動的評価。差分進化法を用いた未知係数の最適化。データセット（tep-data-loader経由）を用いたRMSEの計算と、複雑さ等を考慮したペナルティの適用。
- **Out of scope**: データのダウンロード処理、LLMへのプロンプト生成や通信、数式そのものの生成や変異操作。
- **Adjacent expectations**: tep-data-loaderが正常にDataFrame形式のデータを提供すること。evolution-orchestratorが最適化対象の数式を正しいフォーマットで提供し、評価結果を受け取れること。

## Requirements

### Requirement 1: 数式の動的パースと評価
**Objective:** As a numerical evaluator, I want to parse string-based mathematical formulas provided by the LLM, so that they can be evaluated dynamically during the optimization process.

#### Acceptance Criteria
1. When [数式を表す文字列（例: `a * XMEAS(1) + b`）と独立変数のデータが与えられた場合], the [evaluator] shall [その文字列をJuliaの式としてパースし、計算可能な関数に変換する].
2. If [与えられた文字列がJuliaの構文として無効、またはサポートされていない演算子が含まれている場合], the [evaluator] shall [パースエラーをスローし、評価を中断する].

### Requirement 2: 未知係数の最適化（差分進化法）
**Objective:** As a numerical evaluator, I want to optimize the unknown coefficients (e.g., a, b, c) in the parsed formula using Differential Evolution, so that the formula best fits the provided TEP dataset.

#### Acceptance Criteria
1. When [パースされた数式、TEPデータセット、および係数の探索範囲が与えられた場合], the [evaluator] shall [差分進化法（DE）アルゴリズムを実行し、未知係数の最適値を探索する].
2. The [evaluator] shall [DEのハイパーパラメータ（世代数、個体群サイズなど）を外部から設定可能にする].

### Requirement 3: 適応度（Fitness）の計算
**Objective:** As a numerical evaluator, I want to calculate a comprehensive fitness score for a formula, so that the evolutionary orchestrator can compare candidates.

#### Acceptance Criteria
1. When [最適化された係数を持つ数式と実測値データが与えられた場合], the [evaluator] shall [予測値と実測値間のRMSE（二乗平均平方根誤差）を計算する].
2. When [数式の適応度を最終評価する場合], the [evaluator] shall [式の複雑さ（ノード数など）に対するペナルティスコアをRMSEに加算した総合的なFitnessスコアを計算する].
3. If [数式が指定された物理制約（例: 圧力が負になる等）に著しく違反する場合], the [evaluator] shall [ペナルティを加算する].

### Requirement 4: 外部インターフェースの提供
**Objective:** As a numerical evaluator, I want to receive inputs and return structured evaluation results (e.g., JSON), so that the external orchestrator (Python) can easily invoke and process the evaluation.

#### Acceptance Criteria
1. When [外部プロセス（オーケストレーター）からCLI引数または入力ファイル経由で評価リクエスト（数式文字列、データパスなど）を受け取った場合], the [evaluator] shall [評価プロセスを開始する].
2. When [評価が正常に完了した場合], the [evaluator] shall [RMSE、最適化された係数、Fitnessスコアを含む結果をJSON形式で標準出力または指定ファイルに出力する].
3. If [評価中にエラー（パースエラー、計算発散など）が発生した場合], the [evaluator] shall [エラー内容と失敗ステータスをJSON形式で出力し、非ゼロの終了コードを返す].
