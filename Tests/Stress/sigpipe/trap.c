#include <signal.h>
#include <execinfo.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
static void on_pipe(int sig) {
    void *frames[64];
    int n = backtrace(frames, 64);
    const char *path = getenv("SIGPIPE_TRAP_LOG");
    int fd = path ? open(path, O_WRONLY | O_CREAT | O_APPEND, 0644) : 2;
    const char *head = "\n==== SIGPIPE raised; backtrace of the writing thread ====\n";
    write(fd, head, strlen(head));
    backtrace_symbols_fd(frames, n, fd);
    if (path) close(fd);
}
__attribute__((constructor)) static void install(void) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = on_pipe;
    sigaction(SIGPIPE, &action, NULL);
}
