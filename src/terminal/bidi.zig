//! A pragmatic implementation of the Unicode Bidirectional Algorithm (UAX #9)
//! for terminal text.
//!
//! Scope: this implements the *implicit* portion of the algorithm — paragraph
//! level detection (P2/P3), the weak (W1–W7) and neutral (N1/N2) resolution
//! rules, implicit level assignment (I1/I2), and reordering (L1/L2). Given a
//! line of text in logical order it produces, for each element, an embedding
//! level and a visual-order permutation.
//!
//! It deliberately does NOT implement explicit embeddings / overrides /
//! isolates (rules X1–X8) or paired-bracket resolution (N0). Explicit and
//! isolate formatting characters are normalized to neutral (ON); terminal
//! output essentially never contains them. Paired brackets (N0) can be layered
//! on later without disturbing this structure.
//!
//! Reference: https://www.unicode.org/reports/tr9/
//! The reordering step (computeReorder) follows the Unicode reference
//! implementation (BidiReference.computeReordering).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const uucode = @import("uucode");
const unicode = @import("../unicode/main.zig");

/// Unicode Bidi_Class of a codepoint.
pub const Class = uucode.types.BidiClass;

/// The Unicode Bidi_Class of a codepoint, via Ghostty's property tables.
pub fn classOf(cp: u21) Class {
    return unicode.table.get(cp).bidi_class;
}

/// Whether a codepoint can participate in right-to-left text, i.e. whether a
/// row containing it needs the bidi algorithm run at all. This is a cheap
/// pre-filter so that pure left-to-right rows skip bidi entirely.
pub fn isRTLClass(cp: u21) bool {
    return switch (classOf(cp)) {
        .right_to_left,
        .right_to_left_arabic,
        .arabic_number,
        .right_to_left_embedding,
        .right_to_left_override,
        .right_to_left_isolate,
        => true,
        else => false,
    };
}

/// The requested base (paragraph) direction.
pub const BaseDirection = enum {
    /// Autodetect from the first strong character (P2/P3); default LTR.
    auto,
    ltr,
    rtl,
};

/// The result of running the algorithm over one line (paragraph) of text.
/// Owns two allocations; call `deinit` to free them.
pub const Result = struct {
    /// Resolved embedding level for each logical element. Even = LTR, odd = RTL.
    levels: []u8,

    /// Visual-to-logical mapping: `visual_to_logical[v]` is the logical index
    /// of the element displayed at visual position `v` (left to right).
    visual_to_logical: []u16,

    /// The paragraph embedding level (0 = LTR, 1 = RTL).
    base_level: u8,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.levels);
        alloc.free(self.visual_to_logical);
        self.* = undefined;
    }

    /// True if the element at logical index `i` resolved to right-to-left.
    pub fn isRTL(self: *const Result, i: usize) bool {
        return self.levels[i] & 1 == 1;
    }
};

/// Run the algorithm over a slice of codepoints in logical order.
pub fn reorder(
    alloc: Allocator,
    cps: []const u21,
    base: BaseDirection,
) Allocator.Error!Result {
    const classes = try alloc.alloc(Class, cps.len);
    defer alloc.free(classes);
    for (cps, 0..) |cp, i| classes[i] = unicode.table.get(cp).bidi_class;
    return reorderClasses(alloc, classes, base);
}

