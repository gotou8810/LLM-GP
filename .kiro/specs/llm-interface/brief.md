# Brief: llm-interface

## Problem
LLMを用いて物理的に意味のある数式を生成し、評価結果に基づくフィードバックループを回すためには、LLM APIと構造化されたデータのやり取りを行う機構が必要。

## Current State
LLMとの対話を行うためのコード基盤が存在しない。

## Desired Outcome
設定されたロール（例：化学工学のエキスパート）と進化戦略のプロンプトを管理し、LLM APIへリクエストを送信し、返答から数式候補やフィードバックを抽出するモジュールが実装されていること。

## Approach
「プロンプトメイン」の方針に従い、このモジュール（Python等）がLLM（Gemini等）との通信を担い、生成された数式や改善案を構造化してオーケストレーターに返す。

## Scope
- **In**: 進化プロンプト（EP）のテンプレート管理。LLM API（Google Gemini等）の呼び出し。LLMの応答からの数式の抽出およびフィードバックのパース。
- **Out**: 数値シミュレーションや最適化計算の実行、TEPデータの直接処理。

## Boundary Candidates
- プロンプトの構築とテンプレート管理
- APIクライアントとエラーハンドリング
- LLM出力のパースと構造化データへの変換

## Out of Boundary
- TEPデータの処理
- 差分進化法などの計算

## Upstream / Downstream
- **Upstream**: evolution-orchestrator
- **Downstream**: LLM API

## Constraints
- LLMからの応答がパースエラーになるケースを想定した堅牢な設計（リトライ機構やフォーマット指定など）を含めること。
