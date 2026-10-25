#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    HANDLE from, to;
    int input;
    DWORD error;
} Relay;

static BOOL incomplete_utf8(const unsigned char *bytes, DWORD length) {
    unsigned char first = bytes[0];
    DWORD needed = first >= 0xc2 && first <= 0xdf ? 2
                 : first >= 0xe0 && first <= 0xef ? 3
                 : first >= 0xf0 && first <= 0xf4 ? 4 : 0;
    if (!needed || length >= needed) return FALSE;
    for (DWORD i = 1; i < length; ++i)
        if (bytes[i] < 0x80 || bytes[i] > 0xbf) return FALSE;
    if (length > 1 && ((first == 0xe0 && bytes[1] < 0xa0)
                      || (first == 0xed && bytes[1] > 0x9f)
                      || (first == 0xf0 && bytes[1] < 0x90)
                      || (first == 0xf4 && bytes[1] > 0x8f))) return FALSE;
    return TRUE;
}

static BOOL write_all(HANDLE to, const void *bytes, DWORD length) {
    const char *next = bytes;
    while (length) {
        DWORD count;
        if (!WriteFile(to, next, length, &count, NULL) || !count) return FALSE;
        next += count;
        length -= count;
    }
    return TRUE;
}

static DWORD WINAPI relay_stream(void *argument) {
    Relay *relay = argument;
    char buffer[8192];
    WCHAR wide[8192];
    DWORD mode, count;
    BOOL console = GetConsoleMode(relay->input ? relay->from : relay->to, &mode);
    int pending = 0;
    for (;;) {
        SetLastError(ERROR_SUCCESS);
        if (console && relay->input) {
            if (!ReadConsoleW(relay->from, wide, 2048, &count, NULL) || !count) break;
            int bytes = WideCharToMultiByte(CP_UTF8, 0, wide, (int)count,
                                           buffer, sizeof(buffer), NULL, NULL);
            if (!bytes || !write_all(relay->to, buffer, (DWORD)bytes)) break;
        } else {
            if (!ReadFile(relay->from, buffer + pending,
                          sizeof(buffer) - (DWORD)pending, &count, NULL) || !count) break;
            count += (DWORD)pending;
            if (console) {
                /* A pipe read can split a UTF-8 scalar. Preserve its suffix
                   for the next read; WriteConsoleW never changes the owner CP. */
                DWORD complete = count;
                int chars = 0;
                while (complete && count - complete < 4) {
                    chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                               buffer, (int)complete, wide, 8192);
                    if (chars) break;
                    --complete;
                }
                if (!chars) {
                    if (count < 4 && incomplete_utf8((unsigned char *)buffer, count)) {
                        pending = (int)count;
                        continue;
                    }
                    SetLastError(ERROR_NO_UNICODE_TRANSLATION); break;
                }
                if (!WriteConsoleW(relay->to, wide, (DWORD)chars, &mode, NULL)) break;
                pending = (int)(count - complete);
                memmove(buffer, buffer + complete, (size_t)pending);
            } else if (!write_all(relay->to, buffer, count)) break;
        }
    }
    DWORD error = GetLastError();
    relay->error = (error == ERROR_BROKEN_PIPE || error == ERROR_OPERATION_ABORTED
                    || error == ERROR_INVALID_HANDLE) ? 0 : error;
    if (!relay->input && pending) relay->error = ERROR_NO_UNICODE_TRANSLATION;
    /* Each started relay owns its parent pipe end. In particular, closing an
       undrained output pipe propagates failure to the writer immediately. */
    CloseHandle(relay->input ? relay->to : relay->from);
    return 0;
}

/* Invoked inside the CLI's existing Job Object. No BREAKAWAY flag is used:
   the hidden child and every descendant remain in that same cancellable tree. */
BOOL fp_game_hidden_console(const WCHAR *line, DWORD *exit_code) {
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), NULL, TRUE};
    HANDLE child[3] = {NULL, NULL, NULL}, parent[3] = {NULL, NULL, NULL};
    HANDLE threads[3] = {NULL, NULL, NULL};
    Relay relays[3];
    PROCESS_INFORMATION process = {0};
    STARTUPINFOW startup = {0};
    BOOL success = FALSE;
    DWORD error = 0;
    WCHAR *command = _wcsdup(line);
    if (!command) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return FALSE; }
    for (int i = 0; i < 3; ++i) {
        BOOL made = i == 0
            ? CreatePipe(&child[i], &parent[i], &attributes, 0)
            : CreatePipe(&parent[i], &child[i], &attributes, 0);
        if (!made || !SetHandleInformation(parent[i], HANDLE_FLAG_INHERIT, 0)) goto cleanup;
        relays[i] = (Relay){i == 0 ? GetStdHandle(STD_INPUT_HANDLE) : parent[i],
                           i == 0 ? parent[i] : GetStdHandle(i == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE),
                           i == 0, 0};
    }
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    startup.hStdInput = child[0];
    startup.hStdOutput = child[1];
    startup.hStdError = child[2];
    if (!CreateProcessW(NULL, command, NULL, NULL, TRUE,
                        CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT,
                        NULL, NULL, &startup, &process)) goto cleanup;
    for (int i = 0; i < 3; ++i) {
        CloseHandle(child[i]); child[i] = NULL;
        threads[i] = CreateThread(NULL, 0, relay_stream, &relays[i], 0, NULL);
        if (!threads[i]) goto cleanup;
    }
    if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0
        || !GetExitCodeProcess(process.hProcess, exit_code)) goto cleanup;
    CancelSynchronousIo(threads[0]);
    WaitForMultipleObjects(3, threads, TRUE, INFINITE);
    for (int i = 0; i < 3; ++i) {
        if (relays[i].error) { SetLastError(relays[i].error); goto cleanup; }
    }
    success = TRUE;
cleanup:
    error = GetLastError();
    if (!success && process.hProcess) {
        TerminateProcess(process.hProcess, 1);
        WaitForSingleObject(process.hProcess, INFINITE);
    }
    for (int i = 0; i < 3; ++i) {
        if (threads[i]) { CancelSynchronousIo(threads[i]); WaitForSingleObject(threads[i], INFINITE); CloseHandle(threads[i]); }
        if (child[i]) CloseHandle(child[i]);
        if (parent[i] && !threads[i]) CloseHandle(parent[i]);
    }
    if (process.hThread) CloseHandle(process.hThread);
    if (process.hProcess) CloseHandle(process.hProcess);
    free(command);
    SetLastError(error);
    return success;
}
