type ErrorBoxProps = {
    children: string;
};

export default function ErrorBox({ children }: ErrorBoxProps): JSX.Element {
    return (
        <div
            role="alert"
            className="my-4 flex flex-col gap-2 rounded-md border border-red-600 bg-red-500 p-4 text-red-50 dark:border-red-500 dark:bg-red-700"
        >
            <p className="text-2xl font-bold">Error</p>

            <pre className="overflow-auto rounded bg-red-700 p-2 dark:bg-red-800">
                <code>{children}</code>
            </pre>
        </div>
    );
}
