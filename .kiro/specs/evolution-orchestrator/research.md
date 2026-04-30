# Research & Design Decisions

## Summary
- **Feature**: `evolution-orchestrator`
- **Discovery Scope**: Integration-focused discovery
- **Key Findings**:
  - `llm-interface`はPythonモジュール（Facadeパターン）として提供されており、直接インポートして利用可能。
  - `numerical-evaluator`はJuliaのCLIスクリプトであり、JSONベースの標準入出力を用いてPythonの `subprocess` モジュール経由で呼び出すのが最適。
  - `tep-data-loader`の初期化（データダウンロード）も、Juliaのスクリプトを呼び出す形で実行する。

## Architecture Pattern Evaluation
| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| Pythonメインコントローラ | Pythonスクリプトがループを回し、LLMモジュールをインポート、Juliaをサブプロセスとして呼ぶ | `llm-interface`との統合がシームレス。サブプロセス呼び出しも標準ライブラリで堅牢に実装可能 | Julia起動時のTTFP(Time To First Plot)オーバーヘッドが毎回の呼び出しで発生する | 論文のEP戦略の柔軟な制御（履歴管理やプロンプト構築）にはPythonが適しているため採用。TTFP問題は必要に応じてDaemon化で将来対応。 |

## Design Decisions

### Decision: 状態管理（履歴とエリート保存）
- **Context**: 進化計算における世代ごとの最良個体の追跡と、LLMへのフィードバックコンテキストの構築。
- **Selected Approach**: メモリ上のデータ構造（List, Dict）で世代履歴、評価スコア、生成された数式、LLMの推論理由を保持する `HistoryManager` クラスを導入する。
- **Rationale**: データベースを導入するほどの規模ではなく、1回の実行セッション内で完結するため。

### Decision: Julia連携アーキテクチャ
- **Context**: `numerical-evaluator` との通信とエラーハンドリング。
- **Selected Approach**: Pythonの `subprocess.run` を用い、`stdin`にJSONを書き込み、`stdout`からJSONを読み取る。タイムアウトを設定し、評価が発散/ハングした場合の安全装置とする。
- **Rationale**: 非同期通信やソケット通信に比べ実装がシンプルであり、コンポーネント間の結合度が低く保てるため。
