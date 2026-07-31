#ifndef lowlevel_h
#define lowlevel_h
#include <stdbool.h>

void funlock_sleepDisplay(void);
void funlock_wakeDisplay(void);
void funlock_releaseWakeAssertion(void);
int SACLockScreenImmediate(void);

#endif /* lowlevel_h */
