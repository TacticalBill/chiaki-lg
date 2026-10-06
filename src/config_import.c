/* config_import.c — Auto-import chiaki-ng Windows/Linux settings export
 *
 * Workflow (TV-native):
 *   1. User copies chiaki-ng-Default.ini to the app directory on the TV:
 *        adb push chiaki-ng-Default.ini \
 *          /media/developer/apps/usr/palm/applications/org.homebrew.chiaki/
 *   2. On next launch, config_try_import_chiaki_ini() detects the INI and
 *      extracts all registration keys into config.json automatically.
 *   3. The INI file is renamed to *.imported so it is not re-processed
 *      automatically on next launch.
 *   4. If "host" was already set in config.json it is preserved.
 *      If not, the app shows the setup screen prompting for the PS5 IP only.
 *   5. If the user presses Import Config again, the *.imported file is
 *      used as a fallback — re-importing works without a fresh copy.
 *      Only CI_FILE_NOT_FOUND is returned if neither file exists.
 *
 * chiaki-ng stores keys as Qt @ByteArray(...) escapes.  We parse this format
 * with no external dependencies — plain C string scanning only.
 */

#include "config_import.h"
#include "app_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>

/* ── Minimal self-contained base64 encoder ─────────────────────────────────── */

static const char B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64_encode(const uint8_t *in, size_t in_len, char *out)
{
    size_t i = 0, j = 0;
    uint8_t a3[3], a4[4];
    size_t rem = in_len;

    while (rem--)
    {
        a3[i++] = *in++;
        if (i == 3)
        {
            a4[0] = (a3[0] & 0xfc) >> 2;
            a4[1] = ((a3[0] & 0x03) << 4) | ((a3[1] & 0xf0) >> 4);
            a4[2] = ((a3[1] & 0x0f) << 2) | ((a3[2] & 0xc0) >> 6);
            a4[3] = a3[2] & 0x3f;
            for (int k = 0; k < 4; k++)
                out[j++] = B64[(int)a4[k]];
            i = 0;
        }
    }
    if (i)
    {
        for (int k = i; k < 3; k++)
            a3[k] = 0;
        a4[0] = (a3[0] & 0xfc) >> 2;
        a4[1] = ((a3[0] & 0x03) << 4) | ((a3[1] & 0xf0) >> 4);
        a4[2] = ((a3[1] & 0x0f) << 2) | ((a3[2] & 0xc0) >> 6);
        a4[3] = a3[2] & 0x3f;
        for (int k = 0; k < (int)i + 1; k++)
            out[j++] = B64[(int)a4[k]];
        while (i++ < 3)
            out[j++] = '=';
    }
    out[j] = '\0';
}

/* ── Qt @ByteArray parser ────────────────────────────────────────────────────
 *
 * Parses a Qt INI @ByteArray(...) value into raw bytes.
 *
 * Qt escape sequences used inside ByteArray content:
 *   \xHH  — hex byte (1 or 2 hex digits after the x)
 *   \0    — null byte (0x00)
 *   \"    — double-quote byte (0x22) — needed because INI values may be quoted
 *   \\    — literal backslash (0x5c)
 *   other printable ASCII — literal byte
 *
 * val     : the full INI value, e.g. "@ByteArray(\x90GH!\"\xa3)"
 * out     : destination buffer for raw bytes
 * max_out : size of destination buffer
 * Returns : number of bytes written, or -1 if val is not a @ByteArray
 */
