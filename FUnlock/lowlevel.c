#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>
#include <CoreGraphics/CoreGraphics.h>

static IOPMAssertionID wakeAssertionID = 0;

void funlock_wakeDisplay(void)
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

void funlock_releaseWakeAssertion(void)
{
    if (wakeAssertionID != 0) {
        IOPMAssertionRelease(wakeAssertionID);
        wakeAssertionID = 0;
    }
}

void funlock_sleepDisplay(void)
{
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}

int SACLockScreenImmediate(void)
{
    // 发送真正的系统锁屏快捷键：Control+Command+Q（macOS 内置"锁定屏幕"快捷键）
    // 注意：旧实现（IORequestIdle）只会熄灭屏幕、不会锁定会话，本函数改用 CGEvent 模拟真实按键
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (src == NULL) {
        // 事件源创建失败（罕见），降级为关屏兜底
        goto fallback;
    }

    // 1. Control+Command 按下（keyCode 59 = Control 键）
    CGEventRef modsDown = CGEventCreateKeyboardEvent(src, 59, true);
    // 2. Q 按下（virtualKey 12）
    CGEventRef qDown = CGEventCreateKeyboardEvent(src, 12, true);
    // 3. Q 抬起
    CGEventRef qUp = CGEventCreateKeyboardEvent(src, 12, false);
    // 4. Control+Command 抬起
    CGEventRef modsUp = CGEventCreateKeyboardEvent(src, 59, false);

    if (modsDown == NULL || qDown == NULL || qUp == NULL || modsUp == NULL) {
        // 事件构造失败（常见于无辅助功能权限），释放已创建对象后降级为关屏兜底
        if (modsDown) CFRelease(modsDown);
        if (qDown) CFRelease(qDown);
        if (qUp) CFRelease(qUp);
        if (modsUp) CFRelease(modsUp);
        CFRelease(src);
        goto fallback;
    }

    CGEventSetFlags(modsDown, kCGEventFlagMaskControl | kCGEventFlagMaskCommand);
    CGEventSetFlags(qDown, kCGEventFlagMaskControl | kCGEventFlagMaskCommand);
    CGEventSetFlags(qUp, kCGEventFlagMaskControl | kCGEventFlagMaskCommand);
    CGEventSetFlags(modsUp, kCGEventFlagMaskControl | kCGEventFlagMaskCommand);

    CGEventPost(kCGHIDEventTap, modsDown);
    CGEventPost(kCGHIDEventTap, qDown);
    CGEventPost(kCGHIDEventTap, qUp);
    CGEventPost(kCGHIDEventTap, modsUp);

    CFRelease(modsDown);
    CFRelease(qDown);
    CFRelease(qUp);
    CFRelease(modsUp);
    CFRelease(src);
    return 0;

fallback:
    // 兜底：CGEvent 不可用时退化为原来的 IORequestIdle 关屏（至少让屏幕熄灭）
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
        return 0;
    }
    return -1;
}
