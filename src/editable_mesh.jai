#import "Hash_Table";

Selection_Mode :: enum {
    VERTEX;
    EDGE;
    FACE;
}

Editor_Mode :: enum {
    OBJECT;
    EDIT;
}

Edge_Key :: struct {
    v0: u32;
    v1: u32;
}

operator == :: (a: Edge_Key, b: Edge_Key) -> bool {
    return a.v0 == b.v0 && a.v1 == b.v1;
}

Face_Vert_Range :: struct {
    start: u32;
    count: u32;
}

Object_Operation_State :: struct {
    active_op: Operation_Type = .NONE;
    axis_constraint: s32 = -1;  // -1 = free, 0 = X, 1 = Y, 2 = Z

    original_transform: Transform;
    mouse_start_x: float;
    mouse_start_y: float;

    snap_mode: Snap_Mode = .NONE;
    snap_increment_size: float = 1.0;
}

Scene :: struct {
    objects: [..] *Editable_Mesh;
    selected_object: s32 = -1;  // index into objects, -1 = none
    editor_mode: Editor_Mode = .OBJECT;
}

init_scene :: (scene: *Scene) {
    // nothing for now
}

add_object :: (scene: *Scene, em: *Editable_Mesh) {
    array_add(*scene.objects, em);
}

get_selected_object :: (scene: *Scene) -> *Editable_Mesh {
    if scene.selected_object < 0 || scene.selected_object >= scene.objects.count return null;
    return scene.objects[scene.selected_object];
}

deinit_scene :: (scene: *Scene) {
    array_free(scene.objects);
}

// so in reality we need an editable per renderable/shader, right now we're just doing it for the cpotcr, but we need one of these per-shader.
// that's a future metaprogramming issue.

// also there is huge potential for improvement here, almost each renderable is storing positions, so for a big mesh we're storing like 6 times as 
// much memory as we really should be using, think about this when it's a real issue.

Editable_Mesh :: struct {
    mesh: Adjacency_Mesh;
    transform: Transform;

    // surface display (always rendered, opaque), the thing that will be a metaprogramming parameter.
    surface_renderable: Camera_Per_Object_Transform_Color_Renderable;

    // the picking renderable can always stay as a cpotoir, this is because we can render it in 3 different ways.
    // one where we render it with GL_POINTS, one with GL_LINES, and one with GL_TRIANGLES, we need separate renderables
    // because we need to store different object ids on it depending on what we're trying to select
    // also in the future this may get simplified by just doing cpu raycasts, but I'm deciding to do this for now.

    // vertex selection
    vertex_selection_renderable: Camera_Per_Object_Transform_Position_Point_Color_Renderable;
    vertex_selection_picking_renderable: Camera_Per_Object_Transform_Object_Id_Renderable;

    // edge selection
    // it doesn't require it's own shader because we just use the regular camera color renderable
    // but render in GL_LINES mode, this is fine for now, but later on might require more tweaking I guess.
    edge_selection_renderable: Camera_Per_Object_Transform_Color_Renderable;
    edge_selection_picking_renderable: Camera_Per_Object_Transform_Object_Id_Renderable;

    // face selection (semi-transparent overlay on top of surface)
    face_selection_overlay_renderable: Camera_Per_Object_Transform_Color_Alpha_Renderable;
    face_selection_picking_renderable: Camera_Per_Object_Transform_Object_Id_Renderable;

    // object-level picking renderable (uses surface triangles but with a single object_id)
    object_picking_renderable: Camera_Per_Object_Transform_Object_Id_Renderable;


    // selection state
    selected_vertices: [..] bool;
    selected_edges: [..] bool;
    selected_faces: [..] bool;

    // mappings
    edge_map: [..] Edge_Key;
    face_vert_ranges: [..] Face_Vert_Range;

    selection_mode: Selection_Mode;
    surface_color: Vector3;
    unselected_surface_color: Vector3;
    selected_surface_color: Vector3;

    // object-level state
    is_object_selected: bool;
    object_id: u32;  // unique id for object-level picking

    op_state: Operation_State;
    obj_op_state: Object_Operation_State;
}