static int parse_qt_bytearray(const char *val, uint8_t *out, int max_out)
{
    static const char PREFIX[] = "@ByteArray(";
    if (strncmp(val, PREFIX, sizeof(PREFIX) - 1) != 0)
        return -1;

    const char *p = val + sizeof(PREFIX) - 1;
    int n = 0;

    while (*p && *p != ')' && n < max_out)
    {
        if (*p == '\\' && p[1])
        {
            p++;
            if (*p == 'x' || *p == 'X')
            {
                /* \xHH — 1 or 2 hex digits */
                p++;
                char hex[3] = {0};
                if (isxdigit((unsigned char)*p))
                    hex[0] = *p++;
                if (isxdigit((unsigned char)*p))
                    hex[1] = *p++;
                out[n++] = (uint8_t)strtol(hex, NULL, 16);
            }
            else if (*p == '0')
            {
                out[n++] = 0x00;
                p++;
            }
            else if (*p == 'n')
            {
                out[n++] = 0x0a;
                p++;
            }
            else if (*p == 'r')
            {
                out[n++] = 0x0d;
                p++;
            }
            else if (*p == 't')
            {
                out[n++] = 0x09;
                p++;
            }
            else if (*p == 'a')
            {
                out[n++] = 0x07;
                p++;
            }
            else if (*p == 'b')
            {
                out[n++] = 0x08;
                p++;
            }
            else if (*p == 'f')
            {
                out[n++] = 0x0c;
                p++;
            }
            else if (*p == 'v')
            {
                out[n++] = 0x0b;
                p++;
            }
            else if (*p == '"')
            {
                out[n++] = 0x22;
                p++;
            }
            else if (*p == '\\')
            {
                out[n++] = 0x5c;
                p++;
            }
            else
            {
                /* Unknown escape — keep char after backslash */
                out[n++] = (uint8_t)*p++;
            }
        }
        else
        {
            out[n++] = (uint8_t)*p++;
        }
    }
    return n;
}

/* ── INI parsing ─────────────────────────────────────────────────────────────
 * Qt's INI uses backslashes in key names (e.g. "1\rp_key") which standard
 * parsers mangle.  We scan line-by-line ourselves.
 */

typedef struct
{
    char rp_regist_key[1024]; /* raw @ByteArray string */
    char rp_key[1024];
    int rp_key_type;
    int target; /* PS5 if >= 1000000 */
    char server_mac[512];

    char psn_account_id[256];     /* already base64, may be quoted */
    char psn_refresh_token[2048]; /* OAuth2 refresh token (may be quoted) */
    char codec[32];               /* "h265" / "h264" */
    int bitrate;                  /* kbps */
    bool sleep_on_exit;
} IniData;

