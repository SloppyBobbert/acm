import { useEffect, useRef, useState } from "react";

type CountdownNumberProps = {
  number: number;
  description: string;
};

function CountdownNumber({
  number,
  description,
}: CountdownNumberProps): JSX.Element {
  return (
    <div className="flex w-14 flex-col items-center">
      <span className="text-3xl font-bold">{number}</span>
      <span className="text-sm font-bold">{description}</span>
    </div>
  );
}

type CountdownProps = {
  to: Date;
  onFinal?: () => void;
};

export default function Countdown({ to, onFinal }: CountdownProps): JSX.Element {
  const [time, setTime] = useState(new Date());
  const fired = useRef(false);

  useEffect(() => {
    const interval = setInterval(() => setTime(new Date()), 1000);

    return () => {
      clearInterval(interval);
    };
  }, []);

  const remainingMs = to.getTime() - time.getTime();
  const diff = Math.max(0, remainingMs / 1000);
  const target = to.getTime();

  useEffect(() => {
    fired.current = false;
  }, [target]);

  useEffect(() => {
    if (remainingMs < 0 && onFinal && !fired.current) {
      fired.current = true;
      onFinal();
    }
  }, [remainingMs, onFinal]);

  const seconds = Math.floor(diff) % 60;
  const minutes = Math.floor(diff / 60) % 60;
  const hours = Math.floor(diff / 3600) % 24;
  const days = Math.floor(diff / 86400);

  return (
    <div
      className="flex justify-center gap-4"
      role="timer"
      aria-label={`${days} days, ${hours} hours, ${minutes} minutes, ${seconds} seconds`}
    >
      <CountdownNumber number={days} description="days" />
      <CountdownNumber number={hours} description="hours" />
      <CountdownNumber number={minutes} description="minutes" />
      <CountdownNumber number={seconds} description="seconds" />
    </div>
  );
}
