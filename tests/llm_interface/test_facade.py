import pytest
from unittest.mock import MagicMock
from src.llm_interface.facade import LLMFacade
from src.llm_interface.models import StructuredResult, JudgeResult
from src.llm_interface.prompt_manager import PromptManager
from src.llm_interface.parser import ResponseParser

def test_llm_facade_generate_candidate():
    # 依存コンポーネントのモックまたは実体
    pm = PromptManager(system_prompt="Context: {context}")
    parser = ResponseParser()
    
    mock_client = MagicMock()
    mock_client.send.return_value = '''
    ```json
    {
        "formula": "c[1] * xmeas_1",
        "feedback": "Test feedback"
    }
    ```
    '''
    
    facade = LLMFacade(prompt_manager=pm, client=mock_client, parser=parser)
    
    result = facade.generate_candidate(context="Some data")
    
    # Assertions
    mock_client.send.assert_called_once_with("Context: Some data")
    assert isinstance(result, StructuredResult)
    assert result.formula == "c[1] * xmeas_1"
    assert result.feedback == "Test feedback"

def test_llm_facade_judge_candidate_uses_independent_prompt_and_parser():
    pm = PromptManager()
    parser = ResponseParser()

    mock_client = MagicMock()
    mock_client.send.return_value = '''
    ---VERDICT---
    FLAG
    ---REASONING---
    Narrative claims strong grounding despite a near-zero skill score.
    '''

    facade = LLMFacade(prompt_manager=pm, client=mock_client, parser=parser)

    result = facade.judge_candidate(
        formula="c[1]*xmeas_16",
        law="Energy balance",
        sign_check_result="SIGN CHECK PASSED",
        skill_score="0.008",
        naive_mae="0.92",
        proposer_feedback="This proves a robust physical mechanism.",
        reactive_exclusions={},
    )

    assert isinstance(result, JudgeResult)
    assert result.verdict == "FLAG"
    assert "skill score" in result.reasoning
    # 提案側(generate_candidate)とは別のプロンプトテンプレートが使われていること
    sent_prompt = mock_client.send.call_args[0][0]
    assert "---VERDICT---" in sent_prompt
    assert "c[1]*xmeas_16" in sent_prompt
