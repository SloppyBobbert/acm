ALTER TABLE submissions ADD COLUMN language TEXT NOT NULL DEFAULT 'cpp'
    CHECK (language IN ('cpp', 'rust'));
