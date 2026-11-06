:- module(main,[main/0]).
:- use_module(game).
:- use_module(tetromino).
:- use_module(reachability).
:- use_module(raylib).
:- use_module(view).
:- use_module(library(http/json)).
:- initialization(main,main).

main :-
    current_prolog_flag(argv,Args),options(Args,Opts),
    (Opts.demo==true -> demo_game(Opts.seed,G) ; new_game(Opts.seed,G)),
    A0=app{game:G,mode:play,query:none,replay:[],replay_time:0.0,
           direction:none,held:0.0,next_repeat:0.16,soft:0.0,
           audit:_{queries:0,filters:0,cycles:0,selection_changes:0,
                   replays_started:0,replays_completed:0,replay_moves:0},
           frames:0,work_sum:0.0,work_max:0.0,dt_sum:0.0,opts:Opts},
    setup_call_cleanup(rl_open(1120,800,'Tetris / Logic in Motion'),
        ((Opts.query==true -> open_query(A0,A) ; A=A0),loop(A)),rl_close).

options(Args,O) :-
    get_time(T),Seed is floor(T*1000) mod 4294967296,
    Default=opts{seed:Seed,demo:false,query:false,smoke:0,screenshot:'',report:'',autoplay:false},
    options_(Args,Default,O).
options_([],O,O).
options_(['--demo'|As],O,R) :- !,options_(As,O.put(demo,true),R).
options_(['--query'|As],O,R) :- !,options_(As,O.put(query,true),R).
options_(['--autoplay'|As],O,R) :- !,options_(As,O.put(autoplay,true),R).
options_(['--seed',V|As],O,R) :- !,atom_number(V,N),options_(As,O.put(seed,N),R).
options_(['--smoke',V|As],O,R) :- !,atom_number(V,N),N>0,options_(As,O.put(smoke,N),R).
options_(['--screenshot',V|As],O,R) :- !,options_(As,O.put(screenshot,V),R).
options_(['--report',V|As],O,R) :- !,options_(As,O.put(report,V),R).
options_([A|_],_,_) :- throw(error(domain_error(command_line_option,A),_)).

loop(A) :-
    (rl_should_close -> finish(A)
    ; rl_time(Start),rl_dt(Raw),D is max(0.0,min(0.05,Raw)),
      update(A,D,B),draw(B),rl_time(End),
      F is B.frames+1,W is End-Start,Sum is B.work_sum+W,Max is max(B.work_max,W),
      DS is B.dt_sum+Raw,
      C=B.put(_{frames:F,work_sum:Sum,work_max:Max,dt_sum:DS}),
      (C.opts.smoke>0,F>=C.opts.smoke ->
          (C.opts.screenshot\=='' -> rl_capture(C.opts.screenshot) ; true),finish(C)
      ; loop(C))).
finish(A) :-
    F is max(1,A.frames),Avg is A.work_sum/F,Delta is A.dt_sum/F,
    (A.query==none -> Q=none ; Q=A.query.info),
    Report=_{frames:A.frames,mean_frame_seconds:Delta,mean_work_and_pacing_seconds:Avg,
             max_work_and_pacing_seconds:A.work_max,status:A.game.status,
             score:A.game.score,lines:A.game.lines,pieces:A.game.pieces,query:Q,
             mode:A.mode,ui_events:A.audit},
    (A.opts.report\=='' -> setup_call_cleanup(open(A.opts.report,write,S),json_write_dict(S,Report,[width(100)]),close(S)) ; true),
    (A.opts.smoke>0 -> json_write_dict(current_output,Report,[width(100)]),nl ; true).

update(A,D,Out) :-
    (pressed(A,82) -> new_game(A.opts.seed,G),reset_ui(A,G,Out)
    ; pressed(A,68) -> demo_game(A.opts.seed,G),reset_ui(A,G,Out)
    ; pressed(A,81) ->
        (A.mode==query -> Out=A.put(mode,play)
        ; A.game.status==playing -> open_query(A,Out) ; Out=A)
    ; (pressed(A,80);pressed(A,256)) -> toggle_pause(A,Out)
    ; A.mode==query -> query_keys(A,Out)
    ; A.mode==replay -> replay_tick(A,D,Out)
    ; A.mode==paused -> Out=A
    ; \+rl_focused,A.opts.smoke=:=0 -> Out=A.put(mode,paused)
    ; play_update(A,D,Out)).

% Smoke injection enters the same command dispatch as rl_pressed/1. It tests
% application wiring without claiming that a physical key reached the window.
pressed(A,Key) :-
    (rl_pressed(Key) -> true
    ; A.opts.autoplay==true,A.opts.query==true,A.mode==query,
      scripted_query_key(A.frames,Key)).
