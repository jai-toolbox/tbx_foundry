/*

f = move
d = rotate
s = scale

wer = front right up

tab = cycle selection mode (vertex/edge/face) in edit mode, toggle object/edit mode otherwise

what should I add next... let's say I wanted to create a map in this, 

- look at the scene from the 3 possible views.
- rectangle select.
- improve ui and keybindings, it's hard to use this program.
- set snap increment or whatever
- render the origin being used for an operation.
- cylinder
- move an entire object.
- subdivide face operation
- spin
- inset
- export
- render the locked axis (can use immiedate mode rendering for that).
- snap to grid, and also snap to other vertices in the scene and all that.
- create other objects.
- delete a face
- create a face

all of the above requires a mapping to from wanting to do the thing to doing the thing in code, so we should automate the glue once again.

*/

#import "Basic";
#import "Math";
#import "GL";
#import "GetRect";
#import "Random";
Input :: #import "Input";

#import "Window_Creation";

#import "tbx/engine";
#import "tbx/opengl";
#import "tbx/time";
#import "tbx/geometry";
#import "tbx/camera";
#import "tbx/rectangle";

Transform :: struct {
    position: Vector3;
    scale: Vector3 = .{1, 1, 1};
    rotation: Quaternion = .{0, 0, 0, 1};
}

get_transform_matrix :: (using transform: Transform) -> Matrix4 {
    s := make_scale_matrix4(scale);
    r := rotation_matrix(Matrix4, rotation);
    t := make_translation_matrix4(position);
    return t * r * s;
}

#load "picker.jai";
#load "object_id_selection_outline.jai";
#load "editable_mesh.jai";
#load "operations.jai";
#load "launcher.jai";
#load "hud.jai";

Mode :: enum {
    MOVE_AND_LOOK;
    FREE_MOUSE;
}

snap_round :: (v: float) -> float {
    return floor(v + 0.5);
}

snap_round_to_increment :: (v: float, increment: float) -> float {
    return floor(v / increment + 0.5) * increment;
}

get_selected_vertex_indices :: (em: *Editable_Mesh) -> [..] u32 {
    result: [..] u32;
    result.allocator = temp;

    if em.selection_mode == {
        case .VERTEX;
            for 0..em.selected_vertices.count-1 {
                if em.selected_vertices[it]
                    array_add(*result, cast(u32) it);
            }
        case .EDGE;
            for 0..em.selected_edges.count-1 {
                if em.selected_edges[it] {
                    edge_key := em.edge_map[it];
                    array_add(*result, edge_key.v0);
                    array_add(*result, edge_key.v1);
                }
            }
        case .FACE;
            for face_idx: 0..em.selected_faces.count-1 {
                if em.selected_faces[face_idx] {
                    face := em.mesh.faces[face_idx];
                    start_edge := face.arbitrary_edge;
                    edge := start_edge;
                    while true {
                        array_add(*result, vertex_index(*em.mesh, edge.start_vertex));
                        edge = edge.next_edge_around_face;
                        if edge == start_edge break;
                    }
                }
            }
    }

    return result;
}

apply_snap_grid :: (em: *Editable_Mesh) {
    verts := get_selected_vertex_indices(em);
    for verts {
        pos := *em.mesh.vertices[it].position;
        pos.x = snap_round(pos.x);
        pos.y = snap_round(pos.y);
        pos.z = snap_round(pos.z);
    }
}

apply_snap_increment :: (em: *Editable_Mesh, accumulated_delta: *Vector3, last_snapped_delta: *Vector3, increment: float) {
    verts := get_selected_vertex_indices(em);
    if verts.count == 0 return;

    first := verts[0];
    current_pos := em.mesh.vertices[first].position;
    original_pos := em.op_state.original_positions[first];
    raw_delta := current_pos - original_pos;

    snapped_delta: Vector3;
    snapped_delta.x = snap_round_to_increment(raw_delta.x, increment);
    snapped_delta.y = snap_round_to_increment(raw_delta.y, increment);
    snapped_delta.z = snap_round_to_increment(raw_delta.z, increment);

    correction := snapped_delta - raw_delta;

    for verts {
        pos := *em.mesh.vertices[it].position;
        pos.x += correction.x;
        pos.y += correction.y;
        pos.z += correction.z;
    }


    last_snapped_delta.* = snapped_delta;
}

// helper to check if any operation (edit or object level) is active on a mesh
any_operation_active :: (em: *Editable_Mesh) -> bool {
    return em.op_state.active_op != .NONE || em.obj_op_state.active_op != .NONE;
}

// returns true if the mouse is currently over the hud subwindow and should not be interpreted as a scene interaction (picking, confirming operations, etc.)
mouse_is_over_hud :: (window: Window_Type) -> bool {
    if !hud.subwindow_info.open return false;

    mx, my, ok := get_mouse_pointer_position(window, true);
    if !ok return false;

    r := hud.subwindow_info.rect;
    fx := cast(float) mx;
    fy := cast(float) my;

    return fx >= r.x && fx <= r.x + r.w && fy >= r.y && fy <= r.y + r.h;
}

