// Mac: raw HID gamepads that GameController does not list (pad_hid.h, GitHub issue #637), read on the main run loop alongside front_mac.m's GameController players.
// Each device takes a player slot as a GameController controller does; front_mac.m defines the slot side (hidpad_attach / hidpad_detach / hidpad_read).
// Skipped, so no controller is read twice: GameController's synthetic devices and the devices GameController lists. +[GCController supportsHIDDevice:] does not settle the second:
// macOS gives any HID gamepad with a pad's elements its fallback "Standard MFi Controller" personality, and the call then says yes for a pad gamecontrollerd never lists (a PowerA
// NANO, "Lic Pro Controller", vendor and product 0). So a device it says yes to waits HIDPAD_GC_WAIT seconds for its GCController (hidpad_settle, pad_hid_unlisted); with none
// it is read here, and one GameController lists later goes back to it. DM_HID_PADS=0 turns this off.
#pragma once
#import <IOKit/hid/IOHIDManager.h>
#import <GameController/GameController.h>
#import <GameController/GCSyntheticDeviceKeys.h>
#include "pad_hid.h"
#include <stdio.h>
#include <stdlib.h>

#define HIDPAD_GC_WAIT 3.0
typedef struct hid_pad { IOHIDDeviceRef hid; pad_hid st; char name[64]; double due; uint8_t gc, used, nintendo; struct hid_pad *next; } hid_pad;   // gc: supportsHIDDevice said yes; used: read here; nintendo: buttons in report 0x3F
static IOHIDManagerRef g_hidpad_manager;
static hid_pad *g_hidpads, *g_hidpads_gc;   // read here; left to GameController
static int g_hidpad_log;
static void hidpad_attach(hid_pad *d);
static void hidpad_detach(hid_pad *d);
static void hidpad_read(hid_pad *d);

