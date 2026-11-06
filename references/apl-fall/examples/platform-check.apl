⍝ Boundary fixture: numeric arrays, negative coordinates, primitives, input/time.
∇ PlatformCheck;input;rects;expectedHeld;expectedPressed;count;ok;unused
 rects←6 9⍴0 ¯8 10 40 24 220 30 40 255 1 60 20 80 40 20 210 100 255 2 60 90 140 90 50 100 230 255 3 200 40 15 0 240 200 30 255 0 200 90 20 20 255 255 255 128 0 250 20 20 20 300 ¯2 80 255
 expectedHeld←0 1 1 0 1 0
 expectedPressed←0 1 0 0 1 0
 count←0
loop: unused←20 140 20 230 240 255 255 RLText 'APL native boundary verified'
 input←RLFrame rects
 ok←(38=⍴input)∧(320=input[3])∧(220=input[4])∧(count+1=input[5])
 ok←ok∧(0.125=input[1])∧(0.125×count+1)=input[2]
 ok←ok∧input[RLHeld[RLLeft]]=expectedHeld[count]
 ok←ok∧input[RLPressed[RLLeft]]=expectedPressed[count]
 ok←ok∧input[0]=count=5
 →ok/good
 unused←RLWrite 'E platform check failed ',(⍕input),⎕UCS 10
 →0
good: count←count+1
 →(count<6)/loop
 unused←RLLog 'PLATFORM PASS: geometry, colors, held/pressed edges, clock, dimensions, finite close'
 unused←RLClose 0
∇
PlatformCheck
)OFF
