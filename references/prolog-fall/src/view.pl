:- module(view,[draw/1]).
:- use_module(raylib).
:- use_module(tetromino).

ink(0xe4edf6ff). muted(0x8394aaff). accent(0x6cdec5ff).
color(i,0x58d8e8ff). color(o,0xf4ce60ff). color(t,0xb995f3ff).
color(s,0x79d6a4ff). color(z,0xef8391ff). color(j,0x749eefff). color(l,0xf2ae70ff).
color(none,0x293343ff).

text(S,X,Y,Size) :- ink(C),rl_text(S,X,Y,Size,C).
small(S,X,Y) :- muted(C),rl_text(S,X,Y,16,C).
label(S,X,Y) :- accent(C),rl_text(S,X,Y,16,C).
box(X,Y,W,H) :- rl_rect(X,Y,W,H,0x131c29ff),rl_outline(X,Y,W,H,1,0x273447ff).
fmt(F,Args,X,Y,Size) :- format(atom(S),F,Args),text(S,X,Y,Size).

draw(A) :-
    rl_begin,rl_clear(0x0b111bff),
    rl_rect(0,0,1120,5,0x6cdec5ff),
    text('TETRIS',48,30,36),label('/  LOGIC IN MOTION',210,43),
    small('SWI-PROLOG  /  RAYLIB',808,45),
    draw_left(A),draw_board(A),draw_right(A),
    small('D  demo scene     R  restart     P / ESC  pause',48,756),
    rl_fps(F),fmt('~d FPS',[F],1000,756,16),
    rl_end.

draw_left(A) :-
    S=A.game,box(48,100,236,138),label('HOLD',66,118),
    (S.hold==none -> small('C / SHIFT',96,176) ; mini(S.hold,108,158,22)),
    (S.hold_used==true -> small('used this turn',66,214) ; true),
    label('SCORE',48,272),fmt('~|~`0t~d~8+',[S.score],48,299,32),
    label('LINES',48,364),fmt('~d',[S.lines],48,389,30),
    label('LEVEL',176,364),fmt('~d',[S.level],176,389,30),
    S.active=pose(P,_,_,_),atom_string(P,PS),string_upper(PS,PU),atom_string(PA,PU),
    format(atom(PC),'~w  /  piece ~d',[PA,S.pieces+1]),small(PC,48,441),
    label('PLAY',48,495),
    small('LEFT / RIGHT    move',48,524),small('UP / X    rotate CW',48,551),
    small('Z           rotate CCW',48,578),small('DOWN     soft drop',48,605),
    small('SPACE    hard drop',48,632),small('C / SHIFT       hold',48,659),
    (S.last_clear>0 -> fmt('LAST CLEAR  +~d',[S.last_clear],48,706,18) ; true).

draw_board(A) :-
    S=A.game,rl_rect(324,94,312,612,0x253347ff),
    rl_rect(330,100,300,600,0x101925ff),
    forall((between(0,9,X),between(0,19,Y)),grid_cell(X,Y)),
    forall(member(cell(X,Y,P),S.board),block(P,X,Y,solid)),
    (S.status==playing ->
        landing(S.board,S.active,G,_),draw_pose(G,ghost),
        (A.mode==query -> selected(A.query,C),draw_candidate(C) ; true),
        draw_pose(S.active,solid)
    ; true),
    draw_status(A),
    (A.mode==query -> label('GRAVITY PAUSED  /  FINITE POSE SEARCH',330,720)
    ; A.mode==replay -> label('WITNESS REPLAY  /  TIMERS SUSPENDED',330,720)
    ; label('Q  ask where this piece can reach',330,720)).
grid_cell(X,Y) :- SX is 330+X*30,SY is 100+Y*30,
    rl_outline(SX,SY,30,30,1,0x1b2635ff).
draw_pose(Pose,Style) :-
    Pose=pose(P,_,_,_),pose_cells(Pose,Cells),
    forall((member(X-Y,Cells),Y>=0),block(P,X,Y,Style)).
block(P,X,Y,solid) :-
    color(P,C),SX is 332+X*30,SY is 102+Y*30,
    rl_rect(SX,SY,26,26,C),Top is SY+1,
    rl_rect(SX,Top,26,3,0xffffff40),Edge is SY+23,rl_rect(SX,Edge,26,3,0x00000025).
block(P,X,Y,ghost) :-
    color(P,C),Alpha is (C /\ 0xffffff00) \/ 0x60,
    SX is 333+X*30,SY is 103+Y*30,rl_outline(SX,SY,24,24,1,Alpha).
