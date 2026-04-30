import pytest
from src.llm_interface.models import StructuredResult
from src.llm_interface.exceptions import ParseError, CommunicationError

def test_structured_result_creation():
    # 正常系の生成テスト
    result = StructuredResult(
        formula="c[1] * XMEAS(1) + c[2]",
        feedback="The previous formula lacked a constant term."
    )
    assert result.formula == "c[1] * XMEAS(1) + c[2]"
    assert result.feedback == "The previous formula lacked a constant term."

def test_exceptions():
    # 例外が正しく初期化できるか
    e1 = ParseError("Failed to parse JSON")
    assert str(e1) == "Failed to parse JSON"
    assert isinstance(e1, Exception)

    e2 = CommunicationError("API request timed out")
    assert str(e2) == "API request timed out"
    assert isinstance(e2, Exception)
