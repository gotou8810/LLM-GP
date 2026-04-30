# facade.py

from typing import Protocol
from .models import StructuredResult
from .prompt_manager import PromptManager
from .parser import ResponseParser

class ClientProtocol(Protocol):
    def send(self, prompt: str) -> str:
        ...

class LLMFacade:
    """
    LLMインターフェース全体を統括するFacadeクラス。
    プロンプトの生成、送信、結果のパースを一貫して行う。
    """
    def __init__(self, prompt_manager: PromptManager, client: ClientProtocol, parser: ResponseParser):
        self.prompt_manager = prompt_manager
        self.client = client
        self.parser = parser
        
    def generate_candidate(self, **kwargs) -> StructuredResult:
        """
        与えられたコンテキストからプロンプトを生成し、LLMに送信後、
        パースされた構造化結果を返す。
        """
        # 1. プロンプト生成
        prompt = self.prompt_manager.generate_prompt(**kwargs)
        
        # 2. LLMへの送信（またはインタラクティブ入力）
        raw_response = self.client.send(prompt)
        
        # 3. 応答のパース
        result = self.parser.parse(raw_response)
        
        return result
