# UR-ASG (`liburasg`)

Universal Relational Abstract Syntax Graph and embedded Base Native Compiler (`urc`) implemented in freestanding **Zig 0.17.0** with a C99 ABI and WebAssembly target.

Unifies compiler AST/SSA graphs, relational EAV tables, and bi-temporal knowledge graphs into a single 16-byte homoiconic primitive (`UrCell`).

---

## Features

- **16-Byte Cell Density**: Strictly `@sizeOf(UrCell) == 16` and `@alignOf(UrCell) == 16`, packing 4 cells into every 64-byte CPU cache line.
- **4 KB Page-Table CoW Arena**: 256 cells per page, O(pages) copy-on-write snapshots, and per-page epoch tracking.
- **Cycle-Safe Merkle Hashing**: Incremental `XXH3-64` bottom-up hashing with De Bruijn cycle depth normalization (`#0#`, `#1#`).
- **Dual Sorted EAV Slabs**: Cache-friendly `SPO` (Subject-Predicate-Object) and `POS` (Predicate-Object-Subject) indexes supporting bi-temporal time slices (`valid_from`, `invalidated_at`).
- **Pluggable Projectional Lenses**: Surface-syntax-agnostic `UrLensVTable` with canonical cyclic S-expressions (`#1= ... #1#`, `SexprLens`), human-friendly infix/brace `SweetLens` with `SourceSpan` tracking, and recursive structural `computeTypeDiff` (`.exact`, `.coercible`, `.needs_membrane`).
- **Zero-Copy Container**: `.urasg` binary format (`URASGv01`) with 64-byte aligned header and payload `XXH3-64` integrity checksum.
- **Embedded Compiler (`urc`)**:
  - **Tier 0**: In-arena evaluator supporting `int_lit`, `float_lit`, `fixed_q16_16`, `uncertain_f32` arithmetic, positional `argN` bindings, runtime `UseAfterFreeTrap`/`DoubleFreeTrap` enforcement, and Live Sample Oracle fallback.
  - **Tier 1**: Recursive bytecode lowering (locals, arithmetic, `if_branch` jump backpatching, oracle fallback), PC-driven 64-bit register VM, and pure-Zig `X86Emitter` machine code generation.
  - **Tier 2**: Recursive freestanding Zig 0.17.0 and C99 AOT source emission mapped from `UrTypeTable`, plus `PINNED_BUILTIN` Merkle binary promoter.
  - **Composable Graph Passes**: Compile-time constant folding, symbolic differentiation (`diffCell`) and algebraic simplification (`simplifyCell`) attached as `.grad_adjoint` cells, and `.hazel_membrane` wrapping via `UrGraph.spliceHole`.
- **Unified 6-Mode Memory Engine**: Builtin ownership & alias escape analysis (`MEM_VLANG_AUTOFREE` + `MEM_LOBSTER_RC`, `MEM_FRAME_ARENA`, `MEM_BEEF_GUARDED`, `MEM_RAW_MANUAL`, `MEM_COW_GC`) with live `scope_free` / `rc_adjust` / `gen_guard_check` cell splicing into `unit_def` scopes.
- **Host Domain Opcode Plugins**: Opcodes `0x80..0xFF` wired across all four `UrCompilerExtension` hooks: `typecheck_domain_cell`, `eval_domain_cell`, `run_custom_rewrite_pass`, and `emit_domain_codegen`.

---

## Building & Testing