init_editable_mesh :: (em: *Editable_Mesh, color: Vector3 = .{0.5, 0.5, 0.5}, object_id: u32 = 0) {
    em.surface_color = color;
    em.unselected_surface_color = color;
    em.selected_surface_color = .{
        min(color.x + 0.15, 1.0),
        min(color.y + 0.15, 1.0),
        min(color.z + 0.15, 1.0)
    };
    em.selection_mode = .VERTEX;
    em.object_id = object_id;
    em.is_object_selected = false;
}

vertex_index :: (mesh: *Adjacency_Mesh, v: *Vertex) -> u32 {
    for mesh.vertices {
        if it == v return cast(u32) it_index;
    }
    assert(false, "vertex not found in mesh");
    return 0;
}

rebuild_renderables :: (em: *Editable_Mesh) {
    rebuild_surface_renderable(em);
    rebuild_vertex_selection_renderables(em);
    rebuild_edge_selection_renderables(em);
    rebuild_face_selection_renderables(em);
    rebuild_object_picking_renderable(em);
    resize_selection_arrays(em);
}

rebuild_surface_renderable :: (em: *Editable_Mesh) {
    itpn := make_itpn_from_adjacency_mesh(*em.mesh);
    defer {
        array_free(itpn.indices);
        array_free(itpn.positions);
        array_free(itpn.normals);
    }

    array_reset(*em.surface_renderable.indices);
    array_reset(*em.surface_renderable.positions);
    // this line would be generated for a renderable that did have normals.
    // array_reset(*em.surface_renderable.normals);
    array_reset(*em.surface_renderable.rgb_colors);

    array_copy(*em.surface_renderable.indices, itpn.indices);
    array_copy(*em.surface_renderable.positions, itpn.positions);
    // this line would be generated for a renderable that did have normals.
    // array_copy(*em.surface_renderable.normals, itpn.normals);

    for 0..itpn.positions.count-1 {
        array_add(*em.surface_renderable.rgb_colors, em.surface_color);
    }
}

rebuild_vertex_selection_renderables :: (em: *Editable_Mesh) {
    array_reset(*em.vertex_selection_renderable.indices);
    array_reset(*em.vertex_selection_renderable.positions);
    array_reset(*em.vertex_selection_renderable.rgb_colors);

    array_reset(*em.vertex_selection_picking_renderable.indices);
    array_reset(*em.vertex_selection_picking_renderable.positions);
    array_reset(*em.vertex_selection_picking_renderable.object_ids);

    for em.mesh.vertices {
        idx := cast(u32) it_index;

        // display
        array_add(*em.vertex_selection_renderable.positions, it.position);
        array_add(*em.vertex_selection_renderable.indices, idx);
        array_add(*em.vertex_selection_renderable.rgb_colors, Vector3.{0, 0, 0});

        // picking
        array_add(*em.vertex_selection_picking_renderable.positions, it.position);
        array_add(*em.vertex_selection_picking_renderable.indices, idx);
        array_add(*em.vertex_selection_picking_renderable.object_ids, idx + 1);
    }
}

