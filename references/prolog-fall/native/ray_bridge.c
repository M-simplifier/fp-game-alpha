/* Generic raylib primitives for SWI-Prolog. No game rules live here. */
#include <SWI-Prolog.h>
#include <raylib.h>
#include <stdint.h>

static int integer(term_t t, int *v) { return PL_get_integer_ex(t, v); }
static int color(term_t t, Color *c) {
    int64_t v;
    if (!PL_get_int64_ex(t, &v)) return FALSE;
    if (v < 0 || v > UINT32_MAX) return PL_domain_error("rgba32", t);
    *c = (Color){(unsigned char)(v >> 24), (unsigned char)(v >> 16),
                 (unsigned char)(v >> 8), (unsigned char)v};
    return TRUE;
}
static foreign_t open_window(term_t w, term_t h, term_t title) {
    int x,y; char *s;
    if (!integer(w,&x) || !integer(h,&y) || !PL_get_atom_chars(title,&s)) return FALSE;
    SetTraceLogLevel(LOG_WARNING);
    SetConfigFlags(FLAG_VSYNC_HINT | FLAG_MSAA_4X_HINT);
    InitWindow(x,y,s);
    if (!IsWindowReady()) return PL_resource_error("raylib_window");
    SetExitKey(KEY_NULL);
    SetTargetFPS(60);
    return TRUE;
}
static foreign_t close_window(void) { CloseWindow(); return TRUE; }
static foreign_t should_close(void) { return WindowShouldClose(); }
static foreign_t begin(void) { BeginDrawing(); return TRUE; }
static foreign_t end(void) { EndDrawing(); return TRUE; }
static foreign_t clear(term_t c) { Color v; if (!color(c,&v)) return FALSE; ClearBackground(v); return TRUE; }
static foreign_t rect(term_t x,term_t y,term_t w,term_t h,term_t c) {
    int a,b,d,e; Color v;
    if (!integer(x,&a)||!integer(y,&b)||!integer(w,&d)||!integer(h,&e)||!color(c,&v)) return FALSE;
    DrawRectangle(a,b,d,e,v); return TRUE;
}
static foreign_t outline(term_t x,term_t y,term_t w,term_t h,term_t thick,term_t c) {
    int a,b,d,e,f; Color v;
    if (!integer(x,&a)||!integer(y,&b)||!integer(w,&d)||!integer(h,&e)||!integer(thick,&f)||!color(c,&v)) return FALSE;
    DrawRectangleLinesEx((Rectangle){(float)a,(float)b,(float)d,(float)e},(float)f,v); return TRUE;
}
static foreign_t text(term_t s,term_t x,term_t y,term_t size,term_t c) {
    int a,b,d; Color v; char *str;
    if (!PL_get_atom_chars(s,&str)||!integer(x,&a)||!integer(y,&b)||!integer(size,&d)||!color(c,&v)) return FALSE;
    DrawText(str,a,b,d,v); return TRUE;
}
static foreign_t key_pressed(term_t key) { int k; return integer(key,&k) && IsKeyPressed(k); }
static foreign_t key_down(term_t key) { int k; return integer(key,&k) && IsKeyDown(k); }
static foreign_t time_now(term_t t) { return PL_unify_float(t,GetTime()); }
static foreign_t delta_time(term_t t) { return PL_unify_float(t,GetFrameTime()); }
static foreign_t fps(term_t t) { return PL_unify_integer(t,GetFPS()); }
static foreign_t focused(void) { return IsWindowFocused(); }
static foreign_t capture(term_t path) { char *p; if (!PL_get_atom_chars(path,&p)) return FALSE; TakeScreenshot(p); return TRUE; }

install_t install(void) {
    PL_register_foreign("rl_open",3,open_window,0);
    PL_register_foreign("rl_close",0,close_window,0);
    PL_register_foreign("rl_should_close",0,should_close,0);
    PL_register_foreign("rl_begin",0,begin,0);
    PL_register_foreign("rl_end",0,end,0);
    PL_register_foreign("rl_clear",1,clear,0);
    PL_register_foreign("rl_rect",5,rect,0);
    PL_register_foreign("rl_outline",6,outline,0);
    PL_register_foreign("rl_text",5,text,0);
    PL_register_foreign("rl_pressed",1,key_pressed,0);
    PL_register_foreign("rl_down",1,key_down,0);
    PL_register_foreign("rl_time",1,time_now,0);
    PL_register_foreign("rl_dt",1,delta_time,0);
    PL_register_foreign("rl_fps",1,fps,0);
    PL_register_foreign("rl_focused",0,focused,0);
    PL_register_foreign("rl_capture",1,capture,0);
}
