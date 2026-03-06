Operation :: enum {
    NONE;
    MOVE;
    ROTATE;
    SCALE;
}

Operation_State :: struct {
    active_op: Operation = .NONE;
    
    start_mouse_x: s32;
    start_mouse_y: s32;
    
    original_positions: [..] Vector3;
    
    // which vertices are affected by this operation
    affected_vertices: [..] bool;
    
    pivot: Vector3;
    
    // -1 = free (camera plane), 0 = x, 1 = y, 2 = z
    axis_constraint: s32 = -1;
}

gather_affected_vertices :: (em: *Editable_Mesh) {
    state := *em.op_state;
    array_resize(*state.affected_vertices, em.mesh.vertices.count);
    for 0..state.affected_vertices.count-1 {
        state.affected_vertices[it] = false;
    }

    if em.selection_mode == {
        case .VERTEX;
            for 0..em.selected_vertices.count-1 {
                if em.selected_vertices[it] {
                    state.affected_vertices[it] = true;
                }
            }

        case .EDGE;
            for edge_key, edge_idx: em.edge_map {
                if em.selected_edges[edge_idx] {
                    state.affected_vertices[edge_key.v0] = true;
                    state.affected_vertices[edge_key.v1] = true;
                }
            }

        case .FACE;
            for face_idx: 0..em.selected_faces.count-1 {
                if !em.selected_faces[face_idx] continue;

                face := em.mesh.faces[face_idx];
                start_edge := face.arbitrary_edge;
                edge := start_edge;
                while true {
                    v_idx := vertex_index(*em.mesh, edge.start_vertex);
                    state.affected_vertices[v_idx] = true;
                    edge = edge.next_edge_around_face;
                    if edge == start_edge break;
                }
            }
    }
}

compute_selection_pivot :: (em: *Editable_Mesh) -> Vector3, s64 {
    gather_affected_vertices(em);

    state := *em.op_state;
    pivot := Vector3.{0, 0, 0};
    count: s64 = 0;
    for 0..state.affected_vertices.count-1 {
        if state.affected_vertices[it] {
            pivot += em.mesh.vertices[it].position;
            count += 1;
        }
    }
    if count > 0 {
        pivot.x /= cast(float) count;
        pivot.y /= cast(float) count;
        pivot.z /= cast(float) count;
    }
    return pivot, count;
}

begin_operation :: (em: *Editable_Mesh, op: Operation, mouse_x: s32, mouse_y: s32) -> bool {
    pivot, count := compute_selection_pivot(em);
    if count == 0 return false;
    
    state := *em.op_state;
    state.active_op = op;
    state.start_mouse_x = mouse_x;
    state.start_mouse_y = mouse_y;
    state.axis_constraint = -1;
    state.pivot = pivot;
    
    array_resize(*state.original_positions, em.mesh.vertices.count);
    for 0..em.mesh.vertices.count-1 {
        state.original_positions[it] = em.mesh.vertices[it].position;
    }
    
    return true;
}

cancel_operation :: (em: *Editable_Mesh) {
    if em.op_state.active_op == .NONE return;
    
    for 0..em.mesh.vertices.count-1 {
        em.mesh.vertices[it].position = em.op_state.original_positions[it];
    }
    em.op_state.active_op = .NONE;
}

confirm_operation :: (em: *Editable_Mesh) {
    if em.op_state.active_op == .NONE return;
    em.op_state.active_op = .NONE;
}

ray_plane_intersect :: (ray_origin: Vector3, ray_dir: Vector3, plane_point: Vector3, plane_normal: Vector3) -> hit: Vector3, ok: bool {
    denom := dot(plane_normal, ray_dir);
    if abs(denom) < 0.00001 return .{0,0,0}, false;
    
    t := dot(plane_point - ray_origin, plane_normal) / denom;
    
    return ray_origin + ray_dir * t, true;
}

