import { Component, Suspense, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Canvas, useFrame, useThree, type ThreeEvent } from "@react-three/fiber";
import { useGLTF, useTexture } from "@react-three/drei";
import { easing } from "maath";
import {
  Color,
  Mesh,
  MeshBasicNodeMaterial,
  SRGBColorSpace,
  Vector2,
  Vector3,
  WebGPURenderer,
} from "three/webgpu";
import {
  float,
  materialColor,
  max,
  mix,
  positionWorld,
  smoothstep,
  texture,
  uniform,
  vec3,
} from "three/tsl";
import { keyLabel, type Finish, type InputSource, type KeyboardInput } from "./keyboard";

type Props = {
  input: KeyboardInput;
  finish: Finish;
  selected: string | null;
  reducedMotion: boolean;
  onPress: (code: string, source: InputSource) => void;
  onRelease: (code: string, source: InputSource) => void;
  onReady: () => void;
};

const motion = {
  travel: 0.025,
  damping: 0.0175,
  pulseDuration: 0.9,
  radius: 0.15,
  feather: 0.08,
  intensity: 2,
};
const aliases: Record<string, string> = {
  "keys.311": "F1",
  "keys.310": "F2",
  "keys.309": "F3",
  "keys.308": "F4",
  "keys.307": "F5",
  "keys.306": "F6",
  "keys.305": "F7",
  "keys.304": "F8",
  "keys.303": "F9",
  "keys.302": "F10",
  "keys.301": "F11",
  "keys.300": "F12",
  "keys.299": "PrintScreen",
  "keys.276": "Delete",
  "keys.313": "Home",
  "keys.314": "PageUp",
  "keys.316": "PageDown",
  "keys.317": "End",
  "keys.318": "AltRight",
  "keys.319": "Space",
};

function Scene({ input, finish, selected, reducedMotion, onPress, onRelease, onReady }: Props) {
  const gltf = useGLTF("/keyboard/keyboard.glb", "/draco/");
  const [base, rgb] = useTexture(["/keyboard/base.jpg", "/keyboard/rgb.jpg"]);
  const { camera, size } = useThree();
  const pulseIndex = useRef(0);
  const pointerKey = useRef<string | null>(null);
  const scene = useMemo(() => {
    for (const map of [base, rgb]) {
      map.flipY = false;
      map.colorSpace = SRGBColorSpace;
      map.anisotropy = 8;
    }
    const pulses = Array.from({ length: 10 }, () => ({
      center: uniform(new Vector2()),
      progress: uniform(1),
    }));
    const tint = uniform(new Color("#c3cec1"));
    const recolor = uniform(0);
    let strength = float(0).add(0);
    for (const pulse of pulses) {
      const eased = float(1).sub(float(1).sub(pulse.progress).pow(3));
      const radius = eased.mul(motion.radius);
      const distance = positionWorld.xz.sub(pulse.center).length();
      const mask = float(1)
        .sub(smoothstep(radius, radius.add(motion.feather), distance))
        .mul(float(1).sub(eased));
      strength = max(strength, mask);
    }
    const group = gltf.scene.clone(true);
    const keys: { mesh: Mesh; code: string; rest: Vector3; axis: Vector3; depth: number }[] = [];
    const materials: MeshBasicNodeMaterial[] = [];
    group.traverse((object) => {
      if (!(object instanceof Mesh)) return;
      const isKey = object.name !== "static";
      const material = new MeshBasicNodeMaterial();
      const unlit = texture(base).rgb;
      const lightKeycap = max(vec3(0), vec3(1).sub(unlit.mul(6))).mul(tint);
      const styled = isKey ? mix(unlit, lightKeycap, recolor) : unlit;
      material.colorNode = styled
        .add(texture(rgb).rgb.sub(unlit).mul(strength.mul(motion.intensity)))
        .mul(materialColor);
      object.material = material;
      materials.push(material);
      if (isKey)
        keys.push({
          mesh: object,
          code: aliases[object.name] ?? object.name,
          rest: object.position.clone(),
          axis: new Vector3(0, -1, 0).applyQuaternion(object.quaternion),
          depth: 0,
        });
    });
    return { group, keys, pulses, tint, recolor, materials };
  }, [gltf, base, rgb]);

  useEffect(() => {
    onReady();
    return () => {
      for (const material of scene.materials) material.dispose();
    };
  }, [onReady, scene]);
  useEffect(() => {
    scene.recolor.value = finish === "graphite" ? 0 : 1;
    scene.tint.value.set(finish === "chalk" ? "#eeeae2" : "#aabdad");
  }, [scene, finish]);
  useEffect(() => {
    // Fit the complete keyboard when the editor opens or the viewport narrows.
    const distance = Math.max(2.65, 7.25 / (size.width / size.height));
    camera.position.set(0, distance, distance * 0.43);
    camera.lookAt(0, 0, 0);
    camera.updateProjectionMatrix();
  }, [camera, size]);

  useFrame((_, delta) => {
    const dt = Math.min(delta, 1 / 30);
    for (const code of input.pulses.splice(0)) {
      const key = scene.keys.find((key) => key.code === code);
      if (key && !reducedMotion) {
        const pulse = scene.pulses[pulseIndex.current++ % scene.pulses.length];
        pulse.center.value.set(key.rest.x, key.rest.z);
        pulse.progress.value = 0;
      }
    }
    for (const pulse of scene.pulses)
      pulse.progress.value = reducedMotion
        ? 1
        : Math.min(1, pulse.progress.value + dt / motion.pulseDuration);
    for (const key of scene.keys) {
      const target = input.pressed.has(key.code) ? motion.travel : 0;
      if (reducedMotion) key.depth = target;
      else easing.damp(key, "depth", target, motion.damping, dt);
      key.mesh.position.copy(key.rest).addScaledVector(key.axis, key.depth);
      const material = key.mesh.material as MeshBasicNodeMaterial;
      material.color
        .set(selected === key.code ? "#f2efab" : "#ffffff")
        .multiplyScalar(1 - (key.depth / motion.travel) * 0.4);
    }
  });

  function codeAt(event: ThreeEvent<PointerEvent>) {
    return scene.keys.find((key) => key.mesh === event.object)?.code;
  }
  function press(event: ThreeEvent<PointerEvent>) {
    const code = codeAt(event);
    if (!code || event.button > 0) return;
    event.stopPropagation();
    if (pointerKey.current && pointerKey.current !== code) onRelease(pointerKey.current, "pointer");
    pointerKey.current = code;
    onPress(code, "pointer");
  }
  return (
    <primitive
      object={scene.group}
      onPointerDown={press}
      onPointerOver={(event: ThreeEvent<PointerEvent>) => {
        if (event.buttons & 1) press(event);
      }}
      onPointerOut={() => {
        if (pointerKey.current) onRelease(pointerKey.current, "pointer");
        pointerKey.current = null;
      }}
      onPointerUp={() => {
        if (pointerKey.current) onRelease(pointerKey.current, "pointer");
        pointerKey.current = null;
      }}
    />
  );
}

