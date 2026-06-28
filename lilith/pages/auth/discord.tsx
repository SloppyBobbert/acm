import Link from "next/link";
import { NextPage } from "next";
import { useRouter } from "next/router";
import { useEffect, useState } from "react";
import Navbar from "../../components/navbar";
import { api_url } from "../../utils/fetcher";

const redirect_uri = process.env.NODE_ENV == "production"
  ? "https://chicoacm.org/auth/discord"
  : "http://localhost:3000/auth/discord";

const DiscordAuth: NextPage = () => {
  const router = useRouter();
  const [status, setStatus] = useState<{
    title: string;
    details?: string;
    isError: boolean;
  }>({
    title: "Signing you in with Discord...",
    details: "Please wait while we finish your login.",
    isError: false,
  });

  useEffect(() => {
    let isMounted = true;
    const fragment = new URLSearchParams(window.location.search);
    const code = fragment.get('code');

    if (!code) {
      setStatus({
        title: "Missing Discord authorization code.",
        details: "Please try signing in again from the home page.",
        isError: true,
      });
      return;
    }

    fetch(api_url("/auth/discord"), {
      method: "POST",
      credentials: "include",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        code,
        redirect_uri
      })
    })
      .then(async (res) => {
        const data = await res.json().catch(() => null);

        if (!res.ok || (data && data.error)) {
          throw new Error("discord_auth_failed");
        }

        router.replace("/");
      })
      .catch(() => {
        if (!isMounted) {
          return;
        }

        setStatus({
          title: "Unable to complete Discord sign in.",
          details: "Please head back home and try again.",
          isError: true,
        });
      });

    return () => {
      isMounted = false;
    };
  }, [router]);

  return (
    <div className="min-h-screen bg-neutral-50 dark:bg-neutral-950 text-neutral-900 dark:text-neutral-100">
      <Navbar />

      <main className="flex min-h-[calc(100vh-81px)] items-center justify-center px-6 py-16">
        <div className="w-full max-w-md rounded-2xl border border-neutral-200 bg-white px-8 py-10 text-center shadow-sm dark:border-neutral-800 dark:bg-neutral-900">
          <p className={`text-sm font-semibold uppercase tracking-[0.2em] ${status.isError ? "text-red-600 dark:text-red-400" : "text-blue-600 dark:text-blue-400"}`}>
            Discord Login
          </p>
          <h1 className="mt-4 text-2xl font-bold">{status.title}</h1>
          {status.details && (
            <p className="mt-3 text-sm text-neutral-600 dark:text-neutral-400">
              {status.details}
            </p>
          )}

          {status.isError && (
            <Link href="/">
              <a className="mt-6 inline-flex rounded-full bg-blue-700 px-5 py-2 font-semibold text-white transition-colors hover:bg-blue-600">
                Back home
              </a>
            </Link>
          )}
        </div>
      </main>
    </div>
  );
};

export default DiscordAuth;