/// Run the algorithm over pre-resolved bidi classes in logical order. This is
/// the core entry point; `reorder` is a thin wrapper that resolves codepoints
/// to classes first. Exposed directly so tests can construct inputs by class.
pub fn reorderClasses(
    alloc: Allocator,
    orig: []const Class,
    base: BaseDirection,
) Allocator.Error!Result {
    const n = orig.len;

    const levels = try alloc.alloc(u8, n);
    errdefer alloc.free(levels);
    const visual = try alloc.alloc(u16, n);
    errdefer alloc.free(visual);

    // P2/P3: determine the paragraph embedding level.
    const base_level: u8 = switch (base) {
        .ltr => 0,
        .rtl => 1,
        .auto => firstStrongLevel(orig),
    };

    if (n == 0) return .{
        .levels = levels,
        .visual_to_logical = visual,
        .base_level = base_level,
    };

    const base_dir: Class = dirClass(base_level);

    // Working types. Normalize explicit/isolate formatting characters to
    // neutral (ON) since we don't implement the explicit rules.
    const types = try alloc.alloc(Class, n);
    defer alloc.free(types);
    for (orig, 0..) |c, i| types[i] = normalize(c);

    // With no explicit embeddings, every element sits at the paragraph level.
    @memset(levels, base_level);

    // The whole line is a single isolating run sequence, so its start-of-
    // sequence and end-of-sequence types both equal the base direction.
    const sos = base_dir;
    const eos = base_dir;

    resolveWeak(types, sos);
    resolveNeutral(types, sos, eos, base_dir);
    resolveImplicit(types, levels);
    resetLevels(orig, levels, base_level); // L1
    computeReorder(levels, visual); // L2

    return .{
        .levels = levels,
        .visual_to_logical = visual,
        .base_level = base_level,
    };
}

/// The direction "class" (L or R) implied by an embedding level's parity.
fn dirClass(level: u8) Class {
    return if (level & 1 == 1) .right_to_left else .left_to_right;
}

/// P2/P3: the base level implied by the first strong character (L → 0, R/AL →
/// 1), defaulting to LTR (0) if there is no strong character.
fn firstStrongLevel(orig: []const Class) u8 {
    for (orig) |c| switch (c) {
        .left_to_right => return 0,
        .right_to_left, .right_to_left_arabic => return 1,
        else => {},
    };
    return 0;
}

/// Map explicit/isolate/boundary formatting classes to neutral (ON). Everything
/// else is returned unchanged.
fn normalize(c: Class) Class {
    return switch (c) {
        .left_to_right_embedding,
        .right_to_left_embedding,
        .left_to_right_override,
        .right_to_left_override,
        .pop_directional_format,
        .boundary_neutral,
        .left_to_right_isolate,
        .right_to_left_isolate,
        .first_strong_isolate,
        .pop_directional_isolate,
        => .other_neutrals,
        else => c,
    };
}

/// W1–W7: resolve weak types (marks, numbers, separators). Operates in place.
fn resolveWeak(types: []Class, sos: Class) void {
    const n = types.len;

    // W1: NSM takes the type of the previous character (or sos at the start).
    {
        var prev: Class = sos;
        for (types, 0..) |c, i| {
            if (c == .nonspacing_mark) types[i] = prev;
            prev = types[i];
        }
    }

    // W2: EN becomes AN when the last strong type seen is Arabic (AL).
    {
        var last_strong: Class = sos;
        for (types, 0..) |c, i| switch (c) {
            .left_to_right, .right_to_left, .right_to_left_arabic => last_strong = c,
            .european_number => if (last_strong == .right_to_left_arabic) {
                types[i] = .arabic_number;
            },
            else => {},
        };
    }

    // W3: AL becomes R.
    for (types) |*c| if (c.* == .right_to_left_arabic) {
        c.* = .right_to_left;
    };

    // W4: a single ES between two EN becomes EN; a single CS between two
    // numbers of the same kind becomes that number kind.
    {
        var i: usize = 1;
        while (i + 1 < n) : (i += 1) {
            const l = types[i - 1];
            const r = types[i + 1];
            switch (types[i]) {
                .european_number_separator => if (l == .european_number and
                    r == .european_number)
                {
                    types[i] = .european_number;
                },
                .common_number_separator => {
                    if (l == .european_number and r == .european_number) {
                        types[i] = .european_number;
                    } else if (l == .arabic_number and r == .arabic_number) {
                        types[i] = .arabic_number;
                    }
                },
                else => {},
            }
        }
    }

    // W5: a run of ET adjacent to EN becomes EN.
    {
        var i: usize = 0;
        while (i < n) {
            if (types[i] == .european_number_terminator) {
                var j = i;
                while (j < n and types[j] == .european_number_terminator) j += 1;
                const before_en = i > 0 and types[i - 1] == .european_number;
                const after_en = j < n and types[j] == .european_number;
                if (before_en or after_en) {
                    var k = i;
                    while (k < j) : (k += 1) types[k] = .european_number;
                }
                i = j;
            } else i += 1;
        }
    }

    // W6: any remaining separators/terminators become ON.
    for (types) |*c| switch (c.*) {
        .european_number_separator,
        .european_number_terminator,
        .common_number_separator,
        => c.* = .other_neutrals,
        else => {},
    };

    // W7: EN becomes L when the last strong type seen is L.
    {
        var last_strong: Class = sos;
        for (types, 0..) |c, i| switch (c) {
            .left_to_right, .right_to_left => last_strong = c,
            .european_number => if (last_strong == .left_to_right) {
                types[i] = .left_to_right;
            },
            else => {},
        };
    }
}

