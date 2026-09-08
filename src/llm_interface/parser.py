# parser.py

import json
import re
from pydantic import ValidationError
from .models import StructuredResult
from .exceptions import ParseError

def _parse_expected_signs(raw: str) -> list:
    """
    "+,-,+" や "+1,-1,0" のようなカンマ/空白区切りの符号トークン列を
    [+1, -1, +1] のような整数リストへ変換する。トークンは +/-/0 系列のみ許容。
    """
    tokens = [t.strip() for t in re.split(r"[,\s]+", raw.strip()) if t.strip()]
    signs = []
    for t in tokens:
        if t in ("+", "+1", "positive"):
            signs.append(1)
        elif t in ("-", "-1", "negative"):
            signs.append(-1)
        elif t in ("0", "unconstrained"):
            signs.append(0)
        else:
            raise ValueError(f"Unrecognized sign token: {t!r}")
    return signs


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

        # 2. Try markers (---LAW---, ---EXPECTED_SIGNS---, ---FORMULA---, ---FEEDBACK---)
        law_match = re.search(r"---LAW---\s*(.*?)\s*(?=---EXPECTED_SIGNS---|---FORMULA---|---FEEDBACK---|$)", text, re.DOTALL)
        signs_match = re.search(r"---EXPECTED_SIGNS---\s*(.*?)\s*(?=---FORMULA---|---FEEDBACK---|$)", text, re.DOTALL)
        formula_match = re.search(r"---FORMULA---\s*(.*?)\s*(?=---FEEDBACK---|$)", text, re.DOTALL)
        feedback_match = re.search(r"---FEEDBACK---\s*(.*)", text, re.DOTALL)

        if formula_match:
            formula = formula_match.group(1).strip()
            feedback = feedback_match.group(1).strip() if feedback_match else ""
            law = law_match.group(1).strip() if law_match else ""
            expected_signs = []
            if signs_match:
                try:
                    expected_signs = _parse_expected_signs(signs_match.group(1))
                except ValueError:
                    expected_signs = []  # 符号表記が読めなければ未指定扱い(サインチェックはスキップされる)
            return StructuredResult(formula=formula, feedback=feedback, law=law, expected_signs=expected_signs)

        # 3. Last resort: Try parsing the whole text as JSON
        try:
            data = json.loads(text.strip())
            return StructuredResult(**data)
        except (json.JSONDecodeError, ValidationError) as e:
            raise ParseError(f"Failed to parse response as JSON or markers: {e}") from e
