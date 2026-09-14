import { Accordion } from "@heroui/react";

export default function Questions({ items }: { items: readonly (readonly string[])[] }) {
  return (
    <Accordion className="faq-list" allowsMultipleExpanded>
      {items.map(([question, answer]) => (
        <Accordion.Item key={question} id={question} className="faq-item">
          <Accordion.Heading>
            <Accordion.Trigger className="faq-trigger">
              {question}
              <Accordion.Indicator />
            </Accordion.Trigger>
          </Accordion.Heading>
          <Accordion.Panel>
            <Accordion.Body>
              <p>{answer}</p>
            </Accordion.Body>
          </Accordion.Panel>
        </Accordion.Item>
      ))}
    </Accordion>
  );
}
