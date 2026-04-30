# Research & Design Decisions

## Summary
- **Feature**: `tep-data-loader`
- **Discovery Scope**: Light Discovery (New Module / Simple Addition)
- **Key Findings**:
  - Juliaの標準ライブラリ `Downloads.jl` を用いることで外部依存なくファイルのダウンロードが可能。
  - `.RData` ファイルの読み込みには `RData.jl` が標準的な選択肢。読み込んだデータは `Dict{String, Any}` などの形式になる場合があるため、適切なデータ抽出処理が必要。
  - データ操作および抽出のベースとして `DataFrames.jl` が最も汎用的であり、後続プロセスとの親和性も高い。

## Architecture Pattern Evaluation
| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 統合モジュール (TEPDataLoader) | ダウンロード、パース、抽出の各関数を1つのJuliaモジュールにまとめる。 | シンプルで依存関係が少なく、実装・テストが容易。 | 大規模化した場合にファイルが肥大化する。 | 今回の要件（単一の機能群）に最適。 |

## Design Decisions
### Decision: DataFrames.jlの採用
- **Context**: 抽出したデータを後続プロセス（numerical-evaluator等）に渡すための標準フォーマットの選定。
- **Selected Approach**: すべてのパース済みデータを `DataFrame` 型として取り扱う。
- **Rationale**: 列指向のデータ操作が容易であり、特定の変数名（列名）に基づく抽出要件（Requirement 3）を標準関数で満たすことができるため。
