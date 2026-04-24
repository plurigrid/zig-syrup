# Smart Energy Interfaces for zig-syrup

## Post-Vendor-Lock-In Interoperable Standards

*Plurigrid microinverters: smarter AND kinder.*
*Every protocol open. Every component auditable. Every bit accountable.*

---

## Threat Model: Why This Matters

**May 2025**: Undocumented cellular radios found inside Chinese-made solar
inverters (Reuters/Schneier). Not just firmware backdoors — physical rogue
communication hardware bypassing all software firewalls.

**Oct 2025**: EU lawmakers write to European Commission urging restriction
of "high-risk vendors" (Huawei, Sungrow) from solar energy systems.
Chinese firms control ~65% of Europe's installed inverter capacity.
Lithuania, Czech Republic, Germany already restricting.

**Jan 2026**: EU ISS brief "The Dragon in the Grid" — China systematically
embedded in renewable energy supply chains, connected devices, and EU
energy system operators. Recommends "Made in Europe" for critical infra.

**The 18-eyes requirement**: Every component must be:
1. Open-specification protocol (no proprietary cloud dependency)
2. Auditable firmware (SBOM — Substation Bill of Materials, CycloneDX)
3. Locally controllable (no mandatory cloud phone-home)
4. Cryptographically attested (supply chain verification)
5. GF(3) conservation-checked (triadic balance = integrity invariant)

---

## Protocol Landscape (7 standards, 3 transport layers)

### Layer 1: Grid ↔ Utility (Wide Area)

| Protocol | Scope | Transport | Format | Status |
|----------|-------|-----------|--------|--------|
| **IEEE 2030.5** (SEP 2.0) | DER management, demand response, pricing | HTTPS/TLS | XML (EXI) | CA Rule 21 mandated |
| **OpenADR 3.0** | Demand response signaling | HTTPS | XML/JSON | Utility→aggregator |
| **IEC 61850** | Substation automation, GOOSE/MMS | TCP/MMS, multicast | ASN.1/XML (SCL) | Grid-critical, SBOM-auditable |

### Layer 2: Site ↔ Devices (Local Area)

| Protocol | Scope | Transport | Format | Status |
|----------|-------|-----------|--------|--------|
| **SunSpec Modbus** | Inverter/battery/meter registers | TCP/RTU | Register maps | Industry standard |
| **Matter 1.4** | Smart home energy mgmt (NEW) | Thread/WiFi/Ethernet | TLV | Solar, battery, EV, HVAC device types |
| **OCPP 2.1** | EV charging | WebSocket/JSON | JSON-RPC | DER-aware |

### Layer 3: Device ↔ Cloud / SCADA (Telemetry)

| Protocol | Scope | Transport | Format | Status |
|----------|-------|-----------|--------|--------|
| **MQTT 5.0** | Pub/sub telemetry | TCP/TLS :1883/:8883 | Free-form | Universal |
| **Sparkplug B** | Structured MQTT for IIoT/SCADA | MQTT 5.0 | Protobuf | Eclipse Foundation open spec |

---

## Architecture: zig-syrup Smart Energy Stack

```
                    ┌─────────────────────────────────┐
                    │      OCapN / Syrup Transport     │
                    │   (Capability-secure, auditable) │
                    └──────────┬──────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────▼──────┐ ┌──────▼──────┐ ┌───────▼──────┐
     │  MQTT Client  │ │ HTTP/TLS    │ │ Modbus TCP   │
     │ (Sparkplug B) │ │ (2030.5/ADR)│ │ (SunSpec)    │
     └────────┬──────┘ └──────┬──────┘ └───────┬──────┘
              │                │                │
     ┌────────▼──────┐ ┌──────▼──────┐ ┌───────▼──────┐
     │ Device Drivers │ │ Grid Iface  │ │ Inverter/DER │
     │ Tapo, Shelly,  │ │ IEEE 2030.5 │ │ SunSpec regs │
     │ Matter bridge  │ │ OpenADR 3   │ │ Deye, Hoymiles│
     └────────┬──────┘ └──────┬──────┘ └───────┬──────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────▼──────────────────────┐
                    │      GF(3) Energy Classifier     │
                    │  +1 GENERATOR  0 ERGODIC  -1 VAL │
                    │  Conservation: Σtrit = 0          │
                    └──────────┬──────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────▼──────┐ ┌──────▼──────┐ ┌───────▼──────┐
     │  Propagator   │ │  ReadingRing │ │   SBOM       │
     │  Cell Network │ │  (time series)│ │  Attestation │
     └───────────────┘ └──────────────┘ └──────────────┘
```

