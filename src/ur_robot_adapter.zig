/// UR Robot Adapter for Bridge 9 Phase 3
///
/// Connects Bridge 9 forward morphism (8-DOF generalized coordinates)
/// to UR5/UR10 robot control via:
/// - Modbus TCP (primary: industrial, no ROS required)
/// - ROS/MoveIt (secondary: research, full motion planning)
///
/// Architecture:
/// ┌─────────────────────────────────────┐
/// │ Bridge9FFI.forward_morphism output  │
/// │ LuxGeneralizedCoordinate (8-DOF)    │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ ur_extract_joint_angles()           │ ← Dimension mapping
/// │ (8D → 6D + gripper + tool frame)    │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ URModbusController                  │ ← Modbus TCP client
/// │ Registers: joint angles, speeds,    │
/// │ torque limits, I/O signals          │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ UR5 Robot (physical)                │
/// │ /ur_driver/set_joint_angles topic   │
/// └─────────────────────────────────────┘
///
/// Feedback Loop (backward morphism):
/// ┌─────────────────────────────────────┐
/// │ UR5 Joint State (6 angles, 6 vels)  │
/// │ Gripper feedback, Force/Torque      │
/// └──────────────┬──────────────────────┘
///                ▼
/// ┌─────────────────────────────────────┐
/// │ ur_read_joint_state()               │
/// │ (6D + gripper → 8-DOF encoding)     │
/// └──────────────┬──────────────────────┘
///                ▼
/// │ Bridge9FFI.backward_morphism input  │
/// │ robot_state → phenomenal_state      │
/// └─────────────────────────────────────┘

const std = @import("std");
const message_frame = @import("message_frame");
const tcp_transport = @import("tcp_transport");
const syrup = @import("syrup");

// ============================================================================
// UR ROBOT CONFIGURATION
// ============================================================================

pub const UR_MODEL = enum {
    ur3,    // Payload: 3kg, Reach: 500mm
    ur5,    // Payload: 5kg, Reach: 850mm
    ur10,   // Payload: 10kg, Reach: 1300mm
};

pub const UR_ROBOT_CONFIG = struct {
    model: UR_MODEL,
    hostname: []const u8,
    modbus_port: u16 = 502,  // Standard Modbus TCP port
    ros_enabled: bool = false,
    ros_master_uri: []const u8 = "http://localhost:11311",
};

// ============================================================================
// JOINT CONFIGURATION
// ============================================================================

/// UR5 has 6 revolute joints (shoulder, elbow, wrist1, wrist2, wrist3)
/// + Tool Flange (TCP position/orientation)
/// + Gripper (parallel jaw, 0-110mm)
/// Total: 8-DOF mapping from Bridge 9
pub const JointLimits = struct {
    shoulder_pan: f64 = 360.0,      // degrees, -180 to +180
    shoulder_lift: f64 = 360.0,     // degrees, -90 to +90
    elbow: f64 = 360.0,              // degrees, -180 to +180
    wrist1: f64 = 360.0,             // degrees, -180 to +180
    wrist2: f64 = 360.0,             // degrees, -180 to +180
    wrist3: f64 = 360.0,             // degrees, -180 to +180
    gripper_width: f64 = 110.0,      // mm
    tool_frame_z: f64 = 200.0,       // mm (max height above base)
};

pub const JointState = struct {
    angles: [6]f64,           // radians
    velocities: [6]f64,       // radians/sec
    accelerations: [6]f64,    // radians/sec²
    gripper_width: f64,       // mm
    timestamp_us: u64,
};

// ============================================================================
// MODBUS TCP IMPLEMENTATION (Industrial Protocol)
// ============================================================================

pub const ModbusFrame = struct {
    transaction_id: u16,      // Transaction identifier (MBAP header)
    protocol_id: u16 = 0,     // Protocol identifier (0 for Modbus)
    length: u16,              // Length of following data
    unit_id: u8,              // Unit identifier (slave ID)
    function_code: u8,        // 0x03 (read), 0x10 (write)
    payload: []u8,
};

