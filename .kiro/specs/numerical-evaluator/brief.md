# Brief: numerical-evaluator

## Problem
LLMが生成した数式候補がデータにどの程度適合しているかを評価するためには、数式内の未知係数を最適化し、実測値との誤差（RMSE等）を高速に計算する機能が必要。

## Current State
適応度計算や最適化アルゴリズムが実装されていない。

## Desired Outcome
LLMから文字列として渡された数式に対して、未知の係数を差分進化法（DE）で最適化し、RMSEとペナルティ（複雑さや物理制約）を考慮した適応度スコアを返すJuliaプログラムが実装されていること。

## Approach
LLM（またはオーケストレーター）から外部プロセスとして呼び出されるCLIスクリプト等として実装。`DifferentialEvolution.jl`（またはそれに類するJuliaの最適化パッケージ）を利用して係数をフィッティングし、誤差を計算する。

## Scope
- **In**: 文字列として与えられた数式のパース・動的評価。差分進化法を用いた未知係数の最適化。データセット（tep-data-loader経由）を用いたRMSEの計算と、複雑さ等を考慮したペナルティの適用。
- **Out**: 数式そのものの生成や変異操作。

## Boundary Candidates
- 数式のパースと動的評価機構
- 差分進化法を用いた最適化エンジンの設定
- 適応度関数の定義と計算プロセス

## Out of Boundary
- データのダウンロード
- LLMへのプロンプト生成

## Upstream / Downstream
- **Upstream**: tep-data-loader, evolution-orchestrator
- **Downstream**: evolution-orchestrator

## Constraints
- LLM（オーケストレーター）からの呼び出しに対応できるよう、引数やファイル入出力等で数式を受け取り、結果をパースしやすい形式（JSON等）で返せるインターフェースを持つこと。
