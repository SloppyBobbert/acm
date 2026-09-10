import { animated, useTransition } from "@react-spring/web";
import { useEffect, useRef } from "react";

type ModalProps = {
  children: JSX.Element;
  shown: boolean;
  onClose: () => void;
};

const FOCUSABLE =
  'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])';

export default function Modal({
  shown,
  children,
  onClose,
}: ModalProps): JSX.Element {
  const mousePressed = useRef(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const lastFocus = useRef<HTMLElement | null>(null);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const fadeIn = useTransition(shown, {
    from: {
      opacity: 0,
    },
    enter: {
      opacity: 1,
    },
    leave: {
      opacity: 0,
    },
  });

  const zoomIn = useTransition(shown, {
    from: {
      opacity: 0,
      transform: "translate3d(0, 100px, 0) scale(0.7)",
    },
    enter: {
      opacity: 1,
      transform: "translate3d(0, 0px, 0) scale(1)",
    },
    leave: {
      opacity: 0,
      transform: "translate3d(0, 100px, 0) scale(0.7)",
    },
  });

  useEffect(() => {
    if (!shown) return;

    lastFocus.current = document.activeElement as HTMLElement | null;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    const frame = window.requestAnimationFrame(() => {
      dialogRef.current?.focus();
    });

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        onCloseRef.current();
        return;
      }

      if (event.key !== "Tab" || !dialogRef.current) return;

      const focusable = Array.from(
        dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE)
      ).filter(
        (element) => !element.hasAttribute("inert") && element.tabIndex !== -1
      );

      if (focusable.length === 0) {
        event.preventDefault();
        dialogRef.current.focus();
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement;

      if (event.shiftKey && (active === first || active === dialogRef.current)) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener("keydown", onKeyDown);

    return () => {
      window.cancelAnimationFrame(frame);
      document.body.style.overflow = previousOverflow;
      document.removeEventListener("keydown", onKeyDown);
      lastFocus.current?.focus();
    };
  }, [shown]);

  return fadeIn(
    (styles, item) =>
      item && (
        <animated.div
          ref={(node) =>
            node &&
            (!shown
              ? node.setAttribute("inert", "")
              : node.removeAttribute("inert"))
          }
          style={styles}
          onMouseDown={() => {
            mousePressed.current = true;
          }}
          onMouseUp={() => {
            if (mousePressed.current) {
              onClose();
            }
            mousePressed.current = false;
          }}
          className="fixed bottom-0 left-0 right-0 top-0 z-50 overflow-y-auto bg-black/30"
        >
          {zoomIn(
            (styles, item) =>
              item && (
                <animated.div
                  ref={dialogRef}
                  role="dialog"
                  aria-modal="true"
                  aria-label="Dialog"
                  tabIndex={-1}
                  style={styles}
                  onMouseDown={(e) => e.stopPropagation()}
                  className="relative mx-auto mt-16 max-w-lg p-2 outline-none"
                >
                  {children}
                </animated.div>
              )
          )}
        </animated.div>
      )
  );
}
