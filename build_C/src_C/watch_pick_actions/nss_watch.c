#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <ctype.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>


#define NSS_MARK        0x00010000
#define CONNTRACK_FILE  "/proc/net/nf_conntrack"
#define WATCH_INTERVAL  3

#define C_RESET     "\033[0m"
#define C_BOLD      "\033[1m"
#define C_DIM       "\033[2m"
#define BG_DARK     "\033[48;2;12;18;28m"
#define BG_MED      "\033[48;2;22;32;48m"
#define FG_BRIGHT   "\033[38;2;200;225;255m"
#define FG_DIM      "\033[38;2;70;90;115m"
#define FG_ACCENT   "\033[38;2;60;190;255m"
#define FG_GREEN    "\033[38;2;70;210;110m"
#define FG_RED      "\033[38;2;255;90;90m"
#define FG_YELLOW   "\033[38;2;255;195;70m"
#define FG_ORANGE   "\033[38;2;255;135;35m"
#define ARROW       "▶"


typedef struct {
    unsigned int num;
    char proto[8];
    char src_ip[64];
    unsigned int src_port;
    char dst_ip[64];
    unsigned int dst_port;
    char iface[32];
    char nss_state[8];
    int bypassed;
    unsigned int mark;
    char state[32];
} conntrack_entry_t;

static volatile sig_atomic_t exit_flag = 0;
static int term_rows = 24, term_cols = 80;


void sigint_handler(int signo) {
    (void)signo;
    exit_flag = 1;
    printf("\033[?25h");
    printf("\033[2J\033[H");
    exit(0);
}

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


void compress_ipv6(char *dest, const char *src) {
    char temp[128];
    char *token;
    char *saveptr;
    char result[128] = "";
    int groups[8] = {0};
    int group_count = 0;
    int i;
    int max_len = 0;
    int max_start = -1;
    int cur_len = 0;
    int cur_start = -1;
    int compressed = 0;

    strcpy(temp, src);

    token = strtok_r(temp, ":", &saveptr);
    while (token && group_count < 8) {
        groups[group_count++] = strtol(token, NULL, 16);
        token = strtok_r(NULL, ":", &saveptr);
    }

    for (i = 0; i < group_count; i++) {
        if (groups[i] == 0) {
            if (cur_len == 0) cur_start = i;
            cur_len++;
            if (cur_len > max_len) {
                max_len = cur_len;
                max_start = cur_start;
            }
        } else {
            cur_len = 0;
        }
    }

    if (max_len > 1) {
        for (i = 0; i < group_count; i++) {
            if (i == max_start) {
                if (i == 0) strcat(result, ":");
                strcat(result, ":");
                compressed = 1;
                i += max_len - 1;
            } else {
                if (i > 0 && !compressed) strcat(result, ":");
                sprintf(result + strlen(result), "%x", groups[i]);
                compressed = 0;
            }
        }
    } else {
        for (i = 0; i < group_count; i++) {
            if (i > 0) strcat(result, ":");
            sprintf(result + strlen(result), "%x", groups[i]);
        }
    }

    strcpy(dest, result);
}


void get_iface_for_src(const char *src_ip, char *iface, size_t iface_size) {
    FILE *fp;
    char cmd[256];

    snprintf(cmd, sizeof(cmd), "ip route get %s 2>/dev/null | grep -oE 'dev [^ ]+' | cut -d' ' -f2", src_ip);
    fp = popen(cmd, "r");
    if (fp) {
        if (fgets(iface, iface_size, fp) != NULL) {
            iface[strcspn(iface, "\n")] = '\0';
        }
        pclose(fp);
    }

    if (strlen(iface) == 0) {
        strcpy(iface, "?");
    }
}


