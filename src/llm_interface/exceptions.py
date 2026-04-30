# exceptions.py

class LLMInterfaceError(Exception):
    """LLMInterface モジュールにおける基底の例外クラス"""
    pass

class ParseError(LLMInterfaceError):
    """LLMからの応答のパースに失敗した場合の例外"""
    pass

class CommunicationError(LLMInterfaceError):
    """LLM APIとの通信に失敗した場合の例外"""
    pass