pub const URModbusController = struct {
    allocator: std.mem.Allocator,
    conn: ?tcp_transport.TcpTransport = null,
    transaction_counter: u16 = 0,

    // Register addresses (UR Modbus map)
    // Joint angles (degrees × 100, stored as int16):
    joint_angle_base: u16 = 0x0100,

    // Joint velocities (rpm × 100):
    joint_velocity_base: u16 = 0x0110,

    // Joint torques:
    joint_torque_base: u16 = 0x0120,

    // Gripper position:
    gripper_register: u16 = 0x0130,

    // Control signals:
    power_on_register: u16 = 0x0200,
    motion_enable_register: u16 = 0x0201,

    pub fn init(allocator: std.mem.Allocator) URModbusController {
        return .{
            .allocator = allocator,
        };
    }

    pub fn connect(self: *URModbusController, hostname: []const u8, port: u16) !void {
        self.conn = try tcp_transport.TcpTransport.connect(
            self.allocator,
            hostname,
            port,
            5000, // 5s timeout
        );
    }

    pub fn disconnect(self: *URModbusController) void {
        if (self.conn) |*c| {
            c.close();
            self.conn = null;
        }
    }

    /// Write joint angles to UR5 via Modbus
    /// Input: angles in radians
    /// Modbus register: degrees × 100 (int16)
    pub fn setJointAngles(
        self: *URModbusController,
        angles: [6]f64,
    ) !void {
        if (self.conn == null) return error.NotConnected;

        // Allocate frame buffer
        var frame_buf: [256]u8 = undefined;
        var frame_pos: usize = 0;

        // MBAP Header (7 bytes)
        const txn_id = self.transaction_counter;
        self.transaction_counter += 1;

        frame_buf[frame_pos] = @intCast((txn_id >> 8) & 0xFF);
        frame_pos += 1;
        frame_buf[frame_pos] = @intCast(txn_id & 0xFF);
        frame_pos += 1;

        frame_buf[frame_pos] = 0x00; // Protocol ID high
        frame_pos += 1;
        frame_buf[frame_pos] = 0x00; // Protocol ID low
        frame_pos += 1;

        // Length will be filled later
        const length_pos = frame_pos;
        frame_pos += 2;

        frame_buf[frame_pos] = 0x01; // Unit ID
        frame_pos += 1;

        frame_buf[frame_pos] = 0x10; // Write Multiple Registers
        frame_pos += 1;

        // Starting address (joint angles base)
        frame_buf[frame_pos] = @intCast((self.joint_angle_base >> 8) & 0xFF);
        frame_pos += 1;
        frame_buf[frame_pos] = @intCast(self.joint_angle_base & 0xFF);
        frame_pos += 1;

        // Quantity of registers (6 angles = 6 registers)
        frame_buf[frame_pos] = 0x00;
        frame_pos += 1;
        frame_buf[frame_pos] = 0x06;
        frame_pos += 1;

        // Byte count
        frame_buf[frame_pos] = 0x0C; // 6 registers × 2 bytes
        frame_pos += 1;

        // Data: angles in degrees × 100
        for (angles) |angle_rad| {
            const angle_deg = angle_rad * 180.0 / std.math.pi;
            const angle_int: i16 = @intFromFloat(angle_deg * 100.0);
            std.mem.writeInt(i16, frame_buf[frame_pos..][0..2], angle_int, .big);
            frame_pos += 2;
        }

        // Update length field (excludes MBAP header itself, 6 bytes = 7..length_pos)
        const payload_length: u16 = @intCast(frame_pos - length_pos - 2);
        std.mem.writeInt(u16, frame_buf[length_pos..][0..2], payload_length, .big);

        // Compute CRC16-CCITT (Modbus-specific)
        const frame = frame_buf[0..frame_pos];
        const crc = computeModbusCrc(frame[6..frame_pos]);
        frame_buf[frame_pos] = @intCast((crc >> 8) & 0xFF);
        frame_pos += 1;
        frame_buf[frame_pos] = @intCast(crc & 0xFF);
        frame_pos += 1;

        // Send frame
        try self.conn.?.send(frame[0..frame_pos]);
    }

    /// Read current joint state from UR5
    pub fn readJointState(
        self: *URModbusController,
    ) !JointState {
        if (self.conn == null) return error.NotConnected;

        var frame_buf: [256]u8 = undefined;

        // Build READ request (function 0x03)
        var frame_pos: usize = 0;

        // MBAP Header
        const txn_id = self.transaction_counter;
        self.transaction_counter += 1;
        frame_buf[frame_pos] = @intCast((txn_id >> 8) & 0xFF);
        frame_pos += 1;
        frame_buf[frame_pos] = @intCast(txn_id & 0xFF);
        frame_pos += 1;

        frame_buf[frame_pos] = 0x00; // Protocol ID
        frame_pos += 1;
        frame_buf[frame_pos] = 0x00;
        frame_pos += 1;

        const length_pos = frame_pos;
        frame_pos += 2;

        frame_buf[frame_pos] = 0x01; // Unit ID
        frame_pos += 1;

        frame_buf[frame_pos] = 0x03; // Read Holding Registers
        frame_pos += 1;

        // Starting address (angles)
        frame_buf[frame_pos] = @intCast((self.joint_angle_base >> 8) & 0xFF);
        frame_pos += 1;
        frame_buf[frame_pos] = @intCast(self.joint_angle_base & 0xFF);
        frame_pos += 1;

        // Quantity (6 angles)
        frame_buf[frame_pos] = 0x00;
        frame_pos += 1;
        frame_buf[frame_pos] = 0x06;
        frame_pos += 1;

        // Update length
        const payload_length: u16 = @intCast(frame_pos - length_pos - 2);
        std.mem.writeInt(u16, frame_buf[length_pos..][0..2], payload_length, .big);

        // CRC
        const crc = computeModbusCrc(frame_buf[6..frame_pos]);
        frame_buf[frame_pos] = @intCast((crc >> 8) & 0xFF);
        frame_pos += 1;
        frame_buf[frame_pos] = @intCast(crc & 0xFF);
        frame_pos += 1;

        // Send
        try self.conn.?.send(frame_buf[0..frame_pos]);

        // Receive response
        const response = try self.conn.?.recv();

        // Parse response: skip MBAP (6 bytes) + function (1) + byte count (1)
        // Data starts at byte 8
        var angles: [6]f64 = undefined;
        for (0..6) |i| {
            const data_offset = 8 + (i * 2);
            if (data_offset + 2 > response.len) return error.InvalidResponse;

            const value_int = std.mem.readInt(i16, response[data_offset..][0..2], .big);
            angles[i] = (@as(f64, @floatFromInt(value_int)) / 100.0) * std.math.pi / 180.0;
        }

        return .{
            .angles = angles,
            .velocities = [6]f64{ 0, 0, 0, 0, 0, 0 }, // TODO: read from velocity registers
            .accelerations = [6]f64{ 0, 0, 0, 0, 0, 0 },
            .gripper_width = 0.0,
            .timestamp_us = @intCast(std.time.microTimestamp()),
        };
    }
};