Requires [Zig 0.17.0](https://ziglang.org/).

```bash
# Run unit and blueprint test suite
zig build test --summary all

# Build native static library (urasg.lib), shared DLL (urasg_shared.dll), and C header
zig build --summary all

# Build freestanding WebAssembly binary (zig-out/bin/liburasg.wasm)
zig build wasm --summary all
```

Outputs are installed into `zig-out/`:
- `zig-out/include/urasg.h`
- `zig-out/lib/urasg.lib`
- `zig-out/bin/urasg_shared.dll`
- `zig-out/bin/liburasg.wasm`

---

## Quickstart

### Zig API

```zig
const std = @import("std");
const urasg = @import("urasg");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize graph
    var graph = try urasg.UrGraph.create(allocator);
    defer graph.destroy();

    // 2. Parse cyclic S-expression
    const src = "#1=(unit apply_thruster (call validate sensor) #1#)";
    const root = try urasg.sexpr_lens.parseSexpr(graph, src);

    // 3. Compute deterministic XXH3-64 Merkle hash
    const hash = try graph.merkleHash(root);
    std.debug.print("Root Merkle Hash: 0x{X:0>16}\n", .{hash});

    // 4. Commit and query relational EAV facts
    const sym_hp = try graph.internSym("hp");
    const val_hp = try graph.allocCell(.{ .kind = .int_lit, .payload = .{ .imm_i64 = 100 } });
    try graph.eav_index.commitEav(42, sym_hp, val_hp, urasg.NULL_CELL);
    const read_hp = graph.eav_index.querySpo(42, sym_hp);
    _ = read_hp;
}
```

### SweetLens Projectional Syntax & Compiler Pipeline

```zig
const std = @import("std");
const urasg = @import("urasg");

pub fn runSweetExample(allocator: std.mem.Allocator) !i64 {
    var graph = try urasg.UrGraph.create(allocator);
    defer graph.destroy();

    const sweet_src =
        \\fn step(arg0) {
        \\  let doubled = (arg0 * 2);
        \\  if (doubled > 10) {
        \\    return (doubled + 5);
        \\  } else {
        \\    return (doubled - 1);
        \\  }
        \\}
    ;

    const unit_idx = try urasg.sweet_lens.SweetLens.parseIntoGraph(graph, urasg.NULL_CELL, sweet_src);

    var comp = try urasg.UrCompiler.create(graph, urasg.compiler.core.DEFAULT_FEATURES);
    defer comp.destroy();

    try urasg.compiler.passes.runAllPasses(comp, unit_idx);

    var t0 = urasg.compiler.tier0.Tier0Evaluator.init(comp);
    const arg = try graph.allocCell(.{ .kind = .int_lit, .payload = .{ .imm_i64 = 7 } });
    const out = try t0.evalUnit(unit_idx, &.{arg});
    return graph.getCell(out).payload.imm_i64; // 19
}
```

### C99 / C++ FFI

```c
#include "urasg.h"
#include <stdio.h>

int main(void) {
    UrGraph* g = urasg_create(1024);

    UrCell num = {
        .kind = UR_OP_INT_LIT,
        .flags = 0,
        .type_id = 3,
        .head_idx = 0,
        .payload = 42
    };
    UrCellIdx c = urasg_alloc_cell(g, num);
    uint64_t hash = urasg_merkle_hash(g, c);
    printf("Cell index: %u, Merkle hash: 0x%llx\n", c, (unsigned long long)hash);

    urasg_destroy(g);
    return 0;
}
```

---

## Repository Layout

```
.
├── build.zig                   # Zig 0.17.0 build script (C lib, shared lib, Wasm, test runner)
├── build.zig.zon               # Package manifest
├── include/
│   └── urasg.h                 # C99 / C++ public header interface
└── src/
    ├── lib.zig                 # Main Zig module & C ABI exports
    ├── cell.zig                # 16-byte UrCell, opcodes, Q16.16, UncertainF32 & type table
    ├── graph_store.zig         # 4KB CoW page directory arena & Pantograph hole splice
    ├── merkle.zig              # Cycle-safe De Bruijn XXH3-64 Merkle hasher
    ├── eav_index.zig           # Dual sorted SPO / POS relational index slabs
    ├── lens_api.zig            # UrLensVTable projectional lens interface
    ├── sexpr_lens.zig          # Canonical cyclic S-expression codec (#1= ... #1#) & structural TypeDiff
    ├── sweet_lens.zig          # Human-friendly infix/brace SweetLens with SourceSpan tracking
    ├── binary_codec.zig        # Zero-copy .urasg binary container format (URASGv01)
    └── compiler/               # Embedded Base Native Compiler (urc)
        ├── urc_core.zig        # Compiler state, UrFeatureFlags & time-dilation profiler
        ├── urc_mem.zig         # 6-mode escape analysis & unit instrumentation splicing
        ├── tier0_eval.zig      # In-arena evaluator, memory trap enforcement & Live Sample Oracle
        ├── tier1_jit.zig       # Recursive bytecode VM & pure-Zig X86Emitter machine codegen
        ├── tier2_aot.zig       # Recursive Zig/C99 AOT emitter & PINNED_BUILTIN promoter
        ├── passes.zig          # Constant folding, symbolic autodiff, membranes & extension hooks
        └── ext_api.zig         # Host domain opcode extension hooks (0x80..0xFF) & UrEvalEnv
```

---

## License

MIT / Apache-2.0.

