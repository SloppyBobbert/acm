export type FetchError = Error & { status?: number };

export const fetcher = async (url: string) => {
  const res = await fetch(url, {
    method: "GET",
    credentials: "include"
  });

  if (!res.ok)
    throw Object.assign(new Error("failed to make request"), { status: res.status });

  return await res.json();
}

export function api_url(url: string): string {
  return process.env.NEXT_PUBLIC_API_URL + url;
}
