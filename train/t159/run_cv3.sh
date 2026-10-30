#!/bin/bash
# T159 CV 후보 3: ord224 + 회전 보강 ±30(기본 ±15). 큰 각 줄무늬 축 혼동 대응. 저장소 루트에서 실행.
export PYTHONIOENCODING=utf-8
python train/t159_train.py cv ordrot224 --img 224 --threads 2 --rot 30 > train/t159/cv_ordrot224.log 2>&1
echo "ordrot224 exit=$?" >> train/t159/run.status
