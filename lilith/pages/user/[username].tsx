import type { NextPage } from "next";
import { useRouter } from "next/router";
import useSWR, { useSWRConfig } from "swr";
import Navbar from "../../components/navbar";
import Error from "next/error";
import { api_url, fetcher } from "../../utils/fetcher";
import Link from "next/link";
import { User, useSession } from "../../utils/state";
import useSWRInfinite from "swr/infinite";
import { useState } from "react";
import LoadingButton from "../../components/loading-button";
import Head from "next/head";
import SourceCodeBlock from "../../components/source-code";
import ErrorBox from "../../components/error-box";

export function SubmissionTime({ time }: { time: string }): JSX.Element {
  let dateTime = new Date(time);

  let date = dateTime.toLocaleDateString("en-us", {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
  let timet = dateTime.toLocaleTimeString("en-us", {
    hour: "numeric",
    minute: "numeric",
  });

  return (
    <span>{date} {timet}</span>
  );
}

type Submission = {
  language?: "cpp" | "rust";
  id: number;
  problem_id: number;
  problem_title: string;
  success: boolean;
  time: string;
  runtime: number;
  code: string;
};

function StarCount({ id }: { id?: number }): JSX.Element {
  const { data } = useSWR<{ count: number }>(
    id ? api_url(`/user/star-count/${id}`) : null,
    fetcher
  );

  if (!data || (data && data.count == 0)) return <></>;

  return (
    <div className="badge-star">
      {data.count} ★
    </div>
  )
}

function SubmissionEntry({
  id,
  success,
  runtime,
  problem_title,
  time,
  code,
  language = "cpp",
}: Submission): JSX.Element {
  let compact = Intl.NumberFormat('en', { notation: "compact" }).format(runtime) + " fuel";
  let long = Intl.NumberFormat('en', { notation: "standard" }).format(runtime) + " fuel";

  return (
    <article className="flex flex-col gap-2 border-y border-neutral-300 bg-white p-4 dark:border-neutral-700 dark:bg-black sm:m-2 sm:gap-4 sm:rounded-md sm:border md:m-0">
      <div className="grid grid-cols-full-min grid-rows-2">
        <h2 className="self-start text-2xl font-extrabold">{problem_title}</h2>
        <Link href={`/submissions/${id}`}>
          <a className="btn-primary row-span-1 ml-auto self-start sm:row-span-2 sm:self-center">
            Open
          </a>
        </Link>

        <div className="col-span-2 flex gap-2 text-neutral-500 sm:col-span-1">
          {success ? (
            <>
              <span className="text-lg font-bold text-green-600">
                Passed
              </span>
              {" • "}
              <span title={long}>
                {compact}
              </span>
              {" • "}
              <SubmissionTime time={time + 'Z'} />
            </>
          ) : (
            <>
              <span className="text-lg font-bold text-red-600">
                Failed
              </span>
              {" • "}
              <SubmissionTime time={time + 'Z'} />
            </>
          )}
        </div>
      </div>

      <SourceCodeBlock text={code} language={language} />
    </article>
  );
}

function RecentSubmissions({ username }: { username: string }): JSX.Element {
  const { data: submissions, error, isValidating, size, setSize } = useSWRInfinite<Submission[]>(
    (pageIndex, previousSubmissions) => {
      if (previousSubmissions && !previousSubmissions.length) return null;
      return api_url(`/user/username/${username}/submissions?offset=${pageIndex * 10}&count=10`);
    },
    fetcher
  );

  if (error) {
    return (
      <ErrorBox>Could not load recent submissions.</ErrorBox>
    );
  }

  if (!submissions) {
    return (
      <div className="flex flex-col gap-4" aria-busy="true" aria-label="Loading submissions">
        <h2 className="px-4 pt-4 text-2xl font-extrabold lg:p-0">
          Recent Submissions
        </h2>
        <div className="h-32 animate-pulse rounded bg-neutral-200 dark:bg-neutral-800 sm:m-2 md:m-0" />
        <div className="h-32 animate-pulse rounded bg-neutral-200 dark:bg-neutral-800 sm:m-2 md:m-0" />
      </div>
    );
  }

  const items = submissions.flat();

  return (
    <div className="flex flex-col gap-4">
      <h2 className="px-4 pt-4 text-2xl font-extrabold lg:p-0">
        Recent Submissions
      </h2>

      {items.length === 0 && (
        <p className="px-4 text-neutral-500 dark:text-neutral-400 lg:px-0">
          No submissions yet.
        </p>
      )}

      {items.map((submission) => (
        <SubmissionEntry key={submission.id} {...submission} />
      ))}

      <LoadingButton
        loading={isValidating}
        className="btn-secondary mx-auto"
        onClick={() => setSize(size + 1)}
      >Load more</LoadingButton>
    </div>
  );
}

function UserInfo({
  name,
  username,
  auth,
  id,
  onEdit,
}: User & { onEdit: () => void }): JSX.Element {
  const { data: currentUser } = useSWR<User>(
    api_url("/user/me"),
    fetcher, {
    shouldRetryOnError: false,
  });

  const showEditButton = currentUser?.username == username || currentUser?.auth == "ADMIN";

  return (
    <div className="flex flex-col gap-4 p-4 lg:p-0">
      <div>
        <h1 className="text-2xl font-extrabold">{name}</h1>
        <h3 className="text-neutral-500 dark:text-neutral-400">{username}</h3>
      </div>

      <div className="flex gap-2">
        <span className="self-start rounded-full bg-neutral-600 px-4 py-2 text-sm text-neutral-50">
          {auth[0] + auth.slice(1).toLowerCase()}
        </span>

        <StarCount id={id} />
      </div>

      {showEditButton && <button
        type="button"
        onClick={onEdit}
        className="focus-ring mt-4 w-full rounded bg-gray-200 py-2 text-center outline outline-gray-300 transition-colors hover:bg-gray-100 dark:bg-gray-700 dark:outline-gray-500 dark:hover:bg-gray-600">
        Edit profile
      </button>}
    </div>
  );
}

function UserEditor({ id, name, username, auth, onDone }: User & { onDone: () => void }): JSX.Element {
  const [newUsername, setNewUsername] = useState(username);
  const [newName, setNewName] = useState(name);
  const [newAuth, setNewAuth] = useState(auth);
  const [saving, setSaving] = useState(false);
  const { mutate } = useSWRConfig();
  const setError = useSession((state) => state.setError);
  const router = useRouter();

  const { data: currentUser } = useSWR<User>(
    api_url("/user/me"),
    fetcher, {
    shouldRetryOnError: false,
  });

  function submitUserEdit() {
    setSaving(true);
    fetch(api_url(`/user/edit/${id}`), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      credentials: "include",
      body: JSON.stringify({
        new_username: newUsername,
        new_name: newName,
        new_auth: newAuth,
      }),
    })
      .then(async res => {
        if (!res.ok) {
          setError("Error updating profile", true);
          return;
        }
        const data = await res.json();
        if (data.error) {
          setError("Error updating profile", true);
          return;
        }

        if (username == newUsername) {
          router.replace(`/user/${username}`);
        } else {
          router.push(`/user/${newUsername}`);
        }

        mutate(api_url("/user/me"));
        mutate(api_url(`/user/username/${username}`));
        if (username !== newUsername) {
          mutate(api_url(`/user/username/${newUsername}`));
        }
        onDone();
      })
      .catch(() => {
        setError("Network error", true);
      })
      .finally(() => {
        setSaving(false);
      });
  }

  return (
    <form
      className="flex flex-col gap-2 p-4 lg:p-0"
      onSubmit={(event) => {
        event.preventDefault();
        submitUserEdit();
      }}
    >
      <div className="flex flex-col gap-2">
        <label htmlFor="profile-name">Name</label>
        <input
          id="profile-name"
          value={newName}
          onChange={e => setNewName(e.target.value)}
          className="input-field"
          minLength={1}
          maxLength={16}
        />
      </div>

      <div className="flex flex-col gap-2">
        <label htmlFor="profile-username">Username</label>
        <input
          id="profile-username"
          value={newUsername}
          onChange={e => setNewUsername(e.target.value)}
          className="input-field"
          minLength={1}
          maxLength={16}
        />
      </div>

      {currentUser?.auth == "ADMIN" && <div className="flex flex-col gap-2">
        <label htmlFor="profile-auth">Auth</label>
        <select
          id="profile-auth"
          className="input-field"
          value={newAuth}
          onChange={e => setNewAuth(e.currentTarget.value as User["auth"])}
        >
          <option value="ADMIN">Admin</option>
          <option value="OFFICER">Officer</option>
          <option value="MEMBER">Member</option>
        </select>
      </div>}

      <LoadingButton
        type="submit"
        loading={saving}
        className="btn-success mt-4 w-full"
      >
        Save changes
      </LoadingButton>
    </form>
  );
}

function UserLoading(): JSX.Element {
  return (
    <div className="flex flex-col gap-2 p-4 lg:p-0" aria-busy="true" aria-label="Loading profile">
      <div className="my-1 h-6 w-32 animate-pulse rounded bg-neutral-300" />
      <div className="my-1 h-4 w-48 animate-pulse rounded bg-neutral-300" />
    </div>
  );
}

const UserPage: NextPage = () => {
  const { query, isReady } = useRouter();
  const username = query.username;
  const [editingProfile, setEditingProfile] = useState(false);

  const { data: user, error } = useSWR<User>(
    isReady && typeof username === "string" ? api_url(`/user/username/${username}`) : null,
    fetcher
  );

  if (error) return <Error statusCode={404} />;

  return (
    <div className="page-shell">
      <Navbar />

      <Head>
        <title>{user ? `${user.name} - ${user.username}` : "User"}</title>
      </Head>

      <main className="mx-auto grid w-full max-w-screen-md flex-1 grid-cols-[minmax(0,1fr)] grid-rows-min-full lg:max-w-screen-lg lg:grid-flow-col lg:grid-cols-[300px_minmax(0,1fr)] lg:grid-rows-1 lg:gap-4 lg:p-4">
        {!user ? (
          <UserLoading />
        ) : editingProfile ? (
          <UserEditor {...user} onDone={() => setEditingProfile(false)} />
        ) : (
          <UserInfo {...user} onEdit={() => setEditingProfile(true)} />
        )}

        {isReady && typeof username === "string" && (
          <RecentSubmissions username={username} />
        )}
      </main>

    </div>
  );
};

export default UserPage;