class SceneBoundary extends Component<
  { children: ReactNode; fallback: ReactNode },
  { failed: boolean }
> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    return this.state.failed ? this.props.fallback : this.props.children;
  }
}

export default function Keyboard(props: Props) {
  const container = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(true);
  useEffect(() => {
    let inView = true;
    const update = () => setVisible(inView && !document.hidden);
    const observer = new IntersectionObserver(([entry]) => {
      inView = entry.isIntersecting;
      update();
    });
    if (container.current) observer.observe(container.current);
    document.addEventListener("visibilitychange", update);
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", update);
    };
  }, []);
  const fallback = (
    <div className="scene-fallback">
      <p>The 3D keyboard couldn’t load.</p>
      <p>You can still type and configure your sound.</p>
    </div>
  );
  return (
    <div
      ref={container}
      className="keyboard-canvas"
      tabIndex={0}
      onPointerDown={(event) => event.currentTarget.focus()}
      role="group"
      aria-label={`Interactive keyboard. Type or click to play.${props.selected ? ` ${keyLabel(props.selected)} selected.` : ""}`}
    >
      <SceneBoundary fallback={fallback}>
        <Canvas
          aria-hidden="true"
          camera={{ position: [0, 4.5, 1.9], fov: 25, near: 0.1, far: 50 }}
          dpr={[1, 2]}
          frameloop={visible ? "always" : "demand"}
          fallback={fallback}
          gl={async (defaults) => {
            const renderer = new WebGPURenderer({
              canvas: defaults.canvas as HTMLCanvasElement,
              antialias: true,
              alpha: true,
            });
            await renderer.init();
            renderer.setClearColor(0x000000, 0);
            return renderer;
          }}
        >
          <Suspense fallback={null}>
            <Scene {...props} />
          </Suspense>
        </Canvas>
      </SceneBoundary>
    </div>
  );
}
