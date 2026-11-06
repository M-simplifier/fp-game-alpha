⍝ Counts persist so short native key taps can be inspected after the event.
∇ RunInputDiagnostic;input;counts;unused;last;slow
 counts←16⍴0
 last←'No key-down event has arrived yet.'
 slow←0
 input←RLFrame 0 9⍴0
loop: →input[0]/done
 counts←counts+input[RLPressed]
 slow←slow≠input[RLPressed[RLSpace]]
 →(0=+/input[RLPressed])/draw
 last←'FRAME ',(⍕input[5]),'  PRESSED ',⍕input[RLPressed]
 unused←RLLog last
draw: unused←32 28 28 235 242 255 255 RLText 'APL native keyboard diagnostic'
 unused←32 78 18 148 179 212 255 RLText 'Tap R, arrows, Tab. Counters retain every returned key-down bit.'
 unused←32 118 22 235 242 255 255 RLText 'R PRESSES: ',(⍕counts[RLR]),'    TAB PRESSES: ',⍕counts[RLTab]
 unused←32 158 22 235 242 255 255 RLText 'LEFT: ',(⍕counts[RLLeft]),'    RIGHT: ',(⍕counts[RLRight]),'    UP: ',(⍕counts[RLUp]),'    DOWN: ',⍕counts[RLDown]
 unused←32 208 18 235 242 255 255 RLText 'HELD NOW: ',⍕input[RLHeld]
 unused←32 248 18 235 242 255 255 RLText last
 unused←32 298 18 148 179 212 255 RLText 'ORDER: LEFT RIGHT DOWN UP Z X SPACE P R ESC C TAB ENTER A D S'
 unused←32 338 18 148 179 212 255 RLText 'Space toggles a 250 ms APL delay. Delay enabled: ',⍕slow
 unused←32 378 18 235 242 255 255 RLText 'TOTALS: ',⍕counts
 unused←⎕DL 0.25×slow
 input←RLFrame 0 9⍴0
 →loop
done: unused←RLLog 'INPUT FINAL COUNTS ',⍕counts
 unused←RLClose 0
∇
RunInputDiagnostic
)OFF