unproject_screen_to_ray :: (screen_x: s32, screen_y: s32, camera: *Camera, window_width: int, window_height: int) -> origin: Vector3, direction: Vector3 {
    ndc_x := (cast(float) screen_x / cast(float) window_width) * 2.0 - 1.0;
    ndc_y := (cast(float) screen_y / cast(float) window_height) * 2.0 - 1.0;
    
    clip_near := Vector4.{ndc_x, ndc_y, -1.0, 1.0};
    clip_far  := Vector4.{ndc_x, ndc_y,  1.0, 1.0};
    
    inv_proj := inverse(camera.camera_to_clip);
    inv_view := inverse(camera.world_to_camera);
    
    eye_near := inv_proj * clip_near;
    eye_far  := inv_proj * clip_far;
    
    if eye_near.w != 0 { eye_near.x /= eye_near.w; eye_near.y /= eye_near.w; eye_near.z /= eye_near.w; }
    if eye_far.w  != 0 { eye_far.x  /= eye_far.w;  eye_far.y  /= eye_far.w;  eye_far.z  /= eye_far.w;  }
    
    world_near_4 := inv_view * Vector4.{eye_near.x, eye_near.y, eye_near.z, 1.0};
    world_far_4  := inv_view * Vector4.{eye_far.x,  eye_far.y,  eye_far.z,  1.0};
    
    world_near := Vector3.{world_near_4.x, world_near_4.y, world_near_4.z};
    world_far  := Vector3.{world_far_4.x,  world_far_4.y,  world_far_4.z};
    
    dir := unit_vector(world_far - world_near);
    
    return world_near, dir;
}

apply_move :: (em: *Editable_Mesh, mouse_x: s32, mouse_y: s32, camera: *Camera, window_width: int, window_height: int) {
    state := *em.op_state;
    cam_forward := get_forward(camera);
    
    obj_mat := get_transform_matrix(em.transform);
    world_pivot := (obj_mat * Vector4.{state.pivot.x, state.pivot.y, state.pivot.z, 1.0}).xyz;
    
    start_origin, start_dir := unproject_screen_to_ray(state.start_mouse_x, state.start_mouse_y, camera, window_width, window_height);
    curr_origin, curr_dir   := unproject_screen_to_ray(mouse_x, mouse_y, camera, window_width, window_height);
    
    start_hit, ok1 := ray_plane_intersect(start_origin, start_dir, world_pivot, cam_forward);
    curr_hit,  ok2 := ray_plane_intersect(curr_origin,  curr_dir,  world_pivot, cam_forward);
    
    if !ok1 || !ok2 return;
    
    world_delta := curr_hit - start_hit;
    
    inv_obj := inverse(obj_mat);
    local_delta_4 := inv_obj * Vector4.{world_delta.x, world_delta.y, world_delta.z, 0.0};
    local_delta := Vector3.{local_delta_4.x, local_delta_4.y, local_delta_4.z};
    
    if state.axis_constraint == 0 { local_delta.y = 0; local_delta.z = 0; }
    if state.axis_constraint == 1 { local_delta.x = 0; local_delta.z = 0; }
    if state.axis_constraint == 2 { local_delta.x = 0; local_delta.y = 0; }
    
    for 0..em.mesh.vertices.count-1 {
        if state.affected_vertices[it] {
            em.mesh.vertices[it].position = state.original_positions[it] + local_delta;
        }
    }
}

apply_scale :: (em: *Editable_Mesh, mouse_x: s32, mouse_y: s32) {
    state := *em.op_state;
    dx := cast(float)(mouse_x - state.start_mouse_x);
    scale_factor := 1.0 + dx * 0.005;
    if scale_factor < 0.01 scale_factor = 0.01;
    
    for 0..em.mesh.vertices.count-1 {
        if state.affected_vertices[it] {
            offset := state.original_positions[it] - state.pivot;
            
            if state.axis_constraint == {
                case 0;  offset.x *= scale_factor;
                case 1;  offset.y *= scale_factor;
                case 2;  offset.z *= scale_factor;
                case -1; offset = offset * scale_factor;
            }
            
            em.mesh.vertices[it].position = state.pivot + offset;
        }
    }
}

apply_rotate :: (em: *Editable_Mesh, mouse_x: s32, mouse_y: s32, camera: *Camera) {
    state := *em.op_state;
    dx := cast(float)(mouse_x - state.start_mouse_x);
    angle := dx * 0.01;
    
    axis: Vector3;
    if state.axis_constraint == {
        case 0;  axis = .{1, 0, 0};
        case 1;  axis = .{0, 1, 0};
        case 2;  axis = .{0, 0, 1};
        case -1;
            axis = get_forward(camera);
    }
    
    q: Quaternion;
    set_from_axis_and_angle(*q, axis, angle);
    rot := rotation_matrix(Matrix3, q);
    
    for 0..em.mesh.vertices.count-1 {
        if state.affected_vertices[it] {
            offset := state.original_positions[it] - state.pivot;
            rotated := rot * offset;
            em.mesh.vertices[it].position = state.pivot + rotated;
        }
    }
}
