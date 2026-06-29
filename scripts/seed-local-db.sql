-- Development-only sample data for the local SQLite database.
-- This file is intentionally opt-in; production and CI should not run it.

INSERT OR IGNORE INTO users (id, auth, name, username, discord_id)
VALUES
    (1, 'OFFICER', 'Local Officer', 'local-officer', 'local-officer'),
    (2, 'MEMBER', 'Local Member', 'local-member', 'local-member');

INSERT OR IGNORE INTO meetings (id, title, description, meeting_time)
VALUES
    (
        1,
        'Local ACM Practice Night',
        'A seeded local meeting so the development site has upcoming content.',
        datetime('now', '+7 days')
    );

INSERT OR IGNORE INTO activities (id, meeting_id, title, description, activity_type)
VALUES
    (
        1,
        1,
        'Warm-up problems',
        'Small seeded examples for checking the local problem browser.',
        'SOLO'
    );

INSERT OR IGNORE INTO competitions (id, name, start, end)
VALUES
    (
        1,
        'Local Practice Contest',
        datetime('now', '-1 day'),
        datetime('now', '+14 days')
    );

INSERT OR IGNORE INTO problems (
    id,
    activity_id,
    title,
    description,
    runner,
    reference,
    template,
    visible,
    runtime_multiplier,
    competition_id,
    difficulty
)
VALUES
    (
        1,
        1,
        'Add One',
        'Write `solve` so it returns the input integer plus one. This problem is seeded for local development.',
        'c++',
        'int solve(int x) { return x + 1; }',
        'int solve(int x) {\n    return x;\n}',
        true,
        1.5,
        NULL,
        'Easy'
    ),
    (
        2,
        1,
        'Double It',
        'Write `solve` so it doubles the input integer. This seeded problem appears inside the local practice contest.',
        'c++',
        'int solve(int x) { return x * 2; }',
        'int solve(int x) {\n    return x;\n}',
        true,
        1.5,
        1,
        'Medium'
    );

INSERT OR IGNORE INTO tests (id, problem_id, test_number, input, expected_output, max_runtime, hidden)
VALUES
    (
        1,
        1,
        0,
        '{"name":"solve","arguments":[{"Int":{"Single":1}}],"return_type":{"Int":"Single"}}',
        '{"Int":{"Single":2}}',
        1000000000,
        false
    ),
    (
        2,
        1,
        1,
        '{"name":"solve","arguments":[{"Int":{"Single":41}}],"return_type":{"Int":"Single"}}',
        '{"Int":{"Single":42}}',
        1000000000,
        false
    ),
    (
        3,
        2,
        0,
        '{"name":"solve","arguments":[{"Int":{"Single":6}}],"return_type":{"Int":"Single"}}',
        '{"Int":{"Single":12}}',
        1000000000,
        false
    );

-- Keep previously seeded local databases aligned with the zero-based test
-- numbers expected by the problem console.
UPDATE tests
SET test_number = 0
WHERE id = 1
    AND problem_id = 1
    AND input = '{"name":"solve","arguments":[{"Int":{"Single":1}}],"return_type":{"Int":"Single"}}';

UPDATE tests
SET test_number = 1
WHERE id = 2
    AND problem_id = 1
    AND input = '{"name":"solve","arguments":[{"Int":{"Single":41}}],"return_type":{"Int":"Single"}}';

UPDATE tests
SET test_number = 0
WHERE id = 3
    AND problem_id = 2
    AND input = '{"name":"solve","arguments":[{"Int":{"Single":6}}],"return_type":{"Int":"Single"}}';

INSERT OR IGNORE INTO submissions (id, problem_id, user_id, success, runtime, code, complexity)
VALUES
    (
        1,
        1,
        1,
        true,
        1200,
        'int solve(int x) { return x + 1; }',
        'CONSTANT'
    );

-- Keep previously seeded local databases aligned with the backend enum value.
UPDATE submissions
SET complexity = 'CONSTANT'
WHERE id = 1
    AND problem_id = 1
    AND user_id = 1
    AND code = 'int solve(int x) { return x + 1; }';
