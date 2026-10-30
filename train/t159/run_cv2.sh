#!/bin/bash
# T159 CV 후보 2: ord224 + 큰 각 가중(bigw 2, ≥25도) + 좌우반전 일관성(cons 0.5). 저장소 루트에서 실행.
export PYTHONIOENCODING=utf-8
python train/t159_train.py cv ordbw224 --img 224 --threads 2 --cons 0.5 --bigw 2 --big_deg 25 > train/t159/cv_ordbw224.log 2>&1
echo "ordbw224 exit=$?" >> train/t159/run.status