---

## Module Plan (8 new zig-syrup modules)

### 1. `mqtt_client.zig` — MQTT 5.0 Client

Pure Zig MQTT 5.0 client. No C dependencies. Fixed-buffer packet
encoding/decoding.

```zig
pub const MqttClient = struct {
    allocator: Allocator,
    stream: net.Stream,
    client_id: []const u8,
    state: ConnectionState,

    pub fn connect(self: *MqttClient, broker: net.Address, opts: ConnectOpts) !void;
    pub fn publish(self: *MqttClient, topic: []const u8, payload: []const u8, qos: QoS) !void;
    pub fn subscribe(self: *MqttClient, topic_filter: []const u8, qos: QoS) !void;
    pub fn poll(self: *MqttClient) !?Message;
    pub fn disconnect(self: *MqttClient) void;
};

pub const QoS = enum(u2) { at_most_once = 0, at_least_once = 1, exactly_once = 2 };

pub const ConnectOpts = struct {
    clean_start: bool = true,
    keep_alive_sec: u16 = 60,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    will_topic: ?[]const u8 = null,
    will_payload: ?[]const u8 = null,
    tls: bool = false,
};
```

**Key properties**:
- Zero allocation in hot path (publish/subscribe)
- Fixed 64KB accumulator for packet reassembly
- MQTT 5.0 properties support (topic alias, user properties)
- Will message for device death certificates (Sparkplug B)

### 2. `sparkplug.zig` — Sparkplug B Codec

Sparkplug B topic namespace + Protobuf payload encoding.
State management (NBIRTH/NDEATH/DBIRTH/DDEATH/DDATA).

```zig
pub const SparkplugTopic = struct {
    namespace: []const u8 = "spBv1.0",
    group_id: []const u8,       // e.g. "plurigrid"
    message_type: MessageType,   // NBIRTH, NDEATH, DBIRTH, DDEATH, DDATA, DCMD
    edge_node_id: []const u8,   // e.g. "microinverter-001"
    device_id: ?[]const u8,     // e.g. "panel-A3"

    pub fn format(self: SparkplugTopic, buf: []u8) []const u8;
    // → "spBv1.0/plurigrid/DDATA/microinverter-001/panel-A3"
};

pub const MessageType = enum {
    NBIRTH, NDEATH, DBIRTH, DDEATH, DDATA, DCMD, NCMD, STATE,
};

pub const Metric = struct {
    name: []const u8,
    timestamp: u64,          // epoch ms
    datatype: DataType,
    value: MetricValue,
    // GF(3) extension: trit classification
    trit: ?Trit = null,
};

/// Protobuf-lite encoding (Sparkplug B payload)
pub fn encodePayload(metrics: []const Metric, buf: []u8) !usize;
pub fn decodePayload(buf: []const u8, metrics: []Metric) !usize;
```

**Topic hierarchy for Plurigrid**:
```
spBv1.0/plurigrid/NBIRTH/site-001          # Edge node birth
spBv1.0/plurigrid/DBIRTH/site-001/inv-A    # Microinverter birth
spBv1.0/plurigrid/DDATA/site-001/inv-A     # Telemetry data
spBv1.0/plurigrid/DCMD/site-001/inv-A      # Command to inverter
spBv1.0/plurigrid/NDEATH/site-001          # Edge node death
```

