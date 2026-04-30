import pytest
from unittest.mock import MagicMock
from src.llm_interface.facade import LLMFacade
from src.llm_interface.models import StructuredResult
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
