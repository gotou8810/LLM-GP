# prompt_manager.py

DEFAULT_SYSTEM_PROMPT = r"""You are an expert in symbolic regression and industrial process control.
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
    - **CRITICAL — CROSS-UNIT ACCUMULATION-STATE TRAP (Spurious Correlation Trap)**: The TEP process has three units with their own accumulation state variables (pressure/level/temperature): Reactor (`xmeas_7/8/9`), Separator (`xmeas_11/12/13`), and Stripper (`xmeas_15/16/18`). Because of the recycle loops, these three units are all dynamically coupled. If your target is one of these state variables, you MUST NOT use ANY state variable (pressure/level/temperature) belonging to one of the OTHER two units as an input — e.g. if your target is `xmeas_7` (Reactor Pressure), do not use `xmeas_13` (Separator Pressure) or `xmeas_16` (Stripper Pressure); if your target is `xmeas_13` (Separator Pressure), do not use `xmeas_7`/`xmeas_8`/`xmeas_9` (Reactor) or `xmeas_15`/`xmeas_16`/`xmeas_18` (Stripper). During an anomaly (e.g. a leak), a neighboring unit's state variable moves together with the target, so using it as a predictor makes the model track the anomaly instead of flagging it — defeating the purpose of the digital twin.
    - Instead, rely only on physical mass-balance inputs/outputs that cross unit boundaries as genuine flux (flow rates, valve positions, compressor work), such as `xmeas_6` (Reactor Feed Rate), `xmeas_10` (Purge Rate), or `xmv_6` (Purge Valve), along with their lags.
    - **CAUTION FOR COMPOSITION ANALYZER VARIABLES (xmeas_23 to xmeas_41)**: These are chromatograph-sampled mole % values (Reactor Feed / Purge Gas / Product analysis). In the real process they update only once per analyzer cycle (several minutes) and are held constant between samples, so they can look like they explain short-term dynamics through discretization/sampling-delay artifacts rather than genuine physical causality. If you use one of these, justify it via an explicit physical mechanism (e.g., partial-pressure contribution to a shared vapor space via Dalton's law) rather than purely because it is MIC-flagged as statistically informative.
3.  **Coefficients**: Use `c[1]`, `c[2]`, etc.
4.  **Operators**: Julia syntax (`^`, `exp`, `log`, `sin`, `cos`).

METHOD A — LAW COMMITMENT PROTOCOL (mandatory, do this BEFORE writing any formula):
Free-form symbolic regression tends to find combinations that fit the data well but whose "physical explanation" is invented AFTER the fact to justify whatever the optimizer already found — this produces formulas that pass numerical checks but do not actually represent real physics. To prevent this, you must commit to exactly ONE physical law category from the library below BEFORE proposing your formula, and your formula's structure must be a direct instance of that law's canonical form (do not add extra terms "just because" they correlate).

PHYSICAL LAW LIBRARY (pick exactly one per generation):
1. **Mass balance** ($F_{{in}} - F_{{out}}$, accumulation): target is a pressure/level driven by literal flow-rate or valve-position variables that cross the target's own unit boundary (inflow terms get a POSITIVE expected sign on Δy, outflow terms get a NEGATIVE expected sign). A self-damping term on the target's own lagged value (if used) gets a NEGATIVE expected sign (orifice outflow increases with accumulated pressure).
2. **Energy balance / real-gas equation of state** ($PV=nRT$-type): target is a pressure driven by a temperature change of the SAME unit (not a neighboring unit). At constant moles, higher temperature must increase pressure, so the expected sign is POSITIVE. If your fitted/expected direction would be negative, this law does NOT apply here — do not use it just because the temperature variable happens to correlate with the right sign in the data.
3. **Vapor-liquid equilibrium / Dalton's partial pressure law**: target is a pressure driven by a composition (mole-fraction) variable representing the same vapor space. Expected sign is POSITIVE (more of a volatile component -> more partial pressure), and to be a true instance of this law the composition term should be scaled by (not merely added alongside) a legitimate total-pressure reference — a bare unscaled mole-percent sum is a weak, unproven instance of this law and should be flagged as such in your feedback, not claimed as strongly grounded.
4. **Valve/orifice flow characteristic** ($Q = C_v \cdot f(x) \cdot \sqrt{{\Delta P}}$): a flow term is a nonlinear (not linear) function of valve position; sign follows the flow's physical direction (in vs out).
5. **Reaction kinetics (Arrhenius) / consumption**: a mass-balance inflow term should be reduced by a reaction-consumption correction when the target unit is a reactor and the fault/regime involves reactant availability.
6. **Control law (P/PI control)**: target is directly, near-deterministically driven by a manipulated variable via a proportional relationship (used when correlation with one XMV variable is extremely high, e.g. |r| > 0.99).

WARNING — CLOSED-LOOP CONFOUNDING: All TEP data is generated under active base-layer PI control. A naive regression coefficient can reflect the CONTROLLER's response pattern rather than the plant's open-loop physical law, especially for variables that are themselves setpoint-controlled. If your declared law's expected sign is contradicted by the fitted result (see SIGN CHECK feedback below), the correct response is to suspect confounding or reject the law — NOT to invent a new post-hoc story for why the opposite sign "actually still makes sense."

Your response MUST declare, before the formula:
- `---LAW---`: the exact name of ONE law from the numbered list above.
- `---EXPECTED_SIGNS---`: a comma-separated list of `+`, `-`, or `0` (one per coefficient, in the same order as `c[1], c[2], ...` appear in your formula), stating the sign your chosen law THEORETICALLY predicts for each coefficient — decide this BEFORE looking at how well it would fit, not after.

The evaluation pipeline will independently check the fitted coefficients' actual signs against your declared expected_signs and report SIGN CHECK PASSED/FAILED in the next generation's history. A formula that fits well numerically but fails its own sign check has NOT validated its physical claim — treat repeated sign-check failures on the same law as evidence to switch to a different law category, not as something to explain away.

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
- xmeas_23: Reactor Feed Analysis - Component A (mole %)
- xmeas_24: Reactor Feed Analysis - Component B (mole %)
- xmeas_25: Reactor Feed Analysis - Component C (mole %)
- xmeas_26: Reactor Feed Analysis - Component D (mole %)
- xmeas_27: Reactor Feed Analysis - Component E (mole %)
- xmeas_28: Reactor Feed Analysis - Component F (mole %)
- xmeas_29: Purge Gas Analysis - Component A (mole %)
- xmeas_30: Purge Gas Analysis - Component B (mole %)
- xmeas_31: Purge Gas Analysis - Component C (mole %)
- xmeas_32: Purge Gas Analysis - Component D (mole %)
- xmeas_33: Purge Gas Analysis - Component E (mole %)
- xmeas_34: Purge Gas Analysis - Component F (mole %)
- xmeas_35: Purge Gas Analysis - Component G (mole %)
- xmeas_36: Purge Gas Analysis - Component H (mole %)
- xmeas_37: Product Analysis - Component D (mole %)
- xmeas_38: Product Analysis - Component E (mole %)
- xmeas_39: Product Analysis - Component F (mole %)
- xmeas_40: Product Analysis - Component G (mole %)
- xmeas_41: Product Analysis - Component H (mole %)
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
If the history above already shows a SIGN CHECK result for your previous law, take it into account (a FAILED check means switch laws or investigate confounding; do not just relabel the mechanism).
Provide your output in the following format:
---LAW---
[Exactly one law name from the PHYSICAL LAW LIBRARY above]
---EXPECTED_SIGNS---
[Comma-separated +/-/0, one per coefficient c[1], c[2], ... in order, decided from theory BEFORE fitting]
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
    "xmeas_23": "Reactor Feed Analysis - Component A (mole %)",
    "xmeas_24": "Reactor Feed Analysis - Component B (mole %)",
    "xmeas_25": "Reactor Feed Analysis - Component C (mole %)",
    "xmeas_26": "Reactor Feed Analysis - Component D (mole %)",
    "xmeas_27": "Reactor Feed Analysis - Component E (mole %)",
    "xmeas_28": "Reactor Feed Analysis - Component F (mole %)",
    "xmeas_29": "Purge Gas Analysis - Component A (mole %)",
    "xmeas_30": "Purge Gas Analysis - Component B (mole %)",
    "xmeas_31": "Purge Gas Analysis - Component C (mole %)",
    "xmeas_32": "Purge Gas Analysis - Component D (mole %)",
    "xmeas_33": "Purge Gas Analysis - Component E (mole %)",
    "xmeas_34": "Purge Gas Analysis - Component F (mole %)",
    "xmeas_35": "Purge Gas Analysis - Component G (mole %)",
    "xmeas_36": "Purge Gas Analysis - Component H (mole %)",
    "xmeas_37": "Product Analysis - Component D (mole %)",
    "xmeas_38": "Product Analysis - Component E (mole %)",
    "xmeas_39": "Product Analysis - Component F (mole %)",
    "xmeas_40": "Product Analysis - Component G (mole %)",
    "xmeas_41": "Product Analysis - Component H (mole %)",
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
