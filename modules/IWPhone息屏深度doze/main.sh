#!/bin/sh
(
# 等待初始化完成
echo "<<---------start iwphone_server----------->>" >> log.txt
echo "<<------深度doze------->>" >>log.txt
while true
do
# 简易退出方法回调（作者脑子太笨想不出好办法）
if [ -f "end" ]; then
  echo "<<---------close iwphone_server----------->>" >> log.txt
  exit
else
  # echo "文件不存在"
    # 获取屏幕状态
    screen_status=$(dumpsys window | grep mScreenOnFully | cut -d= -f2)
           
   # 检查屏幕状态
if [ "$screen_status" = "true mScreenOnEarly" ];  then    # 屏幕亮起，退出doze
    # echo "screen_on"          
    if [ $(dumpsys deviceidle enabled) = "1" ]; then    
      dumpsys deviceidle unforce
      # 直接退出deep状态进入乖巧状态
    sleep 2
    fi
    # 处理深度休眠
   if (( i < 5 )); then
      let i++
   fi    
else
    # 屏幕关闭，执行doze
        # 如果多次检测为息屏则进入深度休眠模式
    # echo "screen_off"  
    if (( i > -5 )); then
      let i--
   fi        
fi

if [ -f "Aggressive" ]; then
  deeps="180"
  unforces="30"
  dozes="6"
fi

if [ -f "Moderate" ]; then
  deeps="240"
  unforces="40"
  dozes="8"
fi

if [ -f "Gentle" ]; then
  deeps="360"
  unforces="60"
  dozes="12"
fi




if (( -3 < i < 3 )); then

 sleep $dozes

fi

# 处理深度休眠
if (( i < -3 )); then    
    # 如果多次检测为息屏则进入深度休眠模式
if [ $(dumpsys deviceidle enabled) = "0" ]; then
    echo "doze true" >> log.txt 
    dumpsys deviceidle enable
        sleep 2 
    dumpsys deviceidle step
        sleep 2   
    dumpsys deviceidle force-idle
fi
# 改为三分钟进行一次检测 
    sleep $deeps     
fi

if (( i > 3 )); then
    # 如果多次检测为亮屏则退出深度休眠模式
   if [ $(dumpsys deviceidle enabled) = "1" ]; then      
      echo "doze false" >> log.txt     
       # dumpsys deviceidle unforce
       # sleep 2
       dumpsys deviceidle disable
    fi
    # echo "doze false" >> log.txt
    # 改为半分钟进行一次检测    
    sleep $unforces
fi
    
fi
done

)&




# 作者 皓thirteen
# 脚本 息屏自动进入深度doze
 # 备注 当设备处于亮屏状态时会每半分钟进行一次检测，当设备处于息屏后，经过大约三次检测（此时每次检测间隔半分钟总共约一分半）后进入深度doze状态，当设备亮屏后会继续进行大约三次检测（此时每次检测间隔三分钟大约需要10分钟）后退出深度doze状态
 # i变量代表着缓冲权重