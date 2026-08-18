import pytest
from unittest.mock import patch, MagicMock
from src.llm_interface.client import LLMClient
from src.llm_interface.exceptions import CommunicationError

@patch("src.llm_interface.client.anthropic.Anthropic")
def test_llm_client_success(mock_anthropic_cls):
    mock_client = MagicMock()
    mock_block = MagicMock()
    mock_block.type = "text"
    mock_block.text = '{"formula": "test", "feedback": "test"}'
    mock_response = MagicMock()
    mock_response.content = [mock_block]
    mock_client.messages.create.return_value = mock_response
    mock_anthropic_cls.return_value = mock_client

    client = LLMClient(api_key="dummy", model_name="claude-opus-5")

    response = client.send("Hello")
    assert "formula" in response

@patch("src.llm_interface.client.anthropic.Anthropic")
@patch("src.llm_interface.client.wait_exponential") # リトライ待ち時間をなくすためのモック
def test_llm_client_retry_and_failure(mock_wait, mock_anthropic_cls):
    # テストが遅くならないように待機時間をゼロにするダミーを返す
    mock_wait.return_value = MagicMock(return_value=0)

    mock_client = MagicMock()
    # 常に例外を投げるように設定
    mock_client.messages.create.side_effect = Exception("API Error")
    mock_anthropic_cls.return_value = mock_client

    client = LLMClient(api_key="dummy", model_name="claude-opus-5")

    with pytest.raises(CommunicationError):
        client.send("Fail me")
