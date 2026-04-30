# parser.py

import json
import re
from pydantic import ValidationError
from .models import StructuredResult
from .exceptions import ParseError

class ResponseParser:
    """
    LLMからのテキスト応答をパースし、StructuredResultオブジェクトに変換するクラス
    """
    def parse(self, text: str) -> StructuredResult:
        # 1. Try JSON block (```json ... ```)
        json_pattern = re.compile(r"```json\s*(\{.*?\})\s*```", re.DOTALL)
        match = json_pattern.search(text)
        
        if match:
            try:
                data = json.loads(match.group(1))
                return StructuredResult(**data)
            except (json.JSONDecodeError, ValidationError):
                pass # Fallback to marker parsing

        # 2. Try markers (---FORMULA--- and ---FEEDBACK---)
        formula_match = re.search(r"---FORMULA---\s*(.*?)\s*(?=---FEEDBACK---|$)", text, re.DOTALL)
        feedback_match = re.search(r"---FEEDBACK---\s*(.*)", text, re.DOTALL)
        
        if formula_match:
            formula = formula_match.group(1).strip()
            feedback = feedback_match.group(1).strip() if feedback_match else ""
            return StructuredResult(formula=formula, feedback=feedback)

        # 3. Last resort: Try parsing the whole text as JSON
        try:
            data = json.loads(text.strip())
            return StructuredResult(**data)
        except (json.JSONDecodeError, ValidationError) as e:
            raise ParseError(f"Failed to parse response as JSON or markers: {e}") from e