### 3. `sunspec_modbus.zig` — SunSpec Modbus Register Maps

SunSpec-compliant Modbus TCP client for inverter/battery/meter
communication. Register map definitions per SunSpec Information Models.

```zig
pub const SunSpecModel = enum(u16) {
    common = 1,            // Manufacturer, model, serial
    inverter_single = 101, // Single phase inverter
    inverter_split = 102,  // Split phase
    inverter_three = 103,  // Three phase
    nameplate = 120,       // DER nameplate ratings
    settings = 121,        // DER settings (Vref, Wmax)
    status = 122,          // DER status
    controls = 123,        // DER controls (connect/disconnect)
    storage = 124,         // Storage model (battery)
    pricing = 125,         // Pricing signals
    mppt = 160,            // MPPT extension (per-string)
};

pub const ModbusClient = struct {
    stream: net.Stream,
    unit_id: u8,

    pub fn readHolding(self: *ModbusClient, addr: u16, count: u16, buf: []u16) !void;
    pub fn writeSingle(self: *ModbusClient, addr: u16, value: u16) !void;
    pub fn writeMultiple(self: *ModbusClient, addr: u16, values: []const u16) !void;
};

/// Read a complete SunSpec model from an inverter
pub fn readModel(client: *ModbusClient, model: SunSpecModel, buf: []u8) !ModelData;

/// Common model (1): manufacturer, model, serial, firmware version
pub const CommonModel = struct {
    manufacturer: [32]u8,
    model: [32]u8,
    serial: [32]u8,
    fw_version: [16]u8,
    // ... SBOM fields for supply chain attestation
};

/// Inverter model (101-103): real-time AC power, energy, voltage, current
pub const InverterModel = struct {
    ac_power_w: i16,
    ac_energy_wh: u32,
    ac_voltage_v: u16,    // scale factor applied
    ac_current_a: u16,
    dc_power_w: i16,
    dc_voltage_v: u16,
    dc_current_a: u16,
    cabinet_temp_c: i16,
    operating_state: OperatingState,
    // GF(3) classification derived from power flow
    trit: Trit,
};
```

### 4. `ieee2030_5.zig` — IEEE 2030.5 / CSIP Client

Smart Energy Profile 2.0 client for DER-to-utility communication.
RESTful HTTP/TLS with EXI (Efficient XML Interchange) encoding.

```zig
pub const Sep2Client = struct {
    allocator: Allocator,
    base_url: [256]u8,
    tls_cert: ?[]const u8,     // mTLS client certificate
    tls_key: ?[]const u8,

    /// Discover available function sets
    pub fn getDeviceCapability(self: *Sep2Client) !DeviceCapability;

    /// Read DER program list
    pub fn getDerProgramList(self: *Sep2Client) ![]DerProgram;

    /// Submit DER status
    pub fn postDerStatus(self: *Sep2Client, status: DerStatus) !void;

    /// Read pricing signals
    pub fn getPricing(self: *Sep2Client) ![]PricingSignal;
};

pub const DerProgram = struct {
    description: []const u8,
    default_control: DerControl,
    primacy: u8,            // priority (lower = higher priority)
};

pub const DerControl = struct {
    mode: ControlMode,
    op_mod_connect: bool,
    op_mod_energize: bool,
    op_mod_max_w: ?f32,     // max watts setpoint
    op_mod_pf: ?f32,        // power factor
    op_mod_var: ?f32,       // reactive power
    // GF(3): generation(+), curtailment(-), passthrough(0)
    trit: Trit,
};
```

### 5. `energy_classifier.zig` — Unified GF(3) Energy Classifier

Cross-protocol energy classification. Every device, every protocol,
every reading maps to the same GF(3) trit taxonomy.

