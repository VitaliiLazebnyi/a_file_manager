#include "fuzzc.h"
#include <execinfo.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define FZ_ASAN 1
const char *__asan_default_options(void) {
    return "abort_on_error=1:quarantine_size_mb=16:max_allocation_size_mb=1024:allocator_may_return_null=0:detect_stack_use_after_return=0:print_summary=1:malloc_context_size=8:detect_container_overflow=0";
}
#endif
#endif

// ---- coverage -------------------------------------------------------------------------------
#define MAX_REGIONS 64
static uint8_t *reg_start[MAX_REGIONS], *reg_stop[MAX_REGIONS];
static uint8_t *virgin[MAX_REGIONS];
static int nreg;

void __sanitizer_cov_8bit_counters_init(uint8_t *start, uint8_t *stop) {
    for (int i = 0; i < nreg; i++) if (reg_start[i] == start) return;
    if (nreg == MAX_REGIONS || start == stop) return;
    reg_start[nreg] = start; reg_stop[nreg] = stop;
    virgin[nreg] = calloc((size_t)(stop - start), 1);
    nreg++;
}
void __sanitizer_cov_pcs_init(const uintptr_t *b, const uintptr_t *e) { (void)b; (void)e; }

static inline uint8_t bucket(uint8_t c) {
    if (c == 1) return 1; if (c == 2) return 2; if (c == 3) return 4; if (c < 8) return 8;
    if (c < 16) return 16; if (c < 32) return 32; if (c < 128) return 64; return 128;
}
int fz_cov_collect(void) {
    int fresh = 0;
    for (int r = 0; r < nreg; r++) {
        uint8_t *p = reg_start[r], *v = virgin[r];
        size_t n = (size_t)(reg_stop[r] - p), i = 0;
        for (; i + 8 <= n; i += 8) {
            uint64_t w; memcpy(&w, p + i, 8);
            if (!w) continue;
            for (size_t j = i; j < i + 8; j++) if (p[j]) { uint8_t b = bucket(p[j]); if (!(v[j] & b)) { v[j] |= b; fresh = 1; } p[j] = 0; }
        }
        for (; i < n; i++) if (p[i]) { uint8_t b = bucket(p[i]); if (!(v[i] & b)) { v[i] |= b; fresh = 1; } p[i] = 0; }
    }
    return fresh;
}
void fz_cov_reset(void) { for (int r = 0; r < nreg; r++) memset(reg_start[r], 0, (size_t)(reg_stop[r] - reg_start[r])); }
long fz_cov_edges(void) { long c = 0; for (int r = 0; r < nreg; r++) { size_t n = (size_t)(reg_stop[r] - reg_start[r]); for (size_t i = 0; i < n; i++) if (virgin[r][i]) c++; } return c; }
long fz_cov_total(void) { long c = 0; for (int r = 0; r < nreg; r++) c += reg_stop[r] - reg_start[r]; return c; }

// ---- time, memory ---------------------------------------------------------------------------
double fz_now(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
uint64_t fz_rss(void) {
    task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

// ---- crash handlers -------------------------------------------------------------------------
static void say(const char *s) { write(2, s, strlen(s)); }
static void dump(const char *head, int code) {
    say(head);
    char line[96]; snprintf(line, sizeof line, "FZ-LOAD 0x%lx\n", (unsigned long)_dyld_get_image_header(0)); say(line);
    void *bt[96]; int n = backtrace(bt, 96);
    backtrace_symbols_fd(bt, n, 2);
    say("FZ-END\n");
    _exit(code);
}
static void on_crash(int sig) {
    char head[64]; snprintf(head, sizeof head, "\nFZ-CRASH signal %d\n", sig);
    dump(head, 128 + sig);
}
static void on_timeout(int sig) { (void)sig; dump("\nFZ-TIMEOUT\n", 77); }
static void on_rss(int sig) { (void)sig; dump("\nFZ-RSS\n", 78); }
void fz_fail(const char *text) { say("\nFZ-PROPERTY "); say(text); say("\nFZ-END\n"); _exit(79); }

static void hook(int sig, void (*fn)(int)) {
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_handler = fn; sa.sa_flags = SA_ONSTACK; sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, NULL);
}
static pthread_t main_thread;
void fz_install_handlers(void) {
    main_thread = pthread_self();
    static char alt[1 << 17];
    stack_t ss; ss.ss_sp = alt; ss.ss_size = sizeof alt; ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
    hook(SIGTRAP, on_crash); hook(SIGILL, on_crash); hook(SIGFPE, on_crash); hook(SIGABRT, on_crash);
#ifndef FZ_ASAN
    hook(SIGSEGV, on_crash); hook(SIGBUS, on_crash);
#endif
    hook(SIGUSR2, on_timeout); hook(SIGUSR1, on_rss);
    signal(SIGPIPE, SIG_IGN);
}

// ---- watchdog -------------------------------------------------------------------------------
static volatile double exec_started;   // 0 = idle
static double wd_timeout; static uint64_t wd_rss;
void fz_exec_begin(void) { exec_started = fz_now(); }
void fz_exec_end(void) { exec_started = 0; }
static void *watchdog(void *arg) {
    (void)arg;
    for (;;) {
        usleep(20000);
        double s = exec_started;
        if (s != 0 && fz_now() - s > wd_timeout) { pthread_kill(main_thread, SIGUSR2); sleep(2); say("\nFZ-TIMEOUT (main thread unresponsive)\nFZ-END\n"); _exit(77); }
        if (wd_rss && fz_rss() > wd_rss) { pthread_kill(main_thread, SIGUSR1); sleep(2); say("\nFZ-RSS (main thread unresponsive)\nFZ-END\n"); _exit(78); }
    }
    return NULL;
}
void fz_watchdog_start(double timeoutSec, uint64_t rssLimitBytes) {
    wd_timeout = timeoutSec; wd_rss = rssLimitBytes;
    pthread_t t; pthread_create(&t, NULL, watchdog, NULL); pthread_detach(t);
}
