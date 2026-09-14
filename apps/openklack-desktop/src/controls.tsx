import { useState, type ReactNode } from "react";
import { Accordion, Description, Label, ListBox, Select, Slider, Switch } from "@heroui/react";

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
      isDisabled={disabled}
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
  description?: string;
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
      {description && <Description>{description}</Description>}
    </Switch>
  );
}

export function Choice({
  label,
  value,
  options,
  onChange,
  disabled = false,
  className = "",
}: {
  label: string;
  value: string;
  options: { id: string; name: string }[];
  onChange: (value: string) => void;
  disabled?: boolean;
  className?: string;
}) {
  return (
    <Select
      className={`choice ${className}`}
      value={value}
      isDisabled={disabled}
      onChange={(key) => {
        if (key !== null) onChange(String(key));
      }}
    >
      <Label>{label}</Label>
      <Select.Trigger>
        <Select.Value />
        <Select.Indicator />
      </Select.Trigger>
      <Select.Popover>
        <ListBox>
          {options.map((option) => (
            <ListBox.Item key={option.id} id={option.id} textValue={option.name}>
              {option.name}
              <ListBox.ItemIndicator />
            </ListBox.Item>
          ))}
        </ListBox>
      </Select.Popover>
    </Select>
  );
}

export function Disclosure({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Accordion className="settings-disclosure">
      <Accordion.Item id={title}>
        <Accordion.Heading>
          <Accordion.Trigger>
            {title}
            <Accordion.Indicator />
          </Accordion.Trigger>
        </Accordion.Heading>
        <Accordion.Panel>
          <Accordion.Body>{children}</Accordion.Body>
        </Accordion.Panel>
      </Accordion.Item>
    </Accordion>
  );
}