rebuild_edge_selection_renderables :: (em: *Editable_Mesh) {
    array_reset(*em.edge_selection_renderable.indices);
    array_reset(*em.edge_selection_renderable.positions);
    array_reset(*em.edge_selection_renderable.rgb_colors);

    array_reset(*em.edge_selection_picking_renderable.indices);
    array_reset(*em.edge_selection_picking_renderable.positions);
    array_reset(*em.edge_selection_picking_renderable.object_ids);

    array_reset(*em.edge_map);

    seen_edges: Table(u64, bool);
    defer deinit(*seen_edges);

    edge_index: u32 = 0;

    for face: em.mesh.faces {
        start_edge := face.arbitrary_edge;
        edge := start_edge;

        while true {
            v0_idx := vertex_index(*em.mesh, edge.start_vertex);
            v1_idx := vertex_index(*em.mesh, edge.next_edge_around_face.start_vertex);

            a := cast(u32) min(v0_idx, v1_idx);
            b := cast(u32) max(v0_idx, v1_idx);

            key := (cast(u64) a) * 100000 + (cast(u64) b);


            if !table_find_pointer(*seen_edges, key) {
                table_add(*seen_edges, key, true);

                p0 := em.mesh.vertices[a].position;
                p1 := em.mesh.vertices[b].position;

                // display renderable
                vert_base := cast(u32) em.edge_selection_renderable.positions.count;

                array_add(*em.edge_selection_renderable.positions, p0);
                array_add(*em.edge_selection_renderable.positions, p1);
                array_add(*em.edge_selection_renderable.rgb_colors, Vector3.{0, 0, 0});
                array_add(*em.edge_selection_renderable.rgb_colors, Vector3.{0, 0, 0});
                array_add(*em.edge_selection_renderable.indices, vert_base);
                array_add(*em.edge_selection_renderable.indices, vert_base + 1);

                // picking renderable
                vert_base_pick := cast(u32) em.edge_selection_picking_renderable.positions.count;

                array_add(*em.edge_selection_picking_renderable.positions, p0);
                array_add(*em.edge_selection_picking_renderable.positions, p1);
                array_add(*em.edge_selection_picking_renderable.object_ids, edge_index + 1);
                array_add(*em.edge_selection_picking_renderable.object_ids, edge_index + 1);
                array_add(*em.edge_selection_picking_renderable.indices, vert_base_pick);
                array_add(*em.edge_selection_picking_renderable.indices, vert_base_pick + 1);

                // track edge
                array_add(*em.edge_map, Edge_Key.{a, b});

                edge_index += 1;
            }

            edge = edge.next_edge_around_face;
            if edge == start_edge break;
        }
    }
}

rebuild_face_selection_renderables :: (em: *Editable_Mesh) {
    array_reset(*em.face_selection_overlay_renderable.indices);
    array_reset(*em.face_selection_overlay_renderable.positions);
    array_reset(*em.face_selection_overlay_renderable.rgba_colors);

    array_reset(*em.face_selection_picking_renderable.indices);
    array_reset(*em.face_selection_picking_renderable.positions);
    array_reset(*em.face_selection_picking_renderable.object_ids);

    array_reset(*em.face_vert_ranges);

    for face_idx: 0..em.mesh.faces.count-1 {
        face := em.mesh.faces[face_idx];

        // collect the vertices of this face by walking half-edges
        face_verts: [..] u32;
        face_verts.allocator = temp;

        start_edge := face.arbitrary_edge;
        edge := start_edge;
        while true {
            array_add(*face_verts, vertex_index(*em.mesh, edge.start_vertex));
            edge = edge.next_edge_around_face;
            if edge == start_edge break;
        }

        if face_verts.count < 3 continue;

        // track the vertex range for this face (for coloring later)
        range: Face_Vert_Range;
        range.start = cast(u32) em.face_selection_overlay_renderable.positions.count;
        range.count = cast(u32) face_verts.count;
        array_add(*em.face_vert_ranges, range);

        // overlay renderable (semi-transparent, for selection display)
        base_vert := cast(u32) em.face_selection_overlay_renderable.positions.count;

        for v: face_verts {
            array_add(*em.face_selection_overlay_renderable.positions, em.mesh.vertices[v].position);
            // start fully transparent (unselected)
            array_add(*em.face_selection_overlay_renderable.rgba_colors, Vector4.{0, 0, 0, 0});
        }

        for i: 1..face_verts.count-2 {
            array_add(*em.face_selection_overlay_renderable.indices, base_vert);
            array_add(*em.face_selection_overlay_renderable.indices, base_vert + cast(u32) i);
            array_add(*em.face_selection_overlay_renderable.indices, base_vert + cast(u32) i + 1);
        }

        // picking renderable (opaque, for off-screen picking)
        base_vert_pick := cast(u32) em.face_selection_picking_renderable.positions.count;

        for v: face_verts {
            array_add(*em.face_selection_picking_renderable.positions, em.mesh.vertices[v].position);
            array_add(*em.face_selection_picking_renderable.object_ids, cast(u32) (face_idx + 1));
        }

        for i: 1..face_verts.count-2 {
            array_add(*em.face_selection_picking_renderable.indices, base_vert_pick);
            array_add(*em.face_selection_picking_renderable.indices, base_vert_pick + cast(u32) i);
            array_add(*em.face_selection_picking_renderable.indices, base_vert_pick + cast(u32) i + 1);
        }
    }
}

