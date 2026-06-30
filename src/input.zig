/// SDL2 input backend — satisfies the engine InputInterface(Impl) contract.
/// Event-driven: call handleEvent() from the SDL event loop, then query state.
const std = @import("std");
const c = @import("sdl").c;
const core = @import("labelle_core");

const GamepadEvent = core.GamepadEvent;
const GamepadDescription = core.GamepadDescription;
const GamepadSourceClass = core.GamepadSourceClass;
const GamepadTypeHint = core.GamepadTypeHint;
const GamepadUnavailableReason = core.GamepadUnavailableReason;

const MAX_KEYS = 512;
const MAX_MOUSE_BUTTONS = 7;
const MAX_TOUCHES = 10;

/// Maximum number of simultaneously-tracked controllers. Player-facing
/// "slots" are contiguous 0..MAX_GAMEPADS-1 (matching raylib semantics:
/// games address `gamepad 0`, `gamepad 1`, ...), independent of SDL's
/// ever-incrementing joystick *instance* ids.
const MAX_GAMEPADS = 8;

/// Ring-buffer capacity for pending hotplug events. Connect/disconnect
/// storms are rare; 32 is comfortably more than a single frame ever sees.
const GAMEPAD_EVENT_RING = 32;

var keys_down: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_pressed: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_released: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;

var mouse_down: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_pressed: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_released: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;

var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_wheel: f32 = 0;

// ── Gamepad state ─────────────────────────────────────────────────────────

/// One tracked controller slot. `controller` is null when the slot is free.
/// `instance_id` is the SDL joystick instance id used to resolve REMOVED
/// events (whose `which` is an instance id, not a device index) back to the
/// owning slot. `prev_buttons` snapshots last frame's button state so we can
/// synthesize edge-triggered "pressed" without an SDL pressed-query.
const GamepadSlot = struct {
    controller: ?*c.SDL_GameController = null,
    instance_id: c.SDL_JoystickID = 0,
    prev_buttons: [GAMEPAD_BUTTON_COUNT]bool = [_]bool{false} ** GAMEPAD_BUTTON_COUNT,
    cur_buttons: [GAMEPAD_BUTTON_COUNT]bool = [_]bool{false} ** GAMEPAD_BUTTON_COUNT,
};

/// Engine GamepadButton has indices 0..17 (see labelle-engine input_types).
const GAMEPAD_BUTTON_COUNT = 18;

var gamepad_slots: [MAX_GAMEPADS]GamepadSlot = [_]GamepadSlot{.{}} ** MAX_GAMEPADS;
var gamepad_subsystem_ready: bool = false;

/// Hotplug event ring buffer. Producers (handleEvent) push; pollGamepadEvents
/// drains. Overflow drops the oldest by advancing head (a missed disconnect is
/// far less harmful than blocking the event pump).
var gamepad_ring: [GAMEPAD_EVENT_RING]GamepadEvent = undefined;
var gamepad_ring_head: usize = 0;
var gamepad_ring_len: usize = 0;

/// Call at the start of each frame, BEFORE the SDL event pump, to clear the
/// per-frame keyboard/mouse edge arrays that handleEvent() repopulates.
///
/// Gamepad button edges are intentionally NOT snapshotted here: SDL only
/// refreshes controller state when events are pumped, so sampling buttons
/// before the pump would lag a frame and miss brief taps. Call
/// snapshotGamepads() after the event pump instead.
pub fn newFrame() void {
    keys_pressed = [_]bool{false} ** MAX_KEYS;
    keys_released = [_]bool{false} ** MAX_KEYS;
    mouse_pressed = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_released = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_wheel = 0;
}

