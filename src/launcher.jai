// launcher.jai

Launcher :: struct {
    active := false;
    input_text: [..] u8;  // dynamic buffer for what the user is typing
    input_string: string;  // view into input_text for display

    commands: [..] Launcher_Command;
    filtered_results: [..] *Launcher_Command;  // pointers into commands, filtered by current input
    selected_index: s32 = 0;  // which result in the filtered list is highlighted

    MAX_VISIBLE_RESULTS :: 10;
    scroll_offset: s32 = 0;  // for scrolling through long result lists
}

Launcher_Command :: struct {
    name: string;
    description: string;
    shortcut_hint: string;  // e.g. "F", "D", "TAB" — just for display
    callback: #type (*Launcher_Command, user_data: *void);
    user_data: *void;
}

init_launcher :: (launcher: *Launcher) {
    add_command(launcher, "Move", "Move selected elements", "F");
    add_command(launcher, "Rotate", "Rotate selected elements", "D");
    add_command(launcher, "Scale", "Scale selected elements", "S");
    add_command(launcher, "Select Vertices", "Switch to vertex selection mode", "");
    add_command(launcher, "Select Edges", "Switch to edge selection mode", "");
    add_command(launcher, "Select Faces", "Switch to face selection mode", "");
    add_command(launcher, "Cycle Selection Mode", "Cycle vertex/edge/face", "TAB");
    add_command(launcher, "Snap to Grid", "Snap selected to grid", "");
    add_command(launcher, "Snap Increment", "Toggle snap increment mode", "X");
    add_command(launcher, "Clear Selection", "Deselect all", "");
    add_command(launcher, "Extrude", "Extrude selected faces", "");
    add_command(launcher, "Subdivide", "Subdivide selected faces", "");
    add_command(launcher, "Inset", "Inset selected faces", "");
    add_command(launcher, "Delete", "Delete selected elements", "");
    add_command(launcher, "Create Face", "Create a face from selected vertices", "");
    add_command(launcher, "Create Cube", "Add a new cube to the scene", "");
    add_command(launcher, "Create Cylinder", "Add a new cylinder to the scene", "");
    add_command(launcher, "Create Plane", "Add a new plane to the scene", "");
    add_command(launcher, "Create Quad", "Add a new single quad to the scene", "");
    add_command(launcher, "Create Circle", "Add a new 16-vertex ngon to the scene", "");
    add_command(launcher, "Export", "Export the scene", "");
    add_command(launcher, "View Front", "Look at scene from front", "");
    add_command(launcher, "View Right", "Look at scene from right", "");
    add_command(launcher, "View Top", "Look at scene from top", "");

    rebuild_filtered_results(launcher);
}

deinit_launcher :: (launcher: *Launcher) {
    array_free(launcher.input_text);
    array_free(launcher.commands);
    array_free(launcher.filtered_results);
}

add_command :: (launcher: *Launcher, name: string, description: string, shortcut_hint: string = "", callback: #type (*Launcher_Command, *void) = null, user_data: *void = null) {
    cmd := array_add(*launcher.commands);
    cmd.name = name;
    cmd.description = description;
    cmd.shortcut_hint = shortcut_hint;
    cmd.callback = callback;
    cmd.user_data = user_data;
}

toggle_launcher :: (launcher: *Launcher) {
    if launcher.active {
        close_launcher(launcher);
    } else {
        open_launcher(launcher);
    }
}

open_launcher :: (launcher: *Launcher) {
    launcher.active = true;
    launcher.selected_index = 0;
    launcher.scroll_offset = 0;
    array_reset(*launcher.input_text);
    launcher.input_string = "";
    rebuild_filtered_results(launcher);
}

close_launcher :: (launcher: *Launcher) {
    launcher.active = false;
    array_reset(*launcher.input_text);
    launcher.input_string = "";
}

