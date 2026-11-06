#define WIN32_LEAN_AND_MEAN
#define NOGDI
#define NOUSER
#define NOMINMAX
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include <math.h>
#include "raylib.h"
#include "rlgl.h"

/* NOUSER avoids Win32/raylib name collisions above. Only these two Win32
   calls are needed by the optional self-window native-message regression. */
__declspec(dllimport) BOOL WINAPI PostMessageW(HWND,UINT,WPARAM,LPARAM);
__declspec(dllimport) UINT WINAPI MapVirtualKeyW(UINT,UINT);

/* A generic synchronous rendering endpoint. It has no board, piece, score,
   simulation or game-policy code. GNU APL is the child and owns the loop. */
enum { KEY_COUNT = 16, MAX_TEXT = 512, MAX_LINE = 2*1024*1024 };
static const int keys[KEY_COUNT] = {
    KEY_LEFT,KEY_RIGHT,KEY_DOWN,KEY_UP,KEY_Z,KEY_X,KEY_SPACE,KEY_P,
    KEY_R,KEY_ESCAPE,KEY_C,KEY_TAB,KEY_ENTER,KEY_A,KEY_D,KEY_S
};
typedef struct { int x,y,size; Color color; char text[4096]; } Label;
typedef struct { int frame,key,down; } InputEvent;
static Label labels[MAX_TEXT];
static int label_count;
static InputEvent events[8192];
static int event_count,event_next,injected[KEY_COUNT],previous[KEY_COUNT];
static int native_input;
static int pressed_latch[KEY_COUNT],close_requested,owner_cancel;
static double close_at,last_poll;
static HANDLE child_write, child_read;
static PROCESS_INFORMATION child;
static int frame_limit,shot_frame,width=1080,height=800,fps=60;
static int frame_count,protocol_error;
static double fixed_dt;
static char screenshot[4096];

static void fail(const char *s) { fprintf(stderr,"array-host: %s (Win32 %lu)\n",s,GetLastError()); exit(1); }
static void utf8(const wchar_t *s,char *out,int cap) {
    if (!WideCharToMultiByte(CP_UTF8,0,s,-1,out,cap,0,0)) fail("UTF-8 conversion failed");
}
static void append_arg(wchar_t *command,size_t cap,const wchar_t *s) {
    if (wcslen(command)+wcslen(s)+4>=cap) fail("Command line too long");
    wcscat_s(command,cap,L" \""); wcscat_s(command,cap,s); wcscat_s(command,cap,L"\"");
}
static void launch_apl(const wchar_t *root,int count,wchar_t **files) {
    wchar_t executable[4096],api[4096],command[32768],runtime[4096],scratch[4096],absolute[4096];
    swprintf_s(runtime,4096,L"%s\\.runtime\\apl",root);
    swprintf_s(executable,4096,L"%s\\apl-2.0.exe",runtime);
    swprintf_s(api,4096,L"%s\\host\\api.apl",root);
    swprintf_s(command,32768,L"\"%s\" -s --noSV --rawCIN --OFF -f",executable);
    append_arg(command,32768,api);
    for (int i=0;i<count;i++) {
        if(!GetFullPathNameW(files[i],4096,absolute,NULL)) fail("Cannot resolve APL input path");
        wcscat_s(command,32768,L" -f"); append_arg(command,32768,absolute);
    }
    SECURITY_ATTRIBUTES security={sizeof(security),NULL,TRUE};
    HANDLE child_input,child_output;
    if(!CreatePipe(&child_input,&child_write,&security,65536) ||
       !CreatePipe(&child_read,&child_output,&security,65536)) fail("CreatePipe failed");
    SetHandleInformation(child_write,HANDLE_FLAG_INHERIT,0);
    SetHandleInformation(child_read,HANDLE_FLAG_INHERIT,0);
    STARTUPINFOW si={0}; si.cb=sizeof(si);
    si.dwFlags=STARTF_USESTDHANDLES;
    si.hStdInput=child_input; si.hStdOutput=child_output; si.hStdError=GetStdHandle(STD_ERROR_HANDLE);
    SetEnvironmentVariableW(L"APL_LIB_ROOT",runtime);
    swprintf_s(scratch,4096,L"%s\\.scratch",root); CreateDirectoryW(scratch,NULL);
    swprintf_s(scratch,4096,L"%s\\.scratch\\runtime",root); CreateDirectoryW(scratch,NULL);
    /* GNU APL writes .apl.history in its cwd even for scripts. Contain it. */
    if(!CreateProcessW(executable,command,NULL,NULL,TRUE,CREATE_NO_WINDOW,NULL,scratch,&si,&child))
        fail("Cannot launch workspace-local GNU APL; run tools/setup.ps1");
    CloseHandle(child_input); CloseHandle(child_output);
}

