// hud.jai
//
// Interactive HUD with numeric inputs, toggle buttons, and dropdowns.
//

// ============================================================================
// HUD State
// ============================================================================

Hud :: struct {
    // subwindow
    subwindow_info: Subwindow_Info;
    initted: bool;
    scroll_value: float;

    // snap increment text input
    snap_increment_str: string;
    snap_increment_str_initted: bool;

    // Persistent dropdown indices that GetRect writes to directly.
    editor_mode_index: s32;
    selection_mode_index: s32;
    snap_mode_index: s32;
    axis_constraint_index: s32;

    // "Last known" values from the actual state, so we can detect
    // when external code (keyboard) changed something and we need
    // to update our dropdown index to match.
    last_known_editor_mode: s32 = -1;
    last_known_selection_mode: s32 = -1;
    last_known_snap_mode: s32 = -1;
    last_known_axis_constraint: s32 = -99;

    // references set each frame
    scene: *Scene;
    selected_em: *Editable_Mesh;
    mode: *Mode;
    launcher: *Launcher;
    wp: *Windowed_Program;
    window_width: s32;
    window_height: s32;
    theme: *Overall_Theme;

    needs_rebuffer: bool;

    // renderer references for rebuffering
    surface_renderer: *Camera_Per_Object_Transform_Color_Renderer;
    point_renderer: *Camera_Per_Object_Transform_Position_Point_Color_Renderer;
    edge_renderer: *Camera_Per_Object_Transform_Color_Renderer;
    face_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer;
    picker: *Screen_Space_Object_Picker;
}

hud: Hud;

// ============================================================================
// Dropdown name arrays
// ============================================================================

SELECTION_MODE_NAMES :: string.["Vertex", "Edge", "Face"];
SNAP_MODE_NAMES :: string.["Off", "Grid", "Increment"];
EDITOR_MODE_NAMES :: string.["Object", "Edit"];
AXIS_CONSTRAINT_NAMES :: string.["Free", "X", "Y", "Z"];
AXIS_CONSTRAINT_VALUES :: s32.[-1, 0, 1, 2];

// ============================================================================
// Display toggle state (queryable from main code)
// ============================================================================

hud_show_grid:         bool = true;
hud_show_normals:      bool = false;
hud_show_origins:      bool = true;
hud_wireframe_overlay: bool = false;
hud_backface_culling:  bool = false;

// ============================================================================
// Init / Deinit
// ============================================================================

hud_init :: (
    surface_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    point_renderer: *Camera_Per_Object_Transform_Position_Point_Color_Renderer,
    edge_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    face_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer,
    picker: *Screen_Space_Object_Picker
) {
    hud.surface_renderer = surface_renderer;
    hud.point_renderer = point_renderer;
    hud.edge_renderer = edge_renderer;
    hud.face_renderer = face_renderer;
    hud.picker = picker;
}

hud_deinit :: () {
    if hud.snap_increment_str_initted {
        free(hud.snap_increment_str);
    }
}

// ============================================================================
// Read actual state into an index
// ============================================================================

get_actual_editor_mode_index :: () -> s32 {
    if hud.scene == null return 0;
    return xx hud.scene.editor_mode;
}

get_actual_selection_mode_index :: () -> s32 {
    em := hud.selected_em;
    if em == null return 0;
    return xx em.selection_mode;
}

get_actual_snap_mode_index :: () -> s32 {
    em := hud.selected_em;
    if em == null return 0;
    scene := hud.scene;
    if scene == null return 0;

    snap_mode: type_of(em.op_state.snap_mode);
    if scene.editor_mode == .EDIT {
        snap_mode = em.op_state.snap_mode;
    } else {
        snap_mode = em.obj_op_state.snap_mode;
    }

    if snap_mode == {
        case .NONE;      return 0;
        case .GRID;      return 1;
        case .INCREMENT; return 2;
    }
    return 0;
}

