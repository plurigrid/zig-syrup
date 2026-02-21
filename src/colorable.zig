//! # Colorable Combinatorial Complex Interface
//! 
//! GF(3) trit coloring, voice mapping, and Strange Loop pioneer profiles.

const std = @import("std");
const lux_color = @import("lux_color.zig");
const Trit = lux_color.Trit;

pub const VoiceProfile = enum {
    shea,
    pokey,
    lawson,
    teichman,

    pub fn description(self: VoiceProfile) []const u8 {
        return switch (self) {
            .shea => "Efficient, technical, Perl-optimized (Emily Shea)",
            .pokey => "Hierarchical, tree-sitter based, structural (Pokey Rule)",
            .lawson => "Descriptive, equitable, nonvisual (Laurel Lawson)",
            .teichman => "Low-level, harmonic, digital-modeling (Peter Teichman)",
        };
    }
};

pub const SkillInfo = struct {
    name: []const u8,
    trit: Trit,
    voice: VoiceProfile,
};

pub const SKILLS = [_]SkillInfo{
    .{ .name = "11labs-acset", .trit = .minus, .voice = .shea },
    .{ .name = "aqua-voice-malleability", .trit = .plus, .voice = .pokey },
    .{ .name = "bci-colored-operad", .trit = .minus, .voice = .lawson },
    .{ .name = "elevenlabs-acset", .trit = .minus, .voice = .teichman },
    .{ .name = "ga-visualization", .trit = .minus, .voice = .shea },
    .{ .name = "invoice-organizer", .trit = .plus, .voice = .pokey },
    .{ .name = "lean4-music-topos", .trit = .plus, .voice = .lawson },
    .{ .name = "nerv", .trit = .plus, .voice = .teichman },
    .{ .name = "quantum-music", .trit = .ergodic, .voice = .shea },
    .{ .name = "say-narration", .trit = .minus, .voice = .pokey },
    .{ .name = "scientific-visualization", .trit = .ergodic, .voice = .lawson },
    .{ .name = "synthetic-adjunctions", .trit = .plus, .voice = .teichman },
    .{ .name = "topos-of-music", .trit = .ergodic, .voice = .shea },
    .{ .name = "voice-channel-uwd", .trit = .ergodic, .voice = .pokey },
    .{ .name = "whitehole-audio", .trit = .ergodic, .voice = .lawson },
    .{ .name = "12-factor-app-modernization", .trit = .plus, .voice = .teichman },
    .{ .name = "acset-superior-measurement", .trit = .plus, .voice = .shea },
    .{ .name = "acset-taxonomy", .trit = .ergodic, .voice = .pokey },
    .{ .name = "acsets-algebraic-databases", .trit = .plus, .voice = .lawson },
    .{ .name = "acsets-hatchery", .trit = .minus, .voice = .teichman },
    .{ .name = "acsets-relational-thinking", .trit = .plus, .voice = .shea },
    .{ .name = "agent-o-rama", .trit = .ergodic, .voice = .pokey },
    .{ .name = "astropy", .trit = .ergodic, .voice = .lawson },
    .{ .name = "attractor", .trit = .minus, .voice = .teichman },
    .{ .name = "browser-history-acset", .trit = .minus, .voice = .shea },
    .{ .name = "burpsuite-project-parser", .trit = .ergodic, .voice = .pokey },
    .{ .name = "calendar-acset", .trit = .minus, .voice = .lawson },
    .{ .name = "cargo-rust", .trit = .minus, .voice = .teichman },
    .{ .name = "chaotic-attractor", .trit = .minus, .voice = .shea },
    .{ .name = "cider-clojure", .trit = .minus, .voice = .pokey },
    .{ .name = "claude-in-chrome-troubleshooting", .trit = .minus, .voice = .lawson },
    .{ .name = "clifford-acset-bridge", .trit = .minus, .voice = .teichman },
    .{ .name = "clojure", .trit = .minus, .voice = .shea },
    .{ .name = "code-refactoring", .trit = .plus, .voice = .pokey },
    .{ .name = "codereview-roasted", .trit = .ergodic, .voice = .lawson },
    .{ .name = "competitive-ads-extractor", .trit = .minus, .voice = .teichman },
    .{ .name = "compositional-acset-comparison", .trit = .minus, .voice = .shea },
    .{ .name = "conformal-ga", .trit = .plus, .voice = .pokey },
    .{ .name = "dafny-formal-verification", .trit = .minus, .voice = .lawson },
    .{ .name = "dafny-zig", .trit = .minus, .voice = .teichman },
    .{ .name = "docs-acset", .trit = .plus, .voice = .shea },
    .{ .name = "drive-acset", .trit = .ergodic, .voice = .pokey },
    .{ .name = "effective-topos", .trit = .ergodic, .voice = .lawson },
    .{ .name = "exo-distributed", .trit = .minus, .voice = .teichman },
    .{ .name = "fasttime-mcp", .trit = .minus, .voice = .shea },
    .{ .name = "formal-verification-ai", .trit = .minus, .voice = .pokey },
    .{ .name = "frustration-eradication", .trit = .ergodic, .voice = .lawson },
    .{ .name = "goblins", .trit = .plus, .voice = .teichman },
    .{ .name = "guile-goblins-hoot", .trit = .minus, .voice = .shea },
    .{ .name = "hoot", .trit = .ergodic, .voice = .pokey },
    .{ .name = "infrastructure-cost-estimation", .trit = .plus, .voice = .lawson },
    .{ .name = "infrastructure-software-upgrades", .trit = .minus, .voice = .teichman },
    .{ .name = "jo-clojure", .trit = .plus, .voice = .shea },
    .{ .name = "joker-sims-parser", .trit = .minus, .voice = .pokey },
    .{ .name = "last-passage-percolation", .trit = .plus, .voice = .lawson },
    .{ .name = "lean-proof-walk", .trit = .minus, .voice = .teichman },
    .{ .name = "lispsyntax-acset", .trit = .minus, .voice = .shea },
    .{ .name = "markov-game-acset", .trit = .plus, .voice = .pokey },
    .{ .name = "mcp-fastpath", .trit = .plus, .voice = .lawson },
    .{ .name = "merkle-proof-validation", .trit = .minus, .voice = .teichman },
    .{ .name = "monoidal-category", .trit = .plus, .voice = .shea },
    .{ .name = "narya-proofs", .trit = .ergodic, .voice = .pokey },
    .{ .name = "naturality-factor", .trit = .plus, .voice = .lawson },
    .{ .name = "nix-acset-worlding", .trit = .plus, .voice = .teichman },
    .{ .name = "ocaml", .trit = .plus, .voice = .shea },
    .{ .name = "opam-ocaml", .trit = .ergodic, .voice = .pokey },
    .{ .name = "open-location-code-zig", .trit = .minus, .voice = .lawson },
    .{ .name = "openclaw-goblins-adapter", .trit = .plus, .voice = .teichman },
    .{ .name = "paperproof-validator", .trit = .plus, .voice = .shea },
};

test "voice profiles" {
    try std.testing.expect(SKILLS.len == 69);
    try std.testing.expect(std.mem.eql(u8, VoiceProfile.shea.description(), "Efficient, technical, Perl-optimized (Emily Shea)"));
}
