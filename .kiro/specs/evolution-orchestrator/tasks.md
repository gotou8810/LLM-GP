# Implementation Plan

- [x] 1. Foundation: 環境設定と基盤コンポーネントの実装
- [x] 1.1 Pythonプロジェクトのセットアップと `HistoryManager` の実装
  - `src/orchestrator` ディレクトリを作成し、`__init__.py`, `history.py` 等の空ファイルを用意する
  - `history.py` に `GenerationRecord` データクラス and `HistoryManager` クラスを実装する
  - **完了条件**: `HistoryManager` のユニットテストが通過すること
- [x] 1.2 `SubprocessWrapper` の実装（Julia連携基盤）
  - `julia_runner.py` に `SubprocessWrapper` クラスを作成し、`subprocess.run` を用いてJuliaプロセスを呼び出すロジックを実装する
  - **完了条件**: JuliaプロセスとのJSON通信が正常に動作すること
- [x] 2. Core: 進化ループの実装
- [x] 2.1 `EvolutionLoop` の実装と制御ロジック
  - `loop.py` に `EvolutionLoop` クラスを実装し、LLM生成、Julia評価、履歴記録のサイクルを構成する
  - **完了条件**: 統合テストにおいて指定世代数までループが回ること
- [x] 3. Integration & Validation: システム全体の結合とエントリポイント
- [x] 3.1 CLIエントリポイントの実装と最終出力
  - `main.py` を作成し、全コンポーネントを統合したエントリーポイントを実装する。
  - `--interactive` モードにより実機（Julia）との結合が確認されている。
  - **完了条件**: 統合スクリプトがエラーなく起動し、エンドツーエンドで動作すること
