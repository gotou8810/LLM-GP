# parser.jl

const ALLOWED_FUNCS = Set([:+, :-, :*, :/, :^, :sin, :cos, :tan, :exp, :log, :log10, :sqrt, :abs])

"""
AST（Expr）をトラバースし、許可されていない関数呼び出しがないかチェックし、
変数アクセス（XMEAS(1)など）を `row["XMEAS(1)"]` に置き換えます。
"""
function validate_and_transform_ast(expr::Expr, var_names::Vector{String})
    if expr.head == :call
        func_name = expr.args[1]
        
        # XMEAS(1) のような変数表現を処理する
        # LLMが XMEAS(1) または xmeas_1 のように関数呼び出しの形で生成した場合を想定
        if func_name isa Symbol && (string(func_name) == "XMEAS" || string(func_name) == "xmeas") && length(expr.args) == 2
            idx = expr.args[2]
            var_name = "xmeas_$idx"
            if var_name in var_names
                return :(row[$var_name])
            else
                error("Variable $var_name not found in var_names.")
            end
        end
        
        # 通常の関数呼び出しのチェック
        if !(func_name in ALLOWED_FUNCS)
            error("Function $func_name is not allowed.")
        end
        
        # 引数を再帰的に処理
        new_args = Any[func_name]
        for i in 2:length(expr.args)
            push!(new_args, validate_and_transform_ast(expr.args[i], var_names))
        end
        return Expr(:call, new_args...)
    elseif expr.head == :ref && expr.args[1] == :c
        # c[1] などの係数アクセスはそのまま許可
        return expr
    else
        # その他のExpr（ブロックなど）も再帰的に処理
        new_expr = copy(expr)
        for i in 1:length(new_expr.args)
            new_expr.args[i] = validate_and_transform_ast(new_expr.args[i], var_names)
        end
        return new_expr
    end
end

# Symbolや数値などのリーフノードの処理
function validate_and_transform_ast(x::Symbol, var_names::Vector{String})
    str_x = string(x)
    if str_x in var_names
        return :(row[$str_x])
    elseif x == :c
        return x
    else
        # 定数（piなど）は評価時に解決されるが、安全のため未定義変数はエラーにしてもよい
        return x
    end
end

function validate_and_transform_ast(x::Any, var_names::Vector{String})
    # 数値リテラルなど
    return x
end

"""
AST内の `c[i]` の最大インデックスをカウントし、係数の数を返します。
"""
function count_coefficients(expr::Expr)::Int
    max_idx = 0
    if expr.head == :ref && expr.args[1] == :c
        idx = expr.args[2]
        if idx isa Int
            max_idx = max(max_idx, idx)
        end
    end
    for arg in expr.args
        if arg isa Expr
            max_idx = max(max_idx, count_coefficients(arg))
        end
    end
    return max_idx
end

function count_coefficients(x::Any)::Int
    return 0
end

"""
数式文字列と、データセットの変数名リストを受け取り、
(eval_func, num_coeffs, ast) のタプルを返す。
"""
function parse_formula_full(formula_str::String, var_names::Vector{String})
    ast = Meta.parse(formula_str)
    
    if ast isa Expr && ast.head == :block && length(filter(x -> !(x isa LineNumberNode), ast.args)) > 1
        error("Multiple expressions are not allowed.")
    end

    transformed_ast = validate_and_transform_ast(ast, var_names)
    num_coeffs = count_coefficients(ast)
    
    func_expr = :( (c, row) -> $transformed_ast )
    func = eval(func_expr)
    
    return (func, num_coeffs, ast)
end

"""
旧インターフェース維持用
"""
function parse_formula(formula_str::String, var_names::Vector{String})::Function
    f, _, _ = parse_formula_full(formula_str, var_names)
    return f
end
