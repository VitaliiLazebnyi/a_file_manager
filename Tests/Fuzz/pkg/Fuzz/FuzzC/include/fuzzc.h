#include <stdint.h>
#include <stddef.h>
void fz_install_handlers(void);
void fz_watchdog_start(double timeoutSec, uint64_t rssLimitBytes);
void fz_exec_begin(void);
void fz_exec_end(void);
/// 1 when the counters of the finished execution show something new; clears the counters.
int fz_cov_collect(void);
void fz_cov_reset(void);
long fz_cov_edges(void);
long fz_cov_total(void);
uint64_t fz_rss(void);
double fz_now(void);
void fz_fail(const char *text) __attribute__((noreturn));
