Editor_Mode :: enum {
    OBJECT;
    EDIT;
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