main :: () {

    defer print("program ended gracefully, if you stop seeing this then something bad happened\n");

    wp3: Windowed_Program_3D;
    wp3.vsync = false;
    wp3.movement_mode = .GOD;
    wp3.window_name = "Foundry";
    init(*wp3);

    mode := Mode.MOVE_AND_LOOK;
    operation_just_confirmed := false;

    point_renderer: Camera_Per_Object_Transform_Position_Point_Color_Renderer;
    init(*point_renderer);

    edge_selection_renderer : Camera_Per_Object_Transform_Color_Renderer;
    init(*edge_selection_renderer);

    face_selection_overlay_renderer : Camera_Per_Object_Transform_Color_Alpha_Renderer;
    init(*face_selection_overlay_renderer);

    // I had to start to new these because of a stack overflow.
    object_id_selection_outline := New(Object_Id_Selection_Outline);
    init(object_id_selection_outline);

    picker: Screen_Space_Object_Picker;
    init(*picker, xx 1920, xx 1080);

    launcher: Launcher;
    init_launcher(*launcher);
    defer deinit_launcher(*launcher);

    scene: Scene;
    init_scene(*scene);
    defer deinit_scene(*scene);

    next_object_id: u32 = 1;

    grid: Camera_Infinite_Grid;
    init(*grid);

    hud_init(
        *wp3.camera_per_object_transform_color_renderer,
        *point_renderer,
        *edge_selection_renderer,
        *face_selection_overlay_renderer,
        *picker
    );
    defer hud_deinit();

    while !wp3.end_program {
        mark_frame_start(*wp3);
        start_section(*wp3.section_timer, "tick");

        per_frame_update(*wp3);

        selected_em := get_selected_object(*scene);

        hud_has_mouse := mouse_is_over_hud(wp3.window);

        // event handling - launcher gets priority when active
        no_op_active := selected_em == null || !any_operation_active(selected_em);
        if !launcher.active && no_op_active && mode == .FREE_MOUSE {
            if is_key_just_pressed(#char "A") {
                open_launcher(*launcher);
            }
        }

        executed_command: *Launcher_Command;
        if launcher.active {
            executed_command = launcher_per_frame_update(*launcher);
        }

        if executed_command != null {
            print("Launcher executed: %\n", executed_command.name);

            if executed_command.name == {
                case "Move";
                    if mode == .FREE_MOUSE && selected_em != null && !any_operation_active(selected_em) {
                        mx, my, _ok := get_mouse_pointer_position(wp3.window, true);
                        if scene.editor_mode == .EDIT {
                            begin_operation(selected_em, .MOVE, xx mx, xx my);
                            selected_em.op_state.snap_accumulated_delta = .{};
                            selected_em.op_state.snap_last_snapped_delta = .{};
                        } else {
                            begin_object_operation(selected_em, .MOVE, xx mx, xx my);
                        }
                    }
                case "Rotate";
                    if mode == .FREE_MOUSE && selected_em != null && !any_operation_active(selected_em) {
                        mx, my, _ok := get_mouse_pointer_position(wp3.window, true);
                        if scene.editor_mode == .EDIT {
                            begin_operation(selected_em, .ROTATE, xx mx, xx my);
                        } else {
                            begin_object_operation(selected_em, .ROTATE, xx mx, xx my);
                        }
                    }
                case "Scale";
                    if mode == .FREE_MOUSE && selected_em != null && !any_operation_active(selected_em) {
                        mx, my, _ok := get_mouse_pointer_position(wp3.window, true);
                        if scene.editor_mode == .EDIT {
                            begin_operation(selected_em, .SCALE, xx mx, xx my);
                        } else {
                            begin_object_operation(selected_em, .SCALE, xx mx, xx my);
                        }
                    }
                case "Select Vertices";
                    if selected_em != null && scene.editor_mode == .EDIT && !any_operation_active(selected_em) {
                        selected_em.selection_mode = .VERTEX;
                        clear_selection(selected_em);
                        update_selection_colors(selected_em);
                        rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                        rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                        rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                    }
                case "Select Edges";
                    if selected_em != null && scene.editor_mode == .EDIT && !any_operation_active(selected_em) {
                        selected_em.selection_mode = .EDGE;
                        clear_selection(selected_em);
                        update_selection_colors(selected_em);
                        rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                        rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                        rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                    }
                case "Select Faces";
                    if selected_em != null && scene.editor_mode == .EDIT && !any_operation_active(selected_em) {
                        selected_em.selection_mode = .FACE;
                        clear_selection(selected_em);
                        update_selection_colors(selected_em);
                        rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                        rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                        rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                    }
                case "Cycle Selection Mode";
                    if selected_em != null && scene.editor_mode == .EDIT && !any_operation_active(selected_em) {
                        if selected_em.selection_mode == {
                            case .VERTEX; selected_em.selection_mode = .EDGE;
                            case .EDGE;   selected_em.selection_mode = .FACE;
                            case .FACE;   selected_em.selection_mode = .VERTEX;
                        }
                        clear_selection(selected_em);
                        update_selection_colors(selected_em);
                        rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                        rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                        rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                    }
                case "Clear Selection";
                    if selected_em != null {
                        clear_selection(selected_em);
                        update_selection_colors(selected_em);
                        rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                        rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                        rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                    }
                case "Snap to Grid";
                    if selected_em != null
                        selected_em.op_state.snap_mode = .GRID;
                case "Snap Increment";
                    if selected_em != null
                        selected_em.op_state.snap_mode = .INCREMENT;
                case "Object Mode";
                    if scene.editor_mode == .EDIT {
                        if selected_em != null {
                            clear_selection(selected_em);
                            update_selection_colors(selected_em);
                            rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                            rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                            rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                        }
                        scene.editor_mode = .OBJECT;
                    }
                case "Edit Mode";
                    if scene.editor_mode == .OBJECT && scene.selected_object >= 0 {
                        scene.editor_mode = .EDIT;
                    }
                case "Create Cube";
                    new_em := New(Editable_Mesh);
                    random_color := Vector3.{
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0
                    };
                    init_editable_mesh(new_em, color = random_color, object_id = next_object_id);
                    next_object_id += 1;
                    make_cube(*new_em.mesh, 1.0);
                    new_em.transform.position = .{0, 0, 0};
                    rebuild_renderables(new_em);
                    buffer_all(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    update_transform(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    add_object(*scene, new_em);
                    old_sel := get_selected_object(*scene);
                    if old_sel != null {
                        set_object_selected(old_sel, false);
                        rebuild_surface_renderable(old_sel);
                        rebuffer_object(*wp3.camera_per_object_transform_color_renderer, old_sel.surface_renderable);
                    }
                    scene.selected_object = cast(s32)(scene.objects.count - 1);
                    set_object_selected(new_em, true);
                    rebuild_surface_renderable(new_em);
                    rebuffer_object(*wp3.camera_per_object_transform_color_renderer, new_em.surface_renderable);
                    scene.editor_mode = .OBJECT;
                case "Create Cylinder";
                    new_em := New(Editable_Mesh);
                    random_color := Vector3.{
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0
                    };
                    init_editable_mesh(new_em, color = random_color, object_id = next_object_id);
                    next_object_id += 1;
                    itp := create_cylinder_between(.{0, -0.5, 0}, .{0, 0.5, 0}, 16, 0.5);
                    new_em.mesh = make_adjacency_mesh_from_itp(*itp);
                    array_reset(*itp.positions);
                    array_reset(*itp.indices);
                    new_em.transform.position = .{0, 0, 0};
                    rebuild_renderables(new_em);
                    buffer_all(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    update_transform(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    add_object(*scene, new_em);
                    old_sel := get_selected_object(*scene);
                    if old_sel != null {
                        set_object_selected(old_sel, false);
                        rebuild_surface_renderable(old_sel);
                        rebuffer_object(*wp3.camera_per_object_transform_color_renderer, old_sel.surface_renderable);
                    }
                    scene.selected_object = cast(s32)(scene.objects.count - 1);
                    set_object_selected(new_em, true);
                    rebuild_surface_renderable(new_em);
                    rebuffer_object(*wp3.camera_per_object_transform_color_renderer, new_em.surface_renderable);
                    scene.editor_mode = .OBJECT;
                case "Create Quad";
                    new_em := New(Editable_Mesh);
                    random_color := Vector3.{
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0
                    };
                    init_editable_mesh(new_em, color = random_color, object_id = next_object_id);
                    next_object_id += 1;

                    // single quad on the xz plane at y=0, wound ccw from above (+y)
                    v0 := make_vertex(*new_em.mesh, .{-0.5, 0, -0.5});
                    v1 := make_vertex(*new_em.mesh, .{ 0.5, 0, -0.5});
                    v2 := make_vertex(*new_em.mesh, .{ 0.5, 0,  0.5});
                    v3 := make_vertex(*new_em.mesh, .{-0.5, 0,  0.5});
                    make_face_from_vertices(*new_em.mesh, .[v0, v3, v2, v1]);
                    link_shared_edges(*new_em.mesh);

                    new_em.transform.position = .{0, 0, 0};
                    rebuild_renderables(new_em);
                    buffer_all(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    update_transform(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    add_object(*scene, new_em);
                    old_sel := get_selected_object(*scene);
                    if old_sel != null {
                        set_object_selected(old_sel, false);
                        rebuild_surface_renderable(old_sel);
                        rebuffer_object(*wp3.camera_per_object_transform_color_renderer, old_sel.surface_renderable);
                    }
                    scene.selected_object = cast(s32)(scene.objects.count - 1);
                    set_object_selected(new_em, true);
                    rebuild_surface_renderable(new_em);
                    rebuffer_object(*wp3.camera_per_object_transform_color_renderer, new_em.surface_renderable);
                    scene.editor_mode = .OBJECT;
                case "Create Circle";
                    new_em := New(Editable_Mesh);
                    random_color := Vector3.{
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0,
                        cast(float)(random_get() % 100) / 100.0
                    };
                    init_editable_mesh(new_em, color = random_color, object_id = next_object_id);
                    next_object_id += 1;

                    // create a 16-vertex ngon on the xz plane at y=0
                    NUM_VERTS :: 16;
                    radius :: 0.5;
                    ngon_verts: [..] *Vertex;
                    ngon_verts.allocator = temp;

                    // create vertices in reverse angle order so winding is ccw from above (+y)
                    for 0..NUM_VERTS-1 {
                        angle := cast(float)(NUM_VERTS - 1 - it) * (2.0 * PI / cast(float) NUM_VERTS);
                        x := radius * cos(angle);
                        z := radius * sin(angle);
                        v := make_vertex(*new_em.mesh, .{x, 0, z});
                        array_add(*ngon_verts, v);
                    }
                    make_face_from_vertices(*new_em.mesh, ngon_verts);
                    link_shared_edges(*new_em.mesh);

                    new_em.transform.position = .{0, 0, 0};
                    rebuild_renderables(new_em);
                    buffer_all(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    update_transform(new_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    add_object(*scene, new_em);
                    old_sel := get_selected_object(*scene);
                    if old_sel != null {
                        set_object_selected(old_sel, false);
                        rebuild_surface_renderable(old_sel);
                        rebuffer_object(*wp3.camera_per_object_transform_color_renderer, old_sel.surface_renderable);
                    }
                    scene.selected_object = cast(s32)(scene.objects.count - 1);
                    set_object_selected(new_em, true);
                    rebuild_surface_renderable(new_em);
                    rebuffer_object(*wp3.camera_per_object_transform_color_renderer, new_em.surface_renderable);
                    scene.editor_mode = .OBJECT;
                case "Extrude";
                    if mode == .FREE_MOUSE && selected_em != null && !any_operation_active(selected_em) && scene.editor_mode == .EDIT {
                        faces_to_extrude: [..] s32;
                        faces_to_extrude.allocator = temp;

                        for 0..selected_em.selected_faces.count-1 {
                            if selected_em.selected_faces[it] {
                                array_add(*faces_to_extrude, cast(s32) it);
                            }
                        }

                        if faces_to_extrude.count > 0 {
                            // before extruding, determine which faces are boundary (all edges have no twin)
                            // so we know where the top face ends up after extrusion.
                            is_boundary: [..] bool;
                            is_boundary.allocator = temp;

                            for faces_to_extrude {
                                face := selected_em.mesh.faces[it];
                                boundary := true;
                                edge := face.arbitrary_edge;
                                while true {
                                    if edge.same_edge_other_face != null {
                                        boundary = false;
                                        break;
                                    }
                                    edge = edge.next_edge_around_face;
                                    if edge == face.arbitrary_edge break;
                                }
                                array_add(*is_boundary, boundary);
                            }

                            // track face count before each extrusion so we can find newly added faces
                            top_face_indices: [..] s32;
                            top_face_indices.allocator = temp;

                            for idx: 0..faces_to_extrude.count-1 {
                                face_idx := faces_to_extrude[idx];
                                faces_before_this := cast(s32) selected_em.mesh.faces.count;

                                face := selected_em.mesh.faces[face_idx];
                                extrude_face(*selected_em.mesh, face, 0.0);

                                if is_boundary[idx] {
                                    // boundary case: original face is bottom, top face is the last face added
                                    last_face := cast(s32)(selected_em.mesh.faces.count - 1);
                                    array_add(*top_face_indices, last_face);
                                } else {
                                    // interior case: original face becomes the top (vertices moved up)
                                    array_add(*top_face_indices, face_idx);
                                }
                            }

                            clear_selection(selected_em);
                            rebuild_renderables(selected_em);
                            resize_selection_arrays(selected_em);

                            for top_face_indices {
                                if it >= 0 && it < selected_em.selected_faces.count {
                                    selected_em.selected_faces[it] = true;
                                }
                            }

                            update_selection_colors(selected_em);

                            unbuffer_all(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                            buffer_all(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                            update_transform(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);

                            mx, my, _ok := get_mouse_pointer_position(wp3.window, true);
                            begin_operation(selected_em, .MOVE, xx mx, xx my);
                            selected_em.op_state.snap_accumulated_delta = .{};
                            selected_em.op_state.snap_last_snapped_delta = .{};
                        } else {
                            log("Extrude: no faces selected");
                        }
                    }
                case "Inset";
                    if mode == .FREE_MOUSE && selected_em != null && !any_operation_active(selected_em) && scene.editor_mode == .EDIT {
                        faces_to_inset: [..] s32;
                        faces_to_inset.allocator = temp;

                        for 0..selected_em.selected_faces.count-1 {
                            if selected_em.selected_faces[it] {
                                array_add(*faces_to_inset, cast(s32) it);
                            }
                        }

                        if faces_to_inset.count > 0 {
                            // inset each selected face. the original face becomes the inner face
                            // (its index stays the same), and connecting quads are added.
                            for < faces_to_inset {
                                face := selected_em.mesh.faces[it];
                                inset_face(*selected_em.mesh, face, 0.25);
                            }

                            // the original face indices are now the inner faces, so we re-select them
                            clear_selection(selected_em);
                            rebuild_renderables(selected_em);
                            resize_selection_arrays(selected_em);

                            for faces_to_inset {
                                if it >= 0 && it < selected_em.selected_faces.count {
                                    selected_em.selected_faces[it] = true;
                                }
                            }

                            update_selection_colors(selected_em);

                            unbuffer_all(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                            buffer_all(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                            update_transform(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);

                            // start scale operation so user can interactively resize the inner face
                            mx, my, _ok := get_mouse_pointer_position(wp3.window, true);
                            begin_operation(selected_em, .SCALE, xx mx, xx my);
                        } else {
                            log("Inset: no faces selected");
                        }
                    }
            }
        }

        // normal input handling (only when launcher is not active)
        if !launcher.active {

            // TAB toggles between object mode and edit mode
            if is_key_just_pressed(.TAB) && (selected_em == null || !any_operation_active(selected_em)) {
                if scene.editor_mode == .OBJECT {
                    // enter edit mode (only if an object is selected)
                    if scene.selected_object >= 0 {
                        scene.editor_mode = .EDIT;
                    }
                } else {
                    // exit edit mode back to object mode
                    if selected_em != null {
                        clear_selection(selected_em);
                        update_selection_colors(selected_em);
                        rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                        rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                        rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                    }
                    scene.editor_mode = .OBJECT;
                }
            }

            // c cycles selection mode in edit mode
            if scene.editor_mode == .EDIT && selected_em != null {
                if is_key_just_pressed(#char "C") && !any_operation_active(selected_em) {
                    if selected_em.selection_mode == {
                        case .VERTEX; selected_em.selection_mode = .EDGE;
                        case .EDGE;   selected_em.selection_mode = .FACE;
                        case .FACE;   selected_em.selection_mode = .VERTEX;
                    }

                    clear_selection(selected_em);
                    update_selection_colors(selected_em);
                    rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                    rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                    rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                }
            }

            if is_key_just_pressed(.ESCAPE) {
                if selected_em != null {
                    if scene.editor_mode == .EDIT && selected_em.op_state.active_op != .NONE {
                        cancel_operation(selected_em);
                        sync_positions_from_mesh(selected_em);
                        rebuild_renderables(selected_em);
                        rebuffer_all(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                    } else if scene.editor_mode == .OBJECT && selected_em.obj_op_state.active_op != .NONE {
                        cancel_object_operation(selected_em);
                    }
                }
            }

            // mode toggle / cancel on right click, I should probably change this maybe?
            if is_key_just_pressed(.MOUSE_BUTTON_RIGHT) {
                cancel_happened := false;

                if selected_em != null {
                    if scene.editor_mode == .EDIT && selected_em.op_state.active_op != .NONE {
                        cancel_operation(selected_em);
                        sync_positions_from_mesh(selected_em);
                        rebuild_renderables(selected_em);
                        rebuffer_all(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
                        cancel_happened = true;
                    } else if scene.editor_mode == .OBJECT && selected_em.obj_op_state.active_op != .NONE {
                        cancel_object_operation(selected_em);
                        cancel_happened = true;
                    }
                }

                if !cancel_happened {
                    wp3.camera_look_active = !wp3.camera_look_active;
                    mode = ifx mode == .MOVE_AND_LOOK then .FREE_MOUSE else .MOVE_AND_LOOK;
                }
            }

            // operations only in free mouse mode
            if mode == .FREE_MOUSE {

                if scene.editor_mode == .OBJECT {

                    if selected_em != null && selected_em.obj_op_state.active_op == .NONE {
                        mx, my, _ok := get_mouse_pointer_position(wp3.window, true);

                        if is_key_just_pressed(#char "F") {
                            begin_object_operation(selected_em, .MOVE, xx mx, xx my);
                        }
                        if is_key_just_pressed(#char "D") {
                            begin_object_operation(selected_em, .ROTATE, xx mx, xx my);
                        }
                        if is_key_just_pressed(#char "S") {
                            begin_object_operation(selected_em, .SCALE, xx mx, xx my);
                        }
                    }

                    // cycle snap mode with X
                    if is_key_just_pressed(#char "X") {
                        if selected_em != null {
                            if selected_em.obj_op_state.snap_mode == {
                                case .NONE;      selected_em.obj_op_state.snap_mode = .GRID;
                                case .GRID;      selected_em.obj_op_state.snap_mode = .INCREMENT;
                                case .INCREMENT; selected_em.obj_op_state.snap_mode = .NONE;
                            }
                        }
                    }

                    // apply active object operation every frame
                    if selected_em != null && selected_em.obj_op_state.active_op != .NONE {
                        mx, my, _ok := get_mouse_pointer_position(wp3.window, true);

                        if is_key_just_pressed(#char "W") selected_em.obj_op_state.axis_constraint = 2;
                        if is_key_just_pressed(#char "E") selected_em.obj_op_state.axis_constraint = 0;
                        if is_key_just_pressed(#char "R") selected_em.obj_op_state.axis_constraint = 1;

                        if selected_em.obj_op_state.active_op == {
                            case .MOVE;
                                apply_object_move(selected_em, xx mx, xx my, *wp3.camera, wp3.window_width, wp3.window_height);
                            case .ROTATE;
                                apply_object_rotate(selected_em, xx mx, xx my);
                            case .SCALE;
                                apply_object_scale(selected_em, xx mx, xx my);
                        }

                        // only confirm operation if mouse is not over the hud
                        if is_key_just_pressed(.MOUSE_BUTTON_LEFT) && !hud_has_mouse {
                            confirm_object_operation(selected_em);
                            operation_just_confirmed = true;
                        }
                    }

                    // object picking (click to select object), skip if mouse is over HUD
                    if is_key_just_pressed(.MOUSE_BUTTON_LEFT) && !hud_has_mouse && (selected_em == null || selected_em.obj_op_state.active_op == .NONE) {
                        if operation_just_confirmed {
                            operation_just_confirmed = false;
                        } else {
                            mx, my, mouse_success := get_mouse_pointer_position(wp3.window, true);
                            picked_id := pick_closest_in_radius(*picker, xx mx, xx my);

                            if picked_id != NO_OBJECT_ID {
                                // find which object has this object_id
                                found := false;
                                for obj, obj_idx: scene.objects {
                                    if obj.object_id == cast(u32) picked_id {
                                        // deselect old
                                        old := get_selected_object(*scene);
                                        if old != null {
                                            set_object_selected(old, false);
                                            rebuild_surface_renderable(old);
                                            rebuffer_object(*wp3.camera_per_object_transform_color_renderer, old.surface_renderable);
                                        }
                                        // select new
                                        scene.selected_object = cast(s32) obj_idx;
                                        set_object_selected(obj, true);
                                        rebuild_surface_renderable(obj);
                                        rebuffer_object(*wp3.camera_per_object_transform_color_renderer, obj.surface_renderable);
                                        found = true;
                                        break;
                                    }
                                }
                                if !found {
                                    // deselect
                                    old := get_selected_object(*scene);
                                    if old != null {
                                        set_object_selected(old, false);
                                        rebuild_surface_renderable(old);
                                        rebuffer_object(*wp3.camera_per_object_transform_color_renderer, old.surface_renderable);
                                    }
                                    scene.selected_object = -1;
                                }
                            } else {
                                if !is_key_down(.SHIFT) {
                                    old := get_selected_object(*scene);
                                    if old != null {
                                        set_object_selected(old, false);
                                        rebuild_surface_renderable(old);
                                        rebuffer_object(*wp3.camera_per_object_transform_color_renderer, old.surface_renderable);
                                    }
                                    scene.selected_object = -1;
                                }
                            }
                        }
                    }
                }

                if scene.editor_mode == .EDIT && selected_em != null {

                    // start new edit operations
                    if selected_em.op_state.active_op == .NONE {
                        mx, my, _ok := get_mouse_pointer_position(wp3.window, true);

                        if is_key_just_pressed(#char "F") {
                            begin_operation(selected_em, .MOVE, xx mx, xx my);
                            selected_em.op_state.snap_accumulated_delta = .{};
                            selected_em.op_state.snap_last_snapped_delta = .{};
                        }
                        if is_key_just_pressed(#char "D") {
                            begin_operation(selected_em, .ROTATE, xx mx, xx my);
                        }
                        if is_key_just_pressed(#char "S") {
                            begin_operation(selected_em, .SCALE, xx mx, xx my);
                        }
                    }

                    if is_key_just_pressed(#char "X") {
                        if selected_em.op_state.snap_mode == {
                            case .NONE;      selected_em.op_state.snap_mode = .GRID;
                            case .GRID;      selected_em.op_state.snap_mode = .INCREMENT;
                            case .INCREMENT; selected_em.op_state.snap_mode = .NONE;
                        }
                    }

                    // apply active edit operation every frame
                    if selected_em.op_state.active_op != .NONE {
                        mx, my, _ok := get_mouse_pointer_position(wp3.window, true);

                        if is_key_just_pressed(#char "W") selected_em.op_state.axis_constraint = 2;
                        if is_key_just_pressed(#char "E") selected_em.op_state.axis_constraint = 0;
                        if is_key_just_pressed(#char "R") selected_em.op_state.axis_constraint = 1;

                        if selected_em.op_state.active_op == {
                            case .MOVE;
                                apply_move(selected_em, xx mx, xx my, *wp3.camera, wp3.window_width, wp3.window_height);
                            case .ROTATE;
                                apply_rotate(selected_em, xx mx, xx my, *wp3.camera);
                            case .SCALE;
                                apply_scale(selected_em, xx mx, xx my);
                        }

                        // apply snapping for move operations
                        if selected_em.op_state.active_op == .MOVE {
                            if selected_em.op_state.snap_mode == {
                                case .GRID;
                                    apply_snap_grid(selected_em);
                                case .INCREMENT;
                                    apply_snap_increment(selected_em, *selected_em.op_state.snap_accumulated_delta, *selected_em.op_state.snap_last_snapped_delta, selected_em.op_state.snap_increment_size);
                            }
                        }

                        sync_positions_from_mesh(selected_em);
                        rebuild_renderables(selected_em);
                        update_selection_colors(selected_em);
                        rebuffer_all(selected_em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);

                        // only confirm operation if mouse is not over the hud
                        if is_key_just_pressed(.MOUSE_BUTTON_LEFT) && !hud_has_mouse {
                            confirm_operation(selected_em);
                            operation_just_confirmed = true;
                        }
                    }

                    // picking in edit mode, only when no operation is active, skip if mouse is over HUD
                    if is_key_just_pressed(.MOUSE_BUTTON_LEFT) && !hud_has_mouse && selected_em.op_state.active_op == .NONE {
                        if operation_just_confirmed {
                            operation_just_confirmed = false;
                        } else {
                            mx, my, mouse_success := get_mouse_pointer_position(wp3.window, true);
                            picked_id := pick_closest_in_radius(*picker, xx mx, xx my);

                            if picked_id != NO_OBJECT_ID {
                                if is_key_down(.SHIFT) {
                                    handle_picking(selected_em, cast(u32) picked_id);
                                } else {
                                    clear_selection(selected_em);
                                    handle_picking(selected_em, cast(u32) picked_id);
                                }
                            } else {
                                if !is_key_down(.SHIFT) {
                                    clear_selection(selected_em);
                                    update_selection_colors(selected_em);
                                }
                            }

                            // rebuffer the appropriate selection renderable
                            if selected_em.selection_mode == {
                                case .VERTEX;
                                    rebuffer_object(*point_renderer, selected_em.vertex_selection_renderable);
                                case .EDGE;
                                    rebuffer_object(*edge_selection_renderer, selected_em.edge_selection_renderable);
                                case .FACE;
                                    rebuffer_object(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable);
                            }
                        }
                    }
                }

            } // end if mode == .FREE_MOUSE

        } // end if !launcher.active

        // sync transforms for all objects (every frame, before rendering)
        for scene.objects {
            update_transform(it, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
        }


        // rendering
        
        // this needs to be simplified

        // set camera uniforms for point renderer (vertex selection display)
        glUseProgram(point_renderer.shader_program_gl_handle);
        set_point_size_uniform(*point_renderer, 6.0);
        set_world_to_camera_uniform(*point_renderer, wp3.camera.world_to_camera);
        set_camera_to_clip_uniform(*point_renderer, wp3.camera.camera_to_clip);

        // set camera uniforms for edge selection renderer
        glUseProgram(edge_selection_renderer.shader_program_gl_handle);
        set_world_to_camera_uniform(*edge_selection_renderer, wp3.camera.world_to_camera);
        set_camera_to_clip_uniform(*edge_selection_renderer, wp3.camera.camera_to_clip);

        // set camera uniforms for face selection overlay renderer
        glUseProgram(face_selection_overlay_renderer.shader_program_gl_handle);
        set_world_to_camera_uniform(*face_selection_overlay_renderer, wp3.camera.world_to_camera);
        set_camera_to_clip_uniform(*face_selection_overlay_renderer, wp3.camera.camera_to_clip);

        // queue selection renderables only in edit mode for the selected object
        if scene.editor_mode == .EDIT && selected_em != null {
            if selected_em.selection_mode == {
                case .VERTEX;
                    queue_render(*point_renderer, selected_em.vertex_selection_renderable.object_index);
                    queue_render(*edge_selection_renderer, selected_em.edge_selection_renderable.object_index);
                case .EDGE;
                    queue_render(*edge_selection_renderer, selected_em.edge_selection_renderable.object_index);
                case .FACE;
                    queue_render(*edge_selection_renderer, selected_em.edge_selection_renderable.object_index);
                    queue_render(*face_selection_overlay_renderer, selected_em.face_selection_overlay_renderable.object_index);
            }
        }

        // picking pass
        glUseProgram(picker.renderer.shader_program_gl_handle);
        set_world_to_camera_uniform(*picker.renderer, wp3.camera.world_to_camera);
        set_camera_to_clip_uniform(*picker.renderer, wp3.camera.camera_to_clip);
        set_point_size_uniform(*picker.renderer, 6.0);

        enable_writing(*picker);
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_PROGRAM_POINT_SIZE);

        if scene.editor_mode == .OBJECT {
            // in object mode, render all object picking renderables
            for scene.objects {
                queue_render(*picker.renderer, it.object_picking_renderable.object_index);
            }
            render(*picker.renderer, GL_TRIANGLES);
        } else if scene.editor_mode == .EDIT && selected_em != null {
            // in edit mode, render sub-element picking for the selected object
            if selected_em.selection_mode == {
                case .VERTEX;
                    queue_render(*picker.renderer, selected_em.vertex_selection_picking_renderable.object_index);
                    render(*picker.renderer, GL_POINTS);
                case .EDGE;
                    queue_render(*picker.renderer, selected_em.edge_selection_picking_renderable.object_index);
                    render(*picker.renderer, GL_LINES);
                case .FACE;
                    queue_render(*picker.renderer, selected_em.face_selection_picking_renderable.object_index);
                    render(*picker.renderer, GL_TRIANGLES);
            }
        }

        disable_writing();

        for scene.objects {
            queue_render(*wp3.camera_per_object_transform_color_renderer, it.surface_renderable.object_index);
        }

        Simp :: #import "Simp";
        Simp.update_window(wp3.window);
        Simp.clear_render_target(.15, .08, .08, 1);

        if wp3.current_menu == .NONE {
            glDepthMask(GL_TRUE);
            glEnable(GL_DEPTH_TEST);
            glClear(GL_DEPTH_BUFFER_BIT);

            render(*wp3.camera_per_object_transform_color_renderer);

            // render the active selection overlay (only in edit mode)
            if scene.editor_mode == .EDIT && selected_em != null {
                if selected_em.selection_mode == {
                    case .VERTEX;
                        glEnable(GL_PROGRAM_POINT_SIZE);
                        render(*point_renderer);
                        render(*edge_selection_renderer, GL_LINES);
                    case .EDGE;
                        render(*edge_selection_renderer, GL_LINES);
                    case .FACE;
                        // render edge wireframe as visual aid (non-selectable)
                        render(*edge_selection_renderer, GL_LINES);

                        glEnable(GL_BLEND);
                        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                        glDepthMask(GL_FALSE);
                        glDepthFunc(GL_LEQUAL);
                        render(*face_selection_overlay_renderer);
                        glDepthFunc(GL_LESS);
                        glDepthMask(GL_TRUE);
                        glDisable(GL_BLEND);
                }
            }

            // conditionally render the grid based on hud toggle
            if hud_show_grid {
                glDepthMask(GL_FALSE);
                render(*grid,
                    wp3.camera.camera_to_clip,
                    wp3.camera.world_to_camera,
                    wp3.camera.position
                );
                glDepthMask(GL_TRUE);
            }

            // draw selection outline in object mode
            if scene.editor_mode == .OBJECT && scene.selected_object >= 0 {
                sel := get_selected_object(*scene);
                if sel != null {
                    draw(object_id_selection_outline, picker.picking_texture_handle, sel.object_id);
                }
            }

            if hud_backface_culling {
                glEnable(GL_CULL_FACE);
            } else {
                glDisable(GL_CULL_FACE);
            }

            context.simp.current_shader = null;

            render_tick_stats(*wp3);
            render_movement_stats(*wp3);
            render_camera_stats(*wp3);

            hud_update_and_draw(
                *wp3.wp,
                *scene,
                selected_em,
                *mode,
                *launcher,
                wp3.window_width,
                wp3.window_height,
                *wp3.wp.my_theme
            );

            draw_popups();  // required for getrect dropdowns and subwindows

            update_graph_visual(*wp3.performance_graph);
            render_performance_graph(*wp3);

            render_launcher(*launcher, *wp3.wp);
        } else {
            context.simp.current_shader = null;
            render_menus(*wp3.wp);
        }

        Simp.swap_buffers(wp3.window, false);

        sleep_to_maintain_max_fps(*wp3);
        mark_frame_end(*wp3);
        end_section(*wp3.section_timer, "tick");
    }

    for scene.objects {
        destroy_editable_mesh(it);
        free(it);
    }
    deinit_scene(*scene);
    deinit(*grid);
}


elapsed_seconds :: (start_time: Apollo_Time) -> float {
    now := current_time_monotonic();
    return cast(float) to_float64_seconds(now - start_time);
}

make_rotation_matrix4 :: (axis: Vector3, angle: float) -> Matrix4 {
    q: Quaternion;
    set_from_axis_and_angle(*q, axis, angle);
    return rotation_matrix(Matrix4, q);
}

make_transform_matrix4 :: (translation: Vector3, rotation_axis: Vector3, rotation_angle: float) -> Matrix4 {
    return make_translation_matrix4(translation) * make_rotation_matrix4(rotation_axis, rotation_angle);
}