```zig
/// Energy flow classification across all device types
pub const EnergyFlow = enum {
    /// +1 GENERATOR: producing/exporting energy
    generating,
    /// 0 ERGODIC: passthrough, balanced, idle
    ergodic,
    /// -1 VALIDATOR: consuming, curtailing, validating
    validating,

    pub fn toTrit(self: EnergyFlow) Trit { ... }
};

/// Classify any power reading
pub fn classify(watts: f32, context: DeviceContext) EnergyFlow {
    return switch (context.device_type) {
        .solar_inverter => if (watts > 10) .generating
                          else if (watts < -10) .validating
                          else .ergodic,
        .battery => if (watts > 0) .generating      // discharging
                    else if (watts < 0) .validating  // charging
                    else .ergodic,
        .ev_charger => if (watts > 0) .validating    // drawing power
                       else .ergodic,
        .smart_plug => if (watts > context.threshold_high) .generating
                       else if (watts < context.threshold_low) .validating
                       else .ergodic,
        .microinverter => if (watts > 5) .generating
                          else .ergodic,
    };
}

/// Device types in the smart energy taxonomy
pub const DeviceType = enum {
    solar_inverter,
    microinverter,
    battery,
    ev_charger,
    smart_plug,
    smart_meter,
    heat_pump,
    hvac,
    warehouse_ups,
    grid_tie,
};

/// Site-level GF(3) balance
pub const SiteBalance = struct {
    generators: u32,       // count of +1 devices
    ergodic: u32,          // count of 0 devices
    validators: u32,       // count of -1 devices
    net_trit: i32,         // running sum
    total_watts: f32,
    net_export_watts: f32, // positive = exporting to grid

    pub fn isBalanced(self: SiteBalance) bool {
        return self.net_trit == 0;
    }

    pub fn toSyrup(self: SiteBalance, allocator: Allocator) !syrup.Value;
};
```

### 6. `sbom_attestation.zig` — Supply Chain Verification

Hardware/firmware Bill of Materials verification. Every device must
prove its provenance. Inspired by IEC 61850 Subs-BOM (CycloneDX).

```zig
/// Device attestation record
pub const DeviceAttestation = struct {
    /// Manufacturer identity (from SunSpec Common Model or device cert)
    manufacturer: [64]u8,
    model: [64]u8,
    serial: [64]u8,
    firmware_version: [32]u8,

    /// SHA-256 of firmware binary (if readable)
    firmware_hash: [32]u8,

    /// Country of manufacture (ISO 3166-1)
    country_of_origin: [3]u8,

    /// TLS certificate fingerprint
    tls_cert_fingerprint: [32]u8,

    /// Known-good firmware hash list (from vendor or auditor)
    expected_fw_hash: ?[32]u8,

    /// Rogue hardware detection: unexpected network interfaces
    unexpected_interfaces: u8,

    /// Attestation result
    pub fn verify(self: *const DeviceAttestation) AttestationResult {
        // Check firmware hash matches expected
        if (self.expected_fw_hash) |expected| {
            if (!std.mem.eql(u8, &self.firmware_hash, &expected))
                return .firmware_mismatch;
        }
        // Check for rogue communication hardware
        if (self.unexpected_interfaces > 0)
            return .rogue_hardware_detected;
        return .verified;
    }
};

pub const AttestationResult = enum {
    verified,
    firmware_mismatch,
    rogue_hardware_detected,
    certificate_invalid,
    country_restricted,
    unverifiable,

    pub fn toTrit(self: AttestationResult) Trit {
        return switch (self) {
            .verified => .plus,          // +1 trusted
            .unverifiable => .zero,      // 0 unknown
            else => .minus,              // -1 failed
        };
    }
};
```

### 7. `matter_bridge.zig` — Matter 1.4 Energy Device Bridge

Bridge between Matter energy device types and zig-syrup.
Matter 1.4 adds: Solar Power, Battery Storage, EV Supply Equipment,
Device Energy Management, Water Heater Management.

