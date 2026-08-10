//! Atlas — wiki-style notes over the open folder.
//!
//! Indexes every markdown file under the project root, resolves `[[wikilinks]]` between them,
//! and surfaces the resulting graph: backlinks in the sidebar, a navigable graph in the
//! bottom panel.
//!
//! **Owns no documents.** The `text` plugin owns `.md` and keeps owning it; atlas contributes
//! the link layer around it and reaches live buffer contents through the SDK's
//! `documentContentChanged` broadcast rather than by claiming the file type. That's what lets
//! it index markdown it never renders, and why the vtable here is a *utility* vtable.
const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const sdk = @import("fizzy_sdk");

const runtime = @import("src/runtime.zig");
const State = @import("src/State.zig");
const backlinks = @import("src/ui/backlinks.zig");
const graph = @import("src/ui/graph.zig");
const wikilink_impl = @import("src/service/wikilink_impl.zig");
const md_completion = @import("src/service/md_completion.zig");
const query = @import("src/index/query.zig");

/// Injected at build time from `plugin.zig.zon` — the generated dylib root reads identity
/// through this export rather than importing `fizzy_plugin_options` itself.
pub const plugin_options = @import("fizzy_plugin_options");

pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = pluginDeinit,
    .onFolderOpen = onFolderOpen,
    .onFolderClose = onFolderClose,
    .documentContentChanged = documentContentChanged,
    .folderPathsChanged = folderPathsChanged,
    .needsContinuousRepaint = needsContinuousRepaint,
    .endFrame = endFrame,
    .settingsChanged = settingsChanged,
};

var plugin_state: State = .{};

var wikilink_api: sdk.services.wikilink.Api = .{
    .ctx = @ptrCast(&plugin_state),
    .vtable = &wikilink_impl.vtable,
};

const language_support: sdk.LanguageSupport = .{
    .id = "atlas.md",
    .owner = &plugin,
    .vtable = &language_vtable,
};

const language_vtable: sdk.LanguageSupport.VTable = .{
    .completion = md_completion.completion,
    .supportsFormat = supportsFormat,
    .format = formatMarkdown,
};

/// atlas formats markdown only in the sense of rewriting wikilinks, so it claims `.md` only
/// while the user has asked for that. Reporting true unconditionally would light up
/// `Edit > Format Document` for every markdown file and then do nothing when clicked.
fn supportsFormat(state: *anyopaque, ext: []const u8) bool {
    const st: *State = @ptrCast(@alignCast(state));
    if (!conversionWanted(st)) return false;
    return query.isMarkdownPath(ext);
}

fn conversionWanted(st: *State) bool {
    return st.settings.convert_wikilinks_on_save.get() or st.force_convert;
}

/// The returned slice only has to survive the call (the document's owner copies it), so the
/// frame arena is the right allocator.
fn formatMarkdown(state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8) ?[]const u8 {
    if (!query.isMarkdownPath(ext)) return null;
    const st: *State = @ptrCast(@alignCast(state));
    if (!conversionWanted(st)) return null;
    return st.convertWikilinks(dvui.currentWindow().arena(), path, bytes) catch |err| {
        dvui.log.err("atlas: convert wikilinks {s}: {any}", .{ path, err });
        return null;
    };
}

pub fn register(host: *sdk.Host) !void {
    plugin_state.init(host.allocator);
    plugin.state = @ptrCast(&plugin_state);
    runtime.adoptState(&plugin_state);

    try host.registerPlugin(&plugin);
    plugin_state.loadSettings(host);
    try plugin_state.registerSettings(host, &plugin);
    try host.registerLanguageSupport(language_support);
    try host.registerSidebarView(.{
        .id = backlinks.view_id,
        .owner = &plugin,
        .icon = icons.tvg.lucide.@"git-fork",
        .title = "Backlinks",
        .draw = backlinks.draw,
    });
    try host.registerBottom(.{
        .id = graph.view_id,
        .owner = &plugin,
        .title = "Atlas",
        .persistent = true,
        .draw = graph.draw,
    });
    try host.registerService(sdk.services.wikilink.Api.service_name, &wikilink_api, &plugin);
    try host.registerCommand(.{
        .id = "atlas.rebuildIndex",
        .owner = &plugin,
        .title = "Atlas: Rebuild Index",
        .run = rebuildIndex,
        .isEnabled = rebuildIndexEnabled,
        .icon = icons.tvg.lucide.@"refresh-cw",
    });
    try host.registerCommand(.{
        .id = "atlas.openGraph",
        .owner = &plugin,
        .title = "Atlas: Open Graph",
        .run = openGraph,
        .icon = icons.tvg.lucide.@"git-graph",
    });
    try host.registerCommand(.{
        .id = "atlas.zoomGraphToFit",
        .owner = &plugin,
        .title = "Atlas: Zoom Graph to Fit",
        .run = zoomGraphToFit,
        .icon = icons.tvg.lucide.@"maximize",
    });
    try host.registerCommand(.{
        .id = "atlas.convertWikilinks",
        .owner = &plugin,
        .title = "Atlas: Convert Wikilinks to Markdown Links",
        .run = cmdConvertWikilinks,
        .isEnabled = cmdConvertWikilinksEnabled,
        .icon = icons.tvg.lucide.@"link",
    });
    try host.registerCommand(.{
        .id = "atlas.loadSynthGraph",
        .owner = &plugin,
        .title = "Atlas: Load Synth Graph",
        .run = loadSynthGraph,
        .icon = icons.tvg.lucide.@"orbit",
    });
    try host.registerCommand(.{
        .id = "atlas.clearSynthGraph",
        .owner = &plugin,
        .title = "Atlas: Clear Synth Graph",
        .run = clearSynthGraph,
        .isEnabled = clearSynthGraphEnabled,
        .icon = icons.tvg.lucide.@"circle-x",
    });

    // A folder may already be open when a plugin is loaded mid-session (install, or re-enable
    // from the store), and `onFolderOpen` only fires on a *change*. Without this, atlas would
    // sit idle until the user switched folders.
    if (host.folder()) |root| plugin_state.openVault(host.allocator, root) catch {};
}