// processes all events this frame for the launcher. call once per frame when launcher is active.
// returns the command that was executed (if the user pressed enter), or null otherwise.
launcher_per_frame_update :: (launcher: *Launcher) -> *Launcher_Command {
    Input :: #import "Input";

    if !launcher.active return null;

    result: *Launcher_Command = null;

    for event: Input.events_this_frame {
        cmd := launcher_handle_event(launcher, event);
        if cmd != null then result = cmd;

        // if the launcher was closed (e.g. by escape), stop processing
        if !launcher.active break;
    }

    return result;
}

// returns the command that was executed, or null if nothing happened yet.
launcher_handle_event :: (launcher: *Launcher, event: Input.Event) -> executed_command: *Launcher_Command {
    Input :: #import "Input";

    if !launcher.active return null;

    if event.type == .KEYBOARD && event.key_pressed {
        if event.key_code == {
            case .ESCAPE;
                close_launcher(launcher);
                return null;

            case .ENTER;
                if launcher.filtered_results.count > 0 && launcher.selected_index >= 0 && launcher.selected_index < cast(s32) launcher.filtered_results.count {
                    cmd := launcher.filtered_results[launcher.selected_index];
                    close_launcher(launcher);
                    return cmd;
                }
                return null;

            case .TAB;
                if launcher.filtered_results.count > 0 && launcher.selected_index >= 0 && launcher.selected_index < cast(s32) launcher.filtered_results.count {
                    cmd := launcher.filtered_results[launcher.selected_index];
                    array_reset(*launcher.input_text);
                    for 0..cmd.name.count-1 {
                        array_add(*launcher.input_text, cmd.name[it]);
                    }
                    launcher.input_string.data = launcher.input_text.data;
                    launcher.input_string.count = launcher.input_text.count;
                    rebuild_filtered_results(launcher);
                }
                return null;

            case .ARROW_UP;
                launcher.selected_index -= 1;
                if launcher.selected_index < 0
                    launcher.selected_index = cast(s32) max(cast(s64) 0, cast(s64) launcher.filtered_results.count - 1);
                ensure_selected_visible(launcher);
                return null;

            case .ARROW_DOWN;
                launcher.selected_index += 1;
                if launcher.selected_index >= cast(s32) launcher.filtered_results.count
                    launcher.selected_index = 0;
                ensure_selected_visible(launcher);
                return null;

            case .BACKSPACE;
                if launcher.input_text.count > 0 {
                    launcher.input_text.count -= 1;
                    launcher.input_string.data = launcher.input_text.data;
                    launcher.input_string.count = launcher.input_text.count;
                    rebuild_filtered_results(launcher);
                }
                return null;
        }
    }

    if event.type == .TEXT_INPUT {
        char := event.utf32;
        if char >= 32 && char < 127 {
            array_add(*launcher.input_text, cast(u8) char);
            launcher.input_string.data = launcher.input_text.data;
            launcher.input_string.count = launcher.input_text.count;
            rebuild_filtered_results(launcher);
        }
        return null;
    }

    return null;
}

ensure_selected_visible :: (launcher: *Launcher) {
    if launcher.selected_index < launcher.scroll_offset {
        launcher.scroll_offset = launcher.selected_index;
    }
    if launcher.selected_index >= launcher.scroll_offset + Launcher.MAX_VISIBLE_RESULTS {
        launcher.scroll_offset = launcher.selected_index - Launcher.MAX_VISIBLE_RESULTS + 1;
    }
}

rebuild_filtered_results :: (launcher: *Launcher) {
    array_reset(*launcher.filtered_results);

    query := launcher.input_string;

    if query.count == 0 {
        for * launcher.commands {
            array_add(*launcher.filtered_results, it);
        }
    } else {
        for * launcher.commands {
            if contains_case_insensitive(it.name, query) || contains_case_insensitive(it.description, query) {
                array_add(*launcher.filtered_results, it);
            }
        }
    }

    if launcher.selected_index >= cast(s32) launcher.filtered_results.count {
        launcher.selected_index = cast(s32) max(cast(s64) 0, cast(s64) launcher.filtered_results.count - 1);
    }
    ensure_selected_visible(launcher);
}

