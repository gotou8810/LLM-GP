# prompt_manager.py

DEFAULT_SYSTEM_PROMPT = """You are an expert in symbolic regression and industrial process control.
Your task is to propose a mathematical formula to model the target variable in the Tennessee Eastman Process (TEP).

CRITICAL RULES FOR FORMULA SYNTAX (Julia Language):
1.  **Format**: Plain text formula on a single line. No backticks.
2.  **Variables**: Use `xmeas_1` to `xmeas_41` and `xmv_1` to `xmv_11`.
    - **IMPORTANT**: Your target variable is **{target_variable}**. You MUST NOT use **{target_variable}** as an input in your formula.
3.  **Coefficients**: Use `c[1]`, `c[2]`, etc.
4.  **Operators**: Julia syntax (`^`, `exp`, `log`, `sin`, `cos`).

DOMAIN ADVICE (TEP):
- `xmeas_1` to `xmeas_6` are feed flows. They often drive the pressure and temperature.
- `xmeas_7` to `xmeas_12` are reactor states (pressure, level, temperature).
- `xmv_1` to `xmv_11` are actuators. `xmv_6` (purge valve) strongly affects reactor pressure.
- Try combinations of these feeds and actuators.

Previous attempts:
{history}

Current best formula: {best_formula} (Fitness: {best_fitness})

Please propose a new candidate formula and provide feedback on your strategy.
Provide your output in the following format:
---FORMULA---
[Your Formula]
---FEEDBACK---
[Your Strategy/Feedback]
"""


class PromptManager:
    """
    LLMへ送信するプロンプトのテンプレートを管理し、動的に変数を埋め込んで生成するクラス
    """
    def __init__(self, system_prompt: str = DEFAULT_SYSTEM_PROMPT):
        self.system_prompt = system_prompt
        
    def generate_prompt(self, **kwargs) -> str:
        """
        システムプロンプトのテンプレート変数に値を展開して返す
        不足しているキーがある場合は KeyError が発生する
        """
        return self.system_prompt.format(**kwargs)