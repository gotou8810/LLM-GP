# Brief: evolution-orchestrator

## Problem
LLMによる数式生成とJuliaによる数値評価を連携させ、論文に示された進化戦略（初期化、最適化、評価、LLMフィードバック）の反復ループを実行するメインの制御機構が必要。

## Current State
コンポーネントを繋ぐメインループが存在しない。

## Desired Outcome
プロンプトメインのアーキテクチャに基づき、LLMモジュール（llm-interface）とJulia計算モジュール（numerical-evaluator）を統合し、指定された世代数や収束条件を満たすまで探索ループを自動実行するメインスクリプトが実装されていること。

## Approach
オーケストレーター自体がLLMの制御フローを担うスクリプト（Python等）として実装。llm-interfaceで生成した式をnumerical-evaluatorに渡し、その評価結果（RMSE等）を再びプロンプトに組み込んで次世代の生成をllm-interfaceに依頼する。

## Scope
- **In**: TEPデータローダーの初期化のトリガー。進化の反復ループ（世代管理）の実装。LLMコンポーネントとJuliaコンポーネント間のデータ・指示の受け渡し。収束判定および最終結果の出力。
- **Out**: 個別の適応度計算アルゴリズムの内部実装、個別のLLM通信の低レベルAPIハンドリング。

## Boundary Candidates
- メイン実行ループ（初期化、評価、世代更新、収束判定）
- コンポーネント（LLM、Julia計算機）間のデータの橋渡し（ファイルI/Oまたはサブプロセス間通信）

## Out of Boundary
- TEPデータのダウンロードと前処理処理自体
- 係数最適化の詳細な計算アルゴリズム

## Upstream / Downstream
- **Upstream**: none (Entry point for user)
- **Downstream**: tep-data-loader, numerical-evaluator, llm-interface

## Constraints
- LLMが探索の主導権を握れるよう、評価結果のテキスト化（フィードバック用コンテキストの構築）を適切に構築してLLMに渡す設計とすること。
