⍝ GNU APL 2.0 / native raylib host. Only transport and representation here.
⎕IO←0
⎕PP←12
⎕PW←1000000

∇ z←RLWrite text
 z←text ⎕FIO[23] 1
∇

∇ input←RLFrame rectangles;unused;bytes
 unused←RLWrite 'F ',(⍕(⍴rectangles)[0]),' ',(⍕,rectangles),⎕UCS 10
 unused←⎕FIO[16] 1
 bytes←⎕FIO[8] 0
 input←⍎⎕UCS bytes
∇

∇ z←position RLText text
 z←RLWrite 'T ',(⍕position),'|',text,⎕UCS 10
∇

∇ z←RLLog text
 z←RLWrite 'L ',text,⎕UCS 10
∇

∇ z←RLClose ignored
 z←RLWrite 'X',⎕UCS 10
 z←⎕FIO[16] 1
∇

⍝ Input vector: close dt elapsed width height frame held[16] pressed[16]
RLHeld←6+⍳16
RLPressed←22+⍳16
RLLeft←0 ⋄ RLRight←1 ⋄ RLDown←2 ⋄ RLUp←3
RLZ←4 ⋄ RLX←5 ⋄ RLSpace←6 ⋄ RLP←7
RLR←8 ⋄ RLEscape←9 ⋄ RLC←10 ⋄ RLTab←11
RLEnter←12 ⋄ RLA←13 ⋄ RLD←14 ⋄ RLS←15
