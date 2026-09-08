import pytest
from src.llm_interface.parser import ResponseParser
from src.llm_interface.models import StructuredResult
from src.llm_interface.exceptions import ParseError

def test_parse_valid_json():
    parser = ResponseParser()
    valid_response = '''
    Here is my proposed formula:
    ```json
    {
        "formula": "c[1] * xmeas_1 + c[2]",
        "feedback": "I added a constant term c[2] to improve the fit."
    }
    ```
    '''
    result = parser.parse(valid_response)
    assert isinstance(result, StructuredResult)
    assert result.formula == "c[1] * xmeas_1 + c[2]"
    assert result.feedback == "I added a constant term c[2] to improve the fit."

def test_parse_invalid_json():
    parser = ResponseParser()
    # JSONフォーマットが壊れている場合
    invalid_response = '''
    ```json
    {
        "formula": "c[1] * xmeas_1 + c[2]",
        "feedback": "Missing quote at the end
    }
    ```
    '''
    with pytest.raises(ParseError):
        parser.parse(invalid_response)

def test_parse_missing_fields():
    parser = ResponseParser()
    # 必須フィールドが欠けている場合
    missing_fields_response = '''
    ```json
    {
        "formula": "c[1] * xmeas_1 + c[2]"
    }
    ```
    '''
    with pytest.raises(ParseError):
        parser.parse(missing_fields_response)

def test_parse_no_json_block():
    parser = ResponseParser()
    # コードブロックがない場合は全体をJSONとしてパース試行するか、エラーにする
    no_block_response = '{"formula": "x", "feedback": "y"}'
    result = parser.parse(no_block_response)
    assert result.formula == "x"

def test_parse_markers_with_law_and_expected_signs():
    parser = ResponseParser()
    response = '''
    ---LAW---
    Mass balance
    ---EXPECTED_SIGNS---
    +, -, 0
    ---FORMULA---
    c[1]*xmeas_6 - c[2]*xmeas_10 + c[3]
    ---FEEDBACK---
    Inflow positive, outflow negative.
    '''
    result = parser.parse(response)
    assert result.law == "Mass balance"
    assert result.expected_signs == [1, -1, 0]
    assert result.formula == "c[1]*xmeas_6 - c[2]*xmeas_10 + c[3]"
    assert result.feedback == "Inflow positive, outflow negative."

def test_parse_markers_without_law_defaults_empty():
    parser = ResponseParser()
    response = '''
    ---FORMULA---
    c[1]*xmeas_1
    ---FEEDBACK---
    simple test
    '''
    result = parser.parse(response)
    assert result.law == ""
    assert result.expected_signs == []

def test_parse_markers_unrecognized_sign_token_falls_back_to_empty():
    parser = ResponseParser()
    response = '''
    ---LAW---
    Mass balance
    ---EXPECTED_SIGNS---
    up, down
    ---FORMULA---
    c[1]*xmeas_1
    ---FEEDBACK---
    test
    '''
    result = parser.parse(response)
    assert result.expected_signs == []
