import moment from "moment";
import type { NextPage } from "next";
import Link from "next/link";
import { useRouter } from "next/router";
import { useState } from "react";
import useSWR from "swr";
import Navbar from "../../components/navbar";
import { isServerError, ServerError } from "../../components/problem/submission/error";
import { api_url, fetcher } from "../../utils/fetcher";
import { useSession, User } from "../../utils/state";

const NewCompetitionPage: NextPage = () => {
  const [name, setName] = useState("");
  const [start, setStart] = useState(new Date);
  const [end, setEnd] = useState(new Date);
  const router = useRouter();
  const setError = useSession((state) => state.setError);
  const { data: user, error } = useSWR<User>(api_url("/user/me"), fetcher, {
    shouldRetryOnError: false,
  });
  const canCreate = !!user && (user.auth === "OFFICER" || user.auth === "ADMIN");

  const submit = async () => {
    const res: { id: number } | ServerError = await (await fetch(api_url("/competitions/new"), {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      credentials: "include",
      body: JSON.stringify({
        name,
        start: start.toISOString().slice(0, -1),
        end: end.toISOString().slice(0, -1),
      }),
    })).json();

    if (isServerError(res)) {
      setError(res.error, true);
    } else {
      router.push(`/competitions/${res.id}`);
    }
  };

  return (
    <>
      <Navbar />

      {!user && !error ? (
        <div className="max-w-screen-md mx-auto mt-4 px-4 text-neutral-600 dark:text-neutral-400">
          Checking permissions...
        </div>
      ) : !canCreate ? (
        <div className="max-w-screen-md mx-auto mt-6 px-4">
          <div className="flex flex-col items-center gap-4 rounded-md border border-neutral-300 bg-white px-6 py-8 text-center dark:border-neutral-700 dark:bg-black">
            <p className="text-neutral-700 dark:text-neutral-300">Log in as an officer or admin to create competitions.</p>
            <Link href="/competitions">
              <a className="rounded-full bg-neutral-900 px-4 py-2 text-sm text-neutral-50 transition-colors hover:bg-neutral-700 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-300">
                Back to Competitions
              </a>
            </Link>
          </div>
        </div>
      ) : (
        <div className="flex max-w-screen-md mx-auto flex-col gap-4 mt-4">
          <h1 className="text-3xl font-extrabold">New Competition</h1>

          <div className="w-full p-4 bg-white dark:bg-black dark:border-neutral-700 border-neutral-300 rounded-md mx-auto border flex flex-col gap-2">
            <span>Name</span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="border-neutral-300 dark:border-neutral-700 border rounded p-2 bg-neutral-50 dark:bg-neutral-900 outline-0 transition-shadow focus:ring dark:ring-neutral-700 ring-neutral-300"
            />

            <span>Start Date</span>
            <input
              type="datetime-local"
              value={moment(start).format("yyyy-MM-DDTHH:mm")}
              onChange={(e) => setStart(new Date(e.target.value))}
              className="border-neutral-300 dark:border-neutral-700 border rounded p-2 bg-neutral-50 dark:bg-neutral-900 outline-0 transition-shadow focus:ring dark:ring-neutral-700 ring-neutral-300"
            />

            <span>End Date</span>
            <input
              type="datetime-local"
              value={moment(end).format("yyyy-MM-DDTHH:mm")}
              onChange={(e) => setEnd(new Date(e.target.value))}
              className="border-neutral-300 dark:border-neutral-700 border rounded p-2 bg-neutral-50 dark:bg-neutral-900 outline-0 transition-shadow focus:ring dark:ring-neutral-700 ring-neutral-300"
            />

            <button
              onClick={submit}
              className="mt-2 rounded-full bg-green-500 hover:bg-green-700 px-4 py-2 text-green-50 transition-colors">
              Submit
            </button>
          </div>
        </div>
      )}

    </>
  );
};

export default NewCompetitionPage;
