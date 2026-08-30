import { NextPage } from "next";
import Link from "next/link";
import { useRouter } from "next/router";
import { useEffect, useRef, useState } from "react";
import { api_url } from "../../utils/fetcher";

const DiscordAuth: NextPage = () => {
  const router = useRouter();
  const exchanged = useRef(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const fragment = new URLSearchParams(window.location.search);
    const code = fragment.get('code');
    const state = fragment.get('state');

    if (!code || !state) {
      router.replace("/");
      return;
    }

    if (exchanged.current) return;
    exchanged.current = true;

    const cleanUrl = new URL(window.location.href);
    cleanUrl.searchParams.delete("code");
    cleanUrl.searchParams.delete("state");
    window.history.replaceState(
      window.history.state,
      "",
      `${cleanUrl.pathname}${cleanUrl.search}${cleanUrl.hash}`
    );

    const exchange = async () => {
      try {
        const response = await fetch(api_url("/auth/discord"), {
          method: "POST",
          credentials: "include",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            code,
            state
          })
        });

        if (!response.ok) {
          throw new Error("Discord sign-in failed");
        }

        router.replace("/");
      } catch {
        setFailed(true);
      }
    };

    void exchange();
  }, [router]);

  if (failed) {
    return (
      <main className="flex min-h-screen items-center justify-center px-6">
        <section
          aria-labelledby="sign-in-failed-title"
          className="w-full max-w-sm rounded-md border border-neutral-200 bg-white p-6 shadow-sm dark:border-neutral-700 dark:bg-neutral-800"
          role="alert"
        >
          <h1 id="sign-in-failed-title" className="text-lg font-bold text-neutral-900 dark:text-neutral-100">
            Sign-in failed
          </h1>
          <p className="mt-2 text-sm leading-6 text-neutral-600 dark:text-neutral-300">
            We couldn&apos;t sign you in. Please try again.
          </p>
          <div className="mt-5 flex flex-wrap items-center gap-3">
            <a
              className="rounded-full bg-blue-700 px-4 py-2 text-sm font-bold text-blue-50 transition-colors hover:bg-blue-500"
              href={api_url("/auth/discord/start")}
            >
              Try Discord sign-in again
            </a>
            <Link href="/">
              <a className="text-sm font-bold text-blue-700 hover:underline dark:text-blue-500">
                Return home
              </a>
            </Link>
          </div>
        </section>
      </main>
    );
  }

  return null;
};

export default DiscordAuth;
