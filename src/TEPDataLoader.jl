module TEPDataLoader

using Downloads
using RData
using DataFrames
using Serialization

export download_data, load_rdata, load_rdata_subset, extract_variables

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
.RDataファイルのうち、指定した故障番号(`fault_numbers`)と`simulationRun <= run_max`の
行だけを抽出したDataFrameを返します。抽出結果は`cache_dir`に保存し、2回目以降は
.RDataファイル全体を読み込まずにキャッシュから返します。

`TEP_Faulty_Training.RData`(約5,000,000行)は`load_rdata`で全体を読むと1プロセスで
数GBのメモリを消費するため、一部の故障番号しか使わない処理はこちらを使います。
キャッシュのファイル名には元ファイルのサイズと更新時刻を含めるため、元ファイルが
差し替えられた場合は自動的に作り直されます。初回(キャッシュ作成時)のみ`load_rdata`と
同じメモリを消費します。
"""
function load_rdata_subset(
    file_path::String;
    fault_numbers,
    run_max::Union{Int,Nothing} = nothing,
    cache_dir::String = joinpath(dirname(abspath(file_path)), ".cache")
)::DataFrame
    if !isfile(file_path)
        throw(SystemError("File not found: $file_path"))
    end

    faults = sort(unique(Int.(collect(fault_numbers))))
    st = stat(file_path)
    run_tag = run_max === nothing ? "" : "_run$(run_max)"
    cache_name = string(
        basename(file_path), "_idv", join(faults, "-"), run_tag,
        "_", st.size, "_", round(Int, st.mtime), ".jls"
    )
    cache_path = joinpath(cache_dir, cache_name)

    if isfile(cache_path)
        try
            cached = deserialize(cache_path)
            cached isa DataFrame && return cached
        catch
            # Julia/DataFramesのバージョン違い等で読めないキャッシュは作り直す
        end
    end

    df_all = load_rdata(file_path)
    fault_set = Set(faults)
    mask = [f in fault_set for f in df_all.faultNumber]
    if run_max !== nothing
        mask .&= df_all.simulationRun .<= run_max
    end
    df_subset = df_all[mask, :]

    # 書き込み途中のファイルを別プロセスが読まないよう、一時ファイル経由で置き換える
    mkpath(cache_dir)
    tmp_path = cache_path * ".tmp$(getpid())"
    serialize(tmp_path, df_subset)
    mv(tmp_path, cache_path; force = true)

    return df_subset
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
