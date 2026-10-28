#!/bin/bash
# run_all.sh(CV 4종)가 끝난 뒤 G1 전량 학습 + ONNX + 벤치. 저장소 루트에서 실행.
export PYTHONIOENCODING=utf-8
until grep -q ALLDONE train/t151/run_all.status 2>/dev/null; do sleep 30; done
python train/t151_angle_retrain.py final > train/t151/final.log 2>&1
echo "final exit=$?" >> train/t151/run_all.status
python train/t151_angle_retrain.py bench > train/t151/bench.log 2>&1
echo "bench exit=$?" >> train/t151/run_all.status
