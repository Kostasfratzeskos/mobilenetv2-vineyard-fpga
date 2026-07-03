#include "json.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* ---- parser state ------------------------------------------------------ */
typedef struct { const char *p; int ok; } cursor;

static json *node(json_type t) {
    json *v = calloc(1, sizeof *v);
    if (v) v->type = t;
    return v;
}

static void skip_ws(cursor *c) {
    while (*c->p == ' ' || *c->p == '\t' || *c->p == '\n' || *c->p == '\r') c->p++;
}

static json *parse_value(cursor *c);

/* parse a quoted string body into a fresh malloc'd C string (assumes *p=='"') */
static char *parse_raw_string(cursor *c) {
    c->p++;                       /* opening quote */
    size_t cap = 16, len = 0;
    char *s = malloc(cap);
    if (!s) { c->ok = 0; return NULL; }
    while (*c->p && *c->p != '"') {
        char ch = *c->p++;
        if (ch == '\\' && *c->p) {
            char e = *c->p++;
            switch (e) {
                case 'n': ch = '\n'; break;
                case 't': ch = '\t'; break;
                case 'r': ch = '\r'; break;
                case 'b': ch = '\b'; break;
                case 'f': ch = '\f'; break;
                case '/': ch = '/';  break;
                case '\\': ch = '\\'; break;
                case '"': ch = '"';  break;
                case 'u':             /* \uXXXX: we only need ASCII fields, emit '?' */
                    for (int k = 0; k < 4 && isxdigit((unsigned char)*c->p); k++) c->p++;
                    ch = '?'; break;
                default: ch = e; break;
            }
        }
        if (len + 1 >= cap) { cap *= 2; char *n = realloc(s, cap); if (!n) { free(s); c->ok = 0; return NULL; } s = n; }
        s[len++] = ch;
    }
    if (*c->p == '"') c->p++; else c->ok = 0;
    s[len] = '\0';
    return s;
}

static json *parse_string(cursor *c) {
    json *v = node(JSON_STR);
    if (!v) { c->ok = 0; return NULL; }
    v->str = parse_raw_string(c);
    return v;
}

static json *parse_number(cursor *c) {
    char *end = NULL;
    double d = strtod(c->p, &end);
    if (end == c->p) { c->ok = 0; return NULL; }
    c->p = end;
    json *v = node(JSON_NUM);
    if (v) v->num = d;
    return v;
}

static int append(json *parent, char *key, json *child) {
    json **ni = realloc(parent->items, (parent->count + 1) * sizeof *ni);
    if (!ni) return 0;
    parent->items = ni;
    char **nk = realloc(parent->keys, (parent->count + 1) * sizeof *nk);
    if (!nk) return 0;
    parent->keys = nk;
    parent->items[parent->count] = child;
    parent->keys[parent->count]  = key;   /* NULL for arrays */
    parent->count++;
    return 1;
}

static json *parse_array(cursor *c) {
    json *v = node(JSON_ARR);
    c->p++;                                /* '[' */
    skip_ws(c);
    if (*c->p == ']') { c->p++; return v; }
    for (;;) {
        json *child = parse_value(c);
        if (!c->ok || !append(v, NULL, child)) { c->ok = 0; return v; }
        skip_ws(c);
        if (*c->p == ',') { c->p++; skip_ws(c); continue; }
        if (*c->p == ']') { c->p++; break; }
        c->ok = 0; break;
    }
    return v;
}

static json *parse_object(cursor *c) {
    json *v = node(JSON_OBJ);
    c->p++;                                /* '{' */
    skip_ws(c);
    if (*c->p == '}') { c->p++; return v; }
    for (;;) {
        skip_ws(c);
        if (*c->p != '"') { c->ok = 0; break; }
        char *key = parse_raw_string(c);
        skip_ws(c);
        if (*c->p != ':') { c->ok = 0; free(key); break; }
        c->p++;
        json *child = parse_value(c);
        if (!c->ok || !append(v, key, child)) { c->ok = 0; free(key); return v; }
        skip_ws(c);
        if (*c->p == ',') { c->p++; continue; }
        if (*c->p == '}') { c->p++; break; }
        c->ok = 0; break;
    }
    return v;
}

static json *parse_value(cursor *c) {
    skip_ws(c);
    switch (*c->p) {
        case '{': return parse_object(c);
        case '[': return parse_array(c);
        case '"': return parse_string(c);
        case 't': if (!strncmp(c->p, "true", 4))  { c->p += 4; json *v = node(JSON_BOOL); v->num = 1; return v; } break;
        case 'f': if (!strncmp(c->p, "false", 5)) { c->p += 5; json *v = node(JSON_BOOL); v->num = 0; return v; } break;
        case 'n': if (!strncmp(c->p, "null", 4))  { c->p += 4; return node(JSON_NULL); } break;
        default:  return parse_number(c);
    }
    c->ok = 0;
    return node(JSON_NULL);
}

json *json_parse(const char *text) {
    cursor c = { text, 1 };
    json *v = parse_value(&c);
    skip_ws(&c);
    if (!c.ok) { json_free(v); return NULL; }
    return v;
}

json *json_parse_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return NULL; }
    char *buf = malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[got] = '\0';
    json *v = json_parse(buf);
    free(buf);
    return v;
}

void json_free(json *v) {
    if (!v) return;
    for (int i = 0; i < v->count; i++) {
        json_free(v->items[i]);
        free(v->keys ? v->keys[i] : NULL);
    }
    free(v->items);
    free(v->keys);
    free(v->str);
    free(v);
}

/* ---- navigation -------------------------------------------------------- */
const json *json_get(const json *obj, const char *key) {
    if (!obj || obj->type != JSON_OBJ) return NULL;
    for (int i = 0; i < obj->count; i++)
        if (obj->keys[i] && !strcmp(obj->keys[i], key)) return obj->items[i];
    return NULL;
}

const json *json_at(const json *arr, int i) {
    if (!arr || arr->type != JSON_ARR) return NULL;
    if (i < 0 || i >= arr->count) return NULL;
    return arr->items[i];
}

int json_len(const json *v) { return v ? v->count : 0; }

const char *json_str   (const json *v) { return (v && v->type == JSON_STR) ? v->str : NULL; }
double      json_double(const json *v) { return (v && (v->type == JSON_NUM || v->type == JSON_BOOL)) ? v->num : 0.0; }
long        json_long  (const json *v) { return (long)json_double(v); }
int         json_int   (const json *v) { return (int)json_double(v); }
int         json_bool  (const json *v) { return json_double(v) != 0.0; }

const char *json_get_str (const json *o, const char *k)               { return json_str(json_get(o, k)); }
long        json_get_long(const json *o, const char *k, long def)     { const json *v = json_get(o, k); return v ? json_long(v) : def; }
int         json_get_int (const json *o, const char *k, int def)      { const json *v = json_get(o, k); return v ? json_int(v)  : def; }
int         json_get_bool(const json *o, const char *k, int def)      { const json *v = json_get(o, k); return v ? json_bool(v) : def; }
