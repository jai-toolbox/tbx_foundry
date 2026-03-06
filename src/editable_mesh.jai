#import "Hash_Table";

Selection_Mode :: enum {
    VERTEX;
    EDGE;
    FACE;
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

// so in reality we need an editable per surface renderable, right now we're just doing it for the cpotcr, but we need one of these per-shader.
// that's a future metaprogramming issue.

Editable_Mesh :: struct {
    mesh: Adjacency_Mesh;
    transform: Transform;

    // surface display (always rendered, opaque)
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

    // selection state
    selected_vertices: [..] bool;
    selected_edges: [..] bool;
    selected_faces: [..] bool;

    // mappings
    edge_map: [..] Edge_Key;
    face_vert_ranges: [..] Face_Vert_Range;

    selection_mode: Selection_Mode;
    surface_color: Vector3;

    op_state: Operation_State;
}

init_editable_mesh :: (em: *Editable_Mesh, color: Vector3 = .{0.5, 0.5, 0.5}) {
    em.surface_color = color;
    em.selection_mode = .VERTEX;
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
    // edge_selection_renderer: *Camera_Per_Object_Transform_Line_Color_Renderer,
    edge_selection_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    face_selection_overlay_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer,
    picker: *Screen_Space_Object_Picker 
) {
    buffer_object(surface_renderer, *em.surface_renderable);
    buffer_object(vertex_selection_renderer, *em.vertex_selection_renderable);
    buffer_object(edge_selection_renderer, *em.edge_selection_renderable);
    buffer_object(face_selection_overlay_renderer, *em.face_selection_overlay_renderable);
    buffer_active_picking_renderable(em, picker);
}

rebuffer_all :: (
    em: *Editable_Mesh,
    surface_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    vertex_selection_renderer: *Camera_Per_Object_Transform_Position_Point_Color_Renderer,
    // edge_selection_renderer: *Camera_Per_Object_Transform_Line_Color_Renderer,
    edge_selection_renderer: *Camera_Per_Object_Transform_Color_Renderer,
    face_selection_overlay_renderer: *Camera_Per_Object_Transform_Color_Alpha_Renderer,
    picker: *Screen_Space_Object_Picker
) {
    rebuffer_object(surface_renderer, em.surface_renderable);
    rebuffer_object(vertex_selection_renderer, em.vertex_selection_renderable);
    rebuffer_object(edge_selection_renderer, em.edge_selection_renderable);
    rebuffer_object(face_selection_overlay_renderer, em.face_selection_overlay_renderable);
    rebuffer_active_picking_renderable(em, picker);
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

    // edge renderables - each edge has 2 vertices, and we render with GL_LILES 
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

    // face renderables - walk faces and update vertex positions
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

    if em.selection_mode == {
        case .VERTEX;
            set_local_to_world_matrix(*picker.renderer, em.vertex_selection_picking_renderable, mat);
        case .EDGE;
            set_local_to_world_matrix(*picker.renderer, em.edge_selection_picking_renderable, mat);
        case .FACE;
            set_local_to_world_matrix(*picker.renderer, em.face_selection_picking_renderable, mat);
    }
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
            // fully transparent - invisible
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

destroy_editable_mesh :: (em: *Editable_Mesh) {
    destroy_mesh(*em.mesh);
    array_free(em.selected_vertices);
    array_free(em.selected_edges);
    array_free(em.selected_faces);
    array_free(em.edge_map);
    array_free(em.face_vert_ranges);
}