get_actual_axis_constraint_index :: () -> s32 {
    em := hud.selected_em;
    if em == null return 0;
    scene := hud.scene;
    if scene == null return 0;

    active_axis: s32 = -1;
    if scene.editor_mode == .EDIT && em.op_state.active_op != .NONE {
        active_axis = em.op_state.axis_constraint;
    } else if scene.editor_mode == .OBJECT && em.obj_op_state.active_op != .NONE {
        active_axis = em.obj_op_state.axis_constraint;
    }

    if active_axis == {
        case -1; return 0;
        case  0; return 1;
        case  1; return 2;
        case  2; return 3;
    }
    return 0;
}

// ============================================================================
// Per-frame entry point
// ============================================================================

hud_update_and_draw :: (
    wp: *Windowed_Program,
    scene: *Scene,
    selected_em: *Editable_Mesh,
    mode: *Mode,
    launcher: *Launcher,
    window_width: s32,
    window_height: s32,
    theme: *Overall_Theme
) {
    hud.scene = scene;
    hud.selected_em = selected_em;
    hud.mode = mode;
    hud.launcher = launcher;
    hud.wp = wp;
    hud.window_width = window_width;
    hud.window_height = window_height;
    hud.theme = theme;
    hud.needs_rebuffer = false;

    if !hud.snap_increment_str_initted {
        hud.snap_increment_str = copy_string("0.5");
        hud.snap_increment_str_initted = true;
    }

    // Detect external changes: if the actual state differs from what we
    // last knew, an external source (keyboard shortcut) changed it.
    // Update our dropdown index to match.
    actual_editor := get_actual_editor_mode_index();
    if actual_editor != hud.last_known_editor_mode {
        hud.editor_mode_index = actual_editor;
        hud.last_known_editor_mode = actual_editor;
    }

    actual_sel := get_actual_selection_mode_index();
    if actual_sel != hud.last_known_selection_mode {
        hud.selection_mode_index = actual_sel;
        hud.last_known_selection_mode = actual_sel;
    }

    actual_snap := get_actual_snap_mode_index();
    if actual_snap != hud.last_known_snap_mode {
        hud.snap_mode_index = actual_snap;
        hud.last_known_snap_mode = actual_snap;
    }

    actual_axis := get_actual_axis_constraint_index();
    if actual_axis != hud.last_known_axis_constraint {
        hud.axis_constraint_index = actual_axis;
        hud.last_known_axis_constraint = actual_axis;
    }

    if !hud.initted {
        k := window_height * 0.1;
        r := get_rect(0.1 * k, 0.3 * k, 3.8 * k, 9.2 * k);
        hud.subwindow_info.rect = r;
        hud.subwindow_info.draw = draw_hud_subwindow;
        hud.subwindow_info.title_text = "HUD";
        hud.subwindow_info.open = true;
        hud.initted = true;
    }

    if hud.subwindow_info.open {
        sw_theme := theme.subwindow_theme;
        add_subwindow(*hud.subwindow_info, *sw_theme);
    }

    // If the HUD changed something that needs rebuffering, do it
    if hud.needs_rebuffer && selected_em != null {
        update_selection_colors(selected_em);
        rebuffer_object(hud.point_renderer, selected_em.vertex_selection_renderable);
        rebuffer_object(hud.edge_renderer, selected_em.edge_selection_renderable);
        rebuffer_object(hud.face_renderer, selected_em.face_selection_overlay_renderable);
    }
}

// ============================================================================
// Subwindow draw callback
// ============================================================================

