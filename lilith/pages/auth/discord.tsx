import { NextPage } from "next";
import { useRouter } from "next/router";
import { useEffect } from "react";
import { api_url } from "../../utils/fetcher";

const redirect_uri = process.env.NODE_ENV == "production"
  ? "https://chicoacm.org/auth/discord"
  : "http://localhost:3000/auth/discord";

const DiscordAuth: NextPage = () => {
  const router = useRouter();

  useEffect(() => {
    const fragment = new URLSearchParams(window.location.search);
    const code = fragment.get('code');

    if (!code) {
      router.replace("/");
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
      .then((res) => res.json())
      .then(res => {
        if (res && res.error) {
          console.log("Error logging in");
        }
      })
      .catch(() => router.replace("/"));
  }, [router]);

  return <></>;
};

export default DiscordAuth;
