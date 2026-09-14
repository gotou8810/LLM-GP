# models.py

from typing import List
from pydantic import BaseModel, Field

class StructuredResult(BaseModel):
    """
    LLMからの構造化された応答を保持するデータモデル
    """
    formula: str = Field(..., description="The generated mathematical formula as a string.")
    feedback: str = Field(..., description="The reasoning or feedback from the LLM regarding the generated formula.")
    law: str = Field(default="", description="The single physical law category (from the fixed library) this formula commits to instantiating (Method A). Empty when not using law-constrained mode.")
    expected_signs: List[int] = Field(default_factory=list, description="Theory-derived expected sign (+1/-1/0) for each coefficient c[1], c[2], ... in order of appearance, stated BEFORE fitting. Empty when not using law-constrained mode.")


class JudgeResult(BaseModel):
    """
    「審判」LLM(提案側とは独立に呼び出す)の判定結果。
    数値の再計算は一切行わず、提案側の説明文(feedback)が、渡された確定済みの
    証拠(Skill Score・符号チェック結果など)と矛盾していないかだけを判定する。
    """
    verdict: str = Field(..., description="'PASS' if the narrative is consistent with the evidence, 'FLAG' if it overstates, misrepresents, or ignores the evidence.")
    reasoning: str = Field(..., description="One or two sentences explaining the verdict, citing the specific evidence relied on.")