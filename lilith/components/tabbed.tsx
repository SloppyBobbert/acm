import { useId, useRef, useState } from "react";

type TabbedProps = {
  titles: string[];
  children: JSX.Element[];
  className?: string;
};

export default function Tabbed({
  titles,
  children,
  className,
}: TabbedProps): JSX.Element {
  const [focusedWindow, setFocusedWindow] = useState(0);
  const tabRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const baseId = useId();

  function moveFocus(index: number) {
    const next = (index + titles.length) % titles.length;
    setFocusedWindow(next);
    tabRefs.current[next]?.focus();
  }

  return (
    <div
      className={`grid grid-rows-min-full grid-cols-full bg-white dark:bg-black ${
        className ?? ""
      }`}
    >
      <div
        role="tablist"
        aria-label="Sections"
        className="flex overflow-x-auto border-b border-neutral-300 dark:border-neutral-700"
      >
        {titles.map((title, index) => {
          const selected = index == focusedWindow;
          const focused = selected
            ? "bg-neutral-300 hover:bg-neutral-100 dark:bg-neutral-700 dark:hover:bg-neutral-600 "
            : "bg-neutral-200 hover:bg-neutral-50 dark:bg-neutral-800 dark:hover:bg-neutral-700 ";

          return (
            <button
              key={index}
              ref={(node) => {
                tabRefs.current[index] = node;
              }}
              type="button"
              role="tab"
              id={`${baseId}-tab-${index}`}
              aria-selected={selected}
              aria-controls={`${baseId}-panel`}
              tabIndex={selected ? 0 : -1}
              className={`focus-ring shrink-0 px-4 py-2 transition-colors border-r border-neutral-300 dark:border-neutral-700 ${focused}`}
              onClick={() => setFocusedWindow(index)}
              onKeyDown={(event) => {
                if (event.key === "ArrowRight") {
                  event.preventDefault();
                  moveFocus(index + 1);
                } else if (event.key === "ArrowLeft") {
                  event.preventDefault();
                  moveFocus(index - 1);
                } else if (event.key === "Home") {
                  event.preventDefault();
                  moveFocus(0);
                } else if (event.key === "End") {
                  event.preventDefault();
                  moveFocus(titles.length - 1);
                }
              }}
            >
              {title}
            </button>
          );
        })}
      </div>

      <div
        role="tabpanel"
        id={`${baseId}-panel`}
        aria-labelledby={`${baseId}-tab-${focusedWindow}`}
      >
        {children[focusedWindow]}
      </div>
    </div>
  );
}
