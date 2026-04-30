import re

# 1. Update requirements.md
with open('.kiro/specs/llm-interface/requirements.md', 'r', encoding='utf-8') as f:
    req = f.read()

req_addition = """
### Requirement 5: インタラクティブモード（手動対話）のサポート
**Objective:** As a user without an API key, I want to act as the LLM by reading prompts and manually entering formulas and feedback, so that I can run the evolutionary loop interactively.

#### Acceptance Criteria
1. When [インタラクティブモードが有効な場合], the [LLM Interface] shall [APIリクエストを送信せず、生成されたプロンプトをコンソールに出力する].
2. The [LLM Interface] shall [ユーザーからの標準入力（手動での数式やフィードバックの入力）を待機し、それをLLMからの応答テキストとして扱う].
"""
req += req_addition

with open('.kiro/specs/llm-interface/requirements.md', 'w', encoding='utf-8') as f:
    f.write(req)


# 2. Update design.md
with open('.kiro/specs/llm-interface/design.md', 'r', encoding='utf-8') as f:
    des = f.read()

des = des.replace("4.1, 4.2 | パース/通信エラー時の例外処理", "4.1, 4.2 | パース/通信エラー時の例外処理 | Facade, Exceptions | `LLMInterfaceError` |\n| 5.1, 5.2 | インタラクティブ（手動）モード | InteractiveLLMClient | `send` |")

des = des.replace("#### LLMClient", """#### InteractiveLLMClient
| Field | Detail |
|-------|--------|
| Intent | APIを使用せず、ユーザー入力によってLLMの応答を代替する |
| Requirements | 5.1, 5.2 |

##### Service Interface
```python
class InteractiveLLMClient:
    def send(self, prompt: str) -> str:
        # Prints prompt to console and returns user input via input()
```

#### LLMClient""")

with open('.kiro/specs/llm-interface/design.md', 'w', encoding='utf-8') as f:
    f.write(des)


# 3. Update tasks.md
with open('.kiro/specs/llm-interface/tasks.md', 'r', encoding='utf-8') as f:
    tsk = f.read()

tsk_addition = """- [ ] 2.4 (P) InteractiveLLMClientの実装
  - `client.py` に `InteractiveLLMClient` クラスを作成し、コンソールにプロンプトを出力して `input()` 等でユーザーからの応答を待機・取得するロジックを実装する
  - _Boundary: InteractiveLLMClient_
  - _Requirements: 5.1, 5.2_
"""

tsk = tsk.replace("- [ ] 3. Integration", tsk_addition + "\n- [ ] 3. Integration")

with open('.kiro/specs/llm-interface/tasks.md', 'w', encoding='utf-8') as f:
    f.write(tsk)

