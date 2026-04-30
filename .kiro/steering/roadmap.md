# Roadmap

## Overview
テネシー・イーストマン・プロセス（TEP）データセットに対して式発見（記号回帰）を行うためのLLM-GPシステムの構築。LLMによる知的探索とJuliaによる厳密な数値評価を組み合わせたハイブリッドアーキテクチャを採用する。

## Approach Decision
- **Chosen**: LLM主導型（プロンプトメイン）＋Julia計算エンジン
- **Why**: LLMが探索戦略や式生成を主導し、Juliaを外部プロセスとして呼び出して適応度評価や係数最適化を行わせることで、LLMの推論能力とJuliaの計算速度の両方の強みを活かすことができるため。
- **Rejected alternatives**: Juliaコード内からLLM APIを直接叩く方式。LLMのコンテキスト管理やプロンプト制御が複雑になる可能性があるため。

## Scope
- **In**: Harvard DataverseからのTEPデータダウンロードと読み込み、差分進化法（DE）による定数最適化、RMSEおよびペナルティに基づく適応度評価、進化戦略（EP）に基づく数式生成とLLMフィードバックループ。
- **Out**: 実稼働プラントへのオンラインデプロイ、汎用的な（TEP以外の）データセットへの完全対応。

## Constraints
- **技術制約**: 計算エンジンとしてJuliaを使用（RData.jl, DataFrames.jl, DifferentialEvolution.jl等を想定）。
- **データ制約**: 対象データはHarvard Dataverseから取得するTEPデータ（TEP_FF.RData, TEP_FT.RData）。
- **通信方式**: プロンプトをメインとしてJuliaプログラムを呼び出すアーキテクチャ。

## Boundary Strategy
- **Why this split**: データの取得・前処理、数値計算、LLM通信、全体制御という明確な責務の分離により、各コンポーネントを独立して実装・テストできるようにするため。
- **Shared seams to watch**: メインプロセス（LLMオーケストレーター）からJuliaプロセスへの数式・データの渡し方（例：ファイル経由、標準入力など）、およびJuliaプロセスからの評価結果（RMSE、最適化された係数）の受け取り方。

## Specs (dependency order)
- [x] tep-data-loader -- TEPデータセット（.RData）のダウンロードとJulia DataFrameへの変換. Dependencies: none
- [x] numerical-evaluator -- Juliaによる係数最適化（差分進化法）と適応度（RMSE等）の計算. Dependencies: tep-data-loader
- [x] llm-interface -- プロンプトの構築、LLMへのクエリ送信、LLMからの数式やフィードバックのパース. Dependencies: none
- [x] evolution-orchestrator -- LLMの推論ループを回し、LLMとJuliaエンジンを統合して進化戦略を実行するメインループ. Dependencies: tep-data-loader, numerical-evaluator, llm-interface