/// Snapshot per-frame gamepad button edges. Call AFTER the SDL event pump so
/// SDL has refreshed controller state for this frame. Doing this once per
/// frame (not per event) keeps "pressed" semantics aligned with the keyboard
/// path.
pub fn snapshotGamepads() void {
    for (&gamepad_slots) |*slot| {
        if (slot.controller == null) continue;
        slot.prev_buttons = slot.cur_buttons;
        for (0..GAMEPAD_BUTTON_COUNT) |i| {
            const sdl_btn = engineButtonToSdl(@intCast(i)) orelse {
                slot.cur_buttons[i] = false;
                continue;
            };
            slot.cur_buttons[i] = c.SDL_GameControllerGetButton(slot.controller, sdl_btn) != 0;
        }
    }
}

/// Process an SDL event and update input state.
pub fn handleEvent(event: *const c.SDL_Event) void {
    switch (event.type) {
        c.SDL_KEYDOWN => {
            const code: u32 = @intCast(event.key.keysym.scancode);
            if (code < MAX_KEYS) {
                keys_down[code] = true;
                keys_pressed[code] = true;
            }
        },
        c.SDL_KEYUP => {
            const code: u32 = @intCast(event.key.keysym.scancode);
            if (code < MAX_KEYS) {
                keys_down[code] = false;
                keys_released[code] = true;
            }
        },
        c.SDL_MOUSEMOTION => {
            mouse_x = @floatFromInt(event.motion.x);
            mouse_y = @floatFromInt(event.motion.y);
        },
        c.SDL_MOUSEBUTTONDOWN => {
            const btn: u32 = @intCast(event.button.button);
            if (btn < MAX_MOUSE_BUTTONS) {
                mouse_down[btn] = true;
                mouse_pressed[btn] = true;
            }
        },
        c.SDL_MOUSEBUTTONUP => {
            const btn: u32 = @intCast(event.button.button);
            if (btn < MAX_MOUSE_BUTTONS) {
                mouse_down[btn] = false;
                mouse_released[btn] = true;
            }
        },
        c.SDL_MOUSEWHEEL => {
            mouse_wheel = @floatFromInt(event.wheel.y);
        },
        c.SDL_CONTROLLERDEVICEADDED => {
            // `cdevice.which` is a *device index* for ADDED events.
            onControllerAdded(event.cdevice.which);
        },
        c.SDL_CONTROLLERDEVICEREMOVED => {
            // `cdevice.which` is an *instance id* for REMOVED events.
            onControllerRemoved(event.cdevice.which);
        },
        else => {},
    }
}

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    return if (key < MAX_KEYS) keys_down[key] else false;
}

pub fn isKeyPressed(key: u32) bool {
    return if (key < MAX_KEYS) keys_pressed[key] else false;
}

pub fn isKeyReleased(key: u32) bool {
    return if (key < MAX_KEYS) keys_released[key] else false;
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return mouse_x;
}

pub fn getMouseY() f32 {
    return mouse_y;
}

pub fn isMouseButtonDown(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_down[button] else false;
}

pub fn isMouseButtonPressed(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_pressed[button] else false;
}

pub fn isMouseButtonReleased(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_released[button] else false;
}

pub fn getMouseWheelMove() f32 {
    return mouse_wheel;
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    return 0;
}

pub fn getTouchX(index: u32) f32 {
    _ = index;
    return 0;
}

pub fn getTouchY(index: u32) f32 {
    _ = index;
    return 0;
}

pub fn getTouchId(index: u32) u64 {
    _ = index;
    return 0;
}

// ── Gamepad ───────────────────────────────────────────────

/// Lazily initialize the SDL GameController subsystem and enumerate any
/// controllers already plugged in at startup. Idempotent — safe to call
/// from initGamepads() or on the first gamepad query. SDL also emits a
/// CONTROLLERDEVICEADDED per already-connected controller after init, but
/// we enumerate eagerly so describeGamepads/queries work before the first
/// event pump, and so the initial hotplug events are produced exactly once
/// (we de-dupe by instance id in onControllerAdded).
pub fn initGamepads() void {
    if (gamepad_subsystem_ready) return;
    if (c.SDL_WasInit(c.SDL_INIT_GAMECONTROLLER) == 0) {
        if (c.SDL_InitSubSystem(c.SDL_INIT_GAMECONTROLLER) != 0) return;
    }
    gamepad_subsystem_ready = true;

    const n = c.SDL_NumJoysticks();
    var device_index: c_int = 0;
    while (device_index < n) : (device_index += 1) {
        if (c.SDL_IsGameController(device_index) == c.SDL_TRUE) {
            onControllerAdded(device_index);
        }
    }
}