```zig
/// Matter 1.4 energy device clusters
pub const MatterCluster = enum(u32) {
    electrical_measurement = 0x0B04,
    electrical_energy_measurement = 0x0091,
    device_energy_management = 0x0098,
    device_energy_management_mode = 0x009F,
    energy_evse = 0x0099,
    energy_evse_mode = 0x009D,
    power_topology = 0x009C,
};

/// Read Matter device via local commissioning (BLE/Thread/WiFi)
pub const MatterBridge = struct {
    // Matter operates over Thread (802.15.4) or WiFi
    // We bridge via the Matter controller's local API
    controller_addr: net.Address,

    pub fn readElectricalMeasurement(self: *MatterBridge, node_id: u64) !ElectricalMeasurement;
    pub fn readEnergyManagement(self: *MatterBridge, node_id: u64) !EnergyManagement;
    pub fn setEvseCurrent(self: *MatterBridge, node_id: u64, max_amps: u16) !void;
};
```

### 8. `openadr.zig` — OpenADR 3.0 Client

Demand response event subscription and dispatch.

```zig
pub const AdrClient = struct {
    base_url: [256]u8,
    ven_id: []const u8,     // Virtual End Node ID

    /// Register as VEN (Virtual End Node)
    pub fn register(self: *AdrClient) !void;

    /// Poll for DR events
    pub fn getEvents(self: *AdrClient) ![]DemandResponseEvent;

    /// Report opt-in/opt-out status
    pub fn reportStatus(self: *AdrClient, event_id: []const u8, status: OptStatus) !void;
};

pub const DemandResponseEvent = struct {
    event_id: []const u8,
    signal_type: SignalType,     // LEVEL, PRICE, LOAD_CONTROL
    signal_value: f32,
    start_time: u64,
    duration_sec: u32,
    // GF(3): curtail(-1), normal(0), generate(+1)
    trit: Trit,
};
```

---

## MQTT Topic Namespace for Plurigrid

```
# Sparkplug B structure
spBv1.0/plurigrid/NBIRTH/{site_id}                    # Site comes online
spBv1.0/plurigrid/DBIRTH/{site_id}/{device_id}        # Device birth
spBv1.0/plurigrid/DDATA/{site_id}/{device_id}         # Telemetry
spBv1.0/plurigrid/DCMD/{site_id}/{device_id}          # Commands
spBv1.0/plurigrid/NDEATH/{site_id}                    # Site death

# Plurigrid extensions (under spBv1.0 namespace)
spBv1.0/plurigrid/DDATA/{site_id}/{device_id}/gf3     # GF(3) trit stream
spBv1.0/plurigrid/DDATA/{site_id}/{device_id}/sbom    # Attestation
spBv1.0/plurigrid/DDATA/{site_id}/balance              # Site GF(3) balance

# Device examples
spBv1.0/plurigrid/DDATA/warehouse-sf/inv-001           # Microinverter
spBv1.0/plurigrid/DDATA/warehouse-sf/batt-001          # Battery
spBv1.0/plurigrid/DDATA/warehouse-sf/evse-001          # EV charger
spBv1.0/plurigrid/DDATA/warehouse-sf/plug-tapo-001     # Smart outlet
spBv1.0/plurigrid/DDATA/warehouse-sf/meter-001         # Smart meter

# Site-level aggregation
spBv1.0/plurigrid/DDATA/warehouse-sf/site-balance      # GF(3) conservation
# Payload: {generators: N, ergodic: M, validators: K, net_trit: 0, watts: ...}
```

---

## GF(3) Conservation Across the Smart Energy Stack

```
L14: Physical Energy Layer (this module)
  + generation (solar/wind/battery discharge)
  ○ passthrough (grid-tied, balanced)
  − consumption (load/charging/curtailment)

Conservation law at every scale:
  Device:    Σ(trit per reading over time) → 0 (charge/discharge balance)
  Site:      Σ(trit per device) → 0 (generation matches consumption)
  Grid:      Σ(trit per site) → 0 (supply equals demand)

The GF(3) invariant is the energy balance equation in algebraic form.
Generation - Consumption = ΔStorage
    (+1)    -    (-1)     =    (0)
```

