/// MAVLink Drone Adapter for Bridge 9 Phase 3
///
/// Connects Bridge 9 forward morphism (8-DOF generalized coordinates)
/// to ArduPilot/PX4 drones via MAVLink v2 protocol.
///
/// Architecture:
/// ┌─────────────────────────────────────┐
/// │ Bridge9FFI.forward_morphism output  │
/// │ LuxGeneralizedCoordinate (8-DOF)    │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ drone_extract_commands()            │ ← Dimension mapping
/// │ (8D → roll/pitch/yaw/throttle      │
/// │       + gimbal_pitch/yaw            │
/// │       + aux1/aux2)                  │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ MAVLinkController                   │ ← MAVLink v2 UDP/Serial
/// │ Messages: HEARTBEAT, SET_ATTITUDE,  │
/// │ RC_CHANNELS_OVERRIDE, COMMAND_LONG  │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ ArduPilot / PX4 (flight controller) │
/// └─────────────────────────────────────┘
///
/// Feedback Loop (backward morphism):
/// ┌─────────────────────────────────────┐
/// │ ATTITUDE, GLOBAL_POSITION_INT,      │
/// │ VFR_HUD, BATTERY_STATUS             │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ drone_read_state()                  │
/// │ (attitude + position → 8-DOF)       │
/// └──────────────┬──────────────────────┘
///                ▼
/// │ Bridge9FFI.backward_morphism input  │
/// │ drone_state → phenomenal_state      │
/// └─────────────────────────────────────┘
const std = @import("std");
const message_frame = @import("message_frame");

// ============================================================================
// MAVLINK V2 PROTOCOL
// ============================================================================

pub const MAVLINK_STX_V2: u8 = 0xFD;
pub const MAVLINK_SYSTEM_ID: u8 = 255; // GCS
pub const MAVLINK_COMPONENT_ID: u8 = 190; // MAV_COMP_ID_MISSIONPLANNER

/// MAVLink v2 message IDs
pub const MsgId = enum(u32) {
    heartbeat = 0,
    set_attitude_target = 82,
    attitude = 30,
    global_position_int = 33,
    vfr_hud = 74,
    rc_channels_override = 70,
    command_long = 76,
    command_ack = 77,
    battery_status = 147,
    statustext = 253,
};

/// MAV_CMD constants
pub const MavCmd = enum(u16) {
    arm_disarm = 400,
    takeoff = 22,
    land = 21,
    return_to_launch = 20,
    set_mode = 176,
    do_set_servo = 183,
};

/// Flight modes (ArduCopter)
pub const FlightMode = enum(u8) {
    stabilize = 0,
    alt_hold = 2,
    loiter = 5,
    guided = 4,
    land = 9,
    rtl = 6,
    auto_mode = 3,
};

// ============================================================================
// DRONE CONFIGURATION
// ============================================================================

pub const DroneConfig = struct {
    target_system: u8 = 1, // Autopilot system ID
    target_component: u8 = 1, // Autopilot component ID
    hostname: []const u8 = "127.0.0.1",
    udp_port: u16 = 14550, // Standard MAVLink UDP port
    serial_path: ?[]const u8 = null, // e.g., /dev/ttyUSB0
    serial_baud: u32 = 57600,
    use_udp: bool = true,
};

// ============================================================================
// DRONE STATE
// ============================================================================

pub const DroneAttitude = struct {
    roll: f32, // radians
    pitch: f32, // radians
    yaw: f32, // radians
    rollspeed: f32, // rad/s
    pitchspeed: f32, // rad/s
    yawspeed: f32, // rad/s
    timestamp_ms: u32,
};

pub const DronePosition = struct {
    lat: i32, // degE7
    lon: i32, // degE7
    alt: i32, // mm MSL
    relative_alt: i32, // mm AGL
    vx: i16, // cm/s
    vy: i16, // cm/s
    vz: i16, // cm/s
    hdg: u16, // cdeg (0-35999)
};

pub const DroneState = struct {
    attitude: DroneAttitude,
    position: DronePosition,
    airspeed: f32, // m/s
    groundspeed: f32, // m/s
    throttle: u16, // 0-100%
    climb: f32, // m/s
    battery_remaining: i8, // 0-100, -1 unknown
    armed: bool,
    mode: FlightMode,
    timestamp_us: u64,
};