/// N1/N2: resolve neutral and isolate-formatting runs. A run of neutrals
/// bounded on both sides by the same direction takes that direction (N1);
/// otherwise it takes the embedding direction (N2). Operates in place.
fn resolveNeutral(types: []Class, sos: Class, eos: Class, base_dir: Class) void {
    const n = types.len;
    var i: usize = 0;
    while (i < n) {
        if (!isNI(types[i])) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and isNI(types[j])) j += 1;
        const left = if (i == 0) sos else strongDir(types[i - 1]);
        const right = if (j == n) eos else strongDir(types[j]);
        const resolved: Class = if (left == right) left else base_dir;
        var k = i;
        while (k < j) : (k += 1) types[k] = resolved;
        i = j;
    }
}

/// Neutral-or-isolate types for the N rules.
fn isNI(c: Class) bool {
    return switch (c) {
        .whitespace,
        .other_neutrals,
        .paragraph_separator,
        .segment_separator,
        => true,
        else => false,
    };
}

/// The strong direction a non-neutral type contributes to N1. Numbers (EN/AN)
/// count as R.
fn strongDir(c: Class) Class {
    return switch (c) {
        .left_to_right => .left_to_right,
        .right_to_left, .european_number, .arabic_number => .right_to_left,
        else => .left_to_right,
    };
}

/// I1/I2: raise embedding levels based on resolved type and level parity.
fn resolveImplicit(types: []const Class, levels: []u8) void {
    for (types, 0..) |c, i| {
        const lvl = levels[i];
        if (lvl & 1 == 0) {
            // Even (LTR) level.
            switch (c) {
                .right_to_left => levels[i] = lvl + 1,
                .arabic_number, .european_number => levels[i] = lvl + 2,
                else => {},
            }
        } else {
            // Odd (RTL) level.
            switch (c) {
                .left_to_right, .european_number, .arabic_number => levels[i] = lvl + 1,
                else => {},
            }
        }
    }
}

/// L1: reset the level of segment/paragraph separators, and of any run of
/// whitespace / isolate-formatting preceding such a separator or ending the
/// line, to the paragraph level. Uses the ORIGINAL types, per the spec.
fn resetLevels(orig: []const Class, levels: []u8, base_level: u8) void {
    const n = orig.len;
    for (orig, 0..) |c, i| switch (c) {
        .segment_separator, .paragraph_separator => {
            levels[i] = base_level;
            var j = i;
            while (j > 0 and isResetWS(orig[j - 1])) : (j -= 1) {
                levels[j - 1] = base_level;
            }
        },
        else => {},
    };

    var j = n;
    while (j > 0 and isResetWS(orig[j - 1])) : (j -= 1) {
        levels[j - 1] = base_level;
    }
}

/// Whitespace / isolate-formatting / removed-formatting for L1 resets.
fn isResetWS(c: Class) bool {
    return switch (c) {
        .whitespace,
        .left_to_right_isolate,
        .right_to_left_isolate,
        .first_strong_isolate,
        .pop_directional_isolate,
        .left_to_right_embedding,
        .right_to_left_embedding,
        .left_to_right_override,
        .right_to_left_override,
        .pop_directional_format,
        .boundary_neutral,
        => true,
        else => false,
    };
}

