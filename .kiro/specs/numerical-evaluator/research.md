# Research & Design Decisions

## Summary
- **Feature**: `numerical-evaluator`
- **Discovery Scope**: Light Discovery
- **Key Findings**:
  - Juliaにおける数式の動的評価（文字列からASTへのパースと実行）は `Meta.parse` および `eval` を用いるのが一般的。た だし、スコープの分離やセキュリティの観点からサンドボックス化するか、あるいは事前にサポートする演算子を制限するアプロー チが必要。
  - 最適化エンジンとして `DifferentialEvolution.jl` または `BlackBoxOptim.jl` が候補となる。`BlackBoxOptim.jl` はDE以 外のアルゴリズムもサポートしメンテが活発な場合があるため、汎用的な最適化バックエンドとして検討の余地がある。
  - Python（オーケストレーター）からの呼び出しは、CLIから引数（JSON文字列）を渡すか、テンポラリファイルを介してパラメ ータを渡し、標準出力をJSONで受け取るのが最も安定する。

## Architecture Pattern Evaluation
| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| CLIラッパー (JSON I/O) | JuliaスクリプトがJSONファイルを入力とし、結果をJSON形式で標準出力する。 | 言語間の連携が最も シンプル。依存パッケージの追加が最小限。 | Juliaのプロセス起動ごとのJITコンパイル（TTFP）オーバーヘッド。 | 本システム では1つの式評価ごとにプロセスを再起動すると非常に遅くなるため、バッチ処理またはDaemonモードの検討が必要だが、まずはバッ チ評価用のCLIを設計する。 |

## Design Decisions

### Decision: 数式パースのスコープ制限
- **Context**: LLMが生成した任意の文字列を `eval` することの危険性。
- **Selected Approach**: `Meta.parse` によってExprを生成した後、ホワイトリスト化された関数群（`+`, `-`, `*`, `/`, `sin`, `exp` 等）のみを含んだ専用モジュール内で評価する。
- **Rationale**: セキュリティ上のリスクを最小化し、不要なシステムコールの実行を防ぐため。

### Decision: 差分進化法ライブラリの選定
- **Context**: 安定した係数最適化バックエンドの必要性。
- **Selected Approach**: `BlackBoxOptim.jl` をバックエンドとして利用し、内部の探索アルゴリズムにDEを指定する。
- **Rationale**: `DifferentialEvolution.jl` よりもドキュメントやコミュニティのサポートが手厚く、後の拡張（他アルゴリズムの利用）が容易なため。