/// Close all open controllers and reset slot state. Call before SDL_Quit.
pub fn deinitGamepads() void {
    for (&gamepad_slots) |*slot| {
        if (slot.controller) |ctrl| c.SDL_GameControllerClose(ctrl);
        slot.* = .{};
    }
    gamepad_ring_head = 0;
    gamepad_ring_len = 0;
    gamepad_subsystem_ready = false;
}

pub fn isGamepadAvailable(gamepad: u32) bool {
    if (gamepad >= MAX_GAMEPADS) return false;
    return gamepad_slots[gamepad].controller != null;
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    if (gamepad >= MAX_GAMEPADS or button >= GAMEPAD_BUTTON_COUNT) return false;
    if (gamepad_slots[gamepad].controller == null) return false;
    return gamepad_slots[gamepad].cur_buttons[button];
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    if (gamepad >= MAX_GAMEPADS or button >= GAMEPAD_BUTTON_COUNT) return false;
    if (gamepad_slots[gamepad].controller == null) return false;
    const s = &gamepad_slots[gamepad];
    return s.cur_buttons[button] and !s.prev_buttons[button];
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    if (gamepad >= MAX_GAMEPADS) return 0;
    const ctrl = gamepad_slots[gamepad].controller orelse return 0;
    const sdl_axis = engineAxisToSdl(axis) orelse return 0;
    // SDL axes are i16 (-32768..32767). Normalize to -1..1 (raylib convention).
    // Dividing by 32767 maps the negative extreme (-32768) to -1.0000305, so
    // clamp the low end to keep the result strictly within [-1, 1].
    const raw = c.SDL_GameControllerGetAxis(ctrl, sdl_axis);
    return @max(-1.0, @as(f32, @floatFromInt(raw)) / 32767.0);
}

// ── Gamepad hotplug events (core#18 contract) ─────────────────────────────

/// Drain pending connect/disconnect events into `out`. Returns the count
/// written (<= out.len). Ensures the subsystem is initialized so a caller
/// that only polls events (never queries buttons) still gets hotplug.
pub fn pollGamepadEvents(out: []GamepadEvent) usize {
    if (!gamepad_subsystem_ready) initGamepads();
    var written: usize = 0;
    while (written < out.len and gamepad_ring_len > 0) : (written += 1) {
        out[written] = gamepad_ring[gamepad_ring_head];
        gamepad_ring_head = (gamepad_ring_head + 1) % GAMEPAD_EVENT_RING;
        gamepad_ring_len -= 1;
    }
    return written;
}