/// L2: produce the visual-to-logical order from resolved levels. From the
/// highest level down to the lowest odd level, reverse every contiguous run of
/// elements at that level or higher.
fn computeReorder(levels: []const u8, visual: []u16) void {
    const n = levels.len;
    for (visual, 0..) |*v, i| v.* = @intCast(i);

    var highest: u8 = 0;
    var lowest_odd: u8 = std.math.maxInt(u8);
    for (levels) |lvl| {
        if (lvl > highest) highest = lvl;
        if (lvl & 1 == 1 and lvl < lowest_odd) lowest_odd = lvl;
    }
    if (lowest_odd > highest) return; // no odd levels: already in logical order

    var level = highest;
    while (level >= lowest_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < n) {
            if (levels[i] >= level) {
                var j = i;
                while (j < n and levels[j] >= level) j += 1;
                std.mem.reverse(u16, visual[i..j]);
                i = j;
            } else i += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bidi: empty" {
    var res = try reorder(testing.allocator, &.{}, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), res.visual_to_logical.len);
}

test "bidi: pure LTR is identity" {
    const cps = [_]u21{ 'a', 'b', 'c' };
    var res = try reorder(testing.allocator, &cps, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), res.base_level);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, res.visual_to_logical);
}

test "bidi: pure RTL (Hebrew) is reversed" {
    const cps = [_]u21{ 0x05D0, 0x05D1, 0x05D2 }; // א ב ג
    var res = try reorder(testing.allocator, &cps, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), res.base_level);
    try testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, res.visual_to_logical);
}

test "bidi: LTR base with an embedded RTL run" {
    // logical: a b א ב
    const cps = [_]u21{ 'a', 'b', 0x05D0, 0x05D1 };
    var res = try reorder(testing.allocator, &cps, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), res.base_level);
    // visual: a b ב א  →  logical indices 0 1 3 2
    try testing.expectEqualSlices(u16, &.{ 0, 1, 3, 2 }, res.visual_to_logical);
}

test "bidi: RTL base with an embedded LTR run" {
    // logical: א ב a b  (first strong is Hebrew → base RTL)
    const cps = [_]u21{ 0x05D0, 0x05D1, 'a', 'b' };
    var res = try reorder(testing.allocator, &cps, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), res.base_level);
    // visual (L→R): a b ב א  →  logical indices 2 3 1 0
    try testing.expectEqualSlices(u16, &.{ 2, 3, 1, 0 }, res.visual_to_logical);
}

test "bidi: multi-digit number keeps internal LTR order in RTL context" {
    // logical: ب 1 2   (Arabic letter then European digits)
    const cps = [_]u21{ 0x0628, '1', '2' };
    var res = try reorder(testing.allocator, &cps, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), res.base_level);
    // The number reads "12" (not reversed) and sits to the LEFT of the letter:
    // visual (L→R): 1 2 ب  →  logical indices 1 2 0
    try testing.expectEqualSlices(u16, &.{ 1, 2, 0 }, res.visual_to_logical);
}

test "bidi: whitespace between two RTL words stays RTL" {
    // logical: א (space) ב
    const cps = [_]u21{ 0x05D0, ' ', 0x05D1 };
    var res = try reorder(testing.allocator, &cps, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, res.visual_to_logical);
}

test "bidi: trailing whitespace resets to base level under forced LTR" {
    // logical: א ב (space), base forced LTR
    const cps = [_]u21{ 0x05D0, 0x05D1, ' ' };
    var res = try reorder(testing.allocator, &cps, .ltr);
    defer res.deinit(testing.allocator);
    // visual: ב א (space)  →  logical indices 1 0 2
    try testing.expectEqualSlices(u16, &.{ 1, 0, 2 }, res.visual_to_logical);
    try testing.expectEqual(@as(u8, 0), res.levels[2]); // space reset to base
}

test "bidi: class-based input (no unicode table)" {
    const L: Class = .left_to_right;
    const R: Class = .right_to_left;
    const classes = [_]Class{ L, L, R, R };
    var res = try reorderClasses(testing.allocator, &classes, .auto);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), res.base_level);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 3, 2 }, res.visual_to_logical);
}
