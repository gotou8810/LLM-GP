import re

with open('USER_GUIDE.md', 'r', encoding='utf-8') as f:
    content = f.read()

interactive_section = """
### 1.3 【代替】インタラクティブモード（APIキー不要）
APIキーを使用せず、プロンプトをコンソールに出力し、ユーザー自身がLLMの代わりに応答を入力する「インタラクティブモード」も利用可能です。このモードを使用する場合は環境変数の設定は不要です。

---

## 2. クイックスタート

システムのメインエントリポイントを実行することで、初期化から数式発見のループまでが自動的に開始されます。

### 通常モード（API利用）
```bash
python src/orchestrator/main.py --target "XMEAS(7)" --max-gen 20
```

### インタラクティブモード（APIキー不要・手動入力）
```bash
python src/orchestrator/main.py --target "XMEAS(7)" --max-gen 20 --interactive
```
"""

content = re.sub(r'--- *\n*## 2\. クイックスタート.*?(?=- `--target`)', interactive_section, content, flags=re.DOTALL)

with open('USER_GUIDE.md', 'w', encoding='utf-8') as f:
    f.write(content)
