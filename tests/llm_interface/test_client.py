import pytest
from unittest.mock import patch, MagicMock
from src.llm_interface.client import LLMClient
from src.llm_interface.exceptions import CommunicationError

@patch("src.llm_interface.client.genai.GenerativeModel")
def test_llm_client_success(mock_generative_model):
    mock_instance = MagicMock()
    mock_response = MagicMock()
    mock_response.text = '{"formula": "test", "feedback": "test"}'
    mock_instance.generate_content.return_value = mock_response
    mock_generative_model.return_value = mock_instance

    client = LLMClient(api_key="dummy", model_name="gemini-2.5-pro")
    
    response = client.send("Hello")
    assert "formula" in response

@patch("src.llm_interface.client.genai.GenerativeModel")
@patch("src.llm_interface.client.wait_exponential") # リトライ待ち時間をなくすためのモック
def test_llm_client_retry_and_failure(mock_wait, mock_generative_model):
    # テストが遅くならないように待機時間をゼロにするダミーを返す
    mock_wait.return_value = MagicMock(return_value=0)
    
    mock_instance = MagicMock()
    # 常に例外を投げるように設定
    mock_instance.generate_content.side_effect = Exception("API Error")
    mock_generative_model.return_value = mock_instance

    client = LLMClient(api_key="dummy", model_name="gemini-2.5-pro")
    
    with pytest.raises(CommunicationError):
        client.send("Fail me")
