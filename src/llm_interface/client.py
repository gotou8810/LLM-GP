# client.py

import os
import google.generativeai as genai
from tenacity import retry, stop_after_attempt, wait_exponential
from .exceptions import CommunicationError

class LLMClient:
    """
    Google Generative AI (Gemini) APIを使用してLLMと通信するクライアント
    """
    def __init__(self, api_key: str = None, model_name: str = "gemini-2.5-pro"):
        api_key = api_key or os.environ.get("GEMINI_API_KEY")
        if api_key:
            genai.configure(api_key=api_key)
            
        self.model = genai.GenerativeModel(model_name)
        
    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=10), reraise=True)
    def _send_with_retry(self, prompt: str) -> str:
        try:
            response = self.model.generate_content(prompt)
            return response.text
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