rebuild_object_picking_renderable :: (em: *Editable_Mesh) {
    array_reset(*em.object_picking_renderable.indices);
    array_reset(*em.object_picking_renderable.positions);
    array_reset(*em.object_picking_renderable.object_ids);

    itpn := make_itpn_from_adjacency_mesh(*em.mesh);
    defer {
        array_free(itpn.indices);
        array_free(itpn.positions);
        array_free(itpn.normals);
    }

    array_copy(*em.object_picking_renderable.indices, itpn.indices);
    array_copy(*em.object_picking_renderable.positions, itpn.positions);

    for 0..itpn.positions.count-1 {
        array_add(*em.object_picking_renderable.object_ids, em.object_id);
    }
}

resize_selection_arrays :: (em: *Editable_Mesh) {
    old_vert_count := em.selected_vertices.count;
    array_resize(*em.selected_vertices, em.mesh.vertices.count);
    for old_vert_count..em.selected_vertices.count-1 {
        em.selected_vertices[it] = false;
    }

    old_edge_count := em.selected_edges.count;
    array_resize(*em.selected_edges, em.edge_map.count);
    for old_edge_count..em.selected_edges.count-1 {
        em.selected_edges[it] = false;
    }

    old_face_count := em.selected_faces.count;
    array_resize(*em.selected_faces, em.mesh.faces.count);
    for old_face_count..em.selected_faces.count-1 {
        em.selected_faces[it] = false;
    }
}

buffer_all :: (
    em: *Editable_Mesh,
    surface_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    vertex_selection_renderer: *Camera_Per_Object_Transform_Position_Point_Color_Renderer,
    edge_selection_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    face_selection_overlay_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer,
    picker: *Screen_Space_Object_Picker
) {
    buffer_object(surface_renderer, *em.surface_renderable);
    buffer_object(vertex_selection_renderer, *em.vertex_selection_renderable);
    buffer_object(edge_selection_renderer, *em.edge_selection_renderable);
    buffer_object(face_selection_overlay_renderer, *em.face_selection_overlay_renderable);

    // buffer ALL picking renderables so they all have valid local_to_world indices
    buffer_object(*picker.renderer, *em.object_picking_renderable);
    buffer_object(*picker.renderer, *em.vertex_selection_picking_renderable);
    buffer_object(*picker.renderer, *em.edge_selection_picking_renderable);
    buffer_object(*picker.renderer, *em.face_selection_picking_renderable);
}

unbuffer_all :: (
    em: *Editable_Mesh,
    surface_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    vertex_selection_renderer: *Camera_Per_Object_Transform_Position_Point_Color_Renderer,
    edge_selection_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    face_selection_overlay_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer,
    picker: *Screen_Space_Object_Picker
) {
    unbuffer_object(surface_renderer, *em.surface_renderable);
    unbuffer_object(vertex_selection_renderer, *em.vertex_selection_renderable);
    unbuffer_object(edge_selection_renderer, *em.edge_selection_renderable);
    unbuffer_object(face_selection_overlay_renderer, *em.face_selection_overlay_renderable);

    unbuffer_object(*picker.renderer, *em.object_picking_renderable);
    unbuffer_object(*picker.renderer, *em.vertex_selection_picking_renderable);
    unbuffer_object(*picker.renderer, *em.edge_selection_picking_renderable);
    unbuffer_object(*picker.renderer, *em.face_selection_picking_renderable);
}

// big warning don't do this if you've added or removed elements to the mesh!
rebuffer_all :: (
    em: *Editable_Mesh,
    surface_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    vertex_selection_renderer: *Camera_Per_Object_Transform_Position_Point_Color_Renderer,
    edge_selection_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    face_selection_overlay_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer,
    picker: *Screen_Space_Object_Picker
) {
    rebuffer_object(surface_renderer, em.surface_renderable);
    rebuffer_object(vertex_selection_renderer, em.vertex_selection_renderable);
    rebuffer_object(edge_selection_renderer, em.edge_selection_renderable);
    rebuffer_object(face_selection_overlay_renderer, em.face_selection_overlay_renderable);

    // rebuffer ALL picking renderables
    rebuffer_object(*picker.renderer, em.object_picking_renderable);
    rebuffer_object(*picker.renderer, em.vertex_selection_picking_renderable);
    rebuffer_object(*picker.renderer, em.edge_selection_picking_renderable);
    rebuffer_object(*picker.renderer, em.face_selection_picking_renderable);
}