/// Snapshot currently-visible devices for diagnostics. Reports occupied
/// slots as connected; any other present device (a joystick SDL doesn't
/// recognize as a controller, or a recognized controller that couldn't be
/// opened — e.g. all slots full) gets a `connected = false` description so
/// it isn't silently invisible.
pub fn describeGamepads(out: []GamepadDescription) usize {
    if (!gamepad_subsystem_ready) initGamepads();
    var written: usize = 0;

    // 1. Occupied (open) slots.
    for (&gamepad_slots, 0..) |*slot, slot_idx| {
        if (written >= out.len) break;
        const ctrl = slot.controller orelse continue;
        var desc = GamepadDescription{ .slot = @intCast(slot_idx), .connected = true };
        if (c.SDL_GameControllerName(ctrl)) |name_ptr| {
            desc.setName(spanZ(name_ptr));
        }
        if (c.SDL_GameControllerGetJoystick(ctrl)) |joy| {
            desc.guid = guidBytes(c.SDL_JoystickGetGUID(joy));
        }
        desc.source_class = .gamepad;
        desc.type_hint = typeHintFor(ctrl);
        desc.unavailable_reason = .none;
        out[written] = desc;
        written += 1;
    }

    // 2. Present but not occupying a slot. This covers two cases that section
    //    1 misses: joysticks SDL can't map as game controllers (no mapping),
    //    AND recognized controllers we couldn't open (slots exhausted or
    //    SDL_GameControllerOpen failed). Dedup against open slots by *instance
    //    id* — skipping every SDL_IsGameController device would hide the
    //    latter case entirely.
    const n = c.SDL_NumJoysticks();
    var device_index: c_int = 0;
    while (device_index < n and written < out.len) : (device_index += 1) {
        const instance_id = c.SDL_JoystickGetDeviceInstanceID(device_index);
        if (isInstanceOpen(instance_id)) continue; // already reported in section 1.

        const is_controller = c.SDL_IsGameController(device_index) == c.SDL_TRUE;
        // No player slot: this device has no queryable `gamepad` index. Use the
        // first out-of-range value (MAX_GAMEPADS) as a non-queryable sentinel
        // rather than SDL's device_index, which would collide with real player
        // slots 0..N-1.
        var desc = GamepadDescription{ .slot = MAX_GAMEPADS, .connected = false };
        if (c.SDL_JoystickNameForIndex(device_index)) |name_ptr| {
            desc.setName(spanZ(name_ptr));
        }
        desc.guid = guidBytes(c.SDL_JoystickGetDeviceGUID(device_index));
        desc.source_class = if (is_controller) .gamepad else .unknown;
        // A recognized controller that isn't in a slot failed to open (e.g. no
        // free slot); a non-controller joystick is simply unsupported.
        desc.unavailable_reason = if (is_controller) .init_failed else .unsupported;
        out[written] = desc;
        written += 1;
    }

    return written;
}

/// True if an SDL joystick instance id is currently held by an open slot.
fn isInstanceOpen(instance_id: c.SDL_JoystickID) bool {
    for (gamepad_slots) |slot| {
        if (slot.controller != null and slot.instance_id == instance_id) return true;
    }
    return false;
}

// ── Internal helpers ──────────────────────────────────────────────────────

/// Handle a CONTROLLERDEVICEADDED (device index) — open the controller and
/// assign it the first free slot, then enqueue a connect event. De-dupes by
/// instance id so the startup enumeration + SDL's auto-emitted ADDED event
/// don't double-open the same device.
fn onControllerAdded(device_index: c_int) void {
    if (c.SDL_IsGameController(device_index) != c.SDL_TRUE) return;

    const ctrl = c.SDL_GameControllerOpen(device_index) orelse return;
    const joy = c.SDL_GameControllerGetJoystick(ctrl);
    if (joy == null) {
        // An open controller should always have a joystick; bail defensively.
        c.SDL_GameControllerClose(ctrl);
        return;
    }
    const instance_id = c.SDL_JoystickInstanceID(joy);

    // De-dupe: if this instance is already tracked, drop the extra open.
    for (gamepad_slots) |slot| {
        if (slot.controller != null and slot.instance_id == instance_id) {
            c.SDL_GameControllerClose(ctrl);
            return;
        }
    }

    // Find a free slot.
    var slot_idx: ?usize = null;
    for (&gamepad_slots, 0..) |*slot, idx| {
        if (slot.controller == null) {
            slot_idx = idx;
            break;
        }
    }
    const idx = slot_idx orelse {
        // No room — close and ignore (queries simply won't see it).
        c.SDL_GameControllerClose(ctrl);
        return;
    };

    gamepad_slots[idx] = .{ .controller = ctrl, .instance_id = instance_id };

    var ev = GamepadEvent{ .kind = .connected, .slot = @intCast(idx) };
    if (c.SDL_GameControllerName(ctrl)) |name_ptr| ev.setName(spanZ(name_ptr));
    if (joy) |j| ev.guid = guidBytes(c.SDL_JoystickGetGUID(j));
    ev.source_class = .gamepad;
    ev.type_hint = typeHintFor(ctrl);
    pushGamepadEvent(ev);
}

