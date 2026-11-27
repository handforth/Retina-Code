// hashtable_unterminated.c — second C sample.
// A small open-addressing hash table; ends inside an unterminated block comment.

#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HT_INITIAL_CAP   16u
#define HT_LOAD_NUM      3
#define HT_LOAD_DEN      4
#define HT_TOMBSTONE     ((char *)(uintptr_t)1)
#define HT_IS_LIVE(e)    ((e)->key != NULL && (e)->key != HT_TOMBSTONE)

#define HT_FOREACH(ht, it) \
    for (size_t it##_i = 0; it##_i < (ht)->cap; ++it##_i) \
        for (HtEntry *it = &(ht)->entries[it##_i]; it && HT_IS_LIVE(it); it = NULL)

#if defined(__GNUC__) || defined(__clang__)
#  define LIKELY(x)   __builtin_expect(!!(x), 1)
#  define UNLIKELY(x) __builtin_expect(!!(x), 0)
#  define UNUSED      __attribute__((unused))
#else
#  define LIKELY(x)   (x)
#  define UNLIKELY(x) (x)
#  define UNUSED
#endif

#if 0
/* disabled experimental code with an unterminated "string
static void experimental(void) { 'x }
#endif

typedef struct {
    char    *key;
    int64_t  value;
    uint64_t hash;
} HtEntry;

typedef struct {
    HtEntry *entries;
    size_t   cap;
    size_t   len;
    size_t   tombstones;
} HashTable;

/* FNV-1a, 64-bit */
static uint64_t ht_hash(const char *s) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
        h ^= *p;
        h *= 0x100000001b3ULL;
    }
    return h;
}

static char *ht_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *d = malloc(n);
    return d ? memcpy(d, s, n) : NULL;
}

int ht_init(HashTable *ht, size_t cap) {
    if (cap < HT_INITIAL_CAP) cap = HT_INITIAL_CAP;
    /* round up to a power of two */
    cap--;
    for (size_t shift = 1; shift < sizeof(size_t) * 8; shift <<= 1) cap |= cap >> shift;
    cap++;
    ht->entries = calloc(cap, sizeof *ht->entries);
    if (UNLIKELY(!ht->entries)) return -ENOMEM;
    ht->cap = cap;
    ht->len = ht->tombstones = 0;
    return 0;
}

void ht_free(HashTable *ht) {
    HT_FOREACH(ht, e) free(e->key);
    free(ht->entries);
    memset(ht, 0, sizeof *ht);
}

static HtEntry *ht_find_slot(HtEntry *entries, size_t cap, const char *key, uint64_t h) {
    size_t mask = cap - 1, i = (size_t)h & mask;
    HtEntry *first_tomb = NULL;
    for (;;) {
        HtEntry *e = &entries[i];
        if (e->key == NULL) return first_tomb ? first_tomb : e;
        if (e->key == HT_TOMBSTONE) {
            if (!first_tomb) first_tomb = e;
        } else if (e->hash == h && strcmp(e->key, key) == 0) {
            return e;
        }
        i = (i + 1) & mask;
    }
}

static int ht_grow(HashTable *ht) {
    size_t new_cap = ht->cap * 2;
    HtEntry *fresh = calloc(new_cap, sizeof *fresh);
    if (!fresh) return -ENOMEM;
    HT_FOREACH(ht, e) {
        HtEntry *slot = ht_find_slot(fresh, new_cap, e->key, e->hash);
        *slot = *e;
    }
    free(ht->entries);
    ht->entries = fresh;
    ht->cap = new_cap;
    ht->tombstones = 0;
    return 0;
}

int ht_set(HashTable *ht, const char *key, int64_t value) {
    if ((ht->len + ht->tombstones + 1) * HT_LOAD_DEN > ht->cap * HT_LOAD_NUM) {
        int rc = ht_grow(ht);
        if (rc) return rc;
    }
    uint64_t h = ht_hash(key);
    HtEntry *e = ht_find_slot(ht->entries, ht->cap, key, h);
    if (HT_IS_LIVE(e)) {
        e->value = value;
        return 0;
    }
    if (e->key == HT_TOMBSTONE) ht->tombstones--;
    e->key = ht_strdup(key);
    if (!e->key) return -ENOMEM;
    e->value = value;
    e->hash = h;
    ht->len++;
    return 0;
}

int ht_get(const HashTable *ht, const char *key, int64_t *out) {
    HtEntry *e = ht_find_slot(ht->entries, ht->cap, key, ht_hash(key));
    if (!HT_IS_LIVE(e)) return 0;
    if (out) *out = e->value;
    return 1;
}

int ht_del(HashTable *ht, const char *key) {
    HtEntry *e = ht_find_slot(ht->entries, ht->cap, key, ht_hash(key));
    if (!HT_IS_LIVE(e)) return 0;
    free(e->key);
    e->key = HT_TOMBSTONE;
    ht->len--;
    ht->tombstones++;
    return 1;
}

int main(void) {
    HashTable ht;
    assert(ht_init(&ht, 4) == 0);
    const char *words[] = { "alpha", "beta", "gamma", "delta", "it's", "\"quoted\"", "tab\there", "" };
    for (size_t i = 0; i < sizeof words / sizeof *words; ++i) {
        ht_set(&ht, words[i], (int64_t)(i * i));
    }
    ht_del(&ht, "beta");
    int64_t v = -1;
    printf("gamma -> %" PRId64 " (found=%d)\n", ht_get(&ht, "gamma", &v) ? v : -1, ht_get(&ht, "gamma", NULL));
    printf("len=%zu cap=%zu tomb=%zu\n", ht.len, ht.cap, ht.tombstones);
    HT_FOREACH(&ht, e) printf("  '%s' = %lld (0x%016" PRIx64 ")\n", e->key, (long long)e->value, e->hash);
    ht_free(&ht);
    return 0;
}

/* Implementation notes — this comment is never closed.
 *   - tombstones are reclaimed on grow
 *   - "strings" and 'chars' here are just comment text
 *   #define NOT_A_MACRO 1
 *   // nor is this a line comment
 *   /* and this inner opener does not nest in C
 */  <- that WAS a closer, so the next comment is the real unterminated one
/* reopened and left open:
int not_code(void) { return 0; }