contains_case_insensitive :: (haystack: string, needle: string) -> bool {
    if needle.count == 0 return true;
    if needle.count > haystack.count return false;

    for i: 0..haystack.count - needle.count {
        found := true;
        for j: 0..needle.count - 1 {
            a := haystack[i + j];
            b := needle[j];
            if a >= #char "A" && a <= #char "Z" then a += 32;
            if b >= #char "A" && b <= #char "Z" then b += 32;
            if a != b { found = false; break; }
        }
        if found return true;
    }
    return false;
}

// renders the launcher overlay using getrect labels and simp quads.
// uses the same approach as render_editor_hud and the rest of the engine.
render_launcher :: (launcher: *Launcher, wp: *Windowed_Program) {
    if !launcher.active return;

    Simp :: #import "Simp";

    ww := cast(float) wp.window_width;
    wh := cast(float) wp.window_height;

    // layout in normalized coordinates matching get_rect_normalized conventions
    // panel: centered horizontally, near top of screen
    panel_norm_w := 0.8;   // normalized width
    panel_norm_x := 0.0;   // centered

    row_norm_h := 0.05;
    input_row_norm_h := row_norm_h * 1.4;
    gap_norm := row_norm_h * 0.2;

    visible_count := min(cast(s32) launcher.filtered_results.count - launcher.scroll_offset, cast(s32) Launcher.MAX_VISIBLE_RESULTS);
    if visible_count < 0 then visible_count = 0;

    total_rows_h := cast(float) visible_count * row_norm_h;
    total_panel_h := input_row_norm_h + gap_norm + total_rows_h + row_norm_h * 0.5;

    // panel top edge in normalized coords
    panel_top_y := 0.7;
    panel_bot_y := panel_top_y - total_panel_h;

    // convert panel bounds to screen pixels for simp quads
    panel_left_px  := (panel_norm_x - panel_norm_w * 0.5 + 1.0) * 0.5 * ww;
    panel_right_px := (panel_norm_x + panel_norm_w * 0.5 + 1.0) * 0.5 * ww;
    panel_top_px   := (panel_top_y + 1.0) * 0.5 * wh;
    panel_bot_px   := (panel_bot_y + 1.0) * 0.5 * wh;

    // draw dark background
    Simp.set_shader_for_color(true);
    bg_color := Vector4.{0.12, 0.12, 0.12, 0.95};
    Simp.immediate_quad(panel_left_px, panel_bot_px, panel_right_px, panel_top_px, bg_color);

    // draw border
    border_color := Vector4.{0.4, 0.4, 0.4, 0.8};
    b := 2.0;
    Simp.immediate_quad(panel_left_px, panel_top_px - b, panel_right_px, panel_top_px, border_color);
    Simp.immediate_quad(panel_left_px, panel_bot_px, panel_right_px, panel_bot_px + b, border_color);
    Simp.immediate_quad(panel_left_px, panel_bot_px, panel_left_px + b, panel_top_px, border_color);
    Simp.immediate_quad(panel_right_px - b, panel_bot_px, panel_right_px, panel_top_px, border_color);

    // input field background
    input_top_y := panel_top_y;
    input_bot_y := panel_top_y - input_row_norm_h;
    input_top_px := (input_top_y + 1.0) * 0.5 * wh;
    input_bot_px := (input_bot_y + 1.0) * 0.5 * wh;
    input_bg := Vector4.{0.18, 0.18, 0.18, 1.0};
    Simp.immediate_quad(panel_left_px, input_bot_px, panel_right_px, input_top_px, input_bg);

    // use getrect label for text rendering
    label_theme := wp.my_theme.label_theme;
    label_theme.alignment = .Left;

    // input field text
    display_text: string;
    if launcher.input_text.count > 0 {
        display_text = tprint("> %", launcher.input_string);
    } else {
        display_text = "> Type to search commands...";
    }

    input_label_theme := label_theme;
    if launcher.input_text.count == 0 {
        input_label_theme.text_color = .{0.5, 0.5, 0.5, 1.0};
    }

    input_rect := get_rect_normalized(
        create_rectangle(panel_norm_x, (input_top_y + input_bot_y) * 0.5, panel_norm_w * 0.95, input_row_norm_h, .CENTER),
        ww, wh
    );
    label(input_rect, display_text, *input_label_theme);

    // Draw filtered results
    highlight_bg := Vector4.{0.3, 0.3, 0.5, 0.9};
    shortcut_color := Vector4.{0.6, 0.8, 0.6, 1.0};

    row_top_y := input_bot_y - gap_norm;

    for i: 0..visible_count - 1 {
        result_index := launcher.scroll_offset + cast(s32) i;
        if result_index >= cast(s32) launcher.filtered_results.count break;

        cmd := launcher.filtered_results[result_index];

        row_bot_y := row_top_y - row_norm_h;
        row_center_y := (row_top_y + row_bot_y) * 0.5;

        // highlight selected row
        if result_index == launcher.selected_index {
            Simp.set_shader_for_color(true);
            hl_top_px := (row_top_y + 1.0) * 0.5 * wh;
            hl_bot_px := (row_bot_y + 1.0) * 0.5 * wh;
            Simp.immediate_quad(panel_left_px, hl_bot_px, panel_right_px, hl_top_px, highlight_bg);
        }

        // command name and description
        row_label_theme := label_theme;
        if result_index == launcher.selected_index {
            row_label_theme.text_color = .{1, 1, 1, 1};
        } else {
            row_label_theme.text_color = .{0.85, 0.85, 0.85, 1};
        }

        // name on the left
        name_rect := get_rect_normalized(
            create_rectangle(panel_norm_x - panel_norm_w * 0.25, row_center_y, panel_norm_w * 0.45, row_norm_h, .CENTER),
            ww, wh
        );
        label(name_rect, cmd.name, *row_label_theme);

        // description in the middle (dimmer)
        desc_label_theme := label_theme;
        desc_label_theme.text_color = .{0.5, 0.5, 0.5, 0.9};
        desc_rect := get_rect_normalized(
            create_rectangle(panel_norm_x + panel_norm_w * 0.1, row_center_y, panel_norm_w * 0.4, row_norm_h, .CENTER),
            ww, wh
        );
        label(desc_rect, cmd.description, *desc_label_theme);

        // shortcut hint on the right
        if cmd.shortcut_hint.count > 0 {
            shortcut_label_theme := label_theme;
            shortcut_label_theme.text_color = shortcut_color;
            shortcut_label_theme.alignment = .Right;
            shortcut_rect := get_rect_normalized(
                create_rectangle(panel_norm_x + panel_norm_w * 0.4, row_center_y, panel_norm_w * 0.1, row_norm_h, .CENTER),
                ww, wh
            );
            label(shortcut_rect, cmd.shortcut_hint, *shortcut_label_theme);
        }

        row_top_y = row_bot_y;
    }

    // result count at bottom
    if launcher.filtered_results.count > 0 {
        count_label_theme := label_theme;
        count_label_theme.text_color = .{0.5, 0.5, 0.5, 1.0};
        count_rect := get_rect_normalized(
            create_rectangle(panel_norm_x, panel_bot_y + row_norm_h * 0.25, panel_norm_w * 0.95, row_norm_h * 0.5, .CENTER),
            ww, wh
        );
        label(count_rect, tprint("% / % commands", launcher.filtered_results.count, launcher.commands.count), *count_label_theme);
    }
}
