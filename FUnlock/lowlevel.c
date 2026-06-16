#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>

void wakeDisplay(void)
{
    // 方式1: 声明用户活动（可能不足以唤醒深度休眠的显示器）
    static IOPMAssertionID assertionID;
    IOPMAssertionDeclareUserActivity(CFSTR("BLEUnlock"), kIOPMUserActiveLocal, &assertionID);

    // 方式2: 创建强断言强制唤醒显示器
    static IOPMAssertionID preventSleepID;
    IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("BLEUnlock Wake"),
        &preventSleepID);

    // 方式3: 通过 IORegistry 直接唤醒显示器
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestPowerState"), CFNumberCreate(NULL, kCFNumberIntType, &(int){2}));
        IOObjectRelease(reg);
    }
}

void sleepDisplay(void)
{
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}
