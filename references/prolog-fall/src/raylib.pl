:- module(raylib,[rl_open/3,rl_close/0,rl_should_close/0,rl_begin/0,rl_end/0,
                  rl_clear/1,rl_rect/5,rl_outline/6,rl_text/5,rl_pressed/1,
                  rl_down/1,rl_time/1,rl_dt/1,rl_fps/1,rl_focused/0,rl_capture/1]).
:- prolog_load_context(directory,Here),
   directory_file_path(Here,'../.runtime/bin/prolog_raylib.dll',Relative),
   absolute_file_name(Relative,Bridge,[access(read)]),
   use_foreign_library(Bridge).