draw_candidate(none).
draw_candidate(candidate(pose(P,_,_,_),_,_,Cells)) :-
    color(P,C),Alpha is (C /\ 0xffffff00) \/ 0x50,
    forall((member(X-Y,Cells),Y>=0),
        (SX is 331+X*30,SY is 101+Y*30,
         rl_rect(SX,SY,28,28,Alpha),rl_outline(SX,SY,28,28,2,0xf2f7ffff))).
selected(Q,C) :- (Q.candidates=[] -> C=none ; nth0(Q.index,Q.candidates,C)).

draw_status(A) :-
    (A.game.status==game_over -> overlay('GAME OVER','R to start again')
    ; A.mode==paused -> overlay('PAUSED','P / ESC to resume')
    ; true).
overlay(Title,Sub) :-
    rl_rect(330,310,300,140,0x0b111bea),text(Title,362,342,30),small(Sub,366,393).

draw_right(A) :-
    (A.mode==query -> draw_query(A.query)
    ; A.mode==replay -> draw_replay(A)
    ; draw_next(A.game.queue), draw_intro).
draw_next(Queue) :-
    label('NEXT',690,100),
    forall((nth0(I,Queue,P),I<5),
        (Y is 135+I*83,box(690,Y,188,70),mini(P,736,Y+10,16))),
    small('7-BAG RANDOMIZER',690,570).
draw_intro :-
    box(690,616,374,99),label('ASK THE BOARD',708,633),
    small('Q  explore reachable landings',708,659),
    small('D  load a small line-clear puzzle',708,685).
mini(P,X,Y0,Size) :-
    Y is Y0,shape(P,0,Cells),color(P,C),
    forall(member(DX-DY,Cells),
        (SX is X+DX*Size,SY is Y+DY*Size,W is Size-2,rl_rect(SX,SY,W,W,C))).

draw_query(Q) :-
    label('REACHABILITY',690,100),
    small('From the current pose. No clock.',690,128),
    I=Q.info,Millis is I.seconds*1000,
    fmt('~d visited poses / ~1f ms',[I.poses,Millis],690,161,18),
    length(Q.candidates,N),Index is min(N,Q.index+1),
    fmt('Landing ~d / ~d',[Index,N],690,201,26),
    (Q.filter==true -> label('FILTER: CLEARS A LINE',690,240)
    ; small('FILTER: ALL LANDINGS',690,240)),
    selected(Q,C),draw_candidate_details(C),
    box(690,548,374,167),
    small('LEFT / RIGHT    choose landing',708,566),
    small('F    toggle line-clear filter',708,595),
    small('ENTER    replay path + lock',708,624),
    small('Q    return to play',708,653),
    small('Replay suspends gravity and lock time.',708,685).
draw_candidate_details(none) :-
    text('No landing in this filter.',690,287,20),
    small('F shows all reachable landings.',690,320).
draw_candidate_details(candidate(pose(_,R,X,Y),Lines,Path,_)) :-
    length(Path,N),fmt('~d line(s)  /  ~d actions',[Lines,N],690,283,22),
    fmt('origin (~d, ~d)    rotation ~d',[X,Y,R],690,320,17),
    label('WITNESS ACTIONS',690,364),
    maplist(action_symbol,Path,Symbols),atomic_list_concat(Symbols,' ',Atom),
    atom_codes(Atom,Codes),draw_wrapped(Codes,690,395,34,0),
    small('L/R move   v down   + CW   - CCW',690,511).
action_symbol(left,'L'). action_symbol(right,'R'). action_symbol(down,'v').
action_symbol(cw,'+'). action_symbol(ccw,'-').
draw_wrapped([],_,_,_,_).
draw_wrapped(Codes,X,Y,Width,N) :- Codes=[_|_],N<5,
    take_codes(Width,Codes,Line,Rest),atom_codes(Text,Line),small(Text,X,Y),
    NY is Y+21,M is N+1,draw_wrapped(Rest,X,NY,Width,M).
draw_wrapped([_|_],_,_,_,5).
take_codes(0,C,[],C) :- !.
take_codes(_,[],[],[]) :- !.
take_codes(N,[C|Cs],[C|Out],Rest) :- M is N-1,take_codes(M,Cs,Out,Rest).
draw_replay(A) :-
    label('REPLAYING THE WITNESS',690,100),length(A.replay,N),
    fmt('~d actions remaining',[N],690,145,24),
    small('The shared move predicate checks',690,200),
    small('every step against the same board.',690,226),
    small('This is untimed logical reachability.',690,280),
    small('It does not prove real-time feasibility.',690,306),
    small('Q    stop replay and inspect this pose',690,375).
