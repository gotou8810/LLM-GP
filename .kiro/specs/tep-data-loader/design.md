# Design Document

## Overview 
This feature delivers an automated data loading mechanism for TEP datasets to downstream numerical evaluation processes. Users (systems) will utilize this for fetching remote `.RData` files, parsing them into standard Julia data structures, and extracting relevant variables without manual intervention.

### Goals
- Harvard Dataverse等のリモートURLから`.RData`ファイルを自動ダウンロードする。
- ダウンロードしたファイルをパースし、扱いやすい`DataFrame`形式に変換する。
- 特定の変数にハードコードで依存せず、指定された変数リストに基づいてデータを抽出する。

### Non-Goals
- データの欠損値補完や外れ値除去といった高度なデータクリーニング。
- 抽出したデータを用いた適応度関数の計算や数式の生成。

## Boundary Commitments

### This Spec Owns
- リモートURLからのファイルダウンロード機能。
- `.RData`フォーマットからJuliaの`DataFrame`へのパースおよび変換ロジック。
- 指定された列（変数）のサブセットを抽出する機能。

### Out of Boundary
- 解析アルゴリズム（差分進化法、記号回帰など）の実装。
- 他のデータ形式（.csv, .json等）の読み込み対応（将来的な拡張の余地は残す）。

### Allowed Dependencies
- `Downloads` (Julia標準ライブラリ)
- `RData.jl`
- `DataFrames.jl`

### Revalidation Triggers
- 後続プロセスが`DataFrame`以外のデータ構造（例：テンソルや専用の構造体）を要求するように変更された場合。
- データの取得元（Harvard Dataverse）の認証要求やURL構造が大幅に変更された場合。

## Architecture

### Architecture Pattern & Boundary Map
本機能は独立したユーティリティモジュール（`TEPDataLoader.jl`）として実装されます。後続のプロセスは、このモジュールが提供するパブリック関数を呼び出すことでデータを取得します。

### Technology Stack

| Layer | Choice / Version | Role in Feature | Notes |
|-------|------------------|-----------------|-------|
| Backend | Julia 1.x | 実行環境 | |
| Network | Downloads.jl (stdlib) | HTTPダウンロード | 標準ライブラリを利用 |
| Data | RData.jl | .RDataファイルのパース | |
| Data | DataFrames.jl | 表形式データの操作・保持 | 列の抽出やフィルタリングに使用 |

## File Structure Plan

```text
src/
└── TEPDataLoader.jl    # ダウンロード、RDataパース、変数抽出のすべてのロジックをカプセル化するモジュール
```

## Requirements Traceability

| Requirement | Summary | Components | Interfaces |
|-------------|---------|------------|------------|
| 1 | データのダウンロード | TEPDataLoader | `download_data` |
| 2 | データフォーマットの変換 | TEPDataLoader | `load_rdata` |
| 3 | 変数の選択と抽出 | TEPDataLoader | `extract_variables` |

## Components and Interfaces

### TEPDataLoader

| Field | Detail |
|-------|--------|
| Intent | .RDataファイルのダウンロードから変数抽出までの一連のデータ準備を担う。 |
| Requirements | 1, 2, 3 |

**Responsibilities & Constraints**
- ファイルの安全なダウンロードとエラーハンドリング。
- `RData`オブジェクトの展開と`DataFrame`への確実な変換。
- 存在しない変数が要求された際のフェイルファストなエラー送出。

**Dependencies**
- External: `Downloads` — HTTP取得 (P0)
- External: `RData.jl` — パース (P0)
- External: `DataFrames.jl` — データ構造 (P0)

**Contracts**: Service [x]

##### Service Interface
```julia
module TEPDataLoader

using DataFrames
using RData
using Downloads

"""
指定されたURLからファイルをダウンロードし、ローカルの保存先パスを返します。
ダウンロードに失敗した場合はエラーを発生させます。
"""
function download_data(url::String, dest_path::String)::String
end

"""
ローカルの.RDataファイルを読み込み、DataFrameに変換して返します。
ファイルが不正な場合はエラーを発生させます。
"""
function load_rdata(file_path::String)::DataFrame
end

"""
DataFrameから指定された変数（列名）のみを抽出した新しいDataFrameを返します。
存在しない変数が指定された場合はエラーを発生させます。
"""
function extract_variables(df::DataFrame, variables::Vector{String})::DataFrame
end

end
```

**Implementation Notes**
- Integration: `load_rdata`の実装においては、`RData.load`が返すオブジェクト（Dict等）から実際のデータフレーム部分を適切に抽出するハンドリングが必要です。
- Validation: `download_data`ではネットワークエラーや不正なURLに対する例外処理を適切に行ってください。
- Validation: `extract_variables`では、指定された列名がDataFrame内に存在するかを事前にチェックし、存在しない場合は明確なエラーメッセージを出力してください。

## Error Handling

### Error Strategy
- **Fail Fast**: ダウンロード失敗、ファイル破損、存在しない変数の要求など、異常な状態を検知した場合は直ちにエラー（Exception）をスローし、後続の不正な計算を防ぎます。

### Error Categories and Responses
- **ネットワークエラー**: URLが無効、またはサーバーに接続できない場合は`Downloads.jl`の例外をラップまたはそのまま送出し、ダウンロード失敗を伝達します。
- **パースエラー**: ファイルが破損している、または有効な.RData形式でない場合は`RData.jl`の例外によって処理を中断します。
- **変数抽出エラー**: `extract_variables`において、要求された変数がDataFrameに存在しない場合は、`ArgumentError`などをスローして利用者に通知します。

## Testing Strategy

- Unit Tests:
  - `download_data`: 正常なURLからのダウンロード成功と、無効なURL時の適切なエラー送出。
  - `load_rdata`: テスト用の小規模な`.RData`ファイルを用いたパース成功の確認と、非RDataファイル読み込み時のエラーハンドリング。
  - `extract_variables`: 存在する変数のみを指定した場合の正確な抽出と、存在しない変数を指定した場合のエラー送出。
