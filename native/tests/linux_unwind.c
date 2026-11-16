#include <assert.h>
#include <pthread.h>
#include <unistd.h>

static int blocked[2], ready[2], cleaned;

static void cleanup(void *unused) {
  (void)unused;
  cleaned = 1;
}

static void *reader(void *unused) {
  (void)unused;
  char byte;
  pthread_cleanup_push(cleanup, NULL);
  assert(write(ready[1], "r", 1) == 1);
  read(blocked[0], &byte, 1);
  pthread_cleanup_pop(1);
  return NULL;
}

int main(void) {
  pthread_t thread;
  void *result;
  char byte;
  assert(pipe(blocked) == 0 && pipe(ready) == 0);
  assert(pthread_create(&thread, NULL, reader, NULL) == 0);
  assert(read(ready[0], &byte, 1) == 1);
  assert(pthread_cancel(thread) == 0);
  assert(pthread_join(thread, &result) == 0);
  assert(result == PTHREAD_CANCELED && cleaned == 1);
  return 0;
}