static void load_events(const char *path) {
    FILE *f=NULL; if(fopen_s(&f,path,"r")) fail("Cannot open input fixture");
    char line[256]; int last=-1;
    while(fgets(line,sizeof(line),f)) {
        int frame,key,down;
        if(line[0]=='#' || line[0]=='\n' || line[0]=='\r') continue;
        if(sscanf_s(line,"%d %d %d",&frame,&key,&down)!=3 || frame<1 || frame<last ||
           key<0 || key>=KEY_COUNT || (down!=0 && down!=1) || event_count>=8192)
            fail("Invalid input fixture: use ordered frame key-index down rows");
        events[event_count++]=(InputEvent){frame,key,down}; last=frame;
    }
    fclose(f);
}
static int post_native_key(InputEvent e) {
    /* These are Windows virtual-key codes for the public 16-key contract.
       Messages target this raylib HWND only; no global keyboard injection. */
    static const UINT vk[KEY_COUNT]={37,39,40,38,90,88,32,80,82,27,67,9,13,65,68,83};
    UINT scan=MapVirtualKeyW(vk[e.key],0);
    DWORD bits=1UL | (scan<<16) | (e.key<4?(1UL<<24):0) | (e.down?0:0xc0000000UL);
    return PostMessageW((HWND)GetWindowHandle(),e.down?0x0100:0x0101,(WPARAM)vk[e.key],(LPARAM)bits)!=0;
}
static void latch_input(void) {
    /* A down+up pair can occur inside one PollInputEvents call. The held-state
       comparison in IsKeyPressed then sees 0->0 and misses the tap. raylib's
       key-down queue records that edge independently of the final held state. */
    int pressed;
    while((pressed=GetKeyPressed())!=0) {
        for(int i=0;i<KEY_COUNT;i++) if(keys[i]==pressed) pressed_latch[i]=1;
    }
    if(WindowShouldClose() && !close_requested) { close_requested=1; close_at=GetTime(); }
    last_poll=GetTime();
}
static void send_input(void) {
    /* EndDrawing has just polled events. Include all edges observed during
       pipe waits as well, so extra responsiveness cannot lose a key press. */
    latch_input();
    while(!native_input && event_next<event_count && events[event_next].frame<=frame_count) {
        InputEvent e=events[event_next++]; injected[e.key]=e.down;
    }
    int held[KEY_COUNT],pressed[KEY_COUNT];
    for(int i=0;i<KEY_COUNT;i++) {
        held[i]=IsKeyDown(keys[i]) || injected[i];
        pressed[i]=pressed_latch[i] || (injected[i] && !previous[i]);
        pressed_latch[i]=0;
        previous[i]=injected[i];
    }
    int close=close_requested || (frame_limit>0 && frame_count>=frame_limit);
    double dt=fixed_dt>0?fixed_dt:(double)GetFrameTime();
    double elapsed=fixed_dt>0?frame_count*fixed_dt:GetTime();
    char response[2048]; int n=sprintf_s(response,sizeof(response),"%d %.9f %.9f %d %d %d",close,dt,elapsed,GetScreenWidth(),GetScreenHeight(),frame_count);
    for(int i=0;i<KEY_COUNT;i++) n+=sprintf_s(response+n,sizeof(response)-(size_t)n," %d",held[i]);
    for(int i=0;i<KEY_COUNT;i++) n+=sprintf_s(response+n,sizeof(response)-(size_t)n," %d",pressed[i]);
    response[n++]='\n'; DWORD written;
    if(!WriteFile(child_write,response,(DWORD)n,&written,NULL) || written!=(DWORD)n) protocol_error=1;
}
/* GNU APL's numeric spelling uses U+00AF for negative signs. Convert that one
   spelling in numeric fields; text labels pass through unchanged as UTF-8. */