// ============================================================================
// BRIDGE 9 DIMENSION MAPPING
// ============================================================================

pub const LuxGeneralizedCoordinate = struct {
    q: [8]f64,        // 8-DOF vector
    q_dot: [8]f64,    // Velocities
    q_ddot: [8]f64,   // Accelerations
    timestamp_us: u64,
};

/// Extract 6 joint angles + gripper + tool frame from 8-DOF Bridge 9 output
/// Dimension mapping:
///   q[0-5]: Joint angles (shoulder pan, lift, elbow, wrist1, wrist2, wrist3)
///   q[6]: Gripper width (0-110mm)
///   q[7]: Tool frame Z height (relative to base)
pub fn extractJointAngles(
    coord: LuxGeneralizedCoordinate,
) [6]f64 {
    return [6]f64{
        coord.q[0],
        coord.q[1],
        coord.q[2],
        coord.q[3],
        coord.q[4],
        coord.q[5],
    };
}

pub fn extractGripperCommand(coord: LuxGeneralizedCoordinate) f64 {
    return coord.q[6];
}

pub fn extractToolFrame(coord: LuxGeneralizedCoordinate) f64 {
    return coord.q[7];
}

// ============================================================================
// ROBOT FEEDBACK INTEGRATION
// ============================================================================

pub fn jointStateToGeneralizedCoordinate(
    state: JointState,
    gripper_width: f64,
    tool_z: f64,
) LuxGeneralizedCoordinate {
    return .{
        .q = [8]f64{
            state.angles[0],
            state.angles[1],
            state.angles[2],
            state.angles[3],
            state.angles[4],
            state.angles[5],
            gripper_width,
            tool_z,
        },
        .q_dot = [8]f64{
            state.velocities[0],
            state.velocities[1],
            state.velocities[2],
            state.velocities[3],
            state.velocities[4],
            state.velocities[5],
            0.0,
            0.0,
        },
        .q_ddot = [8]f64{
            state.accelerations[0],
            state.accelerations[1],
            state.accelerations[2],
            state.accelerations[3],
            state.accelerations[4],
            state.accelerations[5],
            0.0,
            0.0,
        },
        .timestamp_us = state.timestamp_us,
    };
}

