# Brief: tep-data-loader

## Problem
TEPのデータはHarvard Dataverse上に`.RData`形式でホストされており、Juliaで数式評価を行うために、これを自動的にダウンロードし、扱いやすい形式（DataFrame等）に変換・抽出する必要がある。

## Current State
データはリモートに存在し、ローカルに処理可能なデータセットがない状態。

## Desired Outcome
指定されたURL（永続ID）からデータをダウンロードし、特定の変数に依存せず任意の変数（XMEAS, XMV等）を抽出できる汎用的なデータローダーがJuliaの機能として実装されていること。

## Approach
Juliaの標準ライブラリ（`Downloads`等）を使用してHarvard Dataverse APIからデータを取得し、`RData.jl`と`DataFrames.jl`を使用してパースおよび抽出を行う。

## Scope
- **In**: Harvard Dataverseからの`TEP_FF.RData`および`TEP_FT.RData`のダウンロード。`RData.jl`を用いたパースと、任意の変数の抽出・前処理。
- **Out**: データそのものの高度な統計的分析やクリーニング処理（欠損値補完などが必要な場合を除く）。

## Boundary Candidates
- データのダウンロード機能
- `.RData`のパースとDataFrame化
- 目的変数・説明変数の選択と抽出機能

## Out of Boundary
- 適応度関数や最適化の計算
- 数式の生成

## Upstream / Downstream
- **Upstream**: Harvard Dataverse API
- **Downstream**: numerical-evaluator, evolution-orchestrator

## Constraints
- 特定の変数に決め打ちせず、任意の変数に対応できる汎用的な設計とすること。
