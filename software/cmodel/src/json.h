#ifndef JSON_H
#define JSON_H

/* =====================================================================
 *  Tiny recursive-descent JSON reader - just enough to load the export
 *  manifest. No external dependency, so the cmodel stays self-contained.
 *  Numbers are stored as double (every value we read - shapes, m0, shift
 *  - is < 2^31, so it round-trips exactly).
 * ===================================================================== */

typedef enum { JSON_NULL, JSON_BOOL, JSON_NUM, JSON_STR, JSON_ARR, JSON_OBJ } json_type;

typedef struct json json;
struct json {
    json_type type;
    double     num;    /* JSON_NUM, and JSON_BOOL (0 / 1)       */
    char      *str;    /* JSON_STR (owned)                      */
    json     **items;  /* JSON_ARR / JSON_OBJ element values    */
    char     **keys;   /* JSON_OBJ keys, parallel to items      */
    int        count;  /* number of items                       */
};

json *json_parse(const char *text);   /* NULL on parse error   */
json *json_parse_file(const char *path);
void  json_free(json *v);

/* navigation - all tolerate NULL and wrong types (return NULL / defaults) */
const json *json_get(const json *obj, const char *key);
const json *json_at (const json *arr, int i);
int         json_len(const json *v);

/* leaf coercion */
const char *json_str   (const json *v);        /* NULL if not a string   */
double      json_double(const json *v);
long        json_long  (const json *v);
int         json_int   (const json *v);
int         json_bool  (const json *v);

/* get-then-coerce convenience */
const char *json_get_str (const json *obj, const char *key);
long        json_get_long(const json *obj, const char *key, long def);
int         json_get_int (const json *obj, const char *key, int def);
int         json_get_bool(const json *obj, const char *key, int def);

#endif /* JSON_H */
