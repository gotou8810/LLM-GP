# prompt_manager.py

DEFAULT_SYSTEM_PROMPT = """You are an expert in symbolic regression and industrial process control.
Your task is to propose a mathematical formula to model the target variable in the Tennessee Eastman Process (TEP).

CRITICAL PHYSICAL CAUSALITY RULE:
Do not model simple static correlations caused by feedback control loops (e.g., control actions y(t) directly responding to disturbances).
Instead, model the physical dynamical causality (such as mass balance, energy balance, or pressure accumulation).
To achieve this, we are modeling the temporal change (1-step difference) of the target variable:
$$\Delta y(t) = y(t) - y(t-1) \approx f(X(t-1))$$
Your formula MUST predict this 1-step change Δy(t) based on the state variables X(t-1) at the previous step.

CRITICAL RULES FOR FORMULA SYNTAX (Julia Language):
1.  **Format**: Plain text formula on a single line. No backticks.
2.  **Variables**: Use `xmeas_1` to `xmeas_41` and `xmv_1` to `xmv_11`.
    - **IMPORTANT**: Your target variable is **{target_variable}** ({target_desc}). You MUST NOT use **{target_variable}** as an input in your formula.
3.  **Coefficients**: Use `c[1]`, `c[2]`, etc.
4.  **Operators**: Julia syntax (`^`, `exp`, `log`, `sin`, `cos`).

{mic_variables_section}
PHYSICAL INSTRUCTION:
Please construct a formula using ONLY or primarily the MIC-selected high-relation variables listed above. Ensure the formula represents physical causality (such as mass/energy accumulation or fluid dynamics) rather than accidental feedback loop correlations.

VARIABLE DICTIONARY (TEP):
- xmeas_1: A Feed Flow
- xmeas_2: D Feed Flow
- xmeas_3: E Feed Flow
- xmeas_4: A & C Feed Flow
- xmeas_5: Recycle Flow
- xmeas_6: Reactor Feed Rate
- xmeas_7: Reactor Pressure
- xmeas_8: Reactor Level
- xmeas_9: Reactor Temperature
- xmeas_10: Purge Rate
- xmeas_11: Separator Temperature
- xmeas_12: Separator Level
- xmeas_13: Separator Pressure
- xmeas_14: Separator Underflow
- xmeas_15: Stripper Level
- xmeas_16: Stripper Pressure
- xmeas_17: Stripper Underflow (Product Flow)
- xmeas_18: Stripper Temperature
- xmeas_19: Stripper Steam Flow
- xmeas_20: Compressor Work
- xmeas_21: Reactor Cooling Water Outlet Temperature
- xmeas_22: Separator Cooling Water Outlet Temperature
- xmv_1: D Feed Flow Valve
- xmv_2: E Feed Flow Valve
- xmv_3: A Feed Flow Valve
- xmv_4: A & C Feed Flow Valve
- xmv_5: Compressor Recycle Valve
- xmv_6: Purge Valve
- xmv_7: Separator Underflow Valve
- xmv_8: Stripper Underflow Valve
- xmv_9: Stripper Steam Valve
- xmv_10: Reactor CW Flow Valve
- xmv_11: Condenser CW Flow Valve

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

TEP_VAR_DESCS = {
    "xmeas_1": "A Feed Flow",
    "xmeas_2": "D Feed Flow",
    "xmeas_3": "E Feed Flow",
    "xmeas_4": "A & C Feed Flow",
    "xmeas_5": "Recycle Flow",
    "xmeas_6": "Reactor Feed Rate",
    "xmeas_7": "Reactor Pressure",
    "xmeas_8": "Reactor Level",
    "xmeas_9": "Reactor Temperature",
    "xmeas_10": "Purge Rate",
    "xmeas_11": "Separator Temperature",
    "xmeas_12": "Separator Level",
    "xmeas_13": "Separator Pressure",
    "xmeas_14": "Separator Underflow",
    "xmeas_15": "Stripper Level",
    "xmeas_16": "Stripper Pressure",
    "xmeas_17": "Stripper Underflow (Product Flow)",
    "xmeas_18": "Stripper Temperature",
    "xmeas_19": "Stripper Steam Flow",
    "xmeas_20": "Compressor Work",
    "xmeas_21": "Reactor Cooling Water Outlet Temperature",
    "xmeas_22": "Separator Cooling Water Outlet Temperature",
    "xmv_1": "D Feed Flow Valve",
    "xmv_2": "E Feed Flow Valve",
    "xmv_3": "A Feed Flow Valve",
    "xmv_4": "A & C Feed Flow Valve",
    "xmv_5": "Compressor Recycle Valve",
    "xmv_6": "Purge Valve",
    "xmv_7": "Separator Underflow Valve",
    "xmv_8": "Stripper Underflow Valve",
    "xmv_9": "Stripper Steam Valve",
    "xmv_10": "Reactor CW Flow Valve",
    "xmv_11": "Condenser CW Flow Valve"
}


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
        target_var = kwargs.get("target_variable", "")
        # Resolve target_desc automatically
        kwargs["target_desc"] = kwargs.get("target_desc", TEP_VAR_DESCS.get(target_var.lower(), "Unknown Variable"))
        
        # Build MIC variables section if provided
        mic_vars = kwargs.get("mic_variables", [])
        if mic_vars:
            mic_str = "\n".join([f"- {var}: {TEP_VAR_DESCS.get(var.lower(), 'Unknown Variable')}" for var in mic_vars])
            kwargs["mic_variables_section"] = f"CRITICAL INPUT VARIABLES (MIC-selected high relation):\n{mic_str}\n"
        else:
            kwargs["mic_variables_section"] = ""
            
        return self.system_prompt.format(**kwargs)
