/* oxlint-disable react/immutability -- The renderer owns mesh transforms, materials, and pulse uniforms. */
import { Component, Suspense, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Canvas, useFrame, useLoader, useThree, type ThreeEvent } from "@react-three/fiber";
import {
  Mesh,
  MeshBasicNodeMaterial,
  SRGBColorSpace,
  TextureLoader,
  Vector2,
  Vector3,
  WebGPURenderer,
} from "three/webgpu";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { DRACOLoader } from "three/addons/loaders/DRACOLoader.js";
import { float, materialColor, max, positionWorld, smoothstep, texture, uniform } from "three/tsl";
import { type KeyboardInput } from "@openklack/keyboard-layout";

type Props = {
  input: KeyboardInput;
  assetBase?: string;
  selected?: string | null;
  assignments?: string[];
  lighting?: boolean;
  reducedMotion?: boolean;
  onPress: (key: string) => void;
  onRelease: (key: string) => void;
};

function configureLoader(loader: GLTFLoader, assetBase: string) {
  const draco = new DRACOLoader()
    .setDecoderPath(`${assetBase}/draco/`)
    .setDecoderConfig({ type: "js" });
  loader.setDRACOLoader(draco);
}
function Model({
  input,
  assetBase = "",
  selected,
  lighting = true,
  reducedMotion,
  onPress,
  onRelease,
}: Props) {
  const gltf = useLoader(GLTFLoader, `${assetBase}/keyboard/openklack.glb`, (loader) =>
    configureLoader(loader, assetBase),
  );
  const [base, rgb] = useLoader(TextureLoader, [
    `${assetBase}/keyboard/base.png`,
    `${assetBase}/keyboard/rgb.png`,
  ]);
  const { camera, size, invalidate } = useThree();
  const pulseIndex = useRef(0);
  const pointerKey = useRef<string | null>(null);
  const scene = useMemo(() => {
    for (const map of [base!, rgb!]) {
      map.flipY = false;
      map.colorSpace = SRGBColorSpace;
      map.anisotropy = 8;
    }
    const pulses = Array.from({ length: 10 }, () => ({
      center: uniform(new Vector2()),
      progress: uniform(1),
    }));
    let strength = float(0).add(0);
    for (const pulse of pulses) {
      const eased = float(1).sub(float(1).sub(pulse.progress).pow(3));
      const radius = eased.mul(0.15);
      const distance = positionWorld.xz.sub(pulse.center).length();
      const mask = float(1)
        .sub(smoothstep(radius, radius.add(0.08), distance))
        .mul(float(1).sub(eased));
      strength = max(strength, mask);
    }
    const group = gltf.scene.clone(true);
    const keys: { mesh: Mesh; code: string; rest: Vector3; axis: Vector3; depth: number }[] = [];
    const materials: MeshBasicNodeMaterial[] = [];
    group.traverse((object) => {
      if (!(object instanceof Mesh)) return;
      const isKey = object.name !== "static";
      const code = object.userData.keyCode as string;
      const material = new MeshBasicNodeMaterial();
      const unlit = texture(base!).rgb;
      material.colorNode = unlit
        .add(texture(rgb!).rgb.sub(unlit).mul(strength.mul(2)))
        .mul(materialColor);
      object.material = material;
      materials.push(material);
      if (isKey)
        keys.push({
          mesh: object,
          code,
          rest: object.position.clone(),
          axis: new Vector3(0, -1, 0).applyQuaternion(object.quaternion),
          depth: 0,
        });
    });
    return { group, keys, pulses, materials };
  }, [gltf, base, rgb]);
  useEffect(
    () => () => {
      scene.materials.forEach((m) => m.dispose());
    },
    [scene],
  );
  useEffect(() => {
    const distance = Math.max(2.65, 7.25 / (size.width / size.height));
    camera.position.set(0, distance, distance * 0.43);
    camera.lookAt(0, 0, 0);
    camera.updateProjectionMatrix();
    invalidate();
  }, [camera, size, invalidate]);
  useEffect(() => input.subscribe(invalidate), [input, invalidate]);
  useEffect(() => {
    invalidate();
  }, [selected, lighting, reducedMotion, invalidate]);
  useFrame((_, delta) => {
    const dt = Math.min(delta, 1 / 30);
    let moving = false;
    for (const code of input.pulses.splice(0)) {
      const key = scene.keys.find((key) => key.code === code);
      if (key && lighting && !reducedMotion) {
        const pulse = scene.pulses[pulseIndex.current++ % scene.pulses.length]!;
        pulse.center.value.set(key.rest.x, key.rest.z);
        pulse.progress.value = 0;
      }
    }
    for (const pulse of scene.pulses) {
      pulse.progress.value =
        !lighting || reducedMotion ? 1 : Math.min(1, pulse.progress.value + dt / 0.9);
      if (pulse.progress.value < 1) moving = true;
    }
    for (const key of scene.keys) {
      const target = input.pressed.has(key.code) && !reducedMotion ? 0.025 : 0;
      key.depth += (target - key.depth) * (1 - Math.exp(-dt * 90));
      if (Math.abs(target - key.depth) < 0.00001) key.depth = target;
      else moving = true;
      key.mesh.position.copy(key.rest).addScaledVector(key.axis, key.depth);
      (key.mesh.material as MeshBasicNodeMaterial).color
        .set(selected === key.code ? "#b6c5ff" : "#ffffff")
        .multiplyScalar(1 - (key.depth / 0.025) * 0.4);
    }
    if (moving) invalidate();
  });
  function press(event: ThreeEvent<PointerEvent>) {
    const code = scene.keys.find((key) => key.mesh === event.object)?.code;
    if (!code || event.button > 0) return;
    event.stopPropagation();
    if (pointerKey.current && pointerKey.current !== code) onRelease(pointerKey.current);
    pointerKey.current = code;
    onPress(code);
  }
  function release() {
    if (pointerKey.current) onRelease(pointerKey.current);
    pointerKey.current = null;
  }
  return (
    <primitive
      object={scene.group}
      onPointerDown={press}
      onPointerOver={(event: ThreeEvent<PointerEvent>) => {
        if (event.buttons & 1) press(event);
      }}
      onPointerOut={release}
      onPointerUp={release}
      onPointerCancel={release}
    />
  );
}

class RendererBoundary extends Component<
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

export default function Keyboard3D(props: Props) {
  const host = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(true);
  useEffect(() => {
    let intersects = true;
    const update = () => setVisible(intersects && !document.hidden);
    const observer = new IntersectionObserver(([entry]) => {
      intersects = entry!.isIntersecting;
      update();
    });
    if (host.current) observer.observe(host.current);
    document.addEventListener("visibilitychange", update);
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", update);
    };
  }, []);
  const fallback = (
    <p className="model-error" role="status">
      Keyboard preview unavailable. You can still try the sounds.
    </p>
  );
  return (
    <div className="original-keyboard" ref={host} aria-label="Interactive 75 percent keyboard">
      <RendererBoundary fallback={fallback}>
        <Canvas
          aria-hidden="true"
          camera={{ position: [0, 4.5, 1.9], fov: 25, near: 0.1, far: 50 }}
          frameloop={visible ? "demand" : "never"}
          dpr={[1, 2]}
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
          fallback={fallback}
        >
          <Suspense fallback={null}>
            <Model {...props} />
          </Suspense>
        </Canvas>
      </RendererBoundary>
    </div>
  );
}
