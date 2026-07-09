// nss_watch.h
#ifndef NSS_WATCH_H
#define NSS_WATCH_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <ctype.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <fcntl.h>

// ─────────────────────────────────────────────────────────────────────────────
// Configuración (hardcoded o desde archivo)
// ─────────────────────────────────────────────────────────────────────────────
#define NSS_MARK        0x00010000
#define CONNTRACK_FILE  "/proc/net/nf_conntrack"
#define DEBUG_LOG       "/usr/bin/NSS-Switch/state/debug.log"
#define WATCH_INTERVAL  3

// ─────────────────────────────────────────────────────────────────────────────
// Colores ANSI (igual que en ui.sh)
// ─────────────────────────────────────────────────────────────────────────────
#define C_RESET     "\033[0m"
#define C_BOLD      "\033[1m"
#define C_DIM       "\033[2m"
#define FG_ACCENT   "\033[38;2;60;190;255m"
#define FG_GREEN    "\033[38;2;70;210;110m"
#define FG_RED      "\033[38;2;255;90;90m"
#define FG_YELLOW   "\033[38;2;255;195;70m"
#define FG_ORANGE   "\033[38;2;255;135;35m"
#define BG_DARK     "\033[48;2;12;18;28m"
#define BG_MED      "\033[48;2;22;32;48m"

// Símbolos
#define TICK        "✓"
#define CROSS       "✗"
#define WARN_SYM    "⚠"
#define ARROW       "▶"

// ─────────────────────────────────────────────────────────────────────────────
// Estructura de una conexión conntrack
// ─────────────────────────────────────────────────────────────────────────────
typedef struct {
    unsigned int num;
    char proto[8];
    char src_ip[64];
    unsigned int src_port;
    char dst_ip[64];
    unsigned int dst_port;
    char iface[32];
    char nss_state[8];
    int bypassed;      // 1 = YES, 0 = NO
    unsigned int mark;
    char state[32];
} conntrack_entry_t;

// ─────────────────────────────────────────────────────────────────────────────
// Funciones principales
// ─────────────────────────────────────────────────────────────────────────────
void cmd_watch(int once, int interval);
void cmd_pick(void);

// Funciones auxiliares
int  parse_conntrack_line(const char *line, conntrack_entry_t *entry);
void get_term_size(int *rows, int *cols);
void compress_ipv6(char *dest, const char *src);
char* get_iface_for_src(const char *src_ip);
void render_conn_row(const conntrack_entry_t *entry, int row_num);
void render_header_bar(const char *title, const char *subtitle, const char *right);
void render_hint_bar(const char *hint);

#endif
