# preprocessing.py

import logging
import pandas as pd
import numpy as np

logger = logging.getLogger(__name__)

# TEPデータセットの物理変数(xmeas_*, xmv_*)ではない、ラン/サンプル番号やラベル等の
# ID/メタデータ列。MICスクリーニングの候補から必ず除外する
# (XMEAS(18)探索で "simulationrun", "sample" がMIC上位候補に混入した実例があった)。
NON_PHYSICAL_COLUMNS = {"simulationrun", "sample", "faultnumber"}

# TEPプロセスの各ユニットが持つ「アキュムレーション状態量」（圧力・液位・温度）。
# Mixer/Condenser/Compressorはこれらの状態量を持たない流束通過ノードであり、
# 再循環ループ（Separator->Compressor->Mixer->Reactor、Separator->Stripper->Mixer->Reactor）
# を通じてReactor/Separator/Stripperの3ユニットは相互に直結しているとみなす。
UNIT_STATE_VARIABLES = {
    "Reactor": {"xmeas_7", "xmeas_8", "xmeas_9"},
    "Separator": {"xmeas_11", "xmeas_12", "xmeas_13"},
    "Stripper": {"xmeas_15", "xmeas_16", "xmeas_18"},
}


def compute_forbidden_variables(target_variable: str) -> set:
    """
    ターゲット変数が属するユニットの状態量（圧力・液位・温度）である場合、
    直結する他ユニットの状態量を「相関の罠」を招く禁止候補として返す。
    異常発生時、隣接ユニットの状態量は連動して変化するため、これをモデルの
    入力に使うと異常への追従（=検知の隠蔽）が起きる。
    ターゲットが流量・弁開度・組成・仕事率などフラックス系変数の場合は
    どのユニット状態量にも属さないため、空集合を返す。
    """
    target_variable = target_variable.lower()
    own_unit = None
    for unit, variables in UNIT_STATE_VARIABLES.items():
        if target_variable in variables:
            own_unit = unit
            break

    if own_unit is None:
        return set()

    forbidden = set()
    for unit, variables in UNIT_STATE_VARIABLES.items():
        if unit != own_unit:
            forbidden |= variables
    return forbidden


def calculate_mic_scores(df: pd.DataFrame, target_variable: str, n_select: int = 10) -> list:
    """
    minepyライブラリ（またはscikit-learn互換の相互情報量計算）を用いて、
    TEPの正常データにおいてターゲット変数と他の全変数間のMICスコアを計算し、
    スコアが高い上位N個の変数をリストアップする。
    
    フォールバックとして、scikit-learnの相互情報量、あるいはピアソン相関係数を使用します。
    """
    if target_variable not in df.columns:
        raise ValueError(f"Target variable {target_variable} not found in DataFrame.")

    # 数値列のみを取得
    numeric_cols = df.select_dtypes(include=[np.number]).columns.tolist()
    if target_variable not in numeric_cols:
        raise ValueError(f"Target variable {target_variable} is not numeric.")

    feature_cols = [col for col in numeric_cols
                    if col != target_variable and col.lower() not in NON_PHYSICAL_COLUMNS]
    y = df[target_variable].values
    
    mic_scores = {}

    # 1. minepyライブラリを試みる
    try:
        from minepy import MINE
        logger.info("Using minepy for MIC calculation.")
        for col in feature_cols:
            x = df[col].values
            # 有限値のみをマスク
            mask = np.isfinite(x) & np.isfinite(y)
            if np.sum(mask) < 2:
                mic_scores[col] = 0.0
                continue
            mine = MINE(alpha=0.6, c=15)
            mine.compute_score(x[mask], y[mask])
            mic_scores[col] = mine.mic()

    except ImportError:
        logger.warning("minepy is not installed. Falling back to scikit-learn mutual_info_regression.")
        # 2. scikit-learnの相互情報量を試みる
        try:
            from sklearn.feature_selection import mutual_info_regression
            # NaNやInfを補間・除去
            df_clean = df[numeric_cols].replace([np.inf, -np.inf], np.nan).dropna()
            if len(df_clean) > 0:
                X_clean = df_clean[feature_cols]
                y_clean = df_clean[target_variable]
                mi = mutual_info_regression(X_clean, y_clean)
                for col, score in zip(feature_cols, mi):
                    mic_scores[col] = score
            else:
                for col in feature_cols:
                    mic_scores[col] = 0.0
        except ImportError:
            logger.error("Neither minepy nor scikit-learn is available. Falling back to absolute Pearson correlation.")
            # 3. ピアソンの相関係数（絶対値）で代替
            for col in feature_cols:
                corr = df[col].corr(df[target_variable])
                mic_scores[col] = abs(corr) if not np.isnan(corr) else 0.0

    # スコアの高い順にソート
    sorted_features = sorted(mic_scores.items(), key=lambda x: x[1], reverse=True)
    top_features = [feature for feature, score in sorted_features[:n_select]]
    
    logger.info(f"Top {n_select} MIC selected variables for {target_variable}: {top_features}")
    return top_features