buffer_active_picking_renderable :: (em: *Editable_Mesh, picker: *Screen_Space_Object_Picker) {
    if em.selection_mode == {
        case .VERTEX;
            buffer_object(*picker.renderer, *em.vertex_selection_picking_renderable);
        case .EDGE;
            buffer_object(*picker.renderer, *em.edge_selection_picking_renderable);
        case .FACE;
            buffer_object(*picker.renderer, *em.face_selection_picking_renderable);
    }
}

rebuffer_active_picking_renderable :: (em: *Editable_Mesh, picker: *Screen_Space_Object_Picker) {
    if em.selection_mode == {
        case .VERTEX;
            rebuffer_object(*picker.renderer, em.vertex_selection_picking_renderable);
        case .EDGE;
            rebuffer_object(*picker.renderer, em.edge_selection_picking_renderable);
        case .FACE;
            rebuffer_object(*picker.renderer, em.face_selection_picking_renderable);
    }
}

sync_positions_from_mesh :: (em: *Editable_Mesh) {
    // vertex renderables
    for em.mesh.vertices {
        if it_index < em.vertex_selection_renderable.positions.count
            em.vertex_selection_renderable.positions[it_index] = it.position;
        if it_index < em.vertex_selection_picking_renderable.positions.count
            em.vertex_selection_picking_renderable.positions[it_index] = it.position;
    }

    // edge renderables, each edge has 2 vertices, and we render with GL_LINES
    for edge_key, edge_idx: em.edge_map {
        p0 := em.mesh.vertices[edge_key.v0].position;
        p1 := em.mesh.vertices[edge_key.v1].position;

        base := cast(s64) edge_idx * 2;
        if base + 1 < em.edge_selection_renderable.positions.count {
            em.edge_selection_renderable.positions[base]     = p0;
            em.edge_selection_renderable.positions[base + 1] = p1;
        }
        if base + 1 < em.edge_selection_picking_renderable.positions.count {
            em.edge_selection_picking_renderable.positions[base]     = p0;
            em.edge_selection_picking_renderable.positions[base + 1] = p1;
        }
    }

    // face renderables, walk faces and update vertex positions
    for face_idx: 0..em.mesh.faces.count-1 {
        if face_idx >= em.face_vert_ranges.count break;

        range := em.face_vert_ranges[face_idx];
        face := em.mesh.faces[face_idx];

        start_edge := face.arbitrary_edge;
        edge := start_edge;
        vert_offset: u32 = 0;

        while true {
            pos := edge.start_vertex.position;
            idx := range.start + vert_offset;

            if idx < em.face_selection_overlay_renderable.positions.count
                em.face_selection_overlay_renderable.positions[idx] = pos;
            if idx < em.face_selection_picking_renderable.positions.count
                em.face_selection_picking_renderable.positions[idx] = pos;

            vert_offset += 1;
            edge = edge.next_edge_around_face;
            if edge == start_edge break;
        }
    }
}

sync_mesh_from_positions :: (em: *Editable_Mesh) {
    for em.mesh.vertices {
        if it_index < em.vertex_selection_renderable.positions.count
            it.position = em.vertex_selection_renderable.positions[it_index];
    }
}

update_transform :: (
    em: *Editable_Mesh,
    surface_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    vertex_selection_renderer: *Camera_Per_Object_Transform_Position_Point_Color_Renderer,
    edge_selection_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    face_selection_overlay_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer,
    picker: *Screen_Space_Object_Picker
) {
    mat := get_transform_matrix(em.transform);
    set_local_to_world_matrix(surface_renderer, em.surface_renderable, mat);
    set_local_to_world_matrix(vertex_selection_renderer, em.vertex_selection_renderable, mat);
    set_local_to_world_matrix(edge_selection_renderer, em.edge_selection_renderable, mat);
    set_local_to_world_matrix(face_selection_overlay_renderer, em.face_selection_overlay_renderable, mat);

    // all picking renderables are always buffered, so always update all of them
    set_local_to_world_matrix(*picker.renderer, em.object_picking_renderable, mat);
    set_local_to_world_matrix(*picker.renderer, em.vertex_selection_picking_renderable, mat);
    set_local_to_world_matrix(*picker.renderer, em.edge_selection_picking_renderable, mat);
    set_local_to_world_matrix(*picker.renderer, em.face_selection_picking_renderable, mat);
}