/// Handle a CONTROLLERDEVICEREMOVED (instance id) — close the matching slot
/// and enqueue a disconnect event.
fn onControllerRemoved(instance_id: c.SDL_JoystickID) void {
    for (&gamepad_slots, 0..) |*slot, idx| {
        if (slot.controller != null and slot.instance_id == instance_id) {
            c.SDL_GameControllerClose(slot.controller);
            slot.* = .{};
            pushGamepadEvent(GamepadEvent.disconnected(@intCast(idx)));
            return;
        }
    }
}

/// Append an event to the ring, dropping the oldest on overflow.
fn pushGamepadEvent(ev: GamepadEvent) void {
    if (gamepad_ring_len == GAMEPAD_EVENT_RING) {
        // Drop oldest.
        gamepad_ring_head = (gamepad_ring_head + 1) % GAMEPAD_EVENT_RING;
        gamepad_ring_len -= 1;
    }
    const tail = (gamepad_ring_head + gamepad_ring_len) % GAMEPAD_EVENT_RING;
    gamepad_ring[tail] = ev;
    gamepad_ring_len += 1;
}

/// Copy an SDL_GUID's 16 bytes into a plain array.
fn guidBytes(guid: c.SDL_JoystickGUID) [16]u8 {
    var out: [16]u8 = undefined;
    @memcpy(&out, guid.data[0..16]);
    return out;
}

/// Borrow a C NUL-terminated string as a Zig slice.
fn spanZ(ptr: [*c]const u8) []const u8 {
    return std.mem.span(ptr);
}

/// Map SDL_GameControllerType (with a name-substring fallback) to the
/// frozen TypeHint vendor family.
fn typeHintFor(ctrl: *c.SDL_GameController) GamepadTypeHint {
    switch (c.SDL_GameControllerGetType(ctrl)) {
        c.SDL_CONTROLLER_TYPE_XBOX360, c.SDL_CONTROLLER_TYPE_XBOXONE => return .xbox,
        c.SDL_CONTROLLER_TYPE_PS3, c.SDL_CONTROLLER_TYPE_PS4, c.SDL_CONTROLLER_TYPE_PS5 => return .playstation,
        c.SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_PRO,
        c.SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_JOYCON_LEFT,
        c.SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT,
        c.SDL_CONTROLLER_TYPE_NINTENDO_SWITCH_JOYCON_PAIR,
        => return .nintendo,
        c.SDL_CONTROLLER_TYPE_VIRTUAL,
        c.SDL_CONTROLLER_TYPE_AMAZON_LUNA,
        c.SDL_CONTROLLER_TYPE_GOOGLE_STADIA,
        c.SDL_CONTROLLER_TYPE_NVIDIA_SHIELD,
        => return .generic,
        else => {},
    }
    // Older SDL or unknown type: fall back to a name heuristic.
    if (c.SDL_GameControllerName(ctrl)) |name_ptr| {
        return typeHintFromName(spanZ(name_ptr));
    }
    return .unknown;
}

fn typeHintFromName(name: []const u8) GamepadTypeHint {
    if (containsAnyCI(name, &.{ "xbox", "xinput" })) return .xbox;
    if (containsAnyCI(name, &.{ "playstation", "dualshock", "dualsense", "ps3", "ps4", "ps5", "sony" })) return .playstation;
    if (containsAnyCI(name, &.{ "nintendo", "switch", "joy-con", "joycon" })) return .nintendo;
    return .unknown;
}