fn pluginDeinit(state: *anyopaque) void {
    // Before anything else: the graph's layout worker runs code from this library, so it has to
    // be joined while that library is still loaded.
    graph.shutdown();
    const st: *State = @ptrCast(@alignCast(state));
    st.deinit(sdk.allocator());
}

fn onFolderOpen(state: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *State = @ptrCast(@alignCast(state));
    const root = sdk.host().folder() orelse return;
    st.openVault(allocator, root) catch |err| {
        dvui.log.err("atlas: could not open vault {s}: {any}", .{ root, err });
    };
}

fn onFolderClose(state: *anyopaque) void {
    // A layout worker for the folder being closed has nothing left to deliver, and `draw`
    // returns early once there is no vault, so it would never be collected there.
    graph.shutdown();
    const st: *State = @ptrCast(@alignCast(state));
    st.closeVault(sdk.allocator());
}

fn documentContentChanged(state: *anyopaque, path: []const u8, bytes: []const u8) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.setDirtyContent(path, bytes);
}

/// Files changed on disk under the open folder. This is what keeps the graph honest about notes
/// nobody has open — a wikilink deleted from a closed file used to sit in the graph until
/// something happened to re-read that file.
fn folderPathsChanged(state: *anyopaque, changes: sdk.Plugin.PathChanges) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.folderPathsChanged(changes);
}

fn needsContinuousRepaint(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    // Debounced reload / background synth build must tick even if the Atlas tab is idle.
    if (st.synthBusy()) return true;
    // Graph fling/drag only — not `busy`. Indexer busy used to force the whole editor
    // (including markdown preview) to redraw every frame while a scan ran, which felt like
    // the graph was "re-parsing". Sidebar counters still update on the next natural frame /
    // `sdk.refresh()` from the worker.
    // Active-tab + recently-painted gates live inside `wantsRepaint` (via `drawn_recently`).
    // Asking while another bottom tab is showing is still a cheap false.
    if (!sdk.host().isActiveBottomView(graph.view_id)) return false;
    return graph.wantsRepaint();
}

fn endFrame(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.tickWatcher();
}

fn settingsChanged(state: *anyopaque, blob: []const u8) void {
    _ = blob; // Schema already wrote the live Settings cells before this fires.
    const st: *State = @ptrCast(@alignCast(state));
    st.scheduleSynthReloadFromSettings();
    // Keep frames pumping while debouncing / building so the old graph stays interactive.
    if (st.synth_mode or st.synthBusy()) sdk.refresh();
}

fn rebuildIndex(state: *anyopaque) !void {
    const st: *State = @ptrCast(@alignCast(state));
    st.rebuildIndex();
}

fn rebuildIndexEnabled(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return st.hasVault() and !st.busy.load(.acquire);
}

fn openGraph(_: *anyopaque) !void {
    sdk.host().setActiveBottomView(graph.view_id);
}

/// In-memory scale vault from Atlas settings (note count / shape / avg degree). Skips force
/// layout — packed positions + Galaxy LOD. Raise N toward 1M to stress the overview path.
fn loadSynthGraph(state: *anyopaque) !void {
    const st: *State = @ptrCast(@alignCast(state));
    const gpa = sdk.allocator();
    st.loadSynth(gpa) catch |err| {
        dvui.log.err("atlas: load synth graph: {any}", .{err});
        return err;
    };
    sdk.host().setActiveBottomView(graph.view_id);
    graph.zoomExtents();
    sdk.refresh();
}

fn clearSynthGraphEnabled(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return st.synth_mode;
}

fn clearSynthGraph(state: *anyopaque) !void {
    const st: *State = @ptrCast(@alignCast(state));
    st.clearSynth(sdk.allocator());
    sdk.host().setActiveBottomView(graph.view_id);
    sdk.refresh();
}

fn cmdConvertWikilinksEnabled(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    if (!st.hasVault()) return false;
    const doc = sdk.host().activeDoc() orelse return false;
    return query.isMarkdownPath(doc.owner.documentPath(doc));
}

/// Rewrite the active markdown document's resolvable wikilinks as markdown links.
///
/// Delegates to the document owner's format command rather than editing the buffer directly:
/// atlas owns no documents, and going through the owner means the rewrite lands as one
/// undoable edit with the caret preserved, which `Document.replaceRange` already handles.
/// `force_convert` is what lets this work while the on-save setting is off.
fn cmdConvertWikilinks(state: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    st.force_convert = true;
    defer st.force_convert = false;
    try sdk.host().runCommand(sdk.Plugin.commandId("text", "format"));
}

/// Recentre the graph on the whole vault. The only way to trigger a refit now that clicking
/// a node deliberately leaves the camera alone.
fn zoomGraphToFit(_: *anyopaque) !void {
    sdk.host().setActiveBottomView(graph.view_id);
    graph.zoomExtents();
}

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}
