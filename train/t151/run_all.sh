#!/bin/bash
# T151 CV 4종 순서대로 (배포 후보 G를 먼저). 저장소 루트에서 실행.
export PYTHONIOENCODING=utf-8
for run in "G 0" "G 1" "W 0" "W 1"; do
  set -- $run
  python train/t151_angle_retrain.py cv $1 $2 > train/t151/cv_$1$2.log 2>&1
  echo "$1$2 exit=$?" >> train/t151/run_all.status
done
echo ALLDONE >> train/t151/run_all.status
