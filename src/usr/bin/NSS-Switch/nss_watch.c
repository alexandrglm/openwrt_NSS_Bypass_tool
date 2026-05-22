// nss_watch.c - Implementación principal
#include "nss_watch.h"

static volatile sig_atomic_t exit_flag = 0;
static int term_rows = 24, term_cols = 80;

// ─────────────────────────────────────────────────────────────────────────────
// Manejador de señales (Ctrl+C)
// ─────────────────────────────────────────────────────────────────────────────
void sigint_handler(int signo) {
    (void)signo;
    exit_flag = 1;
    printf("\033[?25h");  // Mostrar cursor
    printf("\033[2J\033[H"); // Limpiar pantalla
    exit(0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Obtener tamaño de terminal
// ─────────────────────────────────────────────────────────────────────────────
void get_term_size(int *rows, int *cols) {
    struct winsize w;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0) {
        *rows = w.ws_row;
        *cols = w.ws_col;
    } else {
        *rows = 24;
        *cols = 80;
    }
    if (*rows < 10) *rows = 10;
    if (*cols < 40) *cols = 40;
}

// ─────────────────────────────────────────────────────────────────────────────
// Compresión IPv6 (RFC 5952)
// ─────────────────────────────────────────────────────────────────────────────
void compress_ipv6(char *dest, const char *src) {
    // Implementación simplificada - puedes expandir después
    // Por ahora, copia igual o usa inet_ntop si ya está expandida
    struct in6_addr addr;
    if (inet_pton(AF_INET6, src, &addr) == 1) {
        inet_ntop(AF_INET6, &addr, dest, 64);
    } else {
        strcpy(dest, src);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Obtener interfaz para una IP origen (llama a ip route get)
// ─────────────────────────────────────────────────────────────────────────────
char* get_iface_for_src(const char *src_ip) {
    static char iface[32] = "?";
    char cmd[256];
    FILE *fp;

    snprintf(cmd, sizeof(cmd), "ip route get %s 2>/dev/null | grep -oE 'dev [^ ]+' | cut -d' ' -f2", src_ip);
    fp = popen(cmd, "r");
    if (fp) {
        if (fgets(iface, sizeof(iface), fp) != NULL) {
            iface[strcspn(iface, "\n")] = '\0';
        }
        pclose(fp);
    }

    // Si no hay salida, es IP local del router
    if (strlen(iface) == 0 || strcmp(iface, "lo") == 0) {
        // Buscar interfaz que tiene esta IP
        snprintf(cmd, sizeof(cmd), "ip addr show 2>/dev/null | grep -B1 'inet %s' | head -1 | awk '{print $2}' | sed 's/://'", src_ip);
        fp = popen(cmd, "r");
        if (fp) {
            if (fgets(iface, sizeof(iface), fp) != NULL) {
                iface[strcspn(iface, "\n")] = '\0';
                if (strlen(iface) > 0) {
                    char tmp[64];
                    snprintf(tmp, sizeof(tmp), "local:%s", iface);
                    strcpy(iface, tmp);
                }
            }
            pclose(fp);
        }
    }

    if (strlen(iface) == 0) strcpy(iface, "?");
    return iface;
}

// ─────────────────────────────────────────────────────────────────────────────
// Parsear una línea de /proc/net/nf_conntrack
// Formato: ipv4 2 tcp 6 src=192.168.1.100 dst=8.8.8.8 sport=12345 dport=443 ... mark=65536
// ─────────────────────────────────────────────────────────────────────────────
int parse_conntrack_line(const char *line, conntrack_entry_t *entry) {
    char *src_start, *dst_start, *sport_start, *dport_start, *mark_start;
    char *state_start;
    char *line_copy;
    char *token;
    int field_idx = 0;

    memset(entry, 0, sizeof(conntrack_entry_t));
    strcpy(entry->proto, "?");
    entry->src_port = 0;
    entry->dst_port = 0;
    strcpy(entry->state, "?");

    // Hacer una copia modificable
    line_copy = strdup(line);
    if (!line_copy) return -1;

    // Los primeros campos son: [layer3] [layer3num] [proto] [proto_num]
    token = strtok(line_copy, " ");
    while (token && field_idx < 4) {
        if (field_idx == 2) {  // Protocolo en texto (tcp, udp, etc.)
            strncpy(entry->proto, token, sizeof(entry->proto)-1);
        }
        field_idx++;
        token = strtok(NULL, " ");
    }

    // Buscar src=
    src_start = strstr(line, "src=");
    if (src_start) {
        sscanf(src_start, "src=%63s", entry->src_ip);
    }

    // Buscar dst=
    dst_start = strstr(line, "dst=");
    if (dst_start) {
        sscanf(dst_start, "dst=%63s", entry->dst_ip);
    }

    // Buscar sport=
    sport_start = strstr(line, "sport=");
    if (sport_start) {
        sscanf(sport_start, "sport=%u", &entry->src_port);
    }

    // Buscar dport=
    dport_start = strstr(line, "dport=");
    if (dport_start) {
        sscanf(dport_start, "dport=%u", &entry->dst_port);
    }

    // Buscar mark=
    mark_start = strstr(line, "mark=");
    if (mark_start) {
        sscanf(mark_start, "mark=%u", &entry->mark);
    }

    // Buscar estado (para TCP)
    if (strcmp(entry->proto, "tcp") == 0) {
        // El estado suele estar en el campo 4 o 5
        // Formato: ... tcp 6 src=... dst=... sport=... dport=... [ESTABLISHED] ...
        char *state_pos = strstr(line, "ESTABLISHED");
        if (!state_pos) state_pos = strstr(line, "SYN_SENT");
        if (!state_pos) state_pos = strstr(line, "SYN_RECV");
        if (!state_pos) state_pos = strstr(line, "FIN_WAIT");
        if (!state_pos) state_pos = strstr(line, "TIME_WAIT");
        if (!state_pos) state_pos = strstr(line, "CLOSE");
        if (!state_pos) state_pos = strstr(line, "CLOSE_WAIT");
        if (!state_pos) state_pos = strstr(line, "LAST_ACK");
        if (!state_pos) state_pos = strstr(line, "LISTEN");
        if (!state_pos) state_pos = strstr(line, "CLOSING");
        if (state_pos) {
            sscanf(state_pos, "%31s", entry->state);
        } else {
            strcpy(entry->state, "?");
        }
    } else {
        strcpy(entry->state, "stateless");
    }

    // Determinar si está bypassed
    entry->bypassed = (entry->mark & NSS_MARK) != 0;

    // Determinar estado NSS
    if (entry->bypassed) {
        strcpy(entry->nss_state, "CPU");
    } else if (access("/sys/kernel/debug/ecm/ecm_nss_ipv4", F_OK) == 0) {
        strcpy(entry->nss_state, "HW");
    } else if (access("/sys/kernel/debug/ecm/ecm_sfe_ipv4", F_OK) == 0) {
        strcpy(entry->nss_state, "SFE");
    } else {
        strcpy(entry->nss_state, "CPU");
    }

    // Obtener interfaz
    char *iface = get_iface_for_src(entry->src_ip);
    strncpy(entry->iface, iface, sizeof(entry->iface)-1);

    free(line_copy);
    return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Contar conexiones totales y bypassed
// ─────────────────────────────────────────────────────────────────────────────
void get_counts(int *total, int *bypassed) {
    FILE *fp = fopen(CONNTRACK_FILE, "r");
    char line[1024];
    *total = 0;
    *bypassed = 0;

    if (!fp) return;

    while (fgets(line, sizeof(line), fp)) {
        (*total)++;
        if (strstr(line, "mark=")) {
            unsigned int mark;
            if (sscanf(strstr(line, "mark="), "mark=%u", &mark) == 1) {
                if (mark & NSS_MARK) (*bypassed)++;
            }
        }
    }
    fclose(fp);
}

// ─────────────────────────────────────────────────────────────────────────────
// Renderizar barra de header
// ─────────────────────────────────────────────────────────────────────────────
void render_header_bar(const char *title, const char *subtitle, const char *right) {
    int table_width = term_cols - 2;
    int left_len = strlen(title) + strlen(subtitle) + 3;
    int right_len = strlen(right);
    int pad = table_width - left_len - right_len;
    if (pad < 1) pad = 1;

    printf("%s%s%s %s%s  %s",
           BG_DARK, FG_ACCENT, C_BOLD, title,
           C_RESET, BG_DARK, FG_DIM);
    printf("%s", subtitle);
    printf("%s", C_RESET);
    printf("%s", BG_DARK);
    for (int i = 0; i < pad; i++) printf(" ");
    printf("%s%s%s\n", FG_BRIGHT, right, C_RESET);
}

// ─────────────────────────────────────────────────────────────────────────────
// Renderizar barra de hints
// ─────────────────────────────────────────────────────────────────────────────
void render_hint_bar(const char *hint) {
    printf("%s%s %s%s", BG_DARK, FG_DIM, hint, C_RESET);
    int used = strlen(hint) + 1;
    int pad = term_cols - used;
    for (int i = 0; i < pad; i++) printf(" ");
    printf("\n");
}

// ─────────────────────────────────────────────────────────────────────────────
// Renderizar una fila de conexión
// ─────────────────────────────────────────────────────────────────────────────
void render_conn_row(const conntrack_entry_t *entry, int row_num) {
    char src_display[128], dst_display[128];
    char src_ip_comp[64], dst_ip_comp[64];

    // Comprimir IPv6
    if (strchr(entry->src_ip, ':')) {
        compress_ipv6(src_ip_comp, entry->src_ip);
        snprintf(src_display, sizeof(src_display), "[%s]:%u", src_ip_comp, entry->src_port);
    } else {
        snprintf(src_display, sizeof(src_display), "%s:%u", entry->src_ip, entry->src_port);
    }

    if (strchr(entry->dst_ip, ':')) {
        compress_ipv6(dst_ip_comp, entry->dst_ip);
        snprintf(dst_display, sizeof(dst_display), "[%s]:%u", dst_ip_comp, entry->dst_port);
    } else {
        snprintf(dst_display, sizeof(dst_display), "%s:%u", entry->dst_ip, entry->dst_port);
    }

    // Colores por protocolo
    const char *proto_color = FG_ACCENT;
    const char *nss_color;
    const char *bypass_color;
    const char *bypass_text;
    const char *iface_color = C_RESET;

    if (strcmp(entry->nss_state, "HW") == 0) nss_color = FG_GREEN;
    else if (strcmp(entry->nss_state, "SFE") == 0) nss_color = FG_YELLOW;
    else nss_color = FG_RED;

    if (entry->bypassed) {
        bypass_color = FG_ORANGE;
        bypass_text = "BYPASS";
    } else {
        bypass_color = C_DIM;
        bypass_text = "-";
    }

    if (strncmp(entry->iface, "local:", 6) == 0) iface_color = C_DIM;

    // Alternar fondo
    const char *row_bg = (row_num % 2 == 0) ? BG_MED : "";

    printf("%s", row_bg);
    printf("%s%4u%s ", C_BOLD, entry->num, C_RESET);
    printf("%s%-6s%s ", proto_color, entry->proto, C_RESET);
    printf("%-40s ", src_display);
    printf("%-40s ", dst_display);
    printf("%s%-15s%s ", iface_color, entry->iface, C_RESET);
    printf("%s%-4s%s ", nss_color, entry->nss_state, C_RESET);
    printf("%s%-6s%s\n", bypass_color, bypass_text, C_RESET);
}

// ─────────────────────────────────────────────────────────────────────────────
// COMANDO: watch - Monitor en vivo
// ─────────────────────────────────────────────────────────────────────────────
void cmd_watch(int once, int interval) {
    FILE *fp;
    char line[1024];
    conntrack_entry_t entries[4096];
    int num_entries;
    int total, bypassed;
    struct timespec ts = {interval, 0};

    signal(SIGINT, sigint_handler);
    signal(SIGTERM, sigint_handler);

    get_term_size(&term_rows, &term_cols);

    // Ocultar cursor
    printf("\033[?25l");

    while (!exit_flag) {
        // Leer todas las conexiones
        fp = fopen(CONNTRACK_FILE, "r");
        if (!fp) {
            fprintf(stderr, "Cannot open %s\n", CONNTRACK_FILE);
            break;
        }

        num_entries = 0;
        while (fgets(line, sizeof(line), fp) && num_entries < 4096) {
            if (parse_conntrack_line(line, &entries[num_entries]) == 0) {
                entries[num_entries].num = num_entries + 1;
                num_entries++;
            }
        }
        fclose(fp);

        get_counts(&total, &bypassed);

        // Renderizar pantalla
        printf("\033[2J\033[H");  // Clear y home

        char timestamp[64];
        time_t now = time(NULL);
        struct tm *tm_info = localtime(&now);
        strftime(timestamp, sizeof(timestamp), "%a %d %b  %H:%M:%S", tm_info);

        render_header_bar("NSS-Switch", "NSS Conntrack Live Monitor", timestamp);

        char hint[256];
        snprintf(hint, sizeof(hint), "%s Ctrl+C exit  •  refresh every %ds  •  %s connections below",
                 ARROW, interval, ARROW);
        render_hint_bar(hint);

        // Panel de estadísticas
        int normal = total - bypassed;
        printf("\n  %s%-14s%s", FG_BRIGHT, "Connections", C_RESET);
        printf("  %s%3d total%s", FG_GREEN, total, C_RESET);
        printf("  %s%3d NSS/HW%s", FG_ACCENT, normal, C_RESET);
        printf("  %s%3d CPU-bypass%s", FG_ORANGE, bypassed, C_RESET);
        printf("\n\n");

        // Header de tabla
        printf("%s%s", BG_MED, FG_DIM);
        printf(" %-4s %-6s %-40s %-40s %-15s %-4s %-6s\n",
               "NUM", "PROTO", "SOURCE", "DESTINATION", "INTERFACE", "NSS", "BYPASS");
        printf("%s\n", C_RESET);

        // Filas de conexión
        for (int i = 0; i < num_entries; i++) {
            render_conn_row(&entries[i], i);
        }

        printf("\n%sTotal connections: %d  •  Use terminal scroll\n", C_DIM, num_entries);
        printf("%s", C_RESET);

        fflush(stdout);

        if (once) break;

        // Esperar intervalo o señal
        nanosleep(&ts, NULL);
    }

    printf("\033[?25h");  // Mostrar cursor
}

// ─────────────────────────────────────────────────────────────────────────────
// COMANDO: pick - Selección interactiva de conexión
// ─────────────────────────────────────────────────────────────────────────────
void cmd_pick(void) {
    FILE *fp;
    char line[1024];
    conntrack_entry_t entries[4096];
    int num_entries = 0;
    char input[32];
    int selection;

    signal(SIGINT, sigint_handler);

    printf("\033[2J\033[H");
    printf("%s%sNSS-Switch - Connection Picker%s\n", C_BOLD, FG_ACCENT, C_RESET);
    printf("%s%s%s\n\n", C_DIM, "Select a connection to create a bypass rule", C_RESET);

    // Leer conexiones
    fp = fopen(CONNTRACK_FILE, "r");
    if (!fp) {
        fprintf(stderr, "Cannot open %s\n", CONNTRACK_FILE);
        return;
    }

    printf("%-4s %-6s %-40s %-40s %-15s\n",
           "NUM", "PROTO", "SOURCE", "DESTINATION", "INTERFACE");
    printf("%s\n", "---- ------ ---------------------------------------- ---------------------------------------- ---------------");

    while (fgets(line, sizeof(line), fp) && num_entries < 4096) {
        if (parse_conntrack_line(line, &entries[num_entries]) == 0) {
            entries[num_entries].num = num_entries + 1;

            char src_display[128], dst_display[128];
            char src_ip_comp[64], dst_ip_comp[64];

            if (strchr(entries[num_entries].src_ip, ':')) {
                compress_ipv6(src_ip_comp, entries[num_entries].src_ip);
                snprintf(src_display, sizeof(src_display), "[%s]:%u",
                         src_ip_comp, entries[num_entries].src_port);
            } else {
                snprintf(src_display, sizeof(src_display), "%s:%u",
                         entries[num_entries].src_ip, entries[num_entries].src_port);
            }

            if (strchr(entries[num_entries].dst_ip, ':')) {
                compress_ipv6(dst_ip_comp, entries[num_entries].dst_ip);
                snprintf(dst_display, sizeof(dst_display), "[%s]:%u",
                         dst_ip_comp, entries[num_entries].dst_port);
            } else {
                snprintf(dst_display, sizeof(dst_display), "%s:%u",
                         entries[num_entries].dst_ip, entries[num_entries].dst_port);
            }

            printf("%4u %-6s %-40s %-40s %-15s\n",
                   entries[num_entries].num,
                   entries[num_entries].proto,
                   src_display,
                   dst_display,
                   entries[num_entries].iface);

            num_entries++;
        }
    }
    fclose(fp);

    if (num_entries == 0) {
        printf("\n%sNo connections found%s\n", FG_YELLOW, C_RESET);
        return;
    }

    printf("\n%sEnter connection number (or 'q' to cancel): %s", C_BOLD, C_RESET);
    fflush(stdout);

    if (fgets(input, sizeof(input), stdin)) {
        if (input[0] == 'q' || input[0] == 'Q') {
            printf("%sCancelled%s\n", C_DIM, C_RESET);
            return;
        }

        selection = atoi(input);
        if (selection >= 1 && selection <= num_entries) {
            conntrack_entry_t *e = &entries[selection - 1];

            printf("\n%sSelected connection:%s\n", C_BOLD, C_RESET);
            printf("  Protocol:   %s\n", e->proto);
            printf("  Source:     %s:%u\n", e->src_ip, e->src_port);
            printf("  Destination:%s:%u\n", e->dst_ip, e->dst_port);
            printf("  Interface:  %s\n", e->iface);
            printf("  NSS state:  %s\n", e->nss_state);
            printf("  Bypassed:   %s\n\n", e->bypassed ? "YES" : "NO");

            // Construir comando para agregar regla
            char cmd[1024];
            snprintf(cmd, sizeof(cmd),
                     "nss-switch.sh add --proto %s --src-ip %s --dst-ip %s "
                     "--src-port %u --dst-port %u --iface %s --temp "
                     "--comment \"bypass from pick: %s -> %s\"",
                     e->proto, e->src_ip, e->dst_ip,
                     e->src_port, e->dst_port, e->iface,
                     e->src_ip, e->dst_ip);

            printf("%sRun: %s%s\n", C_DIM, cmd, C_RESET);
            printf("\n%sPress Enter to add this rule, Ctrl+C to cancel%s\n", FG_ACCENT, C_RESET);
            fgetc(stdin);  // Esperar Enter

            printf("%sAdding rule...%s\n", FG_GREEN, C_RESET);
            int ret = system(cmd);
            if (ret == 0) {
                printf("%s✓ Rule added successfully%s\n", FG_GREEN, C_RESET);
            } else {
                printf("%s✗ Failed to add rule%s\n", FG_RED, C_RESET);
            }
        } else {
            printf("%sInvalid selection (1-%d)%s\n", FG_RED, num_entries, C_RESET);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────────────────────────────────────
int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s watch [--once] [interval] | pick\n", argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "watch") == 0) {
        int once = 0;
        int interval = WATCH_INTERVAL;

        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--once") == 0) {
                once = 1;
            } else if (isdigit(argv[i][0])) {
                interval = atoi(argv[i]);
                if (interval < 1) interval = 1;
                if (interval > 30) interval = 30;
            }
        }
        cmd_watch(once, interval);

    } else if (strcmp(argv[1], "pick") == 0) {
        cmd_pick();

    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
        return 1;
    }

    return 0;
}
