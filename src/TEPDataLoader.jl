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
        # 通信エラーや無効なURLなどの場合は RequestError がスローされる
        if e isa RequestError
            error_msg = "Failed to download data from $url: $(e.message)"
            @error error_msg
            rethrow(e)
        else
            @error "Unexpected error during download: $e"
            rethrow(e)
        end
    end
end

"""
ローカルの.RDataファイルを読み込み、DataFrameに変換して返します。
ファイルが不正な場合はエラーを発生させます。
"""
function load_rdata(file_path::String)::DataFrame
    # To be implemented
    return DataFrame()
end

"""
DataFrameから指定された変数（列名）のみを抽出した新しいDataFrameを返します。
存在しない変数が指定された場合はエラーを発生させます。
"""
function extract_variables(df::DataFrame, variables::Vector{String})::DataFrame
    # To be implemented
    return DataFrame()
end

end # module
