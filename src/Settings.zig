//! atlas's user settings. Each field is a self-describing `sdk.settings.Value` cell: payload
//! type, default, and the description fizzy shows under the setting's name. Read with `.get()`.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

/// How many marks the graph panel may draw in one frame.
///
/// The host renders an int setting with bounds as a slider, so this needs no widget of its own,
/// and `stepWorld` re-reads it every frame — moving it takes effect immediately, with no rebuild.
///
/// This is the one honest knob for the cost/detail trade. Raising it resolves more of the vault
/// into individual notes instead of coalesced groups and costs more per frame; lowering it
/// coalesces sooner and stays smooth. The default matches `galaxy.plugin_mark_budget`.
/// The graph's single quality control. Three things move together off this one number — the mark
/// budget it names directly, the ambient link budget (`graph.ambientLinkBudget`) and how far a pan
/// is allowed to coarsen the level of detail (`graph.motionSplitMax`) — because they are one
/// decision wearing three hats: how much of the vault is resolved as itself rather than coalesced.
/// Links can only be drawn between two *living* cells, so raising the node count is what makes
/// connections appear at all; the other two stop the web from being truncated or dissolved by
/// motion once they exist. At the default, all three reproduce the constants they replaced.
graph_detail: settings.Value(u32, .{
    .name = "Graph quality",
    .description = "How much of the vault the note graph resolves at once. Higher draws more " ++
        "notes as themselves rather than coalesced groups, keeps more of the links between " ++
        "them, and holds that detail while you pan — a prettier, more accurate map that costs " ++
        "more per frame. Lower coalesces sooner and stays smooth on very large vaults.",
    .min = 50,
    .max = 4000,
}) = .init(360),

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
