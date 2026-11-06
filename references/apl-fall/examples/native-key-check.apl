∇ NativeKeyCheck;input;count;ok;unused;expectedR;expectedLeft
 count←0
 expectedR←0 1 0 0 0 0
 expectedLeft←0 0 0 1 0 0
loop: input←RLFrame 0 9⍴0
 ok←input[RLPressed[RLR]]=expectedR[count]
 ok←ok∧input[RLPressed[RLLeft]]=expectedLeft[count]
 ok←ok∧0=input[RLHeld[RLR]]+input[RLHeld[RLLeft]]
 →ok/good
 unused←RLWrite 'E native key check failed ',(⍕input),⎕UCS 10
 →0
good: count←count+1
 →(count<6)/loop
 unused←RLLog 'NATIVE KEY PASS: same-poll R and Left down/up reach GLFW queue, held=0, pressed once'
 unused←RLClose 0
∇
NativeKeyCheck
)OFF
