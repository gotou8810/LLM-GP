# Research Log

## Summary
- **Discovery Type**: Full (New Feature)
- **Scope**: LLM API統合、プロンプト管理、構造化レスポンスパース
- **Key Findings**:
  1. Pythonベースのオーケストレーターと統合するため、`google-generativeai` または標準的なHTTPクライアント（`requests`/`httpx`）を利用した通信モジュールが必要。
  2. 構造化データの抽出とパースの堅牢性を高めるため、`pydantic`を用いたバリデーションと、リトライ機構（`tenacity`など）の導入が推奨される。
  3. LLMの出力は不安定になる可能性があるため、正規表現を用いたフォールバック抽出や特定タグ（`<formula>...</formula>`等）の指定プロンプトが有効。

## Synthesis Decisions
- **Build vs Adopt**: プロンプトテンプレートエンジンは標準ライブラリ（`string.Template`）または軽量な独自実装を採用（過剰な依存を避けるため）。
- **API Client**: LLMクライアント部分はプロトコルを抽象化し、将来的にGemini以外のLLMへも切り替え可能なインターフェースとする。
- **Resilience**: 通信エラーとパースエラーを明確に区別するカスタム例外クラスを定義し、呼び出し元（オーケストレーター）で適切な再試行戦略を取れるようにする。
