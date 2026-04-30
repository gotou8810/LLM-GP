module TEPDataLoader

using Downloads
using RData
using DataFrames

export download_data, load_rdata, extract_variables

"""
指定されたURLからファイルをダウンロードし、ローカルの保存先パスを返します。
ダウンロードに失敗した場合はエラーを発生させます。
"""
function download_data(url::String, dest_path::String)::String
    try
        Downloads.download(url, dest_path)
        return dest_path
    catch e
        # 通信エラーや無効なURLなどの場合は RequestError などがスローされる
        rethrow(e)
    end
end

"""
ローカルの.RDataファイルを読み込み、DataFrameに変換して返します。
ファイルが不正な場合やデータが含まれていない場合はエラーを発生させます。
"""
function load_rdata(file_path::String)::DataFrame
    if !isfile(file_path)
        throw(SystemError("File not found: $file_path"))
    end

    try
        # RData.load は通常 Dict{String, Any} を返す
        objs = RData.load(file_path)
        
        if isempty(objs)
            error("No objects found in .RData file: $file_path")
        end

        # 最初に見つかった DataFrame を返す。
        # DataFrame が見つからない場合は、最初のアレイ状のオブジェクトを DataFrame に変換して返す。
        for (name, val) in objs
            if val isa DataFrame
                return val
            end
        end

        # DataFrame が直接含まれていない場合、最初のオブジェクトを DataFrame に変換を試みる
        first_obj = first(values(objs))
        try
            return DataFrame(first_obj)
        catch
            # DataFrame(first_obj, :auto) を試みる（マトリックスなどの場合）
            if first_obj isa AbstractMatrix || first_obj isa AbstractArray
                return DataFrame(first_obj, :auto)
            else
                error("Could not convert object of type $(typeof(first_obj)) to DataFrame")
            end
        end

    catch e
        if e isa SystemError || e isa ErrorException
            rethrow(e)
        else
            error("Failed to load .RData file: $file_path. Error: $e")
        end
    end
end

"""
DataFrameから指定された変数（列名）のみを抽出した新しいDataFrameを返します。
存在しない変数が指定された場合はエラーを発生させます。
"""
function extract_variables(df::DataFrame, variables::Vector{String})::DataFrame
    # 指定された変数がすべてDataFrameに存在するか確認
    df_col_names = names(df)
    missing_vars = filter(v -> !(v in df_col_names), variables)
    
    if !isempty(missing_vars)
        error("The following variables are not found in the DataFrame: " * join(missing_vars, ", "))
    end

    # 指定された列を抽出（新しいDataFrameを返す）
    return df[:, variables]
end

end # module
