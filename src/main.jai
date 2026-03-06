/*

f = move
d = rotate
s = scale

wer = front right up

tab = cycle selection mode (vertex/edge/face)

*/

#import "Basic";
#import "Math";
#import "GL";

#import "Window_Creation";

#import "tbx/engine";
#import "tbx/opengl";
#import "tbx/time";
#import "tbx/geometry";
#import "tbx/camera";

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
#load "editable_mesh.jai";
#load "operations.jai";

Mode :: enum {
    MOVE_AND_LOOK;
    FREE_MOUSE;
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

    // edge selection renderer (using color renderer for now, will switch to line color renderer later)
    // edge_selection_renderer: Camera_Per_Object_Transform_Line_Color_Renderer;
    edge_selection_renderer: Camera_Per_Object_Transform_Color_Renderer;
    init(*edge_selection_renderer);

    // face selection overlay renderer (using color renderer for now, will switch to color alpha renderer later)
    face_selection_overlay_renderer: Camera_Per_Object_Transform_Color_Alpha_Renderer;
    init(*face_selection_overlay_renderer);

    picker: Screen_Space_Object_Picker;
    init(*picker, xx 1920, xx 1080);

    // create an editable cube
    em: Editable_Mesh;
    init_editable_mesh(*em, color = .{0.2, 0.6, 0.9});
    make_cube(*em.mesh, 1.0);
    rebuild_renderables(*em);
    buffer_all(*em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);

    grid: Camera_Infinite_Grid;
    init(*grid);

    while !wp3.end_program {
        mark_frame_start(*wp3);
        start_section(*wp3.section_timer, "tick");

        per_frame_update(*wp3);

        // object transform movement via arrow keys
        moved := false;
        offset: Vector3;

        if is_key_just_pressed(.ARROW_UP)    { offset.y += 0.25; moved = true; }
        if is_key_just_pressed(.ARROW_DOWN)  { offset.y -= 0.25; moved = true; }
        if is_key_just_pressed(.ARROW_RIGHT) { offset.x += 0.25; moved = true; }
        if is_key_just_pressed(.ARROW_LEFT)  { offset.x -= 0.25; moved = true; }

        if moved {
            em.transform.position += offset;
            // update_transform(*em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
        }

        // cycle selection mode with tab
        if is_key_just_pressed(.TAB) && em.op_state.active_op == .NONE {
            unbuffer_active_picking_renderable(*em, *picker);

            if em.selection_mode == {
                case .VERTEX; em.selection_mode = .EDGE;
                case .EDGE;   em.selection_mode = .FACE;
                case .FACE;   em.selection_mode = .VERTEX;
            }

            clear_selection(*em);
            update_selection_colors(*em);
            buffer_active_picking_renderable(*em, *picker);
            rebuffer_object(*point_renderer, em.vertex_selection_renderable);
            rebuffer_object(*edge_selection_renderer, em.edge_selection_renderable);
            rebuffer_object(*face_selection_overlay_renderer, em.face_selection_overlay_renderable);
        }

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

        // queue the appropriate selection renderable based on mode
        if em.selection_mode == {
            case .VERTEX;
                queue_render(*point_renderer, em.vertex_selection_renderable.object_index);
            case .EDGE;
                queue_render(*edge_selection_renderer, em.edge_selection_renderable.object_index);
            case .FACE;
                queue_render(*edge_selection_renderer, em.edge_selection_renderable.object_index);
                queue_render(*face_selection_overlay_renderer, em.face_selection_overlay_renderable.object_index);
        }

        // picking pass
        glUseProgram(picker.renderer.shader_program_gl_handle);
        set_world_to_camera_uniform(*picker.renderer, wp3.camera.world_to_camera);
        set_camera_to_clip_uniform(*picker.renderer, wp3.camera.camera_to_clip);
        set_point_size_uniform(*picker.renderer, 6.0);

        enable_writing(*picker);
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_PROGRAM_POINT_SIZE);

        // queue the active picking renderable based on selection mode
        if em.selection_mode == {
            case .VERTEX;
                queue_render(*picker.renderer, em.vertex_selection_picking_renderable.object_index);
                render(*picker.renderer, GL_POINTS);
            case .EDGE;
                queue_render(*picker.renderer, em.edge_selection_picking_renderable.object_index);
                render(*picker.renderer, GL_LINES);
            case .FACE;
                queue_render(*picker.renderer, em.face_selection_picking_renderable.object_index);
                render(*picker.renderer, GL_TRIANGLES);
        }

        disable_writing();

        // cancel on escape
        if is_key_just_pressed(.ESCAPE) {
            if em.op_state.active_op != .NONE {
                cancel_operation(*em);
                sync_positions_from_mesh(*em);
                rebuild_renderables(*em);
                rebuffer_all(*em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
            }
        }

        // mode toggle / cancel on right click
        if is_key_just_pressed(.MOUSE_BUTTON_RIGHT) {
            if em.op_state.active_op != .NONE {
                cancel_operation(*em);
                sync_positions_from_mesh(*em);
                rebuild_renderables(*em);
                rebuffer_all(*em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);
            } else {
                wp3.camera_look_active = !wp3.camera_look_active;
                mode = ifx mode == .MOVE_AND_LOOK then .FREE_MOUSE else .MOVE_AND_LOOK;
            }
        }

        // operations only in free mouse mode
        if mode == .FREE_MOUSE {

            // start new operations
            if em.op_state.active_op == .NONE {
                mx, my, _ok := get_mouse_pointer_position(wp3.window, true);

                if is_key_just_pressed(#char "F")  begin_operation(*em, .MOVE,   xx mx, xx my);
                if is_key_just_pressed(#char "D")  begin_operation(*em, .ROTATE, xx mx, xx my);
                if is_key_just_pressed(#char "S")  begin_operation(*em, .SCALE,  xx mx, xx my);
            }

            // apply active operation every frame
            if em.op_state.active_op != .NONE {
                mx, my, _ok := get_mouse_pointer_position(wp3.window, true);

                if is_key_just_pressed(#char "W") em.op_state.axis_constraint = 2;
                if is_key_just_pressed(#char "E") em.op_state.axis_constraint = 0;
                if is_key_just_pressed(#char "R") em.op_state.axis_constraint = 1;

                if em.op_state.active_op == {
                    case .MOVE;
                        apply_move(*em, xx mx, xx my, *wp3.camera, wp3.window_width, wp3.window_height);
                    case .ROTATE;
                        apply_rotate(*em, xx mx, xx my, *wp3.camera);
                    case .SCALE;
                        apply_scale(*em, xx mx, xx my);
                }

                sync_positions_from_mesh(*em);
                rebuild_renderables(*em);
                update_selection_colors(*em);
                rebuffer_all(*em, *wp3.camera_per_object_transform_color_renderer, *point_renderer, *edge_selection_renderer, *face_selection_overlay_renderer, *picker);

                if is_key_just_pressed(.MOUSE_BUTTON_LEFT) {
                    confirm_operation(*em);
                    operation_just_confirmed = true;
                }
            }
        }

        // picking, only when no operation is active
        if is_key_just_pressed(.MOUSE_BUTTON_LEFT) && em.op_state.active_op == .NONE {
            if operation_just_confirmed {
                operation_just_confirmed = false;
            } else {
                mx, my, mouse_success := get_mouse_pointer_position(wp3.window, true);
                picked_id := pick_closest_in_radius(*picker, xx mx, xx my);

                if picked_id != NO_OBJECT_ID {
                    if is_key_down(.SHIFT) {
                        handle_picking(*em, cast(u32) picked_id);
                    } else {
                        clear_selection(*em);
                        handle_picking(*em, cast(u32) picked_id);
                    }
                } else {
                    if !is_key_down(.SHIFT) {
                        clear_selection(*em);
                        update_selection_colors(*em);
                    }
                }

                // rebuffer the appropriate selection renderable
                if em.selection_mode == {
                    case .VERTEX;
                        rebuffer_object(*point_renderer, em.vertex_selection_renderable);
                    case .EDGE;
                        rebuffer_object(*edge_selection_renderer, em.edge_selection_renderable);
                    case .FACE;
                        rebuffer_object(*face_selection_overlay_renderer, em.face_selection_overlay_renderable);
                }
            }
        }

        queue_render(*wp3.camera_per_object_transform_color_renderer, em.surface_renderable.object_index);

        Simp :: #import "Simp";
        Simp.update_window(wp3.window);
        Simp.clear_render_target(.15, .08, .08, 1);

        if wp3.current_menu == .NONE {
            glDepthMask(GL_TRUE);
            glEnable(GL_DEPTH_TEST);
            glClear(GL_DEPTH_BUFFER_BIT);

            render(*wp3.camera_per_object_transform_color_renderer);

            // render the active selection overlay
            if em.selection_mode == {
                case .VERTEX;
                    glEnable(GL_PROGRAM_POINT_SIZE);
                    render(*point_renderer);
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

            glDepthMask(GL_FALSE);
            render(*grid,
                wp3.camera.camera_to_clip,
                wp3.camera.world_to_camera,
                wp3.camera.position
            );
            glDepthMask(GL_TRUE);

            context.simp.current_shader = null;

            render_tick_stats(*wp3);
            render_movement_stats(*wp3);
            render_camera_stats(*wp3);
            update_graph_visual(*wp3.performance_graph);
            render_performance_graph(*wp3);
        } else {
            context.simp.current_shader = null;
            render_menus(*wp3.wp);
        }

        Simp.swap_buffers(wp3.window, false);

        sleep_to_maintain_max_fps(*wp3);
        mark_frame_end(*wp3);
        end_section(*wp3.section_timer, "tick");
    }

    destroy_editable_mesh(*em);
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
