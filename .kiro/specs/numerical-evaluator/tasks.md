# Implementation Plan

- [x] 1. Foundation: 環境構築とCLII/O基盤の実装
- [x] 1.1 モジュールとパッケージ依存関係のセットアップ
- [x] 1.2 CLIエントリポイントとJSONルーティングの実装
- [x] 2. Core: 計算エンジンの実装
- [x] 2.1 (P) `parser.jl` の実装（安全な数式パース）
- [x] 2.2 (P) `fitness.jl` の実装（適応度・RMSE・ペナルティ計算）
- [x] 2.3 (P) `optimizer.jl` の実装（係数の最適化）
- [x] 3. Integration & Validation: E2E評価フローの統合
- [x] 3.1 評価パイプラインの結合とCLI連携
