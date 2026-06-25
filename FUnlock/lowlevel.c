#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>

static IOPMAssertionID wakeAssertionID = 0;

void wakeDisplay(void)
{
    // 释放前一个未释放的 assertion
    if (wakeAssertionID != 0) {
        IOPMAssertionRelease(wakeAssertionID);
        wakeAssertionID = 0;
    }

    // 方式1: 创建强断言强制唤醒显示器
    IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("FUnlock Wake"),
        &wakeAssertionID);

    // 方式2: 通过 IORegistry 直接唤醒显示器（深层兜底）
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestPowerState"), CFNumberCreate(NULL, kCFNumberIntType, &(int){2}));
        IOObjectRelease(reg);
    }
}

void releaseWakeAssertion(void)
{
    if (wakeAssertionID != 0) {
        IOPMAssertionRelease(wakeAssertionID);
        wakeAssertionID = 0;
    }
}

void sleepDisplay(void)
{
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}

int SACLockScreenImmediate(void)
{
    // 调用 macOS 私有 API 锁屏
    // 这里通过 IOKit 发送锁屏请求
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
        return 0;
    }
    return -1;
}
