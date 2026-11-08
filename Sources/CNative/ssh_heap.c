#include "CNative.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Each block carries its links in front of what libssh2 sees; 32 bytes keeps libssh2's memory 16-byte aligned.
typedef struct roam_ssh_block {
    struct roam_ssh_block *prev, *next;
    size_t size;
} __attribute__((aligned(16))) roam_ssh_block;

struct roam_ssh_heap {
    pthread_mutex_t lock;
    roam_ssh_block head;
    void *user;
};

static void link_block(roam_ssh_heap *heap, roam_ssh_block *block, size_t size) {
    block->size = size;
    pthread_mutex_lock(&heap->lock);
    block->prev = &heap->head; block->next = heap->head.next;
    heap->head.next->prev = block; heap->head.next = block;
    pthread_mutex_unlock(&heap->lock);
}
static void unlink_block(roam_ssh_heap *heap, roam_ssh_block *block) {
    pthread_mutex_lock(&heap->lock);
    block->prev->next = block->next; block->next->prev = block->prev;
    pthread_mutex_unlock(&heap->lock);
}
static void wipe(void *memory, size_t size) {
    volatile unsigned char *bytes = memory;
    while (size--) *bytes++ = 0;
}

static void *heap_alloc(size_t size, void **abstract) {
    roam_ssh_heap *heap = *abstract;
    roam_ssh_block *block = malloc(sizeof(roam_ssh_block) + size);
    if (!block) return NULL;
    link_block(heap, block, size);
    return block + 1;
}
static void heap_free(void *memory, void **abstract) {
    if (!memory) return;
    roam_ssh_block *block = (roam_ssh_block *)memory - 1;
    unlink_block(*abstract, block);
    free(block);
}
static void *heap_realloc(void *memory, size_t size, void **abstract) {
    if (!memory) return heap_alloc(size, abstract);
    roam_ssh_heap *heap = *abstract;
    roam_ssh_block *block = (roam_ssh_block *)memory - 1;
    unlink_block(heap, block);
    roam_ssh_block *moved = realloc(block, sizeof(roam_ssh_block) + size);
    if (!moved) { link_block(heap, block, block->size); return NULL; }
    link_block(heap, moved, size);
    return moved + 1;
}

roam_ssh_heap *roam_ssh_heap_create(void *user) {
    roam_ssh_heap *heap = calloc(1, sizeof(roam_ssh_heap));
    if (!heap) return NULL;
    pthread_mutex_init(&heap->lock, NULL);
    heap->head.prev = heap->head.next = &heap->head;
    heap->user = user;
    return heap;
}
LIBSSH2_SESSION *roam_ssh_session_init(roam_ssh_heap *heap) {
    return libssh2_session_init_ex(heap_alloc, heap_free, heap_realloc, heap);
}
void *roam_ssh_user(void **abstract) {
    return abstract && *abstract ? ((roam_ssh_heap *)*abstract)->user : NULL;
}
void *roam_ssh_set_user(LIBSSH2_SESSION *session, void *user) {
    roam_ssh_heap *heap = *libssh2_session_abstract(session);
    void *previous = heap->user;
    heap->user = user;
    return previous;
}
void *roam_ssh_alloc(void **abstract, size_t size) { return heap_alloc(size, abstract); }
size_t roam_ssh_heap_live(roam_ssh_heap *heap, size_t *bytes) {
    size_t count = 0, total = 0;
    pthread_mutex_lock(&heap->lock);
    for (roam_ssh_block *block = heap->head.next; block != &heap->head; block = block->next) { count++; total += block->size; }
    pthread_mutex_unlock(&heap->lock);
    if (bytes) *bytes = total;
    return count;
}
size_t roam_ssh_heap_destroy(roam_ssh_heap *heap, size_t *bytes) {
    if (!heap) { if (bytes) *bytes = 0; return 0; }
    size_t count = 0, total = 0;
    roam_ssh_block *block = heap->head.next;
    while (block != &heap->head) {
        roam_ssh_block *next = block->next;
        count++; total += block->size;
        // What libssh2 forgets can be key material.
        wipe(block + 1, block->size);
        free(block);
        block = next;
    }
    pthread_mutex_destroy(&heap->lock);
    free(heap);
    if (bytes) *bytes = total;
    return count;
}
