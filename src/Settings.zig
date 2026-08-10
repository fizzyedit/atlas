//! atlas's user settings. Each field is a self-describing `sdk.settings.Value` cell: payload
//! type, default, and the description fizzy shows under the setting's name. Read with `.get()`.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

/// Which layout/level-of-detail pipeline the graph panel uses. See `graph_layout` below.
pub const GraphLayout = enum {
    classic,
    containment,
};

/// Graph shape for **Atlas: Load Synth Graph** — in-memory scale tests (no markdown on disk).
pub const SynthShape = enum {
    islands,
    scale_free,
    hub,
    bipartite,
    chain,
    orphans,
};

/// Rewrites every resolvable `[[wikilink]]` in a markdown document as a `[label](path.md)`
/// markdown link when the document is formatted — which includes format-on-save.
///
/// Off by default, and deliberately so: a wikilink resolves by *stem*, so moving or renaming
/// its target keeps it working, while a markdown link is a literal path that breaks. Turning
/// this on trades that for portability (a plain markdown link renders anywhere, GitHub
/// included). Unresolved links are never converted, so the click-a-phantom-to-create-it flow
/// keeps working either way.
///
/// Note this only reaches the *save* path when the text plugin's own "Format on save" is also
/// enabled — atlas supplies the formatter, but the document's owner decides when to run one.
/// `Atlas: Convert Wikilinks to Markdown Links` runs it on demand regardless.
convert_wikilinks_on_save: settings.Value(bool, .{
    .description = "When formatting a markdown document (including on save), rewrite " ++
        "resolvable [[wikilinks]] as [label](path.md) markdown links. Unresolved links, " ++
        "embeds, and links inside code are left alone.",
}) = .init(false),

/// Selects between two entirely separate ways of deciding where notes go.
///
/// The classic path lays every note out flat (`layout_full.zig`: force solve, folder cohesion,
/// lattice snap, component packing, aspect envelope, crossing-minimising refine) and then infers
/// a level-of-detail hierarchy back out of the resulting positions (`quadlod.zig`). Because that
/// hierarchy is spatial, a coalesced ring can hold notes from unrelated topics that merely landed
/// near each other.
///
/// The containment path inverts it: `fold.zig` builds one hierarchy from links (with folder
/// adjacency as a weak tiebreak), and `containment.zig` derives positions by placing each cell's
/// children inside that cell's disc. A coalesced ring is then related by construction, and the
/// vault always fits one circle — so aspect ratio cannot degenerate and the same rule holds at 5
/// notes and at a million.
graph_layout: settings.Value(GraphLayout, .{
    .name = "Graph layout",
    .description = "Classic: flat force layout with a spatial quadtree for level-of-detail. " ++
        "Containment: one link-derived hierarchy, with each cluster's children placed inside it. " ++
        "Containment is the newer path — switch back if a vault lays out worse under it.",
}) = .init(.classic),

synth_notes: settings.Value(i64, .{
    .name = "Synth note count",
    .description = "Notes for the in-memory synth (no files). Quantized while dragging; rebuilds " ++
        "on a background thread and keeps the previous graph until ready. Start with Atlas: Load Synth Graph.",
    .min = 100,
    .max = 1_000_000,
}) = .init(10_000),

synth_shape: settings.Value(SynthShape, .{
    .name = "Synth shape",
    .description = "Link topology: islands, scale-free, hub, bipartite, chain, or orphans. " ++
        "Swaps in asynchronously after a short debounce when a synth is already open.",
}) = .init(.islands),

synth_avg_degree: settings.Value(f32, .{
    .name = "Synth avg degree",
    .description = "Target mean undirected degree (≈ 2×edges / notes). Background regen; " ++
        "previous graph stays interactive until the new one lands.",
    .min = 0,
    .max = 16,
    .step = 0.5,
}) = .init(4),
