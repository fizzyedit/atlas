const std = @import("std");
const fizzy = @import("fizzy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const plugin = fizzy.plugin.create(b, .{ .target = target, .optimize = optimize });

    // Extras attach to `plugin.module` — the author module — and never to `plugin.lib
    // .root_module`, which is fizzy's *generated* dylib root (std_options + exportEntry).
    if (b.lazyDependency("icons", .{ .target = target, .optimize = optimize })) |dep| {
        plugin.module.addImport("icons", dep.module("icons"));
    }

    const batch2d_dep = b.dependency("batch2d", .{ .target = target, .optimize = optimize });

    // FTS5 is compiled in now, before anything uses it: turning it on later would mean
    // re-pinning and re-verifying the C build for all six release targets, and full-text search
    // over note bodies is the obvious way to make "unlinked mentions" cheap.
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
        .fts5 = true,
    });
    plugin.module.addImport("sqlite", sqlite.module("sqlite"));

    // batch2d must share the consumer's dvui module object (plugin proxy vs sdl3 harness).
    const fizzy_dep = b.dependency("fizzy", .{ .target = target, .optimize = optimize });
    const batch2d_mod = b.createModule(.{
        .root_source_file = batch2d_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    batch2d_mod.addImport("dvui", fizzy_dep.module("dvui"));
    plugin.module.addImport("batch2d", batch2d_mod);

    fizzy.plugin.install(b, plugin.lib, .{});

    // Neutral per-note content graph shape (`ItemKind`/`Item`/`ItemEdge`/`ContentGraph`), shared
    // by the DB-backed indexer (`src/index/query.zig`) and the synthetic generator
    // (`src/ui/vault_synth.zig`). Registered as its own module — rather than left to relative
    // `../index/content_graph.zig` imports — because `vault_synth.zig` also gets its own
    // standalone unit-test module below (rooted at `src/ui/`, which Zig's module boundary won't
    // let a relative import reach outside of); a named import works identically in both the full
    // plugin build and that standalone test.
    const content_graph_mod = b.createModule(.{
        .root_source_file = b.path("src/index/content_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    plugin.module.addImport("content_graph", content_graph_mod);

    // Pure-logic tests: link resolution and the note scanner take plain values in and give
    // records out, with no filesystem, no database, and no dvui, which is the whole reason
    // they're separate files from the plumbing that uses them.
    const test_step = b.step("test", "Run atlas's unit tests");
    inline for (.{
        .{ "atlas-resolve-tests", "src/index/resolve.zig" },
        .{ "atlas-schema-tests", "src/index/schema.zig" },
        .{ "atlas-relpath-tests", "src/index/relpath.zig" },
        .{ "atlas-wikilink-context-tests", "src/service/wikilink_context.zig" },
        .{ "atlas-proximity-tests", "src/ui/proximity.zig" },
        .{ "atlas-cache-dir-tests", "src/index/cache_dir.zig" },
        // `--stats` bench mode: degree/component/hub-fragility/coarsening-ladder/folder-
        // correlation math over plain `Edge` pairs — no dvui, no filesystem.
        .{ "atlas-bench-stats-tests", "src/bench_stats.zig" },
        // The single-hierarchy replacement for ladder/pyramid/quadtree: plain graph math over
        // `Edge` pairs, no dvui and no vault types, so it can eventually lift into its own package.
        .{ "atlas-fold-tests", "src/ui/fold.zig" },
        // Positions derived from the fold ladder: children inside the parent's disc, one rule,
        // no force solve. Plain `Vec2`, so it stays headless too.
        .{ "atlas-containment-tests", "src/ui/containment.zig" },
        // The living set: budgeted, view-culled, level-uniform select over the fold ladder,
        // emitting screen-space marks. Replaces quadlod + quad_agents + lod.
        .{ "atlas-world-tests", "src/ui/world.zig" },
    }) |entry| {
        const t = b.addTest(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(entry[1]),
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Scanner uses the SDK wikilink tokenizer so it and the markdown renderer can't drift.
    const scanner_tests = b.addTest(.{
        .name = "atlas-scanner-tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/index/Scanner.zig"),
        }),
    });
    scanner_tests.root_module.addImport("fizzy_sdk", fizzy_dep.module("fizzy_sdk"));
    test_step.dependOn(&b.addRunArtifact(scanner_tests).step);

    // The schema against real sqlite — that the DDL executes, that a reopen is a no-op, and
    // that a wrong version is discarded rather than half-used. Structural checks in
    // `schema.zig` can't answer any of those; only sqlite can.
    const db_tests = b.addTest(.{
        .name = "atlas-db-tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/index/db_test.zig"),
        }),
    });
    db_tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    // query.zig (reached via db_test.zig's relative import) needs `content_graph` by name — see
    // the comment on that import in query.zig. A distinct Module object from `content_graph_mod`
    // above and from the vault-synth test's own copy: sharing one Module across independent
    // artifacts' import tables is what triggered the double-attachment error in the first place.
    const cg_for_db_test = b.createModule(.{
        .root_source_file = b.path("src/index/content_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_tests.root_module.addImport("content_graph", cg_for_db_test);
    test_step.dependOn(&b.addRunArtifact(db_tests).step);

    // The incremental write path end to end: scan a buffer, write the rows, relink. Everything
    // the graph draws comes out of `links`, and "does removing a wikilink remove the row" is a
    // question only the real Indexer against real sqlite can answer.
    const indexer_tests = b.addTest(.{
        .name = "atlas-indexer-tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/index/Indexer.zig"),
        }),
    });
    indexer_tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    indexer_tests.root_module.addImport("dvui", fizzy_dep.module("dvui"));
    indexer_tests.root_module.addImport("fizzy_sdk", fizzy_dep.module("fizzy_sdk"));
    test_step.dependOn(&b.addRunArtifact(indexer_tests).step);

    // Graph camera + radial layout: pure math over `dvui.Point`/`Rect`, no window needed.
    // The round-trip / angle-stability tests are the ones that catch zoom-around-cursor
    // bugs and the "adding a note spins the whole graph" failure mode.
    inline for (.{
        .{ "atlas-camera-tests", "src/ui/camera.zig" },
        .{ "atlas-layout-full-tests", "src/ui/layout_full.zig" },
        // Point-region quadtree spine + thin present layer (Stable v1 organic LOD).
        .{ "atlas-galaxy-tests", "src/ui/galaxy.zig" },
        .{ "atlas-vault-synth-tests", "src/ui/vault_synth.zig" },
        .{ "atlas-hex-tests", "src/ui/hex.zig" },
        // Only `dotgrid`'s LOD math and buffer sizing — the draw path needs a live window.
        .{ "atlas-dotgrid-tests", "src/ui/dotgrid.zig" },
        // Label slot geometry and the greedy placer — the "no two names overlap" guarantee
        // the graph's draw pass leans on.
        .{ "atlas-labels-tests", "src/ui/labels.zig" },
        // How much of the web a focus flight frames — the percentile that keeps one far-flung
        // link from undoing the zoom.
        .{ "atlas-focus-tests", "src/ui/focus.zig" },
        // Where a note's own cloud sits inside the overview's — the power-of-two nesting that
        // lets the interior be a finer level of the same hex lattice rather than a second one.
        .{ "atlas-interior-tests", "src/ui/interior.zig" },
    }) |entry| {
        const t = b.addTest(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(entry[1]),
            }),
        });
        t.root_module.addImport("dvui", fizzy_dep.module("dvui"));
        if (std.mem.eql(u8, entry[0], "atlas-galaxy-tests")) {
            t.root_module.addImport("batch2d", batch2d_mod);
        }
        if (std.mem.eql(u8, entry[0], "atlas-vault-synth-tests")) {
            // A distinct module object from `content_graph_mod` above, deliberately: this test
            // and `plugin.lib` are separate artifacts, but sharing one Module object between two
            // artifacts' import tables made Zig's module-uniqueness check misattribute
            // `vault_synth.zig` itself as `content_graph_mod`'s root (a confusing, wrong error).
            // Two independently-created modules with the same root file avoids it.
            const cg_for_test = b.createModule(.{
                .root_source_file = b.path("src/index/content_graph.zig"),
                .target = target,
                .optimize = optimize,
            });
            t.root_module.addImport("content_graph", cg_for_test);
        }
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Headless timing harness over a real folder of markdown — see `src/bench_main.zig`. Kept out
    // of the default step: it needs a vault path and is only useful under ReleaseFast.
    // `--world` sweeps the layout/LOD path across a zoom range; `--stats` reports graph structure.
    {
        const bench = b.addExecutable(.{
            .name = "atlas-bench",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/bench_main.zig"),
            }),
        });
        // The sources come in by *path*, not as separate modules: `Scanner.zig` relative-imports
        // `resolve.zig`, and a file may belong to only one module — declaring both as modules is
        // an immediate "file exists in modules 'resolve' and 'Scanner'".
        bench.root_module.addImport("dvui", fizzy_dep.module("dvui"));
        bench.root_module.addImport("fizzy_sdk", fizzy_dep.module("fizzy_sdk"));
        const run_bench = b.addRunArtifact(bench);
        if (b.args) |a| run_bench.addArgs(a);
        b.step("bench", "Scan/resolve timings, --stats structure, --world LOD sweep").dependOn(&run_bench.step);
    }

    // markworld demos (rings / coalesce) — package owns sources + zflecs; brain thin-wraps.
    {
        const dvui_sdl3_dep = fizzy_dep.builder.dependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = .sdl3,
            .accesskit = .off,
        });
        const gpu_dvui = dvui_sdl3_dep.module("dvui_sdl3");
        // batch2d must share the consumer's dvui module object — here the sdl3 one, not the
        // plugin proxy the panel builds against.
        const batch2d_gpu = b.createModule(.{
            .root_source_file = batch2d_dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        batch2d_gpu.addImport("dvui", gpu_dvui);


        // markworld demos (rings / coalesce) — package owns sources + zflecs; brain thin-wraps.
        const markworld_dep = b.dependency("markworld", .{ .target = target, .optimize = optimize });
        const zflecs_dep = markworld_dep.builder.dependency("zflecs", .{
            .optimize = optimize,
            .debug_mode = .depends_on_build,
        });
        const markworld_gpu = b.createModule(.{
            .root_source_file = markworld_dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        markworld_gpu.addImport("dvui", gpu_dvui);
        markworld_gpu.addImport("batch2d", batch2d_gpu);
        markworld_gpu.addImport("zflecs", zflecs_dep.module("root"));
        markworld_gpu.linkLibrary(zflecs_dep.artifact("flecs"));

        inline for (.{
            .{ "rings", "examples/rings.zig", "markworld particle flecs rings stress demo" },
            .{ "coalesce", "examples/coalesce.zig", "markworld sticky LOD + flecs living agents demo" },
        }) |ex| {
            const exe = b.addExecutable(.{
                .name = "atlas-markworld-" ++ ex[0],
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = markworld_dep.path(ex[1]),
                }),
            });
            exe.root_module.addImport("dvui", gpu_dvui);
            exe.root_module.addImport("batch2d", batch2d_gpu);
            exe.root_module.addImport("markworld", markworld_gpu);
            exe.root_module.addImport("zflecs", zflecs_dep.module("root"));
            exe.root_module.linkLibrary(zflecs_dep.artifact("flecs"));
            const run = b.addRunArtifact(exe);
            if (b.args) |a| run.addArgs(a);
            b.step(ex[0], ex[2]).dependOn(&run.step);
            // Back-compat alias for the old local flecs-rings harness.
            if (comptime std.mem.eql(u8, ex[0], "rings")) {
                b.step("flecs-rings", "alias: zig build rings (markworld)").dependOn(&run.step);
            }
        }
    }

    // Headless organic LOD zoom tour — CSV + diagnostic PPM frames (no window).

    // batch2d package tests (soft atlas / sprite+line batches / camera / hit).
    {
        const b2d_tests = b.addTest(.{
            .name = "atlas-batch2d-tests",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = batch2d_dep.path("src/root.zig"),
            }),
        });
        b2d_tests.root_module.addImport("dvui", fizzy_dep.module("dvui"));
        test_step.dependOn(&b.addRunArtifact(b2d_tests).step);
    }
}