int parse_conntrack_line(const char *line, conntrack_entry_t *entry) {
    char *src_start, *dst_start, *sport_start, *dport_start, *mark_start;
    char *line_copy;
    char *token;
    int field_idx = 0;

    memset(entry, 0, sizeof(conntrack_entry_t));
    strcpy(entry->proto, "?");
    strcpy(entry->state, "?");
    strcpy(entry->iface, "?");

    line_copy = strdup(line);
    if (!line_copy) return -1;

    token = strtok(line_copy, " ");
    while (token && field_idx < 4) {
        if (field_idx == 2) {
            strncpy(entry->proto, token, sizeof(entry->proto)-1);
        }
        field_idx++;
        token = strtok(NULL, " ");
    }

    src_start = strstr(line, "src=");
    if (src_start) sscanf(src_start, "src=%63s", entry->src_ip);

    dst_start = strstr(line, "dst=");
    if (dst_start) sscanf(dst_start, "dst=%63s", entry->dst_ip);

    sport_start = strstr(line, "sport=");
    if (sport_start) sscanf(sport_start, "sport=%u", &entry->src_port);

    dport_start = strstr(line, "dport=");
    if (dport_start) sscanf(dport_start, "dport=%u", &entry->dst_port);

    mark_start = strstr(line, "mark=");
    if (mark_start) sscanf(mark_start, "mark=%u", &entry->mark);

    if (strcmp(entry->proto, "tcp") == 0) {
        if (strstr(line, "ESTABLISHED")) strcpy(entry->state, "ESTABLISHED");
        else if (strstr(line, "SYN_SENT")) strcpy(entry->state, "SYN_SENT");
        else if (strstr(line, "TIME_WAIT")) strcpy(entry->state, "TIME_WAIT");
        else strcpy(entry->state, "?");
    } else {
        strcpy(entry->state, "stateless");
    }

    entry->bypassed = (entry->mark & NSS_MARK) != 0;

    if (entry->bypassed) {
        strcpy(entry->nss_state, "CPU");
    } else if (access("/sys/kernel/debug/ecm/ecm_nss_ipv4", F_OK) == 0) {
        strcpy(entry->nss_state, "HW");
    } else {
        strcpy(entry->nss_state, "CPU");
    }

    get_iface_for_src(entry->src_ip, entry->iface, sizeof(entry->iface));

    free(line_copy);
    return 0;
}


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

void render_hint_bar(const char *hint) {
    printf("%s%s %s%s", BG_DARK, FG_DIM, hint, C_RESET);
    int used = strlen(hint) + 1;
    int pad = term_cols - used;
    for (int i = 0; i < pad; i++) printf(" ");
    printf("\n");
}


void render_conn_row(const conntrack_entry_t *entry, int row_num) {
    char src_display[128], dst_display[128];

    if (strchr(entry->src_ip, ':')) {
        char compressed[64];
        compress_ipv6(compressed, entry->src_ip);
        snprintf(src_display, sizeof(src_display), "[%s]:%u", compressed, entry->src_port);
    } else {
        snprintf(src_display, sizeof(src_display), "%s:%u", entry->src_ip, entry->src_port);
    }

    if (strchr(entry->dst_ip, ':')) {
        char compressed[64];
        compress_ipv6(compressed, entry->dst_ip);
        snprintf(dst_display, sizeof(dst_display), "[%s]:%u", compressed, entry->dst_port);
    } else {
        snprintf(dst_display, sizeof(dst_display), "%s:%u", entry->dst_ip, entry->dst_port);
    }

    const char *nss_color = FG_GREEN;
    if (strcmp(entry->nss_state, "CPU") == 0) nss_color = FG_RED;
    else if (strcmp(entry->nss_state, "SFE") == 0) nss_color = FG_YELLOW;

    const char *bypass_color = entry->bypassed ? FG_ORANGE : C_DIM;
    const char *bypass_text = entry->bypassed ? "BYPASS" : "-";

    const char *row_bg = (row_num % 2 == 0) ? BG_MED : "";

    printf("%s", row_bg);
    printf("%s%4u%s ", C_BOLD, entry->num, C_RESET);
    printf("%-6s ", entry->proto);
    printf("%-40s ", src_display);
    printf("%-40s ", dst_display);
    printf("%-15s ", entry->iface);
    printf("%s%-4s%s ", nss_color, entry->nss_state, C_RESET);
    printf("%s%-6s%s\n", bypass_color, bypass_text, C_RESET);
}


