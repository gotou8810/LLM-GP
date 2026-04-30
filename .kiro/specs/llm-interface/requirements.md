# Requirements Document

## Introduction
本仕様は、LLM-GPシステムにおいてLLMとのインターフェースを担う機能要件を定義します。物理的に意味のある数式生成やフィードバックループを実現するため、プロンプトの管理、API通信、およびLLMのテキスト応答からの構造化データ（数式・フィードバック）の抽出を対象とします。

## Boundary Context
- **In scope**: 進化プロンプト（EP）のテンプレート管理と変数の埋め込み、LLM API（Google Gemini等）へのリクエスト送信、LLMのテキスト応答からの数式候補やフィードバックのパース、不完全な応答に対するエラーハンドリング。
- **Out of scope**: TEPデータの読み込み・処理、Juliaを用いた適応度評価や差分進化法などの数値計算全般、オーケストレーションのメインループ制御。
- **Adjacent expectations**: 上流のオーケストレーターは本機能に正しいプロンプト変数を提供する責任を持ちます。下流の数値計算モジュールは本機能がパース・抽出した文字列形式の数式を入力として受け取ります。

## Requirements

### Requirement 1: プロンプト管理 (Prompt Management)
**Objective:** As an orchestrator, I want to manage prompt templates and inject data, so that I can dynamically configure the LLM's role and evolutionary instructions.

#### Acceptance Criteria
1. When [プロンプトテンプレートと変数が提供された場合], the [LLM Interface] shall [それらを結合して完全なプロンプト文字列を生成する].
2. The [LLM Interface] shall [システムプロンプト（専門家としての役割定義など）を保持し、リクエストに含める].

### Requirement 2: LLM API 通信 (LLM API Communication)
**Objective:** As an orchestrator, I want to send prompts to the LLM API, so that the LLM can generate evolutionary candidates and feedback.

#### Acceptance Criteria
1. When [生成されたプロンプトの送信が要求された場合], the [LLM Interface] shall [指定されたLLM APIへリクエストを送信する].
2. While [LLM APIへリクエストを送信中である場合], the [LLM Interface] shall [応答を待機し、取得したテキスト応答を呼び出し元へ返す].

### Requirement 3: 応答のパースとデータ抽出 (Response Parsing and Extraction)
**Objective:** As an orchestrator, I want to extract target formulas and structured feedback from the raw LLM response, so that downstream numerical evaluation can be executed.

#### Acceptance Criteria
1. When [LLMからのテキスト応答を受信した場合], the [LLM Interface] shall [応答テキスト内から数式候補の文字列を抽出する].
2. When [LLMからのテキスト応答を受信した場合], the [LLM Interface] shall [応答テキスト内から評価用の構造化されたフィードバック情報を抽出する].

### Requirement 4: エラーハンドリング (Error Handling)
**Objective:** As an orchestrator, I want the interface to handle LLM communication errors and unparseable responses, so that the overall evolutionary loop can maintain resilience.

#### Acceptance Criteria
1. If [LLMからの応答が期待されるフォーマット（JSONや特定タグなど）に合致せずパースエラーとなった場合], the [LLM Interface] shall [パース失敗のエラーをスローして報告する].
2. If [LLM APIとの通信エラーやタイムアウトが発生した場合], the [LLM Interface] shall [例外を捕捉し、上位のオーケストレーターへ通信エラーとして通知する].

### Requirement 5: インタラクティブモード（手動対話）のサポート
**Objective:** As a user without an API key, I want to act as the LLM by reading prompts and manually entering formulas and feedback, so that I can run the evolutionary loop interactively.

#### Acceptance Criteria
1. When [インタラクティブモードが有効な場合], the [LLM Interface] shall [APIリクエストを送信せず、生成されたプロンプトをコンソールに出力する].
2. The [LLM Interface] shall [ユーザーからの標準入力（手動での数式やフィードバックの入力）を待機し、それをLLMからの応答テキストとして扱う].