def compute_ccf_asymmetry(df: pd.DataFrame, target_variable: str, candidate_variable: str,
                           max_lag: int = 10, run_col: str = "simulationrun", sample_col: str = "sample") -> dict:
    """
    差分系列での相互相関関数(CCF)の非対称性を計算する。

    候補変数Xが、ターゲットYに対して真に因果的なdriving forceなのか、それとも
    閉ループ制御を介してYの変化に"反応"しているだけなのかを診断する。
    正のラグ側(X(t-k)がY(t)を説明、Xが先行)と負のラグ側(Xが未来=Yに反応)の
    ピーク相関を比較し、負側が優勢なほど、Xが原因ではなく結果である疑いが強い。

    ラン(simulationrun)ごとに独立して差分・相関を計算し平均する
    (ラン境界をまたいで差分を取らない。生の水準ではなく差分系列を使うのは、
    ターゲット自身の自己相関(持続性)だけで見かけ上の対称的な相関が生じるのを防ぐため
    — XMEAS(13)の検証で、この2点を怠って誤った結論に至った実例がある)。
    """
    if run_col not in df.columns or sample_col not in df.columns:
        return {"ratio": float("nan"), "pos_peak": 0.0, "neg_peak": 0.0, "pos_lag": 0, "neg_lag": 0}

    df_sorted = df.sort_values([run_col, sample_col])
    lags = list(range(-max_lag, max_lag + 1))
    sums = np.zeros(len(lags))
    counts = np.zeros(len(lags))

    for _, g in df_sorted.groupby(run_col):
        y = np.diff(g[target_variable].values)
        x = np.diff(g[candidate_variable].values)
        n = len(x)
        for i, k in enumerate(lags):
            if k >= 0:
                xs, ys = (x[: n - k], y[k:]) if k > 0 else (x, y)
            else:
                xs, ys = x[-k:], y[: n + k]
            if len(xs) > 10 and np.std(xs) > 1e-10 and np.std(ys) > 1e-10:
                c = np.corrcoef(xs, ys)[0, 1]
                if not np.isnan(c):
                    sums[i] += c
                    counts[i] += 1

    avg = sums / np.maximum(counts, 1)
    pos_idx = [i for i, k in enumerate(lags) if k > 0]
    neg_idx = [i for i, k in enumerate(lags) if k < 0]
    if not pos_idx or not neg_idx:
        return {"ratio": float("nan"), "pos_peak": 0.0, "neg_peak": 0.0, "pos_lag": 0, "neg_lag": 0}

    pos_i = max(pos_idx, key=lambda i: abs(avg[i]))
    neg_i = max(neg_idx, key=lambda i: abs(avg[i]))
    pos_peak, neg_peak = abs(avg[pos_i]), abs(avg[neg_i])
    ratio = neg_peak / max(pos_peak, 1e-10)

    return {"ratio": ratio, "pos_peak": float(pos_peak), "neg_peak": float(neg_peak),
            "pos_lag": lags[pos_i], "neg_lag": lags[neg_i]}


def filter_reactive_variables(df: pd.DataFrame, target_variable: str, candidate_variables: list,
                               max_lag: int = 10, reactive_threshold: float = 2.0) -> tuple:
    """
    CCF非対称性検定を候補変数リストに適用し、明確に"反応側"(閉ループ制御による交絡の疑いが強い)
    と判定される変数を除外する。compute_forbidden_variables()のトポロジーフィルタと同じ位置づけの、
    候補をLLMに見せる前のハードフィルタ。

    reactive_threshold(既定2.0): 負のラグ側ピークが正のラグ側ピークの2倍以上あれば、
    「ターゲットの変化に反応している」証拠が十分強いとみなし除外する。この閾値未満の
    ratio(対称的〜弱い逆転)は、証拠として決定的とは言えないため除外せず残す
    (実例: xmv_5のratio=7.71やxmeas_6のratio=4.20は除外対象だが、xmeas_20のratio=1.40は
    曖昧なため除外しない)。

    戻り値: (残った変数のリスト, 除外された変数とその診断結果のdict)
    """
    kept = []
    excluded = {}
    for var in candidate_variables:
        if var not in df.columns:
            kept.append(var)
            continue
        diag = compute_ccf_asymmetry(df, target_variable, var, max_lag=max_lag)
        if not np.isnan(diag["ratio"]) and diag["ratio"] >= reactive_threshold:
            excluded[var] = diag
        else:
            kept.append(var)
    return kept, excluded


def transform_to_difference(df: pd.DataFrame, target_variable: str) -> pd.DataFrame:
    """
    ターゲット変数の絶対値 y(t) ではなく、1ステップ間の変化量 Δy(t) = y(t) - y(t-1) を計算し、
    これを新たな目的変数として前処理する。
    時系列のダイナミクスを記述するため、説明変数 X(t-1) に対して Δy(t) = y(t) - y(t-1) を対応させる。
    """
    df_diff = df.copy()
    
    # y(t) - y(t-1) を計算
    y_diff = df_diff[target_variable].diff().values
    
    # 状態 X(t-1) から Δy(t) を予測する形式にシフト
    # 行 0...N-2 (X(t-1)) に対応する 目的変数 dy は 1...N-1 (y(t) - y(t-1))
    # これによりオイラー前進差分 (y(t)-y(t-1)) = f(X(t-1)) の学習を可能にする。
    
    # 目的変数に差分データを代入（2行目以降の差分値を1つ上にスライドさせる）
    df_diff[target_variable] = np.append(y_diff[1:], np.nan)
    
    # 最後の行は説明変数 X(N-1) に対して Δy(N) が存在しないため削除
    df_diff = df_diff.dropna(subset=[target_variable]).reset_index(drop=True)
    
    logger.info(f"Transformed target variable '{target_variable}' to 1-step difference.")
    return df_diff
