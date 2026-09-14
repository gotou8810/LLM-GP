# facade.py

from typing import Protocol
from .models import StructuredResult, JudgeResult
from .prompt_manager import PromptManager
from .parser import ResponseParser, JudgeResponseParser

class ClientProtocol(Protocol):
    def send(self, prompt: str) -> str:
        ...

class LLMFacade:
    """
    LLMインターフェース全体を統括するFacadeクラス。
    プロンプトの生成、送信、結果のパースを一貫して行う。
    """
    def __init__(self, prompt_manager: PromptManager, client: ClientProtocol, parser: ResponseParser,
                 judge_parser: JudgeResponseParser = None):
        self.prompt_manager = prompt_manager
        self.client = client
        self.parser = parser
        self.judge_parser = judge_parser or JudgeResponseParser()

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

    def judge_candidate(self, **kwargs) -> JudgeResult:
        """
        提案側とは独立した「審判」呼び出し。数値の再計算はせず、提案側のfeedback
        (説明文)が、渡された確定済みの証拠(Skill Score・符号チェック結果など)と
        矛盾していないかだけを判定する。同じclient(同一LLM API)を使うが、提案時とは
        別のプロンプト・別の呼び出しであるため、提案側の自己正当化バイアスから独立する。
        """
        prompt = self.prompt_manager.generate_judge_prompt(**kwargs)
        raw_response = self.client.send(prompt)
        return self.judge_parser.parse(raw_response)
