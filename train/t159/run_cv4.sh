#!/bin/bash
# T159 CV 후보 4·5: 시야 = 화면 전체(크롭 1.0, 앱 입력 변경 — AngleEstimator.cropRatio 1.0). 저장소 루트에서 실행.
# 224 캐시를 먼저 한 번 만든 뒤(두 프로세스가 같은 파일을 동시에 쓰지 않게) 두 후보를 2스레드씩 동시에.
export PYTHONIOENCODING=utf-8
python -c "import sys; sys.path.insert(0,'train'); sys.argv=['x','cv','x','--crop','1.0']; import t159_train as m, t151_angle_retrain as t151; m.OPT['crop']=1.0; ex,t1=t151.load_all(); m.build_cache(ex+t1,224)" > train/t159/cache224.log 2>&1
echo "cache224 exit=$?" >> train/t159/run.status
(python train/t159_train.py cv full224 --img 224 --threads 2 --crop 1.0 > train/t159/cv_full224.log 2>&1; echo "full224 exit=$?" >> train/t159/run.status) &
(python train/t159_train.py cv fullbw224 --img 224 --threads 2 --crop 1.0 --cons 0.5 --bigw 2 --big_deg 25 > train/t159/cv_fullbw224.log 2>&1; echo "fullbw224 exit=$?" >> train/t159/run.status) &
wait
