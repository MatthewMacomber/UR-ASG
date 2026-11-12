#ifndef URASG_H
#define URASG_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_MSC_VER)
#define URASG_ALIGN16 __declspec(align(16))
#elif defined(__GNUC__) || defined(__clang__)
#define URASG_ALIGN16 __attribute__((aligned(16)))
#else
#define URASG_ALIGN16
#endif

typedef uint32_t UrCellIdx;
typedef uint16_t UrTypeId;
typedef uint32_t UrSymId;
typedef uint32_t UrEntityId;

#define URASG_NULL_CELL 0U

/* UrKind Opcode Ranges */
/* 0x00..0x1F: Atoms & Literals */
#define UR_OP_NIL_CELL         0x00
#define UR_OP_BOOL_LIT         0x01
#define UR_OP_INT_LIT          0x02
#define UR_OP_FLOAT_LIT        0x03
#define UR_OP_FIXED_Q16_16     0x04
#define UR_OP_UNCERTAIN_F32    0x05
#define UR_OP_SYM_ATOM         0x06
#define UR_OP_BYTES_BLOB       0x07

/* 0x20..0x3F: Homoiconic Graph, Control & SSA Nodes */
#define UR_OP_UNIT_DEF         0x20
#define UR_OP_CALL_NODE        0x21
#define UR_OP_LET_BIND         0x22
#define UR_OP_IF_BRANCH        0x23
#define UR_OP_MATCH_SWITCH     0x24
#define UR_OP_LOOP_REPEAT      0x25
#define UR_OP_FIBER_YIELD      0x26
#define UR_OP_RETURN_OK        0x27
#define UR_OP_TRY_OR_ERR       0x28
#define UR_OP_SSA_PHI          0x29
#define UR_OP_SIMD_KERNEL      0x2A
#define UR_OP_CYCLIC_BACKREF   0x2B
#define UR_OP_SCOPE_FREE       0x2C
#define UR_OP_RC_ADJUST        0x2D
#define UR_OP_GEN_GUARD_CHECK  0x2E
#define UR_OP_LIST_NODE        0x2F
#define UR_OP_GRAD_ADJOINT     0x30
#define UR_OP_ARENA_PROMOTE    0x31
#define UR_OP_BORROW_REF       0x32
#define UR_OP_MOVE_TRANSFER    0x33

/* 0x40..0x5F: Relational EAV & Dataflow Nodes */
#define UR_OP_EAV_TUPLE        0x40
#define UR_OP_QUERY_SEARCH     0x41
#define UR_OP_QUERY_BIND       0x42
#define UR_OP_QUERY_COMMIT     0x43
#define UR_OP_MECH_TABLE       0x44
#define UR_OP_MECH_FSM_TRANS   0x45
#define UR_OP_SHARD_PORT       0x46
#define UR_OP_SHARD_WIRE       0x47
#define UR_OP_BITEMPORAL_EDGE  0x48

/* 0x60..0x7F: Live Contracts, Typed Holes & Hardware Capabilities */
#define UR_OP_NEEDS_STUB       0x60
#define UR_OP_SAMPLE_IO_ROW    0x61
#define UR_OP_HOIST_STEP       0x62
#define UR_OP_SHOWBOAT_PROOF   0x63
#define UR_OP_HAZEL_HOLE       0x64
#define UR_OP_HAZEL_MEMBRANE   0x65
#define UR_OP_MMIO_CAPABILITY  0x66
#define UR_OP_IRQ_CAPABILITY   0x67

/* 0x80..0xFF: Host Domain Extension Opcodes */
#define UR_OP_DOMAIN_START     0x80
#define UR_OP_DOMAIN_END       0xFF

/* UrFlags Bitfield Masks */
#define UR_FLAG_DIRTY          (1U << 0)
#define UR_FLAG_CYCLIC_ANCHOR  (1U << 1)
#define UR_FLAG_CYCLIC_REF     (1U << 2)
#define UR_FLAG_VERIFIED       (1U << 3)
#define UR_FLAG_PINNED_BUILTIN (1U << 4)
#define UR_FLAG_MEM_MASK       (7U << 5)

