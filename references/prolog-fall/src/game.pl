:- module(game,[new_game/2, demo_game/2, act/3, tick/3,
                fill_queue/4, take_piece/5, demo_board/1, game_valid/1]).
:- use_module(tetromino).

new_game(Seed,S) :-
    fill_queue([],Seed,Q,NextSeed), take_piece(Q,NextSeed,P,Queue,RS),
    S=game{board:[],active:pose(P,0,3,-1),queue:Queue,seed:RS,
           hold:none,hold_used:false,score:0,lines:0,level:1,status:playing,
           gravity:0.0,lock:0.0,resets:0,last_clear:0,pieces:0}.
demo_game(Seed,S) :-
    new_game(Seed,S0), demo_board(B),
    S=S0.put(_{board:B,active:pose(t,0,3,-1)}).
demo_board(B) :-
    findall(cell(X,19,j),(between(0,9,X),\+between(3,5,X)),Bottom),
    append(Bottom,[cell(0,18,j),cell(1,18,j),cell(0,17,j),
                   cell(8,18,l),cell(9,18,l),cell(9,17,l)],B).

% Local explicit PRNG: replay is independent of Prolog's global random state.
random_index(N,S,I,T) :- T is (1664525*S+1013904223) mod 4294967296, I is T mod N.
bag(Seed,Bag,Next) :- bag_([i,o,t,s,z,j,l],Seed,Bag,Next).
bag_([],S,[],S).
bag_(Pool,S,[P|Ps],Out) :-
    Pool=[_|_], length(Pool,N), random_index(N,S,I,T),
    nth0(I,Pool,P,Rest), bag_(Rest,T,Ps,Out).
fill_queue(Q,S,Out,Next) :-
    length(Q,N), (N>=7 -> Out=Q,Next=S
    ; bag(S,B,T),append(Q,B,QQ),fill_queue(QQ,T,Out,Next)).
take_piece(Q,S,P,Out,Next) :- Q=[P|Rest], fill_queue(Rest,S,Out,Next).

act(S,_,S) :- S.status\==playing, !.
act(S,hold,Out) :- !, hold_piece(S,Out).
act(S,hard_drop,Out) :- !,
    landing(S.board,S.active,L,D), Score is S.score+2*D,
    lock_piece(S.put(_{active:L,score:Score}),Out).
act(S,A,Out) :-
    ( move_pose(S.board,S.active,A,P) ->
        move_clocks(S,A,Lock,Resets),
        (A==down -> Score is S.score+1 ; Score=S.score),
        Out=S.put(_{active:P,lock:Lock,resets:Resets,score:Score})
    ; Out=S ).
move_clocks(S,down,0.0,R) :- !, R=S.resets.
move_clocks(S,_,Lock,R) :-
    ( supported(S.board,S.active), S.resets<15 -> Lock=0.0,R is S.resets+1
    ; Lock=S.lock,R=S.resets ).

hold_piece(S,S) :- S.hold_used==true, !.
hold_piece(S,Out) :-
    S.active=pose(Current,_,_,_),
    (S.hold==none -> take_piece(S.queue,S.seed,P,Q,RS)
    ; P=S.hold,Q=S.queue,RS=S.seed),
    spawn_status(S.board,pose(P,0,3,-1),Status),
    Out=S.put(_{active:pose(P,0,3,-1),hold:Current,hold_used:true,
                 queue:Q,seed:RS,status:Status,gravity:0.0,lock:0.0,resets:0}).

tick(S,_,S) :- S.status\==playing, !.
tick(S,Dt,Out) :-
    D is max(0.0,min(0.05,Dt)), G is S.gravity+D,
    Interval is max(0.055,0.75*0.82**(S.level-1)),
    (G>=Interval ->
        (move_pose(S.board,S.active,down,P) -> Lock=0.0 ; P=S.active,Lock=S.lock),
        NG is G-Interval, T=S.put(_{active:P,gravity:NG,lock:Lock})
    ; T=S.put(gravity,G)),
    (supported(T.board,T.active) ->
        L is T.lock+D,
        (L>=0.5 -> lock_piece(T,Out) ; Out=T.put(lock,L))
    ; Out=T.put(lock,0.0)).

lock_piece(S,Out) :-
    ( lock_board(S.board,S.active,B,N,_) ->
        line_value(N,V), Score is S.score+V*S.level, Lines is S.lines+N,
        Level is 1+Lines//10, Pieces is S.pieces+1,
        take_piece(S.queue,S.seed,P,Q,RS), Spawn=pose(P,0,3,-1),
        spawn_status(B,Spawn,Status),
        Out=S.put(_{board:B,active:Spawn,queue:Q,seed:RS,hold_used:false,
                    score:Score,lines:Lines,level:Level,status:Status,
                    gravity:0.0,lock:0.0,resets:0,last_clear:N,pieces:Pieces})
    ; Out=S.put(status,game_over)).
spawn_status(B,P,Status) :- (legal_pose(B,P,_) -> Status=playing ; Status=game_over).
line_value(0,0). line_value(1,100). line_value(2,300). line_value(3,500). line_value(4,800).

game_valid(S) :-
    is_dict(S,game), ground(S),
    forall(member(cell(X,Y,P),S.board),(between(0,9,X),between(0,19,Y),piece(P))),
    findall(X-Y,member(cell(X,Y,_),S.board),XY),sort(XY,U),same_length(XY,U),
    (S.status==playing -> legal_pose(S.board,S.active,_) ; S.status==game_over),
    maplist(piece,S.queue), S.score>=0,S.lines>=0,S.level=:=1+S.lines//10.
