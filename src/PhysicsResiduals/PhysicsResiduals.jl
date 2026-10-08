module PhysicsResiduals

# ============================================================================
# 反応器冷却水エネルギー収支残差(reactor-cw-energy-residual spec)の薄い集約モジュール。
#
# `NumericalEvaluator.jl`と同型のinclude専用モジュール: 本specに固有の実装は
# すべて`ReactorCwEnergyResidual.jl`に置き、ここでは読み込みとexportのみを行う。
#
# 設計根拠: design.md「Design Decisions」の
# 「ファイル構成は単一ファイル+薄い集約モジュールに留める」を参照。
# Phase 1の既存資産(`VerificationHarness.jl`, `NumericalEvaluator/*`, `TEPDataLoader.jl`)
# は変更しない(読み取り専用の参照のみ)。
# ============================================================================

include("ReactorCwEnergyResidual.jl")

end # module
