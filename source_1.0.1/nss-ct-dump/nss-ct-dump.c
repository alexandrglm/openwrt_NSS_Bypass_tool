/*
 * nss-ct-dump.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>

#define CONNTRACK_FILE "/proc/net/nf_conntrack"
#define NSS_MARK 0x00010000
#define MAX_LINE 2048
#define CACHE_SIZE 256

/* Cache para IP -> interfaz */
typedef struct {
    char ip[64];
    char iface[32];
    int valid;
} iface_cache_t;

static iface_cache_t cache[CACHE_SIZE];
static int cache_idx = 0;

/* headers */
void compress_ipv6(char *dest, const char *src);
char* get_iface_for_ip(const char *ip);
int is_bypassed(unsigned int mark);
const char* get_nss_state(unsigned int mark);
unsigned int parse_mark(const char *line);
void parse_conntrack_line(const char *line, char *proto, char *src_ip, unsigned int *src_port, char *dst_ip, unsigned int *dst_port, unsigned int *mark, char *state);
int is_router_local(const char *ip);


/* Compress IPv6 */
void compress_ipv6(char *dest, const char *src) {
    char temp[128];
    char *token, *saveptr;
    char result[128] = "";
    int groups[8] = {0};
    int group_count = 0;
    int i;
    int max_len = 0, max_start = -1;
    int cur_len = 0, cur_start = -1;
    int compressed = 0;

    if (strchr(src, ':') == NULL) {
        strcpy(dest, src);
        return;
    }

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


/* IP uiface< */
char* get_iface_for_ip(const char *ip) {
    static char iface[32] = "?";
    char cmd[256];
    FILE *fp;
    int i;

    /* Buscar en cache */
    for (i = 0; i < cache_idx; i++) {
        if (strcmp(cache[i].ip, ip) == 0 && cache[i].valid) {
            return cache[i].iface;
        }
    }

    /* Si es IPv6, formato especial */
    if (strchr(ip, ':') != NULL) {
        snprintf(cmd, sizeof(cmd), "ip -6 route get %s 2>/dev/null | grep -oE 'dev [^ ]+' | cut -d' ' -f2", ip);
        /* Y si no, es IPv4 */
    } else {
        snprintf(cmd, sizeof(cmd), "ip route get %s 2>/dev/null | grep -oE 'dev [^ ]+' | cut -d' ' -f2", ip);
    }

    fp = popen(cmd, "r");
    if (fp) {
        if (fgets(iface, sizeof(iface), fp) != NULL) {
            iface[strcspn(iface, "\n")] = '\0';
        }
        pclose(fp);
    }

    if (strlen(iface) == 0 || strcmp(iface, "lo") == 0) {
        /* IP local del router para los problemas lo */
        if (strchr(ip, ':') != NULL) {
            snprintf(cmd, sizeof(cmd), "ip -6 addr show 2>/dev/null | grep -B1 'inet6 %s' | head -1 | awk '{print $2}' | sed 's/://'", ip);
        } else {
            snprintf(cmd, sizeof(cmd), "ip addr show 2>/dev/null | grep -B1 'inet %s' | head -1 | awk '{print $2}' | sed 's/://'", ip);
        }

        fp = popen(cmd, "r");
        if (fp) {
            char local_iface[32] = "";
            if (fgets(local_iface, sizeof(local_iface), fp) != NULL) {
                local_iface[strcspn(local_iface, "\n")] = '\0';
                if (strlen(local_iface) > 0) {
                    snprintf(iface, sizeof(iface), "local:%s", local_iface);
                } else {
                    strcpy(iface, "?");
                }
            }
            pclose(fp);
        } else {
            strcpy(iface, "?");
        }
    }

    if (strlen(iface) == 0) {
        strcpy(iface, "?");
    }

    /* Guardar en cache para velocidad en las proximas, tal como en modo shell */
    if (cache_idx < CACHE_SIZE) {
        strcpy(cache[cache_idx].ip, ip);
        strcpy(cache[cache_idx].iface, iface);
        cache[cache_idx].valid = 1;
        cache_idx++;
    }

    return iface;
}


/* Verifica bypass por mark */
int is_bypassed(unsigned int mark) {
    return (mark & NSS_MARK) != 0;
}

/* Obtener offload (HW/SFE/CPU) */
const char* get_nss_state(unsigned int mark) {
    if (is_bypassed(mark)) {
        return "CPU";
    }

    if (access("/sys/kernel/debug/ecm/ecm_nss_ipv4", F_OK) == 0) {
        return "HW";
    }

    if (access("/sys/kernel/debug/ecm/ecm_sfe_ipv4", F_OK) == 0) {
        return "SFE";
    }

    return "CPU";
}


/* Parsear cada linea de conntrack */
void parse_conntrack_line(const char *line, char *proto, char *src_ip, unsigned int *src_port, char *dst_ip, unsigned int *dst_port, unsigned int *mark, char *state) {
    char *src_start, *dst_start, *sport_start, *dport_start, *mark_start;
    char temp_line[MAX_LINE];
    char *token;
    int field_idx = 0;

    /* Valores por defecto */
    strcpy(proto, "?");
    strcpy(src_ip, "?");
    strcpy(dst_ip, "?");
    *src_port = 0;
    *dst_port = 0;
    *mark = 0;
    strcpy(state, "?");

    /* Extraer protocolo (tercer campo) */
    strcpy(temp_line, line);
    token = strtok(temp_line, " ");
    while (token && field_idx < 4) {
        if (field_idx == 2) {
            strncpy(proto, token, 7);
            proto[7] = '\0';
        }
        field_idx++;
        token = strtok(NULL, " ");
    }

    /* Extraer src= */
    src_start = strstr(line, "src=");
    if (src_start) {
        sscanf(src_start, "src=%63s", src_ip);
    }

    /* Extraer dst= */
    dst_start = strstr(line, "dst=");
    if (dst_start) {
        sscanf(dst_start, "dst=%63s", dst_ip);
    }

    /* Extraer sport= */
    sport_start = strstr(line, "sport=");
    if (sport_start) {
        sscanf(sport_start, "sport=%u", src_port);
    }

    /* Extraer dport= */
    dport_start = strstr(line, "dport=");
    if (dport_start) {
        sscanf(dport_start, "dport=%u", dst_port);
    }

    /* Extraer mark= */
    mark_start = strstr(line, "mark=");
    if (mark_start) {
        sscanf(mark_start, "mark=%u", mark);
    }

    /* Estado COMO EN SHELL: num de protocolo para TCP */
    /* Esto es un error tremendo de interpretacion, que lo arrastramos desde shell, pero ...*/
    if (strcmp(proto, "tcp") == 0 || strcmp(proto, "6") == 0) {
        /* La shell emite "6" para TCP, NO el estado real */
        strcpy(state, "6");
    } else if (strcmp(proto, "udp") == 0 || strcmp(proto, "17") == 0) {
        strcpy(state, "stateless");
    } else {
        strcpy(state, "?");
    }
}


/* Normalizar nombre de interfaz para mostrar */
const char* normalize_iface(const char *iface) {
    if (strcmp(iface, "pppoe-wan") == 0) return "wan";
    if (strcmp(iface, "br-lan") == 0) return "lan";
    if (strncmp(iface, "local:", 6) == 0) return iface;
    return iface;
}

/* MAIN */
int main(int argc, char *argv[]) {
    FILE *fp;
    char line[MAX_LINE];
    char proto[8];
    char src_ip[64], dst_ip[64];
    unsigned int src_port, dst_port;
    unsigned int mark;
    char state[32];
    int num = 0;
    char src_comp[64], dst_comp[64];
    char src_display[128], dst_display[128];

    fp = fopen(CONNTRACK_FILE, "r");
    if (!fp) {
        fprintf(stderr, "ERROR: Cannot open %s\n", CONNTRACK_FILE);
        return 1;
    }

    while (fgets(line, sizeof(line), fp)) {
        parse_conntrack_line(line, proto, src_ip, &src_port, dst_ip, &dst_port, &mark, state);

        /* Saltar líneas mal formadas */
        if (strcmp(src_ip, "?") == 0 || strcmp(dst_ip, "?") == 0) {
            continue;
        }

        num++;

        /* Obtener interfaz */
        char *iface_raw = get_iface_for_ip(src_ip);
        const char *iface = normalize_iface(iface_raw);

        /* Estado NSS y bypass */
        const char *nss_state = get_nss_state(mark);
        const char *bypass = is_bypassed(mark) ? "YES" : "NO";

        /* Comprimir IPv6 si es necesario */
        if (strchr(src_ip, ':')) {
            compress_ipv6(src_comp, src_ip);
            snprintf(src_display, sizeof(src_display), "%s#%u", src_comp, src_port);
        } else {
            snprintf(src_display, sizeof(src_display), "%s#%u", src_ip, src_port);
        }

        if (strchr(dst_ip, ':')) {
            compress_ipv6(dst_comp, dst_ip);
            snprintf(dst_display, sizeof(dst_display), "%s#%u", dst_comp, dst_port);
        } else {
            snprintf(dst_display, sizeof(dst_display), "%s#%u", dst_ip, dst_port);
        }

        /* Normalizar protocolo, con el arrastre que traemos desde shell */
        if (strcmp(proto, "6") == 0) strcpy(proto, "tcp");
        else if (strcmp(proto, "17") == 0) strcpy(proto, "udp");
        else if (strcmp(proto, "1") == 0) strcpy(proto, "icmp");

        /* Output con el m ismo formato pipes que shell */
        printf("%d|%s|%s|%s|%s|%s|%s|%u|%s\n", num, proto, src_display, dst_display, iface, nss_state, bypass, mark, state);
    }

    fclose(fp);
    return 0;
}
