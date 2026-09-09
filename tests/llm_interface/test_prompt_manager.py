import pytest
from src.llm_interface.prompt_manager import PromptManager, DEFAULT_SYSTEM_PROMPT

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

def test_reactive_exclusions_section_included_when_provided():
    pm = PromptManager()
    prompt = pm.generate_prompt(
        target_variable="xmeas_13",
        mic_variables=["xmeas_20"],
        history=[],
        best_formula="(none)",
        best_fitness="(none)",
        reactive_exclusions={"xmv_5": {"ratio": 7.71}, "xmeas_6": {"ratio": 4.20}},
    )
    assert "FORBIDDEN - LIKELY REACTIVE VARIABLES" in prompt
    assert "xmv_5" in prompt
    assert "7.71" in prompt
    assert "xmeas_6" in prompt

def test_reactive_exclusions_section_empty_when_not_provided():
    pm = PromptManager()
    prompt = pm.generate_prompt(
        target_variable="xmeas_13",
        mic_variables=["xmeas_20"],
        history=[],
        best_formula="(none)",
        best_fitness="(none)",
    )
    assert "FORBIDDEN - LIKELY REACTIVE VARIABLES" not in prompt
