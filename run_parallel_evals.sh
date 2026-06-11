#!/bin/bash
JULIA="/opt/bin/julia --project=."
CLI="src/NumericalEvaluator/cli.jl"

echo "Evaluating XMEAS(13)..."
$JULIA $CLI < eval_input_xmeas13.json > res_xmeas13.json &

echo "Evaluating XMEAS(9)..."
$JULIA $CLI < eval_input_xmeas9.json > res_xmeas9.json &

echo "Evaluating XMEAS(12)..."
$JULIA $CLI < eval_input_xmeas12.json > res_xmeas12.json &

wait
echo "All evaluations finished."
