# Implementation Plan

- [ ] 1. Foundation: モジュール構造と環境のセットアップ
- [x] 1.1 `TEPDataLoader.jl` の作成と依存パッケージの設定
  - `Project.toml` を作成し、`RData`, `DataFrames`, `Downloads` を依存関係に追加する
  - `src/TEPDataLoader.jl` にモジュールのスケルトンを定義し、エクスポートする関数名（`download_data`, `load_rdata`, `extract_variables`）を宣言する
  - テスト環境（`test/runtests.jl`）の雛形を用意する
  - **完了条件**: `Pkg.test()` がモジュール読み込みエラー等なく正常に実行できる状態になること
  - _Requirements: 1, 2, 3_

- [ ] 2. Core: データ処理関数の実装
- [x] 2.1 (P) `download_data` 関数の実装とユニットテスト
  - `Downloads.jl` を使用して指定URLからファイルをダウンロードし、保存先パスを返す処理を実装する
  - 無効なURLや通信エラーに対する例外ハンドリングを実装し、適切なエラーメッセージを送出する
  - ユニットテストを追加し、正常系と異常系の動作を確認する
  - **完了条件**: 正常なURLからファイルが保存され、異常なURLではエラーがスローされることがテストで確認されること
  - _Requirements: 1_
  - _Boundary: TEPDataLoader_

- [ ] 2.2 (P) `load_rdata` 関数の実装とユニットテスト
  - `RData.load` を使用してローカルの `.RData` ファイルを読み込む処理を実装する
  - 読み込んだオブジェクトからデータの実体を取り出し、`DataFrame` に変換して返す処理を実装する
  - 破損ファイルや無効なファイルフォーマットに対するエラーハンドリングを実装する
  - ユニットテストを追加し、テスト用 `.RData` を用いてパースと変換の正確性を検証する
  - **完了条件**: テスト用の `.RData` ファイルから DataFrame が正しく生成されることがテストで確認されること
  - _Requirements: 2_
  - _Boundary: TEPDataLoader_

- [ ] 2.3 (P) `extract_variables` 関数の実装とユニットテスト
  - 与えられた `DataFrame` と変数名のリスト（`Vector{String}`）を受け取り、対応する列のみを抽出した新しい `DataFrame` を返す処理を実装する
  - 指定された変数が `DataFrame` に存在しない場合の事前チェックと、明確なエラーメッセージを持つ例外の送出を実装する
  - ユニットテストを追加し、正常抽出と存在しない変数の指定時のエラー動作を検証する
  - **完了条件**: 入力された DataFrame から指定列のみを持つ新しい DataFrame が生成され、存在しない列の指定時にはフェイルファストにエラーがスローされることがテストで確認されること
  - _Requirements: 3_
  - _Boundary: TEPDataLoader_

- [ ] 3. Integration and Validation: エンドツーエンド検証
- [ ] 3.1 データパイプラインの統合テスト
  - `download_data` -> `load_rdata` -> `extract_variables` を一連のフローとして実行する統合テストを実装する
  - 実データ（または構造を模したテストデータ）をダウンロードし、特定の変数が最終的に DataFrame として正しく抽出されることまでを通しで確認する
  - **完了条件**: ダウンロードから変数抽出までの全フローが結合テストとしてパスすること
  - _Depends: 2.1, 2.2, 2.3_
  - _Requirements: 1, 2, 3_