draw_hud_subwindow :: (state: *Subwindow_State, r: Rect, data: *void) {
    theme := hud.theme;
    if theme == null return;

    row_height   := r.w * 0.08;
    section_pad  := row_height * 0.6;
    item_pad     := row_height * 0.25;

    scroll_theme := theme.scrollable_region_theme;
    scroll_theme.region_background.shape.rounding_flags = 0;
    scroll_theme.region_background.frame_color.w = 0;
    scroll_theme.region_background.color.w = 0;

    region, inside := begin_scrollable_region(r, *scroll_theme);

    cursor := inside;
    cursor.h = row_height;
    cursor.y = inside.y + inside.h - row_height + hud.scroll_value;

    scene := hud.scene;
    em := hud.selected_em;

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Mode
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Mode", row_height, theme);

        checkbox_theme := theme.checkbox_theme;
        is_free := hud.mode.* == .FREE_MOUSE;
        base_checkbox(cursor, "Free Mouse (RMB)", is_free, *checkbox_theme, 10000);
        cursor.y -= row_height + item_pad;
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Editor Mode
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Editor", row_height, theme);

        dropdown_theme := *theme.dropdown_theme;

        old_val := hud.editor_mode_index;

        hud_labeled_dropdown(*cursor, "Mode", EDITOR_MODE_NAMES, *hud.editor_mode_index, dropdown_theme, row_height, item_pad, theme, 10100);

        if hud.editor_mode_index != old_val {
            no_op := em == null || !any_operation_active(em);
            if no_op {
                if hud.editor_mode_index == 0 {
                    if em != null {
                        clear_selection(em);
                        hud.needs_rebuffer = true;
                    }
                    scene.editor_mode = .OBJECT;
                    hud.last_known_editor_mode = 0;
                } else if hud.editor_mode_index == 1 {
                    if scene.selected_object >= 0 {
                        scene.editor_mode = .EDIT;
                        hud.last_known_editor_mode = 1;
                    } else {
                        hud.editor_mode_index = old_val;
                    }
                }
            } else {
                hud.editor_mode_index = old_val;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Selection
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Selection", row_height, theme);

        label_theme := theme.label_theme;
        label_theme.alignment = .Left;

        if scene.selected_object >= 0 {
            obj := scene.objects[scene.selected_object];
            label(cursor, tprint("Object: % (id=%)", scene.selected_object, obj.object_id), *label_theme);
        } else {
            label(cursor, "Object: None", *label_theme);
        }
        cursor.y -= row_height + item_pad;

        if scene.editor_mode == .EDIT && em != null {
            dropdown_theme := *theme.dropdown_theme;

            old_val := hud.selection_mode_index;

            hud_labeled_dropdown(*cursor, "Select", SELECTION_MODE_NAMES, *hud.selection_mode_index, dropdown_theme, row_height, item_pad, theme, 10200);

            if hud.selection_mode_index != old_val {
                if !any_operation_active(em) {
                    if hud.selection_mode_index == {
                        case 0; em.selection_mode = .VERTEX;
                        case 1; em.selection_mode = .EDGE;
                        case 2; em.selection_mode = .FACE;
                    }
                    clear_selection(em);
                    hud.needs_rebuffer = true;
                    hud.last_known_selection_mode = hud.selection_mode_index;
                } else {
                    hud.selection_mode_index = old_val;
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Operation
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Operation", row_height, theme);

        label_theme := theme.label_theme;
        label_theme.alignment = .Left;

        op_str: string;
        has_active_op := false;

        if scene.editor_mode == .EDIT && em != null {
            if em.op_state.active_op == {
                case .NONE;   op_str = "None";
                case .MOVE;   op_str = "Move (Edit)";
                case .ROTATE; op_str = "Rotate (Edit)";
                case .SCALE;  op_str = "Scale (Edit)";
            }
            has_active_op = em.op_state.active_op != .NONE;
        } else if scene.editor_mode == .OBJECT && em != null {
            if em.obj_op_state.active_op == {
                case .NONE;   op_str = "None";
                case .MOVE;   op_str = "Move (Object)";
                case .ROTATE; op_str = "Rotate (Object)";
                case .SCALE;  op_str = "Scale (Object)";
            }
            has_active_op = em.obj_op_state.active_op != .NONE;
        } else {
            op_str = "None";
        }

        label(cursor, tprint("Active: %", op_str), *label_theme);
        cursor.y -= row_height + item_pad;

        if has_active_op && em != null {
            dropdown_theme := *theme.dropdown_theme;

            old_val := hud.axis_constraint_index;

            hud_labeled_dropdown(*cursor, "Axis Lock", AXIS_CONSTRAINT_NAMES, *hud.axis_constraint_index, dropdown_theme, row_height, item_pad, theme, 10300);

            if hud.axis_constraint_index != old_val {
                new_axis := AXIS_CONSTRAINT_VALUES[hud.axis_constraint_index];
                if scene.editor_mode == .EDIT {
                    em.op_state.axis_constraint = new_axis;
                } else {
                    em.obj_op_state.axis_constraint = new_axis;
                }
                hud.last_known_axis_constraint = hud.axis_constraint_index;
            }
        }

        if has_active_op {
            hint_theme := theme.label_theme;
            hint_theme.alignment = .Left;
            hint_theme.text_color = .{0.6, 0.6, 0.4, 1};
            label(cursor, "LMB=Confirm  RMB/ESC=Cancel", *hint_theme);
            cursor.y -= row_height + item_pad;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Snapping
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Snapping", row_height, theme);

        if em != null {
            dropdown_theme := *theme.dropdown_theme;

            snap_mode_ptr: *type_of(em.op_state.snap_mode);
            snap_increment_ptr: *float;

            if scene.editor_mode == .EDIT {
                snap_mode_ptr = *em.op_state.snap_mode;
                snap_increment_ptr = *em.op_state.snap_increment_size;
            } else {
                snap_mode_ptr = *em.obj_op_state.snap_mode;
                snap_increment_ptr = *em.obj_op_state.snap_increment_size;
            }

            old_val := hud.snap_mode_index;

            hud_labeled_dropdown(*cursor, "Snap Mode", SNAP_MODE_NAMES, *hud.snap_mode_index, dropdown_theme, row_height, item_pad, theme, 10400);

            if hud.snap_mode_index != old_val {
                if hud.snap_mode_index == {
                    case 0; snap_mode_ptr.* = .NONE;
                    case 1; snap_mode_ptr.* = .GRID;
                    case 2; snap_mode_ptr.* = .INCREMENT;
                }
                hud.last_known_snap_mode = hud.snap_mode_index;
            }

            if hud.snap_mode_index == 2 {
                text_theme := theme.text_input_theme;

                label_theme := theme.label_theme;
                label_theme.alignment = .Left;
                label_theme.text_color = .{0.7, 0.7, 0.7, 1};

                label(cursor, "Increment:", *label_theme);
                cursor.y -= row_height;

                action, new_text := text_input(cursor, hud.snap_increment_str, *text_theme, 10410);
                if action & .ENTERED {
                    val, success, _ := string_to_float(new_text);
                    if success && val > 0.0 {
                        snap_increment_ptr.* = val;
                        hud_modify_string(*hud.snap_increment_str, new_text);
                    } else {
                        hud_modify_string(*hud.snap_increment_str, tprint("%", snap_increment_ptr.*));
                    }
                }
                cursor.y -= row_height + item_pad;

                slider_theme := theme.slider_theme;
                slider(cursor, snap_increment_ptr, 0.05, 10.0, 0.05, *slider_theme, "", " units");
                cursor.y -= row_height * 1.2;

                current_str_val, str_ok, _ := string_to_float(hud.snap_increment_str);
                if str_ok {
                    diff := abs(current_str_val - snap_increment_ptr.*);
                    if diff > 0.001 {
                        hud_modify_string(*hud.snap_increment_str, tprint("%", snap_increment_ptr.*));
                    }
                }
            }
        } else {
            label_theme := theme.label_theme;
            label_theme.alignment = .Left;
            label_theme.text_color = .{0.5, 0.5, 0.5, 1};
            label(cursor, "No object selected", *label_theme);
            cursor.y -= row_height + item_pad;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Display Toggles
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Display", row_height, theme);

        checkbox_theme := theme.checkbox_theme;

        if base_checkbox(cursor, "Show Grid", hud_show_grid, *checkbox_theme, 10500) {
            hud_show_grid = !hud_show_grid;
        }
        cursor.y -= row_height + item_pad;

        if base_checkbox(cursor, "Show Normals", hud_show_normals, *checkbox_theme, 10501) {
            hud_show_normals = !hud_show_normals;
        }
        cursor.y -= row_height + item_pad;

        if base_checkbox(cursor, "Show Origins", hud_show_origins, *checkbox_theme, 10502) {
            hud_show_origins = !hud_show_origins;
        }
        cursor.y -= row_height + item_pad;

        if base_checkbox(cursor, "Wireframe Overlay", hud_wireframe_overlay, *checkbox_theme, 10503) {
            hud_wireframe_overlay = !hud_wireframe_overlay;
        }
        cursor.y -= row_height + item_pad;

        if base_checkbox(cursor, "Backface Culling", hud_backface_culling, *checkbox_theme, 10504) {
            hud_backface_culling = !hud_backface_culling;
        }
        cursor.y -= row_height + item_pad;
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Launcher
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Launcher", row_height, theme);

        label_theme := theme.label_theme;
        label_theme.alignment = .Left;

        if hud.launcher != null {
            launcher_str := ifx hud.launcher.active then "ACTIVE (ESC to close)" else "Press A to open";
            label(cursor, launcher_str, *label_theme);
        } else {
            label(cursor, "N/A", *label_theme);
        }
        cursor.y -= row_height + item_pad;
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Scene Info
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Scene", row_height, theme);

        label_theme := theme.label_theme;
        label_theme.alignment = .Left;

        label(cursor, tprint("Objects: %", scene.objects.count), *label_theme);
        cursor.y -= row_height + item_pad;

        if em != null {
            vert_count := em.mesh.vertices.count;
            face_count := em.mesh.faces.count;
            label(cursor, tprint("Verts: %  Faces: %", vert_count, face_count), *label_theme);
            cursor.y -= row_height + item_pad;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // SECTION: Shortcuts
    // ─────────────────────────────────────────────────────────────────────
    {
        hud_section_header(*cursor, "Shortcuts", row_height, theme);

        hint_theme := theme.label_theme;
        hint_theme.alignment = .Left;
        hint_theme.text_color = .{0.5, 0.5, 0.5, 1};

        shortcuts :: string.[
            "F = Move",
            "D = Rotate",
            "S = Scale",
            "W/E/R = Axis Z/X/Y",
            "C = Cycle Selection",
            "TAB = Toggle Edit/Object",
            "X = Cycle Snap",
            "A = Launcher",
            "SHIFT+LMB = Multi-select",
        ];

        for shortcuts {
            label(cursor, it, *hint_theme);
            cursor.y -= row_height + item_pad;
        }
    }

    end_scrollable_region(region, cursor.x + cursor.w, cursor.y, *hud.scroll_value);
}

// ============================================================================
// Helpers
// ============================================================================

hud_section_header :: (cursor: *Rect, text: string, row_height: float, theme: *Overall_Theme, loc := #caller_location) {
    label_theme := theme.label_theme;
    label_theme.alignment = .Left;
    label_theme.text_color = .{1.0, 0.85, 0.4, 1.0};
    label(cursor.*, text, *label_theme);
    cursor.y -= row_height;
}

hud_labeled_dropdown :: (cursor: *Rect, label_text: string, names: [] string, value: *s32, dropdown_theme: *Dropdown_Theme, row_height: float, item_pad: float, theme: *Overall_Theme, id: s64, loc := #caller_location) {
    label_theme := theme.label_theme;
    label_theme.alignment = .Left;
    label_theme.text_color = .{0.7, 0.7, 0.7, 1.0};

    label(cursor.*, label_text, *label_theme);
    cursor.y -= row_height;

    dropdown(cursor.*, names, value, dropdown_theme, id, loc=loc);
    cursor.y -= row_height + item_pad;
}

hud_modify_string :: (ps: *string, new_value: string) {
    free(ps.*);
    ps.* = copy_string(new_value);
}

#import "String";