// ============================================================================
// MAVLINK V2 FRAME
// ============================================================================

pub const MAVLinkFrame = struct {
    stx: u8 = MAVLINK_STX_V2,
    payload_len: u8,
    incompat_flags: u8 = 0,
    compat_flags: u8 = 0,
    seq: u8,
    sysid: u8 = MAVLINK_SYSTEM_ID,
    compid: u8 = MAVLINK_COMPONENT_ID,
    msgid: u24,
    payload: []const u8,
    checksum: u16,

    pub fn encode(self: MAVLinkFrame, buf: []u8) usize {
        var pos: usize = 0;

        buf[pos] = self.stx;
        pos += 1;
        buf[pos] = self.payload_len;
        pos += 1;
        buf[pos] = self.incompat_flags;
        pos += 1;
        buf[pos] = self.compat_flags;
        pos += 1;
        buf[pos] = self.seq;
        pos += 1;
        buf[pos] = self.sysid;
        pos += 1;
        buf[pos] = self.compid;
        pos += 1;

        // msgid: 3 bytes little-endian
        buf[pos] = @intCast(self.msgid & 0xFF);
        pos += 1;
        buf[pos] = @intCast((self.msgid >> 8) & 0xFF);
        pos += 1;
        buf[pos] = @intCast((self.msgid >> 16) & 0xFF);
        pos += 1;

        // payload
        @memcpy(buf[pos .. pos + self.payload_len], self.payload[0..self.payload_len]);
        pos += self.payload_len;

        // checksum
        std.mem.writeInt(u16, buf[pos..][0..2], self.checksum, .little);
        pos += 2;

        return pos;
    }
};

// ============================================================================
// MAVLINK CONTROLLER
// ============================================================================

