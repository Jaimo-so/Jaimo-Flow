#ifndef JAIMO_CTERMINAL_H
#define JAIMO_CTERMINAL_H
#include <sys/types.h>
pid_t jaimo_start_shell(int *master, const char *directory);
int jaimo_resize_terminal(int master, unsigned short columns, unsigned short rows);
#endif