scripted_query_key(8,262).      % next of the 34 candidates
scripted_query_key(12,263).     % previous candidate
scripted_query_key(16,70).      % then filter to line-clearing candidates
scripted_query_key(20,257).     % Enter: witness replay then lock
audit(A,Key,Out) :- get_dict(Key,A.audit,N),M is N+1,Out=A.put(audit,A.audit.put(Key,M)).
reset_ui(A,G,Out) :-
    Out=A.put(_{game:G,mode:play,query:none,replay:[],replay_time:0.0,
                direction:none,held:0.0,next_repeat:0.16,soft:0.0}).
toggle_pause(A,Out) :-
    (A.mode==paused -> Out=A.put(mode,play)
    ; A.mode==play -> Out=A.put(mode,paused)
    ; Out=A).

play_update(A,D,Out) :-
    horizontal(A,D,B),soft_drop(B,D,C),
    findall(Action,(key_action(Key,Action),rl_pressed(Key)),Actions),
    apply_actions(Actions,C.game,G0),
    scripted(C,G0,G),tick(G,D,Next),Out=C.put(game,Next).
apply_actions([],S,S).
apply_actions([A|As],S,Out) :- act(S,A,N),apply_actions(As,N,Out).
key_action(265,cw). key_action(88,cw). key_action(90,ccw).
key_action(32,hard_drop). key_action(67,hold). key_action(340,hold).

horizontal(A,D,Out) :-
    (rl_down(263) -> Dir=left ; rl_down(262) -> Dir=right ; Dir=none),
    (Dir==none -> Out=A.put(_{direction:none,held:0.0,next_repeat:0.16})
    ; Dir\==A.direction -> act(A.game,Dir,G),Out=A.put(_{game:G,direction:Dir,held:0.0,next_repeat:0.16})
    ; Held is A.held+D,
      (Held>=A.next_repeat -> act(A.game,Dir,G),Next is Held+0.045
      ; G=A.game,Next=A.next_repeat),
      Out=A.put(_{game:G,held:Held,next_repeat:Next})).
soft_drop(A,D,Out) :-
    (rl_down(264) -> T is A.soft+D,
        ((rl_pressed(264);T>=0.035) -> act(A.game,down,G),Out=A.put(_{game:G,soft:0.0})
        ; Out=A.put(soft,T))
    ; Out=A.put(soft,0.0)).
scripted(A,G,Out) :-
    (A.opts.autoplay==true ->
        F=A.frames,
        (F=:=10 -> act(G,cw,Out)
        ; F=:=15 -> act(G,left,Out)
        ; F=:=20 -> act(G,hold,Out)
        ; 0 is F mod 35,F>25 -> act(G,hard_drop,Out)
        ; Out=G)
    ; Out=G).

open_query(A,Out) :-
    reachable_locks(A.game.board,A.game.active,Candidates,Info),
    Q=query{all:Candidates,candidates:Candidates,filter:false,index:0,
            start:A.game.active,info:Info},
    T=A.put(_{mode:query,query:Q,direction:none,held:0.0}),audit(T,queries,Out).
query_keys(A,Out) :-
    Q=A.query,
    (pressed(A,70) ->
        (Q.filter==false -> include(clears,Q.all,C),Filter=true ; C=Q.all,Filter=false),
        T=A.put(query,Q.put(_{candidates:C,filter:Filter,index:0})),audit(T,filters,Out)
    ; pressed(A,263) -> cycle_query(A,-1,Out)
    ; pressed(A,262) -> cycle_query(A,1,Out)
    ; pressed(A,257),Q.candidates\==[] ->
        nth0(Q.index,Q.candidates,candidate(_,_,Path,_)),
        T=A.put(_{mode:replay,replay:Path,replay_time:0.0}),audit(T,replays_started,Out)
    ; Out=A).
clears(candidate(_,L,_,_)) :- L>0.
cycle_query(A,D,Out) :-
    length(A.query.candidates,N),
    (N=:=0 -> Out=A
    ; I is (A.query.index+D+N) mod N,T=A.put(query,A.query.put(index,I)),audit(T,cycles,C),
      (I=:=A.query.index -> Out=C ; audit(C,selection_changes,Out))).
replay_tick(A,D,Out) :-
    T is A.replay_time+D,
    (T<0.055 -> Out=A.put(replay_time,T)
    ; A.replay=[] -> act(A.game,hard_drop,G),
      TApp=A.put(_{game:G,mode:play,query:none,replay_time:0.0}),audit(TApp,replays_completed,Out)
    ; A.replay=[Action|Rest],move_pose(A.game.board,A.game.active,Action,Next),
      G=A.game.put(active,Next),TApp=A.put(_{game:G,replay:Rest,replay_time:0.0}),audit(TApp,replay_moves,Out)).
