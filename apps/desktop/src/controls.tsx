import { useState } from "react";
import { Description, Label, Slider, Switch } from "@heroui/react";

export function Level({
  label,
  value,
  onChange,
  disabled = false,
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
  disabled?: boolean;
}) {
  const [drag, setDrag] = useState<number | null>(null);
  return (
    <Slider
      className="level"
      minValue={0}
      maxValue={100}
      value={drag ?? value}
      aria-busy={disabled}
      onChange={(v) => setDrag(Number(v))}
      onChangeEnd={(v) => {
        setDrag(null);
        onChange(Number(v));
      }}
    >
      <div className="level-heading">
        <Label>{label}</Label>
        <Slider.Output>
          {Math.round(drag ?? value)}
          <span>%</span>
        </Slider.Output>
      </div>
      <Slider.Track>
        <Slider.Fill />
        <Slider.Thumb />
      </Slider.Track>
    </Slider>
  );
}

export function Toggle({
  label,
  description,
  selected,
  onChange,
  disabled = false,
}: {
  label: string;
  description: string;
  selected: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <Switch
      className="setting-toggle"
      isSelected={selected}
      onChange={onChange}
      isDisabled={disabled}
    >
      <Switch.Content>
        <Label>{label}</Label>
        <Switch.Control>
          <Switch.Thumb />
        </Switch.Control>
      </Switch.Content>
      <Description>{description}</Description>
    </Switch>
  );
}