/* UrMemStrategy (bits 5..7 of flags) */
typedef enum UrMemStrategy {
    UR_MEM_VLANG_AUTOFREE = 0,
    UR_MEM_LOBSTER_RC     = 1,
    UR_MEM_BEEF_GUARDED   = 2,
    UR_MEM_RAW_MANUAL     = 3,
    UR_MEM_FRAME_ARENA    = 4,
    UR_MEM_COW_GC         = 5,
} UrMemStrategy;

/* UrFeatureFlags Bitmasks */
#define UR_FEAT_SAMPLE_ORACLE      (1ULL << 0)
#define UR_FEAT_HAZEL_MEMBRANES    (1ULL << 1)
#define UR_FEAT_LOBSTER_RC         (1ULL << 2)
#define UR_FEAT_AUTOFREE_ARENA     (1ULL << 3)
#define UR_FEAT_BEEF_MIXED_OPT     (1ULL << 4)
#define UR_FEAT_RELATIONAL_SIMD    (1ULL << 5)
#define UR_FEAT_MMIO_CAPABILITIES  (1ULL << 6)
#define UR_FEAT_UNCERTAIN_AUTODIFF (1ULL << 7)
#define UR_FEAT_DIAG_REPORT_ESCAPES (1ULL << 8)

/* 16-Byte UrCell Definition */
typedef URASG_ALIGN16 struct UrCell {
    uint8_t  kind;
    uint8_t  flags;
    uint16_t type_id;
    uint32_t head_idx;
    uint64_t payload;
} UrCell;

/* Opaque Handles */
typedef struct UrGraph UrGraph;
typedef struct UrCompiler UrCompiler;

/* Lifecycle & CoW Snapshots */
UrGraph*  urasg_create(size_t initial_cells);
void      urasg_destroy(UrGraph* g);
UrGraph*  urasg_fork_cow(const UrGraph* parent);
uint64_t  urasg_merkle_hash(UrGraph* g, UrCellIdx root);

/* Cell Allocation, Retrieval & Structure Splice */
UrCellIdx urasg_alloc_cell(UrGraph* g, UrCell cell);
UrCell    urasg_get_cell(const UrGraph* g, UrCellIdx idx);
void      urasg_set_cell(UrGraph* g, UrCellIdx idx, UrCell cell);
UrCellIdx urasg_splice_hole(UrGraph* g, UrCellIdx hole_idx, UrCellIdx plug_idx);
UrSymId   urasg_intern_sym(UrGraph* g, const char* name, size_t len);

/* Relational EAV & Execution */
void      urasg_commit_eav(UrGraph* g, uint32_t entity, uint32_t attr_sym, UrCellIdx val);
UrCellIdx urasg_query_eav(const UrGraph* g, uint32_t entity, uint32_t attr_sym);
UrCellIdx urasg_eval_unit(UrGraph* g, UrCellIdx unit_idx, const UrCellIdx* args, size_t arg_count);

/* Base Native Compiler (urc) & Plugins */
UrCompiler* urc_create_compiler(UrGraph* g, uint64_t feature_flags);
void        urc_destroy_compiler(UrCompiler* c);
int         urc_register_extension(UrCompiler* c, const char* ext_name, uint8_t start_op, uint8_t end_op);
int         urc_compile_unit(UrCompiler* c, UrCellIdx unit_idx, int target_tier);
int         urc_promote_builtin(UrCompiler* c, UrCellIdx unit_idx);
double      urc_profile_dilation(const UrCompiler* c, UrCellIdx unit_idx);

/* Codec & Serialization */
size_t    urasg_print_sexpr(const UrGraph* g, UrCellIdx root, char* buf, size_t buf_cap);
UrCellIdx urasg_parse_sexpr(UrGraph* g, const char* sexpr_utf8, size_t len);
int       urasg_save_binary(const UrGraph* g, const char* filepath);
UrGraph*  urasg_load_binary(const char* filepath);

#ifdef __cplusplus
}
#endif

#endif /* URASG_H */

