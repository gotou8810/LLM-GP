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