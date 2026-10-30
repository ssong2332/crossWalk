#!/bin/bash
# T159 CV: 순서형 224(앱 입력 동일) / 288(입력 변경)을 2스레드씩 동시에. 저장소 루트에서 실행.
export PYTHONIOENCODING=utf-8
(python train/t159_train.py cv ord224 --img 224 --threads 2 > train/t159/cv_ord224.log 2>&1; echo "ord224 exit=$?" >> train/t159/run.status) &
(python train/t159_train.py cv ord288 --img 288 --threads 2 > train/t159/cv_ord288.log 2>&1; echo "ord288 exit=$?" >> train/t159/run.status) &
wait
echo ALLDONE >> train/t159/run.status
