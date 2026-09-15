# XMEAS(7)を新しい共通ハーネス(src/VerificationHarness.jl)で再検証する。
# verify_xmeas7_no_ar.jl(個別スクリプト)の結果(Skill=0.0105/0.0111, F1=0.5234)と
# 一致することを確認し、ハーネスの正しさを検証する。
include("src/VerificationHarness.jl")
using .VerificationHarness

result = run_full_verification(
    target = :xmeas_7,
    features = [FeatureSpec(:xmeas_10, 1)],
    label = "XMEAS(7) 質量収支(自己回帰項なし)",
    output_path = "xmeas7_harness_results.json"
)
