#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <os/lock.h>

static IOPMAssertionID wakeAssertionID = 0;
static IOPMAssertionID preventSleepAssertionID = 0;
// 两个 assertion ID 会被主线程（注入前奏）与唤醒重试共享，统一保护
static os_unfair_lock assertionLock = OS_UNFAIR_LOCK_INIT;

void funlock_wakeDisplay(void)
{
    os_unfair_lock_lock(&assertionLock);
    // 释放前一个未释放的 assertion
    if (wakeAssertionID != 0) {
        IOPMAssertionRelease(wakeAssertionID);
        wakeAssertionID = 0;
    }
    if (preventSleepAssertionID != 0) {
        IOPMAssertionRelease(preventSleepAssertionID);
        preventSleepAssertionID = 0;
    }

    // 方式1: 声明用户活动（主动点亮已休眠显示器）
    IOPMAssertionDeclareUserActivity(
        CFSTR("FUnlock Wake Activity"),
        kIOPMUserActiveLocal,
        &wakeAssertionID);

    // 方式2: 创建强断言防止再次闲置休眠
    IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("FUnlock Keep Awake"),
        &preventSleepAssertionID);
    os_unfair_lock_unlock(&assertionLock);

    // 方式3: 通过 IORegistry 直接唤醒显示器（深层兜底，Intel 平台）
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        int powerState = 2;
        CFNumberRef powerNum = CFNumberCreate(NULL, kCFNumberIntType, &powerState);
        if (powerNum) {
            IORegistryEntrySetCFProperty(reg, CFSTR("IORequestPowerState"), powerNum);
            CFRelease(powerNum);
        }
        IOObjectRelease(reg);
    }
}

void funlock_releaseWakeAssertion(void)
{
    os_unfair_lock_lock(&assertionLock);
    if (wakeAssertionID != 0) {
        IOPMAssertionRelease(wakeAssertionID);
        wakeAssertionID = 0;
    }
    if (preventSleepAssertionID != 0) {
        IOPMAssertionRelease(preventSleepAssertionID);
        preventSleepAssertionID = 0;
    }
    os_unfair_lock_unlock(&assertionLock);
}

void funlock_sleepDisplay(void)
{
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}

// 真 SACLockScreenImmediate：从 login.framework 动态加载（不需要辅助功能权限，
// 也不依赖模拟 Control+Command+Q 的修饰键/前台窗口状态）。
typedef void (*SACLockScreenFn)(void);

static SACLockScreenFn lockScreenFn = NULL;
static pthread_once_t lockScreenOnce = PTHREAD_ONCE_INIT;

static void loadLockScreenFn(void)
{
    void *handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
                          RTLD_LAZY);
    if (handle != NULL) {
        lockScreenFn = (SACLockScreenFn)dlsym(handle, "SACLockScreenImmediate");
    }
}

int SACLockScreenImmediate(void)
{
    pthread_once(&lockScreenOnce, loadLockScreenFn);
    if (lockScreenFn != NULL) {
        lockScreenFn();
        return 0;
    }

    // 私有框架不可用时仅降级为关屏（不会锁定会话），由上层回读验证并回滚状态
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
        return 0;
    }
    return -1;
}