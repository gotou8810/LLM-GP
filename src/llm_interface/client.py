# client.py

import anthropic
from tenacity import retry, stop_after_attempt, wait_exponential
from .exceptions import CommunicationError

class LLMClient:
    """
    Anthropic Claude APIを使用してLLMと通信するクライアント
    """
    def __init__(self, api_key: str = None, model_name: str = "claude-sonnet-5", max_tokens: int = 16000):
        # api_key を省略した場合、SDKが ANTHROPIC_API_KEY -> ANTHROPIC_AUTH_TOKEN ->
        # `ant auth login` のプロファイルの順で自動的に認証情報を解決する
        self.client = anthropic.Anthropic(api_key=api_key) if api_key else anthropic.Anthropic()
        self.model_name = model_name
        self.max_tokens = max_tokens

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=10), reraise=True)
    def _send_with_retry(self, prompt: str) -> str:
        try:
            response = self.client.messages.create(
                model=self.model_name,
                max_tokens=self.max_tokens,
                messages=[{"role": "user", "content": prompt}],
            )
            return next((block.text for block in response.content if block.type == "text"), "")
        except Exception as e:
            # retryデコレータが拾えるようにそのまま再スローするが、
            # 最終的に失敗した場合は tenacity がこの例外を投げるので、
            # 呼び出し元でキャッチして CommunicationError に変換する
            raise e

    def send(self, prompt: str) -> str:
        try:
            return self._send_with_retry(prompt)
        except Exception as e:
            raise CommunicationError(f"Failed to communicate with LLM API: {e}") from e

class InteractiveLLMClient:
    """
    APIを使用せず、ユーザー入力によってLLMの応答を代替する（インタラクティブモード）
    """
    def send(self, prompt: str) -> str:
        print("========== PROMPT ==========")
        print(prompt)
        print("============================")
        print("Please provide the LLM's response (End with EOF/Ctrl+D on a new line):")
        
        lines = []
        try:
            while True:
                line = input()
                lines.append(line)
        except EOFError:
            pass
            
        return "\n".join(lines)
