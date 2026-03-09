/*

So as of right now I render all the objects in the object id buffer and then do edge detection on that, that gives us results similar to blender in the multi-object selected case.

If we want to match blender in the single selectino case we need to not render any of the other objects, in general this means that we'd need a different render pass for picking vs this, but for now this is fine so I'm not going to mess around with it too much.

*/

Object_Id_Selection_Outline :: struct {
    renderer: Object_Id_Selection_Outline_Renderer;
    vao:      GLuint;
}

init :: (using outline: *Object_Id_Selection_Outline) -> bool {
    init(*renderer);
    glGenVertexArrays(1, *vao);
    return true;
}

draw :: (using outline: *Object_Id_Selection_Outline, id_texture_handle: GLuint, selected_id: u32, color: Vector4 = .{1.0, 0.7, 0.0, 1.0}, outline_thickness_px : u32 = 5) {

    if selected_id == NO_OBJECT_ID return;

    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    glUseProgram(renderer.shader_program_gl_handle);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, id_texture_handle);
    set_object_id_texture_uniform(*renderer, 0);
    set_selected_object_id_uniform(*renderer, selected_id);
    set_rgba_color_uniform(*renderer, color);
    set_thickness_px_uniform(*renderer, outline_thickness_px);

    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glBindVertexArray(0);

    glDisable(GL_BLEND);
    glEnable(GL_DEPTH_TEST);
}