/// Case-insensitive substring match against any needle.
fn containsAnyCI(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (needle.len == 0 or needle.len > haystack.len) continue;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var matched = true;
            for (needle, 0..) |nch, j| {
                if (lowerAscii(haystack[i + j]) != lowerAscii(nch)) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
    }
    return false;
}

fn lowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

/// Map engine GamepadButton index → SDL_GameControllerButton.
/// Engine indices follow labelle-engine/src/input_types.zig (raylib layout):
///   1 dpad_up, 2 dpad_right, 3 dpad_down, 4 dpad_left,
///   5 Y(north), 6 B(east), 7 A(south), 8 X(west),
///   9 LB, 10 LT(->axis, no button), 11 RB, 12 RT(->axis, no button),
///   13 back, 14 guide, 15 start, 16 left_thumb, 17 right_thumb.
fn engineButtonToSdl(button: u32) ?c.SDL_GameControllerButton {
    return switch (button) {
        1 => c.SDL_CONTROLLER_BUTTON_DPAD_UP, // left_face_up
        2 => c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT, // left_face_right
        3 => c.SDL_CONTROLLER_BUTTON_DPAD_DOWN, // left_face_down
        4 => c.SDL_CONTROLLER_BUTTON_DPAD_LEFT, // left_face_left
        5 => c.SDL_CONTROLLER_BUTTON_Y, // right_face_up
        6 => c.SDL_CONTROLLER_BUTTON_B, // right_face_right
        7 => c.SDL_CONTROLLER_BUTTON_A, // right_face_down
        8 => c.SDL_CONTROLLER_BUTTON_X, // right_face_left
        9 => c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER, // left_trigger_1
        11 => c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, // right_trigger_1
        13 => c.SDL_CONTROLLER_BUTTON_BACK, // middle_left
        14 => c.SDL_CONTROLLER_BUTTON_GUIDE, // middle
        15 => c.SDL_CONTROLLER_BUTTON_START, // middle_right
        16 => c.SDL_CONTROLLER_BUTTON_LEFTSTICK, // left_thumb
        17 => c.SDL_CONTROLLER_BUTTON_RIGHTSTICK, // right_thumb
        // 0 (unknown), 10 (left_trigger_2), 12 (right_trigger_2) have no
        // digital SDL button — triggers are analog axes.
        else => null,
    };
}

/// Map engine GamepadAxis index → SDL_GameControllerAxis.
///   0 left_x, 1 left_y, 2 right_x, 3 right_y, 4 left_trigger, 5 right_trigger.
fn engineAxisToSdl(axis: u32) ?c.SDL_GameControllerAxis {
    return switch (axis) {
        0 => c.SDL_CONTROLLER_AXIS_LEFTX,
        1 => c.SDL_CONTROLLER_AXIS_LEFTY,
        2 => c.SDL_CONTROLLER_AXIS_RIGHTX,
        3 => c.SDL_CONTROLLER_AXIS_RIGHTY,
        4 => c.SDL_CONTROLLER_AXIS_TRIGGERLEFT,
        5 => c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
        else => null,
    };
}

// ── Tests (hardware-free) ─────────────────────────────────────────────────

const testing = std.testing;

test "engineButtonToSdl maps face/dpad/shoulder/system buttons" {
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_A), engineButtonToSdl(7).?);
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_B), engineButtonToSdl(6).?);
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_X), engineButtonToSdl(8).?);
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_Y), engineButtonToSdl(5).?);
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_DPAD_UP), engineButtonToSdl(1).?);
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER), engineButtonToSdl(9).?);
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_START), engineButtonToSdl(15).?);
    try testing.expectEqual(@as(c.SDL_GameControllerButton, c.SDL_CONTROLLER_BUTTON_LEFTSTICK), engineButtonToSdl(16).?);
}

test "engineButtonToSdl returns null for analog-trigger and unknown indices" {
    try testing.expect(engineButtonToSdl(0) == null); // unknown
    try testing.expect(engineButtonToSdl(10) == null); // left_trigger_2 (analog)
    try testing.expect(engineButtonToSdl(12) == null); // right_trigger_2 (analog)
    try testing.expect(engineButtonToSdl(99) == null); // out of range
}