/* Strip leading/trailing whitespace in-place */
static char *str_trim(char *s)
{
    while (*s == ' ' || *s == '\t')
        s++;
    char *end = s + strlen(s) - 1;
    while (end > s && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n'))
        *end-- = '\0';
    return s;
}

static void process_line(IniData *d, const char *section,
                         const char *key, const char *raw_val)
{
    /* Skip val leading whitespace */
    while (*raw_val == ' ' || *raw_val == '\t')
        raw_val++;

    if (strcmp(section, "registered_hosts") == 0)
    {
        /* Only process "1\..." entries (first registered host) */
        if (key[0] != '1' || key[1] != '\\')
            return;
        const char *field = key + 2;

        if (!strcmp(field, "rp_regist_key"))
            snprintf(d->rp_regist_key, sizeof(d->rp_regist_key), "%s", raw_val);
        else if (!strcmp(field, "rp_key"))
            snprintf(d->rp_key, sizeof(d->rp_key), "%s", raw_val);
        else if (!strcmp(field, "rp_key_type"))
            d->rp_key_type = atoi(raw_val);
        else if (!strcmp(field, "target"))
            d->target = atoi(raw_val);
        else if (!strcmp(field, "server_mac"))
            snprintf(d->server_mac, sizeof(d->server_mac), "%s", raw_val);
    }
    else if (strcmp(section, "settings") == 0)
    {
        /* Strip surrounding quotes from string values */
        char val[1024];
        snprintf(val, sizeof(val), "%s", raw_val);
        if (val[0] == '"')
        {
            memmove(val, val + 1, strlen(val));
            size_t len = strlen(val);
            if (len > 0 && val[len - 1] == '"')
                val[len - 1] = '\0';
        }

        if (!strcmp(key, "psn_account_id"))
            snprintf(d->psn_account_id, sizeof(d->psn_account_id), "%s", val);
        else if (!strcmp(key, "psn_refresh_token"))
            snprintf(d->psn_refresh_token, sizeof(d->psn_refresh_token), "%s", val);
        else if (!strcmp(key, "codec_local_ps5") || !strcmp(key, "codec_local_ps4"))
            snprintf(d->codec, sizeof(d->codec), "%s", val);
        else if (!strcmp(key, "bitrate_local_ps5") || !strcmp(key, "bitrate_local_ps4"))
            d->bitrate = atoi(val);
        else if (!strcmp(key, "disconnect_action"))
            d->sleep_on_exit = (strstr(val, "sleep") != NULL);
    }
}

/* ── Minimal host extraction from existing config.json ───────────────────────
 * We only need to preserve "host" (and optionally video params).
 * We avoid pulling json-c in here by doing a simple search, since config_load
 * has not been called yet at import time.
 */
static void extract_existing_host(const char *config_path,
                                  char *host_out, size_t host_len,
                                  int *width, int *height, int *fps,
                                  char *refresh_out, size_t refresh_len)
{
    *host_out = '\0';
    if (refresh_out && refresh_len)
        *refresh_out = '\0';
    *width = 1920;
    *height = 1080;
    *fps = 60;

    FILE *f = fopen(config_path, "r");
    if (!f)
        return;
    char buf[8192];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    /* Find "host": "..." */
    const char *p = strstr(buf, "\"host\"");
    if (p)
    {
        p = strchr(p + 6, '"');
        if (p)
        {
            p++;
            const char *e = strchr(p, '"');
            if (e && (size_t)(e - p) < host_len)
            {
                memcpy(host_out, p, (size_t)(e - p));
                host_out[e - p] = '\0';
            }
        }
    }

    /* Optional: preserve existing PSN refresh token */
    if (refresh_out && refresh_len)
    {
        const char *rp = strstr(buf, "\"psn_refresh_token\"");
        if (rp)
        {
            rp = strchr(rp + 18, '"');
            if (rp)
            {
                rp++;
                const char *re = strchr(rp, '"');
                if (re && (size_t)(re - rp) < refresh_len)
                {
                    memcpy(refresh_out, rp, (size_t)(re - rp));
                    refresh_out[re - rp] = '\0';
                }
            }
        }
    }

    /* Optional: preserve video dimensions */
    const char *wp = strstr(buf, "\"video_width\"");
    if (wp)
    {
        int v = atoi(strchr(wp, ':') + 1);
        if (v > 0)
            *width = v;
    }
    const char *hp = strstr(buf, "\"video_height\"");
    if (hp)
    {
        int v = atoi(strchr(hp, ':') + 1);
        if (v > 0)
            *height = v;
    }
    const char *fp2 = strstr(buf, "\"video_fps\"");
    if (fp2)
    {
        int v = atoi(strchr(fp2, ':') + 1);
        if (v > 0)
            *fps = v;
    }
}

/* ── JSON string escape ──────────────────────────────────────────────────────
 * Minimal escaping for values we write into JSON.
 */
static void json_str(const char *in, char *out, size_t out_len)
{
    size_t j = 0;
    for (; *in && j + 3 < out_len; in++)
    {
        unsigned char c = (unsigned char)*in;
        if (c == '"' || c == '\\')
            out[j++] = '\\';
        out[j++] = (char)c;
    }
    out[j] = '\0';
}

/* ══════════════════════════════════════════════════════════════════════════════
 * config_try_import_chiaki_ini()
 *
 * Checks for a chiaki-ng INI file at ini_path (falling back to
 * ini_path.imported if the original is not found), parses it, and writes
 * the extracted registration keys into config.json at config_path.
 *
 * Returns:
 *   CI_FILE_NOT_FOUND         — neither INI nor .imported file present
 *   CI_SUCCESS                — imported OK, host was already set or preserved
 *   CI_SUCCESS_NEEDS_HOST     — imported OK but host is blank; user must add it
 *   CI_PARSE_ERROR            — INI was found but required fields are missing
 *   CI_WRITE_ERROR            — could not write config.json
 * ══════════════════════════════════════════════════════════════════════════════ */
ChiakiImportResult config_try_import_chiaki_ini(
    const char *ini_path,
    const char *config_path)
{
    /* ── Does the INI file exist?  Try original, then .imported fallback ──── */
    char imported_path[512];
    snprintf(imported_path, sizeof(imported_path), "%s.imported", ini_path);

    const char *actual_path = NULL;
    FILE *probe = fopen(ini_path, "r");
    if (probe)
    {
        actual_path = ini_path;
        fclose(probe);
    }
    else
    {
        probe = fopen(imported_path, "r");
        if (probe)
        {
            actual_path = imported_path;
            fclose(probe);
        }
        else
        {
            return CI_FILE_NOT_FOUND;
        }
    }

    bool from_original = (actual_path == ini_path);
    app_log_always("[IMPORT] Found chiaki-ng export: %s%s\n",
                   actual_path, from_original ? "" : " (re-import)");
    app_log_always("[IMPORT] Importing registration keys into config.json...\n");

    /* ── Parse the INI ───────────────────────────────────────────────────── */
    FILE *f = fopen(actual_path, "r");
    if (!f)
        return CI_FILE_NOT_FOUND;

    IniData d;
    memset(&d, 0, sizeof(d));
    d.target = 1000100;
    d.bitrate = 15000;
    snprintf(d.codec, sizeof(d.codec), "h265");

    char section[128] = "";
    char line[2048];

    while (fgets(line, sizeof(line), f))
    {
        /* Strip newlines */
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';

        if (len == 0 || line[0] == ';' || line[0] == '#')
            continue;

        if (line[0] == '[' && line[len - 1] == ']')
        {
            snprintf(section, sizeof(section), "%.*s", (int)(len - 2), line + 1);
            continue;
        }

        char *eq = strchr(line, '=');
        if (!eq)
            continue;
        *eq = '\0';
        char *key = str_trim(line);
        char *val = eq + 1; /* keep leading whitespace for ByteArrays */

        process_line(&d, section, key, val);
    }
    fclose(f);

    /* ── Validate ─────────────────────────────────────────────────────────── */
    if (!d.rp_regist_key[0])
    {
        app_log_always("[IMPORT] ERROR: rp_regist_key not found — is this a chiaki-ng export?\n");
        return CI_PARSE_ERROR;
    }
    if (!d.rp_key[0])
    {
        app_log_always("[IMPORT] ERROR: rp_key not found\n");
        return CI_PARSE_ERROR;
    }
    if (!d.psn_account_id[0])
    {
        app_log_always("[IMPORT] ERROR: psn_account_id not found in [settings]\n");
        return CI_PARSE_ERROR;
    }

    /* ── Decode ByteArrays → base64 ─────────────────────────────────────── */
    uint8_t raw[256];
    char registered_key_b64[512];
    char rp_key_b64[512];
    char ps5_mac[32] = "";

    int rk_len = parse_qt_bytearray(d.rp_regist_key, raw, sizeof(raw));
    if (rk_len < 0)
    {
        app_log_always("[IMPORT] ERROR: rp_regist_key is not a valid @ByteArray\n");
        return CI_PARSE_ERROR;
    }
    b64_encode(raw, (size_t)rk_len, registered_key_b64);
    app_log_always("[IMPORT] registered_key: %d bytes → %s\n", rk_len, registered_key_b64);

    int rpk_len = parse_qt_bytearray(d.rp_key, raw, sizeof(raw));
    if (rpk_len < 0)
    {
        app_log_always("[IMPORT] ERROR: rp_key is not a valid @ByteArray\n");
        return CI_PARSE_ERROR;
    }
    b64_encode(raw, (size_t)rpk_len, rp_key_b64);
    app_log_always("[IMPORT] rp_key: %d bytes → %s\n", rpk_len, rp_key_b64);

    if (d.server_mac[0])
    {
        int mac_len = parse_qt_bytearray(d.server_mac, raw, sizeof(raw));
        if (mac_len == 6)
        {
            snprintf(ps5_mac, sizeof(ps5_mac),
                     "%02x:%02x:%02x:%02x:%02x:%02x",
                     raw[0], raw[1], raw[2], raw[3], raw[4], raw[5]);
            app_log_always("[IMPORT] ps5_mac: %s\n", ps5_mac);
        }
    }

    bool ps5 = (d.target >= 1000000);

    /* ── Preserve host and video settings from any existing config.json ───── */
    char host[256];
    int vid_w, vid_h, vid_fps;
    char existing_refresh[2048] = "";
    extract_existing_host(config_path, host, sizeof(host), &vid_w, &vid_h, &vid_fps,
                          existing_refresh, sizeof(existing_refresh));

    if (host[0])
        app_log_always("[IMPORT] Preserving existing host: %s\n", host);
    else
        app_log_always("[IMPORT] No existing host — will need to be set manually\n");

    /* ── Write config.json ────────────────────────────────────────────────── */
    char esc_host[256], esc_psn[256], esc_rk[512], esc_rpk[512], esc_mac[64], esc_rt[4096];
    json_str(host, esc_host, sizeof(esc_host));
    json_str(d.psn_account_id, esc_psn, sizeof(esc_psn));
    json_str(registered_key_b64, esc_rk, sizeof(esc_rk));
    json_str(rp_key_b64, esc_rpk, sizeof(esc_rpk));
    json_str(ps5_mac, esc_mac, sizeof(esc_mac));

    const char *refresh = d.psn_refresh_token[0] ? d.psn_refresh_token : existing_refresh;
    json_str(refresh, esc_rt, sizeof(esc_rt));

    int bitrate = (d.bitrate >= 2000 && d.bitrate <= 100000) ? d.bitrate : 15000;
    const char *codec = d.codec[0] ? d.codec : (ps5 ? "h265" : "h264");

    FILE *out = fopen(config_path, "w");
    if (!out)
    {
        app_log_always("[IMPORT] ERROR: Cannot write %s\n", config_path);
        return CI_WRITE_ERROR;
    }

    fprintf(out,
            "{\n"
            "    \"host\": \"%s\",\n"
            "    \"ps5\": %s,\n"
            "    \"psn_account_id\": \"%s\",\n"
            "    \"registered_key\": \"%s\",\n"
            "    \"rp_key\": \"%s\",\n"
            "    \"rp_key_type\": %d,\n"
            "    \"video_width\": %d,\n"
            "    \"video_height\": %d,\n"
            "    \"video_fps\": %d,\n"
            "    \"video_bitrate\": %d,\n"
            "    \"video_codec\": \"%s\",\n"
            "    \"audio_volume\": 100,\n"
            "    \"wakeup\": %s,\n"
            "    \"ps5_mac\": \"%s\",\n"
            "    \"wakeup_delay_ms\": 30000,\n"
            "    \"sleep_on_exit\": %s,\n"
            "    \"log_level\": \"warning\",\n"
            "    \"psn_refresh_token\": \"%s\",\n"
            "    \"ss4s_module\": \"ndl-webos5\"\n"
            "}\n",
            esc_host,
            ps5 ? "true" : "false",
            esc_psn,
            esc_rk,
            esc_rpk,
            d.rp_key_type,
            vid_w, vid_h, vid_fps,
            bitrate,
            codec,
            ps5_mac[0] ? "true" : "false",
            esc_mac,
            d.sleep_on_exit ? "true" : "false",
            esc_rt);
    fclose(out);

    app_log_always("[IMPORT] config.json written: host=%s ps5=%d rp_key_type=%d "
                   "codec=%s bitrate=%d sleep_on_exit=%d mac=%s\n",
                   host[0] ? host : "(not set)", ps5,
                   d.rp_key_type, codec, bitrate, d.sleep_on_exit,
                   ps5_mac[0] ? ps5_mac : "(none)");

    /* ── Rename INI so we don't re-import on next auto-launch ────────────── */
    if (from_original)
    {
        char done_path[512];
        snprintf(done_path, sizeof(done_path), "%s.imported", ini_path);
        if (rename(ini_path, done_path) == 0)
            app_log_always("[IMPORT] Renamed → %s (won't auto-import)\n", done_path);
        else
            app_log_always("[IMPORT] Could not rename INI file — will re-import next launch\n");
    }
    else
    {
        app_log_always("[IMPORT] Re-imported from %s (already renamed)\n", actual_path);
    }

    return host[0] ? CI_SUCCESS : CI_SUCCESS_NEEDS_HOST;
}
