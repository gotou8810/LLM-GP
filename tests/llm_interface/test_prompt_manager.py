import pytest
from src.llm_interface.prompt_manager import PromptManager

def test_prompt_manager_initialization():
    pm = PromptManager(system_prompt="You are a helpful assistant. Dataset: {dataset_info}")
    assert "You are a helpful assistant" in pm.system_prompt

def test_prompt_generation():
    pm = PromptManager(system_prompt="You are an expert. Context: {context}")
    
    # テンプレート変数を渡して生成
    prompt = pm.generate_prompt(context="TEP data with 55 variables")
    assert "TEP data with 55 variables" in prompt
    assert "You are an expert." in prompt

def test_prompt_generation_missing_variables():
    pm = PromptManager(system_prompt="Context: {context}, Data: {data}")
    
    # 必要な変数が不足している場合はKeyError等がスローされること
    with pytest.raises(KeyError):
        pm.generate_prompt(context="Only context provided")