static void hidpad_value(void *ctx, IOReturn result, void *sender, IOHIDValueRef v) {
    (void)sender;
    hid_pad *d = ctx; if (result != kIOReturnSuccess) return;
    IOHIDElementRef e = IOHIDValueGetElement(v);
    uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
    CFIndex x = IOHIDValueGetIntegerValue(v), min = IOHIDElementGetLogicalMin(e), max = IOHIDElementGetLogicalMax(e);
    if (page == kHIDPage_Button && usage >= 1 && usage <= 32) {
        uint32_t bit = 1u << (usage - 1), was = d->st.buttons & bit;
        d->st.buttons = x ? d->st.buttons | bit : d->st.buttons & ~bit;
        if (g_hidpad_log && x && !was) LOG("[hid] %s: button usage %u", d->name, usage);
    } else if (page == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Hatswitch) {
        d->st.hat = pad_hid_hat(x, min, max);
    } else {
        int a = pad_hid_axis_of(page, usage); if (a < 0) return;
        float n = pad_hid_norm(x, min, max);
        d->st.axis[a] = d->st.raw ? pad_hid_raw_axis(&d->st, a, n) : n;
    }
    hidpad_read(d);
}
static hid_pad **hidpad_link(hid_pad **link, IOHIDDeviceRef hid) {
    while (*link && (*link)->hid != hid) link = &(*link)->next;
    return link;
}
static void hidpad_use(hid_pad *d) {
    IOHIDDeviceRef hid = d->hid; uint8_t has[PH_AXES] = {0}; int nintendo = 0;
    NSNumber *vendor = (__bridge NSNumber *)IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDVendorIDKey)), *product = (__bridge NSNumber *)IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDProductIDKey));
    int vid = vendor.intValue, pid = product.intValue;
    NSArray *els = CFBridgingRelease(IOHIDDeviceCopyMatchingElements(hid, NULL, kIOHIDOptionsTypeNone));
    for (id o in els) {
        IOHIDElementRef e = (__bridge IOHIDElementRef)o; int a = pad_hid_axis_of(IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e));
        if (a >= 0) has[a] = 1;
        if (IOHIDElementGetUsagePage(e) == kHIDPage_Button && IOHIDElementGetReportID(e) == PAD_HID_NINTENDO_REPORT) nintendo = 1;
    }
    pad_hid_init(&d->st, getenv("DM_HID_MAP"), nintendo); memcpy(d->st.has, has, sizeof has);
    d->used = 1; d->nintendo = (uint8_t)nintendo;
    IOHIDDeviceRegisterInputValueCallback(hid, hidpad_value, d);
    hidpad_attach(d);
    // HID has no standard button numbering: the default map is 8BitDo's, so another vendor's pad may have its buttons in other places
    if (vid != PAD_HID_DEFAULT_VENDOR && !nintendo && !getenv("DM_HID_MAP"))
        LOG("controller '%s' (HID, %04x:%04x): buttons use 8BitDo's numbering; if they are in the wrong places, DM_HID_LOG=1 logs each button's number for a DM_HID_MAP", d->name, vid, pid);
}
static void hidpad_show_player(hid_pad *d, int p) {   // front_mac.m, once the pad has its player
    if (!d->nintendo) return;
    uint8_t r[PAD_HID_LIGHTS_SIZE]; pad_hid_lights(r, p);
    IOReturn e = IOHIDDeviceSetReport(d->hid, kIOHIDReportTypeOutput, r[0], r, sizeof r);
    if (e != kIOReturnSuccess) LOG("[RED] controller '%s': cannot set its player lights (0x%x)", d->name, e);
}
static void hidpad_stop(hid_pad *d) {
    d->used = 0;
    IOHIDDeviceRegisterInputValueCallback(d->hid, NULL, NULL);
    hidpad_detach(d);
}
static void hidpad_move(hid_pad *d, hid_pad **from, hid_pad **to) { from = hidpad_link(from, d->hid); *from = d->next; d->next = *to; *to = d; }
// Once a device's wait is over, a pad GameController still does not list is read here, and one read here that it now lists goes back to it. Runs on the main run loop
static void hidpad_settle(void) {
    hid_pad *pads[PAD_HID_MAX]; const char *name[PAD_HID_MAX], *listed[PAD_HID_MAX]; uint8_t raw[PAD_HID_MAX]; int n = 0, m = 0; double now = CFAbsoluteTimeGetCurrent();
    for (hid_pad *d = g_hidpads_gc; d && n < PAD_HID_MAX; d = d->next) { pads[n] = d; name[n++] = d->name; }
    for (hid_pad *d = g_hidpads; d && n < PAD_HID_MAX; d = d->next) if (d->gc) { pads[n] = d; name[n++] = d->name; }
    if (!n) return;
    for (GCController *c in GCController.controllers) if (m < PAD_HID_MAX) listed[m++] = c.vendorName.UTF8String ?: "";
    pad_hid_unlisted(name, n, listed, m, raw);
    for (int i = 0; i < n; i++) {
        hid_pad *d = pads[i];
        if (raw[i] && !d->used && d->due <= now) {
            LOG("controller '%s': GameController does not list it, reading it as a HID gamepad", d->name);
            hidpad_move(d, &g_hidpads_gc, &g_hidpads); hidpad_use(d);
        } else if (!raw[i] && d->used) {
            LOG("controller '%s': GameController lists it now", d->name);
            hidpad_move(d, &g_hidpads, &g_hidpads_gc); hidpad_stop(d);
        }
    }
}
static void hidpad_found(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef hid) {
    (void)ctx; (void)sender;
    if (result != kIOReturnSuccess || IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDGCSyntheticDeviceKey)) == kCFBooleanTrue) return;
    if (*hidpad_link(&g_hidpads, hid) || *hidpad_link(&g_hidpads_gc, hid)) return;
    hid_pad *d = calloc(1, sizeof *d); if (!d) { LOG("[RED] HID gamepad: cannot allocate device state"); return; }
    NSString *name = (__bridge NSString *)IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDProductKey));
    snprintf(d->name, sizeof d->name, "%s", name.UTF8String ?: "HID gamepad");
    d->hid = (IOHIDDeviceRef)CFRetain(hid);
    if ([GCController supportsHIDDevice:hid]) {   // once per device: the call is not cheap
        d->gc = 1; d->due = CFAbsoluteTimeGetCurrent() + HIDPAD_GC_WAIT; d->next = g_hidpads_gc; g_hidpads_gc = d;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((HIDPAD_GC_WAIT + 0.1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ hidpad_settle(); });
        return;
    }
    d->next = g_hidpads; g_hidpads = d;
    hidpad_use(d);
}
static void hidpad_removed(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef hid) {
    (void)ctx; (void)result; (void)sender;
    hid_pad **link = hidpad_link(&g_hidpads, hid);
    if (!*link) link = hidpad_link(&g_hidpads_gc, hid);
    if (!*link) return;
    hid_pad *d = *link; *link = d->next;
    if (d->used) hidpad_stop(d);
    CFRelease(d->hid); free(d);
}
static void hidpad_start(void) {
    const char *e = getenv("DM_HID_PADS"); if (e && !atoi(e)) return;
    e = getenv("DM_HID_LOG"); g_hidpad_log = e && atoi(e);
    g_hidpad_manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone); if (!g_hidpad_manager) return;
    IOHIDManagerSetDeviceMatchingMultiple(g_hidpad_manager, (__bridge CFArrayRef)@[
        @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
        @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)}]);
    IOHIDManagerRegisterDeviceMatchingCallback(g_hidpad_manager, hidpad_found, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(g_hidpad_manager, hidpad_removed, NULL);
    IOHIDManagerScheduleWithRunLoop(g_hidpad_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn r = IOHIDManagerOpen(g_hidpad_manager, kIOHIDOptionsTypeNone);   // nonexclusive: GameController and other apps keep their devices
    if (r != kIOReturnSuccess) {
        LOG("[RED] HID gamepads: cannot open HID (0x%x); only GameController controllers are read", r);
        IOHIDManagerUnscheduleFromRunLoop(g_hidpad_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(g_hidpad_manager); g_hidpad_manager = NULL;
    }
}
