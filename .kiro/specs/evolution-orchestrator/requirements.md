# Requirements Document

## Project Description (Input)
LLMによる数式生成とJuliaによる数値評価を連携させ、論文に示された進化戦略（初期化、最適化、評価、LLMフィードバック）の反復ループを実行するメインの制御機構が必要。プロンプトメインのアーキテクチャに基づき、LLMモジュール（llm-interface）とJulia計算モジュール（numerical-evaluator）を統合し、指定された世代数や収束条件を満たすまで探索ループを自動実行するメインスクリプトが実装されていること。

## Boundary Context
- **In scope**: TEPデータローダーの初期化（ダウンストリームプロセスのセットアップ）、進化の反復ループ（世代管理）の実装、LLMコンポーネントとJuliaコンポーネント間のデータ・指示の受け渡し、評価結果からのLLMプロンプトの構築、収束判定および最終結果の出力。
- **Out of scope**: データのダウンロード自体、個別の適応度計算アルゴリズムの内部実装、LLM API通信の低レベルハンドリング（これらは依存する他コンポーネントが行う）。
- **Adjacent expectations**: `llm-interface` が要求されたプロンプトに対して構造化された数式候補を返すこと。`numerical-evaluator` が標準入出力を通じて正確な評価結果（RMSE、Fitness等）を返すこと。

## Requirements

### Requirement 1: システムの初期化とデータ準備
**Objective:** As a system orchestrator, I want to initialize the environment and trigger data preparation, so that the evolutionary loop has access to the required TEP datasets.

#### Acceptance Criteria
1. When [システムが起動された場合], the [orchestrator] shall [データローダースクリプトを呼び出し、TEPデータの準備（ダウンロー ドやDataFrame化）を完了させる].
2. If [データの準備に失敗した場合], the [orchestrator] shall [エラーを報告してシステムを安全に終了させる].

### Requirement 2: 進化ループの制御（世代管理）
**Objective:** As a system orchestrator, I want to manage the evolutionary loop across multiple generations, so that the system can iteratively improve the mathematical formulas.

#### Acceptance Criteria
1. When [進化プロセスが開始された場合], the [orchestrator] shall [指定された最大世代数（例: 20世代）に達するまで、生成→評 価→フィードバックのサイクルを反復実行する].
2. The [orchestrator] shall [各世代における最良個体（Best Fitnessを持つ数式）を記録・保持する].
3. If [ある世代で指定された目標RMSE（収束条件）を満たした場合], the [orchestrator] shall [進化ループを早期終了し、最終結果を 出力する].

### Requirement 3: LLMとJulia計算エンジンの連携
**Objective:** As a system orchestrator, I want to bridge the LLM interface and the numerical evaluator, so that generated formulas are numerically evaluated and the results are fed back to the LLM.

#### Acceptance Criteria
1. When [LLMインターフェースから新しい数式候補を受け取った場合], the [orchestrator] shall [それを適切なJSON形式にフォーマッ トし、Juliaの`numerical-evaluator`をサブプロセスとして呼び出して評価させる].
2. When [Juliaからの評価結果（RMSE、最適化された係数、Fitness等）を受け取った場合], the [orchestrator] shall [その評価結 果とこれまでの履歴を基に、次世代向けの改善を促すプロンプトコンテキストを構築する].
3. The [orchestrator] shall [構築したプロンプトコンテキストを`llm-interface`に渡し、新たな数式の生成を要求する].

### Requirement 4: 結果の出力とロギング
**Objective:** As a system operator, I want to see the progress of the evolution and the final result, so that I can analyze the performance of the LLM-GP system.

#### Acceptance Criteria
1. When [各世代の評価が終了した場合], the [orchestrator] shall [現在の世代番号、テストされた数式、およびそのFitnessスコアをログ出力する].
2. When [進化ループが終了した（最大世代数到達または収束）場合], the [orchestrator] shall [最終的に最も適応度が高かった数式、 最適化された係数、およびそのRMSEを明確に提示する].

### Requirement 5: インタラクティブモードのサポート
**Objective:** As a system operator, I want to start the orchestrator in interactive mode, so that I can manually act as the LLM without requiring an API key.

#### Acceptance Criteria
1. When [起動時のコマンドライン引数にインタラクティブフラグ（例: `--interactive`）が指定された場合], the [orchestrator] shall [LLMモジュールをインタラクティブモードで初期化し、ループを実行する].