static void numeric_ascii(char *s) {
    unsigned char *in=(unsigned char*)s,*out=(unsigned char*)s;
    while(*in) {
        if(in[0]==0xc2 && in[1]==0xaf) { *out++='-'; in+=2; }
        else *out++=*in++;
    }
    *out=0;
}
static int next_number(char **p,double *number) {
    char *end; while(**p==' ' || **p=='\t') ++*p;
    *number=strtod(*p,&end); if(end==*p || !isfinite(*number)) return 0;
    *p=end; return 1;
}
static int channel(double v) { return (int)fmax(0,fmin(255,v)); }
static Color color_of(const double *v) { return (Color){(unsigned char)channel(v[0]),(unsigned char)channel(v[1]),(unsigned char)channel(v[2]),(unsigned char)channel(v[3])}; }
static int process_frame(char *line) {
    numeric_ascii(line); char *p=line+2; double nvalue;
    if(!next_number(&p,&nvalue) || nvalue<0 || nvalue>8192 || nvalue!=floor(nvalue)) return 0;
    int n=(int)nvalue; double *v=malloc((size_t)(n?n:1)*9*sizeof(double));
    if(!v) return 0;
    for(int i=0;i<n*9;i++) if(!next_number(&p,&v[i])) { free(v); return 0; }
    for(int i=0;i<n;i++) if(v[9*i]<0 || v[9*i]>3 || v[9*i]!=floor(v[9*i])) { free(v); return 0; }
    while(*p==' ' || *p=='\r' || *p=='\n') ++p;
    if(*p) { free(v); return 0; }
    BeginDrawing(); ClearBackground((Color){10,14,23,255});
    for(int i=0;i<n;i++) {
        double *r=v+9*i; Rectangle rect={(float)r[1],(float)r[2],(float)r[3],(float)r[4]};
        Color color=color_of(r+5);
        switch((int)r[0]) {
        case 0: DrawRectangleRec(rect,color); break;
        case 1: DrawRectangleLinesEx(rect,1.0f,color); break;
        case 2: DrawLineEx((Vector2){(float)r[1],(float)r[2]},(Vector2){(float)r[3],(float)r[4]},1.0f,color); break;
        case 3: DrawCircleV((Vector2){(float)r[1],(float)r[2]},(float)r[3],color); break;
        default: protocol_error=1;
        }
    }
    for(int i=0;i<label_count;i++) DrawText(labels[i].text,labels[i].x,labels[i].y,labels[i].size,labels[i].color);
    ++frame_count;
    if(screenshot[0] && ((shot_frame>0 && frame_count==shot_frame) || (shot_frame==0 && frame_limit>0 && frame_count==frame_limit))) {
        rlDrawRenderBatchActive();
        TakeScreenshot(screenshot);
        if(!FileExists(screenshot)) protocol_error=1;
        fprintf(stderr,"array-host: screenshot frame %d: %s\n",frame_count,screenshot);
    }
    while(native_input && event_next<event_count && events[event_next].frame<=frame_count) {
        if(!post_native_key(events[event_next++])) protocol_error=1;
    }
    EndDrawing(); free(v); label_count=0;
    send_input(); return 1;
}
static int process_text(char *line) {
    if(label_count>=MAX_TEXT) return 0;
    char *separator=strchr(line,'|'); if(!separator) return 0;
    *separator=0; numeric_ascii(line); char *p=line+2; double v[7];
    for(int i=0;i<7;i++) if(!next_number(&p,&v[i])) return 0;
    Label *l=labels+label_count++; l->x=(int)v[0]; l->y=(int)v[1]; l->size=(int)v[2]; l->color=color_of(v+3);
    char *text=separator+1; size_t len=strcspn(text,"\r\n"); if(len>=sizeof(l->text)) return 0;
    memcpy(l->text,text,len); l->text[len]=0; return 1;
}

