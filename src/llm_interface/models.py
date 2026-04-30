# models.py

from pydantic import BaseModel, Field

class StructuredResult(BaseModel):
    """
    LLMからの構造化された応答を保持するデータモデル
    """
    formula: str = Field(..., description="The generated mathematical formula as a string.")
    feedback: str = Field(..., description="The reasoning or feedback from the LLM regarding the generated formula.")