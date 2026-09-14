"""Author and bake the light OpenKlack colorway on the reference geometry."""
import bpy
import colorsys
import json
import subprocess
import sys
from pathlib import Path
from mathutils import Vector
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'packages/ui/assets/keyboard'
DESIGN = ROOT / 'design/keyboard'
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(ASSETS / 'openklack.glb'))
scene = bpy.context.scene
keys = [o for o in scene.objects if o.type == 'MESH' and (o.get('keyCode') or o.name == 'static')]
assert len(keys) == 85, f'Expected 85 hero meshes, got {len(keys)}'
for obj in list(bpy.data.objects):
    if obj not in keys:
        bpy.data.objects.remove(obj, do_unlink=True)

labels = {code: label for row in json.loads((ROOT / 'packages/keyboard-layout/src/layout.json').read_text()) for code, label, _ in row}
labels.update(PrintScreen='print', Delete='del', Backspace='delete', Enter='enter', Space='OPENKLACK', AltLeft='opt', AltRight='opt', MetaLeft='cmd', MetaRight='cmd')
layers = []
for obj in keys:
    code = obj.get('keyCode')
    if not code or obj.name == 'SpacePlate':
        continue
    uv = [loop.uv for loop in obj.data.uv_layers.active.data]
    # The Up key's homing bump has a separate UV island below the keycap atlas.
    if code == 'ArrowUp':
        uv = [p for p in uv if p.y > 0.65]
    x = (min(p.x for p in uv) + max(p.x for p in uv)) * 1024
    y = (2 - min(p.y for p in uv) - max(p.y for p in uv)) * 1024
    label = labels.get(code, code)
    size = 25 if len(label) == 1 else 21 if code == 'Space' else 18
    tracking = ' letter-spacing="5"' if code == 'Space' else ''
    layers.append(f'<text id="{code}" x="{x}" y="{y}" fill="white" text-anchor="middle" dominant-baseline="central" font-family="Arial, sans-serif" font-size="{size}"{tracking}>{escape(label)}</text>')
(DESIGN / 'legends.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="2048" height="2048">' + ''.join(layers) + '</svg>')
subprocess.run(['node', '--input-type=module', '-e', 'import sharp from "sharp"; await sharp("design/keyboard/legends.svg").png().toFile("design/keyboard/legends.png");'], cwd=ROOT, check=True)
legend = bpy.data.images.load(str(DESIGN / 'legends.png'))
legend.pack()

def linear(hex_color):
    rgb = [int(hex_color[i:i+2], 16) / 255 for i in (1, 3, 5)]
    return tuple(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in rgb) + (1,)

def material(name, color, ink='#252936'):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    shader = nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value = linear(color)
    shader.inputs['Roughness'].default_value = 0.32
    atlas = nodes.new('ShaderNodeTexImage')
    atlas.image = legend
    atlas.label = 'OpenKlack legends — editable SVG atlas'
    mix = nodes.new('ShaderNodeMixRGB')
    mix.inputs[1].default_value = linear(color)
    mix.inputs[2].default_value = linear(ink)
    links.new(atlas.outputs['Alpha'], mix.inputs[0])
    links.new(mix.outputs[0], shader.inputs['Base Color'])
    return mat

ivory = material('Ivory • keycaps', '#efefed')
modifier = material('Cool gray • modifiers', '#c1c7d0')
accent = material('Cobalt • accent keys', '#304bff', '#ffffff')
case = material('Graphite • aluminum case', '#555d70')
for obj in keys:
    code = obj.get('keyCode', '')
    mat = case if not code else accent if code in ['Escape', 'Enter'] else ivory if code.startswith(('Key', 'Digit')) or code in ['Space', 'Backquote', 'Minus', 'Equal', 'BracketLeft', 'BracketRight', 'Backslash', 'Semicolon', 'Quote', 'Comma', 'Period', 'Slash'] else modifier
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    for face in obj.data.polygons:
        face.material_index = 0

# A diffuse bake records the softbox lighting and occlusion in the existing atlas.
scene.render.engine = 'CYCLES'
if sys.platform == 'darwin':
    devices = bpy.context.preferences.addons['cycles'].preferences
    devices.compute_device_type = 'METAL'
    devices.get_devices()
    for device in devices.devices:
        device.use = device.type == 'METAL'
    if any(device.use for device in devices.devices):
        scene.cycles.device = 'GPU'
scene.cycles.samples = 64
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 4
scene.world = bpy.data.worlds.new('Studio ambient')
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (0.8, 0.85, 1, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = 0.15
scene.view_settings.view_transform = 'Standard'

def area(name, position, power, size):
    light = bpy.data.lights.new(name, 'AREA')
    light.energy, light.shape, light.size = power, 'DISK', size
    obj = bpy.data.objects.new(name, light)
    scene.collection.objects.link(obj)
    obj.location = position
    obj.rotation_euler = (Vector((0, 0, 0)) - obj.location).to_track_quat('-Z', 'Y').to_euler()

area('Key softbox', (-3, -4, 6), 300, 4)
area('Fill softbox', (3, 2, 5), 150, 5)
bpy.ops.object.camera_add(location=(0, -3.1, 7.2))
scene.camera = bpy.context.object
scene.camera.rotation_euler = (Vector((0, 0, 0)) - scene.camera.location).to_track_quat('-Z', 'Y').to_euler()
scene.camera.data.type = 'ORTHO'
scene.camera.data.ortho_scale = 3.7
scene.render.resolution_x, scene.render.resolution_y = 1600, 800
scene.render.resolution_percentage = 100
scene.render.film_transparent = True

rgb_lights = []
rgb_collection = bpy.data.collections.new("RGB lighting • enable for lit appearance")
scene.collection.children.link(rgb_collection)
rgb_collection.hide_render = True
for row in [-0.47, -0.09, 0.29, 0.5]:
    for column in range(9):
        x = -1.4 + column * 0.35
        light = bpy.data.lights.new(f'RGB {row} {column}', 'POINT')
        light.color = colorsys.hsv_to_rgb((column / 10 + 0.55) % 1, 0.8, 1)
        light.energy, light.shadow_soft_size = 1.2, 0.035
        obj = bpy.data.objects.new(light.name, light)
        rgb_collection.objects.link(obj)
        obj.location = (x, row, 0.023)
        rgb_lights.append(light)

bpy.ops.wm.save_as_mainfile(filepath=str(DESIGN / 'openklack-keyboard.blend'))
# Join only for baking: one atlas operation instead of 85 independent bakes.
bpy.ops.object.select_all(action='DESELECT')
for obj in keys:
    obj.select_set(True)
bpy.context.view_layer.objects.active = keys[0]
bpy.ops.object.join()
bake_object = bpy.context.object
scene.render.bake.margin = 4
scene.render.bake.use_clear = True
scene.render.bake.use_selected_to_active = False
for name in ['base', 'rgb']:
    rgb_collection.hide_render = name == 'base'
    image = bpy.data.images.new(f'OpenKlack {name}', width=2048, height=2048, alpha=False)
    image.colorspace_settings.name = 'sRGB'
    for mat in bake_object.data.materials:
        node = mat.node_tree.nodes.new('ShaderNodeTexImage')
        node.image = image
        mat.node_tree.nodes.active = node
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT', 'COLOR'})
    image.filepath_raw = str(ASSETS / f'{name}.png')
    image.file_format = 'PNG'
    image.save()
    assert image.size[:] == (2048, 2048)
    print(f'BAKED {name}: 2048×2048', flush=True)