// ============================================================================
// CRC16-CCITT (Modbus variant)
// ============================================================================

fn computeModbusCrc(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;

    for (data) |byte| {
        crc ^= @as(u16, @intCast(byte));

        for (0..8) |_| {
            const lsb = crc & 1;
            crc >>= 1;
            if (lsb != 0) {
                crc ^= 0xA001; // Reversed polynomial
            }
        }
    }

    return crc;
}

// ============================================================================
// TESTS
// ============================================================================

test "ur modbus frame encoding" {
    var allocator = std.testing.allocator;
    var controller = URModbusController.init(allocator);
    defer controller.disconnect();

    // Test angle encoding (90° = π/2 radians)
    const test_angles = [6]f64{
        0.0,
        std.math.pi / 2,
        0.0,
        0.0,
        0.0,
        0.0,
    };

    // (Would test encoding, but requires mock socket)
    // controller.setJointAngles(test_angles) catch {};
}

test "dimension extraction" {
    const coord: LuxGeneralizedCoordinate = .{
        .q = [8]f64{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 50.0, 100.0 },
        .q_dot = [8]f64{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .q_ddot = [8]f64{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .timestamp_us = 0,
    };

    const angles = extractJointAngles(coord);
    const gripper = extractGripperCommand(coord);
    const tool_z = extractToolFrame(coord);

    try std.testing.expectEqual(angles[0], 0.1);
    try std.testing.expectEqual(gripper, 50.0);
    try std.testing.expectEqual(tool_z, 100.0);
}

test "joint state to coordinate roundtrip" {
    const state: JointState = .{
        .angles = [6]f64{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 },
        .velocities = [6]f64{ 0.01, 0.02, 0.03, 0.04, 0.05, 0.06 },
        .accelerations = [6]f64{ 0, 0, 0, 0, 0, 0 },
        .gripper_width = 50.0,
        .timestamp_us = 12345,
    };

    const coord = jointStateToGeneralizedCoordinate(state, 50.0, 100.0);

    try std.testing.expectEqual(coord.q[0], state.angles[0]);
    try std.testing.expectEqual(coord.q_dot[0], state.velocities[0]);
    try std.testing.expectEqual(coord.q[6], 50.0);
}