pub const MAVLinkController = struct {
    allocator: std.mem.Allocator,
    config: DroneConfig,
    socket: ?std.posix.socket_t = null,
    seq_counter: u8 = 0,
    last_state: ?DroneState = null,

    // GF(3) trit for mode selection from BCI
    // -1 = observe (loiter/stabilize), 0 = coordinate (guided), +1 = generate (manual/acro)
    bci_trit: i2 = 0,

    pub fn init(allocator: std.mem.Allocator, config: DroneConfig) MAVLinkController {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn connect(self: *MAVLinkController) !void {
        if (self.config.use_udp) {
            const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
            self.socket = sock;

            const addr = try std.net.Address.resolveIp(
                self.config.hostname,
                self.config.udp_port,
            );
            try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
        }
        // Serial path would use std.fs.openFileAbsolute + termios config
    }

    pub fn disconnect(self: *MAVLinkController) void {
        if (self.socket) |sock| {
            std.posix.close(sock);
            self.socket = null;
        }
    }

    /// Send raw MAVLink v2 frame
    fn send(self: *MAVLinkController, msgid: u32, payload: []const u8) !void {
        if (self.socket == null) return error.NotConnected;

        var buf: [280]u8 = undefined;

        const frame = MAVLinkFrame{
            .payload_len = @intCast(payload.len),
            .seq = self.seq_counter,
            .msgid = @intCast(msgid),
            .payload = payload,
            .checksum = computeMAVLinkCrc(payload, @intCast(msgid)),
        };
        self.seq_counter +%= 1;

        const len = frame.encode(&buf);
        _ = try std.posix.send(self.socket.?, buf[0..len], 0);
    }

    /// Send heartbeat (must be sent at 1Hz to maintain connection)
    pub fn sendHeartbeat(self: *MAVLinkController) !void {
        var payload: [9]u8 = undefined;

        // custom_mode (4 bytes)
        std.mem.writeInt(u32, payload[0..4], 0, .little);
        payload[4] = 6; // MAV_TYPE_GCS
        payload[5] = 0; // MAV_AUTOPILOT_GENERIC
        payload[6] = 0; // base_mode
        payload[7] = 0; // system_status
        payload[8] = 3; // mavlink_version

        try self.send(@intFromEnum(MsgId.heartbeat), &payload);
    }

    /// Set attitude target (roll/pitch/yaw/throttle)
    /// This is the primary BCI control path
    pub fn setAttitudeTarget(
        self: *MAVLinkController,
        roll: f32,
        pitch: f32,
        yaw: f32,
        thrust: f32, // 0.0 to 1.0
    ) !void {
        var payload: [39]u8 = undefined;
        @memset(&payload, 0);

        // time_boot_ms (4 bytes)
        const time_ms: u32 = @intCast(@divFloor(std.time.milliTimestamp(), 1));
        std.mem.writeInt(u32, payload[0..4], time_ms, .little);

        // Quaternion from Euler angles (simplified)
        const cr = @cos(roll * 0.5);
        const sr = @sin(roll * 0.5);
        const cp = @cos(pitch * 0.5);
        const sp = @sin(pitch * 0.5);
        const cy = @cos(yaw * 0.5);
        const sy = @sin(yaw * 0.5);

        const qw: f32 = cr * cp * cy + sr * sp * sy;
        const qx: f32 = sr * cp * cy - cr * sp * sy;
        const qy: f32 = cr * sp * cy + sr * cp * sy;
        const qz: f32 = cr * cp * sy - sr * sp * cy;

        std.mem.writeInt(u32, payload[4..8], @bitCast(qw), .little);
        std.mem.writeInt(u32, payload[8..12], @bitCast(qx), .little);
        std.mem.writeInt(u32, payload[12..16], @bitCast(qy), .little);
        std.mem.writeInt(u32, payload[16..20], @bitCast(qz), .little);

        // body_roll_rate, body_pitch_rate, body_yaw_rate (unused, 0)
        // payload[20..32] already zeroed

        // thrust
        std.mem.writeInt(u32, payload[32..36], @bitCast(thrust), .little);

        payload[36] = self.config.target_system;
        payload[37] = self.config.target_component;
        payload[38] = 0b00000111; // type_mask: ignore rates, use attitude + thrust

        try self.send(@intFromEnum(MsgId.set_attitude_target), &payload);
    }

    /// RC channels override for direct BCI control
    /// Channels: 1=roll, 2=pitch, 3=throttle, 4=yaw, 5=gimbal_pitch, 6=gimbal_yaw, 7=aux1, 8=aux2
    pub fn setRcOverride(
        self: *MAVLinkController,
        channels: [8]u16, // PWM values 1000-2000, 0=release
    ) !void {
        var payload: [18]u8 = undefined;

        for (0..8) |i| {
            std.mem.writeInt(u16, payload[i * 2 ..][0..2], channels[i], .little);
        }

        payload[16] = self.config.target_system;
        payload[17] = self.config.target_component;

        try self.send(@intFromEnum(MsgId.rc_channels_override), &payload);
    }

    /// Arm or disarm motors
    pub fn arm(self: *MAVLinkController, do_arm: bool) !void {
        try self.sendCommandLong(
            @intFromEnum(MavCmd.arm_disarm),
            if (do_arm) 1.0 else 0.0,
            0,
            0,
            0,
            0,
            0,
            0,
        );
    }

    /// Takeoff to altitude (meters)
    pub fn takeoff(self: *MAVLinkController, alt_m: f32) !void {
        try self.sendCommandLong(
            @intFromEnum(MavCmd.takeoff),
            0,
            0,
            0,
            0,
            0,
            0,
            alt_m,
        );
    }

    /// Land at current position
    pub fn land(self: *MAVLinkController) !void {
        try self.sendCommandLong(
            @intFromEnum(MavCmd.land),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        );
    }

    /// Return to launch
    pub fn rtl(self: *MAVLinkController) !void {
        try self.sendCommandLong(
            @intFromEnum(MavCmd.return_to_launch),
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        );
    }

    fn sendCommandLong(
        self: *MAVLinkController,
        command: u16,
        p1: f32,
        p2: f32,
        p3: f32,
        p4: f32,
        p5: f32,
        p6: f32,
        p7: f32,
    ) !void {
        var payload: [33]u8 = undefined;
        @memset(&payload, 0);

        // params 1-7 as f32
        const params = [7]f32{ p1, p2, p3, p4, p5, p6, p7 };
        for (0..7) |i| {
            std.mem.writeInt(u32, payload[i * 4 ..][0..4], @bitCast(params[i]), .little);
        }

        // command (u16)
        std.mem.writeInt(u16, payload[28..30], command, .little);
        payload[30] = self.config.target_system;
        payload[31] = self.config.target_component;
        payload[32] = 0; // confirmation

        try self.send(@intFromEnum(MsgId.command_long), &payload);
    }

    /// Parse incoming MAVLink message and update state
    pub fn parseMessage(self: *MAVLinkController, data: []const u8) !void {
        if (data.len < 12) return error.TooShort;
        if (data[0] != MAVLINK_STX_V2) return error.BadMagic;

        const payload_len = data[1];
        const msgid: u32 = @as(u32, data[7]) |
            (@as(u32, data[8]) << 8) |
            (@as(u32, data[9]) << 16);

        const payload = data[10 .. 10 + payload_len];

        switch (@as(MsgId, @enumFromInt(msgid))) {
            .attitude => {
                if (payload.len < 28) return;
                var state = self.last_state orelse DroneState{
                    .attitude = undefined,
                    .position = std.mem.zeroes(DronePosition),
                    .airspeed = 0,
                    .groundspeed = 0,
                    .throttle = 0,
                    .climb = 0,
                    .battery_remaining = -1,
                    .armed = false,
                    .mode = .stabilize,
                    .timestamp_us = 0,
                };

                state.attitude = .{
                    .timestamp_ms = std.mem.readInt(u32, payload[0..4], .little),
                    .roll = @bitCast(std.mem.readInt(u32, payload[4..8], .little)),
                    .pitch = @bitCast(std.mem.readInt(u32, payload[8..12], .little)),
                    .yaw = @bitCast(std.mem.readInt(u32, payload[12..16], .little)),
                    .rollspeed = @bitCast(std.mem.readInt(u32, payload[16..20], .little)),
                    .pitchspeed = @bitCast(std.mem.readInt(u32, payload[20..24], .little)),
                    .yawspeed = @bitCast(std.mem.readInt(u32, payload[24..28], .little)),
                };
                state.timestamp_us = @intCast(std.time.microTimestamp());
                self.last_state = state;
            },
            .global_position_int => {
                if (payload.len < 28) return;
                var state = self.last_state orelse return;

                state.position = .{
                    .lat = std.mem.readInt(i32, payload[4..8], .little),
                    .lon = std.mem.readInt(i32, payload[8..12], .little),
                    .alt = std.mem.readInt(i32, payload[12..16], .little),
                    .relative_alt = std.mem.readInt(i32, payload[16..20], .little),
                    .vx = std.mem.readInt(i16, payload[20..22], .little),
                    .vy = std.mem.readInt(i16, payload[22..24], .little),
                    .vz = std.mem.readInt(i16, payload[24..26], .little),
                    .hdg = std.mem.readInt(u16, payload[26..28], .little),
                };
                self.last_state = state;
            },
            .vfr_hud => {
                if (payload.len < 20) return;
                var state = self.last_state orelse return;

                state.airspeed = @bitCast(std.mem.readInt(u32, payload[0..4], .little));
                state.groundspeed = @bitCast(std.mem.readInt(u32, payload[4..8], .little));
                state.climb = @bitCast(std.mem.readInt(u32, payload[12..16], .little));
                state.throttle = std.mem.readInt(u16, payload[16..18], .little);
                self.last_state = state;
            },
            else => {},
        }
    }
};

// ============================================================================
// BRIDGE 9 DIMENSION MAPPING (shared with ur_robot_adapter.zig)
// ============================================================================

pub const LuxGeneralizedCoordinate = struct {
    q: [8]f64,
    q_dot: [8]f64,
    q_ddot: [8]f64,
    timestamp_us: u64,
};

/// Extract drone commands from 8-DOF Bridge 9 output
/// Dimension mapping:
///   q[0]: Roll command (radians, -π/4 to π/4)
///   q[1]: Pitch command (radians, -π/4 to π/4)
///   q[2]: Yaw command (radians, -π to π)
///   q[3]: Throttle (0.0 to 1.0)
///   q[4]: Gimbal pitch (radians)
///   q[5]: Gimbal yaw (radians)
///   q[6]: Aux channel 1 (normalized 0-1, e.g., payload release)
///   q[7]: Aux channel 2 (normalized 0-1, e.g., lighting)
pub fn extractDroneCommands(coord: LuxGeneralizedCoordinate) struct {
    roll: f32,
    pitch: f32,
    yaw: f32,
    thrust: f32,
    gimbal_pitch: f32,
    gimbal_yaw: f32,
    aux1: f32,
    aux2: f32,
} {
    return .{
        .roll = @floatCast(std.math.clamp(coord.q[0], -std.math.pi / 4.0, std.math.pi / 4.0)),
        .pitch = @floatCast(std.math.clamp(coord.q[1], -std.math.pi / 4.0, std.math.pi / 4.0)),
        .yaw = @floatCast(coord.q[2]),
        .thrust = @floatCast(std.math.clamp(coord.q[3], 0.0, 1.0)),
        .gimbal_pitch = @floatCast(coord.q[4]),
        .gimbal_yaw = @floatCast(coord.q[5]),
        .aux1 = @floatCast(std.math.clamp(coord.q[6], 0.0, 1.0)),
        .aux2 = @floatCast(std.math.clamp(coord.q[7], 0.0, 1.0)),
    };
}

/// Convert drone commands to RC PWM channels (1000-2000μs)
pub fn commandsToRcPwm(
    roll: f32,
    pitch: f32,
    yaw: f32,
    thrust: f32,
    gimbal_pitch: f32,
    gimbal_yaw: f32,
    aux1: f32,
    aux2: f32,
) [8]u16 {
    return [8]u16{
        angleToPwm(roll, -std.math.pi / 4.0, std.math.pi / 4.0),
        angleToPwm(pitch, -std.math.pi / 4.0, std.math.pi / 4.0),
        normToPwm(thrust),
        angleToPwm(yaw, -std.math.pi, std.math.pi),
        angleToPwm(gimbal_pitch, -std.math.pi / 2.0, std.math.pi / 2.0),
        angleToPwm(gimbal_yaw, -std.math.pi, std.math.pi),
        normToPwm(aux1),
        normToPwm(aux2),
    };
}

fn angleToPwm(angle: f32, min_angle: f32, max_angle: f32) u16 {
    const normalized = (angle - min_angle) / (max_angle - min_angle);
    return @intFromFloat(std.math.clamp(normalized * 1000.0 + 1000.0, 1000.0, 2000.0));
}

fn normToPwm(val: f32) u16 {
    return @intFromFloat(std.math.clamp(val * 1000.0 + 1000.0, 1000.0, 2000.0));
}

// ============================================================================
// ROBOT FEEDBACK → 8-DOF (backward morphism)
// ============================================================================

pub fn droneStateToGeneralizedCoordinate(state: DroneState) LuxGeneralizedCoordinate {
    return .{
        .q = [8]f64{
            @floatCast(state.attitude.roll),
            @floatCast(state.attitude.pitch),
            @floatCast(state.attitude.yaw),
            @as(f64, @floatFromInt(state.throttle)) / 100.0,
            0.0, // gimbal pitch (from gimbal message, not in base state)
            0.0, // gimbal yaw
            @as(f64, @floatFromInt(state.position.relative_alt)) / 1000.0, // alt in meters
            @floatCast(state.groundspeed),
        },
        .q_dot = [8]f64{
            @floatCast(state.attitude.rollspeed),
            @floatCast(state.attitude.pitchspeed),
            @floatCast(state.attitude.yawspeed),
            @floatCast(state.climb),
            0.0,
            0.0,
            @as(f64, @floatFromInt(state.position.vz)) / 100.0,
            0.0,
        },
        .q_ddot = [8]f64{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .timestamp_us = state.timestamp_us,
    };
}

// ============================================================================
// MAVLINK CRC (X.25)
// ============================================================================

const MAVLINK_CRC_INIT: u16 = 0xFFFF;

fn computeMAVLinkCrc(payload: []const u8, msgid: u24) u16 {
    var crc: u16 = MAVLINK_CRC_INIT;

    // CRC includes: payload length, ... but simplified for encoding
    for (payload) |byte| {
        crc = crcAccumulate(byte, crc);
    }

    // CRC extra byte per message (seed) — lookup table for common messages
    const crc_extra = getCrcExtra(msgid);
    crc = crcAccumulate(crc_extra, crc);

    return crc;
}

fn crcAccumulate(byte: u8, crc_in: u16) u16 {
    var crc = crc_in;
    var tmp: u8 = byte ^ @as(u8, @intCast(crc & 0xFF));
    tmp ^= (tmp << 4);
    crc = (crc >> 8) ^
        (@as(u16, tmp) << 8) ^
        (@as(u16, tmp) << 3) ^
        (@as(u16, tmp) >> 4);
    return crc;
}

/// CRC extra bytes for common MAVLink messages
fn getCrcExtra(msgid: u24) u8 {
    return switch (msgid) {
        0 => 50, // HEARTBEAT
        30 => 39, // ATTITUDE
        33 => 104, // GLOBAL_POSITION_INT
        70 => 124, // RC_CHANNELS_OVERRIDE
        74 => 20, // VFR_HUD
        76 => 152, // COMMAND_LONG
        77 => 143, // COMMAND_ACK
        82 => 22, // SET_ATTITUDE_TARGET
        147 => 154, // BATTERY_STATUS
        else => 0,
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "dimension extraction and PWM conversion" {
    const coord: LuxGeneralizedCoordinate = .{
        .q = [8]f64{ 0.1, -0.1, 0.5, 0.6, -0.3, 0.2, 0.5, 0.0 },
        .q_dot = [8]f64{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .q_ddot = [8]f64{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .timestamp_us = 0,
    };

    const cmds = extractDroneCommands(coord);
    try std.testing.expect(cmds.roll > 0);
    try std.testing.expect(cmds.pitch < 0);
    try std.testing.expect(cmds.thrust > 0.5);
    try std.testing.expect(cmds.thrust < 0.7);

    const pwm = commandsToRcPwm(
        cmds.roll,
        cmds.pitch,
        cmds.yaw,
        cmds.thrust,
        cmds.gimbal_pitch,
        cmds.gimbal_yaw,
        cmds.aux1,
        cmds.aux2,
    );

    // All PWM values should be in valid range
    for (pwm) |p| {
        try std.testing.expect(p >= 1000);
        try std.testing.expect(p <= 2000);
    }

    // Throttle at 0.6 → ~1600 PWM
    try std.testing.expect(pwm[2] >= 1550);
    try std.testing.expect(pwm[2] <= 1650);
}

test "drone state to coordinate roundtrip" {
    const state = DroneState{
        .attitude = .{
            .roll = 0.1,
            .pitch = -0.05,
            .yaw = 1.5,
            .rollspeed = 0.01,
            .pitchspeed = -0.01,
            .yawspeed = 0.02,
            .timestamp_ms = 12345,
        },
        .position = .{
            .lat = 377749300,
            .lon = -1224193300,
            .alt = 50000,
            .relative_alt = 10000, // 10m AGL
            .vx = 100,
            .vy = 50,
            .vz = -20,
            .hdg = 27000,
        },
        .airspeed = 5.0,
        .groundspeed = 4.5,
        .throttle = 60,
        .climb = 0.5,
        .battery_remaining = 85,
        .armed = true,
        .mode = .guided,
        .timestamp_us = 99999,
    };

    const coord = droneStateToGeneralizedCoordinate(state);

    // Roll maps to q[0]
    try std.testing.expectApproxEqAbs(coord.q[0], 0.1, 0.001);
    // Altitude in meters = relative_alt / 1000
    try std.testing.expectApproxEqAbs(coord.q[6], 10.0, 0.001);
    // Groundspeed maps to q[7]
    try std.testing.expectApproxEqAbs(coord.q[7], 4.5, 0.001);
}

test "crc accumulate" {
    // Known MAVLink CRC test vector
    var crc: u16 = MAVLINK_CRC_INIT;
    crc = crcAccumulate('H', crc);
    crc = crcAccumulate('e', crc);
    crc = crcAccumulate('l', crc);
    crc = crcAccumulate('l', crc);
    crc = crcAccumulate('o', crc);
    try std.testing.expect(crc != MAVLINK_CRC_INIT);
}