test "engineAxisToSdl maps sticks and triggers" {
    try testing.expectEqual(@as(c.SDL_GameControllerAxis, c.SDL_CONTROLLER_AXIS_LEFTX), engineAxisToSdl(0).?);
    try testing.expectEqual(@as(c.SDL_GameControllerAxis, c.SDL_CONTROLLER_AXIS_RIGHTY), engineAxisToSdl(3).?);
    try testing.expectEqual(@as(c.SDL_GameControllerAxis, c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT), engineAxisToSdl(5).?);
    try testing.expect(engineAxisToSdl(6) == null);
}

test "typeHintFromName heuristic" {
    try testing.expectEqual(GamepadTypeHint.xbox, typeHintFromName("Xbox Wireless Controller"));
    try testing.expectEqual(GamepadTypeHint.xbox, typeHintFromName("XInput STANDARD GAMEPAD"));
    try testing.expectEqual(GamepadTypeHint.playstation, typeHintFromName("Sony DualSense Wireless Controller"));
    try testing.expectEqual(GamepadTypeHint.playstation, typeHintFromName("PS4 Controller"));
    try testing.expectEqual(GamepadTypeHint.nintendo, typeHintFromName("Nintendo Switch Pro Controller"));
    try testing.expectEqual(GamepadTypeHint.nintendo, typeHintFromName("Joy-Con (L)"));
    try testing.expectEqual(GamepadTypeHint.unknown, typeHintFromName("Generic USB Gamepad"));
}

test "gamepad event ring buffer push/drain and overflow" {
    // Reset ring.
    gamepad_ring_head = 0;
    gamepad_ring_len = 0;

    pushGamepadEvent(GamepadEvent.connected(0, "pad0"));
    pushGamepadEvent(GamepadEvent.connected(1, "pad1"));
    pushGamepadEvent(GamepadEvent.disconnected(0));

    var out: [8]GamepadEvent = undefined;
    // Drain directly (bypass pollGamepadEvents' lazy init to keep test pure).
    var n: usize = 0;
    while (n < out.len and gamepad_ring_len > 0) : (n += 1) {
        out[n] = gamepad_ring[gamepad_ring_head];
        gamepad_ring_head = (gamepad_ring_head + 1) % GAMEPAD_EVENT_RING;
        gamepad_ring_len -= 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(GamepadEvent.Kind.connected, out[0].kind);
    try testing.expectEqualStrings("pad0", out[0].nameSlice());
    try testing.expectEqual(GamepadEvent.Kind.disconnected, out[2].kind);
    try testing.expectEqual(@as(u32, 0), out[2].slot);

    // Overflow: fill beyond capacity, oldest dropped, length capped.
    gamepad_ring_head = 0;
    gamepad_ring_len = 0;
    var i: u32 = 0;
    while (i < GAMEPAD_EVENT_RING + 5) : (i += 1) {
        pushGamepadEvent(GamepadEvent.connected(i, "x"));
    }
    try testing.expectEqual(@as(usize, GAMEPAD_EVENT_RING), gamepad_ring_len);
    // Oldest surviving event should be slot 5 (first 5 dropped).
    try testing.expectEqual(@as(u32, 5), gamepad_ring[gamepad_ring_head].slot);
}

test "out-of-range gamepad queries are safe" {
    try testing.expect(!isGamepadAvailable(MAX_GAMEPADS));
    try testing.expect(!isGamepadButtonDown(MAX_GAMEPADS, 0));
    try testing.expect(!isGamepadButtonDown(0, GAMEPAD_BUTTON_COUNT));
    try testing.expectEqual(@as(f32, 0), getGamepadAxisValue(MAX_GAMEPADS, 0));
    try testing.expectEqual(@as(f32, 0), getGamepadAxisValue(0, 99));
}
