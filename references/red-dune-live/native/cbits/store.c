#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Hold every non-reparse ancestor without FILE_SHARE_DELETE. Paths underneath
   this root cannot be redirected while the store is open. A second process
   cannot acquire session.lock. Never use replace-existing on checkpoints. */
typedef struct { HANDLE dirs[128]; unsigned count; HANDLE lock; wchar_t root[32768]; } rd_store;

static int name_ok(const char *name) {
    if (!*name || strlen(name) > 120) return 0;
    for (const char *p = name; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '-' || *p == '.')) return 0;
    return strstr(name, "..") == NULL;
}

static int path_for(rd_store *s, const char *name, wchar_t *path) {
    if (!name_ok(name)) { SetLastError(ERROR_INVALID_NAME); return 0; }
    if (wcslen(s->root) + strlen(name) + 2 >= 32768) { SetLastError(ERROR_BUFFER_OVERFLOW); return 0; }
    wcscpy(path, s->root); wcscat(path, L"\\");
    size_t n = wcslen(path);
    for (; *name; ++name) path[n++] = (unsigned char)*name;
    path[n] = 0; return 1;
}

void rd_store_close(rd_store *s) {
    if (!s) return;
    if (s->lock != INVALID_HANDLE_VALUE) CloseHandle(s->lock);
    while (s->count) CloseHandle(s->dirs[--s->count]);
    free(s);
}

rd_store *rd_store_open(const wchar_t *input) {
    rd_store *s = calloc(1, sizeof(*s));
    if (!s) { SetLastError(ERROR_OUTOFMEMORY); return NULL; }
    s->lock = INVALID_HANDLE_VALUE;
    DWORD n = GetFullPathNameW(input, 32700, s->root, NULL);
    if (n < 3 || n >= 32700 || s->root[1] != ':' || s->root[2] != '\\') {
        free(s); SetLastError(ERROR_INVALID_NAME); return NULL;
    }
    while (n > 3 && s->root[n-1] == '\\') s->root[--n] = 0;
    for (DWORD i = 3; i <= n; ++i) if (i == n || s->root[i] == '\\') {
        wchar_t saved = s->root[i]; s->root[i] = 0;
        if (s->count == 128) { s->root[i] = saved; rd_store_close(s); SetLastError(ERROR_BUFFER_OVERFLOW); return NULL; }
        HANDLE dir = CreateFileW(s->root, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        if (dir == INVALID_HANDLE_VALUE && (GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND)) {
            if (CreateDirectoryW(s->root, NULL) || GetLastError() == ERROR_ALREADY_EXISTS)
                dir = CreateFileW(s->root, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
        }
        DWORD error = GetLastError(); BY_HANDLE_FILE_INFORMATION info;
        if (dir == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(dir, &info) ||
            !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            if (dir != INVALID_HANDLE_VALUE) { CloseHandle(dir); error = ERROR_ACCESS_DENIED; }
            s->root[i] = saved; rd_store_close(s); SetLastError(error); return NULL;
        }
        s->dirs[s->count++] = dir; s->root[i] = saved;
    }
    wchar_t path[32768]; path_for(s, "session.lock", path);
    s->lock = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, NULL);
    DWORD error = GetLastError(); BY_HANDLE_FILE_INFORMATION info;
    if (s->lock == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(s->lock, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) {
        rd_store_close(s); SetLastError(error ? error : ERROR_ACCESS_DENIED); return NULL;
    }
    return s;
}

int rd_store_write(rd_store *s, const char *name, const unsigned char *bytes, unsigned long size) {
    wchar_t path[32768]; if (!path_for(s, name, path)) return 0;
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    DWORD offset = 0, written = 0; int ok = 1;
    while (offset < size) {
        if (!WriteFile(f, bytes + offset, size - offset, &written, NULL) || !written) { ok = 0; break; }
        offset += written;
    }
    if (ok) ok = FlushFileBuffers(f);
    DWORD error = GetLastError(); CloseHandle(f); SetLastError(error); return ok;
}

static int read_bounded(rd_store *s, const char *name, unsigned char **bytes, unsigned long *size,
                        LONGLONG minimum, LONGLONG maximum) {
    wchar_t path[32768]; if (!path_for(s, name, path)) return 0;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    BY_HANDLE_FILE_INFORMATION info; LARGE_INTEGER length;
    if (!GetFileInformationByHandle(f, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) ||
        !GetFileSizeEx(f, &length) || length.QuadPart < minimum || length.QuadPart > maximum) {
        CloseHandle(f); SetLastError(ERROR_INVALID_DATA); return 0;
    }
    unsigned char *buffer = malloc((size_t)length.QuadPart);
    if (!buffer) { CloseHandle(f); SetLastError(ERROR_OUTOFMEMORY); return 0; }
    DWORD offset = 0, got = 0; int ok = 1;
    while (offset < (DWORD)length.QuadPart) {
        if (!ReadFile(f, buffer + offset, (DWORD)length.QuadPart - offset, &got, NULL) || !got) { ok = 0; break; }
        offset += got;
    }
    DWORD error = GetLastError(); CloseHandle(f);
    if (!ok) { free(buffer); SetLastError(error); return 0; }
    *bytes = buffer; *size = offset; return 1;
}

int rd_store_read(rd_store *s, const char *name, unsigned char **bytes, unsigned long *size) {
    return read_bounded(s, name, bytes, size, 40, 33554472);
}

int rd_store_read_ui(rd_store *s, const char *name, unsigned char **bytes, unsigned long *size) {
    if (strcmp(name, "ui-preferences.rdui") && strncmp(name, "ui-preferences-", 15)) {
        SetLastError(ERROR_INVALID_NAME); return 0;
    }
    return read_bounded(s, name, bytes, size, 1, 1024);
}

int rd_store_commit(rd_store *s, const char *temporary, const char *final) {
    wchar_t a[32768], b[32768];
    if (!path_for(s, temporary, a) || !path_for(s, final, b)) return 0;
    return MoveFileExW(a, b, MOVEFILE_WRITE_THROUGH);
}

/* Only the small UI preference leaf can be replaced. World checkpoints retain
   their immutable commit path above. The same ancestor pins and lock apply. */
int rd_store_replace_ui(rd_store *s, const char *temporary) {
    if (strncmp(temporary, "ui-preferences-", 15)) { SetLastError(ERROR_INVALID_NAME); return 0; }
    wchar_t a[32768], b[32768];
    if (!path_for(s, temporary, a) || !path_for(s, "ui-preferences.rdui", b)) return 0;
    DWORD attributes = GetFileAttributesW(b);
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) {
        SetLastError(ERROR_ACCESS_DENIED); return 0;
    }
    return MoveFileExW(a, b, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

unsigned long rd_store_error(void) { return GetLastError(); }
void rd_store_free(void *p) { free(p); }

void rd_native_error(const wchar_t *message) {
    /* Avoid raylib's CloseWindow/ShowCursor names colliding with the import
       library. Resolve only MessageBoxW from the system's KnownDLL. */
    HMODULE module = LoadLibraryExW(L"user32.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (module) {
        typedef int (WINAPI *show_message)(HWND, LPCWSTR, LPCWSTR, UINT);
        show_message show = (show_message)GetProcAddress(module, "MessageBoxW");
        if (show) show(NULL, message, L"Red Dune", MB_OK | MB_ICONERROR);
        FreeLibrary(module);
    }
}
