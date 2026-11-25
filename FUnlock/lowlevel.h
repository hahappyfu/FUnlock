#ifndef lowlevel_h
#define lowlevel_h
#include <stdbool.h>
#include <stddef.h>

void funlock_sleepDisplay(void);
void funlock_wakeDisplay(void);
void funlock_releaseWakeAssertion(void);
void funlock_renewPresenceKeepAlive(void);
void funlock_releasePresenceKeepAlive(void);
void funlock_secureZero(void *ptr, size_t size);
int SACLockScreenImmediate(void);

#endif /* lowlevel_h */
