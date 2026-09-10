import Link from "next/link";
import { useRouter } from "next/router";
import { useEffect, useState } from "react";
import useSWR, { useSWRConfig } from "swr";
import { api_url, fetcher } from "../utils/fetcher";
import { User } from "../utils/state";

type NavbarLinkProps = {
  href: string;
  children: React.ReactNode;
  current?: boolean;
};

function NavbarLink({ href, children, current }: NavbarLinkProps): JSX.Element {
  return (
    <Link href={href}>
      <a className="nav-link" aria-current={current ? "page" : undefined}>
        {children}
      </a>
    </Link>
  );
}

export default function Navbar(): JSX.Element {
  const [menuOpen, setMenuOpen] = useState(false);
  const [isComponentMounted, setIsComponentMounted] = useState(false);
  const router = useRouter();
  const { mutate } = useSWRConfig();

  const { data: user, error } = useSWR<User>(api_url("/user/me"), fetcher, {
    shouldRetryOnError: false,
  });

  useEffect(() => setIsComponentMounted(true), []);

  useEffect(() => {
    const close = () => setMenuOpen(false);
    router.events.on("routeChangeComplete", close);
    return () => {
      router.events.off("routeChangeComplete", close);
    };
  }, [router]);

  useEffect(() => {
    if (!menuOpen) return;

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setMenuOpen(false);
    };

    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [menuOpen]);

  const oauth_url = api_url("/auth/discord/start");
  const path = router.asPath.split("?")[0];

  let sidebar: JSX.Element | undefined;

  if (isComponentMounted) {
    if (!user || error) {
      sidebar = (
        <li className="md:ml-auto">
          <a className="btn-discord" href={oauth_url}>
            Log in with Discord
          </a>
        </li>
      );
    } else {
      sidebar = (
        <>
          <li className="md:ml-auto">
            <NavbarLink
              href={`/user/${user.username}`}
              current={path === `/user/${user.username}`}
            >
              Account
            </NavbarLink>
          </li>
          <li>
            <button
              type="button"
              className="nav-link"
              onClick={() => {
                fetch(api_url("/auth/logout"), {
                  method: "GET",
                  credentials: "include",
                }).then(() => {
                  mutate(api_url("/user/me"));
                  router.push("/");
                });
              }}
            >
              Sign out
            </button>
          </li>
        </>
      );
    }
  }

  return (
    <header className="sticky top-0 z-50 w-full">
      <nav
        aria-label="Primary"
        className="flex flex-col gap-4 border-b border-neutral-300 bg-white/90 p-4 backdrop-blur-lg dark:border-neutral-700 dark:bg-black/90 md:flex-row md:items-center"
      >
        <div className="flex items-center">
          <Link href="/">
            <a className="nav-link flex items-center text-2xl font-extrabold">
              Chico ACM
            </a>
          </Link>

          <button
            type="button"
            onClick={() => setMenuOpen((open) => !open)}
            className="btn-primary ml-auto md:hidden"
            aria-expanded={menuOpen}
            aria-controls="primary-navigation"
          >
            Menu
          </button>
        </div>

        <ul
          id="primary-navigation"
          className={`${
            menuOpen ? "flex" : "hidden md:flex"
          } flex-col gap-4 md:flex-row md:items-center md:flex-1`}
        >
          <li>
            <NavbarLink href="/problems" current={path.startsWith("/problems")}>
              Problems
            </NavbarLink>
          </li>
          <li>
            <NavbarLink href="/leaderboard" current={path === "/leaderboard"}>
              Leaderboard
            </NavbarLink>
          </li>
          <li>
            <NavbarLink
              href="/competitions"
              current={path.startsWith("/competitions")}
            >
              Competitions
            </NavbarLink>
          </li>
          {isComponentMounted &&
            user &&
            (user.auth == "OFFICER" || user.auth == "ADMIN") && (
              <li>
                <NavbarLink
                  href="/dashboard"
                  current={path.startsWith("/dashboard")}
                >
                  Dashboard
                </NavbarLink>
              </li>
            )}
          {sidebar}
        </ul>
      </nav>
    </header>
  );
}
