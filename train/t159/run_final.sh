#!/bin/bash
# T159 최종: fullbw224 설정으로 전량(1,331장) 학습 + ONNX(model/t159/, git 제외). 저장소 루트에서 실행.
# 시야 = 화면 전체(크롭 1.0) — 앱 AngleEstimator.cropRatio를 1.0으로 바꿔야 하는 입력 변경.
export PYTHONIOENCODING=utf-8
python train/t159_train.py final fullbw224 --img 224 --threads 6 --crop 1.0 --cons 0.5 --bigw 2 --big_deg 25 > train/t159/final_fullbw224.log 2>&1
echo "final fullbw224 exit=$?" >> train/t159/run.status
