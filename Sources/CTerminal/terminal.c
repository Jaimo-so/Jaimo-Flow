#include "CTerminal.h"
#include <util.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/ioctl.h>

pid_t jaimo_start_shell(int *master) {
    const char *shell = getenv("SHELL");
    if (!shell || shell[0] != '/') shell = "/bin/zsh";
    const char *home = getenv("HOME");
    struct winsize size = { .ws_row = 24, .ws_col = 80 };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        if (home) chdir(home);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        execl(shell, shell, "-l", (char *)NULL);
        _exit(127);
    }
    return pid;
}
int jaimo_resize_terminal(int master, unsigned short columns, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(master, TIOCSWINSZ, &size);
}
