# Requirements Document

## Introduction
Harvard Dataverse上にホストされている.RData形式のTEPデータセットを自動的にダウンロードし、JuliaのDataFrame形式に変換・抽出する汎用的なデータローダー。特定の変数に依存せず、任意の変数セットを取得可能にすることで、後続の数値評価プロセスにデータを提供することを目的とする。

## Boundary Context (Optional)
- **In scope**: リモートURLからのファイルダウンロード、.RData形式のパースと表形式（DataFrame）への変換、任意の変数の選択および抽出。
- **Out of scope**: 欠損値補完などの高度なデータクリーニング、適応度関数の計算、数式の生成。
- **Adjacent expectations**: ダウンロード元のAPI（Harvard Dataverse）が稼働しておりアクセス可能であること。後続プロセス（numerical-evaluator）が抽出された表形式データを受け取れること。

## Requirements

### Requirement 1: データのダウンロード
**Objective:** システム運用者として、リモートの.RDataファイルを指定したURLから自動的にダウンロードし、ローカル環境で処理可能にしたい。

#### Acceptance Criteria
1. When [有効なダウンロードURLが指定された場合], the [データローダー] shall [対象のファイルをローカルシステムにダウンロードする]
2. If [ダウンロードURLが無効またはアクセスできない場合], the [データローダー] shall [ダウンロード失敗を示すエラーを返す]

### Requirement 2: データフォーマットの変換
**Objective:** 後続の数値評価プロセスとして、ダウンロードした.RDataファイルを汎用的な表形式データに変換し、以降の処理で容易にデータ操作ができるようにしたい。

#### Acceptance Criteria
1. When [有効な.RDataファイルが提供された場合], the [データローダー] shall [ファイルをパースし表形式データ（DataFrame）に変換する]
2. If [提供されたファイルが有効な.RData形式でない、あるいはファイルが破損している場合], the [データローダー] shall [パースエラーを発生させる]

### Requirement 3: 変数の選択と抽出
**Objective:** 後続の数値評価プロセスとして、変換されたデータセットから評価に必要な特定の変数のみを抽出したい。

#### Acceptance Criteria
1. When [抽出対象の変数名リスト（例: XMEAS, XMV）が指定された場合], the [データローダー] shall [指定された変数のみを含むデータセットを返す]
2. If [指定された変数がデータセット内に存在しない場合], the [データローダー] shall [変数が存在しない旨のエラーを返す]
3. The [データローダー] shall [特定の変数名にハードコードで依存せず、データセット内の任意の変数を抽出可能な設計とする]
