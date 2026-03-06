

#import "GL";
#import "Basic";

NO_OBJECT_ID :: 0;

Screen_Space_Object_Picker :: struct {
    frame_buffer_handle:    GLuint;
    picking_texture_handle: GLuint;
    depth_texture_handle:   GLuint;
    width:                  u32;
    height:                 u32;
    
    renderer: Camera_Per_Object_Transform_Object_Id_Renderer;
}

init :: (using picker: *Screen_Space_Object_Picker, window_width_px: u32, window_height_px: u32) -> bool {
    width  = window_width_px;
    height = window_height_px;

    glGenFramebuffers(1, *frame_buffer_handle);
    glBindFramebuffer(GL_FRAMEBUFFER, frame_buffer_handle);

    glGenTextures(1, *picking_texture_handle);
    glBindTexture(GL_TEXTURE_2D, picking_texture_handle);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R32UI, xx window_width_px, xx window_height_px, 0, GL_RED_INTEGER, GL_UNSIGNED_INT, null);

    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, picking_texture_handle, 0);

    glGenTextures(1, *depth_texture_handle);
    glBindTexture(GL_TEXTURE_2D, depth_texture_handle);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, xx window_width_px, xx window_height_px, 0, GL_DEPTH_COMPONENT, GL_FLOAT, null);

    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth_texture_handle, 0);

    status := glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if status != GL_FRAMEBUFFER_COMPLETE {
        log_error("Picking framebuffer incomplete, status: 0x%", formatInt(status, base = 16));
        return false;
    }

    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    init(*renderer);

    return true;
}

resize :: (using picker: *Screen_Space_Object_Picker, new_width: u32, new_height: u32) -> bool {

    // reset and initialize.

    if picking_texture_handle  glDeleteTextures(1, *picking_texture_handle);
    if depth_texture_handle    glDeleteTextures(1, *depth_texture_handle);
    if frame_buffer_handle     glDeleteFramebuffers(1, *frame_buffer_handle);

    picking_texture_handle = 0;
    depth_texture_handle   = 0;
    frame_buffer_handle    = 0;

    return init(picker, new_width, new_height);
}

enable_writing :: (using picker: *Screen_Space_Object_Picker) {
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, frame_buffer_handle);

    clear_value: u32 = NO_OBJECT_ID;
    glClearBufferuiv(GL_COLOR, 0, *clear_value);
    glClear(GL_DEPTH_BUFFER_BIT);
}

disable_writing :: () {
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
}

read_pixel :: (using picker: *Screen_Space_Object_Picker, x: u32, y: u32) -> u32 {
    if x >= width || y >= height  return NO_OBJECT_ID;

    flipped_y := height - y - 1;
    flipped_y = y;

    glBindFramebuffer(GL_READ_FRAMEBUFFER, frame_buffer_handle);
    glReadBuffer(GL_COLOR_ATTACHMENT0);

    object_id: u32;
    glReadPixels(xx x, xx flipped_y, 1, 1, GL_RED_INTEGER, GL_UNSIGNED_INT, *object_id);

    glReadBuffer(GL_NONE);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);

    return object_id;
}


read_region :: (using picker: *Screen_Space_Object_Picker, x: u32, y: u32, w: u32, h: u32, buffer: [] u32) {
    if w == 0 || h == 0  return;

    glBindFramebuffer(GL_READ_FRAMEBUFFER, frame_buffer_handle);
    glReadBuffer(GL_COLOR_ATTACHMENT0);

    glReadPixels(xx x, xx y, xx w, xx h, GL_RED_INTEGER, GL_UNSIGNED_INT, buffer.data);

    glReadBuffer(GL_NONE);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
}

pick_closest_in_radius :: (picker: *Screen_Space_Object_Picker, mouse_x: s32, mouse_y: s32, radius: s32 = 15) -> u32 {

    // Clamp region to framebuffer bounds
    x0 := clamp(mouse_x - radius, 0, cast(s32) picker.width  - 1);
    y0 := clamp(mouse_y - radius, 0, cast(s32) picker.height - 1);
    x1 := clamp(mouse_x + radius, 0, cast(s32) picker.width  - 1);
    y1 := clamp(mouse_y + radius, 0, cast(s32) picker.height - 1);

    w := cast(u32)(x1 - x0 + 1);
    h := cast(u32)(y1 - y0 + 1);

    if w == 0 || h == 0  return NO_OBJECT_ID;

    pixel_count := w * h;
    buffer: [..] u32;
    array_resize(*buffer, pixel_count);
    defer array_free(buffer);

    read_region(picker, cast(u32) x0, cast(u32) y0, w, h, buffer);

    best_id: u32 = NO_OBJECT_ID;
    best_dist_sq: s32 = S32_MAX;

    for row: 0..cast(s32)h-1 {
        for col: 0..cast(s32)w-1 {
            id := buffer[row * cast(s32)w + col];
            if id == NO_OBJECT_ID  continue;

            // Pixel position in screen space
            px := x0 + col;
            py := y0 + row;

            dx := px - mouse_x;
            dy := py - mouse_y;
            dist_sq := dx * dx + dy * dy;

            // Skip pixels outside the circle
            if dist_sq > radius * radius  continue;

            if dist_sq < best_dist_sq {
                best_dist_sq = dist_sq;
                best_id = id;
            }
        }
    }

    return best_id;
}


