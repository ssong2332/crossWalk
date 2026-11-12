import cv2,sys,datetime
v=sys.argv[1]; end=datetime.datetime.strptime(sys.argv[2],'%H:%M:%S')
cap=cv2.VideoCapture(v)
n=cap.get(cv2.CAP_PROP_FRAME_COUNT); fps=cap.get(cv2.CAP_PROP_FPS)
# find duration via last frame msec
cap.set(cv2.CAP_PROP_POS_FRAMES,n-1); cap.read(); dur=cap.get(cv2.CAP_PROP_POS_MSEC)/1000
if dur<=0: dur=n/fps
start=end-datetime.timedelta(seconds=dur)
print('dur',dur,'start',start.time())
import numpy as np
for spec in sys.argv[3:]:
    a,b,step=spec.split(',')
    ta=datetime.datetime.strptime(a,'%H:%M:%S'); tb=datetime.datetime.strptime(b,'%H:%M:%S')
    imgs=[]; t=ta
    while t<=tb:
        cap.set(cv2.CAP_PROP_POS_MSEC,(t-start).total_seconds()*1000)
        ok,f=cap.read()
        if ok:
            f=cv2.resize(f,(180,int(f.shape[0]*180/f.shape[1])))
            cv2.putText(f,t.strftime('%M:%S'),(5,25),cv2.FONT_HERSHEY_SIMPLEX,0.8,(0,0,255),2)
            imgs.append(f)
        t+=datetime.timedelta(seconds=float(step))
    rows=[np.hstack(imgs[i:i+8]+[np.zeros_like(imgs[0])]*(8-len(imgs[i:i+8]))) for i in range(0,len(imgs),8)]
    cv2.imwrite(f"sheet_{a.replace(':','')}.jpg",np.vstack(rows))
