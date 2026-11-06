:- module(reachability,[reachable_locks/4, replay_path/4, reachable_poses/4,
                         cavity_fixture/3, gap_piece/1, projection_witness/3]).
:- use_module(tetromino).
:- use_module(library(assoc)).
:- use_module(library(clpfd)).

% Finite, cycle-safe BFS over full poses (including orientation). No clock,
% hold or next piece is part of this graph. First successful kick is inherited
% from move_pose/4, exactly as in live play. Paths are shortest in action count.
reachable_poses(Board,Start,Nodes,Count) :-
    ground(Board-Start), legal_pose(Board,Start,_),
    empty_assoc(A0),put_assoc(Start,A0,true,A),
    bfs([node(Start,[])|Tail]-Tail,Board,A,[],Rev,0,Count), reverse(Rev,Nodes).
bfs(Front-Back,_,_,Acc,Acc,N,N) :- Front==Back, !.
bfs([node(P,Path)|Rest]-Tail,B,Seen,Acc,Out,N,Count) :-
    findall(node(Q,[Action|Path]),
            (action(Action),move_pose(B,P,Action,Q)),Next),
    enqueue_new(Next,Seen,Seen1,Tail,NewTail),
    M is N+1, bfs(Rest-NewTail,B,Seen1,[node(P,Path)|Acc],Out,M,Count).
action(left). action(right). action(down). action(cw). action(ccw).
enqueue_new([],S,S,T,T).
enqueue_new([node(P,Path)|Ns],S0,S,T0,T) :-
    (get_assoc(P,S0,_) -> S1=S0,T1=T0
    ; put_assoc(P,S0,true,S1), T0=[node(P,Path)|T1]),
    enqueue_new(Ns,S1,S,T1,T).

reachable_locks(B,Start,Candidates,info{poses:Count,landings:N,seconds:Seconds}) :-
    get_time(T0), reachable_poses(B,Start,Nodes,Count),
    findall(Cells-candidate(P,Lines,Path,Cells),
        (member(node(P,Rev),Nodes),supported(B,P),
         lock_board(B,P,_,Lines,_),pose_cells(P,Raw),sort(Raw,Cells),reverse(Rev,Path)),All),
    % Physical-cell quotient only AFTER closure. Keep a witnessed representative.
    keysort(All,Sorted), unique_cells(Sorted,Unique),
    findall(Key-C,(member(C,Unique),C=candidate(pose(_,_,X,Y),L,Path,_),
                   length(Path,Len),Neg is -L,Key=key(Neg,Len,X,Y)),Ranked),
    keysort(Ranked,Ranked1), pairs_values(Ranked1,Candidates),
    length(Candidates,N), get_time(T1),Seconds is T1-T0.
unique_cells([],[]).
unique_cells([K-C|Rest],[C|Cs]) :- drop_key(Rest,K,More),unique_cells(More,Cs).
drop_key([K-_|Rest],K,More) :- !,drop_key(Rest,K,More).
drop_key(Rest,_,Rest).

replay_path(_,P,[],P).
replay_path(B,P,[A|As],End) :- move_pose(B,P,A,Q),replay_path(B,Q,As,End).

% Closed 2x2 pocket: O at (X=3,Y=18) fits and is supported, but the
% roof above it prevents entry. No row is already full in this fixture.
cavity_fixture(B,pose(o,0,3,-1),pose(o,0,3,18)) :-
    findall(cell(X,17,j),between(3,6,X),Roof),
    findall(cell(X,Y,l),(between(18,19,Y),between(0,9,X),X\=4,X\=5),Sides),
    append(Roof,Sides,B).

% Unknown kind, same piece_cells/5 relation. Order is an explicit API detail.
gap_piece(P) :- piece_cells(P,0,0,0,[1-0,0-1,1-1,2-1]).

% Two independently recognizable predecessors map to the empty board when
% rows are removed. This proves non-injectivity of BOARD PROJECTION only.
projection_witness(A,B,Out) :-
    findall(cell(X,19,j),between(0,9,X),A),
    findall(cell(X,Y,l),(between(18,19,Y),between(0,9,X)),B),
    A\==B,clear_rows(A,Out,[19]),clear_rows(B,Out,[18,19]).
