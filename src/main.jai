#import "Basic";
#import "Math";
#import "GL";

#import "tbx/engine";
#import "tbx/opengl";
#import "tbx/model_loading";
#import "tbx/time";
#import "tbx/texture_packing";

main :: () {

    pack_textures(4096);

    defer print("Program ended gracefully, if you stop seeing this then something bad happened.\n");

    wp3: Windowed_Program_3D;
    wp3.vsync = false;
    wp3.movement_mode = .GOD;
    wp3.window_name = "Foundry";
    init(*wp3);

    packed_rendering: Packed_Texture_Rendering;
    init(*packed_rendering);

    // todo it might be nice in the future to not have to do this in multiple steps

    model := load_wavefront_model("data/spot");
    // model := load_wavefront_model("data/sam_max/sam_max");

    new_renderables := load_wavefront_into_packed_texture_renderables(
        *model,
        *packed_rendering.metadata,
        *packed_rendering.renderer
    );

    for new_renderables {
        array_add(*packed_rendering.renderables, it);
    }

    start_time := current_time_monotonic();

    while !wp3.end_program {
        mark_frame_start(*wp3);
        start_section(*wp3.section_timer, "tick");

        per_frame_update(*wp3);

        // set the packed texture renderer's camera uniforms to match the same camera the 3d program uses
        // use the packed texture shader so that uniform calls apply to it
        glUseProgram(packed_rendering.renderer.shader_program_gl_handle);
        set_world_to_camera_uniform(*packed_rendering.renderer, wp3.camera.world_to_camera);
        set_camera_to_clip_uniform(*packed_rendering.renderer, wp3.camera.camera_to_clip);

        for packed_rendering.renderables queue_render(*packed_rendering.renderer, it.object_index); 

        // spin the model for fun I guess
        elapsed := elapsed_seconds(start_time);
        for packed_rendering.renderables {
            // transform := make_transform_matrix4(.{0, 0, 0}, .{0, 0, 1}, elapsed * TAU * 0.1);
            // set_local_to_world_matrix(*packed_rendering.renderer, it, transform);
        }

        Simp :: #import "Simp";
        Simp.update_window(wp3.window);
        Simp.clear_render_target(.15, .08, .08, 1);

        if wp3.current_menu == .NONE {
            // enable writing to the depth buffer so closer geometry occludes further geometry
            glDepthMask(GL_TRUE);

            // turn on depth testing so fragments behind other fragments get discarded
            glEnable(GL_DEPTH_TEST);

            // clear the depth buffer so we start fresh each frame
            glClear(GL_DEPTH_BUFFER_BIT);

            // render the built in color renderer objects if there are any
            render(*wp3.camera_per_object_transform_color_renderer);

            render(*packed_rendering);

            // reset simp's internal shader tracking so it rebinds its own shaders correctly after our custom rendering
            context.simp.current_shader = null;

            render_tick_stats(*wp3);
            render_movement_stats(*wp3);
            render_camera_stats(*wp3);
            update_graph_visual(*wp3.performance_graph);
            render_performance_graph(*wp3);
        } else {
            // reset simp's shader tracking before drawing menus
            context.simp.current_shader = null;
            render_menus(*wp3.wp);
        }

        // present the rendered frame to the screen
        Simp.swap_buffers(wp3.window, false);

        sleep_to_maintain_max_fps(*wp3);
        mark_frame_end(*wp3);
        end_section(*wp3.section_timer, "tick");
    }
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