update_selection_colors :: (em: *Editable_Mesh) {
    if em.selection_mode == {
        case .VERTEX;
            update_vertex_selection_colors(em);
        case .EDGE;
            update_edge_selection_colors(em);
        case .FACE;
            update_face_selection_colors(em);
    }
}

update_vertex_selection_colors :: (em: *Editable_Mesh) {
    for 0..em.selected_vertices.count-1 {
        if em.selected_vertices[it] {
            em.vertex_selection_renderable.rgb_colors[it] = .{1.0, 0.6, 0.0};
        } else {
            em.vertex_selection_renderable.rgb_colors[it] = .{0, 0, 0};
        }
    }
}

update_edge_selection_colors :: (em: *Editable_Mesh) {
    for 0..em.selected_edges.count-1 {
        color: Vector3;
        if em.selected_edges[it] {
            color = .{1.0, 0.6, 0.0};
        } else {
            color = .{0, 0, 0};
        }
        // each edge has 2 vertices in the renderable
        em.edge_selection_renderable.rgb_colors[it * 2 + 0] = color;
        em.edge_selection_renderable.rgb_colors[it * 2 + 1] = color;
    }
}

update_face_selection_colors :: (em: *Editable_Mesh) {
    for face_idx: 0..em.selected_faces.count-1 {
        if face_idx >= em.face_vert_ranges.count break;

        range := em.face_vert_ranges[face_idx];

        color: Vector4;
        if em.selected_faces[face_idx] {
            // semi-transparent orange overlay
            color = .{1.0, 0.6, 0.0, 0.3};
        } else {
            // fully transparent, invisible
            color = .{0, 0, 0, 0};
        }

        for i: range.start..range.start + range.count - 1 {
            em.face_selection_overlay_renderable.rgba_colors[i] = color;
        }
    }
}

handle_picking :: (em: *Editable_Mesh, picked_id: u32) {
    if picked_id == 0 return;

    actual_index := picked_id - 1;

    if em.selection_mode == {
        case .VERTEX;
            if actual_index < em.selected_vertices.count
                em.selected_vertices[actual_index] = !em.selected_vertices[actual_index];

        case .EDGE;
            if actual_index < em.selected_edges.count
                em.selected_edges[actual_index] = !em.selected_edges[actual_index];

        case .FACE;
            if actual_index < em.selected_faces.count
                em.selected_faces[actual_index] = !em.selected_faces[actual_index];
    }

    update_selection_colors(em);
}

clear_selection :: (em: *Editable_Mesh) {
    for 0..em.selected_vertices.count-1  em.selected_vertices[it] = false;
    for 0..em.selected_edges.count-1     em.selected_edges[it] = false;
    for 0..em.selected_faces.count-1     em.selected_faces[it] = false;
}

unbuffer_active_picking_renderable :: (em: *Editable_Mesh, picker: *Screen_Space_Object_Picker) {
    if em.selection_mode == {
        case .VERTEX;
            unbuffer_object(*picker.renderer.psr, em.vertex_selection_picking_renderable.object_index);
        case .EDGE;
            unbuffer_object(*picker.renderer.psr, em.edge_selection_picking_renderable.object_index);
        case .FACE;
            unbuffer_object(*picker.renderer.psr, em.face_selection_picking_renderable.object_index);
    }
}

set_object_selected :: (em: *Editable_Mesh, selected: bool) {
    em.is_object_selected = selected;
    if selected {
        em.surface_color = em.selected_surface_color;
    } else {
        em.surface_color = em.unselected_surface_color;
    }
}

// object-level operations (move/rotate/scale the transform, not vertices)