---

## Supply Chain Security Model

### The "18 Eyes" Audit Trail

1. **Hardware attestation** (sbom_attestation.zig)
   - Firmware hash verification against known-good list
   - Network interface enumeration (detect rogue radios)
   - Certificate chain validation (no self-signed in production)
   - Country-of-origin check (configurable restricted list)

2. **Protocol verification** (every module)
   - All traffic Syrup-serializable for audit replay
   - No proprietary binary blobs in wire protocol
   - Every command/response logged with CID (content-addressed)

3. **Runtime monitoring** (propagator network)
   - Anomaly detection via propagator contradiction cells
   - Unexpected traffic patterns → contradiction → alert
   - GF(3) imbalance beyond threshold → investigate

### What Even Huawei Cannot Sneak Past:

```
Device connects → SBOM check
  ├─ Firmware hash ≠ expected → BLOCK
  ├─ Rogue interfaces detected → BLOCK
  ├─ Certificate from restricted CA → BLOCK
  └─ All clear → ADMIT with continuous monitoring
       ├─ Traffic patterns logged (Syrup CID)
       ├─ GF(3) conservation checked per cycle
       ├─ Propagator contradiction → isolate device
       └─ All readings auditable, replayable, verifiable
```

---

## Implementation Priority

| Phase | Module | LOC est. | Deps |
|-------|--------|----------|------|
| **1** | `mqtt_client.zig` | 800 | tcp_transport |
| **1** | `sparkplug.zig` | 400 | mqtt_client, syrup |
| **2** | `sunspec_modbus.zig` | 600 | tcp_transport |
| **2** | `energy_classifier.zig` | 300 | continuation (Trit) |
| **3** | `sbom_attestation.zig` | 400 | crypto, syrup |
| **3** | `matter_bridge.zig` | 500 | tcp_transport, syrup |
| **4** | `ieee2030_5.zig` | 700 | http/tls, syrup |
| **4** | `openadr.zig` | 400 | http/tls, syrup |

Total: ~4,100 LOC across 8 modules

### What Already Exists:
- `tapo_energy.zig` (680 LOC) — Tapo P15 smart plug driver ✅
- `tcp_transport.zig` — Framed TCP connections ✅
- `message_frame.zig` — Length-prefix framing ✅
- `propagator.zig` — Constraint propagation ✅
- `syrup.zig` — Serialization ✅
- `continuation.zig` — GF(3) Trit type ✅

---

## References

- [IEEE 2030.5 / SunSpec CSIP](https://sunspec.org/ieee-2030-5-csip-certification/)
- [OpenADR 3 ↔ Matter interworking spec](https://geotogether.com/wp-content/uploads/2025/04/Matter_OpenADR3.x_Interworking_Spec_v1.0.pdf)
- [Matter 1.4 energy management](https://csa-iot.org/newsroom/matter-1-4-enables-more-capable-smart-homes/)
- [Sparkplug B spec v2.2](https://sparkplug.eclipse.org/specification/version/2.2/documents/sparkplug-specification-2.2.pdf)
- [IEC 61850 Subs-BOM for supply chain](https://www.arxiv.org/pdf/2503.19638)
- [EU ISS: Dragon in the Grid](https://www.iss.europa.eu/publications/briefs/dragon-grid-limiting-chinas-influence-europes-energy-system)
- [Schneier: Backdoors in Chinese inverters](https://www.schneier.com/blog/archives/2025/05/communications-backdoor-in-chinese-power-inverters.html)
- [OpenDTU MQTT topics](https://www.opendtu.solar/firmware/mqtt_topics/)
- [Deye inverter MQTT bridge](https://github.com/kbialek/deye-inverter-mqtt)
- [SolarEdge2MQTT](https://github.com/DerOetzi/solaredge2mqtt)
