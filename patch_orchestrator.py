import re

# 1. Update requirements.md
with open('.kiro/specs/evolution-orchestrator/requirements.md', 'r', encoding='utf-8') as f:
    req = f.read()

req_addition = """
### Requirement 5: インタラクティブモードのサポート
**Objective:** As a system operator, I want to start the orchestrator in interactive mode, so that I can manually act as the LLM without requiring an API key.

#### Acceptance Criteria
1. When [起動時のコマンドライン引数にインタラクティブフラグ（例: `--interactive`）が指定された場合], the [orchestrator] shall [LLMモジュールをインタラクティブモードで初期化し、ループを実行する].
"""
req += req_addition

with open('.kiro/specs/evolution-orchestrator/requirements.md', 'w', encoding='utf-8') as f:
    f.write(req)

# 2. Update design.md
with open('.kiro/specs/evolution-orchestrator/design.md', 'r', encoding='utf-8') as f:
    des = f.read()

des = des.replace("4.1, 4.2 | 結果出力とロギング", "4.1, 4.2 | 結果出力とロギング | main.py, loop.py | logger.info() |\n| 5.1 | インタラクティブモード引数の解釈 | main.py | `argparse` |")

with open('.kiro/specs/evolution-orchestrator/design.md', 'w', encoding='utf-8') as f:
    f.write(des)

# 3. Update tasks.md
with open('.kiro/specs/evolution-orchestrator/tasks.md', 'r', encoding='utf-8') as f:
    tsk = f.read()

tsk = tsk.replace("実行開始前に `init_data` を呼び出すフローを組み込む", "実行開始前に `init_data` を呼び出すフローを組み込む\n  - argparse等を用いて `--interactive` フラグを実装し、指定時は `InteractiveLLMClient` を使用するようにFacadeの初期化を切り替える処理を実装する")
tsk = tsk.replace("_Requirements: 1.1, 4.2_", "_Requirements: 1.1, 4.2, 5.1_")

with open('.kiro/specs/evolution-orchestrator/tasks.md', 'w', encoding='utf-8') as f:
    f.write(tsk)