begin_object_operation :: (em: *Editable_Mesh, op: Operation_Type, mx: float, my: float) {
    em.obj_op_state.active_op = op;
    em.obj_op_state.original_transform = em.transform;
    em.obj_op_state.mouse_start_x = mx;
    em.obj_op_state.mouse_start_y = my;
    em.obj_op_state.axis_constraint = -1;
}

cancel_object_operation :: (em: *Editable_Mesh) {
    em.transform = em.obj_op_state.original_transform;
    em.obj_op_state.active_op = .NONE;
}

confirm_object_operation :: (em: *Editable_Mesh) {
    em.obj_op_state.active_op = .NONE;
}

apply_object_move :: (em: *Editable_Mesh, mx: float, my: float, camera: *Camera, window_width: s32, window_height: s32) {
    dx := mx - em.obj_op_state.mouse_start_x;
    dy := my - em.obj_op_state.mouse_start_y;

    sensitivity :: 0.005;

    // derive right and up from camera rotation
    rotation := get_rotation(camera);
    right := rotate(Vector3.{1, 0, 0}, rotation);
    up := rotate(Vector3.{0, 1, 0}, rotation);

    original := em.obj_op_state.original_transform.position;
    new_pos: Vector3;

    if em.obj_op_state.axis_constraint == {
        case -1;
            // free movement on camera plane
            delta := right * dx * sensitivity + up * dy * sensitivity;
            new_pos = original + delta;
        case 0;
            // X axis only
            new_pos = original;
            new_pos.x = original.x + dx * sensitivity;
        case 1;
            // Y axis only
            new_pos = original;
            new_pos.y = original.y + dy * sensitivity;
        case 2;
            // Z axis only
            new_pos = original;
            new_pos.z = original.z + dx * sensitivity;
    }

    // apply snapping
    if em.obj_op_state.snap_mode == {
        case .GRID;
            new_pos.x = snap_round(new_pos.x);
            new_pos.y = snap_round(new_pos.y);
            new_pos.z = snap_round(new_pos.z);
        case .INCREMENT;
            delta := new_pos - original;
            delta.x = snap_round_to_increment(delta.x, em.obj_op_state.snap_increment_size);
            delta.y = snap_round_to_increment(delta.y, em.obj_op_state.snap_increment_size);
            delta.z = snap_round_to_increment(delta.z, em.obj_op_state.snap_increment_size);
            new_pos = original + delta;
    }

    em.transform.position = new_pos;
}

apply_object_rotate :: (em: *Editable_Mesh, mx: float, my: float) {
    dx := mx - em.obj_op_state.mouse_start_x;

    sensitivity :: 0.01;
    angle := dx * sensitivity;

    axis: Vector3;
    if em.obj_op_state.axis_constraint == {
        case -1; axis = .{0, 1, 0};  // default to Y
        case  0; axis = .{1, 0, 0};
        case  1; axis = .{0, 1, 0};
        case  2; axis = .{0, 0, 1};
    }

    delta_q: Quaternion;
    set_from_axis_and_angle(*delta_q, axis, angle);

    em.transform.rotation = delta_q * em.obj_op_state.original_transform.rotation;
}

apply_object_scale :: (em: *Editable_Mesh, mx: float, my: float) {
    dx := mx - em.obj_op_state.mouse_start_x;

    sensitivity :: 0.005;
    scale_factor := 1.0 + dx * sensitivity;
    if scale_factor < 0.01 scale_factor = 0.01;

    original := em.obj_op_state.original_transform.scale;

    if em.obj_op_state.axis_constraint == {
        case -1;
            // uniform scale
            em.transform.scale = original * scale_factor;
        case 0;
            em.transform.scale = original;
            em.transform.scale.x = original.x * scale_factor;
        case 1;
            em.transform.scale = original;
            em.transform.scale.y = original.y * scale_factor;
        case 2;
            em.transform.scale = original;
            em.transform.scale.z = original.z * scale_factor;
    }
}

destroy_editable_mesh :: (em: *Editable_Mesh) {
    destroy_mesh(*em.mesh);
    array_free(em.selected_vertices);
    array_free(em.selected_edges);
    array_free(em.selected_faces);
    array_free(em.edge_map);
    array_free(em.face_vert_ranges);
}