void cmd_watch(int once, int interval) {
    FILE *fp;
    char line[1024];
    conntrack_entry_t entries[4096];
    int num_entries;
    int total, bypassed;

    signal(SIGINT, sigint_handler);
    signal(SIGTERM, sigint_handler);

    get_term_size(&term_rows, &term_cols);
    printf("\033[?25l");

    while (!exit_flag) {
        fp = fopen(CONNTRACK_FILE, "r");
        if (!fp) break;

        num_entries = 0;
        while (fgets(line, sizeof(line), fp) && num_entries < 4096) {
            if (parse_conntrack_line(line, &entries[num_entries]) == 0) {
                entries[num_entries].num = num_entries + 1;
                num_entries++;
            }
        }
        fclose(fp);

        get_counts(&total, &bypassed);

        printf("\033[2J\033[H");

        char timestamp[64];
        time_t now = time(NULL);
        struct tm *tm_info = localtime(&now);
        strftime(timestamp, sizeof(timestamp), "%a %d %b %H:%M:%S", tm_info);

        render_header_bar("NSS-Switch", "NSS Conntrack Live Monitor", timestamp);

        char hint[256];
        snprintf(hint, sizeof(hint), "%s Ctrl+C exit | refresh every %ds", ARROW, interval);
        render_hint_bar(hint);

        int normal = total - bypassed;
        printf("\n  %s%-14s%s", FG_BRIGHT, "Connections", C_RESET);
        printf("  %s%3d total%s", FG_GREEN, total, C_RESET);
        printf("  %s%3d NSS/HW%s", FG_ACCENT, normal, C_RESET);
        printf("  %s%3d CPU-bypass%s\n\n", FG_ORANGE, bypassed, C_RESET);

        printf("%s%s", BG_MED, FG_DIM);
        printf(" %-4s %-6s %-40s %-40s %-15s %-4s %-6s\n",
               "NUM", "PROTO", "SOURCE", "DESTINATION", "INTERFACE", "NSS", "BYPASS");
        printf("%s\n", C_RESET);

        for (int i = 0; i < num_entries; i++) {
            render_conn_row(&entries[i], i);
        }

        printf("\n%sTotal connections: %d%s\n", C_DIM, num_entries, C_RESET);
        fflush(stdout);

        if (once) break;
        sleep(interval);
    }

    printf("\033[?25h");
}



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

    fp = fopen(CONNTRACK_FILE, "r");
    if (!fp) {
        fprintf(stderr, "Cannot open %s\n", CONNTRACK_FILE);
        return;
    }

    printf("%s%s", BG_MED, FG_DIM);
    printf(" %-4s %-6s %-40s %-40s %-15s %-4s %-6s\n",
           "NUM", "PROTO", "SOURCE", "DESTINATION", "INTERFACE", "NSS", "BYPASS");
    printf("%s\n", C_RESET);

    while (fgets(line, sizeof(line), fp) && num_entries < 4096) {
        if (parse_conntrack_line(line, &entries[num_entries]) == 0) {
            entries[num_entries].num = num_entries + 1;

            char src_display[128], dst_display[128];

            if (strchr(entries[num_entries].src_ip, ':')) {
                char compressed[64];
                compress_ipv6(compressed, entries[num_entries].src_ip);
                snprintf(src_display, sizeof(src_display), "[%s]:%u",
                         compressed, entries[num_entries].src_port);
            } else {
                snprintf(src_display, sizeof(src_display), "%s:%u",
                         entries[num_entries].src_ip, entries[num_entries].src_port);
            }

            if (strchr(entries[num_entries].dst_ip, ':')) {
                char compressed[64];
                compress_ipv6(compressed, entries[num_entries].dst_ip);
                snprintf(dst_display, sizeof(dst_display), "[%s]:%u",
                         compressed, entries[num_entries].dst_port);
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
        } else {
            printf("%sInvalid selection (1-%d)%s\n", FG_RED, num_entries, C_RESET);
        }
    }
}


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