int wmain(int argc,wchar_t **argv) {
    wchar_t root[4096],title[512]=L"APL / raylib array host"; char title8[2048];
    GetModuleFileNameW(NULL,root,4096);
    for(int i=0;i<3;i++) { wchar_t *slash=wcsrchr(root,L'\\'); if(!slash) fail("Cannot resolve project root"); *slash=0; }
    wchar_t *files[128]; int file_count=0,fixture_seen=0;
    for(int i=1;i<argc;i++) {
        if(wcscmp(argv[i],L"--width")==0 && i+1<argc) width=_wtoi(argv[++i]);
        else if(wcscmp(argv[i],L"--height")==0 && i+1<argc) height=_wtoi(argv[++i]);
        else if(wcscmp(argv[i],L"--fps")==0 && i+1<argc) fps=_wtoi(argv[++i]);
        else if(wcscmp(argv[i],L"--frames")==0 && i+1<argc) frame_limit=_wtoi(argv[++i]);
        else if(wcscmp(argv[i],L"--snapshot-frame")==0 && i+1<argc) shot_frame=_wtoi(argv[++i]);
        else if(wcscmp(argv[i],L"--fixed-dt")==0 && i+1<argc) fixed_dt=_wtof(argv[++i]);
        else if(wcscmp(argv[i],L"--screenshot")==0 && i+1<argc) utf8(argv[++i],screenshot,sizeof(screenshot));
        else if(wcscmp(argv[i],L"--title")==0 && i+1<argc) wcsncpy_s(title,512,argv[++i],_TRUNCATE);
        else if((wcscmp(argv[i],L"--input")==0 || wcscmp(argv[i],L"--native-input")==0) && i+1<argc) {
            if(fixture_seen++) fail("Use only one input fixture");
            native_input=wcscmp(argv[i],L"--native-input")==0;
            char path[4096]; utf8(argv[++i],path,sizeof(path)); load_events(path);
        }
        else if(argv[i][0]=='-') fail("Unknown or incomplete host argument");
        else if(file_count<128) files[file_count++]=argv[i];
        else fail("Too many APL input files");
    }
    if(file_count==0 || width<64 || height<64 || fps<1 || fixed_dt<0) fail("Supply APL script paths and valid window settings");
    utf8(title,title8,sizeof(title8));
    SetTraceLogLevel(LOG_WARNING); SetConfigFlags(FLAG_VSYNC_HINT);
    InitWindow(width,height,title8); if(!IsWindowReady()) fail("raylib window initialization failed");
    SetExitKey(KEY_NULL); SetTargetFPS(fps);
    launch_apl(root,file_count,files);
    char *line=malloc(MAX_LINE); if(!line) fail("Line allocation failed"); size_t used=0;
    char buffer[16384]; DWORD received;
    int finished=0;
    while(!finished) {
        if(close_requested && GetTime()-close_at>0.35) { owner_cancel=1; break; }
        DWORD available=0;
        if(!PeekNamedPipe(child_read,NULL,0,NULL,&available,NULL)) {
            if(GetLastError()!=ERROR_BROKEN_PIPE) protocol_error=1;
            break;
        }
        if(!available) {
            DWORD status=STILL_ACTIVE; GetExitCodeProcess(child.hProcess,&status);
            if(status!=STILL_ACTIVE) break;
            if(GetTime()-last_poll>=1.0/120.0) { PollInputEvents(); latch_input(); }
            Sleep(1); continue;
        }
        DWORD wanted=available<sizeof(buffer)?available:(DWORD)sizeof(buffer);
        if(!ReadFile(child_read,buffer,wanted,&received,NULL) || !received) { protocol_error=1; break; }
        for(DWORD i=0;i<received;i++) {
            if(used+1>=MAX_LINE) { protocol_error=1; finished=1; break; }
            line[used++]=buffer[i];
            if(buffer[i]=='\n') {
                line[used]=0;
                if(strncmp(line,"F ",2)==0) { if(!process_frame(line)) { protocol_error=1; finished=1; } }
                else if(strncmp(line,"T ",2)==0) { if(!process_text(line)) { protocol_error=1; finished=1; } }
                else if(strncmp(line,"L ",2)==0) fputs(line+2,stderr);
                else if(line[0]=='X') finished=1;
                else if(line[0]!='\r' && line[0]!='\n') { fprintf(stderr,"array-host: unexpected APL output: %s",line); protocol_error=1; finished=1; }
                used=0; if(finished) break;
            }
        }
    }
    if(used && !finished && !owner_cancel) protocol_error=1;
    free(line); CloseHandle(child_write); CloseHandle(child_read);
    if(WaitForSingleObject(child.hProcess,owner_cancel?100:2000)==WAIT_TIMEOUT) {
        TerminateProcess(child.hProcess,owner_cancel?0:2);
        WaitForSingleObject(child.hProcess,2000);
        if(!owner_cancel) protocol_error=1;
    }
    DWORD code=0; GetExitCodeProcess(child.hProcess,&code); CloseHandle(child.hProcess); CloseHandle(child.hThread);
    CloseWindow();
    fprintf(stderr,"array-host: frames=%d child_pid=%lu child_exit=%lu protocol=%s close=%s\n",frame_count,child.dwProcessId,code,protocol_error?"error":"ok",close_requested?"owner":"normal");
    return protocol_error || code ? 1:0;
}
