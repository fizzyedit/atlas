//! atlas's user settings. Each field is a self-describing `sdk.settings.Value` cell: payload
//! type, default, and the description fizzy shows under the setting's name. Read with `.get()`.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

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